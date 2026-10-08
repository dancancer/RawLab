using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using RawLab.Windows;

internal static class PerformanceChecks
{
    // A new session, with normal filesystem caching. Pixel hashing is outside timings.
    internal static void Run(string repo,string raw,bool ui=false)
    {
        var film=Path.Combine(repo,"lutools/flog-2-new/FLog2_to_PROVIA_65grid_V.1.00.cube");
        using var process=Process.GetCurrentProcess();
        using var engine=new RenderEngine();
        var settings=new Adjustments();
        void Pair(string name,int edge,bool interactive=false)
        {
            var allocated=GC.GetAllocatedBytesForCurrentThread();
            var cpu=process.TotalProcessorTime;
            var clock=Stopwatch.StartNew();
            var result=ui ? engine.RenderPreview(raw,settings,film,edge,interactive,true,false).Result : PairWithMasks();
            RenderedImage PairWithMasks()
            {
                engine.Render(raw,settings,null,edge,interactive);
                return engine.Render(raw,settings,film,edge,interactive)!;
            }
            clock.Stop();
            var cpuMs=(process.TotalProcessorTime-cpu).TotalMilliseconds;
            allocated=GC.GetAllocatedBytesForCurrentThread()-allocated;
            var pixels=new byte[result.Image.PixelWidth*result.Image.PixelHeight*4];
            result.Image.CopyPixels(pixels,result.Image.PixelWidth*4,0);
            Console.WriteLine($"{name}: {clock.Elapsed.TotalMilliseconds:F2} ms; cpu_ms={cpuMs:F2}; cores={cpuMs/clock.Elapsed.TotalMilliseconds:F2}; managed={allocated}; backend={result.Backend}; sha256={Convert.ToHexString(SHA256.HashData(pixels))}");
            settings.ResolveWhiteBalance(result.WhiteBalance);
        }
        if(ui)Pair("first-proxy",1000,true);
        Pair("fresh-exact",2000);
        for(var i=0;i<6;i++){settings.Set(Parameter.Exposure,(i+1)*.05);Pair("warm-exact",2000);}
        for(var i=0;i<6;i++){settings.Set(Parameter.Exposure,(-i-1)*.05);Pair("drag-exposure",1000,true);}
        foreach(var kelvin in new[]{6000,8000}){settings.Set(Parameter.Temperature,kelvin);Pair("exact-WB",2000);}
        foreach(var kelvin in new[]{5000,7000,9000}){settings.Set(Parameter.Temperature,kelvin);Pair("drag-WB",1000,true);}
        Pair("release-WB",2000);
    }
}
