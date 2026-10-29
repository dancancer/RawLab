using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;

internal static class HDRWorkflowChecks
{
    private const BindingFlags Private=BindingFlags.Instance|BindingFlags.NonPublic;
    private static T Get<T>(object owner,string field)=>(T)owner.GetType().GetField(field,Private)!.GetValue(owner)!;
    private static void Invoke(object owner,string method)=>owner.GetType().GetMethod(method,Private)!.Invoke(owner,null);
    private static void Ready(MainWindow window)=>InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
    internal static void Run(string repo,string fixture,Action<bool,string> check)
    {
        var root=Path.Combine(Path.GetFullPath(repo),"build","hdr-workflow",Guid.NewGuid().ToString("N"));Directory.CreateDirectory(root);
        var source=Path.Combine(root,"phone"+Path.GetExtension(fixture));File.Copy(fixture,source);
        var hash=System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(source));
        var app=TestWindowState.CreateApplication();SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        Loc.Initialize("en");var window=new MainWindow(Path.Combine(root,"looks"));TestWindowState.Isolate(window,root);
        try {
            window.Show();window.OpenFile(source);Ready(window);
            var settings=Get<Adjustments>(window,"settings");
            check(settings.IsHDREditing,"Fresh HDR phone photo opens with HDR editing enabled");
            check(!window.AutoExposureButton.IsEnabled && !window.MenuAutoExposure.IsEnabled,"HDR editing disables the SDR-only automatic exposure action");
            window.MenuCompareSwipe.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));Ready(window);
            check((bool)window.GetType().GetProperty("ReferenceCurrent",Private)!.GetValue(window)!,
                "HDR comparison publishes a current neutral reference");
            window.MenuCompareOff.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));Ready(window);
            check(window.CapturePresetAdjustments(AdjustmentScope.All).Source.HdrProcessingVersion==1,
                "Fresh import can capture HDR preset before the first edit");
            var scopeEditor=new AdjustmentScopeEditor("hdr-test",true);
            var fields=Get<Dictionary<AdjustmentField,CheckBox>>(scopeEditor,"fields");
            check(fields.ContainsKey(AdjustmentField.HdrTemperature) && fields.ContainsKey(AdjustmentField.HdrTint) &&
                !fields.ContainsKey(AdjustmentField.Temperature) && scopeEditor.SelectedScope.Fields!.SetEquals(AdjustmentFields.HDRCommon),
                "HDR scope offers relative WB and initializes only supported fields");
            var tools=Get<Dictionary<EditorAdjustmentTool,(Button Button,AdjustmentRing Ring)>>(window,"workspaceTools");
            foreach(var (tool,parameter,value) in new[] {
                (EditorAdjustmentTool.Exposure,Parameter.Exposure,.5),
                (EditorAdjustmentTool.Highlights,Parameter.Highlights,-20d),
                (EditorAdjustmentTool.Shadows,Parameter.Shadows,30d),
                (EditorAdjustmentTool.Contrast,Parameter.Contrast,25d),
                (EditorAdjustmentTool.Saturation,Parameter.Saturation,-10d)}) {
                var button=tools[tool].Button;check(button.IsEnabled,"HDR tool is enabled: "+tool);
                button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                window.OrdinaryParameter.Number.Text=value.ToString(System.Globalization.CultureInfo.InvariantCulture);
                check(window.OrdinaryParameter.Commit(),"HDR parameter commits through the visible editor: "+tool);Ready(window);
                check(Get<Adjustments>(window,"settings")[parameter]==value,"HDR record receives the edited value: "+tool);
            }
            tools[EditorAdjustmentTool.WhiteBalance].Button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            foreach(var (field,value) in new[]{("temperature",7300d),("tint",12d)}) {
                var row=Get<ParameterRow>(window.WhiteBalanceEditor,field);
                check(row.IsEnabled,"HDR relative WB row is enabled: "+field);
                row.Number.Text=value.ToString(System.Globalization.CultureInfo.InvariantCulture);
                check(row.Commit(),"HDR relative WB commits: "+field);Ready(window);
            }
            var edited=Get<Adjustments>(window,"settings");
            check(edited.HDR!.Temperature==7300 && edited.HDR.Tint==12,"Both HDR relative WB values reach the active record");
            tools[EditorAdjustmentTool.Exposure].Button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            var rendered=Get<RenderedImage>(window,"result");
            check(rendered.HDR!=null && rendered.HDR.Statistics.Bins.Sum(x=>(long)x)==rendered.Image.PixelWidth*rendered.Image.PixelHeight,
                "HDR histogram counts floating-point luminance pixels");
            window.HDRFalseColorMenu.IsChecked=true;window.HDRFalseColorMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
            InteractionChecks.PumpUntil(()=>Get<Dictionary<HDRFloatImage,BitmapSource>>(window,"hdrFalseColorCache").Count>0);
            Capture(window,Path.Combine(root,"hdr-false-color.png"));
            window.HDRFalseColorMenu.IsChecked=false;window.HDRFalseColorMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
            window.HDREditMenu.IsChecked=false;window.HDREditMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));Ready(window);
            check(!Get<Adjustments>(window,"settings").IsHDREditing && Get<RenderedImage>(window,"result").HDR==null,
                "HDR toggle produces the ordinary SDR editing frame");
            check(window.AutoExposureButton.IsEnabled && window.MenuAutoExposure.IsEnabled,"SDR editing restores automatic exposure controls");
            var lut=Path.Combine(root,"unknown.cube");File.WriteAllText(lut,"LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n");
            var draft=LUTCompatibility.Inspect(lut)!;
            using var previewWorker=new LUTPreviewWorker(lut,source);
            var preview=previewWorker.Render(null);
            check(Math.Max(preview.Width,preview.Height)<=512 && preview.Pixels.Length>0,
                "HDR source in SDR editing provides a bounded LUT wizard baseline");
            var dialog=new LUTCompatibilityDialog(window,lut,draft,source,[]);dialog.Show();
            InteractionChecks.PumpUntil(()=>Get<Dictionary<string,(Button Button,Image Image)>>(dialog,"thumbnails").Values.Any(value=>value.Button.IsEnabled));
            var candidate=Get<Dictionary<string,(Button Button,Image Image)>>(dialog,"thumbnails").Values.First(value=>value.Button.IsEnabled);
            candidate.Button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            check(Get<Button>(dialog,"confirm").IsEnabled,"LUT wizard displays candidates and accepts a compatible SDR configuration");
            dialog.UpdateLayout();
            Capture(dialog,Path.Combine(root,"sdr-lut-wizard.png"));dialog.Close();
            window.HDREditMenu.IsChecked=true;window.HDREditMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));Ready(window);
            check(Get<Adjustments>(window,"settings").IsHDREditing && Get<RenderedImage>(window,"result").HDR!=null,
                "Returning to HDR invalidates the SDR frame cache");
            Capture(window,Path.Combine(root,"hdr-editor.png"));

            CheckCollectionPreflight(root,source,check);
            HDRNative.Probe(source,out var sourceInfo);
            HDRSourceCache.Clear();
            using(var one=HDRSourceCache.Acquire(source,sourceInfo!,false,128))
            using(var two=HDRSourceCache.Acquire(source,sourceInfo!,false,64)) {
                check(ReferenceEquals(one.Owner,two.Owner) && HDRSourceCache.CachedBytes is >0 and <=128UL*1024*1024,
                    "Source cache shares one process budget across leases");
                HDRSourceCache.Clear();one.Dispose();
                check(HDRSourceCache.CachedBytes==0 && two.Owner.Pair.Hdr.Data!=IntPtr.Zero,
                    "Eviction preserves a concurrently active source lease");
            }
            using var engine=new RenderEngine(0);
            var neutral=new Adjustments { HDR=new HDRSettings() };
            var sdr=neutral.Clone();sdr.SetHDRMode(false,true);
            var first=engine.RenderPreview(source,sdr,null,128,false,true,false);
            var next=engine.RenderPreview(source,neutral,null,128,false,true,false);
            check(first.Result.HDR==null && next.Result.HDR!=null && next.Neutral.HDR!=null,"Result and neutral caches include HDR mode");
            var meter=engine.AutoExposure(source,sdr);check(double.IsFinite(meter),"SDR HDR-source auto exposure completes on bounded input");
            neutral.Geometry=new GeometrySettings { QuarterTurns=1,CropWidth=.75 };
            var geometry=engine.RenderPreview(source,neutral,null,128,false,false,false).Result;
            check(geometry.NativeWidth==geometry.HDR!.OutputNativeWidth && geometry.NativeHeight==geometry.HDR.OutputNativeHeight,
                "HDR geometry publishes the actual output dimensions to the viewport");
            foreach(var format in new[]{ExportFormat.HdrJpeg,ExportFormat.Jpeg,ExportFormat.Png,ExportFormat.RenderedDng}) {
                var output=Path.Combine(root,"export-"+format+"."+format.Suffix());
                engine.Render(source,neutral,null,128,output:output,longEdge:128,formatOverride:format);
                check(new FileInfo(output).Length>100,"Final output exists: "+format);
                if(format==ExportFormat.HdrJpeg)check(HDRNative.Probe(output,out var info)==HDRProbeState.Supported && Math.Max(info!.Width,info.Height)==Math.Min(128,Math.Max(geometry.NativeWidth,geometry.NativeHeight)),
                    "Final resized HDR JPEG retains its gain map and output dimensions");
                if(format==ExportFormat.Png)check(File.ReadAllBytes(output)[24]==16,"Explicit SDR PNG retains 16-bit channel depth");
            }
            var created=File.GetCreationTimeUtc(source);var modified=File.GetLastWriteTimeUtc(source);
            var originalBytes=File.ReadAllBytes(source);var invalidBytes=originalBytes.ToArray();invalidBytes[0]^=0xff;
            try {
                File.WriteAllBytes(source,invalidBytes);File.SetCreationTimeUtc(source,created);File.SetLastWriteTimeUtc(source,modified);
                var rejected=false;
                try {engine.RenderPreview(source,neutral,null,128,false,false,false);}catch(HDRSourceException){rejected=true;}
                check(rejected,"Fresh source fingerprint prevents a stale cached frame when file stamps are preserved");
            } finally {File.WriteAllBytes(source,originalBytes);File.SetCreationTimeUtc(source,created);File.SetLastWriteTimeUtc(source,modified);}
            check(hash.SequenceEqual(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(source))),"Original phone photo remains unchanged");
            Console.WriteLine("HDR screenshots and outputs: "+root);
        } finally {window.Close();app.Shutdown();}
    }
    private static void CheckCollectionPreflight(string root,string source,Action<bool,string> check)
    {
        var other=Path.Combine(root,"sdr-mode"+Path.GetExtension(source));File.Copy(source,other);
        var store=new EditStore(Path.Combine(root,"preflight-edits"));store.Save(other,new Adjustments().Capture(),null);
        var selection=new BatchSelectionSession();selection.Add([source,other]);
        var journal=new BatchJournal(Path.Combine(root,"preflight-journal"));
        var exporter=new BatchSelectionExport(store,journal,_=>null);
        var review=exporter.Prepare(selection,[],ExportFormat.HdrJpeg,128,root,_=>null);
        check(!review.Ready && review.Rows.Count==2 && review.Rows.Count(row=>row.Error!=null)==1,
            "Mixed HDR/SDR-mode collection rejects HDR JPEG during preflight");
        var rejected=false;try {exporter.Freeze(selection,review,_=>null);}catch(InvalidOperationException){rejected=true;}
        check(rejected && journal.Load()==null,"Rejected collection does not freeze or partially publish outputs");
    }
    private static void Capture(Window window,string path)
    {
        window.UpdateLayout();
        var bitmap=new RenderTargetBitmap((int)Math.Ceiling(window.ActualWidth),(int)Math.Ceiling(window.ActualHeight),96,96,PixelFormats.Pbgra32);
        bitmap.Render(window);var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var file=File.Create(path);encoder.Save(file);
    }
}
