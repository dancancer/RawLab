using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;

internal static class HslTargetUiChecks
{
    private const BindingFlags Private=BindingFlags.NonPublic|BindingFlags.Instance;
    private static T Get<T>(object owner,string name)=>(T)owner.GetType().GetField(name,Private)!.GetValue(owner)!;
    private static object? Invoke(object owner,string name,params object[] args)=>owner.GetType().GetMethods(Private)
        .Single(method=>method.Name==name && method.GetParameters().Length==args.Length).Invoke(owner,args);
    internal static void Run(string repo,string unusedRaw,Action<bool,string> check)
    {
        var output=Path.Combine(repo,"build","windows-hsl-target",Guid.NewGuid().ToString("N"));Directory.CreateDirectory(output);
        var input=Path.Combine(output,"source.png");var other=Path.Combine(output,"other.png");
        var pixels=Enumerable.Range(0,96*64).SelectMany(_=>new byte[]{204,102,51}).ToArray();
        var bitmap=BitmapSource.Create(96,64,96,96,PixelFormats.Rgb24,null,pixels,96*3);
        var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using(var stream=File.Create(input))encoder.Save(stream);File.Copy(input,other);
        TestWindowState.PreserveExistingBatch(BatchJournal.DefaultDirectory);
        var app=TestWindowState.CreateApplication();SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        var window=new MainWindow();TestWindowState.Isolate(window,output);
        var failWrites=false;
        var store=new EditStore(Path.Combine(output,"edits"),(path,value)=>{
            if(failWrites)throw new IOException("Injected HSL save failure");
            AtomicJson.Write(path,value);
        });typeof(MainWindow).GetField("editStore",Private)!.SetValue(window,store);
        void Settled()=>InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
        try {
            window.GpuMode.SelectedIndex=1;window.Show();window.OpenFile(input);Settled();
            window.HslCategory.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));Invoke(window,"SetHslTargetMode",true,1);
            var session=(AdjustmentTransferSession)typeof(MainWindow).GetProperty("TransferSession",Private)!.GetValue(window)!;
            check(session.Transactions.Count==0,"Target mode and axis selection do not write history");
            window.AdjustToggleButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));window.UpdateLayout();
            InteractionChecks.PumpUntil(()=>!Get<DispatcherTimer>(window,"previewResize").IsEnabled && window.ExportPng.IsEnabled);
            check(window.HslTargetBanner.IsVisible && window.ResultCanvas.HslTargetEnabled,
                "Collapsing the panel keeps HSL target input and a visible exit control");
            var bounds=window.ResultCanvas.ImageBounds;
            check(window.ResultCanvas.HslCoordinates(new(-1,-1))==null,"Canvas rejects letterbox/outside hits");
            var center=new Point(bounds.X+bounds.Width*.5,bounds.Y+bounds.Height*.5);
            check(window.ResultCanvas.HslCoordinates(center) is {} point && Math.Abs(point.X-.5)<1e-8 && Math.Abs(point.Y-.5)<1e-8,
                "Canvas maps the full projected image to normalized photo coordinates");
            window.ResultCanvas.ComparisonEnabled=true;window.ResultCanvas.Divider=.5;
            check(window.ResultCanvas.HslCoordinates(center)==null && window.ResultCanvas.HslCoordinates(new(bounds.X+bounds.Width*.2,center.Y))==null,
                "Target rejects the wipe divider and reference half");
            window.ResultCanvas.ComparisonEnabled=false;
            Invoke(window,"BeginHslTarget",new Point(.5,.5),null!);Invoke(window,"MoveHslTarget",20.0);Invoke(window,"EndHslTarget");Settled();
            check(session.Transactions.Count==1 && !Get<Adjustments>(window,"settings").Hsl.IsIdentity,"Released pending target creates exactly one saved edit; history="+session.Transactions.Count+", notice="+Get<HslTargetAvailability?>(window,"hslTargetNotice"));
            var saved=store.VersionedState(input);var before=Get<Adjustments>(window,"settings").Capture();
            Invoke(window,"BeginHslTarget",new Point(.5,.5),null!);
            InteractionChecks.PumpUntil(()=>Get<bool>(window,"hslHistoryActive"));
            Invoke(window,"MoveHslTarget",50.0);Invoke(window,"CancelHslTarget");Invoke(window,"EndHslTarget");Settled();
            check(store.VersionedState(input).SameAs(saved) && Get<Adjustments>(window,"settings").Capture().SameAs(before) && session.Transactions.Count==1,
                "Cancelled target restores all settings without saving intermediate values");
            window.UndoAdjustmentMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));Settled();
            check(Get<Adjustments>(window,"settings").Hsl.IsIdentity,"Target undo restores the complete HSL snapshot");
            window.RedoAdjustmentMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));Settled();
            check(Get<Adjustments>(window,"settings").Capture().SameAs(before),"Target redo restores frozen weighted values");
            Invoke(window,"BeginHslTarget",new Point(.5,.5),null!);
            InteractionChecks.PumpUntil(()=>Get<bool>(window,"hslHistoryActive"));
            Invoke(window,"MoveHslTarget",7.0);failWrites=true;Invoke(window,"EndHslTarget");
            check(Get<object?>(window,"editGesture")==null && Get<bool>(window,"editDirty") && window.RetrySave.IsVisible,
                "Failed HSL save releases the gesture while preserving unsaved changes and retry");
            var unsaved=Get<Adjustments>(window,"settings").Capture();failWrites=false;
            Invoke(window,"BeginEditGesture");Invoke(window,"CancelEditGesture");
            check(Get<Adjustments>(window,"settings").Capture().SameAs(unsaved),"The next gesture does not roll back the failed HSL save");
            Invoke(window,"SaveEdits");Settled();
            Invoke(window,"ExitHslTargetClicked",window,new RoutedEventArgs());
            check(!window.ResultCanvas.HslTargetEnabled && !window.HslTargetBanner.IsVisible,"Canvas exit restores ordinary photo gestures");
            Invoke(window,"SetHslTargetMode",true,1);
            Invoke(window,"BeginHslTarget",new Point(.5,.5),null!);Invoke(window,"MoveHslTarget",20.0);window.OpenFile(other);Settled();
            check(Get<Adjustments>(window,"settings").Hsl.IsIdentity && !Get<HslTargetInteraction>(window,"hslTarget").Waiting,
                "Source switch cannot accept the previous photo's pending sample");
        } finally {window.Close();app.Shutdown();}
    }
}
