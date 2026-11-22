namespace RawLab.Windows;

internal static class ToneCurveSampling
{
    internal static IReadOnlyList<ToneCurvePoint> Samples(ToneCurveSettings curve,
        ToneCurveChannel channel = ToneCurveChannel.Rgb, bool? includeParametric = null, int count = 257)
    {
        if (count is < 2 or > 4097) throw new ArgumentOutOfRangeException(nameof(count));
        var useParametric = includeParametric ?? (channel == ToneCurveChannel.Rgb);
        var shape = curve.Shape(channel);
        var evalShape = shape.Mode == ToneCurveMode.Custom ? shape : ToneCurveShape.Identity;
        var config = evalShape.NativeConfig();
        var x = Enumerable.Range(0, count).Select(i => (double)i / (count - 1)).ToArray();
        var y = new double[count];
        if (useParametric) {
            var param = curve.Parametric.NativeConfig();
            Native.CheckWithoutSession(Native.sony2fuji_sample_tone_curve_v2(ref config, ref param, x, y, (uint)count));
        } else {
            Native.CheckWithoutSession(Native.SampleToneCurveV2WithoutParametric(ref config, IntPtr.Zero, x, y, (uint)count));
        }
        return x.Zip(y, (input, output) => new ToneCurvePoint(input, output)).ToArray();
    }

    internal static double SampleParametricValue(ToneCurveSettings curve, double x)
    {
        if (!double.IsFinite(x)) return x;
        var config = ToneCurveShape.Identity.NativeConfig();
        var param = curve.Parametric.NativeConfig();
        double[] xs = [x], ys = [x];
        Native.CheckWithoutSession(Native.sony2fuji_sample_tone_curve_v2(ref config, ref param, xs, ys, 1));
        return ys[0];
    }
}
