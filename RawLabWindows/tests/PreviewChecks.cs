using System.IO;
using System.Windows.Media;
using RawLab.Windows;

internal static class PreviewChecks
{
    internal static void Run(RenderEngine engine,string raw,string lut,Action<bool,string> check)
    {
        var embedded=RenderEngine.ReadEmbeddedPreview(raw);
        check(embedded.Image!=null && embedded.Image.IsFrozen && Math.Max(embedded.Image.PixelWidth,embedded.Image.PixelHeight)<=1600,
            "Embedded camera preview is decoded and frozen without RAW development");
        var settings=new Adjustments();
        PreviewFrame Frame(int edge=2000,bool interactive=false,bool compare=true,bool clipping=false)=>
            engine.RenderPreview(raw,settings,lut,edge,interactive,compare,clipping);
        var fit=Frame();var full=Frame(0);
        check(embedded.Width==full.Result.Image.PixelWidth && embedded.Height==full.Result.Image.PixelHeight,
            "Embedded metadata supplies the exact active source dimensions before development");
        check(full.Result.Image.Format==PixelFormats.Pbgra32,"Opaque photo buffers use the WPF compositor pixel format");
        check(engine.CachedPreviewBytes<=256L*1024*1024,"Preview cache stays within the 256 MiB pixel budget");
        if((long)embedded.Width*embedded.Height*8+2000L*2000*8<=256L*1024*1024)
        {
            check(ReferenceEquals(fit,Frame()) && ReferenceEquals(full,Frame(0)),"Fit/native toggles reuse exact frames without processing or readback");
            check(ReferenceEquals(fit,Frame(1000,true)),"An exact cached preview may satisfy a proxy request");
        }
        settings.Set(Parameter.Exposure,.35);
        var proxy=Frame(1000,true);var changed=Frame();
        check(!ReferenceEquals(proxy,changed) && !ReferenceEquals(fit,changed),"Editing invalidates cached pixels and proxy quality never satisfies an exact request");
        var single=Frame(compare:false);
        check(ReferenceEquals(single.Neutral,single.Result),"Comparison changes invalidate the cached frame");
        var masked=Frame(clipping:true);
        check(masked.Neutral.Clipping!=null && masked.Result.Clipping!=null,"Clipping changes invalidate the cached frame");
        engine.SetGpuMode(0);var cpu=Frame();
        check(cpu.Result.Backend!=3,"CPU mode cannot reuse a GPU-labelled cached frame");engine.SetGpuMode(1);
        var originalTime=File.GetLastWriteTimeUtc(raw);
        try
        {
            var original=Frame();File.SetLastWriteTimeUtc(raw,originalTime.AddSeconds(2));
            check(!ReferenceEquals(original,Frame()),"Replacing a RAW invalidates managed and native cached data");
        }
        finally{File.SetLastWriteTimeUtc(raw,originalTime);}
    }
}
