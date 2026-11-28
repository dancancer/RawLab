using F = RawLab.Windows.AdjustmentField;

namespace RawLab.Windows;

internal static class AdjustmentTransferRefinement
{
    internal static AdjustmentSnapshot Apply(AdjustmentPayload payload, AdjustmentSnapshot original, AdjustmentSnapshot target, bool fullRecipe)
    {
        var sourceScale = payload.Source.Recipe?.SettingsVersion >= 4 ? payload.Source.Recipe.Strength : 1;
        var previousScale = original.Restore().RefinementScale;
        var targetScale = target.Restore().RefinementScale;
        var originalCurve = original.Curve ?? new();
        var updatedCurveBase = target.Curve ?? new();
        var selectedCurve = payload[F.Curve] is {} json ? ToneCurveSettings.Parse(json, allowV2Fields: false) : null;
        var selectedApply = payload[F.CurveApplyToLuminosity] is {} applyJson && AdjustmentPayload.Boolean(applyJson) is {} applyBool ? applyBool : (bool?)null;
        var selectedParametric = payload[F.CurveParametric] is {} paramJson ? ToneCurveParametric.Parse(paramJson) : null;
        var baseDesiredCurve = selectedCurve?.Scaled(sourceScale) ?? originalCurve.Scaled(previousScale);
        var desiredCurve = new ToneCurveSettings(
            baseDesiredCurve.Mode,
            baseDesiredCurve.Points,
            baseDesiredCurve.Channels,
            selectedApply ?? originalCurve.ApplyToLuminosity,
            selectedParametric?.Scaled(sourceScale) ?? originalCurve.Parametric.Scaled(previousScale));
        var curve = fullRecipe && selectedCurve != null
            ? new ToneCurveSettings(selectedCurve.Mode, selectedCurve.Points, selectedCurve.Channels,
                selectedApply ?? originalCurve.ApplyToLuminosity, selectedParametric ?? originalCurve.Parametric)
            : new ToneCurveSettings(originalCurve.Mode, originalCurve.Points, originalCurve.Channels,
                selectedApply ?? originalCurve.ApplyToLuminosity, selectedParametric ?? originalCurve.Parametric);
        if (!Equivalent(curve.Scaled(targetScale), desiredCurve)) curve = LogicalCurve(desiredCurve, targetScale);
        if (!Equivalent(curve.Scaled(targetScale), desiredCurve)) throw Unrepresentable(F.Curve);
        var applyFinal = updatedCurveBase.ApplyToLuminosity;
        if (selectedApply is {} explicitApply) applyFinal = explicitApply;
        curve = new(curve.Mode, curve.Points, curve.Channels, applyFinal, curve.Parametric);
        var originalGrading = original.ColorGrading ?? new();
        var grading = target.ColorGrading ?? new();
        ColorGradingWheel ResolveWheel(F field, ColorGradingWheel current) {
            var selected = payload[field] is {} wheel ? AdjustmentTransferValues.ParseWheel(wheel) : null;
            var desired = selected == null ? Scaled(current, previousScale) : Scaled(selected, sourceScale);
            ColorGradingWheel logical;
            if (fullRecipe && selected != null) logical = selected;
            else if (Equivalent(Scaled(current, targetScale), desired)) logical = current;
            else {
                if (targetScale == 0 && (desired.Saturation != 0 || desired.Luminance != 0)) throw Unrepresentable(field);
                logical = new(desired.Hue, targetScale == 0 ? 0 : desired.Saturation / targetScale, targetScale == 0 ? 0 : desired.Luminance / targetScale);
            }
            if (!logical.IsValid || !Equivalent(Scaled(logical, targetScale), desired)) throw Unrepresentable(field);
            return logical;
        }
        foreach (var field in AdjustmentFields.RefinementObjects) {
            if (field.GradingZone() is not {} zone) continue;
            grading = grading.With(zone, ResolveWheel(field, originalGrading[zone]));
        }
        grading = grading with { Global = ResolveWheel(F.GradingGlobal, originalGrading.Global) };
        return target with { Curve = curve.IsDefault ? null : curve, ColorGrading = grading.IsDefault ? null : grading };
    }

    private static ToneCurveSettings LogicalCurve(ToneCurveSettings desired, double strength)
    {
        if (desired.IsDefault || strength == 0 && desired.IsIdentity) return desired;
        if (strength == 0) throw Unrepresentable(
            desired.Master.IsIdentity && desired.Channels.IsIdentity && !desired.Parametric.IsIdentity ? F.CurveParametric : F.Curve);
        var result = desired;
        foreach (var channel in Enum.GetValues<ToneCurveChannel>()) {
            var shape = desired.Shape(channel);
            if (shape.Mode == ToneCurveMode.Custom) {
                var last = shape.Points.Count - 1;
                try {
                    result = result.Replacing(channel, new(ToneCurveMode.Custom, shape.Points.Select((p, idx) =>
                        idx == 0 ? new ToneCurvePoint(p.X / strength, p.Y / strength) :
                        idx == last ? new ToneCurvePoint(1.0 + (p.X - 1.0) / strength, 1.0 + (p.Y - 1.0) / strength) :
                        new ToneCurvePoint(p.X, p.X + (p.Y - p.X) / strength))));
                } catch (ArgumentOutOfRangeException) {
                    throw Unrepresentable(F.Curve);
                }
            }
        }
        var p = desired.Parametric;
        var logicalParametric = p.IsIdentity || strength == 1 ? p : new ToneCurveParametric(
            p.Highlights / strength,
            p.Lights / strength,
            p.Darks / strength,
            p.Shadows / strength,
            p.SplitShadow,
            p.SplitMidtone,
            p.SplitHighlight);
        if (!logicalParametric.IsValid) throw Unrepresentable(F.CurveParametric);
        return new(result.Mode, result.Points, result.Channels, result.ApplyToLuminosity, logicalParametric);
    }

    private static ColorGradingWheel Scaled(ColorGradingWheel value, double strength) =>
        value with { Saturation = Math.Clamp(value.Saturation * strength, 0, 100), Luminance = Math.Clamp(value.Luminance * strength, -100, 100) };
    private static bool Equivalent(ColorGradingWheel a, ColorGradingWheel b) =>
        a.Hue == b.Hue && (float)a.Saturation == (float)b.Saturation && (float)a.Luminance == (float)b.Luminance;
    private static bool Equivalent(ToneCurveSettings a, ToneCurveSettings b) =>
        a.ApplyToLuminosity == b.ApplyToLuminosity &&
        a.Parametric.SplitShadow == b.Parametric.SplitShadow &&
        a.Parametric.SplitMidtone == b.Parametric.SplitMidtone &&
        a.Parametric.SplitHighlight == b.Parametric.SplitHighlight &&
        Math.Abs(a.Parametric.Highlights - b.Parametric.Highlights) <= 1e-12 &&
        Math.Abs(a.Parametric.Lights - b.Parametric.Lights) <= 1e-12 &&
        Math.Abs(a.Parametric.Darks - b.Parametric.Darks) <= 1e-12 &&
        Math.Abs(a.Parametric.Shadows - b.Parametric.Shadows) <= 1e-12 &&
        Enum.GetValues<ToneCurveChannel>().All(channel => {
            var first = a.Shape(channel); var second = b.Shape(channel);
            return first.Mode == second.Mode && (first.IsIdentity && second.IsIdentity || first.Points.Count == second.Points.Count &&
                first.Points.Zip(second.Points).All(pair => Math.Abs(pair.First.X - pair.Second.X) <= 1e-12 && Math.Abs(pair.First.Y - pair.Second.Y) <= 1e-12));
        });
    private static AdjustmentTransferException Unrepresentable(F field) => new(AdjustmentFailure.Unrepresentable, field.ID());
}
