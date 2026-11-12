using RawLab.Windows;
using F = RawLab.Windows.AdjustmentField;
using static RawLab.Windows.AdjustmentPayload;

internal static class X3fModeResetChecks
{
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }

    internal static void Run()
    {
        foreach (var (distortion, tca, vignetting) in new[]
        {
            (true, false, false),
            (false, true, false),
            (false, false, true),
            (true, true, true),
        })
        {
            var settings = new Adjustments
            {
                X3fMode = X3fMode.Legacy,
                AIDenoiseEnabled = true,
                Lens = new LensSettings(
                    Distortion: distortion,
                    Tca: tca,
                    AutoCrop: false,
                    Manual: true,
                    ProfileId: "saved-lens-profile",
                    FocalLength: 35,
                    CropFactor: 1.5,
                    Vignetting: vignetting),
            };
            settings.Set(Parameter.Exposure, 0.25);

            settings.SelectX3fMode(X3fMode.Normal);
            Check(settings.X3fMode == X3fMode.Normal && !settings.AIDenoiseEnabled &&
                  !settings.Lens.Distortion && !settings.Lens.Tca &&
                  !settings.Lens.Vignetting && !settings.Lens.Enabled,
                "Normal X3F switch clears distortion, TCA, vignetting and AI denoise in one transaction");
            Check(!settings.Lens.AutoCrop && settings.Lens.Manual &&
                  settings.Lens.ProfileId == "saved-lens-profile" &&
                  settings.Lens.FocalLength == 35 &&
                  settings.Lens.CropFactor == 1.5 &&
                  settings[Parameter.Exposure] == 0.25,
                "Normal X3F switch preserves non-flag lens preferences and unrelated edits");

            var restored = settings.Capture().Restore();
            Check(restored.X3fMode == X3fMode.Normal && !restored.AIDenoiseEnabled &&
                  restored.Lens == settings.Lens,
                "Normal X3F reset state survives snapshot capture and restore");

            settings.SelectX3fMode(X3fMode.Legacy);
            Check(settings.X3fMode == X3fMode.Legacy && !settings.AIDenoiseEnabled &&
                  !settings.Lens.Distortion && !settings.Lens.Tca &&
                  !settings.Lens.Vignetting && !settings.Lens.Enabled,
                "Returning to legacy X3F does not re-enable lens correction or AI denoise");
        }

        var root = Path.Combine(Path.GetTempPath(), "rawlab-x3f-lens-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            var x3fPath = Path.Combine(root, "sigma.X3F");
            File.WriteAllText(x3fPath, "FOVbfixture");
            var mislabeledX3f = Path.Combine(root, "sigma.jpeg");
            File.WriteAllText(mislabeledX3f, "FOVbfixture");
            var identity = new OriginalIdentity(x3fPath, 1, 2, 3);

            var normalTarget = new Adjustments { Processing = ProcessingIdentity.Current, X3fMode = X3fMode.Normal };
            foreach (var targetPath in new[] { x3fPath, mislabeledX3f })
            {
                var normalContext = new AdjustmentTransferContext(targetPath, true,
                    ValidateLens: lens => _ = X3fModeReset.CreateLensProbe(targetPath, normalTarget, lens));
                foreach (var field in new[] { F.LensDistortion, F.LensTCA, F.LensVignetting })
                {
                    var payload = new AdjustmentPayload(new("source", true, 3),
                        new Dictionary<F, System.Text.Json.JsonElement> { [field] = Value(true) });
                    AdjustmentTransferException? thrown = null;
                    try
                    {
                        _ = AdjustmentTransfer.Prepare(payload, new SavedEdit(identity, normalTarget.Capture(), null), normalContext);
                    }
                    catch (AdjustmentTransferException error)
                    {
                        thrown = error;
                    }
                    Check(thrown is { Failure: AdjustmentFailure.Incompatible } &&
                          thrown.Detail.Contains("X3F", StringComparison.Ordinal) &&
                          thrown.Detail != "target lens calibration unavailable",
                        $"Normal X3F target explicitly rejects {field} without disguising as missing calibration");
                }

                var autoCropOnly = new AdjustmentPayload(new("source", true, 3),
                    new Dictionary<F, System.Text.Json.JsonElement> { [F.LensAutoCrop] = Value(false) });
                var accepted = AdjustmentTransfer.Prepare(autoCropOnly, new SavedEdit(identity, normalTarget.Capture(), null), normalContext);
                Check(!accepted.Settings.Restore().Lens.AutoCrop && !accepted.Settings.Restore().Lens.Enabled,
                    "Disabled lens preferences still transfer cleanly to normal X3F targets");
            }

            var legacyTarget = new Adjustments { Processing = ProcessingIdentity.Legacy, X3fMode = X3fMode.Legacy };
            Adjustments? observedProbe = null;
            var legacyContext = new AdjustmentTransferContext(x3fPath, true,
                ValidateLens: lens => observedProbe = X3fModeReset.CreateLensProbe(x3fPath, legacyTarget, lens));
            var vignettingPayload = new AdjustmentPayload(new("source", true, 3),
                new Dictionary<F, System.Text.Json.JsonElement> { [F.LensVignetting] = Value(true) });
            var appliedLegacy = AdjustmentTransfer.Prepare(vignettingPayload,
                new SavedEdit(identity, legacyTarget.Capture(), null), legacyContext);
            Check(observedProbe is { X3fMode: X3fMode.Legacy } &&
                  observedProbe.Processing == ProcessingIdentity.Legacy &&
                  observedProbe.Lens.Vignetting &&
                  appliedLegacy.Settings.Restore().Lens.Vignetting,
                "Legacy X3F target lens preflight probes with the target's actual Legacy X3F mode and processing");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }

        Console.WriteLine("PASS: X3F mode lens reset and Windows paste preflight");
    }
}
