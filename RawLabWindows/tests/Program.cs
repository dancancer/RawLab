using System.Diagnostics;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;

static class Program
{
    private static int checks;
    private static void Check(bool success,string name) { Console.WriteLine((success ? "PASS " : "FAIL ")+name);checks++;if(!success)throw new Exception(name); }
    private static byte[] Pixels(BitmapSource image)
    {
        var bytes=new byte[image.PixelWidth*image.PixelHeight*4];
        new FormatConvertedBitmap(image,PixelFormats.Bgra32,null,0).CopyPixels(bytes,image.PixelWidth*4,0);return bytes;
    }
    private static void PumpUntil(Func<bool> condition,TimeSpan timeout)
    {
        var watch=Stopwatch.StartNew();
        while(!condition())
        {
            if(watch.Elapsed>timeout)throw new TimeoutException("WPF render timed out");
            var frame=new DispatcherFrame();
            var timer=new DispatcherTimer(DispatcherPriority.Background){Interval=TimeSpan.FromMilliseconds(30)};
            timer.Tick+=(_,_)=>{timer.Stop();frame.Continue=false;};timer.Start();Dispatcher.PushFrame(frame);
        }
    }
    [STAThread]
    private static int Main(string[] args)=>Run(args,BatchJournal.DefaultDirectory);
    internal static int Run(string[] args,string journalDirectory)
    {
        try
        {
            if(args.Length==1 && args[0]=="--white-balance") { WhiteBalanceChecks.Run(Check);Console.WriteLine($"PASS {checks} white balance checks");return 0; }
            if(args.Length==3 && args[0]=="--histogram") { ViewComparisonChecks.NeutralChecks(args[1],args[2],Check);Console.WriteLine($"PASS {checks} histogram checks");return 0; }
            if(args.Length==3 && args[0]=="--atmosphere-ui") { AtmosphereUiChecks.Run(args[1],args[2],Check);Console.WriteLine($"PASS {checks} atmosphere UI checks");return 0; }
            if(args.Length==3 && args[0]=="--update-ui") { SoftwareUpdateUiChecks.Run(args[1],args[2],Check);Console.WriteLine($"PASS {checks} update UI checks");return 0; }
            if(args.Length==4 && args[0]=="--atmosphere-render") { AtmosphereRenderChecks.Run(args[1],args[2],args[3],Check);Console.WriteLine($"PASS {checks} atmosphere render checks");return 0; }
            if(args.Length==4 && args[0]=="--tone-render") { ToneControlsRenderChecks.Run(args[1],args[2],args[3],Check);Console.WriteLine($"PASS {checks} tone render checks");return 0; }
            if(args.Length==4 && args[0]=="--grading-render") { ColorGradingRenderChecks.Run(args[1],args[2],args[3],Check);Console.WriteLine($"PASS {checks} grading render checks");return 0; }
            if(args.Length==4 && args[0]=="--curve-render") { ToneCurveRenderChecks.Run(args[1],args[2],args[3],Check);Console.WriteLine($"PASS {checks} curve render checks");return 0; }
            if(args.Length==3 && args[0]=="--curve-ui") { ToneCurveUiChecks.Run(args[1],args[2],Check);Console.WriteLine($"PASS {checks} curve UI checks");return 0; }
            if(args.Length==3 && args[0]=="--hsl-target-render") { HslTargetRenderChecks.Run(args[1],args[2],Check);Console.WriteLine($"PASS {checks} HSL target render checks");return 0; }
            if(args.Length==3 && args[0]=="--hsl-target") { HslTargetUiChecks.Run(args[1],args[2],Check);Console.WriteLine($"PASS {checks} HSL target UI checks");return 0; }
            TestWindowState.PreserveExistingBatch(journalDirectory);
            Loc.Initialize("zh-Hans");
            if(args.Length==3 && args[0]=="--hdr-workflow") {HDRWorkflowChecks.Run(args[1],args[2],Check);Console.WriteLine($"PASS {checks} HDR workflow checks");return 0;}
            if(args.Length==4 && args[0]=="--ai-batch") { AIBatchWindowChecks.Run(args[1],args[2],args[3],Check);Console.WriteLine($"PASS {checks} AI batch checks");return 0; }
            if(args.Length==5 && args[0]=="--ai-real-window") { AIDenoiseRealWindowChecks.Run(args[1],args[2],args[3],args[4],Check);Console.WriteLine($"PASS {checks} real AI window checks");return 0; }
            if(args.Length==4 && args[0]=="--ai-capability") { AICapabilityWindowChecks.Run(args[1],args[2],args[3]=="hardware",Check);Console.WriteLine($"PASS {checks} AI capability checks");return 0; }
            if(args.Length==3 && args[0]=="--ai-window") { AIDenoiseWindowChecks.Run(args[1],args[2],Check);Console.WriteLine($"PASS {checks} AI window checks");return 0; }
            if(args.Length==2 && args[0]=="--ai-panel") { AIDenoisePanelChecks.Run(args[1],Check);Console.WriteLine($"PASS {checks} AI panel checks");return 0; }
            if(args.Length is 4 or 5 && args[0]=="--ai-denoise") { AIDenoiseChecks.Run(args[1],args[2],args[3],Check,args.Length==5 ? args[4] : "DirectML");Console.WriteLine($"PASS {checks} AI denoise checks");return 0; }
            if(args.Length>=1 && args[0]=="--first-preview") { FirstPreviewChecks.Run(args.Skip(1),Check);Console.WriteLine($"PASS {checks} first preview checks");return 0; }
            if(args.Length==3 && args[0]=="--view-compare") { ViewComparisonChecks.Run(args[1],args[2],Check);return 0; }
            if(args.Length==3 && args[0]=="--view-pointer") { ViewComparisonChecks.Run(args[1],args[2],Check,pointerOnly:true);return 0; }
            if(args.Length==3 && args[0]=="--view-labels") { ViewComparisonChecks.Run(args[1],args[2],Check,labelsOnly:true);return 0; }
            if(args.Length==2 && args[0]=="--view-source-identity") { ViewComparisonChecks.SourceIdentityChecks(args[1],Check);return 0; }
            if(args.Length==3 && args[0]=="--comparison-default") { ComparisonDefaultChecks.Run(args[1],args[2],Check);Console.WriteLine($"PASS {checks} comparison default checks");return 0; }
            if(args.Length==3 && args[0]=="--comparison-ui-host")return ComparisonDefaultChecks.Host(args[1],args[2]);
            if(args.Length==4 && args[0]=="--raster") { RasterChecks.Run(args[1],args[2],args[3],Check);Console.WriteLine($"PASS {checks} raster checks");return 0; }
            if(args.Length==4 && args[0]=="--agent-recipe") { AgentRecipeChecks.Run(args[1],args[2],args[3],Check);Console.WriteLine($"PASS {checks} Agent recipe checks");return 0; }
            if(args.Length==3 && args[0]=="--entry-selection") { EntrySelectionChecks.Run(args[1],args[2],Check);Console.WriteLine($"PASS {checks} entry selection checks");return 0; }
            if(args.Length==3 && args[0]=="--resources") { ResourceChecks.Run(args[1],args[2],Check);Console.WriteLine($"PASS {checks} resource checks");return 0; }
            if(args.Length==2 && args[0]=="--default-isolation") { DefaultIsolationChecks.Run(args[1],Check);Console.WriteLine($"PASS {checks} default isolation checks");return 0; }
            if(args.Length==2 && args[0]=="--profile-isolation") { ProfileIsolationChecks.Run(args[1],Check);Console.WriteLine($"PASS {checks} profile isolation checks");return 0; }
            if(args.Length==2 && args[0]=="--status-layout") { StatusLayoutChecks.Run(args[1],Check);Console.WriteLine($"PASS {checks} status layout checks");return 0; }
            if(args.Length==2 && args[0]=="--appearance") { AppearanceChecks.Run(args[1],Check);Console.WriteLine($"PASS {checks} appearance checks");return 0; }
            if(args.Length is 3 or 4 && args[0]=="--editor-review") { EditorReviewChecks.Run(args[1],args[2],Check,args.Length==4 ? args[3] : "all");return 0; }
            if(args.Length==2 && args[0]=="--editor-shell") { EditorShellChecks.Run(args[1],Check);return 0; }
            if(args.Length==2 && args[0]=="--ui-details") { UiDetailChecks.Run(args[1],Check);Console.WriteLine($"PASS {checks} UI detail checks");return 0; }
            if(args.Length==3 && args[0]=="--transform-ui") { TransformUiChecks.Run(args[1],args[2],Check);return 0; }
            if(args.Length==3 && args[0]=="--adjustment-presets") { AdjustmentPresetUiChecks.Run(args[1],args[2],Check);Console.WriteLine($"PASS {checks} adjustment preset checks");return 0; }
            if(args.Length==3 && args[0]=="--batch-selection") { BatchSelectionUiChecks.Run(args[1],args[2],Check);Console.WriteLine($"PASS {checks} batch selection UI checks");return 0; }
            if(args.Length==3 && args[0]=="--adjustment-history") { AdjustmentHistoryUiChecks.Run(args[1],args[2],Check);Console.WriteLine($"PASS {checks} adjustment history checks");return 0; }
            if(args.Length==1 && args[0]=="--about") { AboutChecks.Run(Check);Console.WriteLine($"PASS {checks} about checks");return 0; }
            if(args.Length==3 && args[0]=="--geometry") { GeometryChecks.Run(args[1],args[2],Check);return 0; }
            if(args.Length==3 && args[0]=="--lens") { LensChecks.Run(args[1],args[2],Check);return 0; }
            if(args.Length==3 && args[0]=="--rendered-dng") { RenderedDngChecks.Run(args[1],args[2]);return 0; }
            if(args.Length==3 && args[0]=="--master-recipes") { MasterRecipeChecks.Run(args[1],args[2]);return 0; }
            if(args.Length==3 && args[0]=="--tool-groups") { ToolGroupChecks.Run(args[1],args[2]);return 0; }
            if(args.Length==3 && args[0]=="--photo-features") { PhotoFeatureChecks.Run(args[1],args[2]);return 0; }
            if(args.Length is 3 or 4 && args[0]=="--denoise") { DenoiseChecks.Run(args[1],args[2],args.Length==4 ? args[3] : null);return 0; }
            if(args.Length==3 && args[0]=="--interactions") { InteractionChecks.Run(args[1],args[2]);return 0; }
            if(args.Length==3 && args[0]=="--benchmark") { PerformanceChecks.Run(args[1],args[2]);return 0; }
            if(args.Length==3 && args[0]=="--benchmark-ui") { PerformanceChecks.Run(args[1],args[2],true);return 0; }
            if(args.Length is not(2 or 3) || args[0].StartsWith("--",StringComparison.Ordinal) ||
                (args.Length==3 && args[2]!="--ui-only"))throw new ArgumentException("Unknown command or invalid arguments. Supply <repo> <raw> [--ui-only], or a named mode with its required arguments.");
            return RunDefault(args,journalDirectory);
        }
        catch(Exception ex){Console.Error.WriteLine(ex);return 1;}
    }
    private static int RunDefault(string[] args,string journalDirectory)
    {
        try
        {
            var repo=Path.GetFullPath(args[0]); var output=Path.Combine(repo,"build","windows-verification");Directory.CreateDirectory(output);
            var settings=new Adjustments();
            FeatureRegressionChecks.Run(Check);
            WhiteBalanceChecks.Run(Check);
            settings.Set(Parameter.Strength,250);
            Check(settings[Parameter.Strength]==200 && settings.Request("test.arw","test.cube",2000,null).LutStrength==2,
                "Film strength clamps at 200% and reaches the native renderer");
            var strengthSpec=ParameterSpec.All[(int)Parameter.Strength];
            Check(strengthSpec.Parse("150")==150 && strengthSpec.Parse("201")==null && strengthSpec.Value(.5)==100,
                "Film slider supports 0-200% and numeric input rejects out-of-range text");
            settings.Reset(Parameter.Strength); Check(settings[Parameter.Strength]==100,"Film strength resets to 100%");
            ExportMetadataChecks.Run(output,Check);
            var wb=(Temperature:4870.0,Tint:17.0);settings.ResolveWhiteBalance(wb);
            settings.Set(Parameter.Temperature,8000);settings.Set(Parameter.Highlights,30);settings.Set(Parameter.Contrast,-20);
            var mapped=settings.Request("test.arw","test.cube",2000,null);
            Check(mapped.WbMode==3 && mapped.Temperature==8000 && Math.Abs(mapped.Highlights+.3)<1e-6 && Math.Abs(mapped.Contrast-.8)<1e-6,"Mac adjustment mapping including highlight sign");
            var clone=settings.Clone();settings.ResetAll();Check(settings.CameraWhiteBalance && settings[Parameter.Temperature]==4870 && settings[Parameter.Tint]==17 && clone[Parameter.Temperature]==8000,"As-shot reset and independent photo snapshots");
            foreach(var spec in ParameterSpec.All)
            {
                Check(spec.Parse("NaN")==null && spec.Parse("Infinity")==null,"Reject nonfinite "+spec.Title);
                foreach(var value in new[]{spec.Min,spec.Max})Check(Math.Abs(spec.Value(spec.Position(value))-value)<.01,"Slider endpoint "+spec.Title);
            }
            var queue=new LatestWork<string>();queue.Submit("first");var first=queue.Start()!;for(var i=0;i<1000;i++)queue.Submit(i.ToString());
            Check(queue.Start()==null && !queue.Finish(first),"No concurrent work or stale publication");var last=queue.Start()!;
            Check(last.Value=="999" && queue.Finish(last) && !queue.Busy,"Only latest pending request retained");
            Check(LibraryEntry.IsRaw("中文.ARQ") && LibraryEntry.IsRaw("photo.DNG") && !LibraryEntry.IsRaw("photo.jpg"),"Mac RAW extension parity");
            Console.WriteLine($"C ABI request size {Marshal.SizeOf<Native.Request>()}, buffer {Marshal.SizeOf<Native.Buffer>()}");
            ComparisonChecks.Run(Check);
            if(args.Length<2)throw new ArgumentException("Supply repository root and an external RAW fixture path.");
            var raw=Path.GetFullPath(args[1]);
            if(!args.Contains("--ui-only")) LensChecks.Run(repo,raw,Check);
            var film=Path.Combine(repo,"lutools","flog-2-new","FLog2_to_PROVIA_65grid_V.1.00.cube");
            var unicodeDir=Path.Combine(output,"中文目录");Directory.CreateDirectory(unicodeDir);
            var unicodeRaw=Path.Combine(unicodeDir,"照片.ARW");var unicodeLut=Path.Combine(unicodeDir,"胶片.cube");File.Copy(raw,unicodeRaw,true);File.Copy(film,unicodeLut,true);
            var originalHash=SHA256.HashData(File.ReadAllBytes(unicodeRaw));
            if(!args.Contains("--ui-only"))using(var engine=new RenderEngine())
            {
                var thumb=RenderEngine.Thumbnail(unicodeRaw);Check(thumb!=null && Math.Max(thumb.PixelWidth,thumb.PixelHeight)<=180,"Embedded thumbnail on Unicode path");
                settings=new();var neutral=engine.Render(unicodeRaw,settings,null,800)!;var rendered=engine.Render(unicodeRaw,settings,unicodeLut,800)!;
                Check(Math.Max(rendered.Image.PixelWidth,rendered.Image.PixelHeight)==800,"Real ARW and UTF-8 LUT paths");
                Check(rendered.Backend==3,"Actual Direct3D 11 hardware completes RAW rendering");
                Check(!Pixels(neutral.Image).SequenceEqual(Pixels(rendered.Image)),"Film branch changes pixels");
                settings.Set(Parameter.Strength,200);
                var strong=engine.Render(unicodeRaw,settings,unicodeLut,800)!;
                Check(!Pixels(strong.Image).SequenceEqual(Pixels(rendered.Image)),"200% film differs from 100% on Direct3D 11");
                using (var cpuStrength=new RenderEngine(0))
                    Check(Pixels(strong.Image).Zip(Pixels(cpuStrength.Render(unicodeRaw,settings,unicodeLut,800)!.Image),(x,y)=>Math.Abs(x-y)).Max()<=2,
                        "200% film CPU/Direct3D 11 parity");
                settings.Reset(Parameter.Strength);
                Check(float.IsFinite(rendered.Baseline) && rendered.WhiteBalance!=null,"Selected exposure baseline and calibrated as-shot WB");
                Check(Math.Abs(engine.Render(unicodeRaw,new Adjustments { ExposureMode=0 },null,32,statistics:false,clipping:false)!.Baseline-.7)<.001,"Explicit scene mode keeps the declared baseline");
                ViewComparisonChecks.CheckHistogram(rendered,Check,"rendered output");
                var lean=engine.Render(unicodeRaw,settings,unicodeLut,800,clipping:false)!;
                Check(lean.Clipping==null && lean.Histogram.SequenceEqual(rendered.Histogram) && lean.Shadows==rendered.Shadows && lean.Highlights==rendered.Highlights && Pixels(lean.Image).SequenceEqual(Pixels(rendered.Image)),"Optional clipping mask preserves pixels and exact statistics");
                var referenceOnly=engine.Render(unicodeRaw,settings,null,800,statistics:false,clipping:false)!;
                Check(referenceOnly.Histogram.Length==0 && referenceOnly.Clipping==null && Pixels(referenceOnly.Image).SequenceEqual(Pixels(neutral.Image)),"Neutral comparison skips unused statistics without changing pixels");
                // Compare like-for-like viewport stages, not a downscaled final render.
                var viewport=engine.Render(unicodeRaw,settings,unicodeLut,800,viewportPreview:true)!;
                var single=engine.RenderPreview(unicodeRaw,settings,unicodeLut,800,false,false,false);
                Check(ReferenceEquals(single.Neutral,single.Result) && Pixels(single.Result.Image).SequenceEqual(Pixels(viewport.Image)),"Comparison off renders only the edited image without changing viewport pixels");
                var masked=engine.RenderPreview(unicodeRaw,settings,unicodeLut,800,false,true,true);
                Check(masked.Neutral.Clipping==null && masked.Result.Clipping!=null && Pixels(masked.Result.Clipping).SequenceEqual(Pixels(viewport.Clipping!)),"Clipping applies only to the edited result, never the original");
                PreviewChecks.Run(engine,unicodeRaw,unicodeLut,Check);
                settings.ResolveWhiteBalance(rendered.WhiteBalance);
                foreach(var parameter in new[]{Parameter.Exposure,Parameter.Contrast,Parameter.Highlights,Parameter.Shadows,Parameter.ToneCurve,Parameter.Saturation,Parameter.Sharpening})
                {
                    settings.Set(parameter,parameter==Parameter.Exposure ? 1 : 40);
                    var changed=engine.Render(unicodeRaw,settings,unicodeLut,800)!;
                    Check(!Pixels(rendered.Image).SequenceEqual(Pixels(changed.Image)) && changed.Baseline==rendered.Baseline,"Adjustment affects pixels, preserves baseline: "+parameter);
                    settings.Reset(parameter);
                }
                settings.Set(Parameter.Temperature,8000);var proxy=engine.Render(unicodeRaw,settings,unicodeLut,1000,true)!;
                var exact=engine.Render(unicodeRaw,settings,unicodeLut,800)!;
                Check(Math.Max(proxy.Image.PixelWidth,proxy.Image.PixelHeight)==1000 && !Pixels(exact.Image).SequenceEqual(Pixels(rendered.Image)),"Interactive WB followed by exact WB");
                settings.ResetAll();var reset=engine.Render(unicodeRaw,settings,unicodeLut,800)!;
                Check(Pixels(reset.Image).SequenceEqual(Pixels(rendered.Image)),"Reset returns exactly to as-shot rendering");
                settings.ExposureMode=2;Check(engine.Render(unicodeRaw,settings,null,800)!.Baseline==0,"Sensor exposure baseline");
                settings.ExposureMode=1;Check(float.IsFinite(engine.Render(unicodeRaw,settings,null,800)!.Baseline),"Embedded preview exposure mode");settings.ExposureMode=0;
                using(var cpu=new RenderEngine(0))
                {
                    var cpuResult=cpu.Render(unicodeRaw,settings,unicodeLut,2000)!;
                    var gpuResult=engine.Render(unicodeRaw,settings,unicodeLut,2000)!;
                    Check(Pixels(cpuResult.Image).Zip(Pixels(gpuResult.Image),(x,y)=>Math.Abs(x-y)).Max()<=2,"2000px Windows CPU/GPU parity");
                    var timings=new Dictionary<string,double>();
                    foreach(var (name,renderer) in new[]{("CPU",cpu),("Direct3D11",engine)})
                    {
                        var clock=Stopwatch.StartNew();
                        for(var i=0;i<3;i++){settings.Set(Parameter.Exposure,i*.05);renderer.Render(unicodeRaw,settings,unicodeLut,2000);}
                        timings[name]=clock.Elapsed.TotalMilliseconds/3;
                    }
                    settings.ResetAll();
                    File.WriteAllText(Path.Combine(output,"preview-timings.json"),System.Text.Json.JsonSerializer.Serialize(timings));
                    Console.WriteLine($"Warm 2000px preview incl. readback/statistics: CPU {timings["CPU"]:F1} ms, Direct3D11 {timings["Direct3D11"]:F1} ms");
                    var previous=Environment.GetEnvironmentVariable("RAWLAB_DISABLE_D3D11");
                    try
                    {
                        Environment.SetEnvironmentVariable("RAWLAB_DISABLE_D3D11","1");
                        engine.SetGpuMode(1);var fallback=engine.Render(unicodeRaw,settings,unicodeLut,800)!;
                        Check(fallback.Backend==0 && Pixels(fallback.Image).SequenceEqual(Pixels(cpu.Render(unicodeRaw,settings,unicodeLut,800)!.Image)),"Auto falls back to unchanged CPU pixels");
                        engine.SetGpuMode(2);
                        try{engine.Render(unicodeRaw,settings,unicodeLut,800);throw new Exception("Force silently fell back");}catch(InvalidOperationException){checks++;Console.WriteLine("PASS Force reports unavailable hardware");}
                    }
                    finally {Environment.SetEnvironmentVariable("RAWLAB_DISABLE_D3D11",previous);engine.SetGpuMode(1);}
                }
                var png=Path.Combine(unicodeDir,"原尺寸.png");var jpeg=Path.Combine(unicodeDir,"原尺寸.jpg");
                settings.Set(Parameter.Strength,200);
                engine.Render(unicodeRaw,settings,unicodeLut,0,true,png);engine.Render(unicodeRaw,settings,unicodeLut,0,false,jpeg);
                var sourceTags=ExportMetadataChecks.Read(unicodeRaw);
                foreach (var path in new[]{png,jpeg})
                {
                    var tags=ExportMetadataChecks.Read(path);
                    Check(tags.GetProperty("Model").GetString()==sourceTags.GetProperty("Model").GetString() &&
                        tags.GetProperty("DateTimeOriginal").GetString()==sourceTags.GetProperty("DateTimeOriginal").GetString() &&
                        tags.GetProperty("ExposureTime").GetDouble()==sourceTags.GetProperty("ExposureTime").GetDouble(),
                        "Real RAW capture EXIF survives full-resolution export: "+Path.GetExtension(path));
                }
                var pngBytes=File.ReadAllBytes(png);Check(pngBytes[24]==16,"PNG export contains actual 16-bit channels");
                using var pngStream=File.OpenRead(png);var pngFrame=BitmapFrame.Create(pngStream,BitmapCreateOptions.PreservePixelFormat,BitmapCacheOption.OnLoad);
                using var jpegStream=File.OpenRead(jpeg);var jpegFrame=BitmapFrame.Create(jpegStream,BitmapCreateOptions.PreservePixelFormat,BitmapCacheOption.OnLoad);
                var native=engine.Render(unicodeRaw,settings,unicodeLut,0)!;
                Check(pngFrame.PixelWidth==native.Image.PixelWidth && pngFrame.PixelHeight==native.Image.PixelHeight && jpegFrame.PixelWidth==native.Image.PixelWidth && jpegFrame.PixelHeight==native.Image.PixelHeight,"JPEG and PNG retain active RAW resolution");
                Console.WriteLine($"Native dimensions: {native.Image.PixelWidth} x {native.Image.PixelHeight}");
                var a=Pixels(native.Image);var b=Pixels(pngFrame);var delta=a.Zip(b,(x,y)=>Math.Abs(x-y)).Max();
                Check(delta<=1,"100% preview agrees with 16-bit PNG within 8-bit quantization");
                try{engine.Render(unicodeRaw,settings,unicodeLut,0,false,unicodeRaw);throw new Exception("Input overwrite accepted");}catch(InvalidOperationException){checks++;Console.WriteLine("PASS input RAW overwrite rejected");}
                try{engine.Render(Path.Combine(output,"missing.arw"),settings,null,800);throw new Exception("Missing file accepted");}catch(FileNotFoundException){checks++;Console.WriteLine("PASS missing input reported");}
            }
            Check(originalHash.SequenceEqual(SHA256.HashData(File.ReadAllBytes(unicodeRaw))),"RAW source remains byte-identical");
            // Exercise the real WPF window and asynchronous worker using its dispatcher.
            if(args.Length==3 && args[0]=="--hsl-target") { HslTargetUiChecks.Run(args[1],args[2],Check);Console.WriteLine($"PASS {checks} HSL target UI checks");return 0; }
            TestWindowState.PreserveExistingBatch(journalDirectory);
            var app=TestWindowState.CreateApplication();
            SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
            var window=new MainWindow {Width=1440,Height=920};
            TestWindowState.Isolate(window,output);
            typeof(MainWindow).GetField("editStore",System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic)!
                .SetValue(window,new EditStore(Path.Combine(output,"edits",Guid.NewGuid().ToString("N"))));
            window.Show();
            var folder=new LibraryEntry(Path.GetDirectoryName(raw)!,true);
            window.Files.ItemsSource=new[]{folder};
            var loading=folder.Load();PumpUntil(()=>loading.IsCompleted,TimeSpan.FromSeconds(30));loading.GetAwaiter().GetResult();
            Check(folder.Children.Any(p=>!p.IsFolder) && folder.Children.Where(p=>!p.IsFolder).All(p=>LibraryEntry.IsImage(p.Path)),"Lazy file library lists supported RAW and ordinary images");
            window.Measure(new Size(1440,920));window.Arrange(new Rect(0,0,1440,920));window.UpdateLayout();
            var proxyPublished=false;var proxyAllowedExport=false;var openClock=Stopwatch.StartNew();double proxyMs=0;
            var statusText=DependencyPropertyDescriptor.FromProperty(TextBlock.TextProperty,typeof(TextBlock));
            EventHandler previewChanged=(_,_)=>{if(window.Status.Text.StartsWith("交互预览 ")){proxyPublished=true;proxyMs=openClock.Elapsed.TotalMilliseconds;proxyAllowedExport|=window.ExportPng.IsEnabled;}};
            statusText.AddValueChanged(window.Status,previewChanged);
            window.OpenFile(raw,RenderEngine.ReadEmbeddedPreview(raw).Image);
            window.Width=1344;window.Height=1048;
            window.Measure(new Size(1344,1048));window.Arrange(new Rect(0,0,1344,1048));window.UpdateLayout();
            PumpUntil(()=>window.ExportPng.IsEnabled,TimeSpan.FromMinutes(3));
            statusText.RemoveValueChanged(window.Status,previewChanged);
            Check(proxyPublished && !proxyAllowedExport,"Opening publishes a fast RAW proxy before exact work and never exports the proxy");
            Console.WriteLine($"WPF open: first proxy {proxyMs:F1} ms; exact {openClock.Elapsed.TotalMilliseconds:F1} ms");
            var settled=(RenderedImage)typeof(MainWindow).GetField("result",System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic)!
                .GetValue(window)!;
            Console.WriteLine($"WPF settled: bitmap={settled.Image.PixelWidth}x{settled.Image.PixelHeight}, viewport-edge={window.ResultCanvas.PreviewLongEdge}, status={window.Status.Text}");
            Check(window.Status.Text.StartsWith("预览 ") && Math.Max(settled.Image.PixelWidth,settled.Image.PixelHeight)==window.ResultCanvas.PreviewLongEdge,
                "WPF settled render uses the current viewport dimensions and enables export");
            window.ValueSlider.Value=.625;Check(!window.ExportPng.IsEnabled,"Editing immediately blocks stale export");
            window.ValueSlider.Value=.75;window.ValueSlider.Value=.625;
            PumpUntil(()=>window.ExportPng.IsEnabled,TimeSpan.FromMinutes(3));
            window.OpenFile(unicodeRaw);Check(Math.Abs(window.ValueSlider.Value-.5)<.001,"New photo starts with default exposure");
            PumpUntil(()=>window.ExportPng.IsEnabled,TimeSpan.FromMinutes(3));
            var switched=(RenderedImage)typeof(MainWindow).GetField("result",System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic)!
                .GetValue(window)!;
            Check(Math.Max(switched.Image.PixelWidth,switched.Image.PixelHeight)==window.ResultCanvas.PreviewLongEdge,
                "Opening without a supplied embedded image settles at the current viewport resolution");
            window.OpenFile(raw);Check(Math.Abs(window.ValueSlider.Value-.625)<.001,"Photo switch restores its own exposure");
            window.ValueSlider.Value=.5;PumpUntil(()=>window.ExportPng.IsEnabled,TimeSpan.FromMinutes(3));
            Check(window.BackendLabel.Text.Contains("Direct3D 11"),"WPF reports actual GPU backend");
            var filmDividers=window.FilmStrip.Children.OfType<Border>().Select(
                System.Windows.Automation.AutomationProperties.GetAutomationId).ToArray();
            Check(filmDividers.SequenceEqual(new[]{"film.group-divider.Kodak","film.group-divider.Other"}),
                "Film picker has only two flat group boundaries, Fuji then Kodak then Other");
            Check(window.FilmStrip.Children.OfType<Button>().Any(button=>
                System.Windows.Automation.AutomationProperties.GetName(button)=="EKTAR 100 RawLab edition"),
                "Grouped film picker retains the RawLab Ektar display name");
            foreach(var picker in new[] {
                (Category:window.FilmCategory,Strip:window.FilmStrip,Scroller:window.FilmScroller,Left:window.FilmScrollLeft,Right:window.FilmScrollRight),
                (Category:window.MasterRecipeCategory,Strip:window.RecipeStrip,Scroller:window.RecipeScroller,Left:window.RecipeScrollLeft,Right:window.RecipeScrollRight) })
            {
                picker.Category.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                window.Width=1000;window.Measure(new Size(1000,920));window.Arrange(new Rect(0,0,1000,920));window.UpdateLayout();
                picker.Scroller.ScrollToLeftEnd();window.UpdateLayout();
                PumpUntil(()=>picker.Left.Visibility==Visibility.Visible && !picker.Left.IsEnabled && picker.Right.IsEnabled,TimeSpan.FromSeconds(5));
                Console.WriteLine($"Picker {System.Windows.Automation.AutomationProperties.GetName(picker.Category)}: window={window.ActualWidth}, extent={picker.Scroller.ExtentWidth}, viewport={picker.Scroller.ViewportWidth}, offset={picker.Scroller.HorizontalOffset}, left={picker.Left.Visibility}/{picker.Left.IsEnabled}/{picker.Left.ActualWidth}, right={picker.Right.Visibility}/{picker.Right.IsEnabled}/{picker.Right.ActualWidth}");
                Check(picker.Left.Visibility==Visibility.Visible && !picker.Left.IsEnabled && picker.Right.IsEnabled,"Overflow picker has reachable desktop scroll controls");
                picker.Right.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                PumpUntil(()=>picker.Scroller.HorizontalOffset>1,TimeSpan.FromSeconds(5));
                Check(picker.Left.IsEnabled,"Desktop picker button scrolls content and enables return");
                var items=picker.Strip.Children.Cast<UIElement>().ToArray();
                picker.Strip.Children.Clear();picker.Strip.Children.Add(items[0]);window.UpdateLayout();
                PumpUntil(()=>picker.Left.Visibility==Visibility.Collapsed && picker.Right.Visibility==Visibility.Collapsed,TimeSpan.FromSeconds(5));
                Check(picker.Left.Visibility==Visibility.Collapsed && picker.Right.Visibility==Visibility.Collapsed,"Picker hides both buttons when the complete list fits");
                picker.Strip.Children.Clear();foreach(var item in items)picker.Strip.Children.Add(item);window.UpdateLayout();
            }
            window.Width=1440;window.Measure(new Size(1440,920));window.Arrange(new Rect(0,0,1440,920));window.UpdateLayout();
            var strengthButton=window.Tools.Children.OfType<Button>().Single(button=>
                System.Windows.Automation.AutomationProperties.GetName(button)=="强度");
            strengthButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Check(window.ValueText.Text=="100" && Math.Abs(window.ValueSlider.Value-.5)<.001,
                "WPF film strength starts at 100% in the middle of its slider");
            window.ValueSlider.Value=1;
            Check(window.ValueText.Text=="200" && !window.ExportPng.IsEnabled,"WPF film slider reaches 200% and invalidates stale export");
            PumpUntil(()=>window.ExportPng.IsEnabled,TimeSpan.FromMinutes(3));
            // Capture the client area independently of window chrome.
            var content=(FrameworkElement)window.Content;window.Content=null;
            content.Measure(new Size(1440,920));content.Arrange(new Rect(0,0,1440,920));content.UpdateLayout();
            var screenshot=new RenderTargetBitmap(1440,920,96,96,PixelFormats.Pbgra32);screenshot.Render(content);
            Check(Pixels(screenshot).Where((_,i)=>i%4!=3).Count(v=>v>40)>10000,"WPF screenshot contains rendered content");
            var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(screenshot));using(var stream=File.Create(Path.Combine(output,"editor.png")))encoder.Save(stream);
            window.Close();app.Shutdown();
            Console.WriteLine($"PASS {checks} checks; artifacts: {output}");return 0;
        }
        catch(Exception ex){Console.Error.WriteLine(ex);return 1;}
    }
}
