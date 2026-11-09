using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace RawLab.Windows;

internal sealed class EditedPhotoPreviews(EditStore store, string? cacheDirectory = null) : IAsyncDisposable
{
    internal EditStore Store { get; } = store;
    private readonly EditedPhotoPreviewCache cache = new(cacheDirectory ?? Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"RawLab","Cache","EditedPhotoPreviews"));
    private readonly SemaphoreSlim queue = new(1,1);
    private readonly CancellationTokenSource lifetime = new();
    private readonly object gate = new();
    private readonly HashSet<Task> tasks = [];
    private TaskCompletionSource<bool>? resume;
    private AIDenoiseJob? preparing;
    private PhotoPreviewResourceWatch? resourceWatch;
    internal event Action<string>? Ready;
    internal bool Paused { get { lock(gate)return resume!=null; } }

    internal void SetPaused(bool paused)
    {
        TaskCompletionSource<bool>? previous=null;AIDenoiseJob? cancel=null;
        lock(gate) {
            if(paused) {resume ??=new(TaskCreationOptions.RunContinuationsAsynchronously);cancel=preparing;}
            else {previous=resume;resume=null;}
        }
        cancel?.Cancel();
        if(previous!=null) {previous.TrySetResult(true);Ready?.Invoke("");}
    }
    private async Task WaitForEditor(CancellationToken cancellation)
    {
        Task? wait;lock(gate)wait=resume?.Task;
        if(wait!=null)await wait.WaitAsync(cancellation).ConfigureAwait(false);
    }

    internal Task<PhotoEditState> ReadStateAsync(string path,CancellationToken cancellation) =>
        Task.Run(()=>Store.ReadState(path),cancellation);

    internal Task<BitmapSource> ImageAsync(PhotoEditState record,string? look,int aiBackend,string aiDevice,CancellationToken cancellation)
    {
        if(record.Edit is {} edit) {
            resourceWatch ??=new PhotoPreviewResourceWatch(()=>Ready?.Invoke(""));
            resourceWatch.Watch(EditedPhotoPreviewKey.ResourcePaths(edit.Settings,look));
        }
        var task=RenderAsync(record.Copy(),look,aiBackend,aiDevice,cancellation);
        Track(task);return task;
    }
    private async Task<BitmapSource> RenderAsync(PhotoEditState record,string? look,int aiBackend,string aiDevice,CancellationToken cancellation)
    {
        using var linked=CancellationTokenSource.CreateLinkedTokenSource(cancellation,lifetime.Token);
        var token=linked.Token;
        await queue.WaitAsync(token).ConfigureAwait(false);
        try {
            await WaitForEditor(token).ConfigureAwait(false);
            return await Task.Run(async()=> {
                token.ThrowIfCancellationRequested();
                var key=EditedPhotoPreviewKey.Create(record,look,aiBackend:aiBackend,aiDevice:aiDevice);
                RequireCurrent(record,look,key,aiBackend,aiDevice);
                BitmapSource? cached=null;
                try {if(cache.Read(key) is {} bytes)cached=Decode(bytes);}
                catch(Exception error) when(error is IOException or NotSupportedException or System.FormatException or ArgumentException) { }
                if(cached!=null) {
                    token.ThrowIfCancellationRequested();
                    RequireCurrent(record,look,key,aiBackend,aiDevice);return cached;
                }
                if(record.Edit is not {} edit)throw new AdjustmentOperationExpiredException();
                if(edit.Look!=null && look==null || edit.Settings.MasterRecipeID!=null && look==null)
                    throw new FileNotFoundException(Loc.Text("外观不可用。"));
                using var engine=new RenderEngine(gpuMode:1,aiBackend:aiBackend,aiDeviceID:aiDevice);
                engine.SetCancellation(token);
                var settings=edit.Settings.Restore();
                if(settings.ActiveAIDenoise) {
                    RenderEngine.ValidateAIInput(record.Identity.Path,aiDevice,settings.X3fMode);
                    var job=new AIDenoiseJob((identity,snapshot,progress)=>engine.PrepareAI(identity.Source.Path,snapshot,progress));
                    using var cancel=token.Register(job.Cancel);
                    Task<bool> preparation;
                    lock(gate) {
                        if(resume!=null)throw new OperationCanceledException();
                        preparing=job;
                        preparation=job.StartAsync(AIDenoiseIdentity.Read(record.Identity.Path,settings,aiBackend,aiDevice),settings);
                    }
                    bool ready;
                    try {ready=await preparation.ConfigureAwait(false);}
                    finally {lock(gate)if(ReferenceEquals(preparing,job))preparing=null;}
                    token.ThrowIfCancellationRequested();
                    if(!ready && job.State.Status==AIDenoiseStatus.Cancelled)throw new OperationCanceledException();
                    if(!ready)throw new InvalidOperationException(job.State.Error ?? Loc.Text("预览未更新"));
                }
                token.ThrowIfCancellationRequested();
                var thread=Thread.CurrentThread;var priority=thread.Priority;
                BitmapSource frame;
                try {
                    thread.Priority=ThreadPriority.BelowNormal;
                    frame=engine.RenderPreview(record.Identity.Path,settings,look,EditedPhotoPreviewKey.Edge,
                        interactive:false,compare:false,clipping:false).Result.Image;
                } finally {thread.Priority=priority;}
                token.ThrowIfCancellationRequested();
                RequireCurrent(record,look,key,aiBackend,aiDevice);
                var encoded=Encode(frame);
                try {cache.Write(key,encoded);}catch(Exception error) when(error is IOException or UnauthorizedAccessException) { }
                var image=Decode(encoded);
                token.ThrowIfCancellationRequested();RequireCurrent(record,look,key,aiBackend,aiDevice);
                return image;
            },token).ConfigureAwait(false);
        } finally {queue.Release();}
    }

    internal Task AcceptAsync(PhotoEditState record,BitmapSource image,string? look,string expectedResources,int aiBackend,string aiDevice)
    {
        var task=Task.Run(()=> {
            lifetime.Token.ThrowIfCancellationRequested();
            if(!EditedPhotoPreviewKey.IsEdited(record) ||
                EditedPhotoPreviewKey.ResourceFingerprint(record.Edit!.Settings,look,aiBackend,aiDevice)!=expectedResources)return;
            var key=EditedPhotoPreviewKey.Create(record,look,aiBackend:aiBackend,aiDevice:aiDevice);
            RequireCurrent(record,look,key,aiBackend,aiDevice);
            var encoded=Encode(image);
            RequireCurrent(record,look,key,aiBackend,aiDevice);
            cache.Write(key,encoded);
            Ready?.Invoke(record.Identity.Path);
        },lifetime.Token);
        Track(task);return task;
    }
    private void RequireCurrent(PhotoEditState record,string? look,string key,int backend,string device)
    {
        if(!record.SameAs(Store.ReadState(record.Identity.Path)) ||
            key!=EditedPhotoPreviewKey.Create(record,look,aiBackend:backend,aiDevice:device))throw new AdjustmentOperationExpiredException();
    }
    internal static byte[] Encode(BitmapSource image)
    {
        var scale=Math.Min(1,(double)EditedPhotoPreviewKey.Edge/Math.Max(image.PixelWidth,image.PixelHeight));
        BitmapSource small=image;
        if(scale<1) {small=new TransformedBitmap(image,new ScaleTransform(scale,scale));small.Freeze();}
        var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(small));
        using var stream=new MemoryStream();encoder.Save(stream);return stream.ToArray();
    }
    private static BitmapSource Decode(byte[] data)
    {
        using var stream=new MemoryStream(data,writable:false);
        var image=BitmapFrame.Create(stream,BitmapCreateOptions.PreservePixelFormat,BitmapCacheOption.OnLoad);
        image.Freeze();return image;
    }
    private void Track(Task task)
    {
        lock(gate)tasks.Add(task);
        _=task.ContinueWith(completed=>{lock(gate)tasks.Remove(completed);},CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,TaskScheduler.Default);
    }
    public async ValueTask DisposeAsync()
    {
        resourceWatch?.Dispose();
        lifetime.Cancel();Task[] pending;lock(gate)pending=tasks.ToArray();
        try {await Task.WhenAll(pending).ConfigureAwait(false);}catch { }
        queue.Dispose();lifetime.Dispose();
    }
}
