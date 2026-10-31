using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text.Json;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using RawLab.Windows;

internal static class X3fRenderingChecks
{
    internal static void Run(string repo,string raw,string output,Action<bool,string> check)
    {
        Directory.CreateDirectory(output);
        var before=SHA256.HashData(File.ReadAllBytes(raw));
        using var engine=new RenderEngine(0,Path.Combine(repo,"lutools","third_party","lensfun","version_1"));
        check(RenderEngine.X3fAvailable,"Windows package includes normal X3F rendering");
        var normal=new Adjustments();var legacy=normal.Clone();legacy.X3fMode=X3fMode.Legacy;
        var a=engine.RenderPreview(raw,normal,null,384,false,true,false);
        var b=engine.RenderPreview(raw,legacy,null,384,false,true,false);
        var c=engine.RenderPreview(raw,normal,null,384,false,true,false);
        check(!Pixels(a.Result.Image).SequenceEqual(Pixels(b.Result.Image)) && Pixels(a.Result.Image).SequenceEqual(Pixels(c.Result.Image)),"Normal/legacy/normal restores exact preview pixels");
        check(!Pixels(a.Neutral.Image).SequenceEqual(Pixels(b.Neutral.Image)),"Before reference changes with X3F mode");
        check(a.Result.WhiteBalance is {Temperature:6500,Tint:0},"Normal X3F exposes relative neutral white balance");
        var edited=normal.Clone();edited.Set(Parameter.Exposure,.5);edited.Set(Parameter.Temperature,4800);edited.Set(Parameter.Tint,12);
        check(!Pixels(a.Result.Image).SequenceEqual(Pixels(engine.Render(raw,edited,null,384)!.Image)),"Normal exposure and relative WB affect pixels");
        check(double.IsFinite(engine.AutoExposure(raw,normal)),"Normal auto exposure is finite");
        var gui=Path.Combine(output,"gui.png");var cli=Path.Combine(output,"cli.png");var recipe=Path.Combine(output,"recipe.json");
        engine.Render(raw,edited,null,0,output:gui,longEdge:512);
        var json=engine.AgentRecipe(raw,edited,null,cli,512);File.WriteAllText(recipe,json);
        using(var document=JsonDocument.Parse(json)) {
            check(document.RootElement.GetProperty("schema_version").GetInt32()==7 && document.RootElement.GetProperty("x3f_mode").GetString()=="normal-v1","Agent recipe v7 carries normal X3F identity");
        }
        var start=new ProcessStartInfo(Path.Combine(repo,"build","RawLab-Windows","sony2fuji.exe")) {UseShellExecute=false,RedirectStandardOutput=true,RedirectStandardError=true};
        start.ArgumentList.Add("--recipe");start.ArgumentList.Add(recipe);
        using(var process=Process.Start(start)!) {
            var stdout=process.StandardOutput.ReadToEndAsync();var stderr=process.StandardError.ReadToEndAsync();
            if(!process.WaitForExit(600000)){process.Kill(true);throw new TimeoutException("X3F CLI export timed out");}
            check(process.ExitCode==0,"CLI X3F recipe export: "+stderr.GetAwaiter().GetResult());
            _=stdout.GetAwaiter().GetResult();
        }
        check(File.ReadAllBytes(gui)[24]==16 && File.ReadAllBytes(cli)[24]==16,"Both PNG exports contain real 16-bit channels");
        check(Pixels(Read(gui),PixelFormats.Rgb48).SequenceEqual(Pixels(Read(cli),PixelFormats.Rgb48)),"GUI and CLI normal exports have identical RGB16 pixels");
        check(Math.Max(Read(gui).PixelWidth,Read(gui).PixelHeight)==512,"Normal export respects long-edge limit");
        engine.Render(raw,edited,null,0,output:Path.Combine(output,"edited.jpg"),longEdge:512);
        engine.Render(raw,edited,null,0,output:Path.Combine(output,"edited.dng"),longEdge:512);
        var invalid=normal.Clone();invalid.Lens=new(Distortion:true);
        try {engine.Render(raw,invalid,null,128);check(false,"Normal lens request must reject");}
        catch(InvalidOperationException error) {check(error.Message.Contains("lens"),"Unsupported normal lens correction reports its specific reason");}
        check(Pixels(b.Result.Image).SequenceEqual(Pixels(engine.Render(raw,legacy,null,384)!.Image)),"Explicit legacy rendering recovers after normal rejection");
        var store=new EditStore(Path.Combine(output,"edits"));
        store.Save(raw,legacy.Capture(),null);
        check(new EditStore(Path.Combine(output,"edits")).Find(raw)!.Settings.X3fMode==X3fMode.Legacy,"Saved Windows X3F mode survives a new store");
        check(before.SequenceEqual(SHA256.HashData(File.ReadAllBytes(raw))),"Original X3F remains byte-identical");
    }
    private static BitmapFrame Read(string path) {using var file=File.OpenRead(path);return BitmapFrame.Create(file,BitmapCreateOptions.PreservePixelFormat,BitmapCacheOption.OnLoad);}
    private static byte[] Pixels(BitmapSource source,PixelFormat? format=null) {
        var selected=format ?? PixelFormats.Bgra32;var image=new FormatConvertedBitmap(source,selected,null,0);
        var stride=image.PixelWidth*selected.BitsPerPixel/8;var bytes=new byte[stride*image.PixelHeight];image.CopyPixels(bytes,stride,0);return bytes;
    }
}
