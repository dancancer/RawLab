using System.Diagnostics;
using System.IO;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;

internal static class InteractionChecks
{
    internal static void PumpUntil(Func<bool> done,[CallerArgumentExpression(nameof(done))] string condition="",[CallerMemberName] string caller="")
    {
        var clock=Stopwatch.StartNew();
        while(!done())
        {
            if(clock.Elapsed>TimeSpan.FromMinutes(2))throw new TimeoutException($"{caller} did not complete within 120s: {condition}");
            var frame=new DispatcherFrame();
            var timer=new DispatcherTimer(DispatcherPriority.Background){Interval=TimeSpan.FromMilliseconds(5)};
            timer.Tick+=(_,_)=>{timer.Stop();frame.Continue=false;};timer.Start();Dispatcher.PushFrame(frame);
        }
    }
    internal static void Run(string repo,string raw)
    {
        var geometry=new Viewport();geometry.SetSourceSize(6000,4000);
        if(geometry.PreviewLongEdge(new Size(600,400),new DpiScale(2,2),default)!=1216 ||
           geometry.PreviewLongEdge(new Size(400,400),new DpiScale(2,2),default)!=832)
            throw new Exception("Viewport resize must use physical display pixels");
        geometry.Magnify(2);
        if(geometry.PreviewLongEdge(new Size(400,400),new DpiScale(2,2),default)!=1600)
            throw new Exception("Zoom must increase viewport resolution");
        geometry.Actual();
        if(geometry.PreviewLongEdge(new Size(400,400),new DpiScale(2,2),default)!=0)
            throw new Exception("Actual pixels must select native processing");
        var app=new Application{ShutdownMode=ShutdownMode.OnExplicitShutdown};
        app.Resources.MergedDictionaries.Add(new ResourceDictionary{Source=new Uri("/RawLab;component/FileTreeStyles.xaml",UriKind.Relative)});
        app.Resources.MergedDictionaries.Add(new ResourceDictionary{Source=new Uri("/RawLab;component/Controls.xaml",UriKind.Relative)});
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        var window=TestWindowState.CreateIsolatedWindow(Path.Combine(repo,"build","windows-interactions"),width:1440,height:920);
        window.Show();
        try
        {
            window.PreviewLongEdge=0;
            if(window.RenderEdgeForTests(true) != 2000 || window.RenderEdgeForTests(false) != 0)
                throw new Exception("Native-pixel dragging must stay bounded and release must restore native");
            window.PreviewLongEdge=1216;
            if(window.RenderEdgeForTests(true) != 1216)
                throw new Exception("Fit dragging must retain the viewport edge");
            window.PreviewLongEdge=2000;
            var timer=Stopwatch.StartNew();window.OpenFile(raw);
            PumpUntil(()=>window.ResultCanvas.ImageSource!=null);
            Console.WriteLine($"first-image-ms={timer.Elapsed.TotalMilliseconds:F1}; status={window.Status.Text}");
            PumpUntil(()=>window.ExportPng.IsEnabled);
            Console.WriteLine($"exact-ready-ms={timer.Elapsed.TotalMilliseconds:F1}");
            var viewport=window.ResultCanvas.Viewport!;
            Console.WriteLine($"remote-session={SystemParameters.IsRemoteSession}; source-size={viewport.SourceSize}");
            for(var i=0;i<3;i++)
            {
                timer.Restart();viewport.Actual();
                Console.WriteLine($"zoom-dispatch-ms={timer.Elapsed.TotalMilliseconds:F3}");
                if(viewport.SourceSize.Width>0 && Math.Abs(window.ResultCanvas.ImageBounds.Width-viewport.SourceSize.Width/VisualTreeHelper.GetDpi(window.ResultCanvas).DpiScaleX)>.01)
                    throw new Exception("Zoom did not immediately use native pixel geometry");
                PumpUntil(()=>window.ExportPng.IsEnabled);
                Console.WriteLine($"zoom-detail-{i}-ms={timer.Elapsed.TotalMilliseconds:F1}");
                if(i<2){viewport.Fit();PumpUntil(()=>window.ExportPng.IsEnabled);}
            }
            var intervals=new List<double>();double previous=0;var frames=0;
            var frameClock=Stopwatch.StartNew();
            EventHandler pan=(_,_)=>
            {
                var now=frameClock.Elapsed.TotalMilliseconds;
                if(frames>10)intervals.Add(now-previous);
                previous=now;viewport.Move(new Vector(frames%60<30 ? 3 : -3,0));frames++;
            };
            CompositionTarget.Rendering+=pan;
            try{PumpUntil(()=>frames>=130);}finally{CompositionTarget.Rendering-=pan;}
            intervals.Sort();
            Console.WriteLine($"composition-pan-mean-ms={intervals.Average():F2}; p95-ms={intervals[(int)(intervals.Count*.95)]:F2}; tier={RenderCapability.Tier>>16}");
            var target=new RenderTargetBitmap(700,500,96,96,PixelFormats.Pbgra32);
            var allocated=GC.GetAllocatedBytesForCurrentThread();timer.Restart();
            for(var i=0;i<60;i++){viewport.Move(new Vector(i%2==0 ? 2 : -2,0));window.ResultCanvas.UpdateLayout();target.Clear();target.Render(window.ResultCanvas);}
            Console.WriteLine($"offscreen-pan-mean-ms={timer.Elapsed.TotalMilliseconds/60:F2}; managed-bytes={GC.GetAllocatedBytesForCurrentThread()-allocated}");
            viewport.Fit();PumpUntil(()=>window.ExportPng.IsEnabled);
            var placeholder=window.ResultCanvas.ImageSource!;
            timer.Restart();window.OpenFile(raw,placeholder);
            if(!ReferenceEquals(window.ResultCanvas.ImageSource,placeholder) || window.ExportPng.IsEnabled)
                throw new Exception("Selecting a thumbnail must paint immediately without enabling export");
            Console.WriteLine($"thumbnail-dispatch-ms={timer.Elapsed.TotalMilliseconds:F2}");
            var output=Path.Combine(repo,"build","interaction-verification");Directory.CreateDirectory(output);
            var inputs=Path.Combine(output,Guid.NewGuid().ToString("N"));Directory.CreateDirectory(inputs);
            var other=Path.Combine(inputs,"other"+Path.GetExtension(raw));File.Copy(raw,other);
            var otherPlaceholder=BitmapSource.Create(2,1,96,96,PixelFormats.Rgb24,null,new byte[]{255,0,0,0,255,0},6);otherPlaceholder.Freeze();
            window.OpenFile(other,otherPlaceholder);
            if(window.ResultCanvas.ImageSource==null || window.NeutralCanvas.ImageSource==null ||
               ReferenceEquals(window.ResultCanvas.ImageSource,placeholder) ||
               ReferenceEquals(window.NeutralCanvas.ImageSource,placeholder) || window.ExportPng.IsEnabled)
                throw new Exception("Switching photos must replace both placeholder canvases without enabling export");
            var previousPlaceholder=window.ResultCanvas.ImageSource;var previousNeutral=window.NeutralCanvas.ImageSource;
            window.OpenFile(raw);
            // 当前照片的内嵌预览可能已就绪；只排除上一张照片的占位图。
            if(ReferenceEquals(window.ResultCanvas.ImageSource,previousPlaceholder) ||
               ReferenceEquals(window.NeutralCanvas.ImageSource,previousNeutral) || window.ExportPng.IsEnabled)
                throw new Exception("Opening without a thumbnail must not retain the previous photo's placeholder");
            PumpUntil(()=>window.ExportPng.IsEnabled);
            if(window.ResultCanvas.ImageSource==null || ReferenceEquals(window.ResultCanvas.ImageSource,otherPlaceholder))
                throw new Exception("An exact result must replace the opening placeholder");
            var invalid=Path.Combine(inputs,"invalid.png");File.WriteAllText(invalid,"invalid image");
            window.OpenFile(invalid,otherPlaceholder);
            PumpUntil(()=>window.RenderFailed);
            if(window.ResultCanvas.ImageSource!=null || window.NeutralCanvas.ImageSource!=null || window.ExportPng.IsEnabled)
                throw new Exception("A failed initial render must clear its placeholder without enabling export");
            window.OpenFile(raw,otherPlaceholder);PumpUntil(()=>window.ExportPng.IsEnabled);
            if(ReferenceEquals(window.ResultCanvas.ImageSource,otherPlaceholder))
                throw new Exception("A recovered exact result must replace the opening placeholder");
            PumpUntil(()=>{try{Directory.Delete(inputs,true);return true;}catch(IOException){return false;}});
            Console.WriteLine("PASS thumbnail placeholder lifecycle");
            var shot=new RenderTargetBitmap(1440,920,96,96,PixelFormats.Pbgra32);shot.Render(window);
            var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(shot));
            using(var stream=File.Create(Path.Combine(output,"zoom.png")))encoder.Save(stream);
        }
        finally {window.Close();app.Shutdown();}
    }
}
