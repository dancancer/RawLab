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
        [F.Clarity] = AtmosphereParameter.Clarity, [F.Dehaze] = AtmosphereParameter.Dehaze
    };
    internal static IEnumerable<F> NumericFields => Scalars.Keys.Concat(ToneFields.Keys).Concat(AtmosphereFields.Keys);
    internal static readonly IReadOnlySet<F> Scaled = new HashSet<F> { F.Exposure,F.Contrast,F.Highlights,F.Shadows,F.Saturation };
    internal static double Logical(AdjustmentSnapshot s, F field)
    {
        if (AtmosphereFields.TryGetValue(field, out var atmosphere)) return (s.Atmosphere ?? new())[atmosphere];
        if (ToneFields.TryGetValue(field, out var tone)) return (s.ToneControls ?? new())[tone];
        if (field.HslIndex() is {} index) return (s.Hsl ?? new()).Values[index];
        var value = s.Values[(int)Scalars[field]];
        return field switch { F.Exposure=>value, F.Contrast or F.Saturation=>1+value/100, F.Highlights=>-value/100, _=>value/100 };
    }
    internal static AdjustmentSnapshot SetLogical(AdjustmentSnapshot s, F field, double value)
    {
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
        values[(int)Scalars[field]]=field switch { F.Exposure=>value, F.Contrast or F.Saturation=>(value-1)*100, F.Highlights=>-value*100, _=>value*100 };
        var result=s with { Values=values }; _=result.Restore(); return result;
    }
    internal static Dictionary<F,JsonElement> Values(SavedEdit edit, AdjustmentTransferContext context)
    {
        var s=edit.Settings; var result=new Dictionary<F,JsonElement>();
        void Put<T>(F field,T value) => result[field]=Value(value);
        Put(F.Curve, s.Curve ?? new ToneCurveSettings());
        foreach(var field in NumericFields.Concat(AdjustmentFields.All.Where(f=>f.HslIndex()!=null))) Put(field,Logical(s,field));
        string kind; string? id;
        if(s.MasterRecipeID is {} recipe) { kind="recipe";id=recipe; }
        else if(edit.Look==null) { kind="neutral";id=null; }
        else if(edit.Look.StartsWith("recipe-lut:",StringComparison.Ordinal)) { kind="recipe_lut";id=edit.Look[11..]; }
        else if(edit.Look.StartsWith("builtin:",StringComparison.Ordinal)) { kind="builtin";id=edit.Look[8..]; }
        else { kind="managed";id=edit.Look; }
        Put(F.Look,new {kind,id});
        Put(F.ExposureMode,context.IsRaw ? new[]{"scene","preview","sensor"}[s.ExposureMode] : "sensor");
        var camera=!context.IsRaw || s.CameraWhiteBalance;
        Put(F.WhiteBalanceMode,!context.IsRaw ? "none" : camera ? "camera" : "temperature");
        Put(F.Temperature,camera ? (double?)null : s.Values[(int)Parameter.Temperature]);
        Put(F.Tint,s.MasterRecipeID!=null || !camera ? s.Values[(int)Parameter.Tint] : (double?)null);
        foreach (var field in AdjustmentFields.All) if (field.GradingZone() is {} zone) {
            var wheel = (s.ColorGrading ?? new())[zone];
            Put(field, new { hue = wheel.Hue, saturation = wheel.Saturation });
        }
        var effects=s.Effects ?? new();
        foreach(var field in AdjustmentFields.All.Where(f=>f is >= F.VignetteAmount and <= F.GrainRoughness)) Put(field,effects[(PhotoEffectParameter)((int)field-(int)F.VignetteAmount)]);
        Put(F.RawDenoise,0);Put(F.PostRGBDenoise,0);Put(F.ChromaDenoise,s.DisplayChromaDenoise);
        var denoise=s.Denoise ?? new(); Put(F.WaveletDenoise,new {enabled=denoise.Enabled,luma=denoise.Luma,chroma=denoise.Chroma,coarse=denoise.Coarse,preset=new[]{"detail","clean","custom"}[denoise.Preset]});
        var g=s.Geometry ?? new();
        Put(F.CropX,g.CropX);Put(F.CropY,g.CropY);Put(F.CropWidth,g.CropWidth);Put(F.CropHeight,g.CropHeight);
        Put(F.QuarterTurns,g.QuarterTurns);Put(F.FlipHorizontal,g.FlipHorizontal);Put(F.FlipVertical,g.FlipVertical);
        Put(F.Straighten,g.StraightenDegrees);Put(F.PerspectiveHorizontal,g.PerspectiveHorizontal);Put(F.PerspectiveVertical,g.PerspectiveVertical);
        var lens=context.IsRaw ? s.Lens ?? new() : new();
        Put(F.LensDistortion,lens.Distortion);Put(F.LensTCA,lens.Tca);Put(F.LensAutoCrop,lens.AutoCrop);
        Put(F.LensProfile,lens.Manual ? lens.CoreProfileId : null);
        return result;
    }
    internal static AdjustmentSnapshot ApplyObjects(AdjustmentPayload p,AdjustmentSnapshot s,AdjustmentTransferContext context)
    {
        if (p[F.Curve] is {} curve) {
            var parsed = ToneCurveSettings.Parse(curve);
            s = s with { Curve = parsed.IsDefault ? null : parsed };
        }
        foreach (var field in p.Fields) if (field.GradingZone() is {} zone && p[field] is {} wheel) {
            s = s with { ColorGrading = (s.ColorGrading ?? new()).With(zone,
                new ColorGradingWheel(wheel.GetProperty("hue").GetDouble(), wheel.GetProperty("saturation").GetDouble())) };
        }
        double N(F f,double fallback)=>Number(p[f]) ?? fallback;
        bool B(F f,bool fallback)=>Boolean(p[f]) ?? fallback;
        foreach(var field in new[]{F.RawDenoise,F.PostRGBDenoise})
            if(p[field]!=null && Number(p[field])!=0) throw new AdjustmentTransferException(AdjustmentFailure.Incompatible,field.ID());
        if(s.AIDenoiseEnabled && p.Fields.Overlaps(AdjustmentFields.Denoise))
            throw new AdjustmentTransferException(AdjustmentFailure.Incompatible,"AI denoise is enabled on target");
        if(p[F.ChromaDenoise]!=null) s=s with {DisplayChromaDenoise=(int)(Number(p[F.ChromaDenoise]) ?? 0)};
        if(p[F.WaveletDenoise] is {} wavelet) {
            var d=Null(wavelet) ? new DenoiseSettings() : new(Boolean(wavelet.GetProperty("enabled"))!.Value,
                Number(wavelet.GetProperty("luma"))!.Value,Number(wavelet.GetProperty("chroma"))!.Value,Number(wavelet.GetProperty("coarse"))!.Value);
            if(!Null(wavelet) && new[]{"detail","clean","custom"}[d.Preset]!=Text(wavelet.GetProperty("preset")))
                throw new AdjustmentTransferException(AdjustmentFailure.Unrepresentable,"detail.denoise.wavelet.preset");
            s=s with {Denoise=d};
        }
        if(p.Fields.Any(f=>f.Group()=="effects")) {
            var e=s.Effects ?? new();
            s=s with {Effects=new(N(F.VignetteAmount,e.VignetteAmount),N(F.VignetteMidpoint,e.VignetteMidpoint),N(F.VignetteRoundness,e.VignetteRoundness),
                N(F.VignetteFeather,e.VignetteFeather),N(F.VignetteHighlights,e.VignetteHighlights),N(F.GrainAmount,e.GrainAmount),N(F.GrainSize,e.GrainSize),N(F.GrainRoughness,e.GrainRoughness))};
        }
        if(p.Fields.Any(f=>f.Group()=="geometry" && !AdjustmentFields.Lens.Contains(f))) {
            var g=s.Geometry ?? new();
            s=s with {Geometry=new(N(F.CropX,g.CropX),N(F.CropY,g.CropY),N(F.CropWidth,g.CropWidth),N(F.CropHeight,g.CropHeight),
                (int)N(F.QuarterTurns,g.QuarterTurns),B(F.FlipHorizontal,g.FlipHorizontal),B(F.FlipVertical,g.FlipVertical),N(F.Straighten,g.StraightenDegrees),
                N(F.PerspectiveHorizontal,g.PerspectiveHorizontal),N(F.PerspectiveVertical,g.PerspectiveVertical))};
        }
        if(p.Fields.Overlaps(AdjustmentFields.Lens)) {
            if(!context.IsRaw) {
                var defaults=Values(new(new("",0,0,0),new Adjustments().Capture(),null),context);
                if(AdjustmentFields.Lens.Any(f=>p[f]!=null && !Same(p[f],defaults[f])))
                    throw new AdjustmentTransferException(AdjustmentFailure.Incompatible,"geometry.lens");
            }
            var l=s.Lens ?? new(); var profile=p[F.LensProfile];
            var profileId=Text(profile);if(profileId==new LensSettings(Manual:true).CoreProfileId)profileId=null;
            l=l with {Distortion=B(F.LensDistortion,l.Distortion),Tca=B(F.LensTCA,l.Tca),AutoCrop=B(F.LensAutoCrop,l.AutoCrop),
                Manual=profile!=null ? !Null(profile) : l.Manual,ProfileId=profile!=null ? profileId : l.ProfileId};
            if(l.Enabled && l.Manual && l.ProfileId==null)
                throw new AdjustmentTransferException(AdjustmentFailure.Unrepresentable,F.LensProfile.ID());
            if(l.Enabled) {
                if(!context.IsRaw || context.ValidateLens==null) throw new AdjustmentTransferException(AdjustmentFailure.Incompatible,"target lens calibration unavailable");
                context.ValidateLens(l);
            }
            s=s with {Lens=l};
        }
        _=s.Restore(); return s;
    }
}
