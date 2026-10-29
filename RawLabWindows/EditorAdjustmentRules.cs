namespace RawLab.Windows;

public enum EditorAdjustmentGroup { Looks, Light, Color, Effects, Detail, Geometry }
public enum EditorAdjustmentTool { Film, MasterRecipe, Strength, Exposure, Highlights, Shadows, Contrast, ToneCurve, WhiteBalance, Saturation, Hsl, Vignette, Grain, Denoise, Sharpening, Geometry, Lens, BlackPoint, WhitePoint, Vibrance, ColorGrading, Clarity, Dehaze }
public enum EditorResetKind { Group, HslChannel, AllHsl, All, Tool, GradingZone, AllGrading }
public sealed record EditorResetScope(EditorResetKind Kind, EditorAdjustmentGroup Group = EditorAdjustmentGroup.Looks, int Channel = 0, EditorAdjustmentTool Tool = EditorAdjustmentTool.Film, ColorGradingZone Zone = ColorGradingZone.Shadows);
public enum EditorResetStatus { Ready, NoChange, Invalid, Blocked }
public sealed record EditorResetCandidate(EditorResetStatus Status, SavedEdit? Candidate = null,
    bool RequiresConfirmation = false, string? Reason = null, IReadOnlyList<string>? MaterializedFields = null);

// 候选只负责纯模型转换；调用方确认和保存成功后才能替换当前编辑。
public static class EditorAdjustmentRules
{
    private static readonly IReadOnlyList<EditorAdjustmentTool>[] GroupTools = [
        Array.AsReadOnly(new[] { EditorAdjustmentTool.Film, EditorAdjustmentTool.MasterRecipe, EditorAdjustmentTool.Strength }),
        Array.AsReadOnly(new[] { EditorAdjustmentTool.Exposure, EditorAdjustmentTool.Highlights, EditorAdjustmentTool.Shadows, EditorAdjustmentTool.BlackPoint, EditorAdjustmentTool.WhitePoint, EditorAdjustmentTool.Contrast, EditorAdjustmentTool.ToneCurve }),
        Array.AsReadOnly(new[] { EditorAdjustmentTool.WhiteBalance, EditorAdjustmentTool.Saturation, EditorAdjustmentTool.Vibrance, EditorAdjustmentTool.Hsl, EditorAdjustmentTool.ColorGrading }),
        Array.AsReadOnly(new[] { EditorAdjustmentTool.Clarity, EditorAdjustmentTool.Dehaze, EditorAdjustmentTool.Vignette, EditorAdjustmentTool.Grain }),
        Array.AsReadOnly(new[] { EditorAdjustmentTool.Denoise, EditorAdjustmentTool.Sharpening }),
        Array.AsReadOnly(new[] { EditorAdjustmentTool.Geometry, EditorAdjustmentTool.Lens })
    ];
    public static IReadOnlyList<EditorAdjustmentTool> Tools(EditorAdjustmentGroup group) =>
        Enum.IsDefined(group) ? GroupTools[(int)group] : throw new ArgumentOutOfRangeException(nameof(group));
    public static EditorAdjustmentGroup GroupFor(EditorAdjustmentTool tool)
    {
        foreach (var group in Enum.GetValues<EditorAdjustmentGroup>())
            if (Tools(group).Contains(tool)) return group;
        throw new ArgumentOutOfRangeException(nameof(tool));
    }
    public static string Id(EditorAdjustmentGroup group) => group switch {
        EditorAdjustmentGroup.Looks => "looks", EditorAdjustmentGroup.Light => "light",
        EditorAdjustmentGroup.Color => "color", EditorAdjustmentGroup.Effects => "effects",
        EditorAdjustmentGroup.Detail => "detail", EditorAdjustmentGroup.Geometry => "geometry",
        _ => throw new ArgumentOutOfRangeException(nameof(group))
    };
    public static EditorAdjustmentTool DefaultTool(EditorAdjustmentGroup group) => Tools(group)[0];
    public static string Title(EditorAdjustmentGroup group) => group switch {
        EditorAdjustmentGroup.Looks => "外观", EditorAdjustmentGroup.Light => "光线",
        EditorAdjustmentGroup.Color => "颜色", EditorAdjustmentGroup.Effects => "效果",
        EditorAdjustmentGroup.Detail => "细节", EditorAdjustmentGroup.Geometry => "几何与镜头",
        _ => throw new ArgumentOutOfRangeException(nameof(group))
    };
    public static string Title(EditorAdjustmentTool tool) => tool switch {
        EditorAdjustmentTool.Film => "胶片", EditorAdjustmentTool.MasterRecipe => "大师配方",
        EditorAdjustmentTool.ColorGrading => "颜色分级",
        EditorAdjustmentTool.Clarity => "清晰度", EditorAdjustmentTool.Dehaze => "去朦胧",
        EditorAdjustmentTool.ToneCurve => "曲线",
        EditorAdjustmentTool.WhiteBalance => "白平衡", EditorAdjustmentTool.Hsl => "HSL",
        EditorAdjustmentTool.Vignette => "暗角", EditorAdjustmentTool.Grain => "颗粒",
        EditorAdjustmentTool.Denoise => "降噪", EditorAdjustmentTool.Geometry => "几何",
        EditorAdjustmentTool.BlackPoint => "黑场", EditorAdjustmentTool.WhitePoint => "白场", EditorAdjustmentTool.Vibrance => "鲜艳度",
        EditorAdjustmentTool.Lens => "镜头", _ => ParameterSpec.All[(int)ParameterFor(tool)].Title
    };
    public static AtmosphereParameter? AtmosphereParameterFor(EditorAdjustmentTool tool) => tool switch {
        EditorAdjustmentTool.Clarity => AtmosphereParameter.Clarity, EditorAdjustmentTool.Dehaze => AtmosphereParameter.Dehaze, _ => null
    };
    public static EditorAdjustmentTool ToolFor(AtmosphereParameter parameter) => parameter switch {
        AtmosphereParameter.Clarity => EditorAdjustmentTool.Clarity, AtmosphereParameter.Dehaze => EditorAdjustmentTool.Dehaze,
        _ => throw new ArgumentOutOfRangeException(nameof(parameter))
    };
    public static ToneControlParameter? ToneParameterFor(EditorAdjustmentTool tool) => tool switch {
        EditorAdjustmentTool.BlackPoint => ToneControlParameter.BlackPoint,
        EditorAdjustmentTool.WhitePoint => ToneControlParameter.WhitePoint,
        EditorAdjustmentTool.Vibrance => ToneControlParameter.Vibrance, _ => null
    };
    public static EditorAdjustmentTool ToolFor(ToneControlParameter parameter) => parameter switch {
        ToneControlParameter.BlackPoint => EditorAdjustmentTool.BlackPoint,
        ToneControlParameter.WhitePoint => EditorAdjustmentTool.WhitePoint,
        ToneControlParameter.Vibrance => EditorAdjustmentTool.Vibrance,
        _ => throw new ArgumentOutOfRangeException(nameof(parameter))
    };
    public static Parameter ParameterFor(EditorAdjustmentTool tool) => tool switch {
        EditorAdjustmentTool.Strength => Parameter.Strength, EditorAdjustmentTool.Exposure => Parameter.Exposure,
        EditorAdjustmentTool.Highlights => Parameter.Highlights, EditorAdjustmentTool.Shadows => Parameter.Shadows,
        EditorAdjustmentTool.Contrast => Parameter.Contrast, EditorAdjustmentTool.ToneCurve => Parameter.ToneCurve,
        EditorAdjustmentTool.Saturation => Parameter.Saturation, EditorAdjustmentTool.Sharpening => Parameter.Sharpening,
        _ => throw new ArgumentOutOfRangeException(nameof(tool))
    };
    public static bool IsModified(EditorResetScope scope, SavedEdit edit)
    {
        Validate(scope, edit);
        if (edit.Settings.HDR is { Mode: HDRMode.Hdr } hdr) return ResetHDR(scope, hdr) != hdr;
        return !SameScope(scope, edit, Defaults(edit));
    }
    public static EditorResetCandidate PrepareReset(EditorResetScope scope, SavedEdit edit)
    {
        try { Validate(scope, edit); }
        catch (Exception error) when (error is ArgumentException or System.IO.InvalidDataException or NullReferenceException) {
            return new(EditorResetStatus.Invalid, Reason: error.Message);
        }
        if (edit.Settings.MasterRecipeID is {} recipe && MasterRecipe.Find(recipe) == null)
            return new(EditorResetStatus.Blocked, Reason: "Unknown master recipe.");
        if (edit.Settings.HDR is { Mode: HDRMode.Hdr } hdr)
        {
            var reset = ResetHDR(scope, hdr);
            if (reset == hdr) return new(EditorResetStatus.NoChange);
            return new(EditorResetStatus.Ready, new SavedEdit(edit.Identity, edit.Settings with { HDR = reset }, edit.Look),
                RequiresConfirmation: false);
        }
        var defaults = Defaults(edit);
        if (SameScope(scope, edit, defaults)) return new(EditorResetStatus.NoChange);
        var source = edit.Settings.Copy();
        var candidate = source.Copy();
        var look = edit.Look;
        var detached = false;
        if (scope.Kind == EditorResetKind.All) { candidate = defaults.Settings.Copy(); look = null; }
        else if (scope.Kind == EditorResetKind.AllGrading) candidate = candidate with { ColorGrading = null };
        else if (scope.Kind == EditorResetKind.GradingZone) candidate = candidate with { ColorGrading = (candidate.ColorGrading ?? new()).With(scope.Zone, new()) };
        else if (scope.Kind == EditorResetKind.AllHsl) candidate = candidate with { Hsl = new() };
        else if (scope.Kind == EditorResetKind.HslChannel) {
            var hsl = candidate.Hsl ?? new();
            for (var axis = 0; axis < 3; axis++) hsl = hsl.WithValue(axis, scope.Channel, 0);
            candidate = candidate with { Hsl = hsl };
        }
        else if (scope.Kind == EditorResetKind.Tool && scope.Tool is not (EditorAdjustmentTool.Film or EditorAdjustmentTool.MasterRecipe))
            candidate = ResetTool(scope.Tool, candidate, defaults.Settings);
        else if (scope.Kind == EditorResetKind.Tool || scope.Group == EditorAdjustmentGroup.Looks) {
            if (source.MasterRecipeID != null) {
                var state = source.Restore();
                try { state.ClearMasterRecipe(PhotoInput.IsRaw(edit.Identity.Path)); }
                catch (Exception error) when (error is ArgumentException or System.IO.InvalidDataException) {
                    return new(EditorResetStatus.Blocked, Reason: error.Message);
                }
                candidate = state.Capture();
                detached = true;
            }
            if (detached || scope.Kind != EditorResetKind.Tool) candidate.Values[(int)Parameter.Strength] = 100;
            look = null;
        }
        else candidate = ResetGroup(scope.Group, candidate, defaults.Settings);
        var result = new SavedEdit(edit.Identity, candidate, look);
        try { Validate(scope, result); }
        catch (Exception error) when (error is ArgumentException or System.IO.InvalidDataException) {
            return new(EditorResetStatus.Blocked, Reason: error.Message);
        }
        if (detached && !SameEffective(edit, result))
            return new(EditorResetStatus.Blocked, Reason: "Independent settings cannot preserve final core Float values.");
        var materialized = new List<string>();
        if (detached) {
            foreach (var parameter in Enum.GetValues<Parameter>())
                if (parameter != Parameter.Strength && source.Values[(int)parameter] != candidate.Values[(int)parameter])
                    materialized.Add(ParameterSpec.All[(int)parameter].Title);
            if (!(source.Hsl ?? new()).Equals(candidate.Hsl ?? new())) materialized.Add("HSL");
            if (source.CameraWhiteBalance != candidate.CameraWhiteBalance) materialized.Add("白平衡");
            var beforeTone = source.ToneControls ?? new(); var afterTone = candidate.ToneControls ?? new();
            if (beforeTone.BlackPoint != afterTone.BlackPoint) materialized.Add("黑场");
            if (beforeTone.WhitePoint != afterTone.WhitePoint) materialized.Add("白场");
            if (beforeTone.Vibrance != afterTone.Vibrance) materialized.Add("鲜艳度");
            var beforeAtmosphere = source.Atmosphere ?? new(); var afterAtmosphere = candidate.Atmosphere ?? new();
            if (beforeAtmosphere.Clarity != afterAtmosphere.Clarity) materialized.Add("清晰度");
            if (beforeAtmosphere.Dehaze != afterAtmosphere.Dehaze) materialized.Add("去朦胧");
            if (!(source.Curve ?? new()).Equals(candidate.Curve ?? new())) materialized.Add("曲线");
            if ((source.ColorGrading ?? new()) != (candidate.ColorGrading ?? new())) materialized.Add("颜色分级");
        }
        return new(EditorResetStatus.Ready, result,
            scope.Kind is EditorResetKind.All or EditorResetKind.AllHsl or EditorResetKind.AllGrading or EditorResetKind.Group ||
            scope.Kind == EditorResetKind.Tool && scope.Tool is (EditorAdjustmentTool.Hsl or EditorAdjustmentTool.ColorGrading) || materialized.Count > 0,
            detached ? "Recipe values and white balance are materialized as independent adjustments." : null, materialized);
    }
    private static readonly Parameter[] LightParameters = [Parameter.Exposure, Parameter.Contrast, Parameter.Highlights, Parameter.Shadows, Parameter.ToneCurve];
    private static readonly Parameter[] ColorParameters = [Parameter.Temperature, Parameter.Tint, Parameter.Saturation];
    private static SavedEdit Defaults(SavedEdit edit)
    {
        var state = new Adjustments { Processing = edit.Settings.Processing };
        if (PhotoInput.IsRaw(edit.Identity.Path)) state.ResolveWhiteBalance(edit.Settings.AsShotTemperature is {} t && edit.Settings.AsShotTint is {} tint ? (t, tint) : null);
        state = PhotoInput.PrepareInputSettings(edit.Identity.Path, state);
        return new(edit.Identity, state.Capture(), null);
    }
    private static AdjustmentSnapshot ResetGroup(EditorAdjustmentGroup group, AdjustmentSnapshot value, AdjustmentSnapshot defaults)
    {
        var parameters = group switch {
            EditorAdjustmentGroup.Light => LightParameters, EditorAdjustmentGroup.Color => ColorParameters,
            EditorAdjustmentGroup.Detail => [Parameter.Sharpening], _ => Array.Empty<Parameter>()
        };
        foreach (var parameter in parameters) value.Values[(int)parameter] =
            group == EditorAdjustmentGroup.Color && parameter == Parameter.Tint && value.MasterRecipeID != null ? 0 : defaults.Values[(int)parameter];
        return group switch {
            EditorAdjustmentGroup.Light => value with { ExposureMode = defaults.ExposureMode, Curve = null,
                ToneControls = (value.ToneControls ?? new()) with { BlackPoint = 0, WhitePoint = 0 } },
            EditorAdjustmentGroup.Color => value with { CameraWhiteBalance = true, Hsl = new(), ColorGrading = null,
                ToneControls = (value.ToneControls ?? new()) with { Vibrance = 0 },
                AsShotTemperature = defaults.AsShotTemperature, AsShotTint = defaults.AsShotTint },
            EditorAdjustmentGroup.Effects => value with { Effects = defaults.Effects, Atmosphere = null },
            EditorAdjustmentGroup.Detail => value with { Denoise = defaults.Denoise, DisplayChromaDenoise = defaults.DisplayChromaDenoise, AIDenoiseEnabled = false },
            EditorAdjustmentGroup.Geometry => value with { Geometry = defaults.Geometry, Lens = defaults.Lens },
            _ => value
        };
    }
    private static AdjustmentSnapshot ResetTool(EditorAdjustmentTool tool, AdjustmentSnapshot value, AdjustmentSnapshot defaults)
    {
        if (AtmosphereParameterFor(tool) is {} atmosphereParameter)
            return value with { Atmosphere = (value.Atmosphere ?? new()).With(atmosphereParameter, 0) };
        if (ToneParameterFor(tool) is {} toneParameter)
            return value with { ToneControls = (value.ToneControls ?? new()).With(toneParameter, 0) };
        switch (tool) {
            case EditorAdjustmentTool.ToneCurve:
                value.Values[(int)Parameter.ToneCurve] = defaults.Values[(int)Parameter.ToneCurve];
                return value with { Curve = null };
            case EditorAdjustmentTool.WhiteBalance:
                value.Values[(int)Parameter.Temperature] = defaults.Values[(int)Parameter.Temperature];
                value.Values[(int)Parameter.Tint] = value.MasterRecipeID != null ? 0 : defaults.Values[(int)Parameter.Tint];
                return value with { CameraWhiteBalance = defaults.CameraWhiteBalance };
            case EditorAdjustmentTool.ColorGrading: return value with { ColorGrading = null };
            case EditorAdjustmentTool.Hsl: return value with { Hsl = new() };
            case EditorAdjustmentTool.Vignette:
            case EditorAdjustmentTool.Grain:
                var effects = value.Effects ?? new();
                foreach (var spec in PhotoEffectSpec.All.Where(spec => spec.IsVignette == (tool == EditorAdjustmentTool.Vignette)))
                    effects = SetEffectDefault(effects, spec.Id);
                return value with { Effects = effects };
            case EditorAdjustmentTool.Denoise: return value with { Denoise = defaults.Denoise, DisplayChromaDenoise = defaults.DisplayChromaDenoise, AIDenoiseEnabled = false };
            case EditorAdjustmentTool.Geometry: return value with { Geometry = defaults.Geometry };
            case EditorAdjustmentTool.Lens: return value with { Lens = defaults.Lens };
            default:
                var parameter = ParameterFor(tool); value.Values[(int)parameter] = defaults.Values[(int)parameter];
                return tool == EditorAdjustmentTool.Exposure ? value with { ExposureMode = defaults.ExposureMode } : value;
        }
    }
    private static PhotoEffectsSettings SetEffectDefault(PhotoEffectsSettings effects, PhotoEffectParameter parameter) => parameter switch {
        PhotoEffectParameter.VignetteAmount => effects with { VignetteAmount = 0 },
        PhotoEffectParameter.VignetteMidpoint => effects with { VignetteMidpoint = 50 },
        PhotoEffectParameter.VignetteRoundness => effects with { VignetteRoundness = 0 },
        PhotoEffectParameter.VignetteFeather => effects with { VignetteFeather = 50 },
        PhotoEffectParameter.VignetteHighlights => effects with { VignetteHighlights = 0 },
        PhotoEffectParameter.GrainAmount => effects with { GrainAmount = 0 },
        PhotoEffectParameter.GrainSize => effects with { GrainSize = 25 },
        PhotoEffectParameter.GrainRoughness => effects with { GrainRoughness = 50 },
        _ => throw new ArgumentOutOfRangeException(nameof(parameter))
    };
    private static bool SameScope(EditorResetScope scope, SavedEdit value, SavedEdit defaults)
    {
        if (value.Settings.HDR is { Mode: HDRMode.Hdr } hdr) return ResetHDR(scope, hdr) == hdr;
        if (PhotoInput.IsRaster(value.Identity.Path)) {
            // 普通图片的 RAW 专属元数据不参与标记；配方 tint 仍是待用的逻辑贡献。
            var comparable = value.Settings.Copy() with {
                ExposureMode = defaults.Settings.ExposureMode,
                CameraWhiteBalance = defaults.Settings.CameraWhiteBalance,
                AsShotTemperature = defaults.Settings.AsShotTemperature,
                AsShotTint = defaults.Settings.AsShotTint
            };
            comparable.Values[(int)Parameter.Temperature] = defaults.Settings.Values[(int)Parameter.Temperature];
            if (comparable.MasterRecipeID == null) comparable.Values[(int)Parameter.Tint] = defaults.Settings.Values[(int)Parameter.Tint];
            value = value with { Settings = comparable };
        }
        if (scope.Kind == EditorResetKind.All) return value.Look == null && value.Settings.SameAs(defaults.Settings);
        if (scope.Kind == EditorResetKind.AllGrading) return (value.Settings.ColorGrading ?? new()).IsDefault;
        if (scope.Kind == EditorResetKind.GradingZone) return (value.Settings.ColorGrading ?? new())[scope.Zone].IsDefault;
        if (scope.Kind == EditorResetKind.AllHsl) return (value.Settings.Hsl ?? new()).IsIdentity;
        if (scope.Kind == EditorResetKind.HslChannel) return Enumerable.Range(0, 3).All(axis => (value.Settings.Hsl ?? new()).Value(axis, scope.Channel) == 0);
        if (scope.Kind == EditorResetKind.Tool) {
            if (scope.Tool == EditorAdjustmentTool.Film) return value.Look == null && value.Settings.MasterRecipeID == null;
            if (scope.Tool == EditorAdjustmentTool.MasterRecipe) return value.Settings.MasterRecipeID == null;
            return value.Settings.SameAs(ResetTool(scope.Tool, value.Settings.Copy(), defaults.Settings));
        }
        if (scope.Group == EditorAdjustmentGroup.Looks) return value.Look == null && value.Settings.MasterRecipeID == null && value.Settings.Values[0] == 100;
        // 配方 tint 是相对偏移，默认 0；不能与相机绝对 tint 比较。
        var groupDefaults = defaults.Settings.Copy();
        if (scope.Group == EditorAdjustmentGroup.Color && value.Settings.MasterRecipeID != null) groupDefaults.Values[(int)Parameter.Tint] = 0;
        return value.Settings.SameAs(ResetGroup(scope.Group, value.Settings.Copy(), groupDefaults));
    }

    private static HDRSettings ResetHDR(EditorResetScope scope, HDRSettings value)
    {
        if (scope.Kind == EditorResetKind.All) return value.Reset() with { Mode = value.Mode };
        if (scope.Kind == EditorResetKind.Group)
        {
            return scope.Group switch {
                EditorAdjustmentGroup.Light => value with { Exposure = 0, Contrast = 0, Highlights = 0, Shadows = 0 },
                EditorAdjustmentGroup.Color => value with { Temperature = 6500, Tint = 0, Saturation = 0 },
                EditorAdjustmentGroup.Geometry => value with { Geometry = new() },
                _ => value
            };
        }
        if (scope.Kind != EditorResetKind.Tool) return value;
        return scope.Tool switch {
            EditorAdjustmentTool.Exposure => value with { Exposure = 0 },
            EditorAdjustmentTool.Highlights => value with { Highlights = 0 },
            EditorAdjustmentTool.Shadows => value with { Shadows = 0 },
            EditorAdjustmentTool.Contrast => value with { Contrast = 0 },
            EditorAdjustmentTool.Saturation => value with { Saturation = 0 },
            EditorAdjustmentTool.WhiteBalance => value with { Temperature = 6500, Tint = 0 },
            EditorAdjustmentTool.Geometry => value with { Geometry = new() },
            _ => value
        };
    }
    private static void Validate(EditorResetScope scope, SavedEdit edit)
    {
        if (!Enum.IsDefined(scope.Zone) || !Enum.IsDefined(scope.Kind) || !Enum.IsDefined(scope.Group) || !Enum.IsDefined(scope.Tool) || scope.Kind == EditorResetKind.HslChannel && scope.Channel is < 0 or > 7)
            throw new ArgumentOutOfRangeException(nameof(scope));
        if (string.IsNullOrWhiteSpace(edit.Identity.Path) || !PhotoInput.IsRaw(edit.Identity.Path) && !PhotoInput.IsRaster(edit.Identity.Path))
            throw new System.IO.InvalidDataException("Unsupported photo identity.");
        _ = edit.Settings.Restore();
        if (edit.Settings.AsShotTemperature.HasValue != edit.Settings.AsShotTint.HasValue ||
            edit.Settings.AsShotTemperature is {} t && (!double.IsFinite(t) || t is < 2000 or > 50000) ||
            edit.Settings.AsShotTint is {} tint && (!double.IsFinite(tint) || tint is < -150 or > 150))
            throw new System.IO.InvalidDataException("Invalid as-shot calibration.");
    }
    private static Native.Request EffectiveRequest(string path, Adjustments state)
    {
        var request = PhotoInput.PrepareInputSettings(path, state).Request(path, null, 64, null);
        // DisplayInput.PrepareRequest 使用普通图片的固定 WB；不要求 WPF 解码器参与纯模型校验。
        if (PhotoInput.IsRaster(path)) { request.WbMode = 0; request.Temperature = 6500; request.Tint = 0; }
        return request;
    }
    private static bool SameEffective(SavedEdit before, SavedEdit after)
    {
        var a = before.Settings.Restore(); var b = after.Settings.Restore();
        var x = EffectiveRequest(before.Identity.Path, a); var y = EffectiveRequest(after.Identity.Path, b);
        return x.ExposureEv == y.ExposureEv && x.Contrast == y.Contrast && x.Highlights == y.Highlights &&
            x.Shadows == y.Shadows && x.Saturation == y.Saturation && x.ToneCurve == y.ToneCurve && x.Sharpening == y.Sharpening &&
            x.WbMode == y.WbMode && x.Temperature == y.Temperature && x.Tint == y.Tint && a.ExposureMode == b.ExposureMode &&
            a.RenderHsl.Values.Select(v => (float)v).SequenceEqual(b.RenderHsl.Values.Select(v => (float)v)) &&
            a.RenderToneControls == b.RenderToneControls && a.RenderAtmosphere == b.RenderAtmosphere && a.RenderGrading == b.RenderGrading && a.RenderCurve == b.RenderCurve && a.AIDenoiseEnabled == b.AIDenoiseEnabled && a.Effects == b.Effects && a.Denoise == b.Denoise && a.DisplayChromaDenoise == b.DisplayChromaDenoise && a.Geometry == b.Geometry && a.Lens == b.Lens;
    }
}
