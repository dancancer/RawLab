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
        var settings=new Adjustments();settings.Set(Parameter.ToneCurve,.65);var legacy=Preview(settings);
        check(!legacy.SequenceEqual(baseline),"Legacy S curve remains effective");
        settings.Curve=ToneCurveSettings.Identity;
        check(Preview(settings).SequenceEqual(baseline),"Identity bypasses inactive legacy scalar exactly");
        settings.Curve=ToneCurveSettings.Identity.Inserting(.25,.4).Inserting(.75,.9);
        var changed=Preview(settings);
        check(!changed.SequenceEqual(baseline)&&!changed.SequenceEqual(legacy),"Custom curve invalidates preview cache and reaches native pixels");
        var samples=ToneCurveSampling.Samples(settings.Curve, count: 256);
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
        var v2 = new ToneCurveSettings(
            ToneCurveMode.Custom,
            [new(0, 0.08), new(0.5, 0.55), new(1, 0.92)],
            applyToLuminosity: true,
            parametric: new ToneCurveParametric(-15, 20, -10, 25, 0.2, 0.5, 0.8),
            channels: new ToneCurveChannels(
                new ToneCurveShape(ToneCurveMode.Custom, [new(0, 0), new(0.5, 0.6), new(1, 1)]),
                new(), new()));
        settings.Curve = v2;
        var v2CompositeSamples = ToneCurveSampling.Samples(v2, ToneCurveChannel.Rgb, count: 257);
        var v2PointOnlySamples = ToneCurveSampling.Samples(v2, ToneCurveChannel.Rgb, includeParametric: false, count: 257);
        var v2ParametricOnlySamples = ToneCurveSampling.Samples(
            new ToneCurveSettings(ToneCurveMode.Custom, ToneCurveShape.Identity.Points, parametric: v2.Parametric),
            ToneCurveChannel.Rgb, includeParametric: true, count: 257);
        check(Math.Abs(v2PointOnlySamples[128].Y - 0.55) < 1e-9 && Math.Abs(v2CompositeSamples[128].Y - 0.55) > 1e-3 &&
            Math.Abs(v2ParametricOnlySamples[0].Y - 0.0) < 1e-9 && Math.Abs(v2ParametricOnlySamples[^1].Y - 1.0) < 1e-9,
            "Windows point-curve and parametric-curve canvas samplers isolate each sub-mode cleanly");
        var v2Preview = Preview(settings);
        check(!v2Preview.SequenceEqual(baseline) && !v2Preview.SequenceEqual(changed),
            "Track A v2 curve (unpinned Y, luminosity, parametric, red channel) reaches native pixels");
        var v2Gui = Path.Combine(output, "native-v2.png");
        var v2Agent = Path.Combine(output, "agent-v2.png");
        engine.Render(input, settings, null, 0, output: v2Gui);
        var v2Recipe = engine.AgentRecipe(input, settings, null, v2Agent);
        using (var parsed = JsonDocument.Parse(v2Recipe)) {
            check(parsed.RootElement.GetProperty("schema_version").GetInt32() == 17,
                "Agent emits schema_version 17 for v2 tone curve extensions");
        }
        var v2RecipeFile = Path.Combine(output, "curve-v2.json");
        File.WriteAllText(v2RecipeFile, v2Recipe);
        var v2Start = new ProcessStartInfo(cli){UseShellExecute=false,RedirectStandardOutput=true,RedirectStandardError=true,CreateNoWindow=true};
        v2Start.ArgumentList.Add("--recipe"); v2Start.ArgumentList.Add(v2RecipeFile);
        using (var process = Process.Start(v2Start)!) {
            _ = process.StandardOutput.ReadToEndAsync(); var stderr = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(60000)) { process.Kill(true); throw new TimeoutException("Curve v2 CLI timeout"); }
            check(process.ExitCode == 0, "Curve v2 CLI succeeds: " + stderr.GetAwaiter().GetResult());
        }
        check(Bytes(Load(v2Gui)).SequenceEqual(Bytes(Load(v2Agent))), "Native v2 export and Agent schema v17 FINAL pixels agree");
        var freeX = new ToneCurveSettings(
            ToneCurveMode.Custom,
            [new(0.2, 0.0), new(0.8, 1.0)],
            channels: new ToneCurveChannels(
                new ToneCurveShape(ToneCurveMode.Custom, [new(0.15, 0.05), new(0.85, 0.95)]),
                new(), new()));
        var fxRgb = ToneCurveSampling.Samples(freeX, ToneCurveChannel.Rgb, count: 256);
        var fxRed = ToneCurveSampling.Samples(freeX, ToneCurveChannel.Red, count: 256);
        check(fxRgb[0].Y == 0.0 && fxRgb[^1].Y == 1.0 && Math.Abs(fxRed[0].Y - 0.05) < 1e-5 && Math.Abs(fxRed[^1].Y - 0.95) < 1e-5,
            "Free-X sampling clamps flat outside [x0, x1]");
        settings.Curve = freeX;
        var fxGui = Path.Combine(output, "native-freex.png");
        var fxAgent = Path.Combine(output, "agent-freex.png");
        engine.Render(input, settings, null, 0, output: fxGui);
        var fxRecipe = engine.AgentRecipe(input, settings, null, fxAgent);
        using (var parsed = JsonDocument.Parse(fxRecipe)) {
            check(parsed.RootElement.GetProperty("schema_version").GetInt32() == 18,
                "Agent emits schema_version 18 for free-X curve endpoints");
        }
        var fxRecipeFile = Path.Combine(output, "curve-freex.json");
        File.WriteAllText(fxRecipeFile, fxRecipe);
        var fxStart = new ProcessStartInfo(cli){UseShellExecute=false,RedirectStandardOutput=true,RedirectStandardError=true,CreateNoWindow=true};
        fxStart.ArgumentList.Add("--recipe"); fxStart.ArgumentList.Add(fxRecipeFile);
        using (var process = Process.Start(fxStart)!) {
            _ = process.StandardOutput.ReadToEndAsync(); var stderr = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(60000)) { process.Kill(true); throw new TimeoutException("Curve free-X CLI timeout"); }
            check(process.ExitCode == 0, "Curve free-X CLI succeeds: " + stderr.GetAwaiter().GetResult());
        }
        check(Bytes(Load(fxGui)).SequenceEqual(Bytes(Load(fxAgent))), "Native free-X export and Agent schema v17 FINAL pixels agree");
        settings.Curve=new();check(Preview(settings).SequenceEqual(legacy),"Legacy clears the reused custom session");
        check(Preview(neutral).SequenceEqual(baseline),"Reset clears complete curve state");
    }
}
