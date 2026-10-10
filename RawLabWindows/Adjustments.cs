using System.Globalization;

namespace RawLab.Windows;

public enum Parameter { Strength, Exposure, Temperature, Tint, Contrast, Highlights, Shadows, ToneCurve, Saturation, Sharpening }
public sealed record ParameterSpec(Parameter Id, string Title, string Group, double Min, double Max, double Step, string Unit, int Decimals = 0)
{
    public double Position(double v) => Id == Parameter.Temperature
        ? (1 / Min - 1 / v) / (1 / Min - 1 / Max) : (v - Min) / (Max - Min);
    public double Value(double position)
    {
        position = Math.Clamp(position, 0, 1);
        var v = Id == Parameter.Temperature ? 1 / (1 / Min - position * (1 / Min - 1 / Max)) : Min + position * (Max - Min);
        return Math.Clamp(Math.Round(v / Step) * Step, Min, Max);
    }
    public double? Parse(string text) => double.TryParse(text, NumberStyles.Float, CultureInfo.CurrentCulture, out var value) && double.IsFinite(value)
        ? Math.Clamp(value, Min, Max) : null;
    public static readonly ParameterSpec[] All = [
        new(Parameter.Strength,"强度","胶片",0,200,1,"%"), new(Parameter.Exposure,"曝光","输入",-4,4,.05,"EV",2),
        new(Parameter.Temperature,"色温","输入",2000,50000,10,"K"), new(Parameter.Tint,"色调","输入",-150,150,1,""),
        new(Parameter.Contrast,"对比度","明暗",-100,100,1,"%"), new(Parameter.Highlights,"高光","明暗",-100,100,1,"%"),
        new(Parameter.Shadows,"阴影","明暗",-100,100,1,"%"), new(Parameter.ToneCurve,"S 曲线","明暗",-100,100,1,"%"),
        new(Parameter.Saturation,"饱和度","色彩",-100,100,1,"%"), new(Parameter.Sharpening,"锐化","细节",0,200,1,"%")];
}

public sealed class Adjustments
{
    private double[] values = [100,0,6500,0,0,0,0,0,0,0];
    public int ExposureMode { get; set; }
    public DenoiseSettings Denoise { get; set; } = new();
    public PhotoEffectsSettings Effects { get; set; } = new();
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
    public double this[Parameter id] => values[(int)id];
    public Adjustments Clone() { var copy = (Adjustments)MemberwiseClone(); copy.values = (double[])values.Clone(); return copy; }
    public AdjustmentSnapshot Capture() => new((double[])values.Clone(), ExposureMode, CameraWhiteBalance, AsShot?.Temperature, AsShot?.Tint,
        Denoise, Effects, DisplayChromaDenoise);
    public static Adjustments FromSnapshot(AdjustmentSnapshot snapshot)
    {
        if (snapshot.Values.Length != ParameterSpec.All.Length || snapshot.ExposureMode is < 0 or > 2 ||
            snapshot.Values.Where((value, index) => !double.IsFinite(value) || value < ParameterSpec.All[index].Min || value > ParameterSpec.All[index].Max).Any())
            throw new System.IO.InvalidDataException("调整记录无效，原有文件未被覆盖。");
        var denoise = snapshot.Denoise ?? new DenoiseSettings();
        var effects = snapshot.Effects ?? new PhotoEffectsSettings();
        _ = denoise.NativeConfig();
        _ = effects.NativeConfig();
        if (snapshot.DisplayChromaDenoise is < 0 or > 2)
            throw new System.IO.InvalidDataException("调整记录中的显示色彩降噪模式无效，原有文件未被覆盖。");
        return new Adjustments {
            Denoise = denoise,
            Effects = effects,
            DisplayChromaDenoise = snapshot.DisplayChromaDenoise,
            values = (double[])snapshot.Values.Clone(), ExposureMode = snapshot.ExposureMode,
            CameraWhiteBalance = snapshot.CameraWhiteBalance,
            AsShot = snapshot.AsShotTemperature is {} temperature && snapshot.AsShotTint is {} tint ? (temperature, tint) : null
        };
    }
    public double Default(Parameter id) => id == Parameter.Strength ? 100 : id == Parameter.Temperature ? AsShot?.Temperature ?? 6500 : id == Parameter.Tint ? AsShot?.Tint ?? 0 : 0;
    public void Set(Parameter id, double value)
    {
        if (!double.IsFinite(value)) throw new ArgumentOutOfRangeException(nameof(value));
        var spec = ParameterSpec.All[(int)id];
        values[(int)id] = Math.Clamp(value, spec.Min, spec.Max);
        if (id is Parameter.Temperature or Parameter.Tint)
            CameraWhiteBalance = AsShot is { } wb && this[Parameter.Temperature] == wb.Temperature && this[Parameter.Tint] == wb.Tint;
    }
    public void ResolveWhiteBalance((double Temperature, double Tint)? wb) { AsShot = wb; if (CameraWhiteBalance) ResetWhiteBalance(); }
    public void ResetWhiteBalance() { values[2] = Default(Parameter.Temperature); values[3] = Default(Parameter.Tint); CameraWhiteBalance = true; }
    public void Reset(Parameter id) => Set(id, Default(id));
    public double EffectDefault(PhotoEffectParameter id) => PhotoEffectSpec.For(id).DefaultValue;
    public void SetEffect(PhotoEffectParameter id, double value)
    {
        if (!double.IsFinite(value)) throw new ArgumentOutOfRangeException(nameof(value));
        var spec = PhotoEffectSpec.For(id);
        value = Math.Clamp(Math.Round(value, MidpointRounding.AwayFromZero), spec.Min, spec.Max);
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
        if (group == "输入") { ExposureMode = 0; ResetWhiteBalance(); }
        if (group == "细节") { Denoise = new(); DisplayChromaDenoise = 0; }
        if (group == "效果") Effects = new();
    }
    public void ResetAll() { foreach (var spec in ParameterSpec.All) Reset(spec.Id); ExposureMode = 0; ResetWhiteBalance(); Denoise = new(); Effects = new(); DisplayChromaDenoise = 0; }
    internal Native.Request Request(string path, string? lut, int edge, string? output, int? longEdge = null)
    {
        if (longEdge is { } requested && !ExportSize.IsValid(requested))
            throw new ArgumentOutOfRangeException(nameof(longEdge), "导出长边必须在 1 到 65535 像素之间。");
        var limitedFinal = output != null && longEdge.HasValue;
        return new Native.Request {
            Version=2, StructSize=(uint)System.Runtime.InteropServices.Marshal.SizeOf<Native.Request>(), InputPath=path,
            LutPath=lut, LutStrength=lut == null ? 0 : (float)this[Parameter.Strength]/100,
            WbMode=CameraWhiteBalance ? 0 : 3, Wb0=1,Wb1=1,Wb2=1,Wb3=1,
            ExposureEv=(float)this[Parameter.Exposure], Brightness=1, Contrast=1+(float)this[Parameter.Contrast]/100,
            Saturation=1+(float)this[Parameter.Saturation]/100, Temperature=CameraWhiteBalance ? 6500 : (float)this[Parameter.Temperature],
            Tint=CameraWhiteBalance ? 0 : (float)this[Parameter.Tint], Highlights=-(float)this[Parameter.Highlights]/100,
            Shadows=(float)this[Parameter.Shadows]/100,ToneCurve=(float)this[Parameter.ToneCurve]/100,Sharpening=(float)this[Parameter.Sharpening]/100,
            // SizeMode 4 is the shared final long-edge contract. PreviewLongEdge
            // remains independent and is never used to size an export.
            SizeMode=limitedFinal ? 4 : 3,LongEdge=limitedFinal ? (uint)longEdge!.Value : 0,
            OutputTarget=output == null ? 1 : 0,OutputPath=output,
            OutputFormat=output == null ? 3 : System.IO.Path.GetExtension(output).Equals(".png",StringComparison.OrdinalIgnoreCase) ? 1 : 0,
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
