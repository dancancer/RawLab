using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;

internal static class InteractionChecks
{
    internal static void PumpUntil(Func<bool> done)
    {
        var clock=Stopwatch.StartNew();
        while(!done())
        {
            if(clock.Elapsed>TimeSpan.FromMinutes(2))throw new TimeoutException("Interaction did not complete");
            var frame=new DispatcherFrame();
            var timer=new DispatcherTimer(DispatcherPriority.Background){Interval=TimeSpan.FromMilliseconds(5)};
            timer.Tick+=(_,_)=>{timer.Stop();frame.Continue=false;};timer.Start();Dispatcher.PushFrame(frame);
        }
    }
    internal static void Run(string repo,string raw)
    {
        var app=new Application{ShutdownMode=ShutdownMode.OnExplicitShutdown};
        app.Resources.MergedDictionaries.Add(new ResourceDictionary{Source=new Uri("/RawLab;component/FileTreeStyles.xaml",UriKind.Relative)});
        app.Resources.MergedDictionaries.Add(new ResourceDictionary{Source=new Uri("/RawLab;component/Controls.xaml",UriKind.Relative)});
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        var window=new MainWindow{Width=1440,Height=920};
        window.Show();
        try
        {
            var imageField=typeof(PhotoCanvas).GetField("image",BindingFlags.Instance|BindingFlags.NonPublic)!;
            var timer=Stopwatch.StartNew();window.OpenFile(raw);
            PumpUntil(()=>imageField.GetValue(window.ResultCanvas)!=null);
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
            var placeholder=(BitmapSource)imageField.GetValue(window.ResultCanvas)!;
            timer.Restart();window.OpenFile(raw,placeholder);
            if(!ReferenceEquals(imageField.GetValue(window.ResultCanvas),placeholder) || window.ExportPng.IsEnabled)
                throw new Exception("Selecting a thumbnail must paint immediately without enabling export");
            Console.WriteLine($"thumbnail-dispatch-ms={timer.Elapsed.TotalMilliseconds:F2}");
            PumpUntil(()=>window.ExportPng.IsEnabled);
            var output=Path.Combine(repo,"build","interaction-verification");Directory.CreateDirectory(output);
            var shot=new RenderTargetBitmap(1440,920,96,96,PixelFormats.Pbgra32);shot.Render(window);
            var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(shot));
            using(var stream=File.Create(Path.Combine(output,"zoom.png")))encoder.Save(stream);
        }
        finally {window.Close();app.Shutdown();}
    }
}
