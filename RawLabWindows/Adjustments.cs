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
    public bool CameraWhiteBalance { get; private set; } = true;
    public (double Temperature, double Tint)? AsShot { get; private set; }
    public double this[Parameter id] => values[(int)id];
    public Adjustments Clone() { var copy = (Adjustments)MemberwiseClone(); copy.values = (double[])values.Clone(); return copy; }
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
    public void ResetGroup(string group)
    {
        foreach (var spec in ParameterSpec.All.Where(p => p.Group == group)) Reset(spec.Id);
        if (group == "输入") { ExposureMode = 0; ResetWhiteBalance(); }
        if (group == "细节") Denoise = new();
    }
    public void ResetAll() { foreach (var spec in ParameterSpec.All) Reset(spec.Id); ExposureMode = 0; ResetWhiteBalance(); Denoise = new(); }
    internal Native.Request Request(string path, string? lut, int edge, string? output)
    {
        return new Native.Request {
            Version=2, StructSize=(uint)System.Runtime.InteropServices.Marshal.SizeOf<Native.Request>(), InputPath=path,
            LutPath=lut, LutStrength=lut == null ? 0 : (float)this[Parameter.Strength]/100,
            WbMode=CameraWhiteBalance ? 0 : 3, Wb0=1,Wb1=1,Wb2=1,Wb3=1,
            ExposureEv=(float)this[Parameter.Exposure], Brightness=1, Contrast=1+(float)this[Parameter.Contrast]/100,
            Saturation=1+(float)this[Parameter.Saturation]/100, Temperature=CameraWhiteBalance ? 6500 : (float)this[Parameter.Temperature],
            Tint=CameraWhiteBalance ? 0 : (float)this[Parameter.Tint], Highlights=-(float)this[Parameter.Highlights]/100,
            Shadows=(float)this[Parameter.Shadows]/100,ToneCurve=(float)this[Parameter.ToneCurve]/100,Sharpening=(float)this[Parameter.Sharpening]/100,
            SizeMode=3,OutputTarget=output == null ? 1 : 0,OutputPath=output,
            OutputFormat=output == null ? 3 : System.IO.Path.GetExtension(output).Equals(".png",StringComparison.OrdinalIgnoreCase) ? 1 : 0,
            JpegQuality=95, Intent=edge == 0 ? 1 : 0, PreviewLongEdge=(uint)edge
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
