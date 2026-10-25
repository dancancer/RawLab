using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using RawLab.Windows;

internal static class AtmosphereRenderChecks
{
    internal static void Run(string repo, string output, string cli, Action<bool,string> check)
    {
        Directory.CreateDirectory(output);
        var input=Path.Combine(output,"atmosphere-source.png");
        const int width=320,height=192;
        var pixels=new byte[width*height*3];
        for(var y=0;y<height;y++)for(var x=0;x<width;x++) {
            var i=(y*width+x)*3;var wave=(int)(25*Math.Sin(x*Math.PI/16));
            pixels[i]=(byte)(80+x/4+wave);pixels[i+1]=(byte)(60+y/2+wave);pixels[i+2]=(byte)(65+x/8+y/4+wave);
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
        foreach(var (name,atmosphere) in new[] {
            ("clarity-positive",new AtmosphereSettings(75,0)),("clarity-negative",new AtmosphereSettings(-75,0)),
            ("dehaze-positive",new AtmosphereSettings(0,75)),("dehaze-negative",new AtmosphereSettings(0,-75)),
            ("combined",new AtmosphereSettings(37.251234,-42.5))
        }) {
            var settings=new Adjustments { Atmosphere=atmosphere };
            var preview=engine.RenderPreview(input,settings,null,width,false,false,false);
            check(!Bytes(preview.Result.Image).SequenceEqual(original),name+" invalidates cached preview and changes pixels");
            var compared=engine.RenderPreview(input,settings,null,width,false,true,false);
            check(Bytes(compared.Neutral.Image).SequenceEqual(original),name+" preserves the neutral comparison");
            var gui=Path.Combine(output,name+"-native.png");var agent=Path.Combine(output,name+"-agent.png");
            engine.Render(input,settings,null,0,output:gui);
            var recipe=engine.AgentRecipe(input,settings,null,agent);
            using(var parsed=JsonDocument.Parse(recipe)) {
                var edits=parsed.RootElement.GetProperty("edits");
                check(edits.GetProperty("effects").GetProperty("clarity").GetSingle()==(float)(atmosphere.Clarity/100),name+" clarity maps to core units");
                check(edits.GetProperty("effects").GetProperty("dehaze").GetSingle()==(float)(atmosphere.Dehaze/100),name+" dehaze maps to core units");
            }
            var recipeFile=Path.Combine(output,name+".json");File.WriteAllText(recipeFile,recipe);
            var start=new ProcessStartInfo(cli){UseShellExecute=false,RedirectStandardOutput=true,RedirectStandardError=true,CreateNoWindow=true};
            start.ArgumentList.Add("--recipe");start.ArgumentList.Add(recipeFile);
            using var process=Process.Start(start)!;
            var stdout=process.StandardOutput.ReadToEndAsync();var stderr=process.StandardError.ReadToEndAsync();
            if(!process.WaitForExit(60000)) { process.Kill(true);throw new TimeoutException("Atmosphere recipe CLI timeout"); }
            check(process.ExitCode==0,name+" CLI recipe succeeds: "+stderr.GetAwaiter().GetResult());
            var nativeImage=BitmapFrame.Create(new Uri(gui),BitmapCreateOptions.PreservePixelFormat,BitmapCacheOption.OnLoad);
            var agentImage=BitmapFrame.Create(new Uri(agent),BitmapCreateOptions.PreservePixelFormat,BitmapCacheOption.OnLoad);
            check(nativeImage.Format == agentImage.Format && nativeImage.Format.BitsPerPixel >= 48, name+" native and Agent retain 16-bit PNG channels");
            var stride = nativeImage.PixelWidth * ((nativeImage.Format.BitsPerPixel + 7) / 8);
            var nativePixels = new byte[stride * nativeImage.PixelHeight]; var agentPixels = new byte[stride * agentImage.PixelHeight];
            nativeImage.CopyPixels(nativePixels, stride, 0); agentImage.CopyPixels(agentPixels, stride, 0);
            check(nativePixels.SequenceEqual(agentPixels),name+" native and Agent FINAL 16-bit pixels agree exactly");
            check(Bytes(engine.RenderPreview(input,neutral,null,width,false,false,false).Result.Image).SequenceEqual(original),name+" reset clears the reused session");
            var other=Path.Combine(output,name+"-other-source.png");File.Copy(input,other,true);
            using var fresh=new RenderEngine(0,Path.Combine(repo,"lutools","tests","fixtures","lenses.xml"));
            var expected=Bytes(fresh.Render(other,settings,null,0)!.Image);
            engine.Render(input,neutral,null,0);
            check(Bytes(engine.Render(other,settings,null,0)!.Image).SequenceEqual(expected),
                name+" direct render applies atmosphere after a raster source replaces the session");
        }
    }
}
