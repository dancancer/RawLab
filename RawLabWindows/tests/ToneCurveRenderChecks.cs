using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using RawLab.Windows;

internal static class ToneCurveRenderChecks
{
    internal static void Run(string repo, string output, string cli, Action<bool,string> check)
    {
        Directory.CreateDirectory(output);
        var input=Path.Combine(output,"curve-source.png");
        const int width=96,height=64;
        var pixels=new byte[width*height*3];
        for(var y=0;y<height;y++)for(var x=0;x<width;x++) {
            var i=(y*width+x)*3;pixels[i]=(byte)(24+x*2);pixels[i+1]=(byte)(16+y*3);pixels[i+2]=(byte)(31+x+y);
        }
        var bitmap=BitmapSource.Create(width,height,96,96,PixelFormats.Rgb24,null,pixels,width*3);bitmap.Freeze();
        var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using(var file=File.Create(input))encoder.Save(file);
        byte[] Bytes(BitmapSource image) {
            var converted=new FormatConvertedBitmap(image,PixelFormats.Bgra32,null,0);
            var data=new byte[image.PixelWidth*image.PixelHeight*4];converted.CopyPixels(data,image.PixelWidth*4,0);return data;
        }
        using var engine=new RenderEngine(0,Path.Combine(repo,"lutools","tests","fixtures","lenses.xml"));
        byte[] Preview(Adjustments value)=>Bytes(engine.RenderPreview(input,value,null,width,false,false,false).Result.Image);
        var neutral=new Adjustments();var baseline=Preview(neutral);
        var settings=new Adjustments();settings.Set(Parameter.ToneCurve,65);var legacy=Preview(settings);
        check(!legacy.SequenceEqual(baseline),"Legacy S curve remains effective");
        settings.Curve=ToneCurveSettings.Identity;
        check(Preview(settings).SequenceEqual(baseline),"Identity bypasses inactive legacy scalar exactly");
        settings.Curve=ToneCurveSettings.Identity.Inserting(.25,.4).Inserting(.75,.9);
        var changed=Preview(settings);
        check(!changed.SequenceEqual(baseline)&&!changed.SequenceEqual(legacy),"Custom curve invalidates preview cache and reaches native pixels");
        var samples=ToneCurveSampling.Samples(settings.Curve,256);
        var sample=engine.SampleHsl(input,settings,null,width,false,new(1,1),0,0);
        check(sample.Usable&&samples.Count==256,"Native sampler and pre-HSL probe succeed");
        check(new[]{24,16,31}.Select((value,channel)=>Math.Abs(samples[value].Y-sample.Rgb[channel])<.00001).All(value=>value),
            "Canvas evaluator agrees with native curve pixels");
        engine.RenderPreview(input,settings,null,48,true,false,false);
        check(Preview(settings).SequenceEqual(changed),"FINAL curve pixels survive interactive preview");
        var gui=Path.Combine(output,"native.png");var agent=Path.Combine(output,"agent.png");
        engine.Render(input,settings,null,0,output:gui);
        var recipe=engine.AgentRecipe(input,settings,null,agent);
        using(var parsed=JsonDocument.Parse(recipe)) {
            var tone=parsed.RootElement.GetProperty("edits").GetProperty("tone");
            check(tone.GetProperty("s_curve").GetDouble()==0 && tone.GetProperty("curve").GetProperty("mode").GetString()=="custom",
                "Agent emits custom curve with zero render scalar");
        }
        var recipeFile=Path.Combine(output,"curve.json");File.WriteAllText(recipeFile,recipe);
        var start=new ProcessStartInfo(cli){UseShellExecute=false,RedirectStandardOutput=true,RedirectStandardError=true,CreateNoWindow=true};
        start.ArgumentList.Add("--recipe");start.ArgumentList.Add(recipeFile);
        using(var process=Process.Start(start)!) {
            var stdout=process.StandardOutput.ReadToEndAsync();var stderr=process.StandardError.ReadToEndAsync();
            if(!process.WaitForExit(60000)){process.Kill(true);throw new TimeoutException("Curve recipe CLI timeout");}
            check(process.ExitCode==0,"Curve CLI succeeds: "+stderr.GetAwaiter().GetResult());
        }
        BitmapSource Load(string path)=>BitmapFrame.Create(new Uri(path),BitmapCreateOptions.PreservePixelFormat,BitmapCacheOption.OnLoad);
        check(Bytes(Load(gui)).SequenceEqual(Bytes(Load(agent))),"Native export and Agent FINAL pixels agree");
        settings.Curve=new();check(Preview(settings).SequenceEqual(legacy),"Legacy clears the reused custom session");
        check(Preview(neutral).SequenceEqual(baseline),"Reset clears complete curve state");
    }
}
