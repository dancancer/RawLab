using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text.Json;
using System.Windows;
using System.Windows.Threading;
using RawLab.Windows;

internal static class ResourceChecks
{
    private const BindingFlags Private=BindingFlags.Instance|BindingFlags.NonPublic;
    internal static void Run(string repo,string raw,Action<bool,string> check)
    {
        var output=Path.Combine(repo,"build","windows-resource-checks",DateTime.UtcNow.ToString("yyyyMMdd-HHmmss")+"-"+Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(output);var hash=SHA256.HashData(File.ReadAllBytes(raw));
        var app=TestWindowState.CreateApplication();
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        using var process=Process.GetCurrentProcess();var clock=Stopwatch.StartNew();
        var samples=new List<object>();var rounds=new List<object>();MainWindow? active=null;
        long peakPrivate=0,peakWorking=0,peakCache=0;bool observedCache=false;string? error=null;
        var timer=new DispatcherTimer{Interval=TimeSpan.FromMilliseconds(100)};
        void Sample(string stage,MainWindow? window=null)
        {
            process.Refresh();long cache=-1;
            var owner=window ?? active;
            if(owner!=null)
            {
                var scheduler=typeof(MainWindow).GetField("scheduler",Private)!.GetValue(owner)!;
                if(!(bool)scheduler.GetType().GetProperty("Busy")!.GetValue(scheduler)!)
                    cache=((RenderEngine?)typeof(MainWindow).GetField("engine",Private)!.GetValue(owner))?.CachedPreviewBytes ?? 0;
            }
            peakPrivate=Math.Max(peakPrivate,process.PrivateMemorySize64);peakWorking=Math.Max(peakWorking,process.WorkingSet64);peakCache=Math.Max(peakCache,cache);
            observedCache|=cache>=0;
            samples.Add(new{stage,ms=clock.Elapsed.TotalMilliseconds,privateBytes=process.PrivateMemorySize64,workingSet=process.WorkingSet64,
                gcBytes=GC.GetTotalMemory(false),cpuMs=process.TotalProcessorTime.TotalMilliseconds,cachedPreviewBytes=cache});
        }
        timer.Tick+=(_,_)=>Sample("sample");timer.Start();
        try
        {
            for(var round=-1;round<3;round++)
            {
                var start=clock.Elapsed.TotalMilliseconds;var cpu=process.TotalProcessorTime;var allocated=GC.GetTotalAllocatedBytes();
                var weak=Cycle(app,raw,Path.Combine(output,"round-"+round),round,window=>active=window,Sample,check);
                active=null;
                var drain=Stopwatch.StartNew();InteractionChecks.PumpUntil(()=>drain.ElapsedMilliseconds>=3500);
                GC.Collect(2,GCCollectionMode.Forced,true,true);GC.WaitForPendingFinalizers();GC.Collect(2,GCCollectionMode.Forced,true,true);
                Sample("collected-"+round);
                var collectible=!weak.IsAlive;
                if(!collectible)DescribeRetention(weak,app);
                rounds.Add(new{round,warmup=round<0,elapsedMs=clock.Elapsed.TotalMilliseconds-start,cpuMs=(process.TotalProcessorTime-cpu).TotalMilliseconds,
                    managedAllocated=GC.GetTotalAllocatedBytes()-allocated,collectible,privateBytes=process.PrivateMemorySize64,workingSet=process.WorkingSet64,gcBytes=GC.GetTotalMemory(false)});
                check(collectible,"Closed editor is collectible after dispatcher/timer drain: "+round);
            }
            check(observedCache,"Resource soak samples the idle preview cache, not only busy intervals");
            check(peakCache<=256L*1024*1024,"Soak retains the existing 256 MiB optional preview-cache budget");
            check(hash.SequenceEqual(SHA256.HashData(File.ReadAllBytes(raw))),"Resource soak preserves the external RAW bytes");
            Console.WriteLine($"resource-soak peak-private={peakPrivate}; peak-working-set={peakWorking}; peak-cache={peakCache}; samples={samples.Count}");
        }
        catch(Exception ex){error=ex.ToString();throw;}
        finally
        {
            timer.Stop();if(active?.IsVisible==true)active.Close();active=null;app.Shutdown();
            File.WriteAllText(Path.Combine(output,"resources.json"),JsonSerializer.Serialize(new{error,rounds,samples,peakPrivate,peakWorking,peakCache,
                scope="One warmup plus three real-RAW CPU editor cycles. Sampled process memory, not a total native/GPU memory bound or a physical GPU acceptance."},new JsonSerializerOptions{WriteIndented=true}));
            Console.WriteLine("Resource samples: "+output);
        }
    }
    [MethodImpl(MethodImplOptions.NoInlining)]
    private static void DescribeRetention(WeakReference weak,Application app)
    {
        if(weak.Target is not MainWindow window)return;
        var handlers=((Delegate?)typeof(Loc).GetField("Changed",BindingFlags.Static|BindingFlags.NonPublic)!.GetValue(null))?.GetInvocationList() ?? [];
        Console.WriteLine("Retention diagnostic: windows="+app.Windows.Count+"; main="+(app.MainWindow!=null)+"; Loc="+string.Join(",",handlers.Select(handler=>handler.Target?.GetType().FullName+"."+handler.Method.Name)));
        foreach(var name in new[]{"editSaveTimer","editNoticeTimer","thumbnailRefresh","previewResize"})
            Console.WriteLine(name+" enabled="+((DispatcherTimer)typeof(MainWindow).GetField(name,Private)!.GetValue(window)!).IsEnabled);
    }
    [MethodImpl(MethodImplOptions.NoInlining)]
    private static WeakReference Cycle(Application app,string raw,string output,int round,Action<MainWindow?> active,Action<string,MainWindow?> sample,Action<bool,string> check)
    {
        var window=new MainWindow();TestWindowState.Isolate(window,output);window.GpuMode.SelectedIndex=1;active(window);
        try
        {
            window.Show();window.OpenFile(raw);InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);sample("open-"+round,window);
            check(app.Windows.Count==1,"Manual resource fixture creates exactly one private editor window: "+round);
            window.ValueSlider.Value=.625+Math.Max(0,round)*.025;
            check(!window.ExportPng.IsEnabled,"Soak adjustment invalidates stale export: "+round);
            InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);sample("adjust-"+round,window);
            window.ResultCanvas.Viewport!.Actual();InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);sample("actual-"+round,window);
            window.ResultCanvas.Viewport.Fit();InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);sample("fit-"+round,window);
            window.OpenFile(raw);InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);sample("reopen-"+round,window);
        }
        finally
        {
            window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);sample("closed-"+round,window);
            check(app.Windows.Count==0,"Closing leaves no implicit StartupUri editor: "+round);
            check(typeof(MainWindow).GetField("engine",Private)!.GetValue(window)==null,"Closed soak window disposes its native session: "+round);
            if(ReferenceEquals(app.MainWindow,window))app.MainWindow=null;
            active(null);
        }
        return new WeakReference(window);
    }
}
