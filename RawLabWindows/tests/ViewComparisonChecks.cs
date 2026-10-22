using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;

internal static class ViewComparisonChecks
{
    private const BindingFlags Private=BindingFlags.Instance|BindingFlags.NonPublic;
    private static T Get<T>(object owner,string name)=>(T)owner.GetType().GetField(name,Private)!.GetValue(owner)!;
    private static void Set(object owner,string name,object? value)=>owner.GetType().GetField(name,Private)!.SetValue(owner,value);
    private static object? Invoke(MainWindow window,string name,params object[] args)=>typeof(MainWindow).GetMethod(name,Private)!.Invoke(window,args);
    private static void Click(Control control)=>control.RaiseEvent(new RoutedEventArgs(control is MenuItem ? MenuItem.ClickEvent : Button.ClickEvent));
    private static void Ready(MainWindow window)=>InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
    internal static void Run(string repo,string raw,Action<bool,string> check,Application? application=null,bool pointerOnly=false)
    {
        var output=Path.Combine(repo,"build","windows-v08-results","view-comparison",DateTime.Now.ToString("yyyyMMdd-HHmmss"));Directory.CreateDirectory(output);
        var app=application ?? TestWindowState.CreateApplication();SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        void ApplyLanguage(){foreach(var pair in Loc.Strings)app.Resources[pair.Key]=pair.Value;}
        Loc.Changed+=ApplyLanguage;
        var window=new MainWindow{Width=1200,Height=800};TestWindowState.Isolate(window,output);window.GpuMode.SelectedIndex=1;window.Show();
        Console.WriteLine("S3 artifacts: "+output);
        try {
            window.OpenFile(raw);Ready(window);var view=Get<EditorViewState>(window,"view");
            var initial=Get<Adjustments>(window,"settings").Capture();var revision=Get<long>(window,"editRevision");
            check(System.Windows.Automation.AutomationProperties.GetAutomationId(window.CompareModeButton)=="CompareModeButton","Comparison mode dropdown has a stable native automation identifier");
            if(pointerOnly) {
                check(Environment.GetEnvironmentVariable("RAWLAB_TEST_NATIVE_POINTER")=="1","Pointer-only acceptance explicitly requires native input authorization");
                Click(window.BeforeViewMenu);InteractionChecks.PumpUntil(()=>window.ResultCanvas.ShowingBefore);Click(window.BeforeViewMenu);
                PointerChecks(window,output,check);
                check(initial.SameAs(Get<Adjustments>(window,"settings").Capture()) && revision==Get<long>(window,"editRevision"),"Native viewing input creates no parameter edit");return;
            }
            Click(window.CompareButton);Ready(window);Capture(window,output,"first-side");
            check(view.Enabled && view.PreferredMode==ComparisonMode.SideBySide && window.NeutralCanvas.IsVisible,"First real toolbar toggle enables side-by-side comparison");
            Click(window.CompareSwipe);Ready(window);Click(window.CompareButton);Click(window.CompareButton);Ready(window);Capture(window,output,"restored-wipe");
            check(view.Enabled && view.PreferredMode==ComparisonMode.Wipe && window.ResultCanvas.ComparisonEnabled,"Toolbar off/on restores wipe instead of cycling through another mode");
            window.ResultCanvas.Divider=.25;window.ResultCanvas.Focus();
            window.ResultCanvas.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice,PresentationSource.FromVisual(window.ResultCanvas),Environment.TickCount,Key.Home){RoutedEvent=Keyboard.KeyDownEvent});
            check(window.ResultCanvas.Divider==.5,"Focused photo Home resets the normalized divider");
            var source=Path.Combine(output,"same-values"+Path.GetExtension(raw));File.Copy(raw,source,true);window.OpenFile(source);Ready(window);
            check(!view.Enabled && !view.HoldingBefore && view.PreferredMode==ComparisonMode.Wipe,"Actual photo replacement closes comparison and remembers the session mode");
            Click(window.BeforeViewMenu);InteractionChecks.PumpUntil(()=>window.ResultCanvas.ShowingBefore);Capture(window,output,"semantic-before");
            check(view.HoldingBefore && window.Histogram.Bins==null && window.ClipStats.Text=="","Before action hides after statistics when the real neutral frame has no bins");
            Click(window.BeforeViewMenu);check(!window.ResultCanvas.ShowingBefore,"Accessible before action returns to the adjusted frame");
            ReferenceReadinessChecks(window,source,output,check);
            var inset=window.ResultCanvas.ImageBounds;Click(window.MenuPhotoMargin);window.UpdateLayout();Capture(window,output,"no-margin");
            check(!view.PhotoMargin && !window.ZoomPhotoMargin.IsChecked && window.ResultCanvas.ImageBounds.Width>=inset.Width && window.ResultCanvas.ImageBounds.Height>=inset.Height,"View menu removes margins while keeping the entire photograph fitted");
            Click(window.ZoomPhotoMargin);check(view.PhotoMargin && window.MenuPhotoMargin.IsChecked,"Zoom and View menus share one photo-margin preference");
            Click(window.InfoEntryButton);InteractionChecks.PumpUntil(()=>window.InfoOverlay.IsVisible);Click(window.InfoButton);Capture(window,output,"capture-info");
            check(Get<PhotoInfoMode>(window,"photoInfoMode")==PhotoInfoMode.Capture,"Photo corner and toolbar advance the same information mode");
            Click(window.InfoEntryButton);check(!window.InfoOverlay.IsVisible,"Photo corner completes the information cycle back to hidden");
            Click(window.CompareSide);Ready(window);Click(window.AdjustToggleButton);window.LibraryColumn.Width=new GridLength(520);window.Width=1000;window.Height=780;window.UpdateLayout();Ready(window);Capture(window,output,"vertical-side");
            check(window.PhotoArea.ActualHeight>window.PhotoArea.ActualWidth && Grid.GetRow(window.NeutralCanvas)==0 && Grid.GetRow(window.ResultCanvas)==1,"A tall narrow photo area stacks comparison without changing the dock budget");
            CheckLabels(window,check);
            Click(window.AdjustToggleButton);window.LibraryColumn.Width=new GridLength(244);window.Width=1200;window.Height=800;window.UpdateLayout();Ready(window);
            Click(window.CompareButton);var area=window.PhotoArea.RenderSize;var dock=window.DockRow.ActualHeight;Invoke(window,"Schedule",false);window.UpdateLayout();Capture(window,output,"busy");
            check(window.BusyIndicator.IsVisible && window.BusyIndicator.ActualHeight==2 && window.PhotoArea.RenderSize==area && window.DockRow.ActualHeight==dock,"Latest-preview busy is a two-DIP photo overlay with no canvas or dock layout jump");Ready(window);
            if(Environment.GetEnvironmentVariable("RAWLAB_TEST_NATIVE_POINTER")=="1")PointerChecks(window,output,check);
            else Console.WriteLine("NOT REACHED: native S3 pointer/keyboard checks require RAWLAB_TEST_NATIVE_POINTER=1 on the interactive input desktop");
            LayoutChecks(window,app,output,check);
            check(initial.SameAs(Get<Adjustments>(window,"settings").Capture()) && revision==Get<long>(window,"editRevision") && !Get<bool>(window,"editDirty"),"Comparison, hold, info, margins and layout create no parameter edit or autosave");
            var image=Get<BitmapSource>(window.ResultCanvas,"image");var accepted=Get<RenderedImage>(window,"result");
            var invalid=Path.Combine(output,"invalid.cube");File.WriteAllText(invalid,"invalid LUT");Set(window,"lut",invalid);Invoke(window,"Schedule",false);
            InteractionChecks.PumpUntil(()=>Get<bool>(window,"renderFailed") && !(bool)Get<object>(window,"scheduler").GetType().GetProperty("Busy")!.GetValue(Get<object>(window,"scheduler"))!);
            Capture(window,output,"failed-preview");
            check(ReferenceEquals(image,Get<BitmapSource>(window.ResultCanvas,"image")) && ReferenceEquals(accepted,Get<RenderedImage>(window,"result")) && window.RetryButton.IsVisible && !window.ExportPng.IsEnabled,"Failed latest preview keeps the last accepted pixels, marks outdated and offers retry without pretending exact");
            Set(window,"lut",null);Click(window.RetryButton);Ready(window);
            var store=Get<EditStore>(window,"editStore");var blocked=Path.Combine(output,"blocked-save");Directory.CreateDirectory(Path.Combine(blocked,"edits.json"));Set(window,"editStore",new EditStore(blocked));Invoke(window,"MarkEdited");Invoke(window,"SaveEdits");
            Invoke(window,"Schedule",false);Ready(window);Capture(window,output,"save-error-after-preview");
            check(window.RetrySave.IsVisible,"Successful preview does not clear the independent unsaved-adjustment error");Set(window,"editStore",store);Invoke(window,"SaveEdits");
            NeutralChecks(raw,output,check);
        } catch {
            try{Capture(window,output,"failure-before-close");}catch(Exception diagnostic){Console.WriteLine("Failure screenshot unavailable: "+diagnostic.Message);}
            throw;
        } finally {window.Close();Loc.Changed-=ApplyLanguage;if(application==null)app.Shutdown();}
        Console.WriteLine("S3 artifacts: "+output);
    }
    private static void LayoutChecks(MainWindow window,Application app,string output,Action<bool,string> check)
    {
        var previous=Loc.Language;var size=(double)app.Resources["EditorBodySize"];var preference=Path.Combine(output,"language.txt");
        try {
            foreach(var language in new[]{"zh-Hans","en","de","fr","ja","es"})foreach(var font in new[]{13.0,26.0}) {
                Loc.SetPreference(language,preference);app.Resources["EditorBodySize"]=font;window.FontSize=font;
                window.Width=font==26 ? 1000 : 1200;window.Height=font==26 ? 720 : 800;window.UpdateLayout();
                window.SetComparisonMode(true,true);Ready(window);window.UpdateLayout();
                Capture(window,output,$"view-{language}-{window.Width}-{font}");CheckLabels(window,check);
                check(window.BusyIndicator.Height==2 && window.CompareButton.ActualWidth>=28 && window.CompareModeButton.ActualWidth>=28,
                    $"Viewing controls retain reachable targets and fixed progress thickness: {language}/{font}");
                window.CompareButton.ContextMenu!.IsOpen=true;window.CompareButton.ContextMenu.UpdateLayout();
                var menu=window.CompareButton.ContextMenu;var bitmap=new RenderTargetBitmap(Math.Max(1,(int)Math.Ceiling(menu.ActualWidth)),Math.Max(1,(int)Math.Ceiling(menu.ActualHeight)),96,96,PixelFormats.Pbgra32);bitmap.Render(menu);
                var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));using(var stream=File.Create(Path.Combine(output,$"mode-menu-{language}-{font}.png")))encoder.Save(stream);
                check(window.CompareSide.Header?.ToString()==Loc.Text("并排") && window.CompareSwipe.Header?.ToString()==Loc.Text("分割线"),"Mode menu follows the active language: "+language);menu.IsOpen=false;
            }
        } finally {Loc.SetPreference(previous,preference);app.Resources["EditorBodySize"]=size;window.FontSize=size;window.Width=1200;window.Height=800;window.SetComparisonMode(false,false);window.UpdateLayout();Ready(window);}
    }
    private static void CheckLabels(MainWindow window,Action<bool,string> check)
    {
        var beforeCanvas=window.NeutralCanvas.IsVisible ? window.NeutralCanvas : window.ResultCanvas;
        foreach(var (label,canvas) in new[]{(window.NeutralLabel,beforeCanvas),(window.FilmLabel,window.ResultCanvas)}) {
            var labelRect=label.TransformToAncestor(window.PhotoArea).TransformBounds(new Rect(label.RenderSize));
            var photo=canvas.TransformToAncestor(window.PhotoArea).TransformBounds(canvas.VisibleImageBounds);
            check(label.IsVisible && photo.Contains(labelRect),"Comparison label remains inside its actual visible photograph: "+label.Name);
        }
    }
    private static void NeutralChecks(string raw,string output,Action<bool,string> check)
    {
        byte[] Pixels(BitmapSource bitmap){var bytes=new byte[bitmap.PixelWidth*bitmap.PixelHeight*4];new FormatConvertedBitmap(bitmap,PixelFormats.Bgra32,null,0).CopyPixels(bytes,bitmap.PixelWidth*4,0);return bytes;}
        using var engine=new RenderEngine(0);var edited=new Adjustments();edited.Set(Parameter.Exposure,.8);
        var first=engine.RenderPreview(raw,edited,null,256,false,true,false);
        var expected=engine.Render(raw,new Adjustments(),null,256,statistics:false,clipping:false,viewportPreview:true)!;
        check(Pixels(first.Neutral.Image).SequenceEqual(Pixels(expected.Image)) && !Pixels(first.Neutral.Image).SequenceEqual(Pixels(first.Result.Image)),"Real RAW before matches the default neutral render and differs from the user's exposure adjustment");
        edited.Set(Parameter.Exposure,1.2);
        var grading=engine.RenderPreview(raw,edited,null,256,false,true,false);
        check(ReferenceEquals(first.Neutral,grading.Neutral),"User exposure changes reuse the default neutral reference rather than changing its grading");
        edited.Lens=edited.Lens with{Distortion=true};var lens=engine.RenderPreview(raw,edited,null,256,false,true,false);
        check(!ReferenceEquals(grading.Neutral,lens.Neutral),"Lens-only composition changes invalidate the real neutral cache even when no matching calibration applies");
        edited.Geometry=new(.1,.1,.7,.6,1);var geometry=engine.RenderPreview(raw,edited,null,256,false,true,false);
        check(geometry.Neutral.NativeWidth==geometry.Result.NativeWidth && geometry.Neutral.NativeHeight==geometry.Result.NativeHeight,"Real neutral and edited frames share the committed geometry dimensions");
        var resized=engine.RenderPreview(raw,edited,null,384,false,true,false);
        check(!ReferenceEquals(geometry.Neutral,resized.Neutral) && Math.Max(resized.Neutral.Image.PixelWidth,resized.Neutral.Image.PixelHeight)==384,"Neutral reference demand changes produce the requested exact size");
        engine.RenderPreview(raw,edited,null,384,false,false,false);
        check(Get<object?>(engine,"original")!=null,"Closing comparison retains a same-key neutral for temporary before reuse");
        engine.RenderPreview(raw,edited,null,256,false,false,false);
        check(Get<object?>(engine,"original")==null,"A new demand releases the obsolete neutral even while comparison is closed");
        engine.RenderPreview(raw,edited,null,256,false,true,false);edited.Geometry=new();
        engine.RenderPreview(raw,edited,null,256,false,false,false);
        check(Get<object?>(engine,"original")==null,"A composition change releases the obsolete neutral while comparison is closed");
        var raster=Path.Combine(output,"neutral-raster.png");var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(first.Result.Image));using(var stream=File.Create(raster))encoder.Save(stream);
        var rasterEdit=new Adjustments();rasterEdit.Set(Parameter.Exposure,.7);var rasterFrame=engine.RenderPreview(raster,rasterEdit,null,192,false,true,false);
        var rasterDefault=engine.Render(raster,new Adjustments(),null,192,statistics:false,clipping:false,viewportPreview:true)!;
        check(Pixels(rasterFrame.Neutral.Image).SequenceEqual(Pixels(rasterDefault.Image)) && !Pixels(rasterFrame.Neutral.Image).SequenceEqual(Pixels(rasterFrame.Result.Image)),"Real raster before uses the sensor/none default without copying the adjusted exposure");
        SourceIdentityChecks(output,check);
    }
    internal static void SourceIdentityChecks(string output,Action<bool,string> check)
    {
        Directory.CreateDirectory(output);var path=Path.Combine(output,"same-stamp.tif");
        void Write(byte value){var pixels=Enumerable.Repeat(new byte[]{value,value,value,255},32*32).SelectMany(x=>x).ToArray();var encoder=new TiffBitmapEncoder{Compression=TiffCompressOption.None};encoder.Frames.Add(BitmapFrame.Create(BitmapSource.Create(32,32,96,96,PixelFormats.Bgra32,null,pixels,32*4)));using(var stream=File.Create(path))encoder.Save(stream);}
        byte[] Pixels(RenderedImage frame){var bytes=new byte[frame.Image.PixelWidth*frame.Image.PixelHeight*4];new FormatConvertedBitmap(frame.Image,PixelFormats.Bgra32,null,0).CopyPixels(bytes,frame.Image.PixelWidth*4,0);return bytes;}
        Write(40);var previous=OriginalIdentity.Read(path);using var engine=new RenderEngine(0);
        var first=engine.RenderPreview(path,new Adjustments(),null,32,false,true,false);
        Write(200);File.SetLastWriteTimeUtc(path,new DateTime(previous.Modified,DateTimeKind.Utc));File.SetCreationTimeUtc(path,new DateTime(previous.Created,DateTimeKind.Utc).AddSeconds(2));
        var current=OriginalIdentity.Read(path);check(current.Length==previous.Length && current.Modified==previous.Modified && current.Created!=previous.Created,"Native raster replacement fixture changes only creation identity while preserving length and modified time");
        var replaced=engine.RenderPreview(path,new Adjustments(),null,32,false,true,false);
        check(!Pixels(first.Result).SequenceEqual(Pixels(replaced.Result)) && !Pixels(first.Neutral).SequenceEqual(Pixels(replaced.Neutral)),"Replacing a same-stamp raster refreshes both decoded after and neutral pixels rather than relabelling old display input");
    }
    private static void ReferenceReadinessChecks(MainWindow window,string source,string output,Action<bool,string> check)
    {
        bool Current()=>(bool)typeof(MainWindow).GetProperty("ReferenceCurrent",Private)!.GetValue(window)!;
        var old=Get<RenderedImage>(window,"neutralResult");
        File.SetLastWriteTimeUtc(source,File.GetLastWriteTimeUtc(source).AddSeconds(2));Invoke(window,"Schedule",false);Ready(window);
        Capture(window,output,"source-replaced-after");
        check(!Current() && Get<RenderedImage?>(window,"neutralResult")==null,"An accepted after from a replaced same-path source releases the old neutral before reopening comparison");
        check(Get<object?>(Get<RenderEngine>(window,"engine"),"original")==null,"The same-source replacement also releases the obsolete engine reference while comparison is closed");
        Click(window.CompareButton);check(!Current(),"Reopening comparison cannot briefly publish the replaced source's neutral");Ready(window);
        check(Current() && !ReferenceEquals(old,Get<RenderedImage>(window,"neutralResult")),"Comparison accepts a new same-source neutral and after together");
        Click(window.CompareButton);Invoke(window,"ActualClicked",window,new RoutedEventArgs());Ready(window);
        check(!Current() && Get<RenderedImage?>(window,"neutralResult")==null,"A single-view native-size after does not make the previous smaller neutral ready");
        Click(window.CompareButton);check(!Current(),"A native-size comparison waits for its matching reference demand");Ready(window);Capture(window,output,"native-demand-reference");
        check(Current() && Get<NeutralReferenceKey>(window,"acceptedReference").Edge==0,"Native-size comparison publishes a matching native neutral");
        Click(window.CompareButton);Invoke(window,"FitClicked",window,new RoutedEventArgs());Ready(window);
    }
    private static void Capture(MainWindow window,string output,string name)
    {
        window.UpdateLayout();object RectValue(Rect r)=>new {r.X,r.Y,r.Width,r.Height};
        var state=new {photoArea=window.PhotoArea.RenderSize,dock=window.DockRow.ActualHeight,busy=window.BusyIndicator.ActualHeight,windowState=window.WindowState.ToString(),font=window.FontSize,dpi=VisualTreeHelper.GetDpi(window).DpiScaleX,
            neutral=RectValue(window.NeutralCanvas.ImageBounds),result=RectValue(window.ResultCanvas.ImageBounds),split=window.ResultCanvas.Divider,
            labels=new[]{window.NeutralLabel,window.FilmLabel}.Select(label=>new {label.Name,visible=label.IsVisible,bounds=RectValue(label.TransformToAncestor(window.PhotoArea).TransformBounds(new Rect(label.RenderSize)))}),
            before=window.ResultCanvas.ShowingBefore,mode=Get<EditorViewState>(window,"view").PreferredMode.ToString()};
        File.WriteAllText(Path.Combine(output,name+".bounds.json"),JsonSerializer.Serialize(state));PhotoFeatureChecks.Screenshot(window,Path.Combine(output,name+".png"));
    }
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x,int y);
    [DllImport("user32.dll")] private static extern void mouse_event(uint flags,uint dx,uint dy,uint data,UIntPtr extra);
    [DllImport("user32.dll")] private static extern void keybd_event(byte key,byte scan,uint flags,UIntPtr extra);
    private static void Pump(int milliseconds){var time=Stopwatch.StartNew();InteractionChecks.PumpUntil(()=>time.ElapsedMilliseconds>=milliseconds);}
    private static void PointerChecks(MainWindow window,string output,Action<bool,string> check)
    {
        var view=Get<EditorViewState>(window,"view");window.Activate();window.ResultCanvas.Focus();var bounds=window.ResultCanvas.VisibleImageBounds;
        var center=window.ResultCanvas.PointToScreen(new(bounds.X+bounds.Width/2,bounds.Y+bounds.Height/2));
        if(!SetCursorPos((int)center.X,(int)center.Y))throw new InvalidOperationException("S3 native pointer could not reach the input desktop");
        try {
        mouse_event(2,0,0,0,UIntPtr.Zero);Pump((int)SystemParameters.MouseHoverTime.TotalMilliseconds+100);Capture(window,output,"native-hold");
        check(view.HoldingBefore && window.ResultCanvas.ShowingBefore,"Native mouse press reaches real before after the system hold threshold");
        mouse_event(4,0,0,0,UIntPtr.Zero);Pump(40);check(!view.HoldingBefore,"Native mouse release restores after");
        keybd_event(0xdc,0,0,UIntPtr.Zero);Pump(40);check(view.HoldingBefore,"Native backslash down temporarily shows before");keybd_event(0xdc,0,2,UIntPtr.Zero);Pump(40);check(!view.HoldingBefore,"Native backslash key-up restores after");
        mouse_event(2,0,0,0,UIntPtr.Zero);Pump((int)SystemParameters.MouseHoverTime.TotalMilliseconds+100);check(view.HoldingBefore,"Native before is active before panning");SetCursorPos((int)center.X+40,(int)center.Y+20);Pump(40);Capture(window,output,"native-pan-cancel");
        check(!view.HoldingBefore,"Native pan cancels temporary before before moving the shared photo viewport");mouse_event(4,0,0,0,UIntPtr.Zero);Pump(40);
        window.ValueText.Focus();var info=Get<PhotoInfoMode>(window,"photoInfoMode");keybd_event(0xdc,0,0,UIntPtr.Zero);Pump(40);check(!view.HoldingBefore,"Native backslash down inside numeric text remains text input before key-up");keybd_event(0xdc,0,2,UIntPtr.Zero);keybd_event(0x49,0,0,UIntPtr.Zero);keybd_event(0x49,0,2,UIntPtr.Zero);Pump(40);
        check(!view.HoldingBefore && Get<PhotoInfoMode>(window,"photoInfoMode")==info,"Native backslash and I inside a text box remain text input rather than viewing commands");window.OrdinaryParameter.CancelInput();window.ResultCanvas.Focus();
        keybd_event(0xdc,0,0,UIntPtr.Zero);Pump(40);check(view.HoldingBefore,"Native before is active before moving focus");window.AutoExposureButton.Focus();Pump(40);check(!view.HoldingBefore,"Moving real keyboard focus away from the photo cancels before even before key-up");keybd_event(0xdc,0,2,UIntPtr.Zero);
        foreach(var menu in new[]{(ContextMenu)window.ZoomPhotoMargin.Parent,window.ExportButton.ContextMenu!,window.FileTreeContextMenu}) {
            window.ResultCanvas.Focus();keybd_event(0xdc,0,0,UIntPtr.Zero);Pump(40);check(view.HoldingBefore,"Native before is active before opening a context menu");
            menu.PlacementTarget=ReferenceEquals(menu,window.FileTreeContextMenu) ? window.Files : window.ResultCanvas;menu.IsOpen=true;Pump(60);
            Capture(window,output,"native-menu-"+(ReferenceEquals(menu,window.FileTreeContextMenu) ? "tree" : ReferenceEquals(menu,window.ExportButton.ContextMenu) ? "export" : "zoom"));
            check(!view.HoldingBefore,"The real context menu Opened event cancels an active before hold");keybd_event(0xdc,0,2,UIntPtr.Zero);
            var mode=Get<PhotoInfoMode>(window,"photoInfoMode");keybd_event(0xdc,0,0,UIntPtr.Zero);Pump(40);check(!view.HoldingBefore,"Native backslash down stays excluded inside the open menu before key-up");keybd_event(0xdc,0,2,UIntPtr.Zero);keybd_event(0x49,0,0,UIntPtr.Zero);keybd_event(0x49,0,2,UIntPtr.Zero);Pump(60);
            check(menu.IsOpen && !view.HoldingBefore && Get<PhotoInfoMode>(window,"photoInfoMode")==mode,"Native backslash and I remain excluded while a zoom/export/tree menu is active");menu.IsOpen=false;Pump(40);
        }
        window.ResultCanvas.Focus();SetCursorPos((int)center.X,(int)center.Y);mouse_event(2,0,0,0,UIntPtr.Zero);Pump((int)SystemParameters.MouseHoverTime.TotalMilliseconds+100);check(view.HoldingBefore,"Native before is active before losing mouse capture");Mouse.Capture(null);Pump(40);
        check(!view.HoldingBefore,"Losing actual photo mouse capture cancels before");mouse_event(4,0,0,0,UIntPtr.Zero);
        window.ResultCanvas.Focus();keybd_event(0xdc,0,0,UIntPtr.Zero);Pump(40);check(view.HoldingBefore,"Native before is active before wheel zoom");mouse_event(0x800,0,0,120,UIntPtr.Zero);Pump(40);
        check(!view.HoldingBefore,"Native mouse wheel zoom cancels keyboard-held before before key-up");keybd_event(0xdc,0,2,UIntPtr.Zero);Ready(window);
        window.ResultCanvas.Focus();keybd_event(0xdc,0,0,UIntPtr.Zero);Pump(40);check(view.HoldingBefore,"Native before is active before opening an owned window");var dialog=new Window{Owner=window,Width=240,Height=140,Content=new TextBox()};dialog.Show();Pump(60);Capture(window,output,"native-owned-window-cancel");
        check(!view.HoldingBefore,"Opening another owned window cancels before on real deactivation");keybd_event(0xdc,0,2,UIntPtr.Zero);dialog.Close();window.Activate();window.ResultCanvas.Focus();
        keybd_event(0xdc,0,0,UIntPtr.Zero);Pump(40);check(view.HoldingBefore,"Native before is active before minimizing");window.WindowState=WindowState.Minimized;Pump(60);check(!view.HoldingBefore,"Minimizing the real window cancels before");keybd_event(0xdc,0,2,UIntPtr.Zero);window.WindowState=WindowState.Normal;window.Activate();Ready(window);
        window.ResultCanvas.Focus();keybd_event(0xdc,0,0,UIntPtr.Zero);Pump(40);check(view.HoldingBefore,"Native before is active before reopening the source");window.OpenFile(Get<string>(window,"file"));Ready(window);Capture(window,output,"native-source-cancel");
        check(!view.HoldingBefore && !view.Enabled,"Reopening even the same photo cancels native held-before state before key-up");keybd_event(0xdc,0,2,UIntPtr.Zero);
        } finally {keybd_event(0xdc,0,2,UIntPtr.Zero);mouse_event(4,0,0,0,UIntPtr.Zero);Mouse.Capture(null);}
    }
}
