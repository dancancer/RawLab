using System.Globalization;

namespace RawLab.Windows;

public sealed record NumericRange(double Min, double Max, double Grid = .1, double Wheel = 1,
    double FineWheel = .1, bool Reciprocal = false, int FixedDecimals = -1)
{
    public double Clamp(double value) => Math.Clamp(Math.Round(value / Grid, MidpointRounding.AwayFromZero) * Grid, Min, Max);
    public double Position(double value) => Reciprocal
        ? (1 / Min - 1 / value) / (1 / Min - 1 / Max) : (value - Min) / (Max - Min);
    public double Value(double position) => Clamp(Reciprocal
        ? 1 / (1 / Min - Math.Clamp(position, 0, 1) * (1 / Min - 1 / Max))
        : Min + Math.Clamp(position, 0, 1) * (Max - Min));
    public NumericInputError Validate(string text, double? original, out double value)
    {
        if(!double.TryParse(text,NumberStyles.Float,CultureInfo.GetCultureInfo(Loc.Language),out value) || !double.IsFinite(value))return NumericInputError.Invalid;
        if(value<Min || value>Max)return NumericInputError.Range;
        if(value==original)return NumericInputError.None;
        var units=value/Grid;
        return Math.Abs(units-Math.Round(units))<=1e-8*Math.Max(1,Math.Abs(units)) ? NumericInputError.None : NumericInputError.Grid;
    }
    public double? Parse(string text,double? original=null) => Validate(text,original,out var value)==NumericInputError.None ? value : null;
    public string Format(double value)
    {
        var culture=CultureInfo.GetCultureInfo(Loc.Language);
        var text=value.ToString(FixedDecimals>=0 ? "F"+FixedDecimals : "G",culture);
        return double.TryParse(text,NumberStyles.Float,culture,out var shown) && shown==value ? text : value.ToString("G",culture);
    }
    public (double Start,double End) Fill(double origin,double current) => (Math.Min(Position(origin),Position(current)),Math.Max(Position(origin),Position(current)));
    public static NumericRange For(ParameterSpec spec) => new(spec.Min, spec.Max, spec.Step,
        spec.Id == Parameter.Exposure ? .1 : spec.Id == Parameter.Temperature ? 100 : 1,
        spec.Id == Parameter.Exposure ? .01 : spec.Id == Parameter.Temperature ? 10 : .1,
        spec.Id == Parameter.Temperature, spec.Id == Parameter.Exposure ? 2 : -1);
}

// 每次输入只推进一步，不在事件结束后排队追赶。
public sealed class ParameterWheel
{
    private double remainder;
    private long? lastEvent, lastStep;
    private int direction;
    private bool shift;
    public void Reset() { remainder = 0; lastEvent = lastStep = null; direction = 0; }
    public (bool Consumed, int Steps) Feed(double verticalPixels, double horizontalPixels, bool fine, long milliseconds, bool editable)
    {
        if (!editable || !double.IsFinite(verticalPixels) || !double.IsFinite(horizontalPixels) || verticalPixels == 0 ||
            Math.Abs(horizontalPixels) >= Math.Abs(verticalPixels)) { Reset(); return (false, 0); }
        var nextDirection = Math.Sign(verticalPixels);
        if (lastEvent == null || milliseconds - lastEvent >= 200 || nextDirection != direction || fine != shift)
            remainder = 0;
        lastEvent = milliseconds; direction = nextDirection; shift = fine;
        remainder += verticalPixels;
        if (Math.Abs(remainder) < 80) return (true, 0);
        // 清除本事件多余动量，限速期间也不留下待执行的步进。
        remainder = 0;
        if (lastStep != null && milliseconds - lastStep < 125) return (true, 0);
        lastStep = milliseconds;
        return (true, direction);
    }
}

public enum NumericInputError { None, Invalid, Range, Grid }

// 只持有输入草稿；源和字段身份变化时丢弃，不能把旧文本交给新的回调。
public sealed class NumericInputSession
{
    private object? source,scope;
    private NumericRange range=new(0,100);
    private bool bound;
    public double Original { get; private set; }
    public string Text { get; private set; }="";
    public bool Dirty { get; private set; }
    public NumericInputError Error { get; private set; }
    public bool Bind(object? nextSource,object? nextScope,NumericRange limits,double current)
    {
        var changed=!bound || !Equals(source,nextSource) || !Equals(scope,nextScope) || range!=limits || Original!=current;
        source=nextSource;scope=nextScope;range=limits;bound=true;
        if(changed){Original=current;Cancel();}
        return changed;
    }
    public void Edit(string text){Text=text;Dirty=true;Error=NumericInputError.None;}
    public void Cancel(){Text=range.Format(Original);Dirty=false;Error=NumericInputError.None;}
    public double? Commit()
    {
        if(!Dirty)return null;
        Error=range.Validate(Text,Original,out var next);
        if(Error!=NumericInputError.None)return null;
        var changed=next!=Original;Original=next;Cancel();return changed ? next : null;
    }
}
