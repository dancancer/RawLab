using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using RawLab.Windows;

internal static class AgentRecipeChecks
{
    internal static void Run(string repo,string raw,string cli,Action<bool,string> check)
    {
        var method=typeof(RenderEngine).GetMethod("AgentRecipe",BindingFlags.Instance|BindingFlags.Public|BindingFlags.NonPublic);
        check(method!=null,"Windows exposes effective-state Agent v5 serialization");
        var output=Path.Combine(repo,"build","windows-agent-recipe",DateTime.UtcNow.ToString("yyyyMMdd-HHmmss")+"-"+Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(output);var hash=SHA256.HashData(File.ReadAllBytes(raw));
        using var engine=new RenderEngine(0);
        string Recipe(string input,Adjustments state,string? look,string target,int? edge)=>
            (string)method!.Invoke(engine,[input,state,look,target,edge])!;
        var unicodeRecipe=Path.Combine(output,"recipe-\u6D4B\u8BD5-\U0001F308.json");
        File.WriteAllText(unicodeRecipe,Recipe(raw,new Adjustments(),null,Path.Combine(output,"unicode.png"),128));
        RunCli("--recipe",unicodeRecipe,"--print-recipe");
        var look=Path.Combine(repo,"lutools","flog-2-new","FLog2_to_PROVIA_65grid_V.1.00.cube");
        var mixed=new Adjustments{ExposureMode=2,ToneControls=new(-32.75,46.5,21.25),Hsl=new HslSettings().WithValue(0,0,18).WithValue(1,4,-27).WithValue(2,7,13),
            Effects=new(-28,63,19,72,34,18,31,42),Denoise=new(true,8,51,63),DisplayChromaDenoise=2,
            Geometry=new(.07,.08,.8,.76,1,true,false,3.5,.04,-.03)};
        mixed.Set(Parameter.Exposure,.35);mixed.Set(Parameter.Contrast,23.5);mixed.Set(Parameter.Saturation,-17.8);
        mixed.Set(Parameter.Highlights,21.4);mixed.Set(Parameter.Shadows,14.8);mixed.Set(Parameter.ToneCurve,-18.2);mixed.Set(Parameter.Sharpening,35.7);
        mixed.Set(Parameter.Temperature,5300);mixed.Set(Parameter.Tint,12.4);mixed.Set(Parameter.Strength,73);
        Verify(raw,mixed,look,"mixed",257);
        var legacy=mixed.Clone();legacy.Processing=ProcessingIdentity.Legacy;
        Verify(raw,legacy,look,"legacy-processing",257);
        Verify(raw,new Adjustments(),null,"defaults",128);
        var target=Path.Combine(repo,"lutools","tests","fixtures","linear-lens.dng");
        var targetHash=SHA256.HashData(File.ReadAllBytes(target));
        var targetMaster=new Adjustments();var tintRecipe=MasterRecipe.All.First(recipe=>recipe.TintDelta!=0);
        targetMaster.ApplyMasterRecipe(tintRecipe);targetMaster.ResolveWhiteBalance((2000,-150));
        Verify(target,targetMaster,tintRecipe.LutPath,"target-wb",48);
        foreach(var strength in new[]{0,50,100,200})
        {
            var recipe=MasterRecipe.All.First(recipe=>recipe.TintDelta!=0);
            var state=new Adjustments();state.ApplyMasterRecipe(recipe);state.Set(Parameter.Strength,strength);
            state.ResolveWhiteBalance((2000,-150));
            Verify(raw,state,recipe.LutPath,"master-"+strength,128);
            check(state.AsShot==(2000,-150),"Agent target WB resolution does not mutate the captured source state");
        }
        var chroma=new Adjustments{DisplayChromaDenoise=1};Verify(raw,chroma,null,"display-chroma",128);
        var clamped=new Adjustments();clamped.ApplyMasterRecipe(tintRecipe);clamped.Set(Parameter.Strength,200);
        clamped.Set(Parameter.Contrast,100);clamped.Set(Parameter.Saturation,-100);clamped.Set(Parameter.Highlights,100);
        clamped.Set(Parameter.Shadows,-100);clamped.Set(Parameter.ToneCurve,100);clamped.Set(Parameter.Sharpening,200);
        Verify(raw,clamped,tintRecipe.LutPath,"core-clamp",128);
        foreach(var edge in new[]{0,65536})
        {
            var rejected=false;
            try{_=Recipe(raw,new Adjustments(),null,Path.Combine(output,"invalid.png"),edge);}
            catch(TargetInvocationException error) when(error.InnerException is ArgumentOutOfRangeException){rejected=true;}
            check(rejected && !File.Exists(Path.Combine(output,"invalid.png")),"Agent rejects invalid FINAL size before creating output: "+edge);
        }
        var stored=mixed.Capture();var store=new EditStore(Path.Combine(output,"edits"));
        store.Save(raw,stored,null);var restored=new EditStore(Path.Combine(output,"edits")).Find(raw)!;
        check(restored!=null && restored.Settings.Restore().Capture().Values.SequenceEqual(stored.Values),"Agent regression retains the production edit store round trip");
        Verify(raw,restored!.Settings.Restore(),look,"restored",128);
        var journal=new BatchJournal(Path.Combine(output,"batch"));
        var job=BatchJob.Create(raw,targetMaster.Capture(),tintRecipe.LutPath,"Frozen");job.Format=ExportFormat.Png;job.LongEdge=128;
        job.OutputDirectory=Path.Combine(output,"batch-output");Directory.CreateDirectory(job.OutputDirectory);
        job.Items=[BatchItem.Create(raw) with{Selected=true},BatchItem.Create(target) with{Selected=true}];journal.FreezeLook(job);journal.Save(job);
        mixed.ResetAll();targetMaster.ResetAll();
        BatchRunner.Run(job,journal,false,CancellationToken.None,(_,_)=>{},(input,state,film,target,edge)=>engine.Render(input,state,film,0,output:target,longEdge:edge));
        foreach(var item in job.Items)
        {
            check(item.Status==BatchStatus.Succeeded,"Frozen batch exports through the actual BatchRunner FINAL delegate");
            var agent=Path.Combine(output,"frozen-agent-"+item.Id+".png");var path=Path.Combine(output,"frozen-"+item.Id+".json");
            var state=job.Settings.Restore();var text=Recipe(item.Input,state,job.Look,agent,job.LongEdge);
            AssertTargetWhiteBalance(item.Input,state,text,"Frozen batch "+item.Id);
            File.WriteAllText(path,text);RunCli("--recipe",path,"--json");
            Compare(item.Output!,agent,"Frozen batch and per-target Agent FINAL");
        }
        check(hash.SequenceEqual(SHA256.HashData(File.ReadAllBytes(raw))) && targetHash.SequenceEqual(SHA256.HashData(File.ReadAllBytes(target))),"Agent parity preserves external RAW and the distinct-WB target bytes");
        var database=Path.Combine(repo,"lutools","tests","fixtures","lenses.xml");
        using(var lensEngine=new RenderEngine(0,database))
        {
            var baseline=lensEngine.Render(target,new(),null,64,statistics:false,clipping:false)!;
            var candidate=baseline.Lens!.Candidates.First(c=>c.IsMatch && c.HasDistortion);
            var state=new Adjustments{Lens=new(true,candidate.HasTca,true,true,candidate.Id)};
            var agent=Path.Combine(output,"lens-agent.png");var path=Path.Combine(output,"lens.json");
            File.WriteAllText(path,lensEngine.AgentRecipe(target,state,null,agent));
            using var result=JsonDocument.Parse(RunCli("--recipe",path,"--lens-database",database,"--json"));
            check(result.RootElement.GetProperty("result").GetProperty("lens_correction").GetProperty("applied_distortion").GetBoolean(),"Agent reports the actually applied manual lens calibration");
            var gui=lensEngine.Render(target,state,null,0,statistics:false,clipping:false)!;
            check(gui.Lens?.AppliedDistortion==true,"GUI FINAL applies the same selected manual lens calibration");
            BufferParity(gui.Image,agent,"Manual lens FINAL buffer");
        }
        Console.WriteLine("Agent recipe artifacts: "+output);

        void Verify(string input,Adjustments state,string? film,string name,int edge)
        {
            var gui=Path.Combine(output,name+"-gui.png");var agent=Path.Combine(output,name+"-agent.png");
            var text=Recipe(input,state,film,agent,edge);using var json=JsonDocument.Parse(text);
            if(state.MasterRecipeID!=null)AssertTargetWhiteBalance(input,state,text,name);
            var root=json.RootElement;var edits=root.GetProperty("edits");
            check(root.GetProperty("schema_version").GetInt32()==5 && root.GetProperty("input").GetProperty("type").GetString()=="raw","Agent emits explicit RAW v5: "+name);
            var processing=root.GetProperty("processing");
            check(processing.GetProperty("family").GetString()==state.Processing.Family &&
                processing.GetProperty("version").GetInt32()==state.Processing.Version &&
                processing.GetProperty("quality").GetString()==state.Processing.Quality,"Agent preserves processing identity: "+name);
            check(new[]{"exposure","white_balance","look","tone","detail","hsl","effects","denoise","lens_correction","geometry"}.All(key=>edits.TryGetProperty(key,out _)),"Agent emits every effective edit group: "+name);
            check(edits.GetProperty("hsl").EnumerateObject().All(p=>p.Value.GetArrayLength()==8),"Agent emits all 24 HSL channels: "+name);
            var denoise=edits.GetProperty("denoise");check(denoise.GetProperty("raw_level").GetInt32()==0 &&
                denoise.GetProperty("chroma_mode").GetInt32()==state.DisplayChromaDenoise,"Agent uses no FBDD and retains effective display chroma: "+name);
            if(!state.Denoise.Enabled)check(denoise.GetProperty("wavelet").GetProperty("luma").GetInt32()==0 &&
                denoise.GetProperty("wavelet").GetProperty("chroma").GetInt32()==46 && denoise.GetProperty("wavelet").GetProperty("coarse").GetInt32()==50,"Disabled wavelet emits canonical defaults: "+name);
            var path=Path.Combine(output,name+".json");File.WriteAllText(path,text);
            RunCli("--recipe",path,"--print-recipe");RunCli("--recipe",path,"--json");
            engine.Render(input,state,film,0,output:gui,longEdge:edge);Compare(gui,agent,"GUI and Agent FINAL: "+name);
            if(name=="mixed")
            {
                var preview=Path.Combine(output,"exact-preview.png");RunCli("--recipe",path,"--preview",preview,"--long-edge",edge.ToString(),"--json");
                Compare(agent,preview,"CLI exact preview retains FINAL geometry");
                var frame=engine.Render(input,state,film,edge,statistics:false,clipping:false)!;
                BufferParity(frame.Image,preview,"GUI exact preview and FINAL geometry");
            }
        }
        void AssertTargetWhiteBalance(string input,Adjustments state,string text,string name)
        {
            var camera=engine.Render(input,new Adjustments{ExposureMode=state.ExposureMode},null,32,statistics:false,clipping:false)!.WhiteBalance;
            check(camera.HasValue && camera!=(2000,-150),"Independent neutral target WB is available and differs from captured source WB: "+name);
            using var json=JsonDocument.Parse(text);var wb=json.RootElement.GetProperty("edits").GetProperty("white_balance");
            var offset=state[Parameter.Tint]*state[Parameter.Strength]/100;
            if(state.CameraWhiteBalance && offset==0)
                check(wb.GetProperty("mode").GetString()=="camera","Zero recipe tint keeps target camera WB: "+name);
            else
            {
                var expectedTemperature=state.CameraWhiteBalance ? camera!.Value.Temperature : state[Parameter.Temperature];
                var expectedTint=Math.Clamp(camera!.Value.Tint+offset,-150,150);
                check(wb.GetProperty("mode").GetString()=="temperature" &&
                    Math.Abs(wb.GetProperty("temperature_kelvin").GetDouble()-expectedTemperature)<.1 &&
                    Math.Abs(wb.GetProperty("tint").GetDouble()-expectedTint)<.001,
                    "Serialized WB uses independently probed target camera values and one scaled recipe tint: "+name);
            }
        }
        void BufferParity(BitmapSource expected,string actual,string name)
        {
            using var file=File.OpenRead(actual);var png=BitmapFrame.Create(file,BitmapCreateOptions.PreservePixelFormat,BitmapCacheOption.OnLoad);
            check(expected.PixelWidth==png.PixelWidth && expected.PixelHeight==png.PixelHeight && png.Format==PixelFormats.Rgb48,"FINAL/preview dimensions and PNG16 agree: "+name);
            byte[] Bytes(BitmapSource image){var converted=new FormatConvertedBitmap(image,PixelFormats.Bgra32,null,0);var bytes=new byte[image.PixelWidth*image.PixelHeight*4];converted.CopyPixels(bytes,image.PixelWidth*4,0);return bytes;}
            var first=Bytes(expected);var second=Bytes(png);var difference=first.Zip(second,(a,b)=>Math.Abs(a-b)).Max();
            check(difference<=1,"RGBA8 and independently quantized PNG16 agree within one code value: "+name+" max="+difference);
        }
        void Compare(string expected,string actual,string name)
        {
            BitmapSource Read(string path){using var file=File.OpenRead(path);return BitmapFrame.Create(file,BitmapCreateOptions.PreservePixelFormat,BitmapCacheOption.OnLoad);}
            var a=Read(expected);var b=Read(actual);
            check(a.Format==PixelFormats.Rgb48 && b.Format==PixelFormats.Rgb48 && a.PixelWidth==b.PixelWidth && a.PixelHeight==b.PixelHeight,"Both same-sized outputs are real PNG16: "+name);
            var first=new byte[a.PixelWidth*a.PixelHeight*6];var second=new byte[first.Length];
            a.CopyPixels(first,a.PixelWidth*6,0);b.CopyPixels(second,b.PixelWidth*6,0);
            check(first.SequenceEqual(second),"Independent decoded PNG16 pixels match exactly: "+name);
        }
        string RunCli(params string[] arguments)
        {
            var info=new ProcessStartInfo(cli){UseShellExecute=false,RedirectStandardOutput=true,RedirectStandardError=true};
            foreach(var argument in arguments)info.ArgumentList.Add(argument);
            using var process=Process.Start(info)!;var text=process.StandardOutput.ReadToEndAsync();var error=process.StandardError.ReadToEndAsync();
            if(!process.WaitForExit(180000)){process.Kill(true);throw new TimeoutException("Task-owned Agent CLI timed out");}
            Task.WaitAll(text,error);File.AppendAllText(Path.Combine(output,"cli.log"),string.Join(' ',arguments)+"\n"+text.Result+"\n"+error.Result+"\n");
            check(process.ExitCode==0,"Shared Windows CLI accepts/renders effective v4: "+string.Join(' ',arguments.Take(2)));
            return text.Result;
        }
    }
}
