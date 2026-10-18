using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;

internal static partial class EditorReviewChecks
{
    // Pause the real batch worker at its first progress post, before rendering that item.
    private sealed class BatchProgressGate:IDisposable
    {
        private readonly Dispatcher dispatcher;
        private readonly ManualResetEventSlim entered=new(),release=new();
        private int claimed;
        public bool Entered=>entered.IsSet;
        public BatchProgressGate(Dispatcher dispatcher){this.dispatcher=dispatcher;dispatcher.Hooks.OperationPosted+=Posted;}
        private void Posted(object? sender,DispatcherHookEventArgs args)
        {
            if(dispatcher.CheckAccess() || !new StackTrace().GetFrames().Any(frame=>frame.GetMethod()?.DeclaringType==typeof(BatchRunner)) ||
                Interlocked.Exchange(ref claimed,1)!=0)return;
            entered.Set();if(!release.Wait(TimeSpan.FromMinutes(2)))throw new TimeoutException("Batch progress gate was not released");
        }
        public void Release()=>release.Set();
        public void Dispose(){dispatcher.Hooks.OperationPosted-=Posted;Release();entered.Dispose();release.Dispose();}
    }
    // Hold only dispatcher completion, not rendering, to make both completion orders deterministic.
    private sealed class HeldContext(SynchronizationContext target):SynchronizationContext
    {
        private readonly List<(SendOrPostCallback Callback,object? State)> pending=[];
        private bool released;
        public bool Pending{get{lock(pending)return pending.Count>0;}}
        public override void Post(SendOrPostCallback callback,object? state)
        {
            lock(pending){if(!released){pending.Add((callback,state));return;}}
            target.Post(callback,state);
        }
        public void Capture(Action action)
        {
            var previous=Current;SetSynchronizationContext(this);
            try{action();}finally{SetSynchronizationContext(previous);}
        }
        public void Release()
        {
            lock(pending){released=true;foreach(var (callback,state) in pending)target.Post(callback,state);pending.Clear();}
        }
    }
    private sealed class SteppedContext(SynchronizationContext target):SynchronizationContext
    {
        private readonly Queue<(SendOrPostCallback Callback,object? State)> pending=[];
        private bool released;
        public int Posts {get;private set;}
        public bool Pending{get{lock(pending)return pending.Count>0;}}
        public override void Post(SendOrPostCallback callback,object? state)
        {
            lock(pending){Posts++;if(!released){pending.Enqueue((callback,state));return;}}
            target.Post(_=>Capture(()=>callback(state)),null);
        }
        public void Capture(Action action){var previous=Current;SetSynchronizationContext(this);try{action();}finally{SetSynchronizationContext(previous);}}
        public void Next()
        {
            InteractionChecks.PumpUntil(()=>Pending);
            (SendOrPostCallback Callback,object? State) next;lock(pending)next=pending.Dequeue();
            Capture(()=>next.Callback(next.State));
        }
        public void Release(){lock(pending){released=true;while(pending.TryDequeue(out var next)){var item=next;target.Post(_=>Capture(()=>item.Callback(item.State)),null);}}}
    }
    private sealed class FormatOnlyDrop:IDataObject
    {
        public int PayloadReads {get;private set;}
        public object GetData(string format,bool autoConvert){PayloadReads++;throw new InvalidOperationException("Drag hover must not read payload paths");}
        public object GetData(string format)=>GetData(format,false);
        public object GetData(Type format)=>GetData(format.FullName!,false);
        public bool GetDataPresent(string format,bool autoConvert)=>format==DataFormats.FileDrop;
        public bool GetDataPresent(string format)=>GetDataPresent(format,false);
        public bool GetDataPresent(Type format)=>false;
        public string[] GetFormats(bool autoConvert)=>[DataFormats.FileDrop];
        public string[] GetFormats()=>GetFormats(false);
        public void SetData(string format,object data,bool autoConvert)=>throw new NotSupportedException();
        public void SetData(string format,object data)=>throw new NotSupportedException();
        public void SetData(Type format,object data)=>throw new NotSupportedException();
        public void SetData(object data)=>throw new NotSupportedException();
    }
    private static T Get<T>(object owner,string name)=>(T)owner.GetType().GetField(name,Private)!.GetValue(owner)!;
    private static void Set(object owner,string name,object value)=>owner.GetType().GetField(name,Private)!.SetValue(owner,value);
    private static object? Invoke(object owner,string name,params object[] args)=>owner.GetType().GetMethod(name,Private)!.Invoke(owner,args);
    private static void Click(Button button)=>button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    private static DragEventArgs RouteDrop(UIElement target,IDataObject data,bool drop,DragDropEffects allowed=DragDropEffects.Copy|DragDropEffects.Move)
    {
        var args=(DragEventArgs)Activator.CreateInstance(typeof(DragEventArgs),BindingFlags.Instance|BindingFlags.Public|BindingFlags.NonPublic,
            null,[data,DragDropKeyStates.None,allowed,target,new Point()],null)!;
        args.RoutedEvent=drop ? UIElement.PreviewDropEvent : UIElement.PreviewDragOverEvent;target.RaiseEvent(args);
        if(!args.Handled){args.RoutedEvent=drop ? UIElement.DropEvent : UIElement.DragOverEvent;target.RaiseEvent(args);}
        return args;
    }
    private static byte[] Pixels(BitmapSource image)
    {
        var stride=image.PixelWidth*4;var bytes=new byte[stride*image.PixelHeight];image.CopyPixels(bytes,stride,0);return bytes;
    }
}
