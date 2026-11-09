using System.IO;
using System.Runtime.InteropServices;

namespace RawLab.Windows;

public sealed record ProcessingMigrationReceipt(
    OriginalIdentity Identity,
    SavedEdit Before,
    SavedEdit After,
    string Status)
{
    public const string Migrated = "migrated";
    public const string Kept = "kept";
    public const string RolledBack = "rolledBack";

    public bool IsKnownStatus => Status is Migrated or Kept or RolledBack;
    public bool IsValid
    {
        get
        {
            try
            {
                var before=Before.Settings.Restore();var after=After.Settings.Restore();
                if (before.Processing.Version is not (1 or 2)) return false;
                return Status switch {
                    Migrated or RolledBack => after.Processing == ProcessingIdentity.Current,
                    Kept => After.SameAs(Before), _ => false
                };
            }
            catch (InvalidDataException) { return false; }
        }
    }
    public ProcessingMigrationReceipt Copy() => this with { Before = Before.Copy(), After = After.Copy() };
}

internal static class ProcessingMigration
{
    internal static bool TryBuildCandidate(SavedEdit source, Native.ProcessingMigrationResult result,
        out SavedEdit? candidate)
    {
        candidate = null;
        var settings = source.Settings.Restore();
        if (!Eligible(settings) || settings.Processing.Version is not (1 or 2) ||
            result.Version != 1 || result.StructSize < (uint)Marshal.SizeOf<Native.ProcessingMigrationResult>() ||
            result.SourceVersion != settings.Processing.Version || result.TargetVersion != 3 ||
            result.Disposition != 1 || result.EvaluationCount == 0 || !Finite(result))
            return false;

        settings.Set(Parameter.Exposure, result.ExposureEv);
        settings.Set(Parameter.Contrast, (result.Contrast - 1) * 100);
        // The native migration result uses the core's reversed highlight sign.
        settings.Set(Parameter.Highlights, -result.Highlights * 100);
        settings.Set(Parameter.Shadows, result.Shadows * 100);
        settings.Set(Parameter.Saturation, (result.Saturation - 1) * 100);
        settings.SetTone(ToneControlParameter.BlackPoint, result.BlackPoint * 100);
        settings.SetTone(ToneControlParameter.WhitePoint, result.WhitePoint * 100);
        settings.SetTone(ToneControlParameter.Vibrance, result.Vibrance * 100);
        settings.SetAtmosphere(AtmosphereParameter.Clarity, result.Clarity * 100);
        settings.SetAtmosphere(AtmosphereParameter.Dehaze, result.Dehaze * 100);
        settings.Processing = ProcessingIdentity.Current;
        candidate = new SavedEdit(source.Identity, settings.Capture(), source.Look);
        return true;
    }

    internal static bool ShouldAttempt(SavedEdit current, ProcessingMigrationReceipt? receipt, int gpuMode = 0)
    {
        if (gpuMode == 2) return false;
        var settings = current.Settings.Restore();
        if (!Eligible(settings) || settings.Processing.Version is not (1 or 2)) return false;
        if (receipt?.Status == ProcessingMigrationReceipt.RolledBack) return false;
        return receipt == null || !receipt.Before.SameAs(current);
    }

    internal static bool IsRejectedResult(SavedEdit source, Native.ProcessingMigrationResult result)
    {
        var settings = source.Settings.Restore();
        return Eligible(settings) && settings.Processing.Version is (1 or 2) &&
            result.Version == 1 && result.StructSize >= (uint)Marshal.SizeOf<Native.ProcessingMigrationResult>() &&
            result.SourceVersion == settings.Processing.Version && result.TargetVersion == 3 && result.Disposition == 2;
    }

    private static bool Eligible(Adjustments settings) =>
        !settings.IsHDREditing && settings.HDR == null && !settings.ActiveAIDenoise && settings.MasterRecipeID == null;

    private static bool Finite(Native.ProcessingMigrationResult result) =>
        float.IsFinite(result.ExposureEv) && result.ExposureEv is >= -5 and <= 5 &&
        float.IsFinite(result.Contrast) && result.Contrast is >= 0 and <= 2 &&
        float.IsFinite(result.Highlights) && result.Highlights is >= -1 and <= 1 &&
        float.IsFinite(result.Shadows) && result.Shadows is >= -1 and <= 1 &&
        float.IsFinite(result.Saturation) && result.Saturation is >= 0 and <= 2 &&
        float.IsFinite(result.BlackPoint) && result.BlackPoint is >= -1 and <= 1 &&
        float.IsFinite(result.WhitePoint) && result.WhitePoint is >= -1 and <= 1 &&
        float.IsFinite(result.Vibrance) && result.Vibrance is >= -1 and <= 1 &&
        float.IsFinite(result.Clarity) && result.Clarity is >= -1 and <= 1 &&
        float.IsFinite(result.Dehaze) && result.Dehaze is >= -1 and <= 1 &&
        float.IsFinite(result.RgbRmse) && result.RgbRmse is >= 0 and <= 2f / 255 &&
        float.IsFinite(result.P99Error) && result.P99Error is >= 0 and <= 6f / 255 &&
        float.IsFinite(result.WorstTileRmse) && result.WorstTileRmse is >= 0 and <= 4f / 255 &&
        float.IsFinite(result.DetailRmse) && result.DetailRmse is >= 0 and <= 2f / 255;
}
