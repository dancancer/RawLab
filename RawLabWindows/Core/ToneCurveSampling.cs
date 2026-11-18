namespace RawLab.Windows;

internal static class ToneCurveSampling
{
    internal static IReadOnlyList<ToneCurvePoint> Samples(ToneCurveSettings curve, int count = 257)
    {
        if (curve.Mode != ToneCurveMode.Custom || count is < 2 or > 4097) throw new ArgumentOutOfRangeException(nameof(count));
        var config = curve.NativeConfig();
        var x = Enumerable.Range(0, count).Select(i => (double)i / (count - 1)).ToArray();
        var y = new double[count];
        Native.Check(Native.sony2fuji_sample_tone_curve(ref config, x, y, (uint)count));
        return x.Zip(y, (input, output) => new ToneCurvePoint(input, output)).ToArray();
    }
}
