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
        var allowed = AdjustmentFields.HDRTransferFields(context.SupportsHDRCameraDevelopment);
        var all = AdjustmentFields.HDRSupportedFor(settings.ProcessingVersion);
        if (context.SupportsHDRCameraDevelopment) {
            values[F.HdrCameraDevelopment] = CameraValue(settings.CameraSettings);
            neutral[F.HdrCameraDevelopment] = CameraValue(new());
            if (!Same(values[F.HdrCameraDevelopment],neutral[F.HdrCameraDevelopment])) all = all.Append(F.HdrCameraDevelopment).ToHashSet();
        }
        var fields = scope.Kind switch {
            "all" => all,
            "modified" => allowed.Except(AdjustmentFields.HDRGeometry)
                .Where(field => !Same(values[field], neutral[field])).ToHashSet(),
            "custom" => CustomFields(scope.Fields,allowed),
            _ => throw new AdjustmentTransferException(AdjustmentFailure.InvalidPayload, "scope")
        };
        if (fields.Count == 0) throw new AdjustmentTransferException(AdjustmentFailure.EmptyScope);
        var requiredVersion = fields.Contains(F.HdrLook) ? 7 : fields.Overlaps(AdjustmentFields.HDRDetail) ? 6 :
            fields.Overlaps(AdjustmentFields.HDREffects) ? 5 : fields.Overlaps(AdjustmentFields.HDRRendition) ? 4 :
            fields.Overlaps(AdjustmentFields.HDRColor) ? 3 : fields.Overlaps(AdjustmentFields.HDRTone) ? 2 : 1;
        var version = Math.Max(requiredVersion, settings.ProcessingVersion);
        return new(new(context.Identifier, false, edit.Settings.Processing.Version, null, version),
            values.Where(pair => fields.Contains(pair.Key)).ToDictionary(pair => pair.Key, pair => pair.Value), 2, 2);
    }

    private static IReadOnlySet<F> CustomFields(IReadOnlySet<F>? fields,IReadOnlySet<F> allowed)
    {
        if (fields == null) throw new AdjustmentTransferException(AdjustmentFailure.EmptyScope);
        if (fields.SetEquals(AdjustmentFields.Common)) return AdjustmentFields.HDRCommon;
        if (!fields.IsSubsetOf(allowed))
            throw new AdjustmentTransferException(AdjustmentFailure.Incompatible, "hdr.fields");
        return fields;
    }

    internal static SavedEdit Prepare(AdjustmentPayload payload, SavedEdit target, bool cameraRaw)
    {
        if (target.Settings.HDR is not { } current)
            throw new AdjustmentTransferException(AdjustmentFailure.Incompatible, "hdr.target");
        var hdr = PrepareSettings(payload,current,cameraRaw);
        return target with { Settings = target.Settings with { HDR = hdr,
            HDRCameraAIEnabled = target.Settings.HDRCameraAIEnabled && hdr.CameraSettings.AllowsAI } };
    }

    internal static HDRSettings PrepareSettings(AdjustmentPayload payload, HDRSettings current,bool cameraRaw = false)
    {
        payload.Validate();
        if (current.Mode != HDRMode.Hdr || !current.IsValid)
            throw new AdjustmentTransferException(AdjustmentFailure.Incompatible, "hdr.target");
        if (!payload.Fields.IsSubsetOf(AdjustmentFields.HDRTransferFields(cameraRaw)))
            throw new AdjustmentTransferException(AdjustmentFailure.Incompatible, "hdr.fields");
        if (!payload.Source.IsHDR && payload.Fields.Overlaps(AdjustmentFields.HDRTone))
            throw new AdjustmentTransferException(AdjustmentFailure.Incompatible, "hdr.tone");
        if (!payload.Source.IsHDR && payload.Fields.Overlaps(AdjustmentFields.HDRColor))
            throw new AdjustmentTransferException(AdjustmentFailure.Incompatible, "hdr.color");
        if (!payload.Source.IsHDR && payload.Fields.Overlaps(AdjustmentFields.HDREffects))
            throw new AdjustmentTransferException(AdjustmentFailure.Incompatible, "hdr.effects");
        if (!payload.Source.IsHDR && payload.Fields.Overlaps(AdjustmentFields.HDRDetail))
            throw new AdjustmentTransferException(AdjustmentFailure.Incompatible, "hdr.detail");
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
        var tone = result.ToneSettings;
        if (Number(payload[F.BlackPoint]) is { } black) tone = tone with { BlackPoint = black };
        if (Number(payload[F.WhitePoint]) is { } white) tone = tone with { WhitePoint = white };
        if (Number(payload[F.SCurve]) is { } strength && strength != tone.CurveStrength / 100)
            tone = tone with { CurveStrength = strength * 100 };
        if (payload[F.Curve] is { } curve) tone = tone with { Curve = ToneCurveSettings.Parse(curve) };
        var color = result.ColorSettings;
        if (Number(payload[F.Vibrance]) is { } vibrance) color = color with { Vibrance = vibrance };
        foreach (var field in payload.Fields)
        {
            if (field.HslIndex() is { } index && Number(payload[field]) is { } amount)
                color = color with { Hsl = color.Hsl.WithValue(index / 8, index % 8, amount) };
            if (field.GradingZone() is { } zone && payload[field] is { } wheel)
                color = color with { Grading = color.Grading.With(zone,
                    new(wheel.GetProperty("hue").GetDouble(), wheel.GetProperty("saturation").GetDouble())) };
        }
        var rendition = result.RenditionSettings;
        rendition = rendition with {
            PeakLimitEV = Number(payload[F.HdrPeakLimit]) ?? rendition.PeakLimitEV,
            SdrExposureEV = Number(payload[F.HdrSDRExposure]) ?? rendition.SdrExposureEV,
            SdrContrast = Number(payload[F.HdrSDRContrast]) ?? rendition.SdrContrast,
            SdrSaturation = Number(payload[F.HdrSDRSaturation]) ?? rendition.SdrSaturation
        };
        var effects = result.EffectSettings;
        effects = effects with {
            VignetteAmount = Number(payload[F.VignetteAmount]) ?? effects.VignetteAmount,
            VignetteMidpoint = Number(payload[F.VignetteMidpoint]) ?? effects.VignetteMidpoint,
            VignetteRoundness = Number(payload[F.VignetteRoundness]) ?? effects.VignetteRoundness,
            VignetteFeather = Number(payload[F.VignetteFeather]) ?? effects.VignetteFeather,
            VignetteHighlights = Number(payload[F.VignetteHighlights]) ?? effects.VignetteHighlights,
            GrainAmount = Number(payload[F.GrainAmount]) ?? effects.GrainAmount,
            GrainSize = Number(payload[F.GrainSize]) ?? effects.GrainSize,
            GrainRoughness = Number(payload[F.GrainRoughness]) ?? effects.GrainRoughness
        };
        var detail = result.DetailSettings;
        detail = detail with {
            Sharpening = Number(payload[F.Sharpening]) ?? detail.Sharpening,
            Clarity = DetailPercent(F.Clarity, detail.Clarity),
            Dehaze = DetailPercent(F.Dehaze, detail.Dehaze),
            Denoise = Number(payload[F.PostRGBDenoise]) ?? detail.Denoise
        };
        double DetailPercent(F field, double currentValue) => Number(payload[field]) is { } value && value != currentValue * 100
            ? value / 100 : currentValue;
        result = result.WithTone(tone).WithColor(color).WithRendition(rendition).WithEffects(effects).WithDetail(detail) with { Geometry = geometry };
        if (HDRLookValue(payload[F.HdrLook]) is { } look) result = result.WithLook(look);
        if (HDRCameraValue(payload[F.HdrCameraDevelopment]) is { } camera) {
            result = result.WithCameraDevelopment(current.CameraSettings with {
                CustomWhiteBalance = camera.CustomWhiteBalance, Temperature = camera.Temperature, Tint = camera.Tint,
                SensorExposure = camera.SensorExposure, FbddLevel = camera.FbddLevel
            });
        }
        if (!result.LookSettings.AssetIsAvailable()) throw new AdjustmentTransferException(AdjustmentFailure.MissingLook, result.LookSettings.Name ?? "HDR LUT");
        if (!result.IsValid) throw new AdjustmentTransferException(AdjustmentFailure.Unrepresentable, "hdr.parameters");
        return result;
    }

    private static double Percent(double value) => Math.Round(value, 10, MidpointRounding.AwayFromZero);

    private static JsonElement CameraValue(HDRCameraDevelopmentSettings camera) => Value(new {
        version = 1, white_balance_mode = camera.CustomWhiteBalance ? "temperature" : "as_shot",
        temperature = camera.Temperature, tint = camera.Tint,
        exposure_reference = camera.SensorExposure ? "sensor" : "metadata", fbdd_level = camera.FbddLevel
    });

    private static Dictionary<F, JsonElement> Values(HDRSettings settings)
    {
        var tone = settings.ToneSettings;
        var color = settings.ColorSettings;
        var rendition = settings.RenditionSettings;
        var effects = settings.EffectSettings;
        var detail = settings.DetailSettings;
        var look = settings.LookSettings;
        var result = new Dictionary<F, JsonElement> {
            [F.HdrPeakLimit] = Value(rendition.PeakLimitEV), [F.HdrSDRExposure] = Value(rendition.SdrExposureEV),
            [F.HdrSDRContrast] = Value(rendition.SdrContrast), [F.HdrSDRSaturation] = Value(rendition.SdrSaturation),
            [F.Exposure] = Value(settings.Exposure), [F.Contrast] = Value(1 + settings.Contrast / 100),
            [F.Highlights] = Value(-settings.Highlights / 100), [F.Shadows] = Value(settings.Shadows / 100),
            [F.Saturation] = Value(1 + settings.Saturation / 100), [F.HdrTemperature] = Value(settings.Temperature),
            [F.HdrTint] = Value(settings.Tint), [F.CropX] = Value(settings.Geometry.CropX), [F.CropY] = Value(settings.Geometry.CropY),
            [F.CropWidth] = Value(settings.Geometry.CropWidth), [F.CropHeight] = Value(settings.Geometry.CropHeight),
            [F.QuarterTurns] = Value(settings.Geometry.QuarterTurns), [F.FlipHorizontal] = Value(settings.Geometry.FlipHorizontal),
            [F.FlipVertical] = Value(settings.Geometry.FlipVertical), [F.Straighten] = Value(settings.Geometry.StraightenDegrees),
            [F.PerspectiveHorizontal] = Value(settings.Geometry.PerspectiveHorizontal),
            [F.PerspectiveVertical] = Value(settings.Geometry.PerspectiveVertical),
            [F.BlackPoint] = Value(tone.BlackPoint), [F.WhitePoint] = Value(tone.WhitePoint),
            [F.SCurve] = Value(tone.CurveStrength / 100), [F.Curve] = JsonSerializer.SerializeToElement(tone.Curve),
            [F.Vibrance] = Value(color.Vibrance), [F.Sharpening] = Value(detail.Sharpening),
            [F.Clarity] = Value(detail.Clarity * 100), [F.Dehaze] = Value(detail.Dehaze * 100),
            [F.PostRGBDenoise] = Value(detail.Denoise),
            [F.HdrLook] = look.IsDefault ? Value<object?>(null) : Value(new { sha256 = look.Sha256, name = look.Name, strength = look.Strength })
        };
        foreach (var field in AdjustmentFields.HDREffects)
            result[field] = Value(effects[(PhotoEffectParameter)((int)field-(int)F.VignetteAmount)]);
        foreach (var field in AdjustmentFields.HDRColor)
        {
            if (field.HslIndex() is { } index) result[field] = Value(color.Hsl.Value(index / 8, index % 8));
            if (field.GradingZone() is { } zone)
            {
                var wheel = color.Grading[zone];
                result[field] = JsonSerializer.SerializeToElement(new { hue = wheel.Hue, saturation = wheel.Saturation });
            }
        }
        return result;
    }
}
