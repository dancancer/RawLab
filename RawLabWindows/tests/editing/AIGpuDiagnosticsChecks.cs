using System.IO.Compression;
using System.Text.Json;
using RawLab.Windows;

internal static class AIGpuDiagnosticsChecks
{
    internal static void Run()
    {
        var root=Path.Combine(Path.GetTempPath(),"rawlab-ai-support-"+Guid.NewGuid());
        Directory.CreateDirectory(root);
        void Check(bool value,string message){if(!value)throw new Exception(message);}
        try {
            var preferences=new AIGpuPreferenceStore(Path.Combine(root,"gpu.json"));
            Check(preferences.Read().DeviceID=="","New users did not default to Auto");
            preferences.Save(new("pnp:3060","NVIDIA GeForce RTX 3060 Ti"));
            Check(new AIGpuPreferenceStore(preferences.PathName).Read().DeviceID=="pnp:3060","GPU choice did not survive restart");
            File.WriteAllText(preferences.PathName,"corrupt");
            Check(preferences.Read().DeviceID=="","Corrupt GPU preference prevented startup");
            File.WriteAllText(preferences.PathName,"null");
            Check(preferences.Read().DeviceID=="","Null GPU preference prevented startup");
            var inventory=AIDeviceInventory.Parse("""
                {"version":1,"recommended_id":"gpu-b","devices":[
                 {"id":"gpu-a","name":"Intel UHD 770","available":true,"integrated":true},
                 {"id":"gpu-b","name":"RTX 3060 Ti","available":true,"integrated":false}]}
                """);
            Check(inventory.IsAvailable("") && inventory.IsAvailable("gpu-a") && !inventory.IsAvailable("removed"),
                "Manual missing device was silently replaced by Auto");
            Check(inventory.EffectiveID("")=="gpu-b" && inventory.EffectiveID("gpu-a")=="gpu-a","Requested GPU was not resolved correctly");
            var ambiguous=AIDeviceInventory.Parse("""{"version":1,"recommended_id":"same","devices":[{"id":"same","available":true},{"id":"same","available":true}]}""");
            Check(ambiguous.IsAvailable("") && !ambiguous.IsAvailable("same"),"Auto selection was blocked by an ambiguous manual identity");
            var store=new AIDiagnosticStore(Path.Combine(root,"reports"),maxReports:3);
            var source=Path.Combine(root,"source.arw");File.WriteAllText(source,"fixture");
            var settings=new Adjustments();
            var gpuA=AIDenoiseIdentity.Read(source,settings,2,"gpu-a");
            var gpuB=AIDenoiseIdentity.Read(source,settings,2,"gpu-b");
            Check(gpuA!=gpuB,"Changing AI GPU reused a different device's job identity");
            var batch=BatchJob.Create(source,settings.Capture(),null,"neutral");batch.AIDeviceID="gpu-b";
            var restored=JsonSerializer.Deserialize<BatchJob>(JsonSerializer.Serialize(batch.Copy()))!;
            restored.Validate();Check(restored.AIDeviceID=="gpu-b","Frozen batch lost the GPU selection on copy/restart");
            const string photo=@"D:\Private Photos\客户照片.ARW";
            var error=new InvalidOperationException("GPU failed 0x887A0001 while processing "+photo);
            var context=new AIDiagnosticContext("prepare","gpu-b",3,photo,NativeStatus:6,
                NativeDetails:"DmlFusedNode_0_0 887A0001",
                NativeDiagnostics:"""{"version":1,"logs":[{"severity":3,"category":"DirectML","message":"Invalid GPU call"}]}""",
                Devices:inventory.JSON);
            var report=store.Capture(error,context);
            Check(report!=null && File.Exists(report),"AI failure was not saved automatically");
            var text=File.ReadAllText(report!);
            Check(!text.Contains("Private Photos") && !text.Contains("客户照片") && text.Contains("887A0001"),
                "Diagnostic report leaked a source path or lost its error code");
            Check(store.Capture(error,context)==report && Directory.GetFiles(store.DirectoryPath,"*.json").Length==1,
                "The same exception generated duplicate reports");
            var zip=Path.Combine(root,"report.zip");store.Export(report!,zip);
            using(var archive=ZipFile.OpenRead(zip)) {
                Check(archive.GetEntry("diagnostic.json")!=null && archive.GetEntry("runtime.log")!=null,
                    "Export bundle omitted the diagnostic snapshot or runtime log");
                using var reader=new StreamReader(archive.GetEntry("runtime.log")!.Open());
                Check(reader.ReadToEnd().Contains("Invalid GPU call"),"Runtime messages were not exported");
                Check(archive.Entries.Count==3,"Export included unexpected files or photo data");
            }
            Check(store.Capture(new OperationCanceledException(),context)==null,"Cancellation generated a failure report");
            var failedJob=new AIDenoiseJob((_,_,_)=>throw new Exception("job GPU failure"),
                (failure,identity)=>store.Capture(failure,context with {InputPath=identity.Source.Path}));
            failedJob.StartAsync(gpuB,settings).GetAwaiter().GetResult();
            Check(failedJob.State.Status==AIDenoiseStatus.Failed && failedJob.State.DiagnosticPath!=null,
                "AI failure state lost the automatically captured report");
            for(var i=0;i<6;i++)store.Capture(new Exception("failure "+i),context);
            Check(Directory.GetFiles(store.DirectoryPath,"*.json").Length==3 && store.Latest()!=null,"Diagnostic retention was unbounded");
            var blocked=Path.Combine(root,"not-a-directory");File.WriteAllText(blocked,"keep");
            var failed=new Exception("original GPU failure");
            Check(new AIDiagnosticStore(blocked).Capture(failed,context)==null && failed.Message=="original GPU failure" &&
                  AIDiagnosticStore.SaveFailed(failed),"Diagnostic IO failure masked the original exception");
            var badJson=store.Capture(new Exception("native parse failure"),context with {NativeDiagnostics="invalid json"});
            Check(badJson!=null && JsonDocument.Parse(File.ReadAllText(badJson)).RootElement.GetProperty("version").GetInt32()==1,
                "Malformed native diagnostic JSON prevented error capture");
            var foreign=store.Capture(new Exception("at /Users/Private Person/repo/test.cs:line 3"),context with {
                NativeDetails=@"E:\work\private\provider.cpp: Failure 0x887A0001",NativeDiagnostics="[]"});
            store.Export(foreign!,Path.Combine(root,"foreign.zip"));
            var cleaned=File.ReadAllText(foreign!);
            Check(!cleaned.Contains("Private Person") && cleaned.Contains("0x887A0001"),"Path redaction leaked a build path or erased HRESULT evidence");
            Console.WriteLine("PASS AI GPU preference, failure capture, redaction, export and retention");
        } finally {Directory.Delete(root,true);}
    }
}
