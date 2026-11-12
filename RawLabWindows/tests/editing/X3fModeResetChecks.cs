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

        RunPureRepairChecks();
        RunOpenRepairAndMigrationChecks();
        RunReadOnlyPathChecks();

        Console.WriteLine("PASS: X3F mode lens reset and Windows paste preflight");
    }

    private static void RunPureRepairChecks()
    {
        foreach (var (distortion, tca, vignetting, ai) in new[]
        {
            (true, false, false, false),
            (false, true, false, false),
            (false, false, true, false),
            (false, false, false, true),
            (true, true, true, true),
        })
        {
            var settings = new Adjustments
            {
                Processing = ProcessingIdentity.C5,
                X3fMode = X3fMode.Normal,
                AIDenoiseEnabled = ai,
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
            var originalSnapshot = settings.Capture();

            Check(settings.RepairLegacyNormalX3f(isX3f: true),
                "Normal X3F with active lens switch or AI denoise reports changed");
            Check(settings.X3fMode == X3fMode.Normal && !settings.AIDenoiseEnabled &&
                  !settings.Lens.Distortion && !settings.Lens.Tca &&
                  !settings.Lens.Vignetting && !settings.Lens.Enabled,
                "Normal X3F repair clears distortion, TCA, vignetting and AI denoise");
            Check(!settings.Lens.AutoCrop && settings.Lens.Manual &&
                  settings.Lens.ProfileId == "saved-lens-profile" &&
                  settings.Lens.FocalLength == 35 &&
                  settings.Lens.CropFactor == 1.5 &&
                  settings[Parameter.Exposure] == 0.25 &&
                  settings.Processing == ProcessingIdentity.C5,
                "Normal X3F repair preserves non-flag lens fields and unrelated adjustments");
            Check(!settings.RepairLegacyNormalX3f(isX3f: true),
                "Already repaired normal X3F reports unchanged");

            var snapshotRepair = X3fModeReset.RepairLegacyNormalX3f(originalSnapshot, isX3f: true);
            Check(snapshotRepair.Changed && snapshotRepair.Settings.SameAs(settings.Capture()),
                "Snapshot repair matches in-place Adjustments repair");
        }

        var legacyX3f = new Adjustments
        {
            X3fMode = X3fMode.Legacy,
            AIDenoiseEnabled = true,
            Lens = new LensSettings(Distortion: true, Tca: true, AutoCrop: false, Manual: true, ProfileId: "legacy-profile", Vignetting: true),
        };
        var legacyFrozen = legacyX3f.Capture();
        Check(!legacyX3f.RepairLegacyNormalX3f(isX3f: true) &&
              !legacyX3f.RepairLegacyNormalX3f("sigma.X3F") &&
              !X3fModeReset.RepairLegacyNormalX3f(legacyFrozen, isX3f: true).Changed &&
              legacyX3f.Capture().SameAs(legacyFrozen),
            "Legacy X3F records keep lens switches and AI denoise untouched");

        var nonX3fNormal = new Adjustments
        {
            X3fMode = X3fMode.Normal,
            AIDenoiseEnabled = true,
            Lens = new LensSettings(Distortion: true, Tca: true, AutoCrop: false, Manual: true, ProfileId: "arw-profile", Vignetting: true),
        };
        var nonX3fFrozen = nonX3fNormal.Capture();
        Check(!nonX3fNormal.RepairLegacyNormalX3f(isX3f: false) &&
              !nonX3fNormal.RepairLegacyNormalX3f("photo.ARW") &&
              !nonX3fNormal.RepairLegacyNormalX3f("photo.jpg") &&
              !X3fModeReset.RepairLegacyNormalX3f(nonX3fFrozen, isX3f: false).Changed &&
              nonX3fNormal.Capture().SameAs(nonX3fFrozen),
            "Non-X3F records with normal X3fMode remain untouched");

        var nullLensSnapshot = new Adjustments { X3fMode = X3fMode.Normal }.Capture() with { Lens = null };
        var nullLensUnchanged = X3fModeReset.RepairLegacyNormalX3f(nullLensSnapshot, isX3f: true);
        Check(!nullLensUnchanged.Changed && nullLensUnchanged.Settings.Lens == null,
            "Null Lens snapshot without active flags stays null and unchanged");

        var nullLensAiSnapshot = nullLensSnapshot with { AIDenoiseEnabled = true };
        var nullLensAiRepaired = X3fModeReset.RepairLegacyNormalX3f(nullLensAiSnapshot, isX3f: true);
        Check(nullLensAiRepaired.Changed &&
              !nullLensAiRepaired.Settings.AIDenoiseEnabled &&
              nullLensAiRepaired.Settings.Lens == null,
            "Null Lens snapshot stays null even when AI denoise is cleared");

        var root = Path.Combine(Path.GetTempPath(), "rawlab-x3f-pure-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            var mislabeledX3f = Path.Combine(root, "sigma.jpeg");
            File.WriteAllText(mislabeledX3f, "FOVbfixture");
            var realJpeg = Path.Combine(root, "ordinary.jpeg");
            File.WriteAllText(realJpeg, "JFIFfixture");

            var mislabeledSettings = new Adjustments { X3fMode = X3fMode.Normal, Lens = new LensSettings(Distortion: true) };
            Check(mislabeledSettings.RepairLegacyNormalX3f(mislabeledX3f) && !mislabeledSettings.Lens.Enabled,
                "Path-based repair recognizes X3F FOVb signature on mislabeled files");

            var ordinarySettings = new Adjustments { X3fMode = X3fMode.Normal, Lens = new LensSettings(Distortion: true) };
            Check(!ordinarySettings.RepairLegacyNormalX3f(realJpeg) && ordinarySettings.Lens.Distortion,
                "Path-based repair leaves ordinary non-X3F files untouched");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static void RunOpenRepairAndMigrationChecks()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-x3f-open-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            var flagsOnlyX3f = Path.Combine(root, "flags-only.X3F");
            var editedX3f = Path.Combine(root, "edited.X3F");
            var migrateX3f = Path.Combine(root, "migrate.X3F");
            foreach (var path in new[] { flagsOnlyX3f, editedX3f, migrateX3f })
                File.WriteAllText(path, "FOVb-" + Path.GetFileName(path));

            var editDir = Path.Combine(root, "edits");
            var seedStore = new EditStore(editDir);

            var flagsOnlyInitial = new Adjustments
            {
                X3fMode = X3fMode.Normal,
                AIDenoiseEnabled = true,
                Lens = new LensSettings(Distortion: true, Tca: true, Vignetting: true),
            };
            seedStore.Save(flagsOnlyX3f, flagsOnlyInitial.Capture(), null);

            var editedInitial = new Adjustments
            {
                X3fMode = X3fMode.Normal,
                AIDenoiseEnabled = true,
                Lens = new LensSettings(
                    Distortion: true,
                    Tca: false,
                    AutoCrop: false,
                    Manual: true,
                    ProfileId: "sigma-35",
                    FocalLength: 35,
                    CropFactor: 1.5,
                    Vignetting: true),
            };
            editedInitial.Set(Parameter.Exposure, 0.5);
            seedStore.Save(editedX3f, editedInitial.Capture(), "builtin:provia.cube");

            var migrateInitial = new Adjustments
            {
                Processing = ProcessingIdentity.C5,
                X3fMode = X3fMode.Normal,
                AIDenoiseEnabled = true,
                Lens = new LensSettings(Distortion: true, Tca: true, Vignetting: true),
            };
            migrateInitial.Set(Parameter.Exposure, 0.7);
            migrateInitial.Set(Parameter.Contrast, 18);
            seedStore.Save(migrateX3f, migrateInitial.Capture(), null);

            var writes = 0;
            var store = new EditStore(editDir, (path, value) =>
            {
                writes++;
                AtomicJson.Write(path, value);
            });
            var session = new AdjustmentTransferSession(store);

            // 1) Open repairs disk record without adding undo history, leaves photo unmarked as modified, and does not write on reopen.
            var loadedFlagsOnly = store.ReadState(flagsOnlyX3f);
            var restoredFlagsOnly = loadedFlagsOnly.Edit!.Settings.Restore();
            var repairedFlagsOnly = session.RepairLegacyNormalX3f(loadedFlagsOnly, restoredFlagsOnly);
            Check(writes == 1 &&
                  !restoredFlagsOnly.AIDenoiseEnabled &&
                  !restoredFlagsOnly.Lens.Enabled &&
                  new EditStore(editDir).ReadState(flagsOnlyX3f).SameAs(repairedFlagsOnly),
                "Opening old normal X3F record writes repaired settings to disk");
            Check(session.Transactions.Count == 0 &&
                  session.PhotoHistoryID(flagsOnlyX3f, undo: true) == null &&
                  session.IsCurrentSave(repairedFlagsOnly),
                "Repair writeback records external save without pushing an undo entry");
            Check(!EditedPhotoPreviewKey.IsEdited(repairedFlagsOnly) &&
                  !EditorAdjustmentRules.IsModified(new(EditorResetKind.All), repairedFlagsOnly.Edit!) &&
                  EditorAdjustmentRules.PrepareReset(new(EditorResetKind.All), repairedFlagsOnly.Edit!).Status == EditorResetStatus.NoChange,
                "Repaired X3F record with no user adjustments is not marked as modified");

            var reopenedFlagsOnly = store.ReadState(flagsOnlyX3f);
            var reopenedSettings = reopenedFlagsOnly.Edit!.Settings.Restore();
            var secondOpenResult = session.RepairLegacyNormalX3f(reopenedFlagsOnly, reopenedSettings);
            Check(writes == 1 && secondOpenResult.SameAs(repairedFlagsOnly),
                "Reopening an already repaired X3F record does not write to disk");

            // 2) CAS concurrency check refuses overwriting a newer concurrent edit, and later user Undo stops at the repaired baseline.
            var staleLoaded = store.ReadState(editedX3f);
            var staleSettings = staleLoaded.Edit!.Settings.Restore();
            var concurrentSettings = staleLoaded.Edit.Settings.Restore();
            concurrentSettings.Set(Parameter.Exposure, 1.75);
            store.SaveState(staleLoaded.Identity, staleLoaded.Edit with { Settings = concurrentSettings.Capture() });
            var writesAfterConcurrent = writes;

            var casRejected = false;
            try
            {
                _ = session.RepairLegacyNormalX3f(staleLoaded, staleSettings);
            }
            catch (AdjustmentOperationExpiredException)
            {
                casRejected = true;
            }
            Check(casRejected &&
                  writes == writesAfterConcurrent &&
                  staleSettings.AIDenoiseEnabled &&
                  staleSettings.Lens.Enabled &&
                  store.Find(editedX3f)!.Settings.Restore()[Parameter.Exposure] == 1.75 &&
                  session.Transactions.Count == 0,
                "Repair writeback enforces CAS against the loaded record and preserves concurrent edits");

            var freshLoaded = store.ReadState(editedX3f);
            var freshSettings = freshLoaded.Edit!.Settings.Restore();
            var repairedEdited = session.RepairLegacyNormalX3f(freshLoaded, freshSettings);
            Check(!repairedEdited.Edit!.Settings.AIDenoiseEnabled &&
                  !repairedEdited.Edit.Settings.Lens!.Enabled &&
                  repairedEdited.Edit.Settings.Lens.ProfileId == "sigma-35" &&
                  !repairedEdited.Edit.Settings.Lens.AutoCrop &&
                  repairedEdited.Edit.Look == "builtin:provia.cube" &&
                  repairedEdited.Edit.Settings.Restore()[Parameter.Exposure] == 1.75 &&
                  session.Transactions.Count == 0,
                "Fresh open repairs incompatible flags while retaining exposure, lens profile preferences and look");

            freshSettings.Set(Parameter.Exposure, 2.25);
            var userCommit = session.CommitEdit(repairedEdited, new SavedEdit(repairedEdited.Identity, freshSettings.Capture(), repairedEdited.Edit.Look));
            Check(userCommit.Status == AdjustmentStatus.Applied && session.Transactions.Count == 1,
                "Subsequent user edit records normal undo history");
            var undone = session.UndoPhoto(editedX3f).Single();
            Check(undone.Status == AdjustmentStatus.Applied &&
                  undone.Saved!.SameAs(repairedEdited) &&
                  !undone.Saved.Edit!.Settings.AIDenoiseEnabled &&
                  !undone.Saved.Edit.Settings.Lens!.Enabled &&
                  session.PhotoHistoryID(editedX3f, undo: true) == null,
                "Undoing user edit returns to repaired baseline and never resurrects broken X3F flags");

            // 3) Record needing BOTH X3F repair AND processing migration: repair persists first, then migration commits against repaired baseline.
            var loadedMigrate = store.ReadState(migrateX3f);
            Check(!ProcessingMigration.ShouldAttempt(loadedMigrate.Edit!, store.ReadProcessingMigration(migrateX3f)),
                "Incompatible AI flag would block processing migration before X3F repair");

            var migrateSettings = loadedMigrate.Edit!.Settings.Restore();
            var repairedMigrate = session.RepairLegacyNormalX3f(loadedMigrate, migrateSettings);
            Check(repairedMigrate.Edit!.Settings.Processing == ProcessingIdentity.C5 &&
                  !repairedMigrate.Edit.Settings.AIDenoiseEnabled &&
                  !repairedMigrate.Edit.Settings.Lens!.Enabled &&
                  session.PhotoHistoryID(migrateX3f, undo: true) == null,
                "X3F repair writes repaired v2 record before processing migration starts");

            Check(ProcessingMigration.ShouldAttempt(repairedMigrate.Edit, store.ReadProcessingMigration(migrateX3f)),
                "Repaired v2 X3F record becomes eligible for processing migration");
            var migrationResult = new Native.ProcessingMigrationResult
            {
                Version = 1,
                StructSize = 80,
                SourceVersion = 2,
                TargetVersion = 3,
                Disposition = 1,
                EvaluationCount = 8,
                ExposureEv = 1.1f,
                Contrast = 1.18f,
                Highlights = 0f,
                Shadows = 0f,
                Saturation = 1f,
                BlackPoint = 0f,
                WhitePoint = 0f,
                Vibrance = 0f,
                Clarity = 0f,
                Dehaze = 0f,
                RgbRmse = .002f,
                P99Error = .01f,
                WorstTileRmse = .004f,
                DetailRmse = .003f,
            };
            Check(ProcessingMigration.TryBuildCandidate(repairedMigrate.Edit, migrationResult, out var migratedCandidate) &&
                  migratedCandidate != null,
                "Processing migration builds v3 candidate from repaired X3F record");
            var committedMigrate = store.CommitProcessingMigration(
                repairedMigrate.Identity, repairedMigrate.Edit, migratedCandidate!, ProcessingMigrationReceipt.Migrated);
            session.AdoptExternalProcessingMigration(committedMigrate);

            var receipt = store.ReadProcessingMigration(migrateX3f);
            Check(committedMigrate.Edit!.Settings.Processing == ProcessingIdentity.Current &&
                  committedMigrate.Edit.Settings.X3fMode == X3fMode.Normal &&
                  !committedMigrate.Edit.Settings.AIDenoiseEnabled &&
                  !committedMigrate.Edit.Settings.Lens!.Enabled &&
                  receipt is { Status: ProcessingMigrationReceipt.Migrated } &&
                  receipt.Before.SameAs(repairedMigrate.Edit),
                "Processing migration commits cleanly against repaired X3F baseline and records repaired Before snapshot");

            var rolledBack = store.RollbackProcessingMigration(committedMigrate.Identity, committedMigrate);
            Check(rolledBack.Edit!.SameAs(repairedMigrate.Edit) &&
                  !rolledBack.Edit.Settings.AIDenoiseEnabled &&
                  !rolledBack.Edit.Settings.Lens!.Enabled,
                "Rolling back processing migration restores repaired X3F v2 record without re-enabling incompatible flags");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static void RunReadOnlyPathChecks()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-x3f-readonly-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            var unopenedEditedX3f = Path.Combine(root, "unopened-edited.X3F");
            var unopenedFlagsOnlyX3f = Path.Combine(root, "unopened-flags.X3F");
            var hdrSource = Path.Combine(root, "source.dng");
            var outputDir = Path.Combine(root, "output");
            Directory.CreateDirectory(outputDir);
            File.WriteAllText(unopenedEditedX3f, "FOVb-edited");
            File.WriteAllText(unopenedFlagsOnlyX3f, "FOVb-flags");
            File.WriteAllText(hdrSource, "dng-source");

            var editDir = Path.Combine(root, "edits");
            var seedStore = new EditStore(editDir);

            var editedBroken = new Adjustments
            {
                X3fMode = X3fMode.Normal,
                AIDenoiseEnabled = true,
                Lens = new LensSettings(
                    Distortion: true,
                    Tca: true,
                    AutoCrop: false,
                    Manual: true,
                    ProfileId: "sigma-45",
                    FocalLength: 45,
                    CropFactor: 1.0,
                    Vignetting: true),
            };
            editedBroken.Set(Parameter.Exposure, 0.6);
            seedStore.Save(unopenedEditedX3f, editedBroken.Capture(), null);

            var flagsOnlyBroken = new Adjustments
            {
                X3fMode = X3fMode.Normal,
                AIDenoiseEnabled = true,
                Lens = new LensSettings(Distortion: true),
            };
            seedStore.Save(unopenedFlagsOnlyX3f, flagsOnlyBroken.Capture(), null);

            var editsJsonPath = Path.Combine(editDir, "edits.json");
            var rawEditsBefore = File.ReadAllBytes(editsJsonPath);
            var writes = 0;
            var store = new EditStore(editDir, (path, value) =>
            {
                writes++;
                AtomicJson.Write(path, value);
            });

            // 1) Thumbnail preview read-only path (EditedPhotoPreviewKey.ReadState / PrepareState / IsEdited / Create).
            var previewFlagsOnly = EditedPhotoPreviewKey.ReadState(store, unopenedFlagsOnlyX3f);
            Check(!EditedPhotoPreviewKey.IsEdited(previewFlagsOnly),
                "Thumbnail read-only state does not mark flags-only old X3F record as edited");

            var previewEdited = EditedPhotoPreviewKey.ReadState(store, unopenedEditedX3f);
            Check(EditedPhotoPreviewKey.IsEdited(previewEdited) &&
                  !previewEdited.Edit!.Settings.AIDenoiseEnabled &&
                  !previewEdited.Edit.Settings.Lens!.Enabled &&
                  previewEdited.Edit.Settings.Lens.ProfileId == "sigma-45",
                "Thumbnail read-only state clears incompatible flags in memory while keeping real edits");
            var previewKey = EditedPhotoPreviewKey.Create(previewEdited, null);
            Check(previewKey.Length == 64 &&
                  previewEdited.SameAs(EditedPhotoPreviewKey.ReadState(store, unopenedEditedX3f)) &&
                  previewKey == EditedPhotoPreviewKey.Create(EditedPhotoPreviewKey.PrepareState(store.ReadState(unopenedEditedX3f)), null),
                "Thumbnail cache key and RequireCurrent comparison succeed without AI manifest or disk mutation");

            // 2) Collection export read-only path (BatchSelectionExport.Prepare / Freeze).
            var selection = new BatchSelectionSession();
            selection.Add([unopenedEditedX3f, unopenedFlagsOnlyX3f]);
            var journal = new BatchJournal(Path.Combine(root, "collection-batch"));
            var exporter = new BatchSelectionExport(
                store,
                journal,
                edit => edit.Look,
                validateAI: _ => throw new Exception("Normal X3F should not invoke AI validator after in-memory repair"));
            var review = exporter.Prepare(selection, [], ExportFormat.Png, 1024, outputDir, _ => null);
            Check(review.Ready && review.Rows.Count == 2,
                "Collection export preflight succeeds on unopened legacy normal X3F records");
            var frozenCollectionJob = exporter.Freeze(selection, review, _ => null);
            Check(frozenCollectionJob.Items[0].Frozen!.Settings is
                  {
                      X3fMode: X3fMode.Normal,
                      AIDenoiseEnabled: false,
                      Lens: { Enabled: false, ProfileId: "sigma-45", AutoCrop: false },
                  } &&
                  frozenCollectionJob.Items[0].Frozen!.Settings.Values[(int)Parameter.Exposure] == 0.6 &&
                  frozenCollectionJob.Items[1].Frozen!.Settings is { X3fMode: X3fMode.Normal, AIDenoiseEnabled: false, Lens: { Enabled: false } },
                "Collection export freezes repaired settings in memory");
            journal.Discard(frozenCollectionJob);

            // 3) HDR uniform batch target preparation read-only path (BatchHDRPreparation.Prepare).
            var hdrSourceSettings = new Adjustments
            {
                HDR = new HDRSettings { Mode = HDRMode.Hdr, Exposure = 0.5 },
                ProRAWDecodeVersion = HDRNative.ProRAWDecodeVersion,
            };
            var hdrJob = BatchJob.Create(hdrSource, hdrSourceSettings.Capture(), null, "HDR");
            hdrJob.SourceIsProRAW = true;
            hdrJob.OutputDirectory = outputDir;
            hdrJob.Format = ExportFormat.SdrJpeg;
            hdrJob.LongEdge = 512;
            var hdrTargetFrozen = new BatchHDRPreparation(store, edit => edit.Look)
                .Prepare(hdrJob, BatchItem.Create(unopenedEditedX3f));
            Check(hdrTargetFrozen.Settings is
                  {
                      X3fMode: X3fMode.Normal,
                      AIDenoiseEnabled: false,
                      Lens: { Enabled: false, ProfileId: "sigma-45" },
                  } &&
                  Math.Abs(hdrTargetFrozen.Settings.Values[(int)Parameter.Exposure] - 0.5) < 1e-6,
                "HDR batch target preparation repairs unopened normal X3F target in memory");

            // 4) Paste target validation read-only path (defaults.RepairLegacyNormalX3f + CreateLensProbe).
            var pasteTargetDefaults = store.ReadState(unopenedEditedX3f).Edit!.Settings.Restore();
            Check(pasteTargetDefaults.RepairLegacyNormalX3f(unopenedEditedX3f) &&
                  !pasteTargetDefaults.AIDenoiseEnabled &&
                  !pasteTargetDefaults.Lens.Enabled,
                "Paste preflight target defaults clear incompatible normal X3F flags in memory");
            var lensRejected = false;
            try
            {
                _ = X3fModeReset.CreateLensProbe(unopenedEditedX3f, pasteTargetDefaults, new LensSettings(Distortion: true));
            }
            catch (AdjustmentTransferException error) when (error.Failure == AdjustmentFailure.Incompatible)
            {
                lensRejected = true;
            }
            Check(lensRejected, "Repaired normal X3F paste target still rejects active lens correction");

            Check(writes == 0 &&
                  File.ReadAllBytes(editsJsonPath).SequenceEqual(rawEditsBefore) &&
                  store.ReadState(unopenedEditedX3f).Edit!.Settings is { AIDenoiseEnabled: true, Lens: { Distortion: true } },
                "All read-only paths leave stored edits.json untouched on disk");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }
}
