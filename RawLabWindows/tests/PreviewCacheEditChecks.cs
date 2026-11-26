using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using RawLab.Windows;

// 预览缓存键必须覆盖渲染器实际消费的每个编辑字段：先缓存一张基线帧，再逐项只改一个字段做同尺寸非交互预览，
// 结果必须是新渲染且与全新引擎的渲染逐像素一致，不能把基线帧当作该编辑的结果返回。
internal static class PreviewCacheEditChecks
{
    internal static void Run(string repo,string raw,Action<bool,string> check)
    {
        var directory=Path.Combine(repo,"build","preview-cache-edits",Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            const int edge=256;
            var paths=AppPaths.CreateIsolated(directory);
            using var engine=new RenderEngine(0,appPaths:paths);
            using var fresh=new RenderEngine(0,appPaths:paths);
            var baselineSettings=Baseline();
            var baseline=engine.RenderPreview(raw,baselineSettings,null,edge,false,false,false);
            check(ReferenceEquals(baseline,engine.RenderPreview(raw,Baseline(),null,edge,false,false,false)),
                "Unchanged settings reuse the cached preview frame");
            var stale=new List<string>();
            var mismatched=new List<string>();
            foreach(var (name,edit) in Edits())
            {
                var settings=Baseline();
                edit(settings);
                var frame=engine.RenderPreview(raw,settings,null,edge,false,false,false);
                if(ReferenceEquals(frame,baseline))stale.Add(name);
                var expected=fresh.Render(raw,settings,null,edge,clipping:false,viewportPreview:true)!;
                if(!Pixels(frame.Result.Image).SequenceEqual(Pixels(expected.Image)))mismatched.Add(name);
            }
            check(stale.Count==0,"Preview cache returned the cached baseline frame after editing: "+string.Join(", ",stale));
            check(mismatched.Count==0,"Preview differs from a fresh render after editing: "+string.Join(", ",mismatched));
        }
        finally { Directory.Delete(directory,true); }
    }

    // 基线带传统锐化和颗粒，使只改 v2 锐化参数或颗粒预设的编辑也会改变像素。
    private static Adjustments Baseline()
    {
        var settings=new Adjustments { Effects=new(GrainAmount:40) };
        settings.Set(Parameter.Sharpening,1);
        return settings;
    }

    private static IEnumerable<(string Name,Action<Adjustments> Edit)> Edits()
    {
        yield return ("camera calibration",s=>s.Calibration=new(ShadowTint:40,RedHue:60,BlueSaturation:-60));
        yield return ("point color",s=>s.PointColor=new([new PointColorSwatch(SrcHue:30,HueShift:80,SaturationShift:60,Range:100)]));
        yield return ("selective color",s=>s.SelectiveColor=new(SelectiveColorMethod.Absolute,
            new SelectiveColorBands { Reds=new(80,0,0,0),Neutrals=new(60,-40,30,20) }));
        yield return ("B&W mixer",s=>s.BwMixer=new(true,new BwMixerWeights(Red:60,Blue:-60)));
        yield return ("luminance sharpening v2",s=>s.SharpenV2=new(LuminanceV2:true,Radius:2.5,Detail:80));
        yield return ("halation",s=>s.FilmOptics=new(HalationAmount:100,HalationThreshold:0,HalationRadius:100));
        yield return ("bloom",s=>s.FilmOptics=new(BloomAmount:100,BloomThreshold:0,BloomRadius:100));
        yield return ("texture",s=>s.Atmosphere=new(Texture:80));
        yield return ("grain format preset",s=>s.Effects=s.Effects with { GrainFormatPreset=GrainFormatPreset.Film120 });
        yield return ("grain tone curve",s=>s.Effects=s.Effects with { GrainToneCurve=GrainToneCurve.NegativeAsymmetric });
        yield return ("parametric curve",s=>s.Curve=new(parametric:new(Highlights:40,Shadows:-30)));
        yield return ("channel curve",s=>s.Curve=new(channels:new ToneCurveChannels() with {
            Red=new(ToneCurveMode.Custom,[new(0,0),new(.5,.65),new(1,1)]) }));
        yield return ("defringe",s=>s.Lens=new(DefringePurpleAmount:20,DefringeGreenAmount:20));
        yield return ("exposure",s=>s.Set(Parameter.Exposure,.5));
    }

    private static byte[] Pixels(BitmapSource image)
    {
        var converted=new FormatConvertedBitmap(image,PixelFormats.Bgra32,null,0);
        var bytes=new byte[converted.PixelWidth*converted.PixelHeight*4];
        converted.CopyPixels(bytes,converted.PixelWidth*4,0);
        return bytes;
    }
}
