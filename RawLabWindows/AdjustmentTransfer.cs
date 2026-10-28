using F = RawLab.Windows.AdjustmentField;
using static RawLab.Windows.AdjustmentPayload;

namespace RawLab.Windows;

public sealed record AdjustmentTransferContext(string Identifier,bool IsRaw,
    IReadOnlySet<string>? AvailableLookIDs=null,int DefaultExposureMode=1,bool HasUncommittedDraft=false,Action<LensSettings>? ValidateLens=null,
    (double Temperature,double Tint)? CameraWhiteBalance=null);

public static class AdjustmentTransfer
{
    internal static AdjustmentRecipeContext? Recipe(AdjustmentSnapshot s) => s.MasterRecipeID is {} id ? new(id,s.Values[(int)Parameter.Strength]/100,s.MasterRecipeSettingsVersion) : null;
    public static AdjustmentPayload Capture(AdjustmentScope scope,SavedEdit edit,AdjustmentTransferContext context)
    {
        if(context.HasUncommittedDraft) throw new AdjustmentTransferException(AdjustmentFailure.Draft);
        if(edit.Settings.AIDenoiseEnabled && scope.Kind is "all" or "modified")
            throw new AdjustmentTransferException(AdjustmentFailure.Incompatible,"AI denoise has no transfer field");
        var values=AdjustmentTransferValues.Values(edit,context);
        var defaults=new Adjustments {ExposureMode=context.IsRaw ? context.DefaultExposureMode : 2};
        var neutral=AdjustmentTransferValues.Values(new(edit.Identity,defaults.Capture(),null),context);
        var fields=scope.Kind switch {
            "all"=>AdjustmentFields.All.ToHashSet(),
            "modified"=>AdjustmentFields.Common.Where(f=>!Same(values[f],neutral[f])).ToHashSet(),
            "custom"=>scope.Fields ?? throw new AdjustmentTransferException(AdjustmentFailure.EmptyScope),
            _=>throw new AdjustmentTransferException(AdjustmentFailure.InvalidPayload,"scope")
        };
        return new(new(context.Identifier,context.IsRaw,edit.Settings.Processing.Version,Recipe(edit.Settings)),
            values.Where(p=>fields.Contains(p.Key)).ToDictionary(p=>p.Key,p=>p.Value));
    }
    public static SavedEdit Prepare(AdjustmentPayload payload,SavedEdit target,AdjustmentTransferContext context)
    {
        try { return PrepareChecked(payload,target,context); }
        catch(AdjustmentTransferException) {throw;}
        catch(Exception error) when(error is ArgumentException or System.IO.InvalidDataException) {
            throw new AdjustmentTransferException(AdjustmentFailure.Unrepresentable,error.Message);
        }
    }
    private static SavedEdit PrepareChecked(AdjustmentPayload p,SavedEdit target,AdjustmentTransferContext context)
    {
        if(context.HasUncommittedDraft) throw new AdjustmentTransferException(AdjustmentFailure.Draft);
        p.Validate();var storedTarget=target;
        if(context.IsRaw && context.CameraWhiteBalance is {} calibration) {
            var calibrated=target.Settings.Restore();calibrated.ResolveWhiteBalance(calibration);target=target with {Settings=calibrated.Capture()};
        }
        var s=target.Settings.Copy();var look=target.Look;
        var before=EffectiveNumbers(s);var original=AdjustmentTransferValues.Values(target,context);var fullRecipe=false;
        if(p[F.Look] is {} reference) {
            var kind=Text(reference.GetProperty("kind"))!;var id=Text(reference.GetProperty("id"));
            var lookup=kind switch {"recipe_lut" or "recipe"=>"recipe:"+id,"managed"=>id!,_=>kind+":"+id};
            if(kind!="neutral" && context.AvailableLookIDs?.Contains(lookup)!=true) throw new AdjustmentTransferException(AdjustmentFailure.MissingLook,lookup);
            fullRecipe=kind=="recipe" && p.Fields.IsSupersetOf(AdjustmentFields.DependenciesForRecipe(p.Source.Recipe?.SettingsVersion ?? 3));
            s=s with {MasterRecipeID=fullRecipe ? id : null, MasterRecipeSettingsVersion=fullRecipe ? p.Source.Recipe!.SettingsVersion : 3};
            look=fullRecipe ? "recipe:"+id : kind switch {"neutral"=>null,"recipe" or "recipe_lut"=>"recipe-lut:"+id,"builtin"=>"builtin:"+id,_=>id};
        }
        if(Number(p[F.Strength]) is {} strength) s=AdjustmentTransferValues.SetLogical(s,F.Strength,strength);
        var changed=s.MasterRecipeID!=target.Settings.MasterRecipeID || Scale(s)!=Scale(target.Settings) ||
            s.MasterRecipeSettingsVersion!=target.Settings.MasterRecipeSettingsVersion;
        var fields=AdjustmentTransferValues.NumericFields.Where(f=>f!=F.Strength).Concat(AdjustmentFields.All.Where(f=>f.HslIndex()!=null)).ToArray();
        float Expected(F field) {
            if(Number(p[field]) is not {} value) return before[field];
            if(!changed && context.IsRaw==p.Source.IsRaw && Recipe(target.Settings)==p.Source.Recipe && Same(p[field],original[field])) return before[field];
            return SourceRequest(value,field,p.Source.Recipe);
        }
        foreach(var field in fields) {
            if(Number(p[field]) is {} value) s=fullRecipe
                ? AdjustmentTransferValues.SetLogical(s,field,value) : AssignEffective(s,field,Expected(field),SourceEffective(value,field,p.Source.Recipe));
            else if(changed && EffectiveNumbers(s)[field]!=before[field]) s=AssignEffective(s,field,before[field],
                SourceEffective(AdjustmentTransferValues.Logical(target.Settings,field),field,Recipe(target.Settings)));
        }
        foreach(var field in fields) if(EffectiveNumbers(s)[field]!=Expected(field)) s=AssignEffective(s,field,Expected(field));
        s=AdjustmentTransferWB.Apply(p,target.Settings,s,context,fullRecipe,changed);
        if(Text(p[F.ExposureMode]) is {} mode) {
            if(!context.IsRaw && p.Source.IsRaw && mode!="sensor") throw new AdjustmentTransferException(AdjustmentFailure.Incompatible,F.ExposureMode.ID());
            s=s with {ExposureMode=Array.IndexOf(new[]{"scene","preview","sensor"},mode)};
        }
        s=AdjustmentTransferValues.ApplyObjects(p,s,context);
        s=AdjustmentTransferRefinement.Apply(p,target.Settings,s,fullRecipe);
        foreach(var field in fields) if(EffectiveNumbers(s)[field]!=Expected(field)) throw new AdjustmentTransferException(AdjustmentFailure.Unrepresentable,field.ID());
        var result=new SavedEdit(target.Identity,s,look);
        var actual=AdjustmentTransferValues.Values(result,context);
        return original.All(pair=>Same(pair.Value,actual[pair.Key])) && s.MasterRecipeSettingsVersion==target.Settings.MasterRecipeSettingsVersion ? storedTarget : result;
    }
    internal static double Scale(AdjustmentSnapshot s)=>s.MasterRecipeID==null ? 1 : s.Values[(int)Parameter.Strength]/100;
    public static IReadOnlyDictionary<F,float> EffectiveNumbers(AdjustmentSnapshot s)
    {
        var a=s.Restore();var r=a.Request("",null,0,null);
        var result=new Dictionary<F,float> {[F.Strength]=(float)a[Parameter.Strength]/100,[F.Exposure]=r.ExposureEv,[F.Contrast]=r.Contrast,
            [F.Highlights]=r.Highlights,[F.Shadows]=r.Shadows,[F.SCurve]=(float)Math.Clamp(a[Parameter.ToneCurve]*a.RefinementScale,-100,100)/100,[F.Saturation]=r.Saturation,[F.Sharpening]=r.Sharpening,
            [F.BlackPoint]=(float)a.RenderToneControls.BlackPoint,[F.WhitePoint]=(float)a.RenderToneControls.WhitePoint,[F.Vibrance]=(float)a.RenderToneControls.Vibrance,
            [F.Clarity]=(float)a.RenderAtmosphere.Clarity,[F.Dehaze]=(float)a.RenderAtmosphere.Dehaze};
        var hsl=a.RenderHsl.Values;
        foreach(var field in AdjustmentFields.All) if(field.HslIndex() is {} index) result[field]=(float)hsl[index];
        return result;
    }
    internal static float SourceRequest(double value,F field,AdjustmentRecipeContext? recipe)
        =>(float)SourceEffective(value,field,recipe);
    private static double SourceEffective(double value,F field,AdjustmentRecipeContext? recipe)
    {
        var scale=recipe?.Strength ?? 1;
        if(field.HslIndex()!=null) return Math.Clamp(value*(recipe?.SettingsVersion>=3 ? scale : 1),-100,100);
        if(recipe?.SettingsVersion>=4 && AdjustmentFields.RefinementScalars.Contains(field)) {
            var limit=field==F.SCurve ? 1.0 : 100.0;
            return Math.Clamp(value*scale,-limit,limit);
        }
        return field is F.Contrast or F.Saturation ? 1+(value-1)*scale : value*(AdjustmentTransferValues.Scaled.Contains(field) ? scale : 1);
    }
    private static AdjustmentSnapshot AssignEffective(AdjustmentSnapshot s,F field,float value,double? precise=null)
    {
        var scaled=AdjustmentTransferValues.Scaled.Contains(field) || field.HslIndex()!=null && s.MasterRecipeSettingsVersion>=3 ||
            s.MasterRecipeSettingsVersion>=4 && AdjustmentFields.RefinementScalars.Contains(field);
        var identity=field is F.Contrast or F.Saturation ? 1.0 : 0.0;var scale=Scale(s);
        if(scaled && scale==0 && value!=identity) throw new AdjustmentTransferException(AdjustmentFailure.Unrepresentable,field.ID());
        if(precise is {} exact) {
            var preferred=AdjustmentTransferValues.SetLogical(s,field,!scaled ? exact : scale==0 ? identity : identity+(exact-identity)/scale);
            if(EffectiveNumbers(preferred)[field]==value)return preferred;
        }
        var logical=!scaled ? value : scale==0 ? identity : identity+(value-identity)/scale;
        var candidate=AdjustmentTransferValues.SetLogical(s,field,logical);
        if(EffectiveNumbers(candidate)[field]==value) return candidate;
        // Windows 在百分比运算中间转为 Float；尝试相邻请求桶，最终仍以真实 request 完全相等为准。
        var native=field.HslIndex()!=null || AdjustmentTransferValues.ToneFields.ContainsKey(field) || AdjustmentTransferValues.AtmosphereFields.ContainsKey(field)
            ? logical : candidate.Values[(int)AdjustmentTransferValues.Scalars[field]];
        foreach(var neighbor in new[]{Math.BitDecrement(native),Math.BitIncrement(native),(double)MathF.BitDecrement((float)native),(double)MathF.BitIncrement((float)native)}) {
            try {
                var alternative=field.HslIndex() is {} index ? candidate with {Hsl=(candidate.Hsl ?? new()).WithValue(index/8,index%8,neighbor)} : NativeValue(candidate,field,neighbor);
                if(EffectiveNumbers(alternative)[field]==value) return alternative;
            } catch(ArgumentException) { }
        }
        throw new AdjustmentTransferException(AdjustmentFailure.Unrepresentable,field.ID());
    }
    private static AdjustmentSnapshot NativeValue(AdjustmentSnapshot s,F field,double value)
    {
        if(AdjustmentTransferValues.ToneFields.ContainsKey(field) || AdjustmentTransferValues.AtmosphereFields.ContainsKey(field))return AdjustmentTransferValues.SetLogical(s,field,value);
        var values=(double[])s.Values.Clone(); values[(int)AdjustmentTransferValues.Scalars[field]]=value;
        var result=s with {Values=values};_=result.Restore();return result;
    }
}
