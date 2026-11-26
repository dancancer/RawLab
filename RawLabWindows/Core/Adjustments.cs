using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RawLab.Windows;

public enum Parameter { Strength, Exposure, Temperature, Tint, Contrast, Highlights, Shadows, ToneCurve, Saturation, Sharpening }
[JsonConverter(typeof(LensSettingsJsonConverter))]
public sealed record LensSettings(
    bool Distortion = false,
    bool Tca = false,
    bool AutoCrop = true,
    bool Manual = false,
    string? ProfileId = null,
    double? FocalLength = null,
    double? CropFactor = null,
    bool Vignetting = false,
    double DefringePurpleAmount = 0,
    double DefringePurpleHue = 50,
    double DefringeGreenAmount = 0,
    double DefringeGreenHue = 50)
{
    public bool Enabled => Distortion || Tca || Vignetting;
    public bool HasDefringeSettings => DefringePurpleAmount != 0 || DefringePurpleHue != 50 ||
        DefringeGreenAmount != 0 || DefringeGreenHue != 50;
    public string CoreProfileId => Manual ? ProfileId ?? "__rawlab_manual_selection_required__" : "";

    public void Validate()
    {
        Check(DefringePurpleAmount, AdjustmentFieldSpec.Fields.GeometryLensDefringePurpleAmount.WindowsModel, nameof(DefringePurpleAmount));
        Check(DefringePurpleHue, AdjustmentFieldSpec.Fields.GeometryLensDefringePurpleHue.WindowsModel, nameof(DefringePurpleHue));
        Check(DefringeGreenAmount, AdjustmentFieldSpec.Fields.GeometryLensDefringeGreenAmount.WindowsModel, nameof(DefringeGreenAmount));
        Check(DefringeGreenHue, AdjustmentFieldSpec.Fields.GeometryLensDefringeGreenHue.WindowsModel, nameof(DefringeGreenHue));
    }

    private static void Check(double value, AdjustmentFieldModelSpec m, string name)
    {
        if (!double.IsFinite(value) || value < m.Min!.Value || value > m.Max!.Value)
            throw new ArgumentOutOfRangeException(name, $"{name} out of range");
    }
}

public sealed class LensSettingsJsonConverter : JsonConverter<LensSettings>
{
    public override LensSettings Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        var root = doc.RootElement;
        if (root.ValueKind != JsonValueKind.Object) throw new JsonException("Invalid LensSettings");
        var map = new Dictionary<string, JsonElement>(options.PropertyNameCaseInsensitive ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);
        foreach (var p in root.EnumerateObject())
            if (!map.TryAdd(p.Name, p.Value)) throw new JsonException("Duplicate key in LensSettings");
        bool Bool(string k, bool def) => map.TryGetValue(k, out var e) ? (e.ValueKind switch { JsonValueKind.True => true, JsonValueKind.False => false, _ => throw new JsonException() }) : def;
        string? Str(string k) => map.TryGetValue(k, out var e) ? (e.ValueKind == JsonValueKind.Null ? null : e.ValueKind == JsonValueKind.String ? e.GetString() : throw new JsonException()) : null;
        double? OptNum(string k) => map.TryGetValue(k, out var e) ? (e.ValueKind == JsonValueKind.Null ? null : e.ValueKind == JsonValueKind.Number ? e.GetDouble() : throw new JsonException()) : null;
        double Num(string k, double def) => OptNum(k) ?? def;
        var lens = new LensSettings(
            Distortion: Bool("Distortion", false),
            Tca: Bool("Tca", false),
            AutoCrop: Bool("AutoCrop", true),
            Manual: Bool("Manual", false),
            ProfileId: Str("ProfileId"),
            FocalLength: OptNum("FocalLength"),
            CropFactor: OptNum("CropFactor"),
            Vignetting: Bool("Vignetting", false),
            DefringePurpleAmount: Num("DefringePurpleAmount", 0),
            DefringePurpleHue: Num("DefringePurpleHue", 50),
            DefringeGreenAmount: Num("DefringeGreenAmount", 0),
            DefringeGreenHue: Num("DefringeGreenHue", 50));
        lens.Validate();
        return lens;
    }

    public override void Write(Utf8JsonWriter writer, LensSettings value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WriteBoolean("Distortion", value.Distortion);
        writer.WriteBoolean("Tca", value.Tca);
        writer.WriteBoolean("AutoCrop", value.AutoCrop);
        writer.WriteBoolean("Manual", value.Manual);
        if (value.ProfileId == null) writer.WriteNull("ProfileId"); else writer.WriteString("ProfileId", value.ProfileId);
        if (value.FocalLength is { } fl) writer.WriteNumber("FocalLength", fl); else writer.WriteNull("FocalLength");
        if (value.CropFactor is { } cf) writer.WriteNumber("CropFactor", cf); else writer.WriteNull("CropFactor");
        writer.WriteBoolean("Vignetting", value.Vignetting);
        if (value.HasDefringeSettings)
        {
            writer.WriteNumber("DefringePurpleAmount", value.DefringePurpleAmount);
            writer.WriteNumber("DefringePurpleHue", value.DefringePurpleHue);
            writer.WriteNumber("DefringeGreenAmount", value.DefringeGreenAmount);
            writer.WriteNumber("DefringeGreenHue", value.DefringeGreenHue);
        }
        writer.WriteEndObject();
    }
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
public sealed record LensInfo(int State, string DetectedLens, string SelectedLens, bool AppliedDistortion, bool AppliedTca, float CropScale, IReadOnlyList<LensCandidate> Candidates, bool AppliedVignetting = false)
{
    public string Message => State switch {
        0 => Loc.Text("镜头校正已关闭"),
        1 => AppliedDistortion || AppliedTca || AppliedVignetting
            ? Loc.Format("已校正{0}", string.Join(Loc.Text("、"), new[] {
                AppliedDistortion ? Loc.Text("畸变") : null,
                AppliedTca ? Loc.Text("横向色差") : null,
                AppliedVignetting ? Loc.Text("暗角校正") : null
            }.Where(x => x != null)))
            : Loc.Text("已匹配镜头"),
        2 => Loc.Text("镜头数据库不可用"), 3 => Loc.Text("未找到机身或传感器尺寸信息"),
        5 => Loc.Text("有多个匹配镜头，请手动选择"), 6 => Loc.Text("此镜头没有所选校正的标定数据"),
        7 => Loc.Text("照片缺少有效焦距，未应用校正"),
        8 => Loc.Text("DNG 已执行内嵌 Stage3 处理，未叠加校正"),
        9 => Loc.Text("此输入不支持镜头校正"), _ => Loc.Text("未匹配镜头，请手动选择")
    };
}
public sealed record ParameterSpec(Parameter Id, string Title, string Group, double Min, double Max, double Step, string Unit, int Decimals = 0, double UiScale = 1, double UiOffset = 0)
{
    public double ToDisplay(double model) => UiScale == 1
        ? model - UiOffset
        : Math.Round((model - UiOffset) * UiScale, 10, MidpointRounding.AwayFromZero);
    public double ToCanonical(double display) => UiOffset + display / UiScale;
    public double DisplayMin => Math.Min(ToDisplay(Min), ToDisplay(Max));
    public double DisplayMax => Math.Max(ToDisplay(Min), ToDisplay(Max));
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
        new(Parameter.Strength,"强度","胶片",AdjustmentFieldSpec.Fields.LooksStrength.WindowsModel.Min!.Value,AdjustmentFieldSpec.Fields.LooksStrength.WindowsModel.Max!.Value,.1,"%",0,100,0),
        new(Parameter.Exposure,"曝光","输入",AdjustmentFieldSpec.Fields.LightExposure.WindowsModel.Min!.Value,AdjustmentFieldSpec.Fields.LightExposure.WindowsModel.Max!.Value,.01,"EV",2),
        new(Parameter.Temperature,"色温","输入",AdjustmentFieldSpec.Fields.ColorWhiteBalanceTemperatureKelvin.WindowsModel.Min!.Value,AdjustmentFieldSpec.Fields.ColorWhiteBalanceTemperatureKelvin.WindowsModel.Max!.Value,10,"K"),
        new(Parameter.Tint,"色调","输入",AdjustmentFieldSpec.Fields.ColorWhiteBalanceTint.WindowsModel.Min!.Value,AdjustmentFieldSpec.Fields.ColorWhiteBalanceTint.WindowsModel.Max!.Value,.1,"",1),
        new(Parameter.Contrast,"对比度","明暗",AdjustmentFieldSpec.Fields.LightContrast.WindowsModel.Min!.Value,AdjustmentFieldSpec.Fields.LightContrast.WindowsModel.Max!.Value,.1,"%",1,100,1),
        new(Parameter.Highlights,"高光","明暗",AdjustmentFieldSpec.Fields.LightHighlights.WindowsModel.Min!.Value,AdjustmentFieldSpec.Fields.LightHighlights.WindowsModel.Max!.Value,.1,"%",1,-100,0),
        new(Parameter.Shadows,"阴影","明暗",AdjustmentFieldSpec.Fields.LightShadows.WindowsModel.Min!.Value,AdjustmentFieldSpec.Fields.LightShadows.WindowsModel.Max!.Value,.1,"%",1,100,0),
        new(Parameter.ToneCurve,"S 曲线","明暗",AdjustmentFieldSpec.Fields.LightSCurve.WindowsModel.Min!.Value,AdjustmentFieldSpec.Fields.LightSCurve.WindowsModel.Max!.Value,.1,"%",1,100,0),
        new(Parameter.Saturation,"饱和度","色彩",AdjustmentFieldSpec.Fields.ColorSaturation.WindowsModel.Min!.Value,AdjustmentFieldSpec.Fields.ColorSaturation.WindowsModel.Max!.Value,.1,"%",1,100,1),
        new(Parameter.Sharpening,"锐化","细节",AdjustmentFieldSpec.Fields.DetailSharpening.WindowsModel.Min!.Value,AdjustmentFieldSpec.Fields.DetailSharpening.WindowsModel.Max!.Value,.1,"%",1,100,0)];
}

internal readonly record struct ResolvedNativeWhiteBalance(int WbMode, float Temperature, float Tint);

internal readonly record struct PreparedRecipeSettings(Adjustments Settings, ResolvedNativeWhiteBalance? WhiteBalance)
{
    internal Native.Request Request(string path, string? lut, int edge, string? output, int? longEdge = null) =>
        Settings.Request(path, lut, edge, output, longEdge, WhiteBalance);
}

public sealed class Adjustments
{
    internal const int CurrentProRAWDecodeVersion = 2;
    private double[] values = [1,0,6500,0,1,0,0,0,1,0];
    private GeometrySettings geometry = new();
    public ProcessingIdentity Processing { get; set; } = ProcessingIdentity.Current;
    public X3fMode X3fMode { get; set; } = X3fMode.Normal;
    public HDRSettings? HDR { get; set; }
    // Null keeps ordinary camera RAW and gain-map records on their existing
    // paths; ProRAW HDR explicitly pins the portable decoder revision.
    public int? ProRAWDecodeVersion { get; set; }
    public bool IsHDREditing => HDR?.Mode == HDRMode.Hdr;
    public int ExposureMode { get; set; } = 1;
    public HslSettings Hsl { get; set; } = new();
    public DenoiseSettings Denoise { get; set; } = new();
    public bool AIDenoiseEnabled { get; set; }
    private double aiDenoiseStrength = 100.0;
    public double AIDenoiseStrength
    {
        get => aiDenoiseStrength;
        set
        {
            if (!double.IsFinite(value)) throw new ArgumentOutOfRangeException(nameof(value));
            aiDenoiseStrength = Math.Clamp(value, 0.0, 100.0);
        }
    }
    internal bool HDRCameraAIEnabled { get; set; }
    internal bool ActiveAIDenoise
    {
        get => IsHDREditing ? HDRCameraAIEnabled : AIDenoiseEnabled;
        set
        {
            if (IsHDREditing) HDRCameraAIEnabled = value;
            else AIDenoiseEnabled = value;
        }
    }
    public PhotoEffectsSettings Effects { get; set; } = new();
    public ColorGradingSettings ColorGrading { get; set; } = new();
    internal HslSettings EditingHsl
    {
        get => IsHDREditing ? HDR!.ColorSettings.Hsl : Hsl;
        set
        {
            if (IsHDREditing) HDR = HDR!.WithColor(HDR.ColorSettings with { Hsl = value });
            else Hsl = value;
        }
    }
    internal ColorGradingSettings EditingGrading
    {
        get => IsHDREditing ? HDR!.ColorSettings.Grading : ColorGrading;
        set
        {
            if (IsHDREditing) HDR = HDR!.WithColor(HDR.ColorSettings with { Grading = value });
            else ColorGrading = value;
        }
    }
    public ToneCurveSettings Curve { get; set; } = new();
    internal ToneCurveSettings EditingCurve
    {
        get => IsHDREditing ? HDR!.ToneSettings.Curve : Curve;
        set
        {
            if (IsHDREditing) HDR = HDR!.WithTone(HDR.ToneSettings with { Curve = value });
            else Curve = value;
        }
    }
    public AtmosphereSettings Atmosphere { get; set; } = new();
    public ToneControlsSettings ToneControls { get; set; } = new();
    public CameraCalibrationSettings Calibration { get; set; } = new();
    public PointColorSettings PointColor { get; set; } = new();
    public SelectiveColorSettings SelectiveColor { get; set; } = new();
    public BwMixerSettings BwMixer { get; set; } = new();
    public SharpenV2Settings SharpenV2 { get; set; } = new();
    public FilmOpticsSettings FilmOptics { get; set; } = new();
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
    public double RefinementScale => MasterRecipeID != null && MasterRecipeSettingsVersion >= 4 ? this[Parameter.Strength] : 1;
    public HslSettings RenderHsl => Hsl.Scaled(MasterRecipeID == null || MasterRecipeSettingsVersion < 3 ? 1 : this[Parameter.Strength]);
    public ToneControlsSettings RenderToneControls => ToneControls.Scaled(RefinementScale);
    public AtmosphereSettings RenderAtmosphere => Atmosphere.Scaled(RefinementScale);
    public ColorGradingSettings RenderGrading => ColorGrading.Scaled(RefinementScale);
    public ToneCurveSettings RenderCurve => Curve.Scaled(RefinementScale);
    public void ApplyMasterRecipe(MasterRecipe recipe)
    {
        recipe.Validate();
        MasterRecipeID = recipe.Id;
        MasterRecipeSettingsVersion = recipe.SettingsVersion;
        values[0] = 1;
        values[(int)Parameter.Exposure] = recipe.ExposureDelta;
        values[(int)Parameter.Shadows] = recipe.ShadowsDelta / 100.0;
        values[(int)Parameter.Highlights] = -recipe.HighlightsDelta / 100.0;
        values[(int)Parameter.Contrast] = 1.0 + recipe.ContrastDelta / 100.0;
        values[(int)Parameter.Saturation] = 1.0 + recipe.SaturationDelta / 100.0;
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
        var scale = this[Parameter.Strength];
        var offset = this[Parameter.Tint] * scale;
        if (isRaw && (!CameraWhiteBalance || offset != 0) && AsShot == null)
            throw new System.IO.InvalidDataException(Loc.Text("缺少拍摄时白平衡数据，无法保留配方效果。"));
        var snapshot = Capture().Copy();
        foreach (var parameter in new[] { Parameter.Exposure, Parameter.Highlights, Parameter.Shadows })
            snapshot.Values[(int)parameter] *= scale;
        foreach (var parameter in new[] { Parameter.Contrast, Parameter.Saturation })
            snapshot.Values[(int)parameter] = 1.0 + (snapshot.Values[(int)parameter] - 1.0) * scale;
        var request = Request("", null, 0, null);
        snapshot.Values[(int)Parameter.Tint] = !isRaw ? 0 : request.WbMode == 3
            ? Math.Clamp((AsShot?.Tint ?? 0) + offset, -150, 150) : AsShot?.Tint ?? 0;
        if (!isRaw) snapshot.Values[(int)Parameter.Temperature] = 6500;
        snapshot.Values[(int)Parameter.ToneCurve] = Math.Clamp(this[Parameter.ToneCurve] * RefinementScale, -1, 1);
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
    public double this[Parameter id] => IsHDREditing && HDRSettings.Supports(id)
        ? HDR!.Get(id) : values[(int)id];
    public Adjustments Clone() { var copy = (Adjustments)MemberwiseClone(); copy.values = (double[])values.Clone(); return copy; }
    public AdjustmentSnapshot Capture()
    {
        if (HDR is { } hdr && !hdr.IsValid) throw new System.IO.InvalidDataException(Loc.Text("HDR 调整记录无效，原有文件未被覆盖。"));
        return new((double[])values.Clone(), ExposureMode, CameraWhiteBalance, AsShot?.Temperature, AsShot?.Tint,
        Denoise, Effects, DisplayChromaDenoise, Hsl, MasterRecipeID, Lens, geometry) {
        SettingsVersion = AdjustmentSnapshot.CurrentSettingsVersion,
        Processing = ProcessingIdentity.Require(Processing), X3fMode = X3fMode, AIDenoiseEnabled = AIDenoiseEnabled,
        AIDenoiseBlend = AIDenoiseStrength == 100.0 ? null : AIDenoiseStrength,
        MasterRecipeSettingsVersion = MasterRecipeSettingsVersion,
        HDR = HDR, HDRCameraAIEnabled = HDRCameraAIEnabled,
        ProRAWDecodeVersion = ProRAWDecodeVersion,
        Atmosphere = Atmosphere.IsIdentity ? null : Atmosphere,
        ToneControls = ToneControls.IsIdentity ? null : ToneControls,
        ColorGrading = ColorGrading.IsDefault ? null : ColorGrading,
        Curve = Curve.IsDefault ? null : Curve,
        CameraCalibration = Calibration.IsDefault ? null : Calibration,
        PointColor = PointColor.IsDefault ? null : PointColor,
        SelectiveColor = SelectiveColor.IsDefault ? null : SelectiveColor,
        BwMixer = BwMixer.IsDefault ? null : BwMixer,
        SharpenV2 = SharpenV2.IsDefault ? null : SharpenV2,
        FilmOptics = FilmOptics.IsDefault ? null : FilmOptics
        };
    }
    public static Adjustments FromSnapshot(AdjustmentSnapshot snapshot)
    {
        if (!Enum.IsDefined(snapshot.X3fMode)) throw new System.IO.InvalidDataException("Invalid X3F rendering mode");
        if (snapshot.MasterRecipeSettingsVersion is not (2 or 3 or 4))
            throw new System.IO.InvalidDataException("Invalid master recipe version");
        if (snapshot.SettingsVersion is < 0 or > AdjustmentSnapshot.CurrentSettingsVersion ||
            snapshot.Values.Length != ParameterSpec.All.Length || snapshot.ExposureMode is < 0 or > 2)
            throw new System.IO.InvalidDataException(Loc.Text("调整记录无效，原有文件未被覆盖。"));
        double[] migrated;
        if (snapshot.SettingsVersion < AdjustmentSnapshot.CurrentSettingsVersion)
        {
            for (var i = 0; i < snapshot.Values.Length; i++)
            {
                var v = snapshot.Values[i];
                var (min, max) = (Parameter)i switch
                {
                    Parameter.Strength or Parameter.Sharpening => (0.0, 200.0),
                    Parameter.Contrast or Parameter.Highlights or Parameter.Shadows or Parameter.ToneCurve or Parameter.Saturation => (-100.0, 100.0),
                    _ => (ParameterSpec.All[i].Min, ParameterSpec.All[i].Max)
                };
                if (!double.IsFinite(v) || v < min || v > max)
                    throw new System.IO.InvalidDataException(Loc.Text("调整记录无效，原有文件未被覆盖。"));
            }
            migrated = (double[])snapshot.Values.Clone();
            migrated[(int)Parameter.Strength] = snapshot.Values[(int)Parameter.Strength] / 100.0;
            migrated[(int)Parameter.Contrast] = 1.0 + snapshot.Values[(int)Parameter.Contrast] / 100.0;
            migrated[(int)Parameter.Highlights] = -snapshot.Values[(int)Parameter.Highlights] / 100.0;
            migrated[(int)Parameter.Shadows] = snapshot.Values[(int)Parameter.Shadows] / 100.0;
            migrated[(int)Parameter.ToneCurve] = snapshot.Values[(int)Parameter.ToneCurve] / 100.0;
            migrated[(int)Parameter.Saturation] = 1.0 + snapshot.Values[(int)Parameter.Saturation] / 100.0;
            migrated[(int)Parameter.Sharpening] = snapshot.Values[(int)Parameter.Sharpening] / 100.0;
        }
        else
        {
            migrated = (double[])snapshot.Values.Clone();
        }
        if (migrated.Where((value, index) => !double.IsFinite(value) || value < ParameterSpec.All[index].Min || value > ParameterSpec.All[index].Max).Any())
            throw new System.IO.InvalidDataException(Loc.Text("调整记录无效，原有文件未被覆盖。"));
        var denoise = snapshot.Denoise ?? new DenoiseSettings();
        var effects = snapshot.Effects ?? new PhotoEffectsSettings();
        var geometry = snapshot.Geometry ?? new GeometrySettings();
        if (snapshot.HDR is { } hdr && !hdr.IsValid)
            throw new System.IO.InvalidDataException(Loc.Text("HDR 调整记录无效，原有文件未被覆盖。"));
        if (snapshot.HDRCameraAIEnabled && (snapshot.HDR?.CameraSettings.AllowsAI != true || snapshot.ProRAWDecodeVersion != null))
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
        var lens = snapshot.Lens ?? new();
        lens.Validate();
        var calibration = snapshot.CameraCalibration ?? new();
        calibration.Validate();
        var pointColor = snapshot.PointColor ?? new();
        pointColor.Validate();
        var selectiveColor = snapshot.SelectiveColor ?? new();
        selectiveColor.Validate();
        var bwMixer = snapshot.BwMixer ?? new();
        bwMixer.Validate();
        var sharpenV2 = snapshot.SharpenV2 ?? new();
        sharpenV2.Validate();
        var filmOptics = snapshot.FilmOptics ?? new();
        filmOptics.Validate();
        if (snapshot.DisplayChromaDenoise is < 0 or > 2)
            throw new System.IO.InvalidDataException("调整记录中的显示色彩降噪模式无效，原有文件未被覆盖。");
        if (!double.IsFinite(snapshot.AIDenoiseStrength) || snapshot.AIDenoiseStrength is < 0 or > 100)
            throw new System.IO.InvalidDataException(Loc.Text("调整记录无效，原有文件未被覆盖。"));
        var result = new Adjustments {
            Processing = ProcessingIdentity.Require(snapshot.Processing),
            X3fMode = snapshot.X3fMode,
            Denoise = denoise,
            AIDenoiseEnabled = snapshot.AIDenoiseEnabled,
            AIDenoiseStrength = snapshot.AIDenoiseStrength,
            HDRCameraAIEnabled = snapshot.HDRCameraAIEnabled,
            Effects = effects,
            ToneControls = tone,
            Atmosphere = atmosphere,
            ColorGrading = grading,
            Curve = snapshot.Curve ?? new(),
            Calibration = calibration,
            PointColor = pointColor,
            SelectiveColor = selectiveColor,
            BwMixer = bwMixer,
            SharpenV2 = sharpenV2,
            FilmOptics = filmOptics,
            Hsl = snapshot.Hsl ?? new HslSettings(),
            MasterRecipeID = snapshot.MasterRecipeID,
            MasterRecipeSettingsVersion = snapshot.MasterRecipeSettingsVersion,
            Lens = lens,
            DisplayChromaDenoise = snapshot.DisplayChromaDenoise,
            values = migrated, ExposureMode = snapshot.ExposureMode,
            CameraWhiteBalance = snapshot.CameraWhiteBalance,
            AsShot = snapshot.AsShotTemperature is {} temperature && snapshot.AsShotTint is {} tint ? (temperature, tint) : null,
            HDR = snapshot.HDR,
            ProRAWDecodeVersion = snapshot.ProRAWDecodeVersion
        };
        result.geometry = geometry;
        return result;
    }
    public double Default(Parameter id) => IsHDREditing && (id is Parameter.Temperature or Parameter.Tint) ? id == Parameter.Temperature ? 6500 : 0 :
        id is Parameter.Strength or Parameter.Contrast or Parameter.Saturation ? 1 :
        id == Parameter.Temperature ? AsShot?.Temperature ?? 6500 : id == Parameter.Tint ? (MasterRecipeID == null ? AsShot?.Tint ?? 0 : 0) : 0;
    public void Set(Parameter id, double value)
    {
        if (!double.IsFinite(value)) throw new ArgumentOutOfRangeException(nameof(value));
        if (IsHDREditing && HDRSettings.Supports(id))
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
    public void SetRasterWhiteBalance(Parameter id, double value)
    {
        if (id is not (Parameter.Temperature or Parameter.Tint))
        {
            Set(id, value);
            return;
        }
        if (!double.IsFinite(value)) throw new ArgumentOutOfRangeException(nameof(value));
        if (IsHDREditing && HDRSettings.Supports(id))
        {
            HDR = HDR!.Set(id, value);
            return;
        }
        var spec = ParameterSpec.All[(int)id];
        values[(int)id] = Math.Clamp(value, spec.Min, spec.Max);
        AsShot = null;
        CameraWhiteBalance = true;
    }
    public void SetRelativeWhiteBalance(double temperature, double tint)
    {
        if (!double.IsFinite(temperature) || !double.IsFinite(tint))
            throw new ArgumentOutOfRangeException(nameof(temperature));
        if (IsHDREditing)
        {
            HDR = HDR!.Set(Parameter.Temperature, temperature).Set(Parameter.Tint, tint);
            return;
        }
        var tempSpec = ParameterSpec.All[(int)Parameter.Temperature];
        var tintSpec = ParameterSpec.All[(int)Parameter.Tint];
        values[(int)Parameter.Temperature] = Math.Clamp(temperature, tempSpec.Min, tempSpec.Max);
        values[(int)Parameter.Tint] = Math.Clamp(tint, tintSpec.Min, tintSpec.Max);
        AsShot = null;
        CameraWhiteBalance = true;
    }
    internal void ClearAsShotWhiteBalance() => AsShot = null;
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
        var percent = Math.Clamp(value, -100, 100);
        if (id != AtmosphereParameter.Texture && IsHDREditing && HDR is { } hdr) {
            var detail = hdr.DetailSettings;
            HDR = hdr.WithDetail(id switch {
                AtmosphereParameter.Clarity => detail with { Clarity = percent / 100 },
                AtmosphereParameter.Dehaze => detail with { Dehaze = percent / 100 },
                _ => throw new ArgumentOutOfRangeException(nameof(id))
            });
        } else Atmosphere = Atmosphere.With(id, percent);
    }
    internal double EditingAtmosphereValue(AtmosphereParameter id) => id != AtmosphereParameter.Texture && IsHDREditing && HDR is { } hdr ? id switch {
        AtmosphereParameter.Clarity => hdr.DetailSettings.Clarity * 100,
        AtmosphereParameter.Dehaze => hdr.DetailSettings.Dehaze * 100,
        _ => throw new ArgumentOutOfRangeException(nameof(id))
    } : Atmosphere[id];
    public void SetTone(ToneControlParameter id, double value)
    {
        if (!double.IsFinite(value)) throw new ArgumentOutOfRangeException(nameof(value));
        var bounded = Math.Clamp(Math.Round(value, 1, MidpointRounding.AwayFromZero), -100, 100);
        if (IsHDREditing && HDRSettings.Supports(id)) {
            var hdr = HDR!;
            HDR = id switch {
                ToneControlParameter.BlackPoint => hdr.WithTone(hdr.ToneSettings with { BlackPoint = bounded }),
                ToneControlParameter.WhitePoint => hdr.WithTone(hdr.ToneSettings with { WhitePoint = bounded }),
                _ => hdr.WithColor(hdr.ColorSettings with { Vibrance = bounded })
            };
        } else ToneControls = ToneControls.With(id, bounded);
    }
    internal double EditingToneValue(ToneControlParameter id) => IsHDREditing ? id switch {
        ToneControlParameter.BlackPoint => HDR!.ToneSettings.BlackPoint,
        ToneControlParameter.WhitePoint => HDR!.ToneSettings.WhitePoint,
        ToneControlParameter.Vibrance => HDR!.ColorSettings.Vibrance,
        _ => ToneControls[id]
    } : ToneControls[id];
    internal double EditingHDRRenditionValue(HDRRenditionParameter id) =>
        IsHDREditing && HDR is { } hdr ? hdr.RenditionSettings[id] : 0;
    internal void SetHDRRendition(HDRRenditionParameter id, double value)
    {
        if (!double.IsFinite(value)) throw new ArgumentOutOfRangeException(nameof(value));
        if (!IsHDREditing || HDR is not { } hdr) return;
        var spec = HDRRenditionSpec.For(id);
        var bounded = Math.Clamp(Math.Round(value, spec.Grid < 1 ? 1 : 0, MidpointRounding.AwayFromZero), spec.Min, spec.Max);
        HDR = hdr.WithRendition(hdr.RenditionSettings.With(id, bounded));
    }
    public void Reset(Parameter id) => Set(id, Default(id));
    public double EffectDefault(PhotoEffectParameter id) => PhotoEffectSpec.For(id).DefaultValue;
    internal PhotoEffectsSettings EditingEffects {
        get => IsHDREditing ? HDR!.EffectSettings : Effects;
        set {
            if (IsHDREditing) HDR=HDR!.WithEffects(value);
            else Effects=value;
        }
    }
    public void SetEffect(PhotoEffectParameter id, double value)
    {
        if (!double.IsFinite(value)) throw new ArgumentOutOfRangeException(nameof(value));
        var spec = PhotoEffectSpec.For(id);
        value = Math.Clamp(Math.Round(value, 1, MidpointRounding.AwayFromZero), spec.Min, spec.Max);
        var effects = EditingEffects;
        EditingEffects = id switch {
            PhotoEffectParameter.VignetteAmount => effects with { VignetteAmount = value },
            PhotoEffectParameter.VignetteMidpoint => effects with { VignetteMidpoint = value },
            PhotoEffectParameter.VignetteRoundness => effects with { VignetteRoundness = value },
            PhotoEffectParameter.VignetteFeather => effects with { VignetteFeather = value },
            PhotoEffectParameter.VignetteHighlights => effects with { VignetteHighlights = value },
            PhotoEffectParameter.GrainAmount => effects with { GrainAmount = value },
            PhotoEffectParameter.GrainSize => effects with { GrainSize = value },
            PhotoEffectParameter.GrainRoughness => effects with { GrainRoughness = value },
            _ => throw new ArgumentOutOfRangeException(nameof(id))
        };
    }
    public void ResetEffect(PhotoEffectParameter id) => SetEffect(id, EffectDefault(id));
    public bool IsEffectDefault(bool vignette) =>
        PhotoEffectSpec.All.Where(x => x.IsVignette == vignette)
            .All(spec => EditingEffects[spec.Id] == spec.DefaultValue)
        && (vignette || (EditingEffects.GrainToneCurve == GrainToneCurve.Legacy
            && EditingEffects.GrainFormatPreset == GrainFormatPreset.Custom));
    public void ResetGroup(string group)
    {
        foreach (var spec in ParameterSpec.All.Where(p => p.Group == group)) Reset(spec.Id);
        if (group == "输入") { ExposureMode = 1; ResetWhiteBalance(); }
        if (group == "色彩") { ColorGrading = new(); Hsl = new(); ToneControls = ToneControls with { Vibrance = 0 }; Calibration = new(); PointColor = new(); SelectiveColor = new(); BwMixer = new(); }
        if (group == "明暗") { Curve = new(); ToneControls = ToneControls with { BlackPoint = 0, WhitePoint = 0 }; }
        if (group == "细节") { ActiveAIDenoise = false; AIDenoiseStrength = 100.0; Denoise = new(); DisplayChromaDenoise = 0; SharpenV2 = new(); }
        if (group == "效果") { Effects = new(); Atmosphere = new(); FilmOptics = new(); }
        if (group == "镜头") Lens = new();
        if (group == "几何") Geometry = new();
    }

    public void RequireHDRDecodeVersion(bool proRAW)
    {
        if (proRAW)
        {
            if (ProRAWDecodeVersion is { } storedVersion && storedVersion != CurrentProRAWDecodeVersion)
                throw new HDRModeException(HDRModeFailure.InvalidSettings);
        }
        else if (ProRAWDecodeVersion != null)
            throw new HDRModeException(HDRModeFailure.InvalidSettings);
    }

    public void RequireActiveHDRDecodeVersion(bool? sourceIsProRAW = null)
    {
        if (!IsHDREditing) return;
        if (ProRAWDecodeVersion is { } storedVersion && storedVersion != CurrentProRAWDecodeVersion)
            throw new HDRModeException(HDRModeFailure.InvalidSettings);
        if (sourceIsProRAW is { } proRAW &&
            ProRAWDecodeVersion != (proRAW ? CurrentProRAWDecodeVersion : (int?)null))
            throw new HDRModeException(proRAW ? HDRModeFailure.InvalidSettings : HDRModeFailure.UnsupportedSource);
    }

    public void SetHDRMode(bool enabled, bool sourceIsHDR, bool cameraRaw = false,
        bool proRAW = false)
    {
        if (enabled)
        {
            if (proRAW && !cameraRaw) throw new HDRModeException(HDRModeFailure.UnsupportedSource);
            RequireHDRDecodeVersion(proRAW);
            if (proRAW) ProRAWDecodeVersion = CurrentProRAWDecodeVersion;
            var initial = cameraRaw ? new HDRSettings { Geometry = Geometry } : HDRSettings.FromSdr(this);
            HDR = HDRSettings.Enabling(HDR, initial, sourceIsHDR);
            return;
        }
        if (HDR is { } hdr) HDR = hdr with { Mode = HDRMode.Sdr };
    }

    public void ApplySharpenV2Edit(double? amount = null, double? radius = null, double? detail = null,
        double? masking = null, bool? luminanceV2 = null)
    {
        if (IsHDREditing)
        {
            if (amount is { } hdrAmount && double.IsFinite(hdrAmount))
                Set(Parameter.Sharpening, Math.Clamp(hdrAmount, 0, 2));
            return;
        }
        var v2 = SharpenV2;
        if (amount is { } nextAmount && double.IsFinite(nextAmount))
        {
            var clamped = Math.Clamp(nextAmount, 0, 2);
            var preserveLegacy = this[Parameter.Sharpening] > 0 && !v2.LuminanceV2 && v2.IsDefault;
            Set(Parameter.Sharpening, clamped);
            if (!preserveLegacy && clamped > 0 && !v2.LuminanceV2)
                v2 = v2 with { LuminanceV2 = true };
        }
        if (luminanceV2 is { } lum)
            v2 = v2 with { LuminanceV2 = lum };
        if (radius is { } r && double.IsFinite(r))
        {
            var spec = AdjustmentFieldSpec.Fields.DetailSharpeningRadius.WindowsModel;
            var bounded = Math.Clamp(r, spec.Min!.Value, spec.Max!.Value);
            v2 = v2 with { Radius = bounded, LuminanceV2 = true };
        }
        if (detail is { } d && double.IsFinite(d))
        {
            var spec = AdjustmentFieldSpec.Fields.DetailSharpeningDetail.WindowsModel;
            var bounded = Math.Clamp(d, spec.Min!.Value, spec.Max!.Value);
            v2 = v2 with { Detail = bounded == 0 ? 0 : bounded, LuminanceV2 = true };
        }
        if (masking is { } m && double.IsFinite(m))
        {
            var spec = AdjustmentFieldSpec.Fields.DetailSharpeningMasking.WindowsModel;
            var bounded = Math.Clamp(m, spec.Min!.Value, spec.Max!.Value);
            v2 = v2 with { Masking = bounded == 0 ? 0 : bounded, LuminanceV2 = true };
        }
        SharpenV2 = v2;
    }

    internal Native.Request Request(string path, string? lut, int edge, string? output, int? longEdge = null, ResolvedNativeWhiteBalance? resolvedWhiteBalance = null)
    {
        if (longEdge is { } requested && !ExportSize.IsValid(requested))
            throw new ArgumentOutOfRangeException(nameof(longEdge), Loc.Text("导出长边必须为 1-65535 像素。"));
        var limitedFinal = output != null && longEdge.HasValue;
        var scale = MasterRecipeID == null ? 1 : this[Parameter.Strength];
        int wbMode;
        float temperature, tint;
        if (resolvedWhiteBalance is { } wb)
        {
            wbMode = wb.WbMode;
            temperature = wb.WbMode == 3 ? wb.Temperature : 6500f;
            tint = wb.WbMode == 3 ? wb.Tint : 0f;
        }
        else if (PhotoInput.IsRaster(path))
        {
            var relativeActive = MasterRecipeID == null && (this[Parameter.Temperature] != 6500 || this[Parameter.Tint] != 0);
            wbMode = relativeActive ? 4 : 0;
            temperature = relativeActive ? (float)this[Parameter.Temperature] : 6500f;
            tint = relativeActive ? (float)this[Parameter.Tint] : 0f;
        }
        else
        {
            var tintOffset = MasterRecipeID == null ? 0 : this[Parameter.Tint] * scale;
            var temperatureWb = !CameraWhiteBalance || tintOffset != 0;
            var effectiveTint = MasterRecipeID == null ? this[Parameter.Tint] : Math.Clamp((AsShot?.Tint ?? 0) + tintOffset, -150, 150);
            wbMode = temperatureWb ? 3 : 0;
            temperature = temperatureWb ? (float)this[Parameter.Temperature] : 6500f;
            tint = temperatureWb ? (float)effectiveTint : 0f;
        }
        return new Native.Request {
            Version=2, StructSize=(uint)System.Runtime.InteropServices.Marshal.SizeOf<Native.Request>(), InputPath=path,
            LutPath=lut, LutStrength=lut == null ? 0 : (float)this[Parameter.Strength],
            WbMode=wbMode, Wb0=1,Wb1=1,Wb2=1,Wb3=1,
            ExposureEv=(float)(this[Parameter.Exposure]*scale), Brightness=1, Contrast=(float)(1.0+(this[Parameter.Contrast]-1.0)*scale),
            Saturation=(float)(1.0+(this[Parameter.Saturation]-1.0)*scale), Temperature=temperature,
            Tint=tint, Highlights=(float)(this[Parameter.Highlights]*scale),
            Shadows=(float)(this[Parameter.Shadows]*scale),ToneCurve=Curve.Mode == ToneCurveMode.Custom ? 0 : (float)Math.Clamp(this[Parameter.ToneCurve]*RefinementScale,-1,1),Sharpening=(float)this[Parameter.Sharpening],
            // SizeMode 4 is the shared final long-edge contract. PreviewLongEdge
            // remains independent and is never used to size an export.
            SizeMode=limitedFinal ? 4 : 3,LongEdge=limitedFinal ? (uint)longEdge!.Value : 0,
            OutputTarget=output == null ? 1 : 0,OutputPath=output,
            OutputFormat=output == null ? 3 : ExportFormatExtensions.FromPath(output).NativeValue(),
            JpegQuality=95, Intent=output != null || edge == 0 ? 1 : 0, PreviewLongEdge=(uint)edge
        };
    }
}

// 提交与开启/完成仍在 UI 线程；Revision 可由渲染后台线程无锁读取以检测陈旧任务。
public sealed class LatestWork<T> where T : class
{
    public record Ticket(long Id, T Value);
    private Ticket? pending;
    private long revision;
    internal Ticket? Pending => pending;
    public Ticket? Active { get; private set; }
    public long Revision => Volatile.Read(ref revision);
    public bool Busy => Active != null || pending != null;
    public void Submit(T value) => pending = new Ticket(Interlocked.Increment(ref revision), value);
    public Ticket? Start() { if (Active != null) return null; Active = pending; pending = null; return Active; }
    public bool Finish(Ticket ticket) { if (Active != ticket) return false; Active = null; return ticket.Id == Volatile.Read(ref revision); }
}
