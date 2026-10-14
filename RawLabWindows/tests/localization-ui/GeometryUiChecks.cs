using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;

// Optional actual-Windows entry: LocalizationUiChecks --geometry-ui RAW PRIVATE_RESULTS.
// Run in an interactive, task-owned desktop: the corner checks move its mouse pointer.
internal static class GeometryUiChecks
{
    private const BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;
    private static T Field<T>(MainWindow window, string name) => (T)typeof(MainWindow).GetField(name, Private)!.GetValue(window)!;
    private static void Call(MainWindow window, string name, params object[] args) => typeof(MainWindow).GetMethod(name, Private)!.Invoke(window, args);
    private static void Check(bool value, string message) { if(!value)throw new InvalidOperationException(message); Console.WriteLine("PASS: " + message); }
    internal static void Run(MainWindow window, string raw, string output)
    {
        if(Directory.Exists(output))throw new IOException("Use a fresh private geometry UI results directory.");
        Directory.CreateDirectory(output);
        var fixture=Path.Combine(output,"fixture"+Path.GetExtension(raw)); File.Copy(raw,fixture);
        var store=new EditStore(Path.Combine(output,"edits"));
        typeof(MainWindow).GetField("editStore",Private)!.SetValue(window,store);
        ((ComboBox)window.FindName("GpuMode")).SelectedIndex=1;
        Call(window,"OpenFile",fixture,null!); Wait(window);
        var settings=Field<Adjustments>(window,"settings");var baseline=settings.Geometry;
        var snapshot=settings.Capture();var frozen=BatchJob.Create(fixture,snapshot,null,"Neutral");
        var panel=(GeometryPanel)window.FindName("GeometryEditor");var canvas=(PhotoCanvas)window.FindName("ResultCanvas");
        var committedWidth=Field<object>(window,"result").GetType().GetProperty("NativeWidth")!;
        var nativeWidth=(int)committedWidth.GetValue(Field<object>(window,"result"))!;
        ((Button)window.FindName("GeometryCategory")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); Wait(window);
        var draft=Field<GeometryEditSession>(window,"geometrySession");
        Check(draft.IsActive && canvas.GeometryEditing && !((Button)window.FindName("CompareButton")).IsEnabled,
            "Geometry opens an isolated draft in a fitted single-image canvas");
        var generation=Field<long>(window,"geometryGeneration");
        var bounds=(Rect)typeof(PhotoCanvas).GetProperty("ImageBounds",Private)!.GetValue(canvas)!;
        Check(bounds.Width>0 && bounds.Left>=0 && bounds.Top>=0,"Pointer mapping uses the actual fitted image rectangle");
        var ratios=(ComboBox)panel.FindName("AspectPreset");
        ratios.SelectedIndex=2; Pump();
        var fullNative=Field<object>(window,"result");
        var nw=(int)fullNative.GetType().GetProperty("NativeWidth")!.GetValue(fullNative)!;
        var nh=(int)fullNative.GetType().GetProperty("NativeHeight")!.GetValue(fullNative)!;
        Check(Math.Abs(draft.Draft.CropWidth*nw/(draft.Draft.CropHeight*nh)-1)<1e-6,
            "Square ratio uses the uncropped native canvas");
        var before=CropInteraction.FromGeometry(draft.Draft);
        Drag(canvas,new(bounds.Left+before.Right*bounds.Width,bounds.Top+before.Bottom*bounds.Height),new(-35,-25));
        var first=CropInteraction.FromGeometry(draft.Draft);
        Drag(canvas,new(bounds.Left+first.Right*bounds.Width,bounds.Top+first.Bottom*bounds.Height),new(-35,-25));
        var second=CropInteraction.FromGeometry(draft.Draft);
        Check(second.Width<first.Width && second.Height<first.Height && !canvas.IsMouseCaptured,
            "Two native corner gestures use fresh baselines and release capture");
        var lockedBeforeFlip=draft.Draft;
        ((Button)panel.FindName("HorizontalFlip")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); Wait(window);
        Check(draft.Draft.CropX==lockedBeforeFlip.CropX && draft.Draft.CropY==lockedBeforeFlip.CropY &&
              draft.Draft.CropWidth==lockedBeforeFlip.CropWidth && draft.Draft.CropHeight==lockedBeforeFlip.CropHeight,
            "Flip preserves a manually resized crop with a locked ratio");
        generation=Field<long>(window,"geometryGeneration");
        ratios.SelectedIndex=0; Pump();
        var position=second;
        Drag(canvas,new(bounds.Left+(second.X+second.Width/2)*bounds.Width,bounds.Top+(second.Y+second.Height/2)*bounds.Height),new(20,15));
        Check(draft.Draft.CropWidth==position.Width && draft.Draft.CropHeight==position.Height && draft.Draft.CropX>position.X,
            "Native interior dragging moves the selection without resizing");
        Check(Field<long>(window,"geometryGeneration")==generation && settings.Geometry==baseline &&
              frozen.Settings.Restore().Geometry==baseline && store.Find(fixture)==null && !((MenuItem)window.FindName("ExportJpeg")).IsEnabled,
            "Crop gestures schedule no RAW render, save no draft and guard export/frozen batch");
        SaveVisual(window,Path.Combine(output,"windows-crop-draft.png"));
        ((Button)panel.FindName("CancelGeometry")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); Wait(window);
        Check(!draft.IsActive && settings.Geometry==baseline && store.Find(fixture)==null,"Cancel restores the committed render without persisting draft changes");
        ((Button)window.FindName("GeometryCategory")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); Wait(window);
        Call(window,"UpdateGeometryDraft",new GeometrySettings(.1,.1,.8,.8,0,false,false,2,.15,-.1),false); Wait(window);
        ((TabControl)panel.FindName("GeometryTabs")).SelectedIndex=1; Pump();
        SaveVisual(window,Path.Combine(output,"windows-correction-draft.png"));
        var expected=draft.Draft;var pendingGeneration=Field<long>(window,"geometryGeneration");
        ((Button)panel.FindName("ApplyGeometry")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); Wait(window);
        Check(!draft.IsActive && settings.Geometry==expected && store.Find(fixture)!.Settings.Restore().Geometry==expected &&
              Field<long>(window,"geometryGeneration")>pendingGeneration,
            "Apply commits one normalized draft and invalidates its uncropped render generation");
        var cropped=Field<object>(window,"result");
        Check((int)cropped.GetType().GetProperty("NativeWidth")!.GetValue(cropped)!<nativeWidth,
            "Apply publishes a cropped native result");
        ((Button)window.FindName("GeometryCategory")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); Wait(window);
        window.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice,PresentationSource.FromVisual(window),0,Key.Enter){RoutedEvent=Keyboard.KeyDownEvent}); Wait(window);
        Check(!draft.IsActive && settings.Geometry==expected && (int)Field<object>(window,"result").GetType().GetProperty("NativeWidth")!.GetValue(Field<object>(window,"result"))!<nativeWidth,
            "Enter applies an unchanged draft and still returns to the cropped result");
        ((Button)window.FindName("GeometryCategory")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); Wait(window);
        Call(window,"UpdateGeometryDraft",expected with { QuarterTurns=1 },true);
        window.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice,PresentationSource.FromVisual(window),0,Key.Escape){RoutedEvent=Keyboard.KeyDownEvent}); Wait(window);
        Check(!draft.IsActive && settings.Geometry==expected,"Escape cancels while a transform render is pending; stale draft work cannot publish");
        SaveVisual(window,Path.Combine(output,"windows-applied-crop.png"));
    }
    private static void Wait(MainWindow window)
    {
        var watch=Stopwatch.StartNew();
        while(watch.Elapsed<TimeSpan.FromMinutes(3)) {
            Pump();
            if(Field<bool>(window,"renderFailed"))throw new InvalidOperationException("Native RAW render failed: "+((TextBlock)window.FindName("Status")).Text);
            var scheduler=Field<object>(window,"scheduler");
            if(!(bool)scheduler.GetType().GetProperty("Busy")!.GetValue(scheduler)! && Field<bool>(window,"exactReady"))return;
            Thread.Sleep(15);
        }
        throw new TimeoutException("The exact native geometry preview did not complete.");
    }
    private static void Pump()
    {
        var frame=new DispatcherFrame();Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.Background,new Action(()=>frame.Continue=false));Dispatcher.PushFrame(frame);
    }
    private static void Drag(PhotoCanvas canvas,Point from,Vector delta)
    {
        from=new Point(Math.Clamp(from.X,2,canvas.ActualWidth-2),Math.Clamp(from.Y,2,canvas.ActualHeight-2));
        var start=canvas.PointToScreen(from); var end=canvas.PointToScreen(from+delta);
        SetCursorPos((int)start.X,(int)start.Y); Pump(); mouse_event(2,0,0,0,UIntPtr.Zero); Pump();
        Check(canvas.IsMouseCaptured,"Native crop pointer gesture captures the canvas");
        SetCursorPos((int)end.X,(int)end.Y); Pump(); mouse_event(4,0,0,0,UIntPtr.Zero); Pump();
    }
    private static void SaveVisual(Window window,string path)
    {
        window.UpdateLayout();var dpi=VisualTreeHelper.GetDpi(window);
        var bitmap=new RenderTargetBitmap((int)(window.ActualWidth*dpi.DpiScaleX),(int)(window.ActualHeight*dpi.DpiScaleY),96*dpi.DpiScaleX,96*dpi.DpiScaleY,PixelFormats.Pbgra32);
        bitmap.Render(window);var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));using var stream=File.Create(path);encoder.Save(stream);
    }
    [DllImport("user32.dll")]private static extern bool SetCursorPos(int x,int y);
    [DllImport("user32.dll")]private static extern void mouse_event(uint flags,uint dx,uint dy,uint data,UIntPtr extra);
}
