using System.Globalization;
using System.Text.Json;
using F = RawLab.Windows.AdjustmentField;
using static RawLab.Windows.AdjustmentPayload;

namespace RawLab.Windows;

internal sealed class AdjustmentSummary
{
    internal sealed record Group(string ID, IReadOnlyList<F> Fields);
    private readonly AdjustmentPayload payload;
    private readonly CultureInfo culture;
    private readonly Func<string, string> text;
    private static readonly IReadOnlyList<F> fieldOrder = FieldOrder();

    internal AdjustmentSummary(AdjustmentPayload payload, CultureInfo? culture = null, Func<string, string>? text = null)
    {
        this.payload = payload; this.culture = culture ?? CultureInfo.GetCultureInfo(Loc.Language); this.text = text ?? Loc.Text;
    }

    internal IReadOnlyList<Group> Groups => new[] { "looks", "light", "color", "effects", "detail", "geometry" }
        .Select(id => new Group(id, fieldOrder.Where(field => (field.IsHDRRelative() ? "color" : field.Group()) == id && payload.Fields.Contains(field)).ToArray()))
        .Where(group => group.Fields.Count > 0).ToArray();
    internal int Count => payload.Fields.Count;
    internal bool IncludesGeometry => payload.Fields.Any(field => field.Group() == "geometry");
    internal string? RecipeNote => payload.Source.Recipe is { } recipe
        ? Format("以下为配方逻辑值；强度为 {0}。部分范围会按此强度换算。", NumberText(recipe.Strength * 100) + "%") : null;

    internal string ValueText(F field, Func<string, string, string?>? lookName = null)
    {
        if (payload[field] is not { } value) return "";
        var number = Number(value) ?? 0;
        return field switch {
            F.Look => LookText(value, lookName),
            F.Strength => NumberText(number * 100) + "%",
            F.Exposure => NumberText(number, 2, true) + " EV",
            F.ExposureMode => text(Text(value) switch { "scene" => "场景", "preview" => "预览", _ => "传感器基准" }),
            F.Contrast or F.Saturation => Percent(number - 1, true),
            F.Highlights => Percent(-number, true),
            F.Shadows or F.SCurve => Percent(number, true),
            F.BlackPoint or F.WhitePoint or F.Vibrance or F.Clarity or F.Dehaze => NumberText(number, signed: true) + "%",
            F.HdrTemperature => NumberText(number) + " K（" + text("相对白平衡") + "）",
            F.HdrTint => NumberText(number, signed: true) + "（" + text("相对白平衡") + "）",
            F.WhiteBalanceMode => text(Text(value) switch { "camera" => "相机白平衡（按目标照片）", "temperature" => "自定义", _ => "不适用" }),
            F.Temperature or F.Tint => Null(value)
                ? text(Text(payload[F.WhiteBalanceMode]) == "camera" ? "相机白平衡（按目标照片）" : "不适用")
                : NumberText(number, signed: field == F.Tint) + (field == F.Temperature ? " K" : ""),
            F.Curve => CurveText(value),
            F.GradingShadows or F.GradingMidtones or F.GradingHighlights => text("色相") + " " + NumberText(value.GetProperty("hue").GetDouble()) + "° · " +
                text("饱和度") + " " + NumberText(value.GetProperty("saturation").GetDouble()) + "%",
            F.VignetteAmount or F.VignetteRoundness => NumberText(number, signed: true),
            F.PerspectiveHorizontal or F.PerspectiveVertical => NumberText(number * 100, signed: true),
            F.VignetteMidpoint or F.VignetteFeather or F.VignetteHighlights or F.GrainAmount or F.GrainSize or F.GrainRoughness or F.RawDenoise or F.PostRGBDenoise => NumberText(number),
            F.ChromaDenoise => Null(value) ? text("默认降噪设置") : text((int)number switch { 0 => "停用", 1 => "细节优先", _ => "去噪优先" }),
            F.WaveletDenoise => WaveletText(value),
            F.Sharpening => Percent(number, false),
            F.CropX or F.CropY or F.CropWidth or F.CropHeight => NumberText(number * 100) + "%",
            F.QuarterTurns => NumberText(number * 90) + "°",
            F.FlipHorizontal or F.FlipVertical or F.LensDistortion or F.LensTCA or F.LensAutoCrop => text(Boolean(value) == true ? "开启" : "停用"),
            F.Straighten => NumberText(number, signed: true) + "°",
            F.LensProfile => Null(value) ? text("自动（按目标照片）") : Text(value) == "__rawlab_manual_selection_required__" ? text("待选择的镜头配置") : Text(value) ?? "",
            _ => NumberText(number, signed: true)
        };
    }

    private string LookText(JsonElement value, Func<string, string, string?>? lookName)
    {
        var kind = value.GetProperty("kind").GetString()!;
        if (kind == "neutral") return text("中性");
        var id = value.GetProperty("id").GetString()!;
        var type = text(kind switch { "builtin" => "内置", "managed" => "已保存", "recipe" => "配方", _ => "配方 LUT" });
        var name = lookName?.Invoke(kind, id);
        return type + " · " + (!string.IsNullOrEmpty(name) ? name : id + " · " + text("外观不可用。"));
    }

    private string CurveText(JsonElement value)
    {
        if (value.GetProperty("mode").GetString() != "custom") return text("S 曲线");
        var points = value.GetProperty("points").EnumerateArray().ToArray();
        return Format("多点曲线（{0} 个控制点）", points.Length) + "：" + string.Join(" · ",
            points.Select(point => NumberText(point[0].GetDouble(), 2) + " → " + NumberText(point[1].GetDouble(), 2)));
    }

    private string WaveletText(JsonElement value)
    {
        if (Null(value)) return text("默认降噪设置");
        var preset = text(value.GetProperty("preset").GetString() switch { "detail" => "细节优先", "clean" => "去噪优先", _ => "自定义" });
        return text(value.GetProperty("enabled").GetBoolean() ? "开启" : "停用") + " · " +
            text("亮度降噪") + " " + NumberText(value.GetProperty("luma").GetDouble()) + " · " +
            text("色彩降噪") + " " + NumberText(value.GetProperty("chroma").GetDouble()) + " · " +
            text("粗色斑抑制") + " " + NumberText(value.GetProperty("coarse").GetDouble()) + " · " + preset;
    }

    private string Percent(double value, bool signed) => NumberText(value * 100, signed: signed) + "%";
    private string Format(string key, params object[] arguments) => string.Format(culture, text(key), arguments);
    private string NumberText(double value, int minimum = 0, bool signed = false)
    {
        var threshold = minimum > 0 ? Math.Pow(10, -minimum - 1) : 0.0000001;
        var normalized = Math.Abs(value) < threshold ? 0 : value;
        var rounded = Math.Round(normalized, 2, MidpointRounding.AwayFromZero);
        return (signed && normalized > 0 ? "+" : "") + rounded.ToString(minimum == 2 ? "0.00" : "0.##", culture);
    }

    private static IReadOnlyList<F> FieldOrder()
    {
        // 摘要顺序与共享合同一致，既有 enum ordinal 和持久化目录保持不变。
        var fields = Enum.GetValues<F>().ToList();
        void MoveAfter(F anchor, params F[] moved) {
            foreach (var field in moved) fields.Remove(field);
            fields.InsertRange(fields.IndexOf(anchor) + 1, moved);
        }
        MoveAfter(F.SCurve, F.Curve, F.BlackPoint, F.WhitePoint, F.Vibrance, F.GradingShadows, F.GradingMidtones, F.GradingHighlights);
        MoveAfter(F.Saturation, F.HdrTemperature, F.HdrTint);
        MoveAfter(F.GrainAmount, F.Clarity, F.Dehaze);
        return fields;
    }
}
