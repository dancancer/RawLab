using System.Text.Json;

namespace RawLab.Windows;

internal static class ProcessingMigrationChecks
{
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }

    internal static void Run()
    {
        CandidateMappingPreservesUnrelatedState();
        RejectedAndInvalidResultsDoNotProduceCandidates();
        AtomicMigrationAndCas();
        RestartRollbackSuppressesAutomaticRetry();
        KeptReceiptRetriesOnlyAfterSettingsChange();
        ForceDoesNotStartAutomaticMigration();
        MigrationHistoryIsolation();
        Console.WriteLine("PASS: processing migration mapping, rejection, CAS, rollback and retry policy");
    }

    private static void ForceDoesNotStartAutomaticMigration()
    {
        var before = Source(new OriginalIdentity("force.ARW", 1, 2, 3));
        Check(ProcessingMigration.ShouldAttempt(before, null, gpuMode: 0), "CPU permits automatic migration");
        Check(ProcessingMigration.ShouldAttempt(before, null, gpuMode: 1), "Auto permits automatic migration");
        Check(!ProcessingMigration.ShouldAttempt(before, null, gpuMode: 2), "Force skips automatic migration before starting a worker");
    }

    private static SavedEdit Source(OriginalIdentity identity)
    {
        var settings = new Adjustments { Processing = ProcessingIdentity.C5 };
        settings.Set(Parameter.Exposure, .7);
        settings.Set(Parameter.Contrast, 18);
        settings.Set(Parameter.Highlights, -22);
        settings.Set(Parameter.Shadows, 31);
        settings.Set(Parameter.Saturation, 13);
        settings.SetTone(ToneControlParameter.BlackPoint, -12);
        settings.SetTone(ToneControlParameter.WhitePoint, 17);
        settings.SetTone(ToneControlParameter.Vibrance, 9);
        settings.SetAtmosphere(AtmosphereParameter.Clarity, 24);
        settings.SetAtmosphere(AtmosphereParameter.Dehaze, -11);
        settings.Denoise = DenoiseSettings.Clean;
        settings.DisplayChromaDenoise = 2;
        settings.Geometry = new(StraightenDegrees: 4);
        settings.Lens = new(true, true, true, false, "camera-profile");
        return new(identity, settings.Capture(), "film.cube");
    }

    private static Native.ProcessingMigrationResult Result(int source = 2, int disposition = 1) => new() {
        Version = 1, StructSize = 80, SourceVersion = source, TargetVersion = 3,
        Disposition = disposition, EvaluationCount = 8,
        ExposureEv = 1.25f, Contrast = 1.18f, Highlights = -.23f, Shadows = .31f,
        Saturation = 1.13f, BlackPoint = -.12f, WhitePoint = .17f, Vibrance = .09f,
        Clarity = .24f, Dehaze = -.11f, RgbRmse = .002f, P99Error = .01f,
        WorstTileRmse = .004f, DetailRmse = .003f
    };

    private static void CandidateMappingPreservesUnrelatedState()
    {
        var identity = new OriginalIdentity("mapping.ARW", 1, 2, 3);
        var before = Source(identity);
        Check(ProcessingMigration.TryBuildCandidate(before, Result(), out var candidate),
            "accepted native result creates a candidate");
        Check(candidate!.Settings.Processing == ProcessingIdentity.Current,
            "candidate upgrades only the processing identity");
        var settings = candidate.Settings.Restore();
        Check(Math.Abs(settings[Parameter.Exposure] - 1.25) < 1e-4 && Math.Abs(settings[Parameter.Contrast] - 18) < 1e-4 &&
              Math.Abs(settings[Parameter.Highlights] - 23) < 1e-4 && Math.Abs(settings[Parameter.Shadows] - 31) < 1e-4 &&
              Math.Abs(settings[Parameter.Saturation] - 13) < 1e-4,
            "canonical core exposure, contrast, saturation and reversed highlights map to UI values");
        Check(Math.Abs(settings.EditingToneValue(ToneControlParameter.BlackPoint) + 12) < 1e-6 &&
              Math.Abs(settings.EditingToneValue(ToneControlParameter.WhitePoint) - 17) < 1e-6 &&
              Math.Abs(settings.EditingToneValue(ToneControlParameter.Vibrance) - 9) < 1e-6 &&
              Math.Abs(settings.EditingAtmosphereValue(AtmosphereParameter.Clarity) - 24) < 1e-6 &&
              Math.Abs(settings.EditingAtmosphereValue(AtmosphereParameter.Dehaze) + 11) < 1e-6,
            "canonical tone and atmosphere values map to UI percentages");
        Check(settings.Denoise == before.Settings.Denoise && settings.DisplayChromaDenoise == 2 &&
              settings.Geometry == before.Settings.Geometry && settings.Lens == before.Settings.Lens &&
              candidate.Look == before.Look,
            "non-migrated settings and LUT survive the candidate conversion");
    }

    private static void RejectedAndInvalidResultsDoNotProduceCandidates()
    {
        var identity = new OriginalIdentity("rejected.ARW", 1, 2, 3);
        var before = Source(identity);
        Check(!ProcessingMigration.TryBuildCandidate(before, Result(disposition: 2), out _),
            "native REJECTED does not produce a candidate");
        Check(!ProcessingMigration.TryBuildCandidate(before, Result(source: 1) with { TargetVersion = 2 }, out _),
            "wrong target version does not produce a candidate");
        Check(!ProcessingMigration.TryBuildCandidate(before, Result() with { RgbRmse = float.NaN }, out _),
            "non-finite validation metrics do not produce a candidate");
        Check(!ProcessingMigration.TryBuildCandidate(before, Result() with { P99Error = 7f / 255 }, out _),
            "over-threshold validation metrics do not produce a candidate");
        var v3 = before with { Settings = before.Settings with { Processing = ProcessingIdentity.Current } };
        Check(!ProcessingMigration.TryBuildCandidate(v3, Result(), out _),
            "a non-legacy source cannot be migrated again");
    }

    private static void AtomicMigrationAndCas()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-migration-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            var file = Path.Combine(root, "photo.ARW"); File.WriteAllText(file, "raw");
            var store = new EditStore(Path.Combine(root, "edits"));
            var identity = OriginalIdentity.Read(file); var before = Source(identity);
            store.SaveState(identity, before);
            var invalidValues=(double[])before.Settings.Values.Clone();invalidValues[(int)Parameter.Exposure]=99;
            var invalid=new SavedEdit(identity,before.Settings with { Values=invalidValues, Processing=ProcessingIdentity.Current },before.Look);
            var failedBytes=File.ReadAllBytes(Path.Combine(root,"edits","edits.json"));
            try { store.CommitProcessingMigration(identity,before,invalid,ProcessingMigrationReceipt.Migrated); throw new Exception("invalid migration was committed"); }
            catch (InvalidDataException) { }
            Check(File.ReadAllBytes(Path.Combine(root,"edits","edits.json")).SequenceEqual(failedBytes) && store.Find(file)!.Settings.SameAs(before.Settings),
                "failed migration validation is atomic and preserves the old settings");
            var candidate = ProcessingMigration.TryBuildCandidate(before, Result(), out var converted) ? converted! : throw new Exception("candidate");
            var failingStore=new EditStore(Path.Combine(root,"edits"),(_,_)=>throw new IOException("injected migration write failure"));
            try { failingStore.CommitProcessingMigration(identity,before,candidate,ProcessingMigrationReceipt.Migrated); throw new Exception("failed migration write was committed"); }
            catch (IOException error) when (error.Message.Contains("injected",StringComparison.Ordinal)) { }
            Check(File.ReadAllBytes(Path.Combine(root,"edits","edits.json")).SequenceEqual(failedBytes) &&
                  store.Find(file)!.Settings.SameAs(before.Settings),
                "write failure is atomic and preserves the old settings");
            var saved = store.CommitProcessingMigration(identity, before, candidate, ProcessingMigrationReceipt.Migrated);
            Check(saved.Edit?.Settings.Processing == ProcessingIdentity.Current,
                "accepted migration writes v3");
            var receipt = store.ReadProcessingMigration(file);
            Check(receipt?.Status == ProcessingMigrationReceipt.Migrated &&
                  receipt.Before.Settings.SameAs(before.Settings) && receipt.After.Settings.SameAs(candidate.Settings),
                "migration receipt persists the complete before and after snapshots");

            var concurrent = before.Settings.Restore(); concurrent.Set(Parameter.Exposure, 2.2);
            store.SaveState(identity, new(identity, concurrent.Capture(), before.Look));
            try
            {
                store.CommitProcessingMigration(identity, before, candidate, ProcessingMigrationReceipt.Migrated);
                throw new Exception("CAS accepted a changed current record");
            }
            catch (AdjustmentOperationExpiredException) { }
            Check(store.Find(file)!.Settings.Values[(int)Parameter.Exposure] == 2.2,
                "CAS conflict leaves the concurrent edit intact");
            using var document = JsonDocument.Parse(File.ReadAllText(Path.Combine(root, "edits", "edits.json")));
            Check(Math.Abs(document.RootElement.GetProperty("Records").GetProperty(identity.Path).GetProperty("Settings").GetProperty("Values")[1].GetDouble() - 2.2) < 1e-9,
                "CAS test retains the complete atomically written registry");
        }
        finally { Directory.Delete(root, true); }
    }

    private static void RestartRollbackSuppressesAutomaticRetry()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-rollback-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            var file = Path.Combine(root, "photo.ARW"); File.WriteAllText(file, "raw");
            var directory = Path.Combine(root, "edits"); var store = new EditStore(directory);
            var identity = OriginalIdentity.Read(file); var before = Source(identity); store.SaveState(identity, before);
            Check(ProcessingMigration.TryBuildCandidate(before, Result(), out var candidate), "candidate");
            store.CommitProcessingMigration(identity, before, candidate!, ProcessingMigrationReceipt.Migrated);

            var restarted = new EditStore(directory); var current = restarted.ReadState(file);
            var rolledBack = restarted.RollbackProcessingMigration(identity, current);
            Check(rolledBack.Edit?.Settings.SameAs(before.Settings) == true,
                "restart-safe rollback restores the complete pre-migration snapshot");
            var receipt = new EditStore(directory).ReadProcessingMigration(file);
            Check(receipt?.Status == ProcessingMigrationReceipt.RolledBack &&
                  !ProcessingMigration.ShouldAttempt(before, receipt),
                "rolledBack receipt permanently suppresses automatic retry");
        }
        finally { Directory.Delete(root, true); }
    }

    private static void KeptReceiptRetriesOnlyAfterSettingsChange()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-kept-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            var file = Path.Combine(root, "photo.ARW"); File.WriteAllText(file, "raw");
            var directory = Path.Combine(root, "edits"); var store = new EditStore(directory);
            var identity = OriginalIdentity.Read(file); var before = Source(identity); store.SaveState(identity, before);
            store.CommitProcessingMigration(identity, before, before, ProcessingMigrationReceipt.Kept);
            var receipt = store.ReadProcessingMigration(file);
            Check(!ProcessingMigration.ShouldAttempt(before, receipt), "kept result is attempted only once");
            var changed = before.Settings.Restore(); changed.Set(Parameter.Exposure, 2);
            var changedEdit = new SavedEdit(identity, changed.Capture(), before.Look); store.SaveState(identity, changedEdit);
            Check(ProcessingMigration.ShouldAttempt(changedEdit, receipt),
                "a user settings change permits a new automatic fit");
        }
        finally { Directory.Delete(root, true); }
    }

    private static void MigrationHistoryIsolation()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-history-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            var a=Path.Combine(root,"a.ARW");var b=Path.Combine(root,"b.ARW");File.WriteAllText(a,"a");File.WriteAllText(b,"b");
            var store=new EditStore(Path.Combine(root,"edits"));var session=new AdjustmentTransferSession(store);
            foreach(var path in new[]{a,b})
            {
                var state=store.ReadState(path);var edit=new Adjustments { Processing=ProcessingIdentity.C5 };edit.Set(Parameter.Exposure,.5);
                Check(session.CommitEdit(state,new(state.Identity,edit.Capture(),null)).Status==AdjustmentStatus.Applied,"history seed");
            }
            Check(session.PhotoHistoryID(a,true)!=null && session.PhotoHistoryID(b,true)!=null,"history seed is visible for both photos");
            session.AdoptExternalProcessingMigration(store.ReadState(a));
            Check(session.PhotoHistoryID(a,true)==null && session.PhotoHistoryID(b,true)!=null,
                "processing migration clears only this photo's in-memory history");
        }
        finally { Directory.Delete(root,true); }
    }
}
