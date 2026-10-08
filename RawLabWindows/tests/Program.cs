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
    private static int Main(string[] args)
    {
        try
        {
            if(args.Length==3 && args[0]=="--interactions") { InteractionChecks.Run(args[1],args[2]);return 0; }
            if(args.Length==3 && args[0]=="--benchmark") { PerformanceChecks.Run(args[1],args[2]);return 0; }
            if(args.Length==3 && args[0]=="--benchmark-ui") { PerformanceChecks.Run(args[1],args[2],true);return 0; }
            var repo=Path.GetFullPath(args[0]); var output=Path.Combine(repo,"build","windows-verification");Directory.CreateDirectory(output);
            var settings=new Adjustments();
            settings.Set(Parameter.Strength,250);
            Check(settings[Parameter.Strength]==200 && settings.Request("test.arw","test.cube",2000,null).LutStrength==2,
                "Film strength clamps at 200% and reaches the native renderer");
            var strengthSpec=ParameterSpec.All[(int)Parameter.Strength];
            Check(strengthSpec.Parse("150")==150 && strengthSpec.Parse("201")==200 && strengthSpec.Value(.5)==100,
                "Film slider and numeric input support 0-200%");
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
            var film=Path.Combine(repo,"lutools","flog-2-new","FLog2_to_PROVIA_65grid_V.1.00.cube");
            var unicodeDir=Path.Combine(output,"中文目录");Directory.CreateDirectory(unicodeDir);
            var unicodeRaw=Path.Combine(unicodeDir,"照片.ARW");var unicodeLut=Path.Combine(unicodeDir,"胶片.cube");File.Copy(raw,unicodeRaw,true);File.Copy(film,unicodeLut,true);
            var originalHash=SHA256.HashData(File.ReadAllBytes(unicodeRaw));
            if(!args.Contains("--ui-only"))using(var engine=new RenderEngine())
            {
                var thumb=RenderEngine.Thumbnail(unicodeRaw);Check(thumb!=null && Math.Max(thumb.PixelWidth,thumb.PixelHeight)<=180,"Embedded thumbnail on Unicode path");
                settings=new();var neutral=engine.Render(unicodeRaw,settings,null,800)!;var rendered=engine.Render(unicodeRaw,settings,unicodeLut,800)!;
                Check(rendered.Image.PixelWidth==800 && rendered.Image.PixelHeight>0,"Real ARW and UTF-8 LUT paths");
                Check(rendered.Backend==3,"Actual Direct3D 11 hardware completes RAW rendering");
                Check(!Pixels(neutral.Image).SequenceEqual(Pixels(rendered.Image)),"Film branch changes pixels");
                settings.Set(Parameter.Strength,200);
                var strong=engine.Render(unicodeRaw,settings,unicodeLut,800)!;
                Check(!Pixels(strong.Image).SequenceEqual(Pixels(rendered.Image)),"200% film differs from 100% on Direct3D 11");
                using (var cpuStrength=new RenderEngine(0))
                    Check(Pixels(strong.Image).Zip(Pixels(cpuStrength.Render(unicodeRaw,settings,unicodeLut,800)!.Image),(x,y)=>Math.Abs(x-y)).Max()<=2,
                        "200% film CPU/Direct3D 11 parity");
                settings.Reset(Parameter.Strength);
                Check(Math.Abs(rendered.Baseline-.7)<.001 && rendered.WhiteBalance!=null,"Scene baseline and calibrated as-shot WB");
                Check(rendered.Histogram.Take(256).Sum(x=>(long)x)==rendered.Image.PixelWidth*rendered.Image.PixelHeight,"Native histogram counts each pixel");
                var lean=engine.Render(unicodeRaw,settings,unicodeLut,800,clipping:false)!;
                Check(lean.Clipping==null && lean.Histogram.SequenceEqual(rendered.Histogram) && lean.Shadows==rendered.Shadows && lean.Highlights==rendered.Highlights && Pixels(lean.Image).SequenceEqual(Pixels(rendered.Image)),"Optional clipping mask preserves pixels and exact statistics");
                var referenceOnly=engine.Render(unicodeRaw,settings,null,800,statistics:false,clipping:false)!;
                Check(referenceOnly.Histogram.Length==0 && referenceOnly.Clipping==null && Pixels(referenceOnly.Image).SequenceEqual(Pixels(neutral.Image)),"Neutral comparison skips unused statistics without changing pixels");
                var single=engine.RenderPreview(unicodeRaw,settings,unicodeLut,800,false,false,false);
                Check(ReferenceEquals(single.Neutral,single.Result) && Pixels(single.Result.Image).SequenceEqual(Pixels(rendered.Image)),"Comparison off renders only the edited image without changing pixels");
                var masked=engine.RenderPreview(unicodeRaw,settings,unicodeLut,800,false,true,true);
                Check(masked.Neutral.Clipping!=null && masked.Result.Clipping!=null && Pixels(masked.Result.Clipping).SequenceEqual(Pixels(rendered.Clipping!)),"Clipping on retains both comparison masks");
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
                Check(proxy.Image.PixelWidth==1000 && !Pixels(exact.Image).SequenceEqual(Pixels(rendered.Image)),"Interactive WB followed by exact WB");
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
                try{engine.Render(Path.Combine(output,"missing.arw"),settings,null,800);throw new Exception("Missing file accepted");}catch(InvalidOperationException){checks++;Console.WriteLine("PASS missing input reported");}
            }
            Check(originalHash.SequenceEqual(SHA256.HashData(File.ReadAllBytes(unicodeRaw))),"RAW source remains byte-identical");
            // Exercise the real WPF window and asynchronous worker using its dispatcher.
            var app=new App();app.InitializeComponent();app.ShutdownMode=ShutdownMode.OnExplicitShutdown;
            SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
            var window=new MainWindow {Width=1440,Height=920};
            var folder=new LibraryEntry(Path.GetDirectoryName(raw)!,true);
            window.Files.ItemsSource=new[]{folder};
            var loading=folder.Load();PumpUntil(()=>loading.IsCompleted,TimeSpan.FromSeconds(30));loading.GetAwaiter().GetResult();
            Check(folder.Children.Any(p=>!p.IsFolder) && folder.Children.Where(p=>!p.IsFolder).All(p=>LibraryEntry.IsRaw(p.Path)),"Lazy file library lists RAW files and filters JPEGs");
            window.Measure(new Size(1440,920));window.Arrange(new Rect(0,0,1440,920));window.UpdateLayout();
            var proxyPublished=false;var proxyAllowedExport=false;var openClock=Stopwatch.StartNew();double proxyMs=0;
            var statusText=DependencyPropertyDescriptor.FromProperty(TextBlock.TextProperty,typeof(TextBlock));
            EventHandler previewChanged=(_,_)=>{if(window.Status.Text.StartsWith("交互预览 ")){proxyPublished=true;proxyMs=openClock.Elapsed.TotalMilliseconds;proxyAllowedExport|=window.ExportPng.IsEnabled;}};
            statusText.AddValueChanged(window.Status,previewChanged);
            window.OpenFile(raw);PumpUntil(()=>window.ExportPng.IsEnabled,TimeSpan.FromMinutes(3));
            statusText.RemoveValueChanged(window.Status,previewChanged);
            Check(proxyPublished && !proxyAllowedExport,"Opening publishes a fast RAW proxy before exact work and never exports the proxy");
            Console.WriteLine($"WPF open: first proxy {proxyMs:F1} ms; exact {openClock.Elapsed.TotalMilliseconds:F1} ms");
            Check(window.Status.Text.Contains("2000"),"WPF exact render completes and enables export");
            window.ValueSlider.Value=.625;Check(!window.ExportPng.IsEnabled,"Editing immediately blocks stale export");
            window.ValueSlider.Value=.75;window.ValueSlider.Value=.625;
            PumpUntil(()=>window.ExportPng.IsEnabled,TimeSpan.FromMinutes(3));
            window.OpenFile(unicodeRaw);Check(Math.Abs(window.ValueSlider.Value-.5)<.001,"New photo starts with default exposure");
            window.OpenFile(raw);Check(Math.Abs(window.ValueSlider.Value-.625)<.001,"Photo switch restores its own exposure");
            window.ValueSlider.Value=.5;PumpUntil(()=>window.ExportPng.IsEnabled,TimeSpan.FromMinutes(3));
            Check(window.BackendLabel.Text.Contains("Direct3D 11"),"WPF reports actual GPU backend");
            var strengthButton=window.Tools.Children.OfType<Button>().Single(button=>
                System.Windows.Automation.AutomationProperties.GetName(button)=="强度");
            strengthButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Check(window.ValueText.Text=="100" && Math.Abs(window.ValueSlider.Value-.5)<.001,
                "WPF film strength starts at 100% in the middle of its slider");
            window.ValueSlider.Value=1;
            Check(window.ValueText.Text=="200" && !window.ExportPng.IsEnabled,"WPF film slider reaches 200% and invalidates stale export");
            PumpUntil(()=>window.ExportPng.IsEnabled,TimeSpan.FromMinutes(3));
            // Render the content independently of a hidden HWND; rendering the
            // unshown Window itself produces a transparent bitmap on Windows.
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
