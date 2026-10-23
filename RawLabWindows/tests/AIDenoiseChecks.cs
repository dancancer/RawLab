using System.IO;
using System.Windows.Media.Imaging;
using RawLab.Windows;

internal static class AIDenoiseChecks
{
    internal static void Run(string model,string raw,string cache,Action<bool,string> check,string backend="CPU")
    {
        using var engine=new RenderEngine(gpuMode:0,aiModelDirectory:model,aiCacheDirectory:cache,aiBackend:2);
        var settings=new Adjustments { AIDenoiseEnabled=true };
        using var cancelled=new AIPreparation((_,_,_)=>{});cancelled.Cancel();
        try { engine.PrepareAI(raw,settings,cancelled);throw new Exception("Cancelled AI started"); }
        catch(OperationCanceledException) { check(true,"AI cancellation exits before inference"); }
        try { engine.AgentRecipe(raw,settings,null,"unused.png");throw new Exception("AI edits silently omitted from Agent recipe"); }
        catch(NotSupportedException) { check(true,"Agent v5 explicitly rejects unsupported AI edits"); }
        var phases=new List<(int Phase,ulong Done,ulong Total)>();
        using var progress=new AIPreparation((phase,done,total)=>phases.Add((phase,done,total)));
        engine.PrepareAI(raw,settings,progress);
        check(phases.Where(v=>v.Phase is 2 or 3).All(v=>v.Done==1 && v.Total==1),"Prepared Windows AI cache is reused");
        var rgbBackend=backend=="CPU" ? "CPU" : "ISP:CPU/RGB:"+backend;
        check(engine.LastAIBackend==$"RAW={backend}; RGB={rgbBackend}","Windows Auto truthfully reports actual AI producers: "+engine.LastAIBackend);
        check(double.IsFinite(engine.AutoExposure(raw,settings)),"Auto exposure reads the selected AI backend cache");
        var a=engine.RenderPreview(raw,settings,null,512,false,false,false).Result;
        settings.Denoise=DenoiseSettings.Clean;settings.DisplayChromaDenoise=2;
        var retained=engine.RenderPreview(raw,settings,null,512,false,false,false).Result;
        check(Pixels(a.Image).SequenceEqual(Pixels(retained.Image)),"AI bypasses retained ordinary denoise parameters");
        settings.Set(Parameter.Exposure,1);
        var brighter=engine.RenderPreview(raw,settings,null,512,false,false,false).Result;
        check(!Pixels(a.Image).SequenceEqual(Pixels(brighter.Image)),"Exposure edits prepared AI result");
        var output=Path.Combine(Path.GetTempPath(),"rawlab-ai-export-"+Guid.NewGuid()+".png");
        try {
            var exact=engine.Render(raw,settings,null,0,statistics:false,clipping:false)!;
            engine.Render(raw,settings,null,0,output:output);
            using var stream=File.OpenRead(output);
            var saved=BitmapDecoder.Create(stream,BitmapCreateOptions.PreservePixelFormat,BitmapCacheOption.OnLoad).Frames[0];
            var x=Pixels(exact.Image);var y=Pixels(saved);
            check(x.Length==y.Length && x.Zip(y).All(p=>Math.Abs(p.First-p.Second)<=2),"Windows native preview/export share prepared AI result");
        } finally { if(File.Exists(output))File.Delete(output); }
        settings.Set(Parameter.Temperature,4500);
        try { engine.RenderPreview(raw,settings,null,512,false,false,false);throw new Exception("Missing WB cache rendered silently"); }
        catch(AINotReadyException) { check(true,"Changed white balance requires its RGB result"); }
    }
    private static byte[] Pixels(BitmapSource image)
    {
        var converted=new FormatConvertedBitmap(image,System.Windows.Media.PixelFormats.Bgra32,null,0);
        var bytes=new byte[converted.PixelWidth*converted.PixelHeight*4];converted.CopyPixels(bytes,converted.PixelWidth*4,0);return bytes;
    }
}
