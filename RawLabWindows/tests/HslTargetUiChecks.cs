using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
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
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] private static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);

    internal static void RunHDR(string repo, string fixture, Action<bool,string> check)
    {
        var output = Path.Combine(repo, "build", "windows-hdr-color", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(output);
        var input = Path.Combine(output, "hdr.jpg");
        File.Copy(fixture, input);
        Loc.Initialize("en");
        var app = TestWindowState.CreateApplication();
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        var window = new MainWindow(); TestWindowState.Isolate(window, output);
        Adjustments Settings() => Get<Adjustments>(window, "settings");
        void Ready() => InteractionChecks.PumpUntil(() => window.ExportPng.IsEnabled);
        void Click(Button button) { check(button.IsEnabled, "HDR color control is enabled"); button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); }
        try
        {
            window.Show(); window.OpenFile(input); Ready(); window.Activate();
            InteractionChecks.PumpUntil(() => window.IsActive);
            check(Settings().IsHDREditing, "HDR color fixture opens in HDR mode");
            Invoke(window, "SelectTool", EditorAdjustmentTool.Vibrance);
            window.OrdinaryParameter.Number.Text = "35";
            check(window.OrdinaryParameter.Commit(), "The HDR vibrance editor commits a typed value"); Ready();
            check(Settings().HDR!.ColorSettings.Vibrance == 35 && Settings().ToneControls.Vibrance == 0,
                "Vibrance belongs to the HDR record");

            Click(window.HslCategory); Invoke(window, "SetHslTargetMode", true, 1);
            Ready(); window.UpdateLayout();
            var canvas = window.ResultCanvas;
            var bounds = canvas.ImageBounds;
            var point = new Point(bounds.X + bounds.Width * .54, bounds.Y + bounds.Height * .53);
            check(canvas.HslCoordinates(point) != null, "The HDR image accepts a canvas hit");
            var before = Settings().EditingHsl;
            var screen = canvas.PointToScreen(point);
            check(SetCursorPos((int)screen.X, (int)screen.Y), "Native pointer reaches the visible HDR canvas");
            mouse_event(2, 0, 0, 0, UIntPtr.Zero);
            InteractionChecks.PumpUntil(() => canvas.IsMouseCaptured);
            SetCursorPos((int)screen.X, (int)screen.Y - 36);
            InteractionChecks.PumpUntil(() => !Settings().EditingHsl.Equals(before));
            mouse_event(4, 0, 0, 0, UIntPtr.Zero);
            InteractionChecks.PumpUntil(() => !canvas.IsMouseCaptured); Ready();
            var editedHsl = Settings().EditingHsl;
            check(!editedHsl.Equals(before) && Settings().Hsl.IsIdentity &&
                Get<HslTargetInteraction>(window, "hslTarget").Selection?.Usable == true,
                "Native HDR target drag samples the HDR plane and leaves SDR HSL neutral");
            PhotoFeatureChecks.Screenshot(window, Path.Combine(output, "hdr-target.png"));
            window.UndoAdjustmentMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent)); Ready();
            check(Settings().EditingHsl.Equals(before), "Undo restores HDR HSL");
            window.RedoAdjustmentMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent)); Ready();
            check(Settings().EditingHsl.Equals(editedHsl), "Redo restores the weighted HDR edit");

            Click(window.GradingCategory);
            window.GradingEditor.SelectZone(ColorGradingZone.Highlights);
            var saturation = Get<ParameterRow>(window.GradingEditor, "saturation");
            saturation.Number.Text = "40";
            check(saturation.Commit(), "The HDR grading editor commits a wheel value"); Ready();
            var edited = Settings().HDR!;
            check(edited.ProcessingVersion == 3 && edited.ColorSettings.Grading.Highlights.Saturation == 40 &&
                Settings().ColorGrading.IsDefault, "Grading belongs to the HDR record");
            PhotoFeatureChecks.Screenshot(window, Path.Combine(output, "hdr-grading.png"));
            window.HDREditMenu.IsChecked = false;
            window.HDREditMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent)); Ready();
            check(!Settings().IsHDREditing && Settings().EditingHsl.IsIdentity && Settings().EditingGrading.IsDefault,
                "Switching to SDR restores its own colors");
            window.HDREditMenu.IsChecked = true;
            window.HDREditMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent)); Ready();
            window.OpenFile(input); Ready();
            check(Settings().HDR == edited, "Reopening restores HDR color v3");
            var destination = Path.Combine(output, "hdr-color.jpg");
            var export = window.ExportPhoto(ExportFormat.HdrJpeg, destination);
            InteractionChecks.PumpUntil(() => export.IsCompleted);
            export.GetAwaiter().GetResult();
            check(HDRNative.Probe(destination, out _) == HDRProbeState.Supported, "HDR color edits export and read back");
        }
        finally { mouse_event(4, 0, 0, 0, UIntPtr.Zero); window.Close(); app.Shutdown(); }
    }

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
            var beforePreview=store.VersionedState(input);
            var transactionCount=session.Transactions.Count;
            Invoke(window,"SetHslTargetMode",true,1);
            Invoke(window,"BeginHslTarget",new Point(.5,.5),null!);
            Invoke(window,"MoveHslTarget",20.0);
            PhotoFeatureChecks.Click(window.PreviewWorkspaceButton);
            window.UpdateLayout();
            check(window.PhotoArea.IsVisible && !window.ResultCanvas.HslTargetEnabled && !window.HslTargetBanner.IsVisible &&
                !Get<bool>(window,"hslTargetEnabled"),"Entering Preview exits HSL target mode");
            Invoke(window,"EndHslTarget");Settled();
            check(store.VersionedState(input).SameAs(beforePreview) && session.Transactions.Count==transactionCount,
                "A queued HSL sample cannot save edits after entering Preview");
            PhotoFeatureChecks.Click(window.EditingWorkspaceButton);Settled();
            check(!window.ResultCanvas.HslTargetEnabled,"Returning to Edit keeps HSL target mode off");
            Invoke(window,"SetHslTargetMode",true,1);
            Invoke(window,"BeginHslTarget",new Point(.5,.5),null!);Invoke(window,"MoveHslTarget",20.0);window.OpenFile(other);Settled();
            check(Get<Adjustments>(window,"settings").Hsl.IsIdentity && !Get<HslTargetInteraction>(window,"hslTarget").Waiting,
                "Source switch cannot accept the previous photo's pending sample");
        } finally {window.Close();app.Shutdown();}
    }
}
