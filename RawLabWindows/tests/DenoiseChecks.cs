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
        // 小缩图可能没有足够的噪声样本；导出回归先确保预览实际发生滤波。
        const int appliedEdge=1600;
        var off=engine.RenderPreview(raw,settings,null,appliedEdge,false,true,false);
        settings.Denoise=DenoiseSettings.Clean;
        var clean=engine.RenderPreview(raw,settings,null,appliedEdge,false,true,false);
        Check(ReferenceEquals(off.Neutral,clean.Neutral),"Denoise leaves the original frame unchanged");
        Check(!Pixels(off.Result.Image).SequenceEqual(Pixels(clean.Result.Image)),"Native wavelet changes real RAW output");
        settings.Set(Parameter.Exposure,1);
        var exposed=engine.RenderPreview(raw,settings,null,appliedEdge,false,true,false);
        Check(ReferenceEquals(off.Neutral,exposed.Neutral),"Exposure leaves the original frame unchanged");
        settings.Set(Parameter.Temperature,8000);
        var balanced=engine.RenderPreview(raw,settings,null,appliedEdge,false,true,false);
        Check(ReferenceEquals(off.Neutral,balanced.Neutral),"White balance leaves the original frame unchanged");
        settings.ResetAll();settings.Denoise=DenoiseSettings.Clean;
        using(var fresh=new RenderEngine(0)) {
            var proxy=fresh.RenderPreview(raw,settings,null,1000,true,true,false);
            var exact=fresh.RenderPreview(raw,settings,null,appliedEdge,false,true,false);
            Check(Pixels(exact.Result.Image).SequenceEqual(Pixels(clean.Result.Image)),"Fresh proxy never contaminates exact denoise");
            Check(ReferenceEquals(proxy.Neutral,exact.Neutral),"Proxy retains the fixed original frame");
        }
        settings.Denoise=settings.Denoise with {Enabled=false};
        Check(Pixels(engine.Render(raw,settings,null,appliedEdge,viewportPreview:true)!.Image).SequenceEqual(Pixels(off.Result.Image)),"Disabling restores the original output");
        settings.Denoise=DenoiseSettings.Clean;
        using var gpuEngine=new RenderEngine(1);
        var nativeGpuAvailable=gpuEngine.Render(raw,new Adjustments(),null,600)!.Backend==3;
        var autoClean=gpuEngine.Render(raw,settings,null,appliedEdge,viewportPreview:true)!;
        if(nativeGpuAvailable)
        {
            Check(autoClean.Backend==3,"Auto keeps active denoise on an available Direct3D 11 backend");
            gpuEngine.SetGpuMode(2);
            var forcedClean=gpuEngine.Render(raw,settings,null,appliedEdge,viewportPreview:true)!;
            Check(forcedClean.Backend==3,"Force GPU executes active denoise on Direct3D 11");
            Check(Pixels(forcedClean.Image).Zip(Pixels(clean.Result.Image),(a,b)=>Math.Abs(a-b)).Max()<=2,
                "Direct3D 11 active denoise stays within CPU tolerance");
        }
        else
        {
            Console.WriteLine("SKIP Direct3D 11 active denoise parity: no hardware adapter available");
            gpuEngine.SetGpuMode(2);
            try { gpuEngine.Render(raw,settings,null,appliedEdge,viewportPreview:true);throw new Exception("Force GPU accepted active denoise without Direct3D 11"); }
            catch(InvalidOperationException) { Console.WriteLine("PASS Force GPU rejects active denoise without hardware"); }
        }
        var previousDisable=Environment.GetEnvironmentVariable("RAWLAB_DISABLE_D3D11");
        try
        {
            Environment.SetEnvironmentVariable("RAWLAB_DISABLE_D3D11","1");
            gpuEngine.SetGpuMode(1);
            var fallback=gpuEngine.Render(raw,settings,null,appliedEdge,viewportPreview:true)!;
            Check(fallback.Backend==0 && Pixels(fallback.Image).Zip(Pixels(clean.Result.Image),(a,b)=>Math.Abs(a-b)).Max()<=1,
                "RAWLAB_DISABLE_D3D11 keeps active denoise on the CPU fallback");
            gpuEngine.SetGpuMode(2);
            try { gpuEngine.Render(raw,settings,null,appliedEdge,viewportPreview:true);throw new Exception("Disabled Direct3D 11 accepted Force active denoise"); }
            catch(InvalidOperationException) { Console.WriteLine("PASS RAWLAB_DISABLE_D3D11 rejects Force active denoise"); }
        }
        finally { Environment.SetEnvironmentVariable("RAWLAB_DISABLE_D3D11",previousDisable); gpuEngine.SetGpuMode(1); }
        var combined=settings.Clone();
        combined.Effects=new PhotoEffectsSettings(-65,52,-35,70,75,70,60,80);
        combined.DisplayChromaDenoise=2;
        combined.Set(Parameter.Sharpening,50);
        var combinedCpu=engine.Render(raw,combined,null,600)!;
        var combinedAuto=gpuEngine.Render(raw,combined,null,600)!;
        Check(Pixels(combinedCpu.Image).Zip(Pixels(combinedAuto.Image),(a,b)=>Math.Abs(a-b)).Max()<=2,
            "Combined effects, wavelet, chroma and detail match CPU");
        if(nativeGpuAvailable)
        {
            Check(combinedAuto.Backend==3,"Combined Auto actually uses Direct3D 11");
            gpuEngine.SetGpuMode(2);
            var forced=gpuEngine.Render(raw,combined,null,600)!;
            Check(forced.Backend==3 && Pixels(forced.Image).Zip(Pixels(combinedCpu.Image),(a,b)=>Math.Abs(a-b)).Max()<=2,
                "Combined Force uses Direct3D 11 within CPU tolerance");
            Check(Pixels(forced.Image).SequenceEqual(Pixels(gpuEngine.Render(raw,combined,null,600)!.Image)),
                "Direct3D 11 grain is deterministic");
        }
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
        engine.RenderPreview(raw,settings,null,832,true,true,false);
        var jpeg=Path.Combine(directory,"denoised.jpg");
        var expectedJpeg=Path.Combine(directory,"denoised-reference.jpg");
        engine.Render(raw,settings,null,0,interactive:true,output:jpeg,viewportPreview:true);
        reference.Render(raw,settings,null,0,output:expectedJpeg);
        using var actualStream=File.OpenRead(jpeg);
        using var expectedStream=File.OpenRead(expectedJpeg);
        var actual=new JpegBitmapDecoder(actualStream,BitmapCreateOptions.PreservePixelFormat,BitmapCacheOption.OnLoad).Frames[0];
        var expected=new JpegBitmapDecoder(expectedStream,BitmapCreateOptions.PreservePixelFormat,BitmapCacheOption.OnLoad).Frames[0];
        Check(actual.PixelWidth==full.Image.PixelWidth && actual.PixelHeight==full.Image.PixelHeight,
            "JPEG after viewport denoise remains native size");
        Check(Pixels(actual).SequenceEqual(Pixels(expected)),"JPEG after viewport denoise matches independent FINAL export");
    }
}
