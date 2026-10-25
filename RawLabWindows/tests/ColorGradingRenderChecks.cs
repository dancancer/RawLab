using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using RawLab.Windows;

internal static class ColorGradingRenderChecks
{
    internal static void Run(string repo, string output, string cli, Action<bool,string> check)
    {
        Directory.CreateDirectory(output);
        var input=Path.Combine(output,"grading-source.png");
        const int width=128,height=96;
        var pixels=new byte[width*height*3];
        for(var y=0;y<height;y++)for(var x=0;x<width;x++) {
            var i=(y*width+x)*3;pixels[i]=(byte)(24+x*1.6);pixels[i+1]=(byte)(16+y*2.1);pixels[i+2]=(byte)(31+x+y/2);
        }
        var bitmap=BitmapSource.Create(width,height,96,96,PixelFormats.Rgb24,null,pixels,width*3);bitmap.Freeze();
        var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using(var file=File.Create(input))encoder.Save(file);
        byte[] Bytes(BitmapSource image) {
            var converted=new FormatConvertedBitmap(image,PixelFormats.Bgra32,null,0);
            var data=new byte[image.PixelWidth*image.PixelHeight*4];converted.CopyPixels(data,image.PixelWidth*4,0);return data;
        }
        using var engine=new RenderEngine(0,Path.Combine(repo,"lutools","tests","fixtures","lenses.xml"),aiCacheDirectory:Path.Combine(output,"ai-cache"));
        var neutral=new Adjustments();
        var original=Bytes(engine.RenderPreview(input,neutral,null,width,false,false,false).Result.Image);
        foreach(var (name,grading) in new[] {
            ("shadows",new ColorGradingSettings { Shadows=new(240,80) }),
            ("midtones",new ColorGradingSettings { Midtones=new(120,80) }),
            ("highlights",new ColorGradingSettings { Highlights=new(0,80) }),
            ("combined",new ColorGradingSettings { Shadows=new(220,35),Midtones=new(110,25),Highlights=new(35,45) })
        }) {
            var settings=new Adjustments { ColorGrading=grading };
            var preview=engine.RenderPreview(input,settings,null,width,false,false,false);
            check(!Bytes(preview.Result.Image).SequenceEqual(original),name+" invalidates cached preview and changes pixels");
            var compared=engine.RenderPreview(input,settings,null,width,false,true,false);
            check(Bytes(compared.Neutral.Image).SequenceEqual(original),name+" preserves the neutral comparison");
            var gui=Path.Combine(output,name+"-native.png");var agent=Path.Combine(output,name+"-agent.png");
            engine.Render(input,settings,null,0,output:gui);
            var recipe=engine.AgentRecipe(input,settings,null,agent);
            using(var parsed=JsonDocument.Parse(recipe)) {
                var edits=parsed.RootElement.GetProperty("edits");
                var actual=edits.GetProperty("color_grading");
                foreach(var zone in Enum.GetValues<ColorGradingZone>()) {
                    var wheel=actual.GetProperty(zone.ToString().ToLowerInvariant());
                    check(wheel.GetProperty("hue").GetSingle()==grading[zone].NativeHue &&
                        wheel.GetProperty("saturation").GetSingle()==(float)grading[zone].Saturation,
                        name+" serializes complete canonical grading zones");
                }
            }
            var recipeFile=Path.Combine(output,name+".json");File.WriteAllText(recipeFile,recipe);
            var start=new ProcessStartInfo(cli){UseShellExecute=false,RedirectStandardOutput=true,RedirectStandardError=true,CreateNoWindow=true};
            start.ArgumentList.Add("--recipe");start.ArgumentList.Add(recipeFile);
            using var process=Process.Start(start)!;
            var stdout=process.StandardOutput.ReadToEndAsync();var stderr=process.StandardError.ReadToEndAsync();
            if(!process.WaitForExit(60000)) { process.Kill(true);throw new TimeoutException("Grading recipe CLI timeout"); }
            check(process.ExitCode==0,name+" CLI recipe succeeds: "+stderr.GetAwaiter().GetResult());
            var nativeImage=BitmapFrame.Create(new Uri(gui),BitmapCreateOptions.PreservePixelFormat,BitmapCacheOption.OnLoad);
            var agentImage=BitmapFrame.Create(new Uri(agent),BitmapCreateOptions.PreservePixelFormat,BitmapCacheOption.OnLoad);
            check(Bytes(nativeImage).SequenceEqual(Bytes(agentImage)),name+" native and Agent FINAL pixels agree");
            check(Bytes(engine.RenderPreview(input,neutral,null,width,false,false,false).Result.Image).SequenceEqual(original),name+" reset clears the reused session");
            var other=Path.Combine(output,name+"-other-source.png");File.Copy(input,other,true);
            using var fresh=new RenderEngine(0,Path.Combine(repo,"lutools","tests","fixtures","lenses.xml"));
            var expected=Bytes(fresh.Render(other,settings,null,0)!.Image);
            engine.Render(input,neutral,null,0);
            check(Bytes(engine.Render(other,settings,null,0)!.Image).SequenceEqual(expected),
                name+" direct render applies grading after a raster source replaces the session");
        }
        var pending=new Adjustments { ColorGrading=new() { Shadows=new(231.25,0) } };
        check(Bytes(engine.Render(input,pending,null,0)!.Image).SequenceEqual(original),"Pending hue has no pixel effect");
        using var pendingRecipe=JsonDocument.Parse(engine.AgentRecipe(input,pending,null,Path.Combine(output,"pending.png")));
        check(pendingRecipe.RootElement.GetProperty("edits").GetProperty("color_grading").GetProperty("shadows").GetProperty("hue").GetDouble()==231.25,
            "Agent preserves pending hue despite render identity");
    }
}
