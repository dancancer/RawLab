using RawLab.Windows;
using System.Text.Json;
using F = RawLab.Windows.AdjustmentField;
using static RawLab.Windows.AdjustmentPayload;

internal static class AdjustmentTransferChecks
{
    internal static void Run()
    {
        var context = new AdjustmentTransferContext("source", true);
        var identity = new OriginalIdentity("photo.arw", 1, 2, 3);
        var settings = new Adjustments(); settings.Set(Parameter.Exposure, 1.25);
        var source = new SavedEdit(identity, settings.Capture(), null);
        var payload = AdjustmentTransfer.Capture(AdjustmentScope.Standard, source, context);
        if (payload.Fields.Any(x => x.Group() == "geometry")) throw new Exception("Default excludes geometry");
        var frozen = AdjustmentPayload.Parse(payload.ToJson());
        settings.Set(Parameter.Exposure, 2);
        var target = new SavedEdit(identity, new Adjustments { Processing = ProcessingIdentity.Legacy }.Capture(), null);
        var candidate = AdjustmentTransfer.Prepare(frozen, target, context);
        if (candidate.Settings.Restore()[Parameter.Exposure] != 1.25 || candidate.Settings.Processing != ProcessingIdentity.Legacy)
            throw new Exception("Frozen logical values preserve target processing");
        Console.WriteLine("PASS: Windows selective payload capture, frozen JSON and processing provenance");
        Vectors(); AdapterChecks();
    }
    private static void Check(bool condition,string message) {if(!condition)throw new Exception(message);}
    private static void Reject(Action action,string message)
    {try {action();}catch(AdjustmentTransferException){return;}throw new Exception(message);}
    private static readonly OriginalIdentity Identity=new("test.arw",1,2,3);
    private static readonly AdjustmentTransferContext Context=new("source",true);
    private static SavedEdit Edit(Adjustments? value=null,string? look=null)=>new(Identity,(value ?? new()).Capture(),look);
    private static AdjustmentPayload Payload(params (F Field,object? Value)[] values)=>new(new("source",true,2),values.ToDictionary(p=>p.Field,p=>Value(p.Value)));
    private static SavedEdit Prepare(AdjustmentPayload payload,Adjustments? target=null,AdjustmentTransferContext? context=null)=>AdjustmentTransfer.Prepare(payload,Edit(target),context ?? Context);
    private static AdjustmentPayload Copy(Adjustments source,params F[] fields)=>AdjustmentTransfer.Capture(AdjustmentScope.Custom(fields),Edit(source),Context);
    private static void Vectors()
    {
        using var document=JsonDocument.Parse(File.ReadAllText("Shared/fixtures/adjustment-transfer-v1.json"));
        var count=0;
        foreach(var vector in document.RootElement.GetProperty("vectors").EnumerateArray()) {
            var json=vector.GetProperty("payload").GetRawText();var id=vector.GetProperty("id").GetString();
            if(!vector.GetProperty("valid").GetBoolean()) {Reject(()=>AdjustmentPayload.Parse(json),"accepted invalid vector "+id);count++;continue;}
            var payload=AdjustmentPayload.Parse(json);_=AdjustmentPayload.Parse(payload.ToJson());
            if(vector.TryGetProperty("neutral_effective",out var expected)) {
                var actual=AdjustmentTransfer.EffectiveNumbers(Prepare(payload).Settings);
                foreach(var field in expected.EnumerateObject())Check(actual[AdjustmentFields.Parse(field.Name)]==(float)field.Value.GetDouble(),"native request mismatch "+id+" "+field.Name);
            }
            count++;
        }
        Check(AdjustmentFields.All.Count==72,"stable field catalog");
        Console.WriteLine($"PASS: {count} shared payload vectors and native request equality");
    }
    private static void AdapterChecks()
    {
        Check(Prepare(Payload((F.Exposure,1.2))).Settings.Values[1]==1.2,"Selected decimal exposure keeps its logical Double value");
        Check(Prepare(Payload((F.HslHueRed,13.15))).Settings.Hsl!.Value(0,0)==13.15,"Selected decimal HSL keeps its logical Double value");
        var recipe=MasterRecipe.All[0];var source=new Adjustments();source.ApplyMasterRecipe(recipe);source.Set(Parameter.Strength,50);
        source.Set(Parameter.Exposure,1.4);source.Hsl=source.Hsl.WithValue(0,0,12.375);
        var context=Context with {AvailableLookIDs=new HashSet<string>{"recipe:"+recipe.Id}};
        var selected=Copy(source,F.Exposure,F.HslHueRed);
        var result=Prepare(selected);
        Check(AdjustmentTransfer.EffectiveNumbers(result.Settings)[F.Exposure]==.7f,"recipe contribution applied once");
        Check(result.Settings.Hsl!.Value(0,0)==6.1875,"fractional HSL preserved");
        var defaults=new Adjustments();defaults.ResolveWhiteBalance((5100,11));
        var all=AdjustmentTransfer.Capture(AdjustmentScope.All,Edit(source),context);
        var retained=Prepare(all,defaults,context);
        Check(retained.Settings.MasterRecipeID==recipe.Id && retained.Settings.AsShotTint==11,"complete recipe retains target calibration");
        var legacyValues=all.Values.ToDictionary(p=>p.Key,p=>p.Value);legacyValues[F.HslHueRed]=Value(37.25);
        var legacy=new AdjustmentPayload(all.Source with {Recipe=all.Source.Recipe! with {SettingsVersion=2}},legacyValues);
        var legacyResult=Prepare(legacy,defaults,context);
        Check(legacyResult.Settings.MasterRecipeID==recipe.Id && AdjustmentTransfer.EffectiveNumbers(legacyResult.Settings)[F.HslHueRed]==37.25f,
            "Full legacy HSL is inversely represented in the current Windows renderer");
        Check(AdjustmentTransfer.Capture(AdjustmentScope.All,legacyResult,context).Source.Recipe!.SettingsVersion==3,
            "Recapture describes the current target representation rather than false legacy provenance");
        var partial=Prepare(Copy(source,F.Look),defaults,context);
        Check(partial.Settings.MasterRecipeID==null && partial.Look=="recipe-lut:"+recipe.Id,"partial recipe look becomes independent LUT");
        source.Set(Parameter.Strength,0);
        var modified=AdjustmentTransfer.Capture(AdjustmentScope.Modified,Edit(source),context);
        Check(modified.Fields.Contains(F.Exposure),"zero strength does not hide logical edits");
        Reject(()=>Prepare(Payload((F.Exposure,1.0)),source),"zero-scale target cannot represent selected exposure");
        var target=new Adjustments();target.ApplyMasterRecipe(recipe);target.ResolveWhiteBalance((5100,11));target.Set(Parameter.Strength,50);
        target.Set(Parameter.Exposure,1.234);target.Set(Parameter.Contrast,17.789);
        var before=AdjustmentTransfer.EffectiveNumbers(target.Capture());
        var strength=Prepare(Payload((F.Strength,1.0)),target).Settings;
        var after=AdjustmentTransfer.EffectiveNumbers(strength);
        foreach(var field in before.Keys.Where(f=>f!=F.Strength))Check(before[field]==after[field],"strength preserves unselected "+field);
        Check(strength.CameraWhiteBalance==target.CameraWhiteBalance,"strength retains unselected camera WB mode when recipe can represent it");
        var self=AdjustmentTransfer.Capture(AdjustmentScope.All,Edit(target),context);
        Check(Prepare(self,target,context).Settings.SameAs(target.Capture()),"same full recipe is exactly unchanged");
        Reject(()=>Prepare(Payload((F.CropX,.2))),"partial crop cannot silently shrink unselected width");
        Reject(()=>Prepare(Payload((F.Exposure,5.0))),"native exposure range is narrower than payload");
        Reject(()=>Prepare(Payload((F.RawDenoise,1))),"FBDD is unsupported");
        Reject(()=>Prepare(Payload((F.PostRGBDenoise,.1))),"post RGB is unsupported");
        Reject(()=>Prepare(Payload((F.LensDistortion,true))),"lens enabled requires target calibration");
        var lensValidated=false;var lens=Prepare(Payload((F.LensDistortion,true)),context:Context with {ValidateLens=l=>lensValidated=l.Distortion});
        Check(lensValidated && lens.Settings.Lens!.Distortion,"lens validator called");
        Reject(()=>Prepare(Payload((F.LensProfile,"test-profile")),context:Context with {IsRaw=false}),"raster rejects disabled explicit lens profile");
        var manualLens=new Adjustments {Lens=new LensSettings(Manual:true)};
        foreach(var scope in new[]{AdjustmentScope.All,AdjustmentScope.Custom(new[]{F.LensProfile})}) {
            var copied=AdjustmentTransfer.Capture(scope,Edit(manualLens),Context);
            Check(Text(copied[F.LensProfile])==manualLens.Lens.CoreProfileId,"manual lens uses reserved transport");
            var applied=Prepare(AdjustmentPayload.Parse(copied.ToJson()));
            Check(applied.Settings.Lens!.Manual && applied.Settings.Lens.ProfileId==null,"manual lens preserves nil profile after round-trip");
        }
        var standardManual=AdjustmentTransfer.Capture(AdjustmentScope.Standard,Edit(manualLens),Context);
        Check(standardManual.Fields.All(f=>!AdjustmentFields.Lens.Contains(f)),"default scope excludes manual lens selection");
        var enabledManual=new Adjustments {Lens=new LensSettings(Distortion:true,Manual:true)};
        var enabledPayload=Copy(enabledManual,F.LensDistortion,F.LensProfile);var validatorCalled=false;
        Reject(()=>Prepare(enabledPayload,context:Context with {ValidateLens=_=>validatorCalled=true}),"enabled manual lens without profile rejects");
        Check(!validatorCalled,"missing manual profile rejects before target validation");
        Reject(()=>Prepare(Payload((F.Temperature,5500))),"partial temperature cannot implicitly change camera mode");
        var wb=Prepare(Payload((F.WhiteBalanceMode,"temperature"),(F.Temperature,5500),(F.Tint,15)),defaults);
        Check(!wb.Settings.CameraWhiteBalance && wb.Settings.AsShotTemperature==5100 && wb.Settings.Values[2]==5500 && wb.Settings.Values[3]==15,"fixed WB keeps target calibration");
        var fractionalWB=Prepare(Payload((F.WhiteBalanceMode,"temperature"),(F.Temperature,5500.5),(F.Tint,1.2)),defaults);
        Check(fractionalWB.Settings.Values[2]==5500.5 && fractionalWB.Settings.Values[3]==1.2,"Fixed WB preserves exact selected decimal values when native requests match");
        Reject(()=>Prepare(Payload((F.WhiteBalanceMode,"camera"),(F.Temperature,null),(F.Tint,null)),context:Context with {IsRaw=false}),"RAW WB on raster blocked");
        var ai=new Adjustments{AIDenoiseEnabled=true,Denoise=DenoiseSettings.Clean};
        Reject(()=>AdjustmentTransfer.Capture(AdjustmentScope.All,Edit(ai),Context),"AI all capture blocked");
        Reject(()=>AdjustmentTransfer.Capture(AdjustmentScope.Modified,Edit(ai),Context),"AI modified capture blocked");
        Check(Copy(ai,F.Exposure).Fields.Count==1,"AI custom ordinary field allowed");
        Reject(()=>Prepare(Payload((F.ChromaDenoise,1)),ai),"ordinary denoise target AI blocked");
        Check(Prepare(Payload((F.Exposure,1)),ai).Settings.AIDenoiseEnabled,"other fields preserve AI");
        Console.WriteLine("PASS: Windows recipe, partial fields, WB, lens, denoise and AI transfer boundaries");
    }
}
