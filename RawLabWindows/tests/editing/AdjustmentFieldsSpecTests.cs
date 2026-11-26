using System.Text.Json;
using RawLab.Windows;
using Xunit;

namespace RawLab.Windows.Tests;

public sealed class AdjustmentFieldsSpecTests
{
    private static string ResolveSpecPath()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, "Shared", "specs", "adjustment-fields-v1.json");
            if (File.Exists(candidate)) return candidate;
        }
        throw new FileNotFoundException("Shared/specs/adjustment-fields-v1.json not found");
    }

    private static double? OptDouble(JsonElement element, string propertyName) =>
        element.TryGetProperty(propertyName, out var prop) && prop.ValueKind == JsonValueKind.Number
            ? prop.GetDouble()
            : null;

    private static string? OptString(JsonElement element, string propertyName) =>
        element.TryGetProperty(propertyName, out var prop) && prop.ValueKind == JsonValueKind.String
            ? prop.GetString()
            : null;

    [Fact]
    [Trait("Category", "Model")]
    public void GeneratedSpecAndProtocolMatchRuntimeJson()
    {
        using var document = JsonDocument.Parse(File.ReadAllText(ResolveSpecPath()));
        var root = document.RootElement;
        Assert.Equal(1, root.GetProperty("spec_version").GetInt32());

        var fields = root.GetProperty("fields").EnumerateArray().ToArray();
        Assert.Equal(118, fields.Length);

        var transferIds = new List<string>();
        var localIds = new List<string>();

        foreach (var entry in fields)
        {
            var fid = entry.GetProperty("field_id").GetString()!;
            var group = entry.GetProperty("group").GetString()!;
            var proto = entry.GetProperty("protocol");
            var winModel = entry.GetProperty("model").GetProperty("windows");

            var generated = AdjustmentFieldSpec.ForId(fid);
            Assert.NotNull(generated);
            Assert.Equal(group, generated!.Group);
            Assert.Equal(proto.GetProperty("transferable").GetBoolean(), generated.Protocol.Transferable);
            Assert.Equal(proto.GetProperty("nullable").GetBoolean(), generated.Protocol.Nullable);
            Assert.Equal(proto.GetProperty("exclusive_min").GetBoolean(), generated.Protocol.ExclusiveMin);
            Assert.Equal(proto.GetProperty("hdr_only").GetBoolean(), generated.Protocol.IsHdrOnly);
            Assert.Equal(OptDouble(proto, "min"), generated.Protocol.Min);
            Assert.Equal(OptDouble(proto, "max"), generated.Protocol.Max);

            AssertModelSpecMatchesJson(fid, generated.WindowsModel, winModel);

            if (proto.GetProperty("transferable").GetBoolean())
            {
                transferIds.Add(fid);
                var enumField = AdjustmentFields.Parse(fid);
                Assert.Equal(group, enumField.Group());
                Assert.Equal(proto.GetProperty("hdr_only").GetBoolean(), enumField.IsHDROnly());
                AssertProtocolRuntimeAcceptance(enumField, proto);
            }
            else
            {
                localIds.Add(fid);
            }
        }

        Assert.Equal(115, transferIds.Count);
        Assert.Equal(3, localIds.Count);
        Assert.Equal(transferIds.ToHashSet(), Enum.GetValues<AdjustmentField>().Select(f => f.ID()).ToHashSet());
        Assert.Equal(Enum.GetValues<AdjustmentField>().Length, transferIds.Count);
        Assert.Equal(localIds, AdjustmentFieldSpec.LocalOnlyFieldIds);
    }

    [Fact]
    [Trait("Category", "Model")]
    public void EveryTransferableAdjustmentFieldHasNonEmptyPresentationTitle()
    {
        foreach (var field in Enum.GetValues<AdjustmentField>())
        {
            var title = AdjustmentTransferPresentation.Title(field);
            Assert.False(string.IsNullOrWhiteSpace(title), $"Missing presentation title for {field}");
        }

        Assert.Contains(Loc.Text("全局"), AdjustmentTransferPresentation.Title(AdjustmentField.GradingGlobal));
        Assert.Equal(Loc.Text("融合"), AdjustmentTransferPresentation.Title(AdjustmentField.GradingBlending));
        Assert.Equal(Loc.Text("平衡"), AdjustmentTransferPresentation.Title(AdjustmentField.GradingBalance));
    }

    [Fact]
    [Trait("Category", "Model")]
    public void RuntimeModelObjectsMatchWindowsSpecJson()
    {
        using var document = JsonDocument.Parse(File.ReadAllText(ResolveSpecPath()));
        var specById = document.RootElement.GetProperty("fields").EnumerateArray()
            .ToDictionary(e => e.GetProperty("field_id").GetString()!, e => e);

        JsonElement WinModel(string fid) => specById[fid].GetProperty("model").GetProperty("windows");

        // Adjustments + ParameterSpec.All
        var adjustments = new Adjustments();
        var paramBindings = new (Parameter Param, string FieldId)[]
        {
            (Parameter.Strength, "looks.strength"),
            (Parameter.Exposure, "light.exposure"),
            (Parameter.Temperature, "color.white_balance.temperature_kelvin"),
            (Parameter.Tint, "color.white_balance.tint"),
            (Parameter.Contrast, "light.contrast"),
            (Parameter.Highlights, "light.highlights"),
            (Parameter.Shadows, "light.shadows"),
            (Parameter.ToneCurve, "light.s_curve"),
            (Parameter.Saturation, "color.saturation"),
            (Parameter.Sharpening, "detail.sharpening"),
        };
        foreach (var (param, fid) in paramBindings)
        {
            var m = WinModel(fid);
            var spec = ParameterSpec.All[(int)param];
            Assert.Equal(m.GetProperty("min").GetDouble(), spec.Min);
            Assert.Equal(m.GetProperty("max").GetDouble(), spec.Max);
            Assert.Equal(m.GetProperty("default").GetDouble(), adjustments[param]);
        }

        // PhotoEffectsSettings + PhotoEffectSpec.All
        var effects = new PhotoEffectsSettings();
        var effectBindings = new (PhotoEffectParameter Param, string FieldId)[]
        {
            (PhotoEffectParameter.VignetteAmount, "effects.vignette.amount"),
            (PhotoEffectParameter.VignetteMidpoint, "effects.vignette.midpoint"),
            (PhotoEffectParameter.VignetteRoundness, "effects.vignette.roundness"),
            (PhotoEffectParameter.VignetteFeather, "effects.vignette.feather"),
            (PhotoEffectParameter.VignetteHighlights, "effects.vignette.highlights"),
            (PhotoEffectParameter.GrainAmount, "effects.grain.amount"),
            (PhotoEffectParameter.GrainSize, "effects.grain.size"),
            (PhotoEffectParameter.GrainRoughness, "effects.grain.roughness"),
        };
        foreach (var (param, fid) in effectBindings)
        {
            var m = WinModel(fid);
            var spec = PhotoEffectSpec.For(param);
            Assert.Equal(m.GetProperty("min").GetDouble(), spec.Min);
            Assert.Equal(m.GetProperty("max").GetDouble(), spec.Max);
            Assert.Equal(m.GetProperty("default").GetDouble(), spec.DefaultValue);
            Assert.Equal(m.GetProperty("default").GetDouble(), effects[param]);
        }
        Assert.Throws<ArgumentOutOfRangeException>(() => new PhotoEffectsSettings(VignetteMidpoint: -1).NativeConfig());

        // ToneControlsSettings & AtmosphereSettings
        var tone = new ToneControlsSettings();
        Assert.Equal(WinModel("tone.black_point").GetProperty("default").GetDouble(), tone.BlackPoint);
        Assert.Equal(WinModel("tone.white_point").GetProperty("default").GetDouble(), tone.WhitePoint);
        Assert.Equal(WinModel("color.vibrance").GetProperty("default").GetDouble(), tone.Vibrance);
        Assert.Throws<ArgumentOutOfRangeException>(() => new ToneControlsSettings(BlackPoint: 101).NativeConfig());

        var atmosphere = new AtmosphereSettings();
        Assert.Equal(WinModel("effects.clarity").GetProperty("default").GetDouble(), atmosphere.Clarity);
        Assert.Equal(WinModel("effects.dehaze").GetProperty("default").GetDouble(), atmosphere.Dehaze);
        Assert.Throws<ArgumentOutOfRangeException>(() => new AtmosphereSettings(Dehaze: -101).NativeConfig());

        // GeometrySettings
        var geo = new GeometrySettings();
        Assert.Equal(WinModel("geometry.crop.x").GetProperty("default").GetDouble(), geo.CropX);
        Assert.Equal(WinModel("geometry.crop.y").GetProperty("default").GetDouble(), geo.CropY);
        Assert.Equal(WinModel("geometry.crop.width").GetProperty("default").GetDouble(), geo.CropWidth);
        Assert.Equal(WinModel("geometry.crop.height").GetProperty("default").GetDouble(), geo.CropHeight);
        Assert.Equal(WinModel("geometry.quarter_turns").GetProperty("default").GetInt32(), geo.QuarterTurns);
        Assert.Equal(WinModel("geometry.flip_horizontal").GetProperty("default").GetBoolean(), geo.FlipHorizontal);
        Assert.Equal(WinModel("geometry.flip_vertical").GetProperty("default").GetBoolean(), geo.FlipVertical);
        Assert.Equal(WinModel("geometry.straighten_degrees").GetProperty("default").GetDouble(), geo.StraightenDegrees);
        Assert.Equal(WinModel("geometry.perspective.horizontal").GetProperty("default").GetDouble(), geo.PerspectiveHorizontal);
        Assert.Equal(WinModel("geometry.perspective.vertical").GetProperty("default").GetDouble(), geo.PerspectiveVertical);
        Assert.Throws<ArgumentOutOfRangeException>(() => new GeometrySettings(QuarterTurns: 4).NativeConfig());

        // ColorGradingSettings, ToneCurveSettings, DenoiseSettings, HDRSettings + HDRRenditionSpec.All
        var grading = new ColorGradingSettings();
        Assert.True(grading.IsValid);
        Assert.False(new ColorGradingWheel(360, 0).IsValid);
        Assert.Equal(WinModel("color.grading.blending").GetProperty("default").GetDouble(), grading.Blending);
        Assert.Equal(WinModel("color.grading.balance").GetProperty("default").GetDouble(), grading.Balance);
        Assert.Equal(WinModel("local.ai_denoise_strength").GetProperty("default").GetDouble(), adjustments.AIDenoiseStrength);

        var curve = new ToneCurveSettings();
        Assert.True(curve.IsDefault);
        Assert.Equal(WinModel("light.curve.apply_to_luminosity").GetProperty("default").GetBoolean(), curve.ApplyToLuminosity);
        Assert.Throws<ArgumentOutOfRangeException>(() => new ToneCurveShape(ToneCurveMode.Custom, []));

        var denoise = new DenoiseSettings();
        var waveletDef = WinModel("detail.denoise.wavelet").GetProperty("default");
        Assert.Equal(waveletDef.GetProperty("enabled").GetBoolean(), denoise.Enabled);
        Assert.Equal(waveletDef.GetProperty("luma").GetDouble(), denoise.Luma);
        Assert.Equal(waveletDef.GetProperty("chroma").GetDouble(), denoise.Chroma);
        Assert.Equal(waveletDef.GetProperty("coarse").GetDouble(), denoise.Coarse);
        Assert.Throws<ArgumentOutOfRangeException>(() => new DenoiseSettings(Luma: 101).NativeConfig());

        var hdr = new HDRSettings();
        Assert.True(hdr.IsValid);
        var hdrRenditionBindings = new (HDRRenditionParameter Param, string FieldId)[]
        {
            (HDRRenditionParameter.PeakLimitEV, "hdr.peak_limit_ev"),
            (HDRRenditionParameter.SdrExposureEV, "hdr.sdr_exposure_ev"),
            (HDRRenditionParameter.SdrContrast, "hdr.sdr_contrast"),
            (HDRRenditionParameter.SdrSaturation, "hdr.sdr_saturation"),
        };
        foreach (var (param, fid) in hdrRenditionBindings)
        {
            var m = WinModel(fid);
            var spec = HDRRenditionSpec.For(param);
            Assert.Equal(m.GetProperty("min").GetDouble(), spec.Min);
            Assert.Equal(m.GetProperty("max").GetDouble(), spec.Max);
        }

        // v0.14.0 models & SubFields
        Assert.Equal(WinModel("effects.texture").GetProperty("default").GetDouble(), atmosphere.Texture);
        Assert.Throws<ArgumentOutOfRangeException>(() => new AtmosphereSettings(Texture: 101).NativeConfig());

        var cal = new CameraCalibrationSettings();
        Assert.Equal(WinModel("color.calibration.shadow_tint").GetProperty("default").GetDouble(), cal.ShadowTint);
        Assert.Equal(WinModel("color.calibration.blue_saturation").GetProperty("default").GetDouble(), cal.BlueSaturation);
        Assert.Throws<ArgumentOutOfRangeException>(() => new CameraCalibrationSettings(ShadowTint: -101).Validate());

        Assert.True(new PointColorSettings().IsDefault);
        Assert.Throws<ArgumentOutOfRangeException>(() => new PointColorSwatch(SrcHue: 360).Validate());
        Assert.Throws<ArgumentOutOfRangeException>(() => new PointColorSwatch(SrcSaturation: 1.1).Validate());
        Assert.Throws<ArgumentOutOfRangeException>(() =>
            new PointColorSettings(Enumerable.Range(0, AdjustmentFieldSpec.SubFields.PointColor.MaxSwatches + 1).Select(_ => new PointColorSwatch()).ToArray()).Validate());

        var sel = new SelectiveColorSettings();
        Assert.Equal("relative", sel.Method.WireValue());
        Assert.Throws<ArgumentOutOfRangeException>(() => new SelectiveColorBand(Cyan: 101).Validate());

        var bw = new BwMixerSettings();
        Assert.Equal(WinModel("color.bw.enabled").GetProperty("default").GetBoolean(), bw.Enabled);
        Assert.Throws<ArgumentOutOfRangeException>(() => new BwMixerWeights(Red: -101).Validate());

        var sv2 = new SharpenV2Settings();
        Assert.Equal(WinModel("detail.sharpening.luminance_v2").GetProperty("default").GetBoolean(), sv2.LuminanceV2);
        Assert.Equal(WinModel("detail.sharpening.radius").GetProperty("default").GetDouble(), sv2.Radius);
        Assert.Equal(WinModel("detail.sharpening.detail").GetProperty("default").GetDouble(), sv2.Detail);
        Assert.Equal(WinModel("detail.sharpening.masking").GetProperty("default").GetDouble(), sv2.Masking);
        Assert.Throws<ArgumentOutOfRangeException>(() => new SharpenV2Settings(Radius: 0.4).Validate());

        var fo = new FilmOpticsSettings();
        Assert.Equal(WinModel("effects.halation.amount").GetProperty("default").GetDouble(), fo.HalationAmount);
        Assert.Equal(WinModel("effects.halation.threshold").GetProperty("default").GetDouble(), fo.HalationThreshold);
        Assert.Equal(WinModel("effects.halation.radius").GetProperty("default").GetDouble(), fo.HalationRadius);
        Assert.Equal(WinModel("effects.halation.hue").GetProperty("default").GetDouble(), fo.HalationHue);
        Assert.Equal(WinModel("effects.bloom.amount").GetProperty("default").GetDouble(), fo.BloomAmount);
        Assert.Equal(WinModel("effects.bloom.threshold").GetProperty("default").GetDouble(), fo.BloomThreshold);
        Assert.Equal(WinModel("effects.bloom.radius").GetProperty("default").GetDouble(), fo.BloomRadius);
        Assert.Throws<ArgumentOutOfRangeException>(() => new FilmOpticsSettings(BloomRadius: 101).Validate());

        Assert.Equal(WinModel("effects.grain.tone_curve").GetProperty("default").GetString(), effects.GrainToneCurve.WireValue());
        Assert.Equal(WinModel("effects.grain.format_preset").GetProperty("default").GetString(), effects.GrainFormatPreset.WireValue());

        var lens = new LensSettings();
        Assert.Equal(WinModel("geometry.lens.defringe_purple_amount").GetProperty("default").GetDouble(), lens.DefringePurpleAmount);
        Assert.Equal(WinModel("geometry.lens.defringe_purple_hue").GetProperty("default").GetDouble(), lens.DefringePurpleHue);
        Assert.Equal(WinModel("geometry.lens.defringe_green_amount").GetProperty("default").GetDouble(), lens.DefringeGreenAmount);
        Assert.Equal(WinModel("geometry.lens.defringe_green_hue").GetProperty("default").GetDouble(), lens.DefringeGreenHue);
        Assert.Throws<ArgumentOutOfRangeException>(() => new LensSettings(DefringePurpleAmount: 21).Validate());
    }

    private static void AssertModelSpecMatchesJson(string fid, AdjustmentFieldModelSpec actual, JsonElement json)
    {
        Assert.Equal(json.GetProperty("supported").GetBoolean(), actual.Supported);
        var modes = json.GetProperty("modes").EnumerateArray().Select(x => x.GetString()!).ToArray();
        Assert.Equal(modes, actual.Modes);
        Assert.Equal(json.GetProperty("storage_type").GetString(), actual.StorageType);
        Assert.Equal(json.GetProperty("nullable").GetBoolean(), actual.Nullable);
        Assert.Equal(OptDouble(json, "min"), actual.Min);
        Assert.Equal(OptDouble(json, "max"), actual.Max);
        Assert.Equal(json.GetProperty("scale_from_protocol").GetString(), actual.ScaleFromProtocol);
        Assert.Equal(json.GetProperty("quantization").GetString(), actual.Quantization.ToString().ToLowerInvariant());
        Assert.Equal(OptDouble(json, "hdr_min"), actual.HdrMin);
        Assert.Equal(OptDouble(json, "hdr_max"), actual.HdrMax);
        Assert.Equal(OptDouble(json, "hdr_default"), actual.HdrDefaultNumber);
        Assert.Equal(OptString(json, "hdr_scale_from_protocol"), actual.HdrScaleFromProtocol);
    }

    private static void AssertProtocolRuntimeAcceptance(AdjustmentField field, JsonElement proto)
    {
        var isHdr = proto.GetProperty("hdr_only").GetBoolean();
        var source = new AdjustmentSource("spec-probe", !isHdr, 3, null, isHdr ? 7 : null);
        var nullable = proto.GetProperty("nullable").GetBoolean();
        if (nullable && field != AdjustmentField.Tint)
        {
            _ = new AdjustmentPayload(source, new Dictionary<AdjustmentField, JsonElement> { [field] = AdjustmentPayload.Value<object?>(null) });
        }
        else if (!nullable)
        {
            Assert.Throws<AdjustmentTransferException>(() =>
                new AdjustmentPayload(source, new Dictionary<AdjustmentField, JsonElement> { [field] = AdjustmentPayload.Value<object?>(null) }));
        }

        var valueType = proto.GetProperty("value_type").GetString();
        if ((valueType is "number" or "integer") && OptDouble(proto, "min") is { } minV && OptDouble(proto, "max") is { } maxV)
        {
            var exclusiveMin = proto.GetProperty("exclusive_min").GetBoolean();
            if (field is not (AdjustmentField.Temperature or AdjustmentField.Tint))
            {
                var loTest = exclusiveMin ? minV : minV - 1.0;
                Assert.Throws<AdjustmentTransferException>(() =>
                    new AdjustmentPayload(source, new Dictionary<AdjustmentField, JsonElement> { [field] = AdjustmentPayload.Value(loTest) }));
                Assert.Throws<AdjustmentTransferException>(() =>
                    new AdjustmentPayload(source, new Dictionary<AdjustmentField, JsonElement> { [field] = AdjustmentPayload.Value(maxV + 1.0) }));
                if (!exclusiveMin)
                {
                    _ = new AdjustmentPayload(source, new Dictionary<AdjustmentField, JsonElement> { [field] = AdjustmentPayload.Value(minV) });
                }
                _ = new AdjustmentPayload(source, new Dictionary<AdjustmentField, JsonElement> { [field] = AdjustmentPayload.Value(maxV) });
            }
        }
    }
}
