using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using RawLab.Windows;
using Xunit;

namespace RawLab.Windows.Tests;

public sealed class AgentTransferHotReloadChecks
{
    private static void Check(bool condition, string message) => Assert.True(condition, message);

    [Fact]
    [Trait("Category", "Model")]
    [Trait("Suite", "editing")]
    public void TransferJsonSerializationAndExternalReloadStateWork()
    {
        TransferJsonRoundTripChecks();
        StoreSelfWriteStampChecks();
        AdoptExternalReloadUndoRedoChecks();
        ExternalReloadBannerStateChecks();
        ExternalStoreWatcherChecks();
        CliSchemaEditsAndPresetsDecodeChecks();
        FileShareNoneContentionChecks();
        ExternalStoreWatcherErrorRecoveryChecks();
        AsShotHydrationCalibrationChecks();
    }

    private static void TransferJsonRoundTripChecks()
    {
        var adj = new Adjustments();
        adj.Set(Parameter.Exposure, 0.75);
        adj.Set(Parameter.Contrast, 1.16);
        adj.ToneControls = new ToneControlsSettings(BlackPoint: -0.15, WhitePoint: 0.1, Vibrance: 0.25);
        adj.Atmosphere = new AtmosphereSettings(Clarity: 0.3, Dehaze: -0.2);
        adj.EditingCurve = new ToneCurveSettings(
            ToneCurveMode.Custom,
            [new(0, 0), new(0.25, 0.2), new(1, 1)],
            applyToLuminosity: true,
            parametric: new ToneCurveParametric(Highlights: -10, Lights: 6, Darks: -4, Shadows: 12));
        adj.EditingGrading = new ColorGradingSettings
        {
            Shadows = new ColorGradingWheel(215, 25, -5),
            Midtones = new ColorGradingWheel(),
            Highlights = new ColorGradingWheel(40, 18, 4),
            Global = new ColorGradingWheel(180, 12, 2),
            Blending = 60,
            Balance = -15
        };

        var identity = new OriginalIdentity("C:\\photos\\fixture.dng", 100, 200, 300);
        var saved = new SavedEdit(identity, adj.Capture(), null);
        var context = new AdjustmentTransferContext(identity.Path, IsRaw: true, AvailableLookIDs: new HashSet<string>());
        var payload = AdjustmentTransfer.Capture(AdjustmentScope.Custom(AdjustmentFields.All), saved, context);

        var indentedJson = payload.ToIndentedJson();
        Check(indentedJson.Contains('\n', StringComparison.Ordinal), "ToIndentedJson emits formatted JSON");
        var parsed = AdjustmentPayload.Parse(indentedJson);
        Check(parsed.PayloadVersion == payload.PayloadVersion, "Round-trip preserves payload_version");
        Check(AdjustmentPayload.Boolean(parsed[AdjustmentField.CurveApplyToLuminosity]) == true, "Round-trip preserves apply_to_luminosity");
        Check(AdjustmentPayload.Number(parsed[AdjustmentField.GradingBlending]) == 60, "Round-trip preserves grading blending");
        Check(AdjustmentPayload.Number(parsed[AdjustmentField.GradingBalance]) == -15, "Round-trip preserves grading balance");
    }

    private static void StoreSelfWriteStampChecks()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-win-stamp-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var photo = Path.Combine(root, "photo.png");
            File.WriteAllBytes(photo, [1, 2, 3, 4]);
            var identity = OriginalIdentity.Read(photo);

            var editsDir = Path.Combine(root, "Edits");
            var storeA = new EditStore(editsDir);
            var storeB = new EditStore(editsDir);
            var adjA = new Adjustments { ExposureMode = 2 };
            adjA.Set(Parameter.Exposure, 0.5);
            storeA.SaveState(identity, new SavedEdit(identity, adjA.Capture(), null));
            var editsStampA = PathStatStamp.Capture(storeA.RegistryPath);
            Check(storeA.LastWriteStamp == editsStampA, "EditStore records LastWriteStamp matching disk stamp after self-write");

            var adjB = new Adjustments { ExposureMode = 2 };
            adjB.Set(Parameter.Exposure, 1.1);
            storeB.SaveState(identity, new SavedEdit(identity, adjB.Capture(), null));
            var editsStampB = PathStatStamp.Capture(storeA.RegistryPath);
            Check(storeA.LastWriteStamp != editsStampB, "External write changes disk stamp away from storeA.LastWriteStamp");

            var presetsDir = Path.Combine(root, "Presets");
            var presetStoreA = new AdjustmentPresetStore(presetsDir);
            var presetStoreB = new AdjustmentPresetStore(presetsDir);
            var ctx = new AdjustmentTransferContext(photo, IsRaw: false, AvailableLookIDs: new HashSet<string>());
            var payload = AdjustmentTransfer.Capture(AdjustmentScope.Custom([AdjustmentField.Exposure]),
                new SavedEdit(identity, adjA.Capture(), null), ctx);
            presetStoreA.Create("Preset A", payload);
            var presetStampA = PathStatStamp.Capture(presetStoreA.RegistryPath);
            Check(presetStoreA.LastWriteStamp == presetStampA, "AdjustmentPresetStore records LastWriteStamp after write");

            presetStoreB.Create("Preset B", payload);
            var presetStampB = PathStatStamp.Capture(presetStoreA.RegistryPath);
            Check(presetStoreA.LastWriteStamp != presetStampB, "External preset write changes disk stamp");
        }
        finally
        {
            try { Directory.Delete(root, recursive: true); } catch { }
        }
    }

    private static void AdoptExternalReloadUndoRedoChecks()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-win-reload-undo-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var photo = Path.Combine(root, "photo.png");
            File.WriteAllBytes(photo, [9, 8, 7, 6]);
            var identity = OriginalIdentity.Read(photo);
            var editsDir = Path.Combine(root, "Edits");
            var store = new EditStore(editsDir);
            var externalStore = new EditStore(editsDir);
            var session = new AdjustmentTransferSession(store);

            var initialAdj = new Adjustments { ExposureMode = 2 };
            initialAdj.Set(Parameter.Exposure, 0.25);
            var expected = store.SaveState(identity, new SavedEdit(identity, initialAdj.Capture(), null));

            var unchanged = session.AdoptExternalReload(expected, expected);
            Check(unchanged.Status == AdjustmentStatus.Unchanged && session.Transactions.Count == 0,
                "Unchanged external state does not add history transaction");

            var extAdj = new Adjustments { ExposureMode = 2 };
            extAdj.Set(Parameter.Exposure, 1.35);
            var reloaded = externalStore.SaveState(identity, new SavedEdit(identity, extAdj.Capture(), null));

            var applied = session.AdoptExternalReload(expected, reloaded);
            Check(applied.Status == AdjustmentStatus.Applied && session.Transactions.Count == 1,
                "AdoptExternalReload records 1 undoable transaction");
            Check(session.PhotoHistoryID(photo, undo: true) != null, "Can undo external reload in 1 step");

            var undone = session.UndoPhoto(photo);
            Check(undone.Single().Status == AdjustmentStatus.Applied &&
                  Math.Abs(undone.Single().Saved!.Edit!.Settings.Values[(int)Parameter.Exposure] - 0.25) < 1e-6,
                "Undo reverts external reload in 1 step");
        }
        finally
        {
            try { Directory.Delete(root, recursive: true); } catch { }
        }
    }

    private static void ExternalReloadBannerStateChecks()
    {
        var identity = new OriginalIdentity("C:\\photos\\test.png", 10, 20, 30);
        var baseAdj = new Adjustments { ExposureMode = 2 };
        var committed = new PhotoEditState(identity, new SavedEdit(identity, baseAdj.Capture(), null));
        var extAdj = new Adjustments { ExposureMode = 2 };
        extAdj.Set(Parameter.Exposure, 1.2);
        var disk = new PhotoEditState(identity, new SavedEdit(identity, extAdj.Capture(), null));

        var state = ExternalReloadBannerState.Empty;
        var cleanEval = state.Evaluate(committed, committed.Edit, disk, stamp: null, hasUnsavedManualDraft: false);
        Check(cleanEval.Decision == ExternalReloadDecision.AutoReload && !cleanEval.NextState.Visible,
            "Clean state auto-reloads without banner");

        var draftAdj = new Adjustments { ExposureMode = 2 };
        draftAdj.Set(Parameter.Exposure, -0.7);
        var draftUi = new SavedEdit(identity, draftAdj.Capture(), null);
        var stamp1 = new PathStatStamp(true, "C:\\edits.json", "C:\\edits.json", null, 120, 1000, 1000);
        var dirtyEval = state.Evaluate(committed, draftUi, disk, stamp1, hasUnsavedManualDraft: true);
        Check(dirtyEval.Decision == ExternalReloadDecision.ShowBanner && dirtyEval.NextState.Visible &&
              dirtyEval.NextState.PendingRecord!.SameAs(disk),
            "Unsaved manual draft shows non-blocking banner instead of overwriting draft");

        var kept = dirtyEval.NextState.KeepManualDraft();
        Check(!kept.Visible && kept.PendingRecord == null, "KeepManualDraft hides banner");

        var repeatSameStamp = kept.Evaluate(committed, draftUi, disk, stamp1, hasUnsavedManualDraft: true);
        Check(repeatSameStamp.Decision == ExternalReloadDecision.None && !repeatSameStamp.NextState.Visible,
            "Dismissed stamp is not re-surfaced until file changes again");

        var stamp2 = new PathStatStamp(true, "C:\\edits.json", "C:\\edits.json", null, 140, 2000, 1000);
        var nextExternal = kept.Evaluate(committed, draftUi, disk, stamp2, hasUnsavedManualDraft: true);
        Check(nextExternal.Decision == ExternalReloadDecision.ShowBanner && nextExternal.NextState.Visible,
            "New external update re-surfaces banner");

        var accepted = nextExternal.NextState.AcceptReload();
        Check(!accepted.Visible && accepted.PendingRecord == null, "AcceptReload clears banner");

        // In-flight async save guard: Evaluate must never AutoReload while async save is in flight,
        // and TryAcceptReload must block ReloadExternalUpdate until async save completes.
        var asyncBlocked = state.Evaluate(committed, committed.Edit, disk, stamp2,
            hasUnsavedManualDraft: false, hasPendingAsyncSave: true);
        Check(asyncBlocked.Decision == ExternalReloadDecision.None && !asyncBlocked.NextState.Visible,
            "Evaluate blocks AutoReload while an async save is in flight");
        Check(!nextExternal.NextState.TryAcceptReload(hasPendingAsyncSave: true, out var blockedDisk) &&
              blockedDisk == null && nextExternal.NextState.Visible &&
              nextExternal.NextState.PendingRecord != null,
            "TryAcceptReload blocks external reload acceptance while an async save is in flight");
        Check(nextExternal.NextState.TryAcceptReload(hasPendingAsyncSave: false, out var readyDisk) &&
              readyDisk != null && readyDisk.SameAs(disk),
            "TryAcceptReload yields pending record once in-flight async save drains");

        // Cancelling an un-dirtied tool draft (e.g., crop -> Keep Manual Draft -> Esc) or pending text input
        // transitions HasUnsavedManualDraft from true -> false; re-evaluating external disk state must AutoReload
        // even though the same stamp was previously dismissed while the draft was active.
        var undirtiedDraftEval = state.Evaluate(committed, committed.Edit, disk, stamp1, hasUnsavedManualDraft: true);
        Check(undirtiedDraftEval.Decision == ExternalReloadDecision.ShowBanner,
            "Un-dirtied active tool or pending parameter input shows external reload banner");
        var dismissedDuringDraft = undirtiedDraftEval.NextState.KeepManualDraft();
        var afterCancelDraft = dismissedDuringDraft.Evaluate(committed, committed.Edit, disk, stamp1, hasUnsavedManualDraft: false);
        Check(afterCancelDraft.Decision == ExternalReloadDecision.AutoReload && !afterCancelDraft.NextState.Visible,
            "Cancelling un-dirtied draft re-evaluates external state and auto-reloads dismissed stamp");
    }

    private static void ExternalStoreWatcherChecks()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-win-watch-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var editsFile = Path.Combine(root, "Edits", "edits.json");
            var presetsFile = Path.Combine(root, "Presets", "presets.json");
            var notifications = new List<string>();
            using var signal = new ManualResetEventSlim(false);

            using var watcher = new ExternalStoreWatcher([editsFile, presetsFile], path =>
            {
                lock (notifications) notifications.Add(path);
                signal.Set();
            }, debounceMs: 25);

            Directory.CreateDirectory(Path.GetDirectoryName(editsFile)!);
            var tmp = editsFile + ".tmp";
            File.WriteAllText(tmp, "{\"Records\":{},\"Version\":1}");
            File.Move(tmp, editsFile, overwrite: true);

            Check(signal.Wait(TimeSpan.FromSeconds(4)), "ExternalStoreWatcher detects file creation from missing directory");
        }
        finally
        {
            try { Directory.Delete(root, recursive: true); } catch { }
        }
    }

    private static void CliSchemaEditsAndPresetsDecodeChecks()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-win-cli-schema-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var photo = Path.Combine(root, "IMG_0100.ARW");
            File.WriteAllBytes(photo, [1, 2, 3, 4, 5, 6]);
            var identity = OriginalIdentity.Read(photo);
            var lowerPath = identity.Path.ToLowerInvariant();

            var editsDir = Path.Combine(root, "Edits");
            Directory.CreateDirectory(editsDir);
            // Match exact sony2fuji Windows codec output (OrdinalIgnoreCase key, SettingsVersion=2, Values[10],
            // PascalCase Denoise/Effects/Hsl/Lens/Geometry/ToneControls/Atmosphere/ColorGrading, lowercase Curve/Processing).
            var hslValues = string.Join(",", Enumerable.Range(0, 24).Select(i => i == 0 ? "12" : i == 8 ? "-5" : "0"));
            var escapedLowerPath = System.Text.Json.JsonSerializer.Serialize(lowerPath);
            var escapedFileId = System.Text.Json.JsonSerializer.Serialize(identity.FileID);
            var editsJson = $$"""
            {
              "CustomTier1": true,
              "Records": {
                {{escapedLowerPath}}: {
                  "Identity": {
                    "Path": {{escapedLowerPath}},
                    "Length": {{identity.Length}},
                    "Modified": {{identity.Modified}},
                    "Created": {{identity.Created}},
                    "FileID": {{escapedFileId}}
                  },
                  "Look": "builtin:classic_chrome",
                  "Settings": {
                    "SettingsVersion": 2,
                    "Values": [0.85, 0.75, 5800, 12, 1.25, -0.35, 0.4, 0.0, 1.15, 0.5],
                    "ExposureMode": 0,
                    "CameraWhiteBalance": false,
                    "AsShotTemperature": null,
                    "AsShotTint": null,
                    "Processing": {"family": "rawlab", "version": 3, "quality": "standard"},
                    "X3fMode": "normal-v1",
                    "AIDenoiseEnabled": false,
                    "DisplayChromaDenoise": 1,
                    "Denoise": {"Enabled": true, "Luma": 12, "Chroma": 50, "Coarse": 40},
                    "Effects": {"VignetteAmount": -15, "VignetteMidpoint": 50, "VignetteRoundness": 0, "VignetteFeather": 50, "VignetteHighlights": 0, "GrainAmount": 10, "GrainSize": 25, "GrainRoughness": 50},
                    "Hsl": {"Values": [{{hslValues}}]},
                    "MasterRecipeID": null,
                    "MasterRecipeSettingsVersion": 3,
                    "Lens": {"Distortion": true, "Tca": true, "AutoCrop": true, "Manual": false, "ProfileId": null, "FocalLength": null, "CropFactor": null, "Vignetting": false},
                    "Geometry": {"CropX": 0.1, "CropY": 0.0, "CropWidth": 0.9, "CropHeight": 1.0, "QuarterTurns": 1, "FlipHorizontal": false, "FlipVertical": true, "StraightenDegrees": 1.5, "PerspectiveHorizontal": -0.2, "PerspectiveVertical": 0.1},
                    "ToneControls": {"BlackPoint": -10, "WhitePoint": 12, "Vibrance": 18},
                    "Atmosphere": {"Clarity": 20, "Dehaze": -5},
                    "ColorGrading": {
                      "Shadows": {"Hue": 210, "Saturation": 15},
                      "Midtones": {"Hue": 0, "Saturation": 0},
                      "Highlights": {"Hue": 40, "Saturation": 12, "Luminance": 5},
                      "Blending": 65
                    },
                    "Curve": {
                      "mode": "custom",
                      "points": [[0, 0], [0.5, 0.58], [1, 1]],
                      "apply_to_luminosity": true
                    }
                  }
                }
              },
              "Version": 1
            }
            """;
            File.WriteAllText(Path.Combine(editsDir, "edits.json"), editsJson);

            var store = new EditStore(editsDir);
            var read = store.ReadState(photo);
            Check(read.Edit != null, "EditStore decodes CLI-written Windows edits.json via OrdinalIgnoreCase");
            Check(read.Edit!.Look == "builtin:classic_chrome", "EditStore preserves CLI Look field");
            var restored = read.Edit.Settings.Restore();
            Check(Math.Abs(restored[Parameter.Exposure] - 0.75) < 1e-6, "CLI exposure decoded");
            Check(Math.Abs(restored[Parameter.Contrast] - 1.25) < 1e-6, "CLI contrast decoded");
            Check(Math.Abs(restored[Parameter.Highlights] - (-0.35)) < 1e-6, "CLI highlights decoded");
            Check(restored.ExposureMode == 0 && !restored.CameraWhiteBalance, "CLI exposureMode and WB flags decoded");
            Check(restored.ToneControls.BlackPoint == -10 && restored.Atmosphere.Clarity == 20, "CLI ToneControls and Atmosphere decoded");
            Check(restored.Curve.ApplyToLuminosity && restored.ColorGrading.Highlights.Luminance == 5, "CLI Curve and ColorGrading decoded");
            Check(restored.Hsl.Value(0, 0) == 12 && restored.Hsl.Value(1, 0) == -5, "CLI Hsl decoded");
            Check(restored.Denoise.Enabled && restored.Denoise.Luma == 12, "CLI Denoise decoded");
            Check(restored.Geometry.QuarterTurns == 1 && restored.Geometry.FlipVertical, "CLI Geometry decoded");

            var presetsDir = Path.Combine(root, "Presets");
            Directory.CreateDirectory(presetsDir);
            var futureSlice = "{\"id\":\"99999999-9999-4999-8999-999999999999\",\"name\":\"Future\",\"future\":true}";
            var presetsJson = $$"""
            {
              "presets": [
                {
                  "id": "11111111-1111-4111-8111-111111111111",
                  "name": "CLI SDR Preset",
                  "created_at": 1700000000000,
                  "updated_at": 1700000000000,
                  "payload": {
                    "payload_version": 1,
                    "scope_version": 1,
                    "source": {"identifier": "preset:11111111-1111-4111-8111-111111111111", "is_raw": true, "processing_version": 3, "recipe": null},
                    "values": {"light.exposure": 0.5, "light.curve.apply_to_luminosity": true}
                  }
                },
                {{futureSlice}}
              ],
              "registry_version": 1,
              "retired_ids": ["22222222-2222-4222-8222-222222222222"]
            }
            """;
            File.WriteAllText(Path.Combine(presetsDir, "presets.json"), presetsJson);

            var presetStore = new AdjustmentPresetStore(presetsDir);
            var (presets, unreadable) = presetStore.LoadSnapshot();
            Check(presets.Count == 1 && presets[0].Name == "CLI SDR Preset", "AdjustmentPresetStore decodes CLI presets.json");
            Check(unreadable.Count == 1 && unreadable[0].Json == futureSlice, "AdjustmentPresetStore isolates future preset");
        }
        finally
        {
            try { Directory.Delete(root, recursive: true); } catch { }
        }
    }

    private static void FileShareNoneContentionChecks()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-win-lock-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var photo = Path.Combine(root, "photo.png");
            File.WriteAllBytes(photo, [1, 2, 3, 4]);
            var identity = OriginalIdentity.Read(photo);

            var editsDir = Path.Combine(root, "Edits");
            Directory.CreateDirectory(editsDir);
            var lockPath = Path.Combine(editsDir, "edits.json.lock");
            var store = new EditStore(editsDir);

            using var acquired = new ManualResetEventSlim(false);
            var holder = new System.Threading.Thread(() =>
            {
                using var fs = new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
                acquired.Set();
                System.Threading.Thread.Sleep(120);
            });
            holder.Start();
            Check(acquired.Wait(TimeSpan.FromSeconds(2)), "Contention test lock holder acquired edits.json.lock");

            var adj = new Adjustments { ExposureMode = 2 };
            adj.Set(Parameter.Exposure, 0.9);
            var saved = store.SaveState(identity, new SavedEdit(identity, adj.Capture(), null));
            holder.Join();
            Check(Math.Abs(saved.Edit!.Settings.Values[(int)Parameter.Exposure] - 0.9) < 1e-6,
                "EditStore retries and succeeds after FileShare.None lock release");
        }
        finally
        {
            try { Directory.Delete(root, recursive: true); } catch { }
        }
    }

    private static void ExternalStoreWatcherErrorRecoveryChecks()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-win-watch-err-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var editsDir = Path.Combine(root, "Edits");
            Directory.CreateDirectory(editsDir);
            var editsFile = Path.Combine(editsDir, "edits.json");
            File.WriteAllText(editsFile, "{\"Records\":{},\"Version\":1}");

            using var recoveredSignal = new ManualResetEventSlim(false);
            using var watcher = new ExternalStoreWatcher([editsFile], _ => recoveredSignal.Set(), debounceMs: 25);

            // Simulate FileSystemWatcher.Error -> must recreate watcher and trigger ScheduleCheck(null)
            watcher.SimulateErrorForTests();
            Check(recoveredSignal.Wait(TimeSpan.FromSeconds(4)), "ExternalStoreWatcher recovers and emits check after Error event");

            recoveredSignal.Reset();
            var tmp = editsFile + ".tmp";
            File.WriteAllText(tmp, "{\"Records\":{},\"Version\":1,\"Tag\":2}");
            File.Move(tmp, editsFile, overwrite: true);
            Check(recoveredSignal.Wait(TimeSpan.FromSeconds(4)), "ExternalStoreWatcher still observes subsequent writes after Error recovery");
        }
        finally
        {
            try { Directory.Delete(root, recursive: true); } catch { }
        }
    }

    private static void AsShotHydrationCalibrationChecks()
    {
        var identity = new OriginalIdentity("C:\\photos\\IMG_0200.ARW", 100, 200, 300);
        var calibration = (Temperature: 5200.0, Tint: 8.0);

        // 1. CLI-synced RAW record (AsShotTemperature=null, AsShotTint=null, CameraWhiteBalance=true)
        var cliAdj = new Adjustments { ExposureMode = 0 };
        var diskSnap = cliAdj.Capture();
        Check(diskSnap.CameraWhiteBalance && diskSnap.AsShotTemperature == null && diskSnap.AsShotTint == null,
            "CLI-style RAW snapshot starts with CameraWhiteBalance=true and null AsShot calibration");
        var diskRecord = new PhotoEditState(identity, new SavedEdit(identity, diskSnap, null));

        var hydratedAdj = diskSnap.Restore();
        hydratedAdj.ResolveWhiteBalance(calibration);
        var hydratedSnap = hydratedAdj.Capture();
        var hydratedUi = new SavedEdit(identity, hydratedSnap, null);

        // CacheCurrentPhotoPreview check: normalized disk snapshot matches hydrated hslAcceptedSettings
        Check(diskSnap.WithAsShotCalibration(calibration).SameAs(hydratedSnap),
            "WithAsShotCalibration normalizes null-AsShot CLI snapshot to match hydrated render snapshot");

        // Evaluate check: unrelated edits.json change must yield None (no spurious AutoReload)
        var state = ExternalReloadBannerState.Empty;
        var unchangedEval = state.Evaluate(
            diskRecord,
            hydratedUi,
            diskRecord,
            stamp: null,
            hasUnsavedManualDraft: false,
            asShotCalibration: calibration);
        Check(unchangedEval.Decision == ExternalReloadDecision.None && !unchangedEval.NextState.Visible,
            "AsShot-only hydration mismatch does not trigger spurious AutoReload");

        // 2. Real external edit on CLI-synced RAW record (still null AsShot) must still AutoReload / ShowBanner
        var updatedCliAdj = new Adjustments { ExposureMode = 0 };
        updatedCliAdj.Set(Parameter.Exposure, 0.45);
        updatedCliAdj.Set(Parameter.Temperature, 5800);
        updatedCliAdj.Set(Parameter.Tint, 12);
        Check(!updatedCliAdj.CameraWhiteBalance, "Setting custom Temperature/Tint clears CameraWhiteBalance");
        var updatedDisk = new PhotoEditState(identity, new SavedEdit(identity, updatedCliAdj.Capture(), null));

        var reloadEval = state.Evaluate(
            diskRecord,
            hydratedUi,
            updatedDisk,
            stamp: null,
            hasUnsavedManualDraft: false,
            asShotCalibration: calibration);
        Check(reloadEval.Decision == ExternalReloadDecision.AutoReload,
            "Real external update on CLI-synced RAW record still triggers AutoReload");

        var bannerEval = state.Evaluate(
            diskRecord,
            hydratedUi,
            updatedDisk,
            stamp: null,
            hasUnsavedManualDraft: true,
            asShotCalibration: calibration);
        Check(bannerEval.Decision == ExternalReloadDecision.ShowBanner &&
              bannerEval.NextState.PendingRecord!.SameAs(updatedDisk),
            "Banner PendingRecord preserves original unhydrated disk record when manual draft is active");
    }
}
