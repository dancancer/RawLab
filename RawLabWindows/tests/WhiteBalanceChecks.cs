using System.IO;
using RawLab.Windows;

internal static class WhiteBalanceChecks
{
    internal static void RecipeCache(string repo,string raw,Action<bool,string> check)
    {
        var directory=Path.Combine(repo,"build","recipe-camera-wb",Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var source=Path.Combine(directory,Path.GetFileName(raw));
        File.Copy(raw,source);
        try
        {
            using var engine=new RenderEngine(0,appPaths:AppPaths.CreateIsolated(directory));
            using var cancellation=new CancellationTokenSource();
            engine.SetCancellation(cancellation.Token);
            var session=engine.Session;
            Adjustments Resolve(Adjustments settings)=>engine.PrepareRecipe(source,settings).Settings;
            var polls=0;
            Native.CancellationCallback countCalls=_=>{Interlocked.Increment(ref polls);return 0;};
            // Replacing the RAW may recreate the native session. Keep the observer registered through that path.
            engine.CancellationCallback=countCalls;
            Native.Check(Native.sony2fuji_session_set_cancellation_callback(session,countCalls,IntPtr.Zero), session);
            var recipe=new Adjustments();recipe.ApplyMasterRecipe(MasterRecipe.All[0]);
            recipe.Set(Parameter.Strength,100);recipe.Set(Parameter.Tint,10);
            var firstPrepared=engine.PrepareRecipe(source,recipe);
            var first=firstPrepared.Settings;
            check(polls>0 && first.AsShot!=null,"First recipe reads the target RAW camera white balance with the native probe");
            polls=0;
            recipe.Set(Parameter.Exposure,.5);recipe.Set(Parameter.Tint,-15);recipe.Set(Parameter.Strength,50);
            var editedPrepared=engine.PrepareRecipe(source,recipe);
            var edited=editedPrepared.Settings;
            check(polls==0 && edited.AsShot==first.AsShot &&
                editedPrepared.Request(source,null,640,null).Tint!=firstPrepared.Request(source,null,640,null).Tint,
                "Edits reuse the target camera calibration without a native probe and apply the new recipe offset");
            recipe.ExposureMode=recipe.ExposureMode==0 ? 1 : 0;
            check(Resolve(recipe).AsShot!=null && polls>0,"A change of RAW exposure mode refreshes the calibration");
            polls=0;
            File.SetLastWriteTimeUtc(source,File.GetLastWriteTimeUtc(source).AddSeconds(4));
            check(Resolve(recipe).AsShot!=null && polls>0,"A changed RAW identity refreshes the calibration");
            var x3fSource=Path.Combine(directory,"normal-recipe.X3F");
            File.WriteAllBytes(x3fSource,[(byte)'F',(byte)'O',(byte)'V',(byte)'b',0,0,0,0]);
            var x3fRecipe=new Adjustments{X3fMode=X3fMode.Normal};
            x3fRecipe.ApplyMasterRecipe(MasterRecipe.All[0]);
            x3fRecipe.Set(Parameter.Tint,20);
            x3fRecipe.Set(Parameter.Strength,50);
            polls=0;
            var x3fPrepared=engine.PrepareRecipe(x3fSource,x3fRecipe);
            var x3fRequest=x3fPrepared.Request(x3fSource,null,640,null);
            check(polls==0 && x3fPrepared.Settings.AsShot is {Temperature:6500,Tint:0} &&
                x3fRequest is {WbMode:3,Temperature:6500f,Tint:10f},
                "Normal X3F recipe resolves to core WB (3, 6500, 10) with zero decode probes");
            var lut=recipe.Recipe!.LutPath;
            var original=engine.RenderPreview(source,recipe,lut,384,false,false,false).Result;
            recipe.Set(Parameter.Exposure,1.5);
            var updated=engine.RenderPreview(source,recipe,lut,640,false,false,false).Result;
            using var fresh=new RenderEngine(0);
            var expected=fresh.RenderPreview(source,recipe,lut,640,false,false,false).Result;
            check(original.WhiteBalance!=null && original.WhiteBalance==updated.WhiteBalance &&
                updated.WhiteBalance==expected.WhiteBalance && updated.Histogram.SequenceEqual(expected.Histogram),
                "Real recipe previews use the same camera calibration and output as a fresh render across edits and sizes");
            var cold=new Adjustments();cold.ApplyMasterRecipe(MasterRecipe.All[0]);
            cold.Set(Parameter.Tint,7);cold.Set(Parameter.Strength,75);
            var coldFrame=engine.RenderPreview(source,cold,lut,384,false,false,false);
            var resolvedCold=cold.Clone();
            resolvedCold.ResolveWhiteBalance(coldFrame.Result.WhiteBalance!.Value);
            var warmFrame=engine.RenderPreview(source,resolvedCold,lut,384,false,false,false);
            check(ReferenceEquals(coldFrame,warmFrame),
                "RenderPreview cache key matches after ResolveWhiteBalance updates caller metadata");
            var custom6500=cold.Clone();
            custom6500.Set(Parameter.Temperature,6500);
            var custom6500Frame=engine.RenderPreview(source,custom6500,lut,384,false,false,false);
            if(Math.Round(coldFrame.Result.WhiteBalance!.Value.Temperature)!=6500)
                check(!ReferenceEquals(coldFrame,custom6500Frame),
                    "Cold recipe PreviewKey uses core camera temperature instead of colliding on uncalibrated 6500K");
        }
        finally { Directory.Delete(directory,true); }
    }

    private static (double Temperature,double Tint) RoundWb(float temperature,float tint) =>
        (Math.Round(temperature,MidpointRounding.AwayFromZero),Math.Round(tint,MidpointRounding.AwayFromZero));

    internal static void Run(Action<bool,string> check)
    {
        foreach(var sample in new[] {
            (Temperature:5000.5f,Tint:12.5f,Offset:5.0,Strength:100.0,CameraTemperature:5001.0,CameraTint:13.0,RequestTint:18.0f),
            (Temperature:5000.5f,Tint:-12.5f,Offset:-5.0,Strength:150.0,CameraTemperature:5001.0,CameraTint:-13.0,RequestTint:-20.5f),
            (Temperature:5000.5f,Tint:12.5f,Offset:5.0,Strength:50.0,CameraTemperature:5001.0,CameraTint:13.0,RequestTint:15.5f),
            (Temperature:5000.25f,Tint:12.25f,Offset:5.0,Strength:50.0,CameraTemperature:5000.0,CameraTint:12.0,RequestTint:14.5f),
            (Temperature:5000.75f,Tint:-12.75f,Offset:5.0,Strength:50.0,CameraTemperature:5001.0,CameraTint:-13.0,RequestTint:-10.5f)
        })
        {
            var camera=RoundWb(sample.Temperature,sample.Tint);
            var settings=new Adjustments();
            settings.ApplyMasterRecipe(MasterRecipe.All[0]);
            settings.Set(Parameter.Tint,sample.Offset);
            settings.Set(Parameter.Strength,sample.Strength);
            settings.ResolveWhiteBalance(camera);
            var request=settings.Request("target.ARW",null,32,null);
            check(request.WbMode==3 && request.Temperature==sample.CameraTemperature && request.Tint==sample.RequestTint,
                $"Camera tint {sample.Tint}, offset {sample.Offset}, strength {sample.Strength}% requests {sample.RequestTint}; actual {request.Tint}");
            check(camera==(sample.CameraTemperature,sample.CameraTint),"Camera Kelvin/tint integers match the macOS baseline");

            var ordinary=new Adjustments();ordinary.ResolveWhiteBalance(camera);
            check(ordinary[Parameter.Temperature]==sample.CameraTemperature && ordinary[Parameter.Tint]==sample.CameraTint &&
                  NumericRange.For(ParameterSpec.All[(int)Parameter.Temperature]).Format(ordinary[Parameter.Temperature])==sample.CameraTemperature.ToString(),
                "Display settings retain camera integers without snapping Kelvin to the slider grid");
            check(ordinary.Request("target.ARW",null,32,null).WbMode==0,"Ordinary camera WB retains original gains");
            var exported=settings.Capture().Restore().Request("target.ARW",null,0,"output.png");
            check(exported.WbMode==3 && exported.Temperature==sample.CameraTemperature && exported.Tint==sample.RequestTint,
                "Frozen export request keeps the same WB and fractional recipe result");
            settings.Set(Parameter.Strength,0);
            check(settings.Request("target.ARW",null,32,null).WbMode==0,"Zero recipe strength retains original camera gains");
            settings.Set(Parameter.Strength,100);settings.Set(Parameter.Tint,0);
            check(settings.Request("target.ARW",null,32,null).WbMode==0,"Zero recipe offset retains original camera gains");
        }
        var mismatched=new Adjustments();
        mismatched.ApplyMasterRecipe(MasterRecipe.All[0]);
        mismatched.ResolveWhiteBalance((3200.0,-40.0));
        mismatched.Set(Parameter.Tint,20.0);
        mismatched.Set(Parameter.Strength,50.0);
        var direct=new PreparedRecipeSettings(mismatched,new ResolvedNativeWhiteBalance(3,5600f,17.5f))
            .Request("target.ARW",null,32,null);
        check(direct is {WbMode:3,Temperature:5600f,Tint:17.5f},
            "PreparedRecipeSettings writes core-resolved WB directly without C# recipe-tint recomputation");
        var customMismatched=mismatched.Clone();
        customMismatched.Set(Parameter.Temperature,8000.0);
        var cameraDirect=new PreparedRecipeSettings(customMismatched,new ResolvedNativeWhiteBalance(0,8000f,25f))
            .Request("target.ARW",null,32,null);
        check(cameraDirect is {WbMode:0,Temperature:6500f,Tint:0f},
            "PreparedRecipeSettings normalizes camera WB mode directly without C# temperature/tint leakage");
        CheckPersistence(check);
    }

    private static void CheckPersistence(Action<bool,string> check)
    {
        var root=Path.Combine(Path.GetTempPath(),"rawlab-wb-"+Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var input=Path.Combine(root,"input.ARW");File.WriteAllText(input,"identity only");
            var store=new EditStore(root);
            var settings=new Adjustments();settings.ResolveWhiteBalance(RoundWb(5000.5f,12.5f));
            store.Save(input,settings.Capture(),null);
            var saved=new EditStore(root).Find(input)!.Settings;
            check(saved.AsShotTemperature==5001 && saved.AsShotTint==13 && saved.Values[2]==5001 && saved.Values[3]==13,
                "New edit records persist the converted camera integers");

            var legacy=new Adjustments();legacy.ResolveWhiteBalance((5000,12));
            foreach(var custom in new[]{false,true})
            {
                if(custom)legacy.Set(Parameter.Tint,17);
                store.Save(input,legacy.Capture(),null);
                var path=Path.Combine(root,"edits.json");var before=File.ReadAllBytes(path);
                var restored=new EditStore(root).Find(input)!.Settings.Restore();
                check(restored.AsShot==(5000,12) && restored[Parameter.Temperature]==5000 && restored[Parameter.Tint]==(custom ? 17 : 12),
                    "Existing Windows camera metadata and explicit WB load without migration");
                restored.ResolveWhiteBalance(RoundWb(5000.5f,12.5f));
                var request=restored.Request(input,null,32,null);
                check(custom ? request is {WbMode:3,Temperature:5000,Tint:17} : request.WbMode==0 && restored.AsShot==(5001,13),
                    "Fresh camera metadata preserves explicit edits and original-gain camera mode");
                check(before.SequenceEqual(File.ReadAllBytes(path)),"Reading and resolving WB never silently rewrites stored records");
            }
            foreach(var custom in new[]{false,true})
            {
                var recipe=new Adjustments();recipe.ApplyMasterRecipe(MasterRecipe.All[0]);
                recipe.ResolveWhiteBalance((5000,12));recipe.Set(Parameter.Tint,5);
                if(custom)recipe.Set(Parameter.Temperature,4500);
                var job=BatchJob.Create(input,recipe.Capture(),null,"WB rounding");
                var journal=new BatchJournal(Path.Combine(root,"batch"));journal.Save(job);
                var path=Path.Combine(journal.DirectoryPath,"job.json");var before=File.ReadAllBytes(path);
                var frozen=journal.Load()!.Settings;
                var target=frozen.Restore();target.ResolveWhiteBalance(RoundWb(5000.5f,12.5f));
                var request=target.Request(input,null,0,"output.png");
                check(request.WbMode==3 && request.Temperature==(custom ? 4500 : 5001) && request.Tint==18,
                    "Legacy frozen recipe uses fresh target camera tint and preserves explicit temperature");
                check(frozen.AsShotTemperature==5000 && frozen.AsShotTint==12 && before.SequenceEqual(File.ReadAllBytes(path)),
                    "Target WB resolution does not migrate or mutate the frozen batch record");
            }
        }
        finally { Directory.Delete(root,true); }
    }
}
