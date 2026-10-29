using System.Text.Json;
using F = RawLab.Windows.AdjustmentField;
using static RawLab.Windows.AdjustmentPayload;

namespace RawLab.Windows;

internal static class HDRAdjustmentTransfer
{
    private static readonly F[] Scalars = [F.Exposure, F.Contrast, F.Highlights, F.Shadows, F.Saturation, F.HdrTemperature, F.HdrTint];

    internal static AdjustmentPayload Capture(AdjustmentScope scope, SavedEdit edit, AdjustmentTransferContext context)
    {
        var settings = edit.Settings.HDR;
        if (settings is not { Mode: HDRMode.Hdr } || !settings.IsValid)
            throw new AdjustmentTransferException(AdjustmentFailure.InvalidPayload, "hdr.settings");
        var values = Values(settings);
        var neutral = Values(new HDRSettings());
        var fields = scope.Kind switch {
            "all" => AdjustmentFields.HDRSupported,
            "modified" => AdjustmentFields.HDRCommon.Where(field => !Same(values[field], neutral[field])).ToHashSet(),
            "custom" => CustomFields(scope.Fields),
            _ => throw new AdjustmentTransferException(AdjustmentFailure.InvalidPayload, "scope")
        };
        if (fields.Count == 0) throw new AdjustmentTransferException(AdjustmentFailure.EmptyScope);
        return new(new(context.Identifier, false, edit.Settings.Processing.Version, null, settings.ProcessingVersion),
            values.Where(pair => fields.Contains(pair.Key)).ToDictionary(pair => pair.Key, pair => pair.Value), 2, 2);
    }

    private static IReadOnlySet<F> CustomFields(IReadOnlySet<F>? fields)
    {
        if (fields == null) throw new AdjustmentTransferException(AdjustmentFailure.EmptyScope);
        if (fields.SetEquals(AdjustmentFields.Common)) return AdjustmentFields.HDRCommon;
        if (!fields.IsSubsetOf(AdjustmentFields.HDRSupported))
            throw new AdjustmentTransferException(AdjustmentFailure.Incompatible, "hdr.fields");
        return fields;
    }

    internal static SavedEdit Prepare(AdjustmentPayload payload, SavedEdit target)
    {
        payload.Validate();
        if (target.Settings.HDR is not { Mode: HDRMode.Hdr } current || !current.IsValid)
            throw new AdjustmentTransferException(AdjustmentFailure.Incompatible, "hdr.target");
        if (!payload.Fields.IsSubsetOf(AdjustmentFields.HDRSupported))
            throw new AdjustmentTransferException(AdjustmentFailure.Incompatible, "hdr.fields");
        var result = current;
        foreach (var field in Scalars)
        {
            if (payload[field] is not { } raw) continue;
            var number = Number(raw) ?? throw new AdjustmentTransferException(AdjustmentFailure.InvalidPayload, field.ID());
            var value = field switch {
                F.Contrast or F.Saturation => Percent((number - 1) * 100),
                F.Highlights => Percent(-number * 100),
                F.Shadows => Percent(number * 100),
                _ => number
            };
            result = field switch {
                F.Exposure => result with { Exposure = value }, F.Contrast => result with { Contrast = value },
                F.Highlights => result with { Highlights = value }, F.Shadows => result with { Shadows = value },
                F.Saturation => result with { Saturation = value }, F.HdrTemperature => result with { Temperature = value },
                F.HdrTint => result with { Tint = value }, _ => result
            };
        }
        var geometry = result.Geometry;
        geometry = geometry with {
            CropX = Number(payload[F.CropX]) ?? geometry.CropX, CropY = Number(payload[F.CropY]) ?? geometry.CropY,
            CropWidth = Number(payload[F.CropWidth]) ?? geometry.CropWidth, CropHeight = Number(payload[F.CropHeight]) ?? geometry.CropHeight,
            QuarterTurns = (int)(Number(payload[F.QuarterTurns]) ?? geometry.QuarterTurns),
            FlipHorizontal = Boolean(payload[F.FlipHorizontal]) ?? geometry.FlipHorizontal,
            FlipVertical = Boolean(payload[F.FlipVertical]) ?? geometry.FlipVertical,
            StraightenDegrees = Number(payload[F.Straighten]) ?? geometry.StraightenDegrees,
            PerspectiveHorizontal = Number(payload[F.PerspectiveHorizontal]) ?? geometry.PerspectiveHorizontal,
            PerspectiveVertical = Number(payload[F.PerspectiveVertical]) ?? geometry.PerspectiveVertical
        };
        result = result with { Geometry = geometry };
        if (!result.IsValid) throw new AdjustmentTransferException(AdjustmentFailure.Unrepresentable, "hdr.parameters");
        return target with { Settings = target.Settings with { HDR = result } };
    }

    private static double Percent(double value) => Math.Round(value, 10, MidpointRounding.AwayFromZero);

    private static Dictionary<F, JsonElement> Values(HDRSettings settings)
    {
        var result = new Dictionary<F, JsonElement> {
            [F.Exposure] = Value(settings.Exposure), [F.Contrast] = Value(1 + settings.Contrast / 100),
            [F.Highlights] = Value(-settings.Highlights / 100), [F.Shadows] = Value(settings.Shadows / 100),
            [F.Saturation] = Value(1 + settings.Saturation / 100), [F.HdrTemperature] = Value(settings.Temperature),
            [F.HdrTint] = Value(settings.Tint), [F.CropX] = Value(settings.Geometry.CropX), [F.CropY] = Value(settings.Geometry.CropY),
            [F.CropWidth] = Value(settings.Geometry.CropWidth), [F.CropHeight] = Value(settings.Geometry.CropHeight),
            [F.QuarterTurns] = Value(settings.Geometry.QuarterTurns), [F.FlipHorizontal] = Value(settings.Geometry.FlipHorizontal),
            [F.FlipVertical] = Value(settings.Geometry.FlipVertical), [F.Straighten] = Value(settings.Geometry.StraightenDegrees),
            [F.PerspectiveHorizontal] = Value(settings.Geometry.PerspectiveHorizontal),
            [F.PerspectiveVertical] = Value(settings.Geometry.PerspectiveVertical)
        };
        return result;
    }
}
