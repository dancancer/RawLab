using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Windows.Media.Imaging;

namespace RawLab.Windows;
public sealed class LibraryEntry : INotifyPropertyChanged
{
    public static readonly HashSet<string> RawExtensions = PhotoInput.RawExtensions;
    public static bool IsRaw(string path) => PhotoInput.IsRaw(path);
    public static readonly HashSet<string> RasterExtensions = PhotoInput.RasterExtensions;
    public static bool IsRaster(string path) => PhotoInput.IsRaster(path);
    public static bool IsImage(string path) => IsRaw(path) || IsRaster(path);
    internal static string ImageFilter => string.Join(';',RawExtensions.Concat(RasterExtensions).Select(x=>"*."+x));
    public string Path { get; }
    public string Name => System.IO.Path.GetFileName(IsFolder ? System.IO.Path.TrimEndingDirectorySeparator(Path) : Path) is { Length: > 0 } name ? name : Path;
    public bool IsFolder { get; }
    private Task? directoryLoad;
    private bool directoryLoaded;
    private BitmapSource? thumbnail;
    private OriginalIdentity? thumbnailIdentity;
    private bool thumbnailVisible;
    private int thumbnailRequest;
    private CancellationTokenSource? thumbnailCancellation;
    private bool isEdited;
    private bool adjustedThumbnail;
    private string? previewNotice;
    public bool IsEdited { get=>isEdited; private set {if(isEdited==value)return;isEdited=value;OnPropertyChanged();OnPropertyChanged(nameof(PhotoStatus));} }
    public string? PreviewNotice { get=>previewNotice is {} key ? Loc.Text(key) : null; private set {previewNotice=value;OnPropertyChanged();OnPropertyChanged(nameof(PhotoStatus));} }
    internal void RefreshPhotoStatus() {OnPropertyChanged(nameof(PreviewNotice));OnPropertyChanged(nameof(PhotoStatus));}
    public string PhotoStatus => string.Join(" · ",new[]{IsSelected ? Loc.Text("当前照片") : null,
        IsMarked ? Loc.Text("已选") : null,IsEdited ? Loc.Text("已编辑") : null,PreviewNotice}.Where(value=>value!=null));
    public BitmapSource? Thumbnail { get=>thumbnail; private set { thumbnail=value; OnPropertyChanged(); } }
    public LibraryEntry? Parent { get; private set; }
    public ObservableCollection<LibraryEntry> Children { get; } = [];
    public ObservableCollection<LibraryEntry> Folders { get; } = [];
    public IReadOnlyList<LibraryEntry> Photos { get; private set; } = [];
    private bool isSelected;
    private bool isMarked;
    private bool isExpanded;
    public bool IsSelected { get=>isSelected; set { if(isSelected==value)return;isSelected=value;OnPropertyChanged();OnPropertyChanged(nameof(PhotoStatus)); } }
    public bool IsMarked { get=>isMarked; set { if(isMarked==value)return;isMarked=value;OnPropertyChanged();OnPropertyChanged(nameof(PhotoStatus)); } }
    public bool IsExpanded { get=>isExpanded; set { if(isExpanded==value)return;isExpanded=value;OnPropertyChanged(); } }
    public LibraryEntry(string path, bool folder)
    {
        Path = path;
        IsFolder = folder;
        if (folder)
        {
            var placeholder = new LibraryEntry("", false);
            Children.Add(placeholder);
            Folders.Add(placeholder);
        }
    }
    public async Task Load()
    {
        if (!IsFolder || directoryLoaded) return;
        var load = directoryLoad ??= ReadDirectory();
        try { await load; }
        finally { if (ReferenceEquals(load, directoryLoad)) directoryLoad = null; }
    }
    internal async Task Reload()
    {
        if (directoryLoad != null)
        {
            try { await Load(); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
        directoryLoaded = false;
        await Load();
    }
    private async Task ReadDirectory()
    {
        var existing = Children.ToDictionary(entry => entry.Path, StringComparer.Ordinal);
        var visiblePhotos = existing.Values.Where(entry => entry.thumbnailVisible)
            .Select(entry => entry.Path).ToHashSet(StringComparer.Ordinal);
        var paths = await Task.Run(() => new DirectoryInfo(Path).EnumerateFileSystemInfos()
            .Where(entry => (entry.Attributes & (FileAttributes.Hidden | FileAttributes.ReparsePoint)) == 0)
            .Where(entry => entry is DirectoryInfo || IsImage(entry.FullName))
            .OrderBy(entry => entry is DirectoryInfo ? 0 : 1).ThenBy(entry => entry.Name, StringComparer.CurrentCultureIgnoreCase)
            .Select(entry => (entry.FullName, Folder: entry is DirectoryInfo,
                Identity: visiblePhotos.Contains(entry.FullName) ? ReadThumbnailIdentity(entry.FullName) : null)).ToArray());
        var entries = paths.Select(path =>
        {
            if (existing.TryGetValue(path.FullName, out var entry) && entry.IsFolder == path.Folder)
            {
                if (!entry.thumbnailVisible || (path.Identity is { } current && entry.thumbnailIdentity?.SameFile(current) == true))
                    return entry;
                // Replacing the entry also lets the visible gallery request a new thumbnail.
                entry.ReleaseThumbnail();
            }
            return new LibraryEntry(path.FullName, path.Folder) { Parent = this };
        }).ToArray();
        Photos = entries.Where(entry => !entry.IsFolder).ToArray();
        // Keep existing folder instances and expansion state while refreshing children.
        foreach (var removed in Folders.Except(entries).ToArray()) Folders.Remove(removed);
        var index = 0;
        foreach (var child in entries.Where(entry => entry.IsFolder))
        {
            var position = Folders.IndexOf(child);
            if (position < 0) Folders.Insert(index, child);
            else if (position != index) Folders.Move(position, index);
            index++;
        }
        Children.Clear();
        foreach (var entry in entries) Children.Add(entry);
        directoryLoaded = true;
    }
    private static readonly SemaphoreSlim ThumbnailSlots = new(2);
    private static OriginalIdentity? ReadThumbnailIdentity(string path)
    {
        try { return OriginalIdentity.Read(path); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or Win32Exception) { return null; }
    }

    public Task LoadThumbnail() => LoadThumbnail(null,null,2,"");
    internal async Task LoadThumbnail(EditedPhotoPreviews? previews,Func<SavedEdit,string?>? resolveLook,int aiBackend,string aiDevice,bool refresh=false)
    {
        if(IsFolder || thumbnailVisible && !refresh || string.IsNullOrEmpty(Path))return;
        thumbnailVisible=true;
        thumbnailCancellation?.Cancel();thumbnailCancellation?.Dispose();
        thumbnailCancellation=new();var cancellation=thumbnailCancellation.Token;
        var request=++thumbnailRequest;
        try {
            PhotoEditState? record=null;
            if(previews!=null) {
                record=await previews.ReadStateAsync(Path,cancellation);
                if(request!=thumbnailRequest)return;
                IsEdited=EditedPhotoPreviewKey.IsEdited(record);
                if(thumbnailIdentity?.SameFile(record.Identity)!=true) {Thumbnail=null;adjustedThumbnail=false;}
                PreviewNotice=IsEdited ? adjustedThumbnail ? "预览待更新" : "原始预览" : null;
            }
            if(Thumbnail==null || !IsEdited && adjustedThumbnail) {
                await ThumbnailSlots.WaitAsync(cancellation);
                try {
                    var loaded=await Task.Run(()=>(Identity:ReadThumbnailIdentity(Path),Image:RenderEngine.Thumbnail(Path)),cancellation);
                    if(request!=thumbnailRequest)return;
                    thumbnailIdentity=loaded.Identity;Thumbnail=loaded.Image;adjustedThumbnail=false;
                } finally {ThumbnailSlots.Release();}
            }
            if(IsEdited && record!=null && previews!=null) {
                var look=record.Edit is {} edit ? resolveLook?.Invoke(edit) : null;
                var image=await previews.ImageAsync(record,look,aiBackend,aiDevice,cancellation);
                if(request!=thumbnailRequest)return;
                thumbnailIdentity=record.Identity;Thumbnail=image;adjustedThumbnail=true;PreviewNotice=null;
            }
        } catch(OperationCanceledException) { }
        catch(Exception) {if(request==thumbnailRequest)PreviewNotice="预览未更新";}
    }
    public void ReleaseThumbnail()
    {
        if(!thumbnailVisible)return;
        thumbnailVisible=false;++thumbnailRequest;
        thumbnailCancellation?.Cancel();thumbnailCancellation?.Dispose();thumbnailCancellation=null;
        thumbnailIdentity=null;Thumbnail=null;adjustedThumbnail=false;
    }
    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged([CallerMemberName]string? name=null)=>PropertyChanged?.Invoke(this,new(name));
    // 文件树的读屏名称取自 ToString：读目录或文件名，不读类型名
    public override string ToString()=>Name;
}
internal sealed class Library
{
    private readonly string settingsPath;
    private readonly Action<string, string>? moveFile;
    private readonly Action<TimeSpan>? sleep;
    private readonly Func<TimeSpan>? elapsed;
    public ObservableCollection<LibraryEntry> Roots { get; }=[];
    public Library() : this(null) { }
    internal Library(string? settingsPath, Action<string, string>? moveFile = null, Action<TimeSpan>? sleep = null, Func<TimeSpan>? elapsed = null)
    {
        this.settingsPath = settingsPath ?? System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"RawLab","folders.json");
        this.moveFile = moveFile; this.sleep = sleep; this.elapsed = elapsed;
        try { foreach(var path in JsonSerializer.Deserialize<string[]>(File.ReadAllText(this.settingsPath)) ?? [])Roots.Add(new(path,true)); }
        catch(Exception ex) when(ex is IOException or UnauthorizedAccessException or JsonException) { }
    }
    public void Add(string path) { path=System.IO.Path.TrimEndingDirectorySeparator(System.IO.Path.GetFullPath(path)); if(!Roots.Any(r=>System.IO.Path.TrimEndingDirectorySeparator(r.Path).Equals(path,StringComparison.OrdinalIgnoreCase)))Roots.Add(new(path,true)); Save(); }
    public void Remove(LibraryEntry entry) { Roots.Remove(entry); Save(); }
    private void Save() => AtomicFileWrite.WriteText(settingsPath,JsonSerializer.Serialize(Roots.Select(r=>r.Path)),moveFile,sleep,elapsed);
}
