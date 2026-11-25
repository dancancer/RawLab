using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RawLab.Windows;

public enum ToneCurveMode { Legacy, Custom }
public readonly record struct ToneCurvePoint(double X, double Y);

[JsonConverter(typeof(ToneCurveShapeJsonConverter))]
public sealed class ToneCurveShape : IEquatable<ToneCurveShape>
{
    public ToneCurveMode Mode { get; }
    public IReadOnlyList<ToneCurvePoint> Points { get; }
    public ToneCurveShape(ToneCurveMode mode = ToneCurveMode.Legacy, IEnumerable<ToneCurvePoint>? points = null)
    {
        Mode = mode; Points = Array.AsReadOnly((points ?? []).ToArray());
        if (!IsValid) throw new ArgumentOutOfRangeException(nameof(points), "Invalid curve points");
    }
    public static ToneCurveShape Identity { get; } = new(ToneCurveMode.Custom, [new(0, 0), new(1, 1)]);
    public bool IsDefault => Mode == ToneCurveMode.Legacy;
    public bool IsIdentity => IsDefault || (!HasUnpinnedEndpoints && Points.All(p => p.X == p.Y));
    internal bool HasUnpinnedEndpoints => Mode == ToneCurveMode.Custom && Points.Count >= 2 &&
        (Points[0].X != 0 || Points[0].Y != 0 || Points[^1].X != 1 || Points[^1].Y != 1);
    // 端点 x 内移需要 SDR 配方 v18 / HDR 处理 v10；已发布的 v17 / v9 只放开端点 y。
    internal bool HasFreeEndpointX => Mode == ToneCurveMode.Custom && Points.Count >= 2 && (Points[0].X != 0 || Points[^1].X != 1);
    public double Progress => Mode != ToneCurveMode.Custom || Points.Count == 0 ? 0 :
        Math.Max(Points.Max(p => Math.Abs(p.Y - p.X)), Math.Max(Points[0].Y, 1.0 - Points[^1].Y));
    public ToneCurveShape Scaled(double strength)
    {
        if (Mode != ToneCurveMode.Custom || strength == 1) return this;
        if (strength == 0) return Identity;
        var result = Points.ToArray();
        var last = result.Length - 1;
        if (result.Length == 2) {
            var rawX0 = Math.Clamp(Points[0].X * strength, 0.0, 1.0);
            var rawX1 = Math.Clamp(1.0 + (Points[1].X - 1.0) * strength, 0.0, 1.0);
            if (rawX0 < rawX1) {
                result[0] = new(rawX0, Points[0].Y);
                result[1] = new(rawX1, Points[1].Y);
            } else if (rawX1 <= 0.0) {
                result[0] = new(0.0, Points[0].Y);
                result[1] = new(Math.BitIncrement(0.0), Points[1].Y);
            } else if (rawX0 >= 1.0) {
                result[0] = new(Math.BitDecrement(1.0), Points[0].Y);
                result[1] = new(1.0, Points[1].Y);
            } else {
                var mid = Points[0].X / (Points[0].X + (1.0 - Points[1].X));
                result[0] = new(Math.BitDecrement(mid), Points[0].Y);
                result[1] = new(Math.BitIncrement(mid), Points[1].Y);
            }
        } else {
            result[0] = new(Math.Clamp(Points[0].X * strength, 0.0, Math.BitDecrement(Points[1].X)), Points[0].Y);
            result[last] = new(Math.Clamp(1.0 + (Points[last].X - 1.0) * strength, Math.BitIncrement(Points[last - 1].X), 1.0), Points[last].Y);
        }
        var previous = 0.0;
        for (var i = 0; i < result.Length; i++) {
            var point = Points[i];
            var rawY = i == 0 ? point.Y * strength : i == last ? 1.0 + (point.Y - 1.0) * strength : point.X + (point.Y - point.X) * strength;
            var y = Math.Clamp(rawY, previous, 1);
            previous = y;
            result[i] = new(result[i].X, y);
        }
        return new(Mode, result);
    }
    private bool IsValid => Mode == ToneCurveMode.Legacy ? Points.Count == 0 : Mode == ToneCurveMode.Custom &&
        Points.Count is >= 2 and <= 33 &&
        (AdjustmentFieldSpec.SubFields.LightCurve.EndpointsXUnpinned || (Points[0].X == 0 && Points[^1].X == 1)) &&
        (AdjustmentFieldSpec.SubFields.LightCurve.EndpointsYUnpinned || (Points[0].Y == 0 && Points[^1].Y == 1)) &&
        Points.All(p => double.IsFinite(p.X) && double.IsFinite(p.Y) && p.X is >= 0 and <= 1 && p.Y is >= 0 and <= 1) &&
        Points.Zip(Points.Skip(1)).All(pair => pair.First.X < pair.Second.X && pair.First.Y <= pair.Second.Y);
    public bool IsInterior(int index) => Mode == ToneCurveMode.Custom && index > 0 && index + 1 < Points.Count;
    public bool IsEndpoint(int index) => Mode == ToneCurveMode.Custom && Points.Count >= 2 && (index == 0 || index == Points.Count - 1);
    public bool CanMoveX(int index) => Mode == ToneCurveMode.Custom && index >= 0 && index < Points.Count &&
        (AdjustmentFieldSpec.SubFields.LightCurve.EndpointsXUnpinned || IsInterior(index));
    public bool CanMoveY(int index) => Mode == ToneCurveMode.Custom && index >= 0 && index < Points.Count;
    public ToneCurveShape Inserting(double x, double y)
    {
        if (Mode != ToneCurveMode.Custom || Points.Count >= 33 || !double.IsFinite(x) || !double.IsFinite(y) ||
            x is < 0 or > 1 || Points.Any(p => p.X == x)) return this;
        var result = Points.ToList(); var next = result.FindIndex(p => p.X > x);
        if (next < 0) next = result.Count;
        var minY = next > 0 ? Points[next - 1].Y : 0.0;
        var maxY = next < Points.Count ? Points[next].Y : 1.0;
        result.Insert(next, new(x, Math.Clamp(y, minY, maxY)));
        return new(Mode, result);
    }
    public ToneCurveShape Moving(int index, double x, double y)
    {
        if (!CanMoveY(index) || !double.IsFinite(x) || !double.IsFinite(y)) return this;
        var allowX = AdjustmentFieldSpec.SubFields.LightCurve.EndpointsXUnpinned;
        var result = Points.ToArray();
        if (index == 0) {
            var highX = Points.Count > 1 ? Math.BitDecrement(Points[1].X) : 1.0;
            var maxY = Points.Count > 1 ? Points[1].Y : 1.0;
            result[0] = new(allowX ? Math.Clamp(x, 0.0, highX) : 0.0, Math.Clamp(y, 0.0, maxY));
            return new(Mode, result);
        }
        if (index == Points.Count - 1) {
            var lowX = Points.Count > 1 ? Math.BitIncrement(Points[index - 1].X) : 0.0;
            var minY = Points.Count > 1 ? Points[index - 1].Y : 0.0;
            result[index] = new(allowX ? Math.Clamp(x, lowX, 1.0) : 1.0, Math.Clamp(y, minY, 1.0));
            return new(Mode, result);
        }
        var low = Math.BitIncrement(Points[index - 1].X); var high = Math.BitDecrement(Points[index + 1].X);
        if (low > high) return this;
        result[index] = new(Math.Clamp(x, low, high), Math.Clamp(y, Points[index - 1].Y, Points[index + 1].Y));
        return new(Mode, result);
    }
    public ToneCurveShape Removing(int index)
    {
        if (!IsInterior(index)) return this;
        var result = Points.ToList(); result.RemoveAt(index); return new(Mode, result);
    }
    public bool Equals(ToneCurveShape? other) => other is not null && Mode == other.Mode && Points.SequenceEqual(other.Points);
    public override bool Equals(object? other) => other is ToneCurveShape curve && Equals(curve);
    public override int GetHashCode() { var hash = new HashCode(); hash.Add(Mode); foreach (var point in Points) hash.Add(point); return hash.ToHashCode(); }
    public static bool operator ==(ToneCurveShape? a, ToneCurveShape? b) => Equals(a, b);
    public static bool operator !=(ToneCurveShape? a, ToneCurveShape? b) => !Equals(a, b);
    internal Native.ToneCurveConfig NativeConfig()
    {
        var values = new double[66];
        for (var i = 0; i < Points.Count; i++) { values[i * 2] = Points[i].X; values[i * 2 + 1] = Points[i].Y; }
        return new() { Version = 1, StructSize = (uint)Marshal.SizeOf<Native.ToneCurveConfig>(), Mode = (int)Mode, Count = (uint)Points.Count, Points = values };
    }
    internal static ToneCurveShape Parse(JsonElement json, bool allowExtensions = false)
    {
        if (json.ValueKind != JsonValueKind.Object ||
            !json.EnumerateObject().Select(p => p.Name)
                .Where(key => !allowExtensions || key is not ("channels" or "apply_to_luminosity" or "parametric"))
                .Order().SequenceEqual(new[] { "mode", "points" }))
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

public sealed class ToneCurveShapeJsonConverter : JsonConverter<ToneCurveShape>
{
    public override ToneCurveShape Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    { using var json = JsonDocument.ParseValue(ref reader); return ToneCurveShape.Parse(json.RootElement); }
    public override void Write(Utf8JsonWriter writer, ToneCurveShape value, JsonSerializerOptions options)
    {
        writer.WriteStartObject(); writer.WriteString("mode", value.Mode == ToneCurveMode.Custom ? "custom" : "legacy");
        writer.WriteStartArray("points");
        foreach (var point in value.Points) { writer.WriteStartArray(); writer.WriteNumberValue(point.X); writer.WriteNumberValue(point.Y); writer.WriteEndArray(); }
        writer.WriteEndArray(); writer.WriteEndObject();
    }
}

public enum ToneCurveChannel { Rgb, Red, Green, Blue }
public sealed record ToneCurveChannels(ToneCurveShape Red, ToneCurveShape Green, ToneCurveShape Blue)
{
    public ToneCurveChannels() : this(new(), new(), new()) { }
    public bool IsDefault => Red.IsDefault && Green.IsDefault && Blue.IsDefault;
    public bool IsIdentity => Red.IsIdentity && Green.IsIdentity && Blue.IsIdentity;
    internal bool HasUnpinnedEndpoints => Red.HasUnpinnedEndpoints || Green.HasUnpinnedEndpoints || Blue.HasUnpinnedEndpoints;
    internal bool HasFreeEndpointX => Red.HasFreeEndpointX || Green.HasFreeEndpointX || Blue.HasFreeEndpointX;
    public ToneCurveChannels Scaled(double strength) => new(Red.Scaled(strength), Green.Scaled(strength), Blue.Scaled(strength));
}

public sealed record ToneCurveParametric(
    double Highlights = 0,
    double Lights = 0,
    double Darks = 0,
    double Shadows = 0,
    double SplitShadow = 0.25,
    double SplitMidtone = 0.50,
    double SplitHighlight = 0.75)
{
    public bool IsDefault => Highlights == 0 && Lights == 0 && Darks == 0 && Shadows == 0 &&
        SplitShadow == AdjustmentFieldSpec.SubFields.LightCurveParametric.SplitShadowDefault &&
        SplitMidtone == AdjustmentFieldSpec.SubFields.LightCurveParametric.SplitMidtoneDefault &&
        SplitHighlight == AdjustmentFieldSpec.SubFields.LightCurveParametric.SplitHighlightDefault;
    public bool IsIdentity => Highlights == 0 && Lights == 0 && Darks == 0 && Shadows == 0;
    public bool IsValid => double.IsFinite(Highlights) && double.IsFinite(Lights) &&
        double.IsFinite(Darks) && double.IsFinite(Shadows) &&
        double.IsFinite(SplitShadow) && double.IsFinite(SplitMidtone) && double.IsFinite(SplitHighlight) &&
        Highlights is >= AdjustmentFieldSpec.SubFields.LightCurveParametric.BandMin and <= AdjustmentFieldSpec.SubFields.LightCurveParametric.BandMax &&
        Lights is >= AdjustmentFieldSpec.SubFields.LightCurveParametric.BandMin and <= AdjustmentFieldSpec.SubFields.LightCurveParametric.BandMax &&
        Darks is >= AdjustmentFieldSpec.SubFields.LightCurveParametric.BandMin and <= AdjustmentFieldSpec.SubFields.LightCurveParametric.BandMax &&
        Shadows is >= AdjustmentFieldSpec.SubFields.LightCurveParametric.BandMin and <= AdjustmentFieldSpec.SubFields.LightCurveParametric.BandMax &&
        SplitShadow is >= AdjustmentFieldSpec.SubFields.LightCurveParametric.SplitShadowMin and <= AdjustmentFieldSpec.SubFields.LightCurveParametric.SplitShadowMax &&
        SplitMidtone is >= AdjustmentFieldSpec.SubFields.LightCurveParametric.SplitMidtoneMin and <= AdjustmentFieldSpec.SubFields.LightCurveParametric.SplitMidtoneMax &&
        SplitHighlight is >= AdjustmentFieldSpec.SubFields.LightCurveParametric.SplitHighlightMin and <= AdjustmentFieldSpec.SubFields.LightCurveParametric.SplitHighlightMax &&
        SplitShadow + AdjustmentFieldSpec.SubFields.LightCurveParametric.SplitMinGap <= SplitMidtone &&
        SplitMidtone + AdjustmentFieldSpec.SubFields.LightCurveParametric.SplitMinGap <= SplitHighlight;
    public double Progress => Math.Max(Math.Max(Math.Abs(Highlights), Math.Abs(Lights)),
        Math.Max(Math.Abs(Darks), Math.Abs(Shadows))) / 100.0;
    public ToneCurveParametric Scaled(double strength) => this with {
        Highlights = Math.Clamp(Highlights * strength, -100, 100),
        Lights = Math.Clamp(Lights * strength, -100, 100),
        Darks = Math.Clamp(Darks * strength, -100, 100),
        Shadows = Math.Clamp(Shadows * strength, -100, 100)
    };
    internal static ToneCurveParametric Parse(JsonElement json)
    {
        if (json.ValueKind != JsonValueKind.Object || !json.EnumerateObject().Select(p => p.Name).Order(StringComparer.Ordinal)
            .SequenceEqual(new[] { "darks", "highlights", "lights", "shadows", "split_highlight", "split_midtone", "split_shadow" }))
            throw new JsonException("Invalid parametric curve fields");
        double ReadDouble(string name) {
            var prop = json.GetProperty(name);
            if (prop.ValueKind != JsonValueKind.Number || !prop.TryGetDouble(out var v)) throw new JsonException("Invalid parametric curve value");
            return v;
        }
        var result = new ToneCurveParametric(
            ReadDouble("highlights"), ReadDouble("lights"), ReadDouble("darks"), ReadDouble("shadows"),
            ReadDouble("split_shadow"), ReadDouble("split_midtone"), ReadDouble("split_highlight"));
        if (!result.IsValid) throw new JsonException("Invalid parametric curve values");
        return result;
    }
    internal Native.ToneCurveParametricConfig NativeConfig()
    {
        if (!IsValid) throw new ArgumentOutOfRangeException(nameof(ToneCurveParametric), "Invalid parametric curve");
        return new() {
            Version = 1,
            StructSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<Native.ToneCurveParametricConfig>(),
            Highlights = (float)Highlights,
            Lights = (float)Lights,
            Darks = (float)Darks,
            Shadows = (float)Shadows,
            SplitShadow = (float)SplitShadow,
            SplitMidtone = (float)SplitMidtone,
            SplitHighlight = (float)SplitHighlight,
            Reserved = 0
        };
    }
    internal void WriteObject(Utf8JsonWriter writer)
    {
        writer.WriteStartObject();
        writer.WriteNumber("highlights", Highlights);
        writer.WriteNumber("lights", Lights);
        writer.WriteNumber("darks", Darks);
        writer.WriteNumber("shadows", Shadows);
        writer.WriteNumber("split_shadow", SplitShadow);
        writer.WriteNumber("split_midtone", SplitMidtone);
        writer.WriteNumber("split_highlight", SplitHighlight);
        writer.WriteEndObject();
    }
}

[JsonConverter(typeof(ToneCurveJsonConverter))]
public sealed class ToneCurveSettings : IEquatable<ToneCurveSettings>
{
    public ToneCurveShape Master { get; }
    public ToneCurveChannels Channels { get; }
    public bool ApplyToLuminosity { get; }
    public ToneCurveParametric Parametric { get; }
    public ToneCurveMode Mode => Master.Mode;
    public IReadOnlyList<ToneCurvePoint> Points => Master.Points;
    public ToneCurveSettings(ToneCurveMode mode = ToneCurveMode.Legacy, IEnumerable<ToneCurvePoint>? points = null,
        ToneCurveChannels? channels = null, bool applyToLuminosity = false, ToneCurveParametric? parametric = null)
    {
        Master = new(mode, points);
        Channels = channels ?? new();
        ApplyToLuminosity = applyToLuminosity;
        Parametric = parametric ?? new();
        if (!Parametric.IsValid) throw new ArgumentOutOfRangeException(nameof(parametric), "Invalid parametric curve");
    }
    public static ToneCurveSettings Identity { get; } = new(ToneCurveMode.Custom, ToneCurveShape.Identity.Points);
    public bool IsDefault => Master.IsDefault && Channels.IsDefault && !ApplyToLuminosity && Parametric.IsDefault;
    public bool IsIdentity => Master.IsIdentity && Channels.IsIdentity && Parametric.IsIdentity;
    public bool HasChannelCurves => !Channels.IsDefault;
    public bool HasV2Extensions => ApplyToLuminosity || !Parametric.IsDefault || Master.HasUnpinnedEndpoints || Channels.HasUnpinnedEndpoints;
    public bool HasFreeEndpointX => Master.HasFreeEndpointX || Channels.HasFreeEndpointX;
    public double Progress => new[] { Master.Progress, Channels.Red.Progress, Channels.Green.Progress, Channels.Blue.Progress, Parametric.Progress }.Max();
    public ToneCurveShape Shape(ToneCurveChannel channel) => channel switch {
        ToneCurveChannel.Rgb => Master, ToneCurveChannel.Red => Channels.Red, ToneCurveChannel.Green => Channels.Green, _ => Channels.Blue };
    public ToneCurveSettings Replacing(ToneCurveChannel channel, ToneCurveShape shape) => channel switch {
        ToneCurveChannel.Rgb => new(shape.Mode, shape.Points, Channels, ApplyToLuminosity, Parametric),
        ToneCurveChannel.Red => new(Mode, Points, Channels with { Red = shape }, ApplyToLuminosity, Parametric),
        ToneCurveChannel.Green => new(Mode, Points, Channels with { Green = shape }, ApplyToLuminosity, Parametric),
        _ => new(Mode, Points, Channels with { Blue = shape }, ApplyToLuminosity, Parametric) };
    public ToneCurveSettings Scaled(double strength) {
        var master = Master.Scaled(strength);
        return new(master.Mode, master.Points, Channels.Scaled(strength), ApplyToLuminosity, Parametric.Scaled(strength));
    }
    public bool IsInterior(int index) => Master.IsInterior(index);
    public bool IsEndpoint(int index) => Master.IsEndpoint(index);
    public bool CanMoveX(int index) => Master.CanMoveX(index);
    public bool CanMoveY(int index) => Master.CanMoveY(index);
    public ToneCurveSettings Inserting(double x, double y) => Replacing(ToneCurveChannel.Rgb, Master.Inserting(x, y));
    public ToneCurveSettings Moving(int index, double x, double y) => Replacing(ToneCurveChannel.Rgb, Master.Moving(index, x, y));
    public ToneCurveSettings Removing(int index) => Replacing(ToneCurveChannel.Rgb, Master.Removing(index));
    public bool Equals(ToneCurveSettings? other) => other is not null && Master == other.Master && Channels == other.Channels &&
        ApplyToLuminosity == other.ApplyToLuminosity && Parametric == other.Parametric;
    public override bool Equals(object? other) => other is ToneCurveSettings curve && Equals(curve);
    public override int GetHashCode() => HashCode.Combine(Master, Channels, ApplyToLuminosity, Parametric);
    public static bool operator ==(ToneCurveSettings? a, ToneCurveSettings? b) => Equals(a, b);
    public static bool operator !=(ToneCurveSettings? a, ToneCurveSettings? b) => !Equals(a, b);
    internal Native.ToneCurveConfig NativeConfig() => Master.NativeConfig();
    internal Native.ToneCurveSetConfig NativeSetConfig() => new() {
        Version = 1, StructSize = (uint)Marshal.SizeOf<Native.ToneCurveSetConfig>(), Master = Master.NativeConfig(),
        Red = Channels.Red.NativeConfig(), Green = Channels.Green.NativeConfig(), Blue = Channels.Blue.NativeConfig() };
    internal Native.ToneCurveSetV2Config NativeSetV2Config() => new() {
        Version = 2, StructSize = (uint)Marshal.SizeOf<Native.ToneCurveSetV2Config>(),
        ApplyToLuminosity = ApplyToLuminosity ? 1 : 0, Reserved = 0,
        Master = Master.NativeConfig(), Red = Channels.Red.NativeConfig(), Green = Channels.Green.NativeConfig(), Blue = Channels.Blue.NativeConfig(),
        Parametric = Parametric.NativeConfig() };
    internal static ToneCurveSettings Parse(JsonElement json, bool allowV2Fields = true) {
        if (json.ValueKind != JsonValueKind.Object) throw new JsonException("Invalid curve fields");
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var prop in json.EnumerateObject()) {
            if (!seen.Add(prop.Name)) throw new JsonException("Duplicate curve field: " + prop.Name);
            if (!allowV2Fields && prop.Name is "apply_to_luminosity" or "parametric")
                throw new JsonException("Invalid curve field: " + prop.Name);
        }
        var master = ToneCurveShape.Parse(json, true);
        var channels = new ToneCurveChannels();
        if (json.TryGetProperty("channels", out var fields)) {
            if (fields.ValueKind != JsonValueKind.Object || fields.EnumerateObject().Any(p => p.Name is not ("red" or "green" or "blue")))
                throw new JsonException("Invalid curve channels");
            ToneCurveShape Shape(string key) => fields.TryGetProperty(key, out var value) ? ToneCurveShape.Parse(value) : new();
            channels = new(Shape("red"), Shape("green"), Shape("blue"));
        }
        var applyToLuminosity = false;
        if (json.TryGetProperty("apply_to_luminosity", out var applyElem)) {
            if (applyElem.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
                throw new JsonException("Invalid apply_to_luminosity");
            applyToLuminosity = applyElem.GetBoolean();
        }
        var parametric = json.TryGetProperty("parametric", out var paramElem) ? ToneCurveParametric.Parse(paramElem) : new();
        return new(master.Mode, master.Points, channels, applyToLuminosity, parametric);
    }
}

public sealed class ToneCurveJsonConverter : JsonConverter<ToneCurveSettings>
{
    public override ToneCurveSettings Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    { using var json = JsonDocument.ParseValue(ref reader); return ToneCurveSettings.Parse(json.RootElement); }
    public override void Write(Utf8JsonWriter writer, ToneCurveSettings value, JsonSerializerOptions options) {
        writer.WriteStartObject(); writer.WriteString("mode", value.Mode == ToneCurveMode.Custom ? "custom" : "legacy");
        writer.WriteStartArray("points");
        foreach (var point in value.Points) { writer.WriteStartArray(); writer.WriteNumberValue(point.X); writer.WriteNumberValue(point.Y); writer.WriteEndArray(); }
        writer.WriteEndArray();
        if (value.HasChannelCurves) {
            writer.WriteStartObject("channels");
            writer.WritePropertyName("red"); JsonSerializer.Serialize(writer, value.Channels.Red, options);
            writer.WritePropertyName("green"); JsonSerializer.Serialize(writer, value.Channels.Green, options);
            writer.WritePropertyName("blue"); JsonSerializer.Serialize(writer, value.Channels.Blue, options);
            writer.WriteEndObject();
        }
        if (value.ApplyToLuminosity) writer.WriteBoolean("apply_to_luminosity", true);
        if (!value.Parametric.IsDefault) {
            writer.WritePropertyName("parametric");
            value.Parametric.WriteObject(writer);
        }
        writer.WriteEndObject();
    }
}
