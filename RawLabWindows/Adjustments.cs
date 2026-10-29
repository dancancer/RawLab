using System.Globalization;

namespace RawLab.Windows;

public enum Parameter { Strength, Exposure, Temperature, Tint, Contrast, Highlights, Shadows, ToneCurve, Saturation, Sharpening }
public sealed record LensSettings(bool Distortion = false, bool Tca = false, bool AutoCrop = true, bool Manual = false, string? ProfileId = null)
{
    public bool Enabled => Distortion || Tca;
    public string CoreProfileId => Manual ? ProfileId ?? "__rawlab_manual_selection_required__" : "";
}
public sealed record LensCandidate(string Id, string Maker, string Model, bool HasDistortion, bool HasTca, bool IsMatch)
{
    public string Title => Model.Contains(Maker, StringComparison.OrdinalIgnoreCase) ? Model : Maker + " " + Model;
    public string Calibration => string.Join(" / ", new[] {
        HasDistortion ? Loc.Text("畸变") : null,
        HasTca ? Loc.Text("横向色差") : null,
        IsMatch ? Loc.Text("元数据匹配") : null
    }.Where(x => x != null));
}
public sealed record LensInfo(int State, string DetectedLens, string SelectedLens, bool AppliedDistortion, bool AppliedTca, float CropScale, IReadOnlyList<LensCandidate> Candidates)
{
    public string Message => State switch {
        0 => Loc.Text("镜头校正已关闭"),
        1 => AppliedDistortion || AppliedTca
            ? Loc.Format("已校正{0}", string.Join(Loc.Text("、"), new[] {
                AppliedDistortion ? Loc.Text("畸变") : null,
                AppliedTca ? Loc.Text("横向色差") : null
            }.Where(x => x != null)))
            : Loc.Text("已匹配镜头"),
        2 => Loc.Text("镜头数据库不可用"), 3 => Loc.Text("未找到机身或传感器尺寸信息"),
        5 => Loc.Text("有多个匹配镜头，请手动选择"), 6 => Loc.Text("此镜头没有所选校正的标定数据"),
        7 => Loc.Text("照片缺少有效焦距，未应用校正"),
        8 => Loc.Text("DNG 已执行内嵌 Stage3 处理，未叠加校正"),
        9 => Loc.Text("此输入不支持镜头校正"), _ => Loc.Text("未匹配镜头，请手动选择")
    };
}
public sealed record ParameterSpec(Parameter Id, string Title, string Group, double Min, double Max, double Step, string Unit, int Decimals = 0)
{
    public double Position(double v) => Id == Parameter.Temperature
        ? (1 / Min - 1 / v) / (1 / Min - 1 / Max) : (v - Min) / (Max - Min);
    public double Value(double position)
    {
        position = Math.Clamp(position, 0, 1);
        var v = Id == Parameter.Temperature ? 1 / (1 / Min - position * (1 / Min - 1 / Max)) : Min + position * (Max - Min);
        return Math.Clamp(Math.Round(v / Step, MidpointRounding.AwayFromZero) * Step, Min, Max);
    }
    public double? Parse(string text) => double.TryParse(text,NumberStyles.Float,CultureInfo.GetCultureInfo(Loc.Language),out var value) && double.IsFinite(value) &&
        value>=Min && value<=Max && Math.Abs(value/Step-Math.Round(value/Step))<=1e-8*Math.Max(1,Math.Abs(value/Step)) ? value : null;
    public static readonly ParameterSpec[] All = [
        new(Parameter.Strength,"强度","胶片",0,200,.1,"%"), new(Parameter.Exposure,"曝光","输入",-4,4,.01,"EV",2),
        new(Parameter.Temperature,"色温","输入",2000,50000,10,"K"), new(Parameter.Tint,"色调","输入",-150,150,.1,"",1),
        new(Parameter.Contrast,"对比度","明暗",-100,100,.1,"%",1), new(Parameter.Highlights,"高光","明暗",-100,100,.1,"%",1),
        new(Parameter.Shadows,"阴影","明暗",-100,100,.1,"%",1), new(Parameter.ToneCurve,"S 曲线","明暗",-100,100,.1,"%",1),
        new(Parameter.Saturation,"饱和度","色彩",-100,100,.1,"%",1), new(Parameter.Sharpening,"锐化","细节",0,200,.1,"%",1)];
}

public sealed class Adjustments
{
    private double[] values = [100,0,6500,0,0,0,0,0,0,0];
    private GeometrySettings geometry = new();
    public ProcessingIdentity Processing { get; set; } = ProcessingIdentity.Current;
    public HDRSettings? HDR { get; set; }
    public bool IsHDREditing => HDR?.Mode == HDRMode.Hdr;
    public int ExposureMode { get; set; } = 1;
    public HslSettings Hsl { get; set; } = new();
    public DenoiseSettings Denoise { get; set; } = new();
    public bool AIDenoiseEnabled { get; set; }
    public PhotoEffectsSettings Effects { get; set; } = new();
    public ColorGradingSettings ColorGrading { get; set; } = new();
    public ToneCurveSettings Curve { get; set; } = new();
    public AtmosphereSettings Atmosphere { get; set; } = new();
    public ToneControlsSettings ToneControls { get; set; } = new();
    public string? MasterRecipeID { get; private set; }
    public int MasterRecipeSettingsVersion { get; private set; } = 3;
    public LensSettings Lens { get; set; } = new();
    public GeometrySettings Geometry
    {
        get => IsHDREditing ? HDR?.Geometry ?? geometry : geometry;
        set
        {
            if (IsHDREditing && HDR is { } hdr) HDR = hdr with { Geometry = value };
            else geometry = value;
        }
    }
    public MasterRecipe? Recipe => MasterRecipeID == null ? null : MasterRecipe.Find(MasterRecipeID);
    public double RefinementScale => MasterRecipeID != null && MasterRecipeSettingsVersion >= 4 ? this[Parameter.Strength] / 100 : 1;
    public HslSettings RenderHsl => Hsl.Scaled(MasterRecipeID == null || MasterRecipeSettingsVersion < 3 ? 1 : this[Parameter.Strength] / 100);
    public ToneControlsSettings RenderToneControls => ToneControls.Scaled(RefinementScale);
    public AtmosphereSettings RenderAtmosphere => Atmosphere.Scaled(RefinementScale);
    public ColorGradingSettings RenderGrading => ColorGrading.Scaled(RefinementScale);
    public ToneCurveSettings RenderCurve => Curve.Scaled(RefinementScale);
    public void ApplyMasterRecipe(MasterRecipe recipe)
    {
        recipe.Validate();
        MasterRecipeID = recipe.Id;
        MasterRecipeSettingsVersion = recipe.SettingsVersion;
        values[0] = 100;
        values[(int)Parameter.Exposure] = recipe.ExposureDelta;
        values[(int)Parameter.Shadows] = recipe.ShadowsDelta;
        values[(int)Parameter.Highlights] = recipe.HighlightsDelta;
        values[(int)Parameter.Contrast] = recipe.ContrastDelta;
        values[(int)Parameter.Saturation] = recipe.SaturationDelta;
        values[(int)Parameter.Tint] = recipe.TintDelta;
        Hsl = recipe.Hsl.Settings();
        if (recipe.SettingsVersion >= 4) {
            ToneControls = recipe.Tone!; Atmosphere = recipe.Atmosphere!;
            ColorGrading = recipe.Grading!; Curve = recipe.Curve!;
            values[(int)Parameter.ToneCurve] = 0;
        }
    }
    public void ClearMasterRecipe(bool isRaw = true)
    {
        if (MasterRecipeID == null) return;
        var scale = this[Parameter.Strength] / 100;
        var offset = this[Parameter.Tint] * scale;
        if (isRaw && (!CameraWhiteBalance || offset != 0) && AsShot == null)
            throw new System.IO.InvalidDataException(Loc.Text("缺少拍摄时白平衡数据，无法保留配方效果。"));
        var snapshot = Capture().Copy();
        foreach (var parameter in new[] { Parameter.Exposure, Parameter.Highlights, Parameter.Shadows, Parameter.Contrast, Parameter.Saturation })
            snapshot.Values[(int)parameter] *= scale;
        var request = Request("", null, 0, null);
        snapshot.Values[(int)Parameter.Tint] = !isRaw ? 0 : request.WbMode == 3
            ? Math.Clamp((AsShot?.Tint ?? 0) + offset, -150, 150) : AsShot?.Tint ?? 0;
        if (!isRaw) snapshot.Values[(int)Parameter.Temperature] = 6500;
        snapshot.Values[(int)Parameter.ToneCurve] = Math.Clamp(this[Parameter.ToneCurve] * RefinementScale, -100, 100);
        snapshot = snapshot with { MasterRecipeID = null, MasterRecipeSettingsVersion = 3, Hsl = RenderHsl,
            ToneControls = RenderToneControls, Atmosphere = RenderAtmosphere, ColorGrading = RenderGrading, Curve = RenderCurve,
            CameraWhiteBalance = !isRaw || request.WbMode != 3,
            AsShotTemperature = isRaw ? snapshot.AsShotTemperature : null, AsShotTint = isRaw ? snapshot.AsShotTint : null };
        // 先验证独立状态可表示，失败时不改动当前编辑。
        var independent = FromSnapshot(snapshot);
        values = independent.values; Hsl = independent.Hsl; ToneControls = independent.ToneControls;
        Atmosphere = independent.Atmosphere; ColorGrading = independent.ColorGrading; Curve = independent.Curve;
        CameraWhiteBalance = independent.CameraWhiteBalance; AsShot = independent.AsShot;
        MasterRecipeID = null;
        MasterRecipeSettingsVersion = 3;
    }
    private int displayChromaDenoise;
    public int DisplayChromaDenoise
    {
        get => displayChromaDenoise;
        set
        {
            if (value is < 0 or > 2) throw new ArgumentOutOfRangeException(nameof(value), "显示色彩降噪模式必须为 0、1 或 2。");
            displayChromaDenoise = value;
        }
    }
    public bool CameraWhiteBalance { get; private set; } = true;
    public (double Temperature, double Tint)? AsShot { get; private set; }
    public double this[Parameter id] => IsHDREditing && (id is Parameter.Exposure or Parameter.Temperature or Parameter.Tint or
        Parameter.Contrast or Parameter.Highlights or Parameter.Shadows or Parameter.Saturation)
        ? HDR!.Get(id) : values[(int)id];
    public Adjustments Clone() { var copy = (Adjustments)MemberwiseClone(); copy.values = (double[])values.Clone(); return copy; }
    public AdjustmentSnapshot Capture()
    {
        if (HDR is { } hdr && !hdr.IsValid) throw new System.IO.InvalidDataException(Loc.Text("HDR 调整记录无效，原有文件未被覆盖。"));
        return new((double[])values.Clone(), ExposureMode, CameraWhiteBalance, AsShot?.Temperature, AsShot?.Tint,
        Denoise, Effects, DisplayChromaDenoise, Hsl, MasterRecipeID, Lens, geometry) {
        Processing = ProcessingIdentity.Require(Processing), AIDenoiseEnabled = AIDenoiseEnabled,
        MasterRecipeSettingsVersion = MasterRecipeSettingsVersion,
        HDR = HDR,
        Atmosphere = Atmosphere.IsIdentity ? null : Atmosphere,
        ToneControls = ToneControls.IsIdentity ? null : ToneControls,
        ColorGrading = ColorGrading.IsDefault ? null : ColorGrading,
        Curve = Curve.IsDefault ? null : Curve
        };
    }
    public static Adjustments FromSnapshot(AdjustmentSnapshot snapshot)
    {
        if (snapshot.MasterRecipeSettingsVersion is not (2 or 3 or 4))
            throw new System.IO.InvalidDataException("Invalid master recipe version");
        if (snapshot.Values.Length != ParameterSpec.All.Length || snapshot.ExposureMode is < 0 or > 2 ||
            snapshot.Values.Where((value, index) => !double.IsFinite(value) || value < ParameterSpec.All[index].Min || value > ParameterSpec.All[index].Max).Any())
            throw new System.IO.InvalidDataException(Loc.Text("调整记录无效，原有文件未被覆盖。"));
        var denoise = snapshot.Denoise ?? new DenoiseSettings();
        var effects = snapshot.Effects ?? new PhotoEffectsSettings();
        var geometry = snapshot.Geometry ?? new GeometrySettings();
        if (snapshot.HDR is { } hdr && !hdr.IsValid)
            throw new System.IO.InvalidDataException(Loc.Text("HDR 调整记录无效，原有文件未被覆盖。"));
        var atmosphere = snapshot.Atmosphere ?? new AtmosphereSettings();
        _ = atmosphere.NativeConfig();
        var tone = snapshot.ToneControls ?? new ToneControlsSettings();
        var grading = snapshot.ColorGrading ?? new ColorGradingSettings();
        _ = grading.NativeConfig();
        _ = tone.NativeConfig();
        _ = denoise.NativeConfig();
        _ = effects.NativeConfig();
        _ = geometry.NativeConfig();
        if (snapshot.DisplayChromaDenoise is < 0 or > 2)
            throw new System.IO.InvalidDataException("调整记录中的显示色彩降噪模式无效，原有文件未被覆盖。");
        var result = new Adjustments {
            Processing = ProcessingIdentity.Require(snapshot.Processing),
            Denoise = denoise,
            AIDenoiseEnabled = snapshot.AIDenoiseEnabled,
            Effects = effects,
            ToneControls = tone,
            Atmosphere = atmosphere,
            ColorGrading = grading,
            Curve = snapshot.Curve ?? new(),
            Hsl = snapshot.Hsl ?? new HslSettings(),
            MasterRecipeID = snapshot.MasterRecipeID,
            MasterRecipeSettingsVersion = snapshot.MasterRecipeSettingsVersion,
            Lens = snapshot.Lens ?? new(),
            DisplayChromaDenoise = snapshot.DisplayChromaDenoise,
            values = (double[])snapshot.Values.Clone(), ExposureMode = snapshot.ExposureMode,
            CameraWhiteBalance = snapshot.CameraWhiteBalance,
            AsShot = snapshot.AsShotTemperature is {} temperature && snapshot.AsShotTint is {} tint ? (temperature, tint) : null,
            HDR = snapshot.HDR
        };
        result.geometry = geometry;
        return result;
    }
    public double Default(Parameter id) => IsHDREditing && (id is Parameter.Temperature or Parameter.Tint) ? id == Parameter.Temperature ? 6500 : 0 :
        id == Parameter.Strength ? 100 : id == Parameter.Temperature ? AsShot?.Temperature ?? 6500 : id == Parameter.Tint ? (MasterRecipeID == null ? AsShot?.Tint ?? 0 : 0) : 0;
    public void Set(Parameter id, double value)
    {
        if (!double.IsFinite(value)) throw new ArgumentOutOfRangeException(nameof(value));
        if (IsHDREditing && (id is Parameter.Exposure or Parameter.Temperature or Parameter.Tint or Parameter.Contrast or
            Parameter.Highlights or Parameter.Shadows or Parameter.Saturation))
        {
            HDR = HDR!.Set(id, value);
            return;
        }
        var spec = ParameterSpec.All[(int)id];
        values[(int)id] = Math.Clamp(value, spec.Min, spec.Max);
        if (MasterRecipeID != null) { if (id == Parameter.Temperature) CameraWhiteBalance = AsShot?.Temperature == value; return; }
        if (id is Parameter.Temperature or Parameter.Tint)
            CameraWhiteBalance = AsShot is { } wb && this[Parameter.Temperature] == wb.Temperature && this[Parameter.Tint] == wb.Tint;
    }
    public void ResolveWhiteBalance((double Temperature, double Tint)? wb)
    {
        AsShot = wb;
        if (IsHDREditing) return;
        if (CameraWhiteBalance) {
            if (MasterRecipeID != null) values[2] = wb?.Temperature ?? 6500;
            else ResetWhiteBalance();
        }
    }
    public void ResetWhiteBalance()
    {
        if (IsHDREditing) { HDR = HDR! with { Temperature = 6500, Tint = 0 }; return; }
        values[2] = Default(Parameter.Temperature); values[3] = Default(Parameter.Tint); CameraWhiteBalance = true;
    }
    public void SetAtmosphere(AtmosphereParameter id, double value)
    {
        if (!double.IsFinite(value)) throw new ArgumentOutOfRangeException(nameof(value));
        Atmosphere = Atmosphere.With(id, Math.Clamp(value, -100, 100));
    }
    public void SetTone(ToneControlParameter id, double value)
    {
        if (!double.IsFinite(value)) throw new ArgumentOutOfRangeException(nameof(value));
        ToneControls = ToneControls.With(id, Math.Clamp(Math.Round(value, 1, MidpointRounding.AwayFromZero), -100, 100));
    }
    public void Reset(Parameter id) => Set(id, Default(id));
    public double EffectDefault(PhotoEffectParameter id) => PhotoEffectSpec.For(id).DefaultValue;
    public void SetEffect(PhotoEffectParameter id, double value)
    {
        if (!double.IsFinite(value)) throw new ArgumentOutOfRangeException(nameof(value));
        var spec = PhotoEffectSpec.For(id);
        value = Math.Clamp(Math.Round(value, 1, MidpointRounding.AwayFromZero), spec.Min, spec.Max);
        Effects = id switch {
            PhotoEffectParameter.VignetteAmount => Effects with { VignetteAmount = value },
            PhotoEffectParameter.VignetteMidpoint => Effects with { VignetteMidpoint = value },
            PhotoEffectParameter.VignetteRoundness => Effects with { VignetteRoundness = value },
            PhotoEffectParameter.VignetteFeather => Effects with { VignetteFeather = value },
            PhotoEffectParameter.VignetteHighlights => Effects with { VignetteHighlights = value },
            PhotoEffectParameter.GrainAmount => Effects with { GrainAmount = value },
            PhotoEffectParameter.GrainSize => Effects with { GrainSize = value },
            PhotoEffectParameter.GrainRoughness => Effects with { GrainRoughness = value },
            _ => throw new ArgumentOutOfRangeException(nameof(id))
        };
    }
    public void ResetEffect(PhotoEffectParameter id) => SetEffect(id, EffectDefault(id));
    public void ResetEffects(bool vignette) {
        foreach (var spec in PhotoEffectSpec.All.Where(x => x.IsVignette == vignette)) ResetEffect(spec.Id);
    }
    public bool IsEffectDefault(bool vignette) => PhotoEffectSpec.All.Where(x => x.IsVignette == vignette)
        .All(spec => this.Effects[spec.Id] == spec.DefaultValue);
    public void ResetGroup(string group)
    {
        foreach (var spec in ParameterSpec.All.Where(p => p.Group == group)) Reset(spec.Id);
        if (group == "输入") { ExposureMode = 1; ResetWhiteBalance(); }
        if (group == "色彩") { ColorGrading = new(); Hsl = new(); ToneControls = ToneControls with { Vibrance = 0 }; }
        if (group == "明暗") { Curve = new(); ToneControls = ToneControls with { BlackPoint = 0, WhitePoint = 0 }; }
        if (group == "细节") { AIDenoiseEnabled = false; Denoise = new(); DisplayChromaDenoise = 0; }
        if (group == "效果") { Effects = new(); Atmosphere = new(); }
        if (group == "镜头") Lens = new();
        if (group == "几何") Geometry = new();
    }
    public void ResetAll() { Atmosphere = new(); Curve = new(); ColorGrading = new(); ToneControls = new(); AIDenoiseEnabled = false; MasterRecipeID = null; MasterRecipeSettingsVersion = 3; foreach (var spec in ParameterSpec.All) Reset(spec.Id); ExposureMode = 1; ResetWhiteBalance(); Denoise = new(); Effects = new(); Hsl = new(); DisplayChromaDenoise = 0; Lens = new(); Geometry = new(); if (HDR is { } hdr) HDR = hdr.Reset() with { Mode = hdr.Mode }; }

    public void SetHDRMode(bool enabled, bool sourceIsHDR, IEnumerable<string>? conflicts = null)
    {
        if (enabled)
        {
            var blocked = conflicts?.ToArray() ?? HDRConflicts();
            HDR = HDRSettings.Enabling(HDR, HDRSettings.FromSdr(this), sourceIsHDR, blocked);
            return;
        }
        if (HDR is { } hdr) HDR = hdr with { Mode = HDRMode.Sdr };
    }

    private IEnumerable<string> HDRConflicts()
    {
        if (this[Parameter.Temperature] != 6500 || this[Parameter.Tint] != 0) yield return "white_balance";
        if (MasterRecipeID != null) yield return "look";
        if (!ToneControls.IsIdentity) yield return "tone_controls";
        if (!Curve.IsIdentity || this[Parameter.ToneCurve] != 0) yield return "tone_curve";
        if (!Hsl.IsIdentity) yield return "hsl";
        if (!ColorGrading.IsDefault) yield return "color_grading";
        if (!Atmosphere.IsIdentity) { yield return "clarity"; yield return "dehaze"; }
        if (this[Parameter.Sharpening] != 0) yield return "sharpening";
        if (AIDenoiseEnabled || Denoise != new DenoiseSettings() || DisplayChromaDenoise != 0) yield return "denoise";
        if (Effects != new PhotoEffectsSettings()) yield return "effects";
        if (Lens != new LensSettings()) yield return "lens_correction";
    }
    internal Native.Request Request(string path, string? lut, int edge, string? output, int? longEdge = null)
    {
        if (longEdge is { } requested && !ExportSize.IsValid(requested))
            throw new ArgumentOutOfRangeException(nameof(longEdge), Loc.Text("导出长边必须为 1-65535 像素。"));
        var limitedFinal = output != null && longEdge.HasValue;
        var scale = MasterRecipeID == null ? 1 : this[Parameter.Strength] / 100;
        var tintOffset = MasterRecipeID == null ? 0 : this[Parameter.Tint] * scale;
        var temperatureWb = !CameraWhiteBalance || tintOffset != 0;
        var tint = MasterRecipeID == null ? this[Parameter.Tint] : Math.Clamp((AsShot?.Tint ?? 0) + tintOffset, -150, 150);
        return new Native.Request {
            Version=2, StructSize=(uint)System.Runtime.InteropServices.Marshal.SizeOf<Native.Request>(), InputPath=path,
            LutPath=lut, LutStrength=lut == null ? 0 : (float)this[Parameter.Strength]/100,
            WbMode=temperatureWb ? 3 : 0, Wb0=1,Wb1=1,Wb2=1,Wb3=1,
            ExposureEv=(float)(this[Parameter.Exposure]*scale), Brightness=1, Contrast=1+(float)(this[Parameter.Contrast]*scale)/100,
            Saturation=1+(float)(this[Parameter.Saturation]*scale)/100, Temperature=temperatureWb ? (float)this[Parameter.Temperature] : 6500,
            Tint=temperatureWb ? (float)tint : 0, Highlights=-(float)(this[Parameter.Highlights]*scale)/100,
            Shadows=(float)(this[Parameter.Shadows]*scale)/100,ToneCurve=Curve.Mode == ToneCurveMode.Custom ? 0 : (float)Math.Clamp(this[Parameter.ToneCurve]*RefinementScale,-100,100)/100,Sharpening=(float)this[Parameter.Sharpening]/100,
            // SizeMode 4 is the shared final long-edge contract. PreviewLongEdge
            // remains independent and is never used to size an export.
            SizeMode=limitedFinal ? 4 : 3,LongEdge=limitedFinal ? (uint)longEdge!.Value : 0,
            OutputTarget=output == null ? 1 : 0,OutputPath=output,
            OutputFormat=output == null ? 3 : ExportFormatExtensions.FromPath(output).NativeValue(),
            JpegQuality=95, Intent=output != null || edge == 0 ? 1 : 0, PreviewLongEdge=(uint)edge
        };
    }
}

// Accessed only on the UI thread: one running operation and one replaceable pending request.
public sealed class LatestWork<T> where T : class
{
    public record Ticket(long Id, T Value);
    private Ticket? pending;
    public Ticket? Active { get; private set; }
    public long Revision { get; private set; }
    public bool Busy => Active != null || pending != null;
    public void Submit(T value) => pending = new Ticket(++Revision, value);
    public Ticket? Start() { if (Active != null) return null; Active = pending; pending = null; return Active; }
    public bool Finish(Ticket ticket) { if (Active != ticket) return false; Active = null; return ticket.Id == Revision; }
}
