using F = RawLab.Windows.AdjustmentField;
using static RawLab.Windows.AdjustmentPayload;

namespace RawLab.Windows;

// Q3/Q4 粘贴提示：本平台不支持的键收到非 0 值时忽略并提示；处理版本与来源不同
// 时沿用目标处理版本并提示。两种情况都不拒绝粘贴，也不改动目标的其它字段。
public enum AdjustmentTransferNotice
{
    IgnoredRawDenoise,
    IgnoredPostRGBDenoise,
    RetainedTargetProcessingVersion
}

public static class AdjustmentTransferNoticeExtensions
{
    // 共享场景 fixture（adjustment-transfer-scenarios-v1.json expect.notices）的稳定标识。
    public static string FixtureId(this AdjustmentTransferNotice notice) => notice switch
    {
        AdjustmentTransferNotice.IgnoredRawDenoise => "ignored_raw_denoise",
        AdjustmentTransferNotice.IgnoredPostRGBDenoise => "ignored_post_rgb_denoise",
        AdjustmentTransferNotice.RetainedTargetProcessingVersion => "retained_target_processing_version",
        _ => throw new ArgumentOutOfRangeException(nameof(notice))
    };

    // 文案键登记在 Shared/strings；同一次粘贴把去重后的提示合并为一条一次性提示。
    public static string PromptKey(this AdjustmentTransferNotice notice)=>notice switch
    {
        AdjustmentTransferNotice.IgnoredRawDenoise=>"已忽略旧版 RAW 降噪（FBDD）",
        AdjustmentTransferNotice.IgnoredPostRGBDenoise=>"已忽略渲染后 RGB 降噪",
        _=>"处理版本与来源不同，已沿用当前照片的处理版本"
    };
}

public static class AdjustmentPasteNoticeDisplay
{
    public static bool ShowsInDialog(IReadOnlyList<AdjustmentTransferNotice> notices, bool hasPasteResults) =>
        hasPasteResults && notices != null && notices.Count > 0;
}

public enum AdjustmentTransferNoticeOrigin { Dialog, QuickPreset }

public readonly record struct AdjustmentTransferNoticeState(
    IReadOnlyList<AdjustmentTransferNotice> Notices,
    AdjustmentTransferNoticeOrigin Origin = AdjustmentTransferNoticeOrigin.QuickPreset,
    bool AwaitsSettledRender = false,
    long OpenRevision = 0,
    long EditRevision = 0)
{
    public static readonly AdjustmentTransferNoticeState Empty = new([]);

    public IReadOnlyList<AdjustmentTransferNotice> ActiveNotices => Notices ?? [];
    public bool HasNotices => ActiveNotices.Count > 0;
    public bool HasPendingRenderNotice => HasNotices && AwaitsSettledRender;

    public static AdjustmentTransferNoticeState Prepare(
        IReadOnlyList<AdjustmentTransferNotice> notices,
        AdjustmentTransferNoticeOrigin origin,
        bool appliedCurrentPhoto,
        long openRevision,
        long editRevision)
    {
        if (notices == null || notices.Count == 0) return Empty;
        return new(notices.ToArray(), origin, appliedCurrentPhoto, openRevision, editRevision);
    }

    public AdjustmentTransferNoticeState Invalidate() => Empty;
    public AdjustmentTransferNoticeState DisposeDialog() =>
        Origin == AdjustmentTransferNoticeOrigin.Dialog ? Empty : this;
    public AdjustmentTransferNoticeState DisposeQuickPreset() =>
        Origin == AdjustmentTransferNoticeOrigin.QuickPreset ? Empty : this;
    public AdjustmentTransferNoticeState AfterSourceChange() => Empty;
    public AdjustmentTransferNoticeState AfterUserEdit() => Empty;

    public (AdjustmentTransferNoticeState NextState, IReadOnlyList<AdjustmentTransferNotice> ConsumedNotices) DeliverRender(
        long frameOpenRevision,
        long currentEditRevision,
        bool isSettledFrame)
    {
        if (!HasPendingRenderNotice) return (this, []);
        if (frameOpenRevision != OpenRevision || currentEditRevision != EditRevision) return (Empty, []);
        if (!isSettledFrame) return (this, ActiveNotices);
        return (Empty, ActiveNotices);
    }
}

public sealed record AdjustmentTransferContext(string Identifier,bool IsRaw,
    IReadOnlySet<string>? AvailableLookIDs=null,int DefaultExposureMode=1,bool HasUncommittedDraft=false,Action<LensSettings>? ValidateLens=null,
    (double Temperature,double Tint)? CameraWhiteBalance=null, bool IsProRAW=false, bool SupportsCameraHDR=false,
    Action<Adjustments>? ValidateHDRCamera=null,Action<AdjustmentTransferNotice>? OnTransferNotice=null)
{
    internal bool SupportsHDRCameraDevelopment => IsRaw && SupportsCameraHDR && !IsProRAW;
}

public static class AdjustmentTransfer
{
    public static AdjustmentPayload PreviewCapture(AdjustmentScope scope, SavedEdit snapshot, SavedEdit committed, AdjustmentTransferContext context)
    {
        var live = AdjustmentTransferValues.Values(snapshot, context);
        var saved = AdjustmentTransferValues.Values(committed, context);
        if (!snapshot.Identity.SameFile(committed.Identity) || snapshot.Settings.Processing != committed.Settings.Processing ||
            snapshot.Settings.HDR != committed.Settings.HDR || snapshot.Settings.AIDenoiseEnabled != committed.Settings.AIDenoiseEnabled ||
            snapshot.Settings.HDRCameraAIEnabled != committed.Settings.HDRCameraAIEnabled ||
            snapshot.Settings.MasterRecipeSettingsVersion != committed.Settings.MasterRecipeSettingsVersion ||
            live.Count != saved.Count || live.Any(pair => !saved.TryGetValue(pair.Key, out var value) || !Same(pair.Value, value)))
            throw new AdjustmentTransferException(AdjustmentFailure.Draft);
        return Capture(scope, committed, context);
    }

    internal static AdjustmentRecipeContext? Recipe(AdjustmentSnapshot s) => s.MasterRecipeID is {} id ? new(id,s.Values[(int)Parameter.Strength]/100,s.MasterRecipeSettingsVersion) : null;
    public static AdjustmentPayload Capture(AdjustmentScope scope,SavedEdit edit,AdjustmentTransferContext context)
    {
        if(context.HasUncommittedDraft) throw new AdjustmentTransferException(AdjustmentFailure.Draft);
        if (edit.Settings.HDR is { Mode: HDRMode.Hdr })
        {
            ValidateHDRContext(edit,context,"hdr.camera_raw");
            return HDRAdjustmentTransfer.Capture(scope, edit, context);
        }
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
        p.Validate();
        if (target.Settings.HDR is { Mode: HDRMode.Hdr })
        {
            ValidateHDRContext(target,context,"hdr.target");
            var candidate = HDRAdjustmentTransfer.Prepare(p,target,context.SupportsHDRCameraDevelopment);
            if (p.Fields.Contains(F.HdrCameraDevelopment)) {
                var validate = context.ValidateHDRCamera ?? throw new AdjustmentTransferException(AdjustmentFailure.Incompatible,"hdr.camera_development");
                validate(candidate.Settings.Restore());
            }
            return candidate;
        }
        if(p.Source.IsHDR) {
            if(p.Fields.Any(field=>field.IsHDRRelative()))throw new AdjustmentTransferException(AdjustmentFailure.Incompatible,"hdr.relative_white_balance");
            if(p.Fields.Overlaps(AdjustmentFields.HDRTone))throw new AdjustmentTransferException(AdjustmentFailure.Incompatible,"hdr.tone");
            if(p.Fields.Overlaps(AdjustmentFields.HDRColor))throw new AdjustmentTransferException(AdjustmentFailure.Incompatible,"hdr.color");
            if(p.Fields.Overlaps(AdjustmentFields.HDRRendition))throw new AdjustmentTransferException(AdjustmentFailure.Incompatible,"hdr.rendition");
            if(p.Fields.Overlaps(AdjustmentFields.HDREffects))throw new AdjustmentTransferException(AdjustmentFailure.Incompatible,"hdr.effects");
            if(p.Fields.Overlaps(AdjustmentFields.HDRDetail))throw new AdjustmentTransferException(AdjustmentFailure.Incompatible,"hdr.detail");
            if(p.Fields.Contains(F.HdrLook))throw new AdjustmentTransferException(AdjustmentFailure.Incompatible,"hdr.look");
            if(p.Fields.Contains(F.HdrCameraDevelopment))throw new AdjustmentTransferException(AdjustmentFailure.Incompatible,"hdr.camera_development");
            p=new(p.Source with {HdrProcessingVersion=null},p.Values.ToDictionary(pair=>pair.Key,pair=>pair.Value));
        }
        var storedTarget=target;
        // Q4：来源与目标处理版本不同不拒绝，沿用目标处理版本并一次性提示。
        if(p.Source.ProcessingVersion!=storedTarget.Settings.Processing.Version) context.OnTransferNotice?.Invoke(AdjustmentTransferNotice.RetainedTargetProcessingVersion);
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
        if(Text(p[F.ExposureMode]) is {} mode && (p.Source.IsRaw || !context.IsRaw)) {
            // 普通图片没有 RAW 曝光基准：其 sensor 占位值不改变 RAW 目标；普通目标始终保持 sensor。
            s=s with {ExposureMode=!context.IsRaw ? 2 : Array.IndexOf(new[]{"scene","preview","sensor"},mode)};
        }
        s=AdjustmentTransferValues.ApplyObjects(p,s,context);
        s=AdjustmentTransferRefinement.Apply(p,target.Settings,s,fullRecipe);
        foreach(var field in fields) if(EffectiveNumbers(s)[field]!=Expected(field)) throw new AdjustmentTransferException(AdjustmentFailure.Unrepresentable,field.ID());
        var result=new SavedEdit(target.Identity,s,look);
        var actual=AdjustmentTransferValues.Values(result,context);
        return original.All(pair=>Same(pair.Value,actual[pair.Key])) && s.MasterRecipeSettingsVersion==target.Settings.MasterRecipeSettingsVersion ? storedTarget : result;
    }

    private static void ValidateHDRContext(SavedEdit edit, AdjustmentTransferContext context, string field)
    {
        if ((context.IsRaw || PhotoInput.IsRaw(edit.Identity.Path)) && !context.SupportsCameraHDR && !context.IsProRAW)
            throw new AdjustmentTransferException(AdjustmentFailure.Incompatible,field);
        var expectedVersion = context.IsProRAW ? HDRNative.ProRAWDecodeVersion : (int?)null;
        if (edit.Settings.ProRAWDecodeVersion != expectedVersion)
            throw new AdjustmentTransferException(AdjustmentFailure.Incompatible,"hdr.proraw_version");
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
