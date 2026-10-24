using System.Globalization;
using System.Text.Json;

namespace RawLab.Windows;

internal enum PhotoInfoMode
{
    Hidden,
    File,
    Capture
}

internal static class PhotoInfoModeExtensions
{
    internal static PhotoInfoMode Next(this PhotoInfoMode mode) => mode switch
    {
        PhotoInfoMode.Hidden => PhotoInfoMode.File,
        PhotoInfoMode.File => PhotoInfoMode.Capture,
        _ => PhotoInfoMode.Hidden
    };
}

internal sealed record PhotoInfo(
    string FileName,
    string? CaptureTime,
    int? DisplayWidth,
    int? DisplayHeight,
    int? Orientation,
    string? OrientationText,
    string? Camera,
    string? Lens,
    string? Shutter,
    string? Aperture,
    string? Iso,
    string? FocalLength)
{
    internal string FileLine
    {
        get
        {
            var fields = new List<string> { FileName };
            if (CaptureTime is { Length: > 0 } time) fields.Add(time);
            if (DisplayWidth is { } width && DisplayHeight is { } height)
                fields.Add($"{width} × {height}");
            if (Orientation is { } orientation && orientation != 1)
                fields.Add(OrientationText is { Length: > 0 } text ? text : Loc.Format("方向 {0}", orientation));
            return string.Join(" · ", fields);
        }
    }

    internal string CaptureLine
    {
        get
        {
            var fields = new List<string> { FileName };
            Add(fields, Loc.Text("相机"), Camera);
            Add(fields, Loc.Text("镜头"), Lens);
            Add(fields, Loc.Text("快门"), FormatShutter(Shutter));
            Add(fields, Loc.Text("光圈"), FormatAperture(Aperture));
            Add(fields, "ISO", FormatUnit(Iso, "ISO"));
            Add(fields, Loc.Text("焦距"), FormatUnit(FocalLength, "mm"));
            return fields.Count == 1 ? FileName + " · " + Loc.Text("未读取到拍摄参数") : string.Join(" · ", fields);
        }
    }

    private static void Add(List<string> fields, string label, string? value)
    {
        if (!string.IsNullOrWhiteSpace(value)) fields.Add(label + " " + value.Trim());
    }

    private static string? FormatShutter(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        var original=value.Trim();
        var text=original;
        if (text.EndsWith("s", StringComparison.OrdinalIgnoreCase)) text=text[..^1].Trim();
        if (text.Contains('/')) return text + " s";
        if (double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds) && double.IsFinite(seconds) && seconds > 0)
            return seconds <= .5 ? $"1/{Math.Round(1 / seconds):0} s" : seconds.ToString("0.##", CultureInfo.GetCultureInfo(Loc.Language)) + " s";
        return original;
    }

    private static string? FormatAperture(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        var original=value.Trim();
        var text=original;
        if (text.StartsWith("f/", StringComparison.OrdinalIgnoreCase)) text=text[2..].Trim();
        return double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var aperture) && double.IsFinite(aperture) && aperture > 0
            ? "f/" + aperture.ToString("0.##", CultureInfo.GetCultureInfo(Loc.Language)) : original;
    }

    private static string? FormatUnit(string? value, string unit)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        var original=value.Trim();
        var text=original;
        if (text.StartsWith(unit, StringComparison.OrdinalIgnoreCase)) text=text[unit.Length..].Trim();
        if (text.EndsWith(unit, StringComparison.OrdinalIgnoreCase)) text=text[..^unit.Length].Trim();
        if (double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var number) && double.IsFinite(number))
            return number.ToString("0.##", CultureInfo.GetCultureInfo(Loc.Language)) + (unit == "ISO" ? "" : " " + unit);
        return original.StartsWith(unit, StringComparison.OrdinalIgnoreCase) || original.EndsWith(unit, StringComparison.OrdinalIgnoreCase)
            ? original : original + (unit == "ISO" ? "" : " " + unit);
    }
}

internal static class PhotoInfoReader
{
    internal static PhotoInfo? Read(string path)
    {
        try
        {
            var json = ExportMetadata.Run(["-json", "-S", path]);
            return Parse(json, path);
        }
        catch (Exception)
        {
            // Metadata is advisory. A missing/broken ExifTool must never stop a RAW render.
            return null;
        }
    }

    internal static PhotoInfo? Parse(string json, string path)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Array || root.GetArrayLength() == 0) return null;
            var tags = root[0];
            if (tags.ValueKind != JsonValueKind.Object) return null;

            var fileName = Text(tags, "FileName") ?? System.IO.Path.GetFileName(path);
            var date = Text(tags, "DateTimeOriginal") ?? Text(tags, "CreateDate");
            var width = Integer(tags, "ImageWidth") ?? Integer(tags, "ExifImageWidth");
            var height = Integer(tags, "ImageHeight") ?? Integer(tags, "ExifImageHeight");
            var orientation = Integer(tags, "Orientation") ?? ParseOrientation(Text(tags, "Orientation"));
            var orientationText = Text(tags, "Orientation");
            if (orientation is >= 5 and <= 8 && width is { } w && height is { } h) (width, height) = (h, w);

            var make = Text(tags, "Make");
            var model = Text(tags, "Model");
            var camera = Join(make, model);
            var lensMake = Text(tags, "LensMake");
            var lens = Join(lensMake, Text(tags, "LensModel"));
            return new(
                fileName,
                date,
                width,
                height,
                orientation,
                orientationText,
                camera,
                lens,
                Text(tags, "ExposureTime") ?? Text(tags, "ShutterSpeedValue"),
                Text(tags, "FNumber") ?? Text(tags, "ApertureValue"),
                Text(tags, "ISO") ?? Text(tags, "ISOSpeed"),
                Text(tags, "FocalLength"));
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static string? Text(JsonElement tags, params string[] names)
    {
        foreach (var name in names)
        {
            if (!tags.TryGetProperty(name, out var value) || value.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined) continue;
            var text = value.ValueKind == JsonValueKind.String ? value.GetString() : value.ToString();
            if (!string.IsNullOrWhiteSpace(text)) return text.Trim();
        }
        return null;
    }

    private static int? Integer(JsonElement tags, params string[] names)
    {
        foreach (var name in names)
        {
            if (!tags.TryGetProperty(name, out var value)) continue;
            if (value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number)) return number;
            if (value.ValueKind == JsonValueKind.String && int.TryParse(value.GetString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var textNumber)) return textNumber;
        }
        return null;
    }

    private static int? ParseOrientation(string? value) => value switch
    {
        null => null,
        _ when value.Contains("90", StringComparison.OrdinalIgnoreCase) && value.Contains("CW", StringComparison.OrdinalIgnoreCase) => 6,
        _ when value.Contains("270", StringComparison.OrdinalIgnoreCase) => 8,
        _ when value.Contains("180", StringComparison.OrdinalIgnoreCase) => 3,
        _ => null
    };

    private static string? Join(string? first, string? second)
    {
        if (string.IsNullOrWhiteSpace(first)) return string.IsNullOrWhiteSpace(second) ? null : second.Trim();
        if (string.IsNullOrWhiteSpace(second)) return first.Trim();
        if (second.Contains(first, StringComparison.OrdinalIgnoreCase)) return second.Trim();
        return first.Trim() + " " + second.Trim();
    }
}
