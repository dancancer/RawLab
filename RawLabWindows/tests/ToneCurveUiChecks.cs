using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using RawLab.Windows;

internal static class ToneCurveUiChecks
{
    private const BindingFlags Private=BindingFlags.Instance|BindingFlags.NonPublic;
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x,int y);
    [DllImport("user32.dll")] private static extern void mouse_event(uint flags,uint dx,uint dy,uint data,UIntPtr extra);
    [DllImport("user32.dll")] private static extern IntPtr GetLastActivePopup(IntPtr owner);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window,out uint process);
    [DllImport("user32.dll")] private static extern IntPtr GetDlgItem(IntPtr dialog,int id);
    [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr window,uint message,IntPtr wParam,IntPtr lParam);
    private static T Get<T>(object value,string name)=>(T)value.GetType().GetField(name,Private)!.GetValue(value)!;
    private static object? Invoke(object value,string name,params object?[] args)=>value.GetType().GetMethod(name,Private)!.Invoke(value,args);
    private static void Ready(MainWindow window)=>InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
    private static void Pump(int milliseconds){var timer=Stopwatch.StartNew();InteractionChecks.PumpUntil(()=>timer.ElapsedMilliseconds>=milliseconds);}
    internal static void Run(string repo,string raw,Action<bool,string> check)
    {
        TestWindowState.PreserveExistingBatch(BatchJournal.DefaultDirectory);
        var output=Path.Combine(repo,"build","windows-curve-ui",Guid.NewGuid().ToString("N"));Directory.CreateDirectory(output);
        var photo=Path.Combine(output,"source"+Path.GetExtension(raw));File.Copy(raw,photo);
        var app=TestWindowState.CreateApplication();SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        Loc.Initialize("en");foreach(var pair in Loc.Strings)app.Resources[pair.Key]=pair.Value;
        var window=new MainWindow {Width=1200,Height=900};TestWindowState.Isolate(window,output);
        var store=new EditStore(Path.Combine(output,"edits"));typeof(MainWindow).GetField("editStore",Private)!.SetValue(window,store);
        try {
            window.GpuMode.SelectedIndex=1;window.Show();window.OpenFile(photo);Ready(window);
            var settings=Get<Adjustments>(window,"settings");var hdr=settings.IsHDREditing;
            settings.EditingCurve=ToneCurveSettings.Identity.Inserting(.5,.5);
            ToneCurveSettings ActiveCurve()=>Get<Adjustments>(window,"settings").EditingCurve;
            ToneCurveSettings StoredCurve()=>store.Find(photo)!.Settings.Restore().EditingCurve;
            settings.Set(Parameter.ToneCurve,65);Invoke(window,"MarkEdited");Invoke(window,"SelectTool",EditorAdjustmentTool.ToneCurve);Ready(window);
            var session=(AdjustmentTransferSession)typeof(MainWindow).GetProperty("TransferSession",Private)!.GetValue(window)!;
            var canvas=Get<ToneCurveCanvas>(window.CurveEditor,"canvas");window.Activate();InteractionChecks.PumpUntil(()=>window.IsActive);
            canvas.Focus();canvas.BringIntoView();Pump(100);window.UpdateLayout();
            var baseline=session.Transactions.Count;var before=ActiveCurve();
            var originalHDR=hdr ? Get<RenderedImage>(window,"result").HDR!.HDR : null;
            if (hdr) check(Get<Grid>(window.CurveEditor,"exposureAxis").IsVisible &&
                Get<TextBlock>(window.CurveEditor,"referenceWhite").Text.Contains("Reference White"),
                "HDR curve shows EV scale and reference white");
            var start=canvas.PointToScreen(new Point(canvas.ActualWidth/2,canvas.ActualHeight/2));
            Console.WriteLine($"CURVE_POINTER visible={canvas.IsVisible} enabled={canvas.IsEnabled} active={window.IsActive} size={canvas.RenderSize} screen={start} hit={window.InputHitTest(canvas.TranslatePoint(new Point(canvas.ActualWidth/2,canvas.ActualHeight/2),window))?.GetType().Name}");
            PhotoFeatureChecks.Screenshot(window,Path.Combine(output,"curve-before-pointer.png"));
            check(SetCursorPos((int)start.X,(int)start.Y),"Curve pointer reaches the interactive desktop");
            Pump(40);mouse_event(2,0,0,0,UIntPtr.Zero);
            var captureWait=Stopwatch.StartNew();InteractionChecks.PumpUntil(()=>canvas.IsMouseCaptured || captureWait.ElapsedMilliseconds>5000);
            check(canvas.IsMouseCaptured,"Native pointer press reaches the visible curve canvas");
            SetCursorPos((int)start.X+30,(int)start.Y-20);Pump(700);
            check(ActiveCurve()!=before && session.Transactions.Count==baseline,
                "Native curve drag changes preview without saving an intermediate history entry");
            mouse_event(4,0,0,0,UIntPtr.Zero);Ready(window);
            var changed=ActiveCurve();
            if (originalHDR != null) check(!originalHDR.RGB.SequenceEqual(Get<RenderedImage>(window,"result").HDR!.HDR.RGB),
                "HDR curve drag changes the floating-point preview");
            check(session.Transactions.Count==baseline+1 && StoredCurve()==changed,
                "One native curve drag saves one complete history entry");
            window.UndoAdjustmentMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));Ready(window);
            check(ActiveCurve()==before && StoredCurve()==before,"Curve Undo restores native and persisted points");
            window.RedoAdjustmentMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));Ready(window);
            check(ActiveCurve()==changed,"Curve Redo restores all points");
            var saved=store.ReadState(photo);baseline=session.Transactions.Count;
            var point=changed.Points[1];start=canvas.PointToScreen(new Point(12+point.X*(canvas.ActualWidth-24),12+(1-point.Y)*(canvas.ActualHeight-24)));
            SetCursorPos((int)start.X,(int)start.Y);Pump(40);mouse_event(2,0,0,0,UIntPtr.Zero);InteractionChecks.PumpUntil(()=>canvas.IsMouseCaptured);
            SetCursorPos((int)start.X-20,(int)start.Y+15);Pump(80);window.CurveEditor.CancelInputs();mouse_event(4,0,0,0,UIntPtr.Zero);Ready(window);
            check(ActiveCurve()==changed && store.ReadState(photo).SameAs(saved) && session.Transactions.Count==baseline,
                "Cancelled native curve drag restores its starting state and ignores late mouse-up");
            var x=Get<ParameterRow>(window.CurveEditor,"x");x.Number.BringIntoView();x.Number.Focus();x.Number.Text=hdr ? "-4" : "0.250000000000001";
            x.Number.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice,PresentationSource.FromVisual(x.Number),Environment.TickCount,Key.Enter){RoutedEvent=Keyboard.PreviewKeyDownEvent});Ready(window);
            check(ActiveCurve().Points[1].X==(hdr ? .25 : .250000000000001) && Get<Adjustments>(window,"settings")[Parameter.ToneCurve]==65,
                "Native coordinate input preserves Double precision and inactive legacy scalar");
            PhotoFeatureChecks.Screenshot(window,Path.Combine(output,"curve-native.png"));
            var exact=ActiveCurve();baseline=session.Transactions.Count;
            void Switch(bool confirm) {
                var clicked=0;var owner=new System.Windows.Interop.WindowInteropHelper(window).Handle;
                using var timer=new System.Threading.Timer(_=>{
                    var dialog=GetLastActivePopup(owner);
                    if(dialog==IntPtr.Zero || dialog==owner)return;
                    GetWindowThreadProcessId(dialog,out var process);if(process!=Environment.ProcessId)return;
                    var button=GetDlgItem(dialog,confirm ? 1 : 2);if(button==IntPtr.Zero)return;
                    if(Interlocked.Exchange(ref clicked,1)==0)SendMessage(button,0x00F5,IntPtr.Zero,IntPtr.Zero);
                },null,30,30);
                Get<Button>(window.CurveEditor,"switchMode").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                timer.Change(Timeout.Infinite,Timeout.Infinite);
                check(Volatile.Read(ref clicked)==1,"Native curve confirmation responds through its owned dialog button");Ready(window);
            }
            Switch(false);check(ActiveCurve()==exact && session.Transactions.Count==baseline,
                "Cancelling curve mode confirmation preserves the points and history");
            Switch(true);check(ActiveCurve().IsDefault && Get<Adjustments>(window,"settings")[Parameter.ToneCurve]==65,
                "Confirmed legacy mode restores the retained S curve scalar");
            Switch(true);check(ActiveCurve()==ToneCurveSettings.Identity && session.Transactions.Count==baseline+2,
                "Confirmed custom mode starts at identity and saves one mode transaction");
            window.UndoAdjustmentMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));Ready(window);
            window.UndoAdjustmentMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));Ready(window);
            check(ActiveCurve()==exact,"Mode Undo restores the complete precise curve");
            if (hdr) {
                window.OpenFile(photo);Ready(window);
                check(ActiveCurve()==exact && Get<Adjustments>(window,"settings").Curve.IsDefault,
                    "Reopened HDR curve leaves the dormant SDR curve intact");
                var destination=Path.Combine(output,"hdr-curve.jpg");
                var export=window.ExportPhoto(ExportFormat.HdrJpeg,destination);
                InteractionChecks.PumpUntil(()=>export.IsCompleted);
                export.GetAwaiter().GetResult();
                check(File.Exists(destination) && HDRNative.Probe(destination,out _)==HDRProbeState.Supported,
                    "Reopened HDR curve exports a readable HDR JPEG");
            }
            foreach(var language in new[]{"zh-Hans","en","de","fr","ja","es"}) {
                Loc.Initialize(language);System.Windows.Documents.TextElement.SetFontSize(window.CurveEditor,26);window.CurveEditor.RefreshLanguage();window.UpdateLayout();
                var remove=Get<Button>(window.CurveEditor,"remove");remove.BringIntoView();window.UpdateLayout();
                check(remove.ActualHeight>=32 && x.Number.ActualHeight>=26 && window.CurveEditor.ActualWidth<=window.ActualWidth,
                    "Curve layout grows for large text: "+language);
                PhotoFeatureChecks.Screenshot(window,Path.Combine(output,"curve-large-"+language+".png"));
            }
        } finally {mouse_event(4,0,0,0,UIntPtr.Zero);window.Close();app.Shutdown();}
    }
}
