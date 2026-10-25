using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using RawLab.Windows;

internal static class HslTargetRenderChecks
{
    internal static void Run(string repo,string output,Action<bool,string> check)
    {
        Directory.CreateDirectory(output);
        var input=Path.Combine(output,"hsl-target.png");
        const int width=48,height=32;
        var pixels=new byte[width*height*3];
        for(var y=0;y<height;y++)for(var x=0;x<width;x++) {
            var i=(y*width+x)*3;pixels[i]=(byte)(120+x*2);pixels[i+1]=(byte)(30+y*3);pixels[i+2]=(byte)(20+x);
        }
        var bitmap=BitmapSource.Create(width,height,96,96,PixelFormats.Rgb24,null,pixels,width*3);
        var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using(var stream=File.Create(input))encoder.Save(stream);
        using var engine=new RenderEngine(0,Path.Combine(repo,"lutools","tests","fixtures","lenses.xml"));
        var revision=new HslTargetRevision(19,41);var neutral=new Adjustments();
        var before=engine.SampleHsl(input,neutral,null,0,false,revision,.4,.3);
        check(before.Usable && before.Revision==revision && !before.Preview,"Full CPU sample returns validated HSL weights and revision");
        check(Marshal.SizeOf<Native.HslProbeQuery>()==32 && Marshal.SizeOf<Native.HslProbeResult>()==96,"Probe P/Invoke ABI matches native structs");
        var downstream=new Adjustments {Hsl=new HslSettings().WithValue(0,0,80),ColorGrading=new(){Shadows=new(230,70)}};
        downstream.SetEffect(PhotoEffectParameter.GrainAmount,70);
        var unchanged=engine.SampleHsl(input,downstream,null,0,false,revision,.4,.3);
        check(unchanged.Rgb.SequenceEqual(before.Rgb) && unchanged.Weights.SequenceEqual(before.Weights),"HSL, grading and grain cannot feed back into the sample");
        var upstream=new Adjustments {ToneControls=new(){Vibrance=80}};upstream.Set(Parameter.Exposure,.5);
        var changed=engine.SampleHsl(input,upstream,null,0,false,revision,.4,.3);
        check(!changed.Rgb.SequenceEqual(before.Rgb),"Sample includes upstream exposure and vibrance");
        foreach(var quarter in Enumerable.Range(0,4)) {
            var settings=new Adjustments {Geometry=new(.1,.1,.8,.7,quarter,true,false,3,PerspectiveHorizontal:.12,PerspectiveVertical:-.09)};
            var rendered=engine.RenderPreview(input,settings,null,24,false,false,false).Result.Image;
            var x=rendered.PixelWidth/3;var y=rendered.PixelHeight/3;
            var sample=engine.SampleHsl(input,settings,null,24,false,revision,x/(double)(rendered.PixelWidth-1),y/(double)(rendered.PixelHeight-1));
            var rgb=new FormatConvertedBitmap(rendered,PixelFormats.Rgb24,null,0);var data=new byte[rendered.PixelWidth*rendered.PixelHeight*3];
            rgb.CopyPixels(data,rendered.PixelWidth*3,0);var offset=(y*rendered.PixelWidth+x)*3;
            check(sample.Preview && sample.Usable && Enumerable.Range(0,3).All(c=>Math.Abs(sample.Rgb[c]*255-data[offset+c])<2),"Probe follows crop, rotation, perspective and preview resizing");
        }
        check(engine.SampleHsl(input,neutral,null,24,false,revision,-double.Epsilon,.5).Availability==HslTargetAvailability.Outside,"Outside Double is rejected before Float conversion");
        check(engine.SampleHsl(input,neutral,null,24,false,revision,double.NaN,.5).Availability==HslTargetAvailability.Nonfinite,"Nonfinite input rejected");
    }
}
