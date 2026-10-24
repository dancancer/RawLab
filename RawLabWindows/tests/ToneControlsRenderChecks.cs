using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using RawLab.Windows;

internal static class ToneControlsRenderChecks
{
    internal static void Run(string repo, string output, string cli, Action<bool,string> check)
    {
        Directory.CreateDirectory(output);
        var input=Path.Combine(output,"tone-source.png");
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
        foreach(var (name,tone) in new[] {
            ("black",new ToneControlsSettings(60,0,0)),("white",new ToneControlsSettings(0,-60,0)),
            ("vibrance",new ToneControlsSettings(0,0,60)),("combined",new ToneControlsSettings(-32.75,46.5,21.25))
        }) {
            var settings=new Adjustments { ToneControls=tone };
            var preview=engine.RenderPreview(input,settings,null,width,false,false,false);
            check(!Bytes(preview.Result.Image).SequenceEqual(original),name+" invalidates cached preview and changes pixels");
            var compared=engine.RenderPreview(input,settings,null,width,false,true,false);
            check(Bytes(compared.Neutral.Image).SequenceEqual(original),name+" preserves the neutral comparison");
            var gui=Path.Combine(output,name+"-native.png");var agent=Path.Combine(output,name+"-agent.png");
            engine.Render(input,settings,null,0,output:gui);
            var recipe=engine.AgentRecipe(input,settings,null,agent);
            using(var parsed=JsonDocument.Parse(recipe)) {
                var edits=parsed.RootElement.GetProperty("edits");
                if(tone.BlackPoint!=0)check(edits.GetProperty("tone").GetProperty("black_point").GetSingle()==(float)(tone.BlackPoint/100),name+" black point maps to core units");
                if(tone.WhitePoint!=0)check(edits.GetProperty("tone").GetProperty("white_point").GetSingle()==(float)(tone.WhitePoint/100),name+" white point maps to core units");
                if(tone.Vibrance!=0)check(edits.GetProperty("color").GetProperty("vibrance").GetSingle()==(float)(tone.Vibrance/100),name+" vibrance maps to core units");
            }
            var recipeFile=Path.Combine(output,name+".json");File.WriteAllText(recipeFile,recipe);
            var start=new ProcessStartInfo(cli){UseShellExecute=false,RedirectStandardOutput=true,RedirectStandardError=true,CreateNoWindow=true};
            start.ArgumentList.Add("--recipe");start.ArgumentList.Add(recipeFile);
            using var process=Process.Start(start)!;
            var stdout=process.StandardOutput.ReadToEndAsync();var stderr=process.StandardError.ReadToEndAsync();
            if(!process.WaitForExit(60000)) { process.Kill(true);throw new TimeoutException("Tone recipe CLI timeout"); }
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
                name+" direct render applies tone after a raster source replaces the session");
        }
    }
}
