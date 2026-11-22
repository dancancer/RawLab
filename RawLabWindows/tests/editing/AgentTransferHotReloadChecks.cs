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
    }

    private static void TransferJsonRoundTripChecks()
    {
        var adj = new Adjustments();
        adj.Set(Parameter.Exposure, 0.75);
        adj.Set(Parameter.Contrast, 16);
        adj.EditingToneControls = new ToneControlsSettings(BlackPoint: -0.15, WhitePoint: 0.1, Vibrance: 0.25);
        adj.EditingAtmosphere = new AtmosphereSettings(Clarity: 0.3, Dehaze: -0.2);
        adj.EditingCurve = new ToneCurveSettings(
            ToneCurveMode.Custom,
            [new(0, 0), new(0.25, 0.2), new(1, 1)],
            ApplyToLuminosity: true,
            Parametric: new ToneCurveParametric(Highlights: -10, Lights: 6, Darks: -4, Shadows: 12));
        adj.EditingGrading = new ColorGradingSettings(
            Shadows: new ColorGradingWheel(215, 25, -5),
            Midtones: new ColorGradingWheel(),
            Highlights: new ColorGradingWheel(40, 18, 4),
            Global: new ColorGradingWheel(180, 12, 2),
            Blending: 60,
            Balance: -15);

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
}
