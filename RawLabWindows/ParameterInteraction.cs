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
    public double? Parse(string text) => double.TryParse(text, NumberStyles.Float, CultureInfo.CurrentCulture, out var value)
        && double.IsFinite(value) ? Clamp(value) : null;
    public string Format(double value) => value.ToString(FixedDecimals >= 0 ? "F" + FixedDecimals : "0.########", CultureInfo.CurrentCulture);
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
