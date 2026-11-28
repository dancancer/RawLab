using System.Text.Json;
using F = RawLab.Windows.AdjustmentField;
using static RawLab.Windows.AdjustmentPayload;

namespace RawLab.Windows;

internal static class AdjustmentTransferValues
{
    internal static readonly IReadOnlyDictionary<F, Parameter> Scalars = new Dictionary<F, Parameter> {
        [F.Strength]=Parameter.Strength, [F.Exposure]=Parameter.Exposure, [F.Contrast]=Parameter.Contrast,
        [F.Highlights]=Parameter.Highlights, [F.Shadows]=Parameter.Shadows, [F.SCurve]=Parameter.ToneCurve,
        [F.Saturation]=Parameter.Saturation, [F.Sharpening]=Parameter.Sharpening
    };
    internal static readonly IReadOnlyDictionary<F, ToneControlParameter> ToneFields = new Dictionary<F, ToneControlParameter> {
        [F.BlackPoint] = ToneControlParameter.BlackPoint, [F.WhitePoint] = ToneControlParameter.WhitePoint,
        [F.Vibrance] = ToneControlParameter.Vibrance
    };
    internal static readonly IReadOnlyDictionary<F, AtmosphereParameter> AtmosphereFields = new Dictionary<F, AtmosphereParameter> {
        [F.Clarity] = AtmosphereParameter.Clarity, [F.Dehaze] = AtmosphereParameter.Dehaze,
        [F.Texture] = AtmosphereParameter.Texture
    };
    internal static IEnumerable<F> NumericFields => Scalars.Keys.Concat(ToneFields.Keys).Concat(AtmosphereFields.Keys);
    internal static readonly IReadOnlySet<F> Scaled = new HashSet<F> { F.Exposure,F.Contrast,F.Highlights,F.Shadows,F.Saturation };
    internal static double Logical(AdjustmentSnapshot s, F field)
    {
        s = s.Normalized();
        if (AtmosphereFields.TryGetValue(field, out var atmosphere)) return (s.Atmosphere ?? new())[atmosphere];
        if (ToneFields.TryGetValue(field, out var tone)) return (s.ToneControls ?? new())[tone];
        if (field.HslIndex() is {} index) return (s.Hsl ?? new()).Values[index];
        return s.Values[(int)Scalars[field]];
    }
    internal static AdjustmentSnapshot SetLogical(AdjustmentSnapshot s, F field, double value)
    {
        s = s.Normalized();
        if (AtmosphereFields.TryGetValue(field, out var atmosphere)) {
            var controls = (s.Atmosphere ?? new()).With(atmosphere, value); _ = controls.NativeConfig();
            return s with { Atmosphere = controls.IsIdentity ? null : controls };
        }
        if (ToneFields.TryGetValue(field, out var tone)) {
            var controls = (s.ToneControls ?? new()).With(tone, value); _ = controls.NativeConfig();
            return s with { ToneControls = controls.IsIdentity ? null : controls };
        }
        if (field.HslIndex() is {} index) {
            var hsl=(s.Hsl ?? new()).Values; hsl[index]=value; return s with { Hsl=new(hsl) };
        }
        var values=(double[])s.Values.Clone();
        values[(int)Scalars[field]]=value;
        var result=s with { Values=values }; _=result.Restore(); return result;
    }
    internal static Dictionary<F,JsonElement> Values(SavedEdit edit, AdjustmentTransferContext context)
    {
        var s=edit.Settings.Normalized(); var result=new Dictionary<F,JsonElement>();
        void Put<T>(F field,T value) => result[field]=Value(value);
        var curve = s.Curve ?? new ToneCurveSettings();
        result[F.Curve] = CurveElement(curve);
        Put(F.CurveApplyToLuminosity, curve.ApplyToLuminosity);
        result[F.CurveParametric] = ParametricElement(curve.Parametric);
        foreach(var field in NumericFields.Concat(AdjustmentFields.All.Where(f=>f.HslIndex()!=null))) Put(field,Logical(s,field));
        string kind; string? id;
        if(s.MasterRecipeID is {} recipe) { kind="recipe";id=recipe; }
        else if(edit.Look==null) { kind="neutral";id=null; }
        else if(edit.Look.StartsWith("recipe-lut:",StringComparison.Ordinal)) { kind="recipe_lut";id=edit.Look[11..]; }
        else if(edit.Look.StartsWith("builtin:",StringComparison.Ordinal)) { kind="builtin";id=edit.Look[8..]; }
        else { kind="managed";id=edit.Look; }
        Put(F.Look,new {kind,id});
        Put(F.ExposureMode,context.IsRaw ? new[]{"scene","preview","sensor"}[s.ExposureMode] : "sensor");
        if (!context.IsRaw) {
            var rasterRelative = s.MasterRecipeID == null && (s.Values[(int)Parameter.Temperature] != 6500 || s.Values[(int)Parameter.Tint] != 0);
            Put(F.WhiteBalanceMode, rasterRelative ? "relative" : "none");
            Put(F.Temperature, rasterRelative ? s.Values[(int)Parameter.Temperature] : (double?)null);
            Put(F.Tint, rasterRelative || s.MasterRecipeID != null ? s.Values[(int)Parameter.Tint] : (double?)null);
        } else {
            var camera = s.CameraWhiteBalance;
            Put(F.WhiteBalanceMode, camera ? "camera" : "temperature");
            Put(F.Temperature, camera ? (double?)null : s.Values[(int)Parameter.Temperature]);
            Put(F.Tint, s.MasterRecipeID != null || !camera ? s.Values[(int)Parameter.Tint] : (double?)null);
        }
        var grading = s.ColorGrading ?? new();
        foreach (var field in AdjustmentFields.All) if (field.GradingZone() is {} zone) {
            result[field] = WheelElement(grading[zone]);
        }
        result[F.GradingGlobal] = WheelElement(grading.Global);
        Put(F.GradingBlending, grading.Blending);
        Put(F.GradingBalance, grading.Balance);
        var effects=s.Effects ?? new();
        foreach(var field in AdjustmentFields.All.Where(f=>f is >= F.VignetteAmount and <= F.GrainRoughness)) Put(field,effects[(PhotoEffectParameter)((int)field-(int)F.VignetteAmount)]);
        Put(F.GrainToneCurve, effects.GrainToneCurve.WireValue());
        Put(F.GrainFormatPreset, effects.GrainFormatPreset.WireValue());
        var cal = s.CameraCalibration ?? new();
        Put(F.CalibrationShadowTint, cal.ShadowTint);
        Put(F.CalibrationRedHue, cal.RedHue); Put(F.CalibrationRedSaturation, cal.RedSaturation);
        Put(F.CalibrationGreenHue, cal.GreenHue); Put(F.CalibrationGreenSaturation, cal.GreenSaturation);
        Put(F.CalibrationBlueHue, cal.BlueHue); Put(F.CalibrationBlueSaturation, cal.BlueSaturation);
        var pc = s.PointColor ?? new();
        Put(F.PointColor, new {
            swatches = pc.Swatches.Select(sw => new {
                src_hue = sw.SrcHue, src_saturation = sw.SrcSaturation, src_luminance = sw.SrcLuminance,
                hue_shift = sw.HueShift, saturation_shift = sw.SaturationShift, luminance_shift = sw.LuminanceShift,
                range = sw.Range, hue_range = sw.HueRange, sat_range = sw.SatRange, lum_range = sw.LumRange,
                variance = sw.Variance, enabled = sw.Enabled
            }).ToArray()
        });
        var sc = s.SelectiveColor ?? new();
        Put(F.SelectiveColor, new {
            method = sc.Method.WireValue(),
            bands = sc.Bands.AsMap().ToDictionary(kv => kv.Key, kv => new {
                cyan = kv.Value.Cyan, magenta = kv.Value.Magenta, yellow = kv.Value.Yellow, black = kv.Value.Black
            })
        });
        var bw = s.BwMixer ?? new();
        Put(F.BwEnabled, bw.Enabled);
        Put(F.BwMixer, bw.Mixer.AsMap());
        var sv2 = s.SharpenV2 ?? new();
        Put(F.SharpeningLuminanceV2, sv2.LuminanceV2);
        Put(F.SharpeningRadius, sv2.Radius);
        Put(F.SharpeningDetail, sv2.Detail);
        Put(F.SharpeningMasking, sv2.Masking);
        var fo = s.FilmOptics ?? new();
        Put(F.HalationAmount, fo.HalationAmount); Put(F.HalationThreshold, fo.HalationThreshold);
        Put(F.HalationRadius, fo.HalationRadius); Put(F.HalationHue, fo.HalationHue);
        Put(F.BloomAmount, fo.BloomAmount); Put(F.BloomThreshold, fo.BloomThreshold); Put(F.BloomRadius, fo.BloomRadius);
        Put(F.RawDenoise,0);Put(F.PostRGBDenoise,0);Put(F.ChromaDenoise,s.DisplayChromaDenoise);
        var denoise=s.Denoise ?? new(); Put(F.WaveletDenoise,new {enabled=denoise.Enabled,luma=denoise.Luma,chroma=denoise.Chroma,coarse=denoise.Coarse,preset=new[]{"detail","clean","custom"}[denoise.Preset]});
        var g=s.Geometry ?? new();
        Put(F.CropX,g.CropX);Put(F.CropY,g.CropY);Put(F.CropWidth,g.CropWidth);Put(F.CropHeight,g.CropHeight);
        Put(F.QuarterTurns,g.QuarterTurns);Put(F.FlipHorizontal,g.FlipHorizontal);Put(F.FlipVertical,g.FlipVertical);
        Put(F.Straighten,g.StraightenDegrees);Put(F.PerspectiveHorizontal,g.PerspectiveHorizontal);Put(F.PerspectiveVertical,g.PerspectiveVertical);
        var actualLens = s.Lens ?? new();
        var lens=context.IsRaw ? actualLens : new();
        Put(F.LensDistortion,lens.Distortion);Put(F.LensTCA,lens.Tca);Put(F.LensVignetting,lens.Vignetting);Put(F.LensAutoCrop,lens.AutoCrop);
        Put(F.LensProfile,lens.Manual ? lens.CoreProfileId : null);
        Put(F.LensDefringePurpleAmount, actualLens.DefringePurpleAmount);
        Put(F.LensDefringePurpleHue, actualLens.DefringePurpleHue);
        Put(F.LensDefringeGreenAmount, actualLens.DefringeGreenAmount);
        Put(F.LensDefringeGreenHue, actualLens.DefringeGreenHue);
        return result;
    }
    internal static AdjustmentSnapshot ApplyObjects(AdjustmentPayload p,AdjustmentSnapshot s,AdjustmentTransferContext context)
    {
        s = s.Normalized();
        double N(F f,double fallback)=>Number(p[f]) ?? fallback;
        bool B(F f,bool fallback)=>Boolean(p[f]) ?? fallback;
        // Q3：Windows 的 SDR 管线不建模这两个键，收到非 0 值忽略并提示，不再拒绝。
        foreach(var field in new[]{F.RawDenoise,F.PostRGBDenoise})
            if(p[field]!=null && Number(p[field])!=0) context.OnTransferNotice?.Invoke(field==F.RawDenoise ? AdjustmentTransferNotice.IgnoredRawDenoise : AdjustmentTransferNotice.IgnoredPostRGBDenoise);
        if(p[F.ChromaDenoise]!=null) {
            var chroma=(int)(Number(p[F.ChromaDenoise]) ?? 0);
            if(s.AIDenoiseEnabled) {
                if(chroma!=0) context.OnTransferNotice?.Invoke(AdjustmentTransferNotice.IgnoredTargetDenoise);
            } else s=s with {DisplayChromaDenoise=chroma};
        }
        if(p[F.WaveletDenoise] is {} wavelet) {
            var d=Null(wavelet) ? new DenoiseSettings() : new(Boolean(wavelet.GetProperty("enabled"))!.Value,
                Number(wavelet.GetProperty("luma"))!.Value,Number(wavelet.GetProperty("chroma"))!.Value,Number(wavelet.GetProperty("coarse"))!.Value);
            // AI 运行时传统降噪不生效，连零值也不覆盖关闭 AI 后要恢复的存量参数。
            if(s.AIDenoiseEnabled) {
                if(d!=new DenoiseSettings() || !Null(wavelet) && Text(wavelet.GetProperty("preset"))!="detail")
                    context.OnTransferNotice?.Invoke(AdjustmentTransferNotice.IgnoredTargetDenoise);
            } else {
                if(!Null(wavelet) && new[]{"detail","clean","custom"}[d.Preset]!=Text(wavelet.GetProperty("preset")))
                    throw new AdjustmentTransferException(AdjustmentFailure.Unrepresentable,"detail.denoise.wavelet.preset");
                s=s with {Denoise=d};
            }
        }
        if(p.Fields.Any(f=>f.Group()=="effects")) {
            var e=s.Effects ?? new();
            s=s with {Effects=new(N(F.VignetteAmount,e.VignetteAmount),N(F.VignetteMidpoint,e.VignetteMidpoint),N(F.VignetteRoundness,e.VignetteRoundness),
                N(F.VignetteFeather,e.VignetteFeather),N(F.VignetteHighlights,e.VignetteHighlights),N(F.GrainAmount,e.GrainAmount),N(F.GrainSize,e.GrainSize),N(F.GrainRoughness,e.GrainRoughness),
                Text(p[F.GrainToneCurve]) is { } tc ? GrainToneCurveExtensions.ParseGrainToneCurve(tc) : e.GrainToneCurve,
                Text(p[F.GrainFormatPreset]) is { } fp ? GrainFormatPresetExtensions.ParseGrainFormatPreset(fp) : e.GrainFormatPreset)};
            if (p.Fields.Any(f => f is F.HalationAmount or F.HalationThreshold or F.HalationRadius or F.HalationHue or F.BloomAmount or F.BloomThreshold or F.BloomRadius)) {
                var fo = s.FilmOptics ?? new();
                var updatedFo = fo with {
                    HalationAmount = N(F.HalationAmount, fo.HalationAmount),
                    HalationThreshold = N(F.HalationThreshold, fo.HalationThreshold),
                    HalationRadius = N(F.HalationRadius, fo.HalationRadius),
                    HalationHue = N(F.HalationHue, fo.HalationHue),
                    BloomAmount = N(F.BloomAmount, fo.BloomAmount),
                    BloomThreshold = N(F.BloomThreshold, fo.BloomThreshold),
                    BloomRadius = N(F.BloomRadius, fo.BloomRadius)
                };
                s = s with { FilmOptics = updatedFo.IsDefault ? null : updatedFo };
            }
        }
        if (p.Fields.Any(f => f is F.CalibrationShadowTint or F.CalibrationRedHue or F.CalibrationRedSaturation or
            F.CalibrationGreenHue or F.CalibrationGreenSaturation or F.CalibrationBlueHue or F.CalibrationBlueSaturation)) {
            var cal = s.CameraCalibration ?? new();
            var updatedCal = cal with {
                ShadowTint = N(F.CalibrationShadowTint, cal.ShadowTint),
                RedHue = N(F.CalibrationRedHue, cal.RedHue),
                RedSaturation = N(F.CalibrationRedSaturation, cal.RedSaturation),
                GreenHue = N(F.CalibrationGreenHue, cal.GreenHue),
                GreenSaturation = N(F.CalibrationGreenSaturation, cal.GreenSaturation),
                BlueHue = N(F.CalibrationBlueHue, cal.BlueHue),
                BlueSaturation = N(F.CalibrationBlueSaturation, cal.BlueSaturation)
            };
            s = s with { CameraCalibration = updatedCal.IsDefault ? null : updatedCal };
        }
        if (p[F.PointColor] is {} pcElem && PointColorValue(pcElem) is {} pcVal) {
            s = s with { PointColor = pcVal.IsDefault ? null : pcVal };
        }
        if (p[F.SelectiveColor] is {} scElem && SelectiveColorValue(scElem) is {} scVal) {
            s = s with { SelectiveColor = scVal.IsDefault ? null : scVal };
        }
        if (p[F.BwEnabled] != null || p[F.BwMixer] != null) {
            var bw = s.BwMixer ?? new();
            var updatedBw = new BwMixerSettings(
                enabled: B(F.BwEnabled, bw.Enabled),
                mixer: p[F.BwMixer] is {} mxElem ? (BwMixerValue(mxElem) ?? bw.Mixer) : bw.Mixer);
            s = s with { BwMixer = updatedBw.IsDefault ? null : updatedBw };
        }
        if (p.Fields.Any(f => f is F.SharpeningLuminanceV2 or F.SharpeningRadius or F.SharpeningDetail or F.SharpeningMasking)) {
            var sv2 = s.SharpenV2 ?? new();
            var updatedSv2 = sv2 with {
                LuminanceV2 = B(F.SharpeningLuminanceV2, sv2.LuminanceV2),
                Radius = N(F.SharpeningRadius, sv2.Radius),
                Detail = N(F.SharpeningDetail, sv2.Detail),
                Masking = N(F.SharpeningMasking, sv2.Masking)
            };
            s = s with { SharpenV2 = updatedSv2.IsDefault ? null : updatedSv2 };
        }
        if(p.Fields.Any(f=>f.Group()=="geometry" && !AdjustmentFields.Lens.Contains(f) && !AdjustmentFields.Defringe.Contains(f))) {
            var g=s.Geometry ?? new();
            s=s with {Geometry=new(N(F.CropX,g.CropX),N(F.CropY,g.CropY),N(F.CropWidth,g.CropWidth),N(F.CropHeight,g.CropHeight),
                (int)N(F.QuarterTurns,g.QuarterTurns),B(F.FlipHorizontal,g.FlipHorizontal),B(F.FlipVertical,g.FlipVertical),N(F.Straighten,g.StraightenDegrees),
                N(F.PerspectiveHorizontal,g.PerspectiveHorizontal),N(F.PerspectiveVertical,g.PerspectiveVertical))};
        }
        if (p.Fields.Overlaps(AdjustmentFields.Defringe)) {
            var l = s.Lens ?? new();
            s = s with {
                Lens = l with {
                    DefringePurpleAmount = N(F.LensDefringePurpleAmount, l.DefringePurpleAmount),
                    DefringePurpleHue = N(F.LensDefringePurpleHue, l.DefringePurpleHue),
                    DefringeGreenAmount = N(F.LensDefringeGreenAmount, l.DefringeGreenAmount),
                    DefringeGreenHue = N(F.LensDefringeGreenHue, l.DefringeGreenHue)
                }
            };
        }
        if(p.Fields.Overlaps(AdjustmentFields.Lens)) {
            var defaults=Values(new(new("",0,0,0),new Adjustments().Capture(),null),context);
            var isNeutralLens=AdjustmentFields.Lens.All(f=>p[f]==null || Same(p[f],defaults[f]));
            if(!context.IsRaw && !isNeutralLens)
                throw new AdjustmentTransferException(AdjustmentFailure.Incompatible,"geometry.lens");
            if(p.Source.IsRaw || !context.IsRaw || !isNeutralLens) {
                var l=s.Lens ?? new(); var profile=p[F.LensProfile];
                var profileId=Text(profile);if(profileId==new LensSettings(Manual:true).CoreProfileId)profileId=null;
                l=l with {Distortion=B(F.LensDistortion,l.Distortion),Tca=B(F.LensTCA,l.Tca),Vignetting=B(F.LensVignetting,l.Vignetting),AutoCrop=B(F.LensAutoCrop,l.AutoCrop),
                    Manual=profile!=null ? !Null(profile) : l.Manual,ProfileId=profile!=null ? profileId : l.ProfileId};
                if(l.Enabled && l.Manual && l.ProfileId==null)
                    throw new AdjustmentTransferException(AdjustmentFailure.Unrepresentable,F.LensProfile.ID());
                if(l.Enabled) {
                    if(!context.IsRaw || context.ValidateLens==null) throw new AdjustmentTransferException(AdjustmentFailure.Incompatible,"target lens calibration unavailable");
                    context.ValidateLens(l);
                }
                s=s with {Lens=l};
            }
        }
        if (p[F.CurveApplyToLuminosity] is {} applyLum && Boolean(applyLum) is {} applyBool) {
            var current = s.Curve ?? new();
            var updated = new ToneCurveSettings(current.Mode, current.Points, current.Channels, applyBool, current.Parametric);
            s = s with { Curve = updated.IsDefault ? null : updated };
        }
        if (p[F.CurveParametric] is {} paramElem) {
            var current = s.Curve ?? new();
            var parametric = ToneCurveParametric.Parse(paramElem);
            var updated = new ToneCurveSettings(current.Mode, current.Points, current.Channels, current.ApplyToLuminosity, parametric);
            s = s with { Curve = updated.IsDefault ? null : updated };
        }
        if (p[F.GradingBlending] != null || p[F.GradingBalance] != null) {
            var grading = s.ColorGrading ?? new();
            if (p[F.GradingBlending] is {} blendingElem && Number(blendingElem) is {} blending) grading = grading with { Blending = blending };
            if (p[F.GradingBalance] is {} balanceElem && Number(balanceElem) is {} balance) grading = grading with { Balance = balance };
            s = s with { ColorGrading = grading.IsDefault ? null : grading };
        }
        _=s.Restore(); return s;
    }

    internal static JsonElement CurveElement(ToneCurveSettings curve) =>
        JsonSerializer.SerializeToElement(new ToneCurveSettings(curve.Mode, curve.Points, curve.Channels));

    internal static JsonElement ParametricElement(ToneCurveParametric p) => Value(new {
        highlights = p.Highlights, lights = p.Lights, darks = p.Darks, shadows = p.Shadows,
        split_shadow = p.SplitShadow, split_midtone = p.SplitMidtone, split_highlight = p.SplitHighlight
    });

    internal static JsonElement WheelElement(ColorGradingWheel wheel) => wheel.Luminance == 0
        ? Value(new { hue = wheel.Hue, saturation = wheel.Saturation })
        : Value(new { hue = wheel.Hue, saturation = wheel.Saturation, luminance = wheel.Luminance });

    internal static ColorGradingWheel ParseWheel(JsonElement wheel) => new(
        wheel.GetProperty("hue").GetDouble(),
        wheel.GetProperty("saturation").GetDouble(),
        wheel.TryGetProperty("luminance", out var lum) && Number(lum) is {} l ? l : 0.0);
}
