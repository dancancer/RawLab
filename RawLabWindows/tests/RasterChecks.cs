using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using RawLab.Windows;

internal static class RasterChecks
{
    internal static void Run(string repo,string raw,string cli,Action<bool,string> check)
    {
        var raster=typeof(LibraryEntry).GetMethod("IsRaster",BindingFlags.Public|BindingFlags.Static);
        var image=typeof(LibraryEntry).GetMethod("IsImage",BindingFlags.Public|BindingFlags.Static);
        check(raster!=null && image!=null,"File library exposes ordinary-image and RAW/image classification");
        foreach(var name in new[]{"image.JPG","image.jpeg","image.PNG","image.tif","image.TIFF"})
            check((bool)raster!.Invoke(null,[name])! && (bool)image!.Invoke(null,[name])! && !LibraryEntry.IsRaw(name),"Ordinary image classification: "+name);
        check((bool)image!.Invoke(null,["image.ARW"])! && !(bool)image.Invoke(null,["image.txt"])!,"RAW classification is retained without admitting arbitrary files");
        var output=Path.Combine(repo,"build","windows-raster",DateTime.UtcNow.ToString("yyyyMMdd-HHmmss")+"-"+Guid.NewGuid().ToString("N")[..8]);
        var inputs=Path.Combine(output,"inputs");Directory.CreateDirectory(inputs);
        const int width=48,height=32;
        var pixels=new byte[width*height*3];
        for(var y=0;y<height;y++)for(var x=0;x<width;x++)
        {var p=(y*width+x)*3;pixels[p]=(byte)(32+x*3);pixels[p+1]=(byte)(25+y*5);pixels[p+2]=(byte)(21+x*2+y);}
        var bitmap=BitmapSource.Create(width,height,96,96,PixelFormats.Rgb24,null,pixels,width*3);bitmap.Freeze();
        var png=Path.Combine(inputs,"pattern.png");var jpeg=Path.Combine(inputs,"ordinary.jpg");var tiff=Path.Combine(inputs,"classic.tiff");
        Save(png,new PngBitmapEncoder());Save(jpeg,new JpegBitmapEncoder{QualityLevel=96});
        Save(tiff,new TiffBitmapEncoder{Compression=TiffCompressOption.None});
        var metadataProtected=false;
        try { ExportMetadata.Preserve(png,png); }
        catch(InvalidOperationException error) when(error.Message==Loc.Text("不能覆盖原始文件。")) { metadataProtected=true; }
        check(metadataProtected,"Raster metadata writer reports the dedicated original-file protection message");
        var identities=new[]{raw,png,jpeg,tiff}.ToDictionary(path=>path,Hash);
        using var engine=new RenderEngine(0);
        using(var forced=new RenderEngine(2))
        {
            var unsupported=false;try{forced.Render(png,new(),null,32,statistics:false,clipping:false);}
            catch(InvalidOperationException error) when(error.Message==Loc.Text("不支持此照片、外观或处理方式。请检查文件兼容性和处理设置。")){unsupported=true;}
            check(unsupported,"Direct Force GPU remains explicitly unsupported for raster; it never pretends CPU succeeded");
        }
        var identity=engine.Render(png,new(),null,0,statistics:false,clipping:false)!;
        check(identity.WhiteBalance==null && identity.Baseline==0 && identity.Lens==null,"Raster frame has no RAW WB, baseline or lens report");
        var rgba=Bytes(identity.Image);
        for(var p=0;p<width*height;p++)for(var c=0;c<3;c++)
            if(rgba[p*4+c]!=pixels[p*3+2-c])throw new Exception("Display-sRGB identity changed an untagged RGB channel");
        check(true,"Untagged PNG keeps exact sRGB code values without a RAW sigmoid");
        check(DisplayBytes()==width*height*4,"Managed display input retains only one full RGBA8 source buffer");
        var preview=engine.RenderPreview(png,new(),null,16,false,false,false);
        check(ReferenceEquals(preview.Neutral,preview.Result) && Math.Max(preview.Result.Image.PixelWidth,preview.Result.Image.PixelHeight)==16,
            "Raster single preview uses a bounded result without a duplicate comparison frame");
        var embedded=RenderEngine.ReadEmbeddedPreview(png,7);
        check(embedded.Image!=null && Math.Max(embedded.Image.PixelWidth,embedded.Image.PixelHeight)<=7 && embedded.Width==width && embedded.Height==height,
            "Ordinary-image embedded/thumbnail adapter is bounded and reports native source dimensions");
        var frame=engine.Render(raw,new(),null,32,statistics:false,clipping:false)!;
        check(frame.WhiteBalance!=null && DisplayBytes()==0,"Switching back to RAW releases the display input and restores RAW WB");
        check(Bytes(engine.Render(png,new(),null,0,statistics:false,clipping:false)!.Image).SequenceEqual(rgba),"RAW/raster switching does not retain stale source pixels or WB");
        check(Bytes(engine.Render(tiff,new(),null,0,statistics:false,clipping:false)!.Image).SequenceEqual(rgba),
            "Classic RGB8 TIFF reaches the managed renderer with exact sRGB source values");
        var tiffPreview=RenderEngine.ReadEmbeddedPreview(tiff,7);
        check(tiffPreview.Image!=null && Math.Max(tiffPreview.Image.PixelWidth,tiffPreview.Image.PixelHeight)<=7 &&
            tiffPreview.Width==width && tiffPreview.Height==height,"Classic RGB8 TIFF uses the bounded managed thumbnail adapter");
        var state=new Adjustments{ExposureMode=0,Lens=new(true,true,true),DisplayChromaDenoise=1,
            Hsl=new HslSettings().WithValue(0,2,24),Effects=new(-18,61,12,73,24,11,29,37),
            Geometry=new(.1,.125,.75,.75,1,true,false,2,.03,-.02)};
        state.Set(Parameter.Temperature,4200);state.Set(Parameter.Tint,44);
        var captured=JsonSerializer.Serialize(state.Capture());
        Verify(png,state,null,"edited");Verify(jpeg,new(),null,"jpeg");Verify(tiff,state,null,"tiff");
        check(JsonSerializer.Serialize(state.Capture())==captured,"Raster normalization does not mutate the captured RAW-only settings");
        var store=new EditStore(Path.Combine(output,"edits"));store.Save(png,state.Capture(),null);
        var restored=new EditStore(Path.Combine(output,"edits")).Find(png)!;
        Verify(png,restored.Settings.Restore(),null,"restored");
        var master=new Adjustments();var recipe=MasterRecipe.All.First(value=>value.TintDelta!=0);
        master.ApplyMasterRecipe(recipe);master.ResolveWhiteBalance((2000,-150));
        var journal=new BatchJournal(Path.Combine(output,"batch"));
        var job=BatchJob.Create(raw,master.Capture(),recipe.LutPath,"Mixed");job.Format=ExportFormat.Png;job.LongEdge=64;
        job.OutputDirectory=Path.Combine(output,"batch-output");Directory.CreateDirectory(job.OutputDirectory);
        job.Items=[BatchItem.Create(raw) with{Selected=true},BatchItem.Create(png) with{Selected=true},BatchItem.Create(jpeg) with{Selected=true},BatchItem.Create(tiff) with{Selected=true}];
        journal.FreezeLook(job);journal.Save(job);master.ResetAll();
        BatchRunner.Run(job,journal,false,CancellationToken.None,(_,_)=>{},(input,settings,look,target,edge)=>engine.Render(input,settings,look,0,output:target,longEdge:edge));
        foreach(var item in job.Items)
        {
            check(item.Status==BatchStatus.Succeeded,"Frozen mixed RAW/raster BatchRunner publishes FINAL output");
            var agent=Path.Combine(output,"batch-agent-"+item.Id+".png");var path=Path.Combine(output,"batch-agent-"+item.Id+".json");
            File.WriteAllText(path,engine.AgentRecipe(item.Input,job.Settings.Restore(),job.Look,agent,64));RunCli(path);Compare(item.Output!,agent);
        }
        var dormant=new Adjustments { ExposureMode=0, Lens=new(true,true,true,true,"dormant-profile"), Denoise=DenoiseSettings.Clean,
            Effects=new(-21,62,13,71,22,15,27,39), DisplayChromaDenoise=2,
            Hsl=new HslSettings().WithValue(0,3,17), Geometry=new(.08,.09,.77,.74,1,true,false,2.5,.02,-.03) };
        dormant.ApplyMasterRecipe(recipe);dormant.ResolveWhiteBalance((2000,-150));dormant.Set(Parameter.Temperature,4200);dormant.Set(Parameter.Tint,44);dormant.Set(Parameter.Strength,73);
        var dormantSnapshot=dormant.Capture();
        var rasterSourceJob=BatchJob.Create(png,dormantSnapshot,null,"Raster source");rasterSourceJob.Format=ExportFormat.Png;
        rasterSourceJob.OutputDirectory=Path.Combine(output,"batch-raster-source");Directory.CreateDirectory(rasterSourceJob.OutputDirectory);
        rasterSourceJob.Items=[BatchItem.Create(png) with{Selected=true},BatchItem.Create(raw) with{Selected=true}];
        var rasterSourceJournal=new BatchJournal(Path.Combine(output,"batch-raster-source-journal"));
        var observed=new Dictionary<string,AdjustmentSnapshot>(StringComparer.OrdinalIgnoreCase);
        BatchRunner.Run(rasterSourceJob,rasterSourceJournal,false,CancellationToken.None,(_,_)=>{},(input,state,look,target,edge)=>{
            observed[input]=state.Capture();engine.Render(input,state,look,0,output:target,longEdge:edge);
        });
        var rawKey=Path.GetFullPath(raw);AdjustmentSnapshot? effectiveRaw=null;observed.TryGetValue(rawKey,out effectiveRaw);
        check(effectiveRaw!=null,"Raster-source batch reaches the RAW target");
        if(effectiveRaw is {} rawTargetState)
        {
            check(rawTargetState.ExposureMode==1,"Raster-source batch RAW target uses RAW preview exposure default");
            check(rawTargetState.CameraWhiteBalance,"Raster-source batch RAW target uses as-shot white balance");
            check(rawTargetState.Values[(int)Parameter.Temperature]==6500,"Raster-source batch RAW target resets temperature to RAW default");
            check(rawTargetState.Values[(int)Parameter.Tint]==dormantSnapshot.Values[(int)Parameter.Tint] && rawTargetState.Values[(int)Parameter.Tint]!=0,
                "Raster-source batch RAW target preserves active recipe tint offset");
            check(rawTargetState.Lens==new LensSettings(false,false,false),"Raster-source batch RAW target disables lens correction");
            check(rawTargetState.MasterRecipeID==dormantSnapshot.MasterRecipeID && rawTargetState.Values[(int)Parameter.Strength]==dormantSnapshot.Values[(int)Parameter.Strength],
                "Raster-source batch RAW target preserves recipe identity and strength");
            check(rawTargetState.Denoise==dormantSnapshot.Denoise && rawTargetState.Effects==dormantSnapshot.Effects &&
                rawTargetState.Hsl==dormantSnapshot.Hsl && rawTargetState.Geometry==dormantSnapshot.Geometry &&
                rawTargetState.DisplayChromaDenoise==dormantSnapshot.DisplayChromaDenoise,
                "Raster-source batch RAW target retains common style settings");
        }
        var rasterKey=Path.GetFullPath(png);
        check(observed.TryGetValue(rasterKey,out var rasterTargetState) && rasterTargetState.SameAs(dormantSnapshot),
            "Mixed batch keeps the raster target snapshot unchanged while target normalization remains input-scoped");
        check(dormant.Capture().SameAs(dormantSnapshot),"Batch target normalization does not mutate the frozen source snapshot");
        var batchSettingsHelper=typeof(RenderEngine).GetMethod("PrepareBatchSettings",BindingFlags.Static|BindingFlags.NonPublic);
        check(batchSettingsHelper!=null,"Batch render and target preview share an explicit source/target settings helper");
        if(batchSettingsHelper!=null)
        {
            var previewSettings=(Adjustments)batchSettingsHelper.Invoke(null,[png,raw,dormant])!;
            check(previewSettings.Capture().SameAs(effectiveRaw!),"Batch target preview uses the same effective RAW settings as final render");
        }
        var damaged=Path.Combine(inputs,"damaged.png");File.WriteAllBytes(damaged,[137,80,78,71]);
        var rejected=false;try{engine.Render(damaged,new(),null,32);}catch(InvalidOperationException){rejected=true;}
        check(rejected,"Damaged ordinary input is rejected rather than returning the previous image");
        check(Bytes(engine.Render(png,new(),null,0,statistics:false,clipping:false)!.Image).SequenceEqual(rgba),"A valid source recovers after an ordinary-image decoding failure");
        var large=Path.Combine(inputs,"performance-2048.png");const int largeWidth=2048,largeHeight=1536;
        var largePixels=new byte[largeWidth*largeHeight*3];
        for(var p=0;p<largePixels.Length;p++)largePixels[p]=(byte)((p/3+p/largeWidth)%251);
        var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(BitmapSource.Create(largeWidth,largeHeight,96,96,PixelFormats.Rgb24,null,largePixels,largeWidth*3)));
        using(var file=File.Create(large))encoder.Save(file);
        var timings=new List<double>();var memory=new List<object>();
        for(var i=0;i<6;i++)
        {
            var watch=Stopwatch.StartNew();var adjustment=new Adjustments();adjustment.Set(Parameter.Exposure,i*.1);
            var result=engine.RenderPreview(large,adjustment,null,320,false,false,false);watch.Stop();timings.Add(watch.Elapsed.TotalMilliseconds);
            check(DisplayBytes()==(long)largeWidth*largeHeight*4 && ReferenceEquals(result.Neutral,result.Result) && engine.CachedPreviewBytes<=256L*1024*1024,
                "Repeated ordinary-image adjustment retains one source and bounded single-preview cache");
            using var process=Process.GetCurrentProcess();process.Refresh();
            memory.Add(new{iteration=i,sourceBytes=DisplayBytes(),previewBytes=engine.CachedPreviewBytes,workingSet=process.WorkingSet64,privateBytes=process.PrivateMemorySize64,osPeak=process.PeakWorkingSet64});
        }
        File.WriteAllText(Path.Combine(output,"performance-memory.json"),JsonSerializer.Serialize(new{width=largeWidth,height=largeHeight,timingsMs=timings,memory},new JsonSerializerOptions{WriteIndented=true}));
        Console.WriteLine("Raster 3MP preview timings ms: "+string.Join(",",timings.Select(value=>value.ToString("F2"))));
        check(identities.All(pair=>Hash(pair.Key).SequenceEqual(pair.Value)),"RAW and ordinary-image source bytes remain unchanged");
        engine.Dispose();check(DisplayBytes()==0,"Disposal releases the private display source buffer");
        Console.WriteLine("Raster artifacts: "+output);

        void Save(string path,BitmapEncoder encoder){encoder.Frames.Add(BitmapFrame.Create(bitmap));using var file=File.Create(path);encoder.Save(file);}
        long DisplayBytes(){var property=typeof(RenderEngine).GetProperty("CachedDisplayBytes",BindingFlags.Instance|BindingFlags.NonPublic);check(property!=null,"Display cache exposes an actual bounded allocation counter");return (long)property!.GetValue(engine)!;}
        void Verify(string input,Adjustments settings,string? look,string name)
        {
            var gui=Path.Combine(output,name+"-gui.png");var agent=Path.Combine(output,name+"-agent.png");var path=Path.Combine(output,name+".json");
            var text=engine.AgentRecipe(input,settings,look,agent,64);using var json=JsonDocument.Parse(text);var edits=json.RootElement.GetProperty("edits");
            check(json.RootElement.GetProperty("input").GetProperty("type").GetString()=="raster" && edits.GetProperty("exposure").GetProperty("mode").GetString()=="sensor" &&
                edits.GetProperty("white_balance").GetProperty("mode").GetString()=="none","Raster Agent v4 explicitly excludes RAW exposure and WB");
            var lens=edits.GetProperty("lens_correction");check(!lens.GetProperty("distortion").GetBoolean() && !lens.GetProperty("tca").GetBoolean() && !lens.GetProperty("auto_crop").GetBoolean() &&
                lens.GetProperty("profile_id").ValueKind==JsonValueKind.Null && edits.GetProperty("denoise").GetProperty("raw_level").GetInt32()==0,"Raster Agent v4 disables all RAW-only lens/FBDD requests");
            File.WriteAllText(path,text);RunCli(path);engine.Render(input,settings,look,0,output:gui,longEdge:64);Compare(gui,agent);
        }
        void RunCli(string recipePath)
        {
            var info=new ProcessStartInfo(cli){UseShellExecute=false,RedirectStandardOutput=true,RedirectStandardError=true};
            foreach(var value in new[]{"--recipe",recipePath,"--json"})info.ArgumentList.Add(value);
            using var process=Process.Start(info)!;var stdout=process.StandardOutput.ReadToEndAsync();var stderr=process.StandardError.ReadToEndAsync();
            if(!process.WaitForExit(180000)){process.Kill(true);throw new TimeoutException("Owned raster CLI timed out");}
            Task.WaitAll(stdout,stderr);File.AppendAllText(Path.Combine(output,"cli.log"),stdout.Result+"\n"+stderr.Result+"\n");
            check(process.ExitCode==0,"Shared Windows CLI renders the actual raster/RAW v4 recipe");
        }
        void Compare(string first,string second)
        {
            BitmapSource Read(string path){using var file=File.OpenRead(path);return BitmapFrame.Create(file,BitmapCreateOptions.PreservePixelFormat,BitmapCacheOption.OnLoad);}
            var a=Read(first);var b=Read(second);check(a.Format==PixelFormats.Rgb48 && b.Format==PixelFormats.Rgb48 && a.PixelWidth==b.PixelWidth && a.PixelHeight==b.PixelHeight,"GUI/Agent/Batch outputs retain the same PNG16 format and FINAL dimensions");
            var left=new byte[a.PixelWidth*a.PixelHeight*6];var right=new byte[left.Length];a.CopyPixels(left,a.PixelWidth*6,0);b.CopyPixels(right,b.PixelWidth*6,0);
            check(left.SequenceEqual(right),"Independent GUI/Agent/Batch PNG16 decoded pixels match exactly");
        }
    }
    private static byte[] Bytes(BitmapSource image){var output=new byte[image.PixelWidth*image.PixelHeight*4];new FormatConvertedBitmap(image,PixelFormats.Bgra32,null,0).CopyPixels(output,image.PixelWidth*4,0);return output;}
    private static byte[] Hash(string path){using var file=File.OpenRead(path);return SHA256.HashData(file);}
}
