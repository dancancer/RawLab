using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using RawLab.Windows;

internal static class DenoiseChecks
{
    internal static void Run(string repository,string raw)
    {
        static void Check(bool value,string message) { if(!value)throw new Exception(message);Console.WriteLine("PASS "+message); }
        static byte[] Pixels(BitmapSource image) {
            var bytes=new byte[image.PixelWidth*image.PixelHeight*4];
            new FormatConvertedBitmap(image,PixelFormats.Bgra32,null,0).CopyPixels(bytes,image.PixelWidth*4,0);return bytes;
        }
        ComparisonChecks.Run(Check);
        using var engine=new RenderEngine(0);
        var settings=new Adjustments();
        var off=engine.RenderPreview(raw,settings,null,600,false,true,false);
        settings.Denoise=DenoiseSettings.Clean;
        var clean=engine.RenderPreview(raw,settings,null,600,false,true,false);
        Check(ReferenceEquals(off.Neutral,clean.Neutral),"Denoise leaves the original frame unchanged");
        Check(!Pixels(off.Result.Image).SequenceEqual(Pixels(clean.Result.Image)),"Native wavelet changes real RAW output");
        settings.Set(Parameter.Exposure,1);
        var exposed=engine.RenderPreview(raw,settings,null,600,false,true,false);
        Check(ReferenceEquals(off.Neutral,exposed.Neutral),"Exposure leaves the original frame unchanged");
        settings.Set(Parameter.Temperature,8000);
        var balanced=engine.RenderPreview(raw,settings,null,600,false,true,false);
        Check(ReferenceEquals(off.Neutral,balanced.Neutral),"White balance leaves the original frame unchanged");
        settings.ResetAll();settings.Denoise=DenoiseSettings.Clean;
        using(var fresh=new RenderEngine(0)) {
            var proxy=fresh.RenderPreview(raw,settings,null,1000,true,true,false);
            var exact=fresh.RenderPreview(raw,settings,null,600,false,true,false);
            Check(Pixels(exact.Result.Image).SequenceEqual(Pixels(clean.Result.Image)),"Fresh proxy never contaminates exact denoise");
            Check(ReferenceEquals(proxy.Neutral,exact.Neutral),"Proxy retains the fixed original frame");
        }
        settings.Denoise=settings.Denoise with {Enabled=false};
        Check(Pixels(engine.Render(raw,settings,null,600)!.Image).SequenceEqual(Pixels(off.Result.Image)),"Disabling restores the original output");
        settings.Denoise=DenoiseSettings.Clean;
        engine.SetGpuMode(2);
        try { engine.Render(raw,settings,null,600);throw new Exception("Force GPU accepted CPU-only denoise"); }
        catch(InvalidOperationException) { Console.WriteLine("PASS Force GPU rejects active CPU-only denoise"); }
        engine.SetGpuMode(0);
        var directory=Path.Combine(repository,"build","denoise-verification");Directory.CreateDirectory(directory);
        var output=Path.Combine(directory,"denoised.png");
        engine.Render(raw,settings,null,0,output:output);
        using var stream=File.OpenRead(output);
        var saved=new PngBitmapDecoder(stream,BitmapCreateOptions.PreservePixelFormat,BitmapCacheOption.OnLoad).Frames[0];
        using var reference=new RenderEngine(0);
        var full=reference.Render(raw,settings,null,0)!;
        Check(saved.PixelWidth==full.Image.PixelWidth && saved.PixelHeight==full.Image.PixelHeight && saved.Format.BitsPerPixel>=48,
            "Denoise export remains native size and sixteen-bit RGB");
        Check(Pixels(saved).Zip(Pixels(full.Image),(a,b)=>Math.Abs(a-b)).Max()<=1,
            "PNG pixels match independent exact denoise within one code value");
    }
}
