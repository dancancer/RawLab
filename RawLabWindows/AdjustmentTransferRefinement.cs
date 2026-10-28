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
        var selectedCurve = payload[F.Curve] is {} json ? ToneCurveSettings.Parse(json) : null;
        var expectedCurve = selectedCurve?.Scaled(sourceScale) ?? originalCurve.Scaled(previousScale);
        var curve = fullRecipe && selectedCurve != null ? selectedCurve : LogicalCurve(expectedCurve, originalCurve, targetScale);
        if (!Equivalent(curve.Scaled(targetScale), expectedCurve)) throw Unrepresentable(F.Curve);
        var grading = original.ColorGrading ?? new();
        foreach (var field in AdjustmentFields.RefinementObjects) {
            if (field.GradingZone() is not {} zone) continue;
            var current = grading[zone];
            var selected = payload[field] is {} wheel ? new ColorGradingWheel(wheel.GetProperty("hue").GetDouble(), wheel.GetProperty("saturation").GetDouble()) : null;
            var desired = selected == null ? Scaled(current, previousScale) : Scaled(selected, sourceScale);
            ColorGradingWheel logical;
            if (fullRecipe && selected != null) logical = selected;
            else if (Equivalent(Scaled(current, targetScale), desired)) logical = current;
            else {
                if (targetScale == 0 && desired.Saturation != 0) throw Unrepresentable(field);
                logical = new(desired.Hue, targetScale == 0 ? 0 : desired.Saturation / targetScale);
            }
            if (!logical.IsValid || !Equivalent(Scaled(logical, targetScale), desired)) throw Unrepresentable(field);
            grading = grading.With(zone, logical);
        }
        return target with { Curve = curve.IsDefault ? null : curve, ColorGrading = grading.IsDefault ? null : grading };
    }

    private static ToneCurveSettings LogicalCurve(ToneCurveSettings desired, ToneCurveSettings current, double strength)
    {
        if (Equivalent(current.Scaled(strength), desired)) return current;
        if (desired.Mode == ToneCurveMode.Legacy || strength == 0 && desired.IsIdentity) return desired;
        if (strength == 0) throw Unrepresentable(F.Curve);
        return new(ToneCurveMode.Custom, desired.Points.Select(p => new ToneCurvePoint(p.X, p.X + (p.Y - p.X) / strength)));
    }

    private static ColorGradingWheel Scaled(ColorGradingWheel value, double strength) =>
        value with { Saturation = Math.Clamp(value.Saturation * strength, 0, 100) };
    private static bool Equivalent(ColorGradingWheel a, ColorGradingWheel b) => a.Hue == b.Hue && (float)a.Saturation == (float)b.Saturation;
    private static bool Equivalent(ToneCurveSettings a, ToneCurveSettings b) => a.Mode == b.Mode &&
        (a.IsIdentity && b.IsIdentity || a.Points.Count == b.Points.Count && a.Points.Zip(b.Points)
            .All(pair => pair.First.X == pair.Second.X && Math.Abs(pair.First.Y - pair.Second.Y) <= 1e-12));
    private static AdjustmentTransferException Unrepresentable(F field) => new(AdjustmentFailure.Unrepresentable, field.ID());
}
