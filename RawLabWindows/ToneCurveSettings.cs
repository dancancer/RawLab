using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RawLab.Windows;

public enum ToneCurveMode { Legacy, Custom }
public readonly record struct ToneCurvePoint(double X, double Y);

[JsonConverter(typeof(ToneCurveJsonConverter))]
public sealed class ToneCurveSettings : IEquatable<ToneCurveSettings>
{
    public ToneCurveMode Mode { get; }
    public IReadOnlyList<ToneCurvePoint> Points { get; }
    public ToneCurveSettings(ToneCurveMode mode = ToneCurveMode.Legacy, IEnumerable<ToneCurvePoint>? points = null)
    {
        Mode = mode; Points = Array.AsReadOnly((points ?? []).ToArray());
        if (!IsValid) throw new ArgumentOutOfRangeException(nameof(points), "Invalid curve points");
    }
    public static ToneCurveSettings Identity { get; } = new(ToneCurveMode.Custom, [new(0, 0), new(1, 1)]);
    public bool IsDefault => Mode == ToneCurveMode.Legacy;
    public bool IsIdentity => IsDefault || Points.All(p => p.X == p.Y);
    public double Progress => Points.Count == 0 ? 0 : Points.Max(p => Math.Abs(p.Y - p.X));
    private bool IsValid => Mode == ToneCurveMode.Legacy ? Points.Count == 0 : Mode == ToneCurveMode.Custom &&
        Points.Count is >= 2 and <= 33 && Points[0] == new ToneCurvePoint(0, 0) && Points[^1] == new ToneCurvePoint(1, 1) &&
        Points.All(p => double.IsFinite(p.X) && double.IsFinite(p.Y) && p.X is >= 0 and <= 1 && p.Y is >= 0 and <= 1) &&
        Points.Zip(Points.Skip(1)).All(pair => pair.First.X < pair.Second.X && pair.First.Y <= pair.Second.Y);
    public bool IsInterior(int index) => Mode == ToneCurveMode.Custom && index > 0 && index + 1 < Points.Count;
    public ToneCurveSettings Inserting(double x, double y)
    {
        if (Mode != ToneCurveMode.Custom || Points.Count >= 33 || !double.IsFinite(x) || !double.IsFinite(y) ||
            x <= 0 || x >= 1 || Points.Any(p => p.X == x)) return this;
        var result = Points.ToList(); var next = result.FindIndex(p => p.X > x);
        result.Insert(next, new(x, Math.Clamp(y, Points[next - 1].Y, Points[next].Y)));
        return new(Mode, result);
    }
    public ToneCurveSettings Moving(int index, double x, double y)
    {
        if (!IsInterior(index) || !double.IsFinite(x) || !double.IsFinite(y)) return this;
        var low = Math.BitIncrement(Points[index - 1].X); var high = Math.BitDecrement(Points[index + 1].X);
        if (low > high) return this;
        var result = Points.ToArray(); result[index] = new(Math.Clamp(x, low, high), Math.Clamp(y, Points[index - 1].Y, Points[index + 1].Y));
        return new(Mode, result);
    }
    public ToneCurveSettings Removing(int index)
    {
        if (!IsInterior(index)) return this;
        var result = Points.ToList(); result.RemoveAt(index); return new(Mode, result);
    }
    public bool Equals(ToneCurveSettings? other) => other is not null && Mode == other.Mode && Points.SequenceEqual(other.Points);
    public override bool Equals(object? other) => other is ToneCurveSettings curve && Equals(curve);
    public override int GetHashCode() { var hash = new HashCode(); hash.Add(Mode); foreach (var point in Points) hash.Add(point); return hash.ToHashCode(); }
    public static bool operator ==(ToneCurveSettings? a, ToneCurveSettings? b) => Equals(a, b);
    public static bool operator !=(ToneCurveSettings? a, ToneCurveSettings? b) => !Equals(a, b);
    internal Native.ToneCurveConfig NativeConfig()
    {
        var values = new double[66];
        for (var i = 0; i < Points.Count; i++) { values[i * 2] = Points[i].X; values[i * 2 + 1] = Points[i].Y; }
        return new() { Version = 1, StructSize = (uint)Marshal.SizeOf<Native.ToneCurveConfig>(), Mode = (int)Mode, Count = (uint)Points.Count, Points = values };
    }
    internal static ToneCurveSettings Parse(JsonElement json)
    {
        if (json.ValueKind != JsonValueKind.Object || !json.EnumerateObject().Select(p => p.Name).Order().SequenceEqual(new[] { "mode", "points" }))
            throw new JsonException("Invalid curve fields");
        var mode = json.GetProperty("mode");
        if (mode.ValueKind != JsonValueKind.String || mode.GetString() is not ("legacy" or "custom")) throw new JsonException("Invalid curve mode");
        var points = json.GetProperty("points");
        if (points.ValueKind != JsonValueKind.Array || points.GetArrayLength() > 33) throw new JsonException("Invalid curve points");
        var decoded = new List<ToneCurvePoint>();
        foreach (var point in points.EnumerateArray()) {
            if (point.ValueKind != JsonValueKind.Array || point.GetArrayLength() != 2 ||
                point[0].ValueKind != JsonValueKind.Number || point[1].ValueKind != JsonValueKind.Number ||
                !point[0].TryGetDouble(out var x) || !point[1].TryGetDouble(out var y)) throw new JsonException("Invalid curve point");
            decoded.Add(new(x, y));
        }
        try { return new(mode.GetString() == "custom" ? ToneCurveMode.Custom : ToneCurveMode.Legacy, decoded); }
        catch (ArgumentException error) { throw new JsonException("Invalid curve points", error); }
    }
}

public sealed class ToneCurveJsonConverter : JsonConverter<ToneCurveSettings>
{
    public override ToneCurveSettings Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    { using var json = JsonDocument.ParseValue(ref reader); return ToneCurveSettings.Parse(json.RootElement); }
    public override void Write(Utf8JsonWriter writer, ToneCurveSettings value, JsonSerializerOptions options)
    {
        writer.WriteStartObject(); writer.WriteString("mode", value.Mode == ToneCurveMode.Custom ? "custom" : "legacy");
        writer.WriteStartArray("points");
        foreach (var point in value.Points) { writer.WriteStartArray(); writer.WriteNumberValue(point.X); writer.WriteNumberValue(point.Y); writer.WriteEndArray(); }
        writer.WriteEndArray(); writer.WriteEndObject();
    }
}
