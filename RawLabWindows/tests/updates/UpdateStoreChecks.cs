using System.Text.Json;
using System.Diagnostics;
using RawLab.Windows;

internal static class UpdateStoreChecks
{
    internal static void Crash(string root, string saved)
    {
        new UpdateDataBackup(root, Path.Combine(root, "Updates")).Restore(saved, name => { if (name == "Edits") Environment.Exit(71); });
        throw new Exception("Crash injection was not reached");
    }
    internal static void Run(Action<bool, string> check)
    {
        AtomicWriteRetries(check);
        StateRepair(check);
        FailedStateValidation(check);
        CheckFailureCompatibility(check);
        RollbackCompatibility(check);
        var root = Path.Combine(Path.GetTempPath(), "rawlab-update-store-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
        try
        {
            var store = new UpdateStore(Path.Combine(root, "Updates")); var prefs = store.Load(false);
            check(!prefs.AutomaticCheck && !prefs.AutomaticInstall, "Old opt-out is preserved during migration");
            prefs.SkippedVersion = "0.9.1"; prefs.RemindAfter = DateTimeOffset.UtcNow.AddDays(1);
            var token = prefs.PendingUpdate.BeginCheck(); prefs.PendingUpdate.Fail("network", "offline", token); store.Save(prefs);
            var restored = store.Load(true);
            check(restored.PendingUpdate.Failure?.Code == "network" && restored.SkippedVersion == prefs.SkippedVersion && restored.RemindAfter == prefs.RemindAfter,
                "Failure and reminder settings survive reopening");
            File.WriteAllText(store.StatePath, "broken"); var rejected = false;
            try { store.Load(true); } catch (JsonException) { rejected = true; }
            check(rejected && File.ReadAllText(store.StatePath) == "broken", "Corrupt state is not overwritten");
            var edits = Path.Combine(root, "Edits"); Directory.CreateDirectory(edits); var photo = Path.Combine(edits, "photo.json"); File.WriteAllText(photo, "precise edit");
            var modified = File.GetLastWriteTimeUtc(photo);
            var backup = new UpdateDataBackup(root, store.DirectoryPath); var saved = backup.Create("0.8.2", "0.9.1");
            check(backup.Verify(saved).Files.Count == 1 && File.ReadAllText(photo) == "precise edit" && File.GetLastWriteTimeUtc(photo) == modified,
                "Backup verifies copies without changing source data or modification time");
            File.WriteAllText(photo, "new format"); File.WriteAllText(Path.Combine(edits, "new.json"), "new photo");
            var receipt = backup.Restore(saved);
            check(File.ReadAllText(photo) == "precise edit" && !File.Exists(Path.Combine(edits, "new.json")),
                "Explicit recovery restores only verified previous records");
            check(File.ReadAllText(Path.Combine(receipt, "original", "Edits", "photo.json")) == "new format" &&
                File.ReadAllText(Path.Combine(receipt, "original", "Edits", "new.json")) == "new photo",
                "Recovery quarantines every newer record");
            check(backup.HasPendingRecovery, "Recovery remains blocked until its completion is persisted");
            backup.FinishRecovery(receipt);
            var recovered=new UpdatePreferences {RecoveryReceipt=receipt};
            var damagedRecovery=JsonSerializer.SerializeToNode(recovered)!;damagedRecovery["AutomaticCheck"]="broken";
            File.WriteAllText(store.StatePath,damagedRecovery.ToJsonString());
            var repairedRecovery=store.RepairState(store.RepairableState());
            check(repairedRecovery.RecoveryReceipt==receipt && Directory.Exists(receipt),
                "Completed recovery receipt does not block preference repair or lose its data link");
            backup.DiscardUnreferencedBackups(saved+"/.",receipt+"/.");
            check(Directory.Exists(saved) && Directory.Exists(receipt),"Equivalent referenced paths preserve backup and recovery links during cleanup");
            File.WriteAllText(photo, "latest format"); rejected = false;
            try { backup.Restore(saved, name => { if (name == "Edits") throw new IOException("Injected failure"); }); }
            catch (IOException) { rejected = true; }
            check(rejected && File.ReadAllText(photo) == "latest format" && !backup.HasPendingRecovery,
                "A mid-recovery failure rolls back moved directories without losing new data");
            var start = new ProcessStartInfo("dotnet") { UseShellExecute = false };
            start.ArgumentList.Add(typeof(UpdateStoreChecks).Assembly.Location);
            start.ArgumentList.Add("--crash-recovery"); start.ArgumentList.Add(root); start.ArgumentList.Add(saved);
            using var child = Process.Start(start)!;
            if (!child.WaitForExit(10000)) { child.Kill(); child.WaitForExit(); throw new Exception("Recovery crash fixture timed out"); }
            check(child.ExitCode == 71 && backup.HasPendingRecovery && !File.Exists(photo), "An actual process crash leaves a recovery journal between directory moves");
            var resumed = backup.Restore(saved);
            check(File.ReadAllText(photo) == "precise edit" && File.ReadAllText(Path.Combine(resumed, "original", "Edits", "photo.json")) == "latest format",
                "A new process safely rolls back an interrupted move before repeating recovery");
            backup.FinishRecovery(resumed);
            File.WriteAllText(Path.Combine(saved, "Edits", "photo.json"), "changed"); rejected = false;
            try { backup.Verify(saved); } catch (IOException) { rejected = true; }
            check(rejected, "Modified backup is rejected");
            rejected = false; try { backup.Verify(root); } catch (InvalidDataException) { rejected = true; }
            check(rejected, "Recovery cannot reference an arbitrary directory");
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    private static void StateRepair(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-state-repair-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new UpdateStore(Path.Combine(root, "Updates")); Directory.CreateDirectory(store.DirectoryPath);
            bool Rejected(Action work) { try { work(); return false; } catch { return true; } }
            foreach (var incomplete in new[] { "{}", "{\"PendingUpdate\":{}}" })
            {
                File.WriteAllText(store.StatePath, incomplete);
                check(Rejected(() => store.Load(false)) && store.RepairableState().Length > 0, "Incomplete state requires explicit repair instead of defaulting to idle");
            }
            foreach (var field in new[] { "Phase", "Choice" })
            {
                store.Save(new()); var json = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(store.StatePath))!;
                json["PendingUpdate"]![field] = 99; File.WriteAllText(store.StatePath, json.ToJsonString());
                UpdatePreferences? downgraded = null; try { downgraded = store.Load(false); } catch { }
                check(downgraded != null && downgraded.PendingUpdate.Phase == UpdatePhase.Idle &&
                    downgraded.PendingUpdate.Choice == UpdateInstallChoice.None && downgraded.PendingUpdate.Failure == null,
                    "Future enum state opens editing as idle (Q13 rollback): " + field);
                string? rebuildError = null; try { store.RepairableState(); } catch (InvalidDataException error) { rebuildError = error.Message; }
                check(rebuildError != null && rebuildError.Contains("readable", StringComparison.Ordinal),
                    "Unknown enum state reports readable instead of demanding a rebuild: " + field);
            }
            byte[] damaged = "{broken"u8.ToArray(); File.WriteAllBytes(store.StatePath, damaged);
            var snapshot = store.RepairableState(); var repaired = store.RepairState(snapshot); var receipt = repaired.StateRepairReceipt!;
            check(File.ReadAllBytes(store.RepairedStateArchive(receipt)).SequenceEqual(damaged) && !repaired.AutomaticCheck &&
                !repaired.AutomaticInstall && repaired.PendingUpdate.Phase == UpdatePhase.Idle,
                "Explicit state repair preserves damaged bytes and disables automatic updates");
            check(store.Load(true).StateRepairReceipt == receipt, "State repair persists a verified startup receipt");
            File.WriteAllText(store.RepairedStateArchive(receipt), "changed archive");
            check(Rejected(() => store.Load(false)) && Rejected(() => store.RepairableState()), "A changed repair archive blocks startup and another reset");
            check(Rejected(() => store.RepairState(snapshot)), "A stale repair cannot overwrite the replacement state");
            var future = new UpdatePreferences(); future.PendingUpdate.Format = 2; store.Save(future);
            check(Rejected(() => store.RepairableState()), "Future update formats cannot be reset as corrupt preferences");
            File.WriteAllText(store.StatePath, "{\"PendingUpdate\":{\"Phase\":8},\"AutomaticCheck\":\"invalid\"}");
            check(Rejected(() => store.RepairableState()), "Partial installation state remains blocked without its backup");
            File.WriteAllText(store.StatePath, "{\"PendingUpdate\":{\"PreviousVersion\":\"0.8.2\"}}");
            check(Rejected(() => store.RepairableState()), "Previous installation identity blocks ambiguous state repair");
            var orphanManager=new UpdateDataBackup(root,store.DirectoryPath);
            var orphan=orphanManager.Create("0.8.2","0.9.1","14");
            File.WriteAllText(store.StatePath,"{\"AutomaticCheck\":\"broken\",\"PendingUpdate\":{\"Format\":1,\"Phase\":0}}");
            check(Rejected(() => store.RepairableState()) && Directory.Exists(orphan), "Incomplete installation state cannot prove a backup is orphaned");
            var nonInstallation=System.Text.Json.JsonSerializer.SerializeToNode(new UpdatePreferences())!;
            nonInstallation["AutomaticCheck"]="broken"; File.WriteAllText(store.StatePath,nonInstallation.ToJsonString());
            var partialId=Guid.NewGuid().ToString("N"); var recoveryId=Guid.NewGuid().ToString("N"); var stagedId=Guid.NewGuid().ToString("N");
            var partial=Path.Combine(store.DirectoryPath,"Backups",partialId);
            var recovery=Path.Combine(store.DirectoryPath,"Recoveries",recoveryId,"original","Edits");
            var staged=Path.Combine(store.DirectoryPath,"Backups",".staging-"+stagedId);
            foreach(var path in new[]{partial,recovery,staged})Directory.CreateDirectory(path);
            File.WriteAllText(Path.Combine(partial,"part.json"),"unfinished copy");
            File.WriteAllText(Path.Combine(recovery,"new.json"),"unique newer edit");
            File.WriteAllText(Path.Combine(staged,"part.json"),"staged copy");
            Directory.SetLastWriteTimeUtc(staged,DateTime.UtcNow.AddDays(-2));
            store.RepairState(store.RepairableState());
            check(Directory.Exists(orphan),"Repair preserves backup evidence until a healthy startup can clean it");
            orphanManager.DiscardUnreferencedBackups(null);
            check(!Directory.Exists(orphan) && !Directory.Exists(staged),"Healthy cleanup removes verified orphan backups and abandoned staging copies");
            check(File.ReadAllText(Path.Combine(store.DirectoryPath,"IncompleteBackups",partialId,"part.json"))=="unfinished copy",
                "Old incomplete backups are quarantined rather than deleted");
            check(File.ReadAllText(Path.Combine(store.DirectoryPath,"RecoveryArchives",recoveryId,"original","Edits","new.json"))=="unique newer edit",
                "Inactive recovery data is archived without losing newer edits");
            File.WriteAllBytes(store.StatePath, damaged); var backups = Path.Combine(store.DirectoryPath, "Backups");
            Directory.CreateDirectory(Path.Combine(backups, "prior"));
            check(Rejected(() => store.RepairableState()), "Installation evidence blocks uncertain state repair");
            Directory.Delete(backups, true); File.WriteAllText(Path.Combine(store.DirectoryPath, "recovery-in-progress.json"), "journal");
            check(Rejected(() => store.RepairableState()) && File.ReadAllBytes(store.StatePath).SequenceEqual(damaged),
                "An interrupted recovery remains blocked without changing damaged state");
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    private static void FailedStateValidation(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-failure-state-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new UpdateStore(root); var valid = new UpdatePreferences(); var token = valid.PendingUpdate.BeginCheck();
            valid.PendingUpdate.Fail("network", "", token); store.Save(valid);
            check(store.Load(false).PendingUpdate.Failure == valid.PendingUpdate.Failure, "A complete failure with empty detail remains readable");
            var original = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(store.StatePath))!; var accepted = new List<string>();
            foreach (var name in new[] { "missing", "null", "empty", "missing-Stage", "missing-Code", "missing-Detail",
                "null-Stage", "null-Code", "null-Detail", "empty-Code", "Idle", "Available", "Complete", "Failed" })
            {
                var document = original.DeepClone(); var pending = document["PendingUpdate"]!.AsObject(); var failure = pending["Failure"]!.AsObject();
                if (name == "missing") pending.Remove("Failure");
                else if (name == "null") pending["Failure"] = null;
                else if (name == "empty") pending["Failure"] = new System.Text.Json.Nodes.JsonObject();
                else if (name == "empty-Code") failure["Code"] = "";
                else if (name.StartsWith("missing-")) failure.Remove(name[8..]);
                else if (name.StartsWith("null-")) failure[name[5..]] = null;
                else failure["Stage"] = (int)Enum.Parse<UpdatePhase>(name);
                var damaged = document.ToJsonString(); File.WriteAllText(store.StatePath, damaged);
                try { store.Load(false); accepted.Add(name); } catch { }
                check(File.ReadAllText(store.StatePath) == damaged, "Rejected failure input is preserved: " + name);
            }
            check(accepted.Count == 0, "Malformed failed states must be rejected; accepted: " + string.Join(", ", accepted));
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    private static void RollbackCompatibility(Action<bool, string> check)
    {
        // Q13 回滚兼容：新版写入旧版读不懂的枚举值时降级为 Idle，不锁编辑区；
        // 真正的损坏与安装证据仍走显式存储修复。
        var root = Path.Combine(Path.GetTempPath(), "rawlab-rollback-compat-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new UpdateStore(root); Directory.CreateDirectory(store.DirectoryPath);
            var lastCheck = DateTimeOffset.FromUnixTimeSeconds(1800000000);
            var release = new UpdateDescriptor("0.9.1", "19", "windows", "x64", "stable", "https://example.invalid/update.nupkg", 12, null, "Notes");
            UpdatePreferences Prepared()
            {
                var prefs = new UpdatePreferences { AutomaticCheck = true, LastCheck = lastCheck, SkippedVersion = "0.9.0" };
                var token = prefs.PendingUpdate.BeginCheck();
                prefs.PendingUpdate.Found(release, token);
                var download = prefs.PendingUpdate.BeginDownload()!.Value;
                prefs.PendingUpdate.Preparing(download); prefs.PendingUpdate.Verified(download);
                return prefs;
            }
            void Patch(Action<System.Text.Json.Nodes.JsonObject> edit)
            {
                var json = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(store.StatePath))!.AsObject();
                edit(json); File.WriteAllText(store.StatePath, json.ToJsonString());
            }
            UpdatePreferences? Downgrade() { try { return store.Load(false); } catch { return null; } }

            store.Save(Prepared());
            Patch(json => json["PendingUpdate"]!["Phase"] = 99);
            var onDisk = File.ReadAllBytes(store.StatePath);
            var fromPhase = Downgrade();
            check(fromPhase != null && fromPhase.PendingUpdate.Phase == UpdatePhase.Idle && fromPhase.PendingUpdate.Release == null &&
                fromPhase.PendingUpdate.Attempt != Guid.Empty, "Future Phase downgrades to a fresh idle record");
            check(fromPhase != null && fromPhase.AutomaticCheck && fromPhase.LastCheck == lastCheck && fromPhase.SkippedVersion == "0.9.0",
                "Future Phase downgrade preserves preferences outside the pending update");
            check(File.ReadAllBytes(store.StatePath).SequenceEqual(onDisk), "Future Phase downgrade never rewrites state during load");

            store.Save(Prepared());
            Patch(json => json["PendingUpdate"]!["Choice"] = 99);
            var fromChoice = Downgrade();
            check(fromChoice != null && fromChoice.PendingUpdate.Phase == UpdatePhase.Idle && fromChoice.PendingUpdate.Release == null,
                "Future install choice downgrades to idle instead of locking the editor");

            var failed = Prepared(); var downloadToken = failed.PendingUpdate.Attempt;
            failed.PendingUpdate.Fail("network", "dropped", downloadToken);
            store.Save(failed);
            Patch(json => json["PendingUpdate"]!["Failure"]!["Stage"] = 99);
            var fromStage = Downgrade();
            check(fromStage != null && fromStage.PendingUpdate.Phase == UpdatePhase.Idle && fromStage.PendingUpdate.Failure == null,
                "Future failure stage downgrades to idle instead of locking the editor");

            store.Save(Prepared());
            Patch(json => json["PendingUpdate"]!["Progress"] = 2.5);
            var rejected = false; try { store.Load(false); } catch (InvalidDataException) { rejected = true; }
            check(rejected, "Known enum values with out-of-range progress remain rejected");

            store.Save(failed);
            Patch(json => { json["PendingUpdate"]!["Failure"]!["Stage"] = 99; json["AutomaticCheck"] = "broken"; });
            var bytes = File.ReadAllBytes(store.StatePath);
            rejected = false; try { store.Load(false); } catch (JsonException) { rejected = true; }
            check(rejected, "Future enum plus unrelated corruption still requires explicit repair");
            byte[]? rebuild = null; try { rebuild = store.RepairableState(); } catch { }
            check(rebuild != null && rebuild.SequenceEqual(bytes) && File.ReadAllBytes(store.StatePath).SequenceEqual(bytes),
                "Future enum no longer refuses an otherwise-corrupt state rebuild");
            var repaired = store.RepairState(store.RepairableState());
            check(repaired.PendingUpdate.Phase == UpdatePhase.Idle && repaired.StateRepairReceipt != null && !repaired.AutomaticCheck,
                "Explicit rebuild of a future-enum state still archives bytes and disables automatic updates");

            var evidenceStore = new UpdateStore(Path.Combine(root, "evidence")); Directory.CreateDirectory(evidenceStore.DirectoryPath);
            File.WriteAllBytes(evidenceStore.StatePath, bytes);
            var json2 = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(evidenceStore.StatePath))!.AsObject();
            json2["AutomaticCheck"] = true; json2["PendingUpdate"]!["BackupPath"] = "C:\\RawLab\\Backups\\pending";
            File.WriteAllText(evidenceStore.StatePath, json2.ToJsonString());
            string? rebuildReason = null; try { evidenceStore.RepairableState(); } catch (InvalidDataException error) { rebuildReason = error.Message; }
            check(rebuildReason != null && rebuildReason.Contains("cannot be rebuilt", StringComparison.Ordinal),
                "Installation evidence still refuses the rollback-compat rebuild");
            rejected = false; try { evidenceStore.Load(false); } catch (InvalidDataException) { rejected = true; }
            check(rejected, "Evidence combo keeps the storage gate instead of downgrading to idle");

            // — Q13 组合：未知枚举与安装证据并存时不得进入「删备份」的降级分支 —
            store.Save(Prepared());
            Patch(json => { var pending = json["PendingUpdate"]!.AsObject();
                pending["Phase"] = (int)UpdatePhase.Installing; pending["Choice"] = 99; pending["BackupPath"] = "pending-backup"; pending["PreviousVersion"] = "0.8.2"; });
            var comboBytes = File.ReadAllBytes(store.StatePath);
            rejected = false; try { store.Load(false); } catch (InvalidDataException) { rejected = true; }
            check(rejected && File.ReadAllBytes(store.StatePath).SequenceEqual(comboBytes),
                "Known Installing with a future choice keeps the storage gate instead of downgrading");

            store.Save(Prepared());
            Patch(json => { var pending = json["PendingUpdate"]!.AsObject(); pending["Phase"] = 99; pending["PreviousBuild"] = "19"; });
            rejected = false; try { store.Load(false); } catch (InvalidDataException) { rejected = true; }
            check(rejected, "Future phase with previous build identity keeps the storage gate");

            store.Save(failed);
            Patch(json => { var pending = json["PendingUpdate"]!.AsObject(); pending["Choice"] = 99; pending["Failure"]!["Stage"] = (int)UpdatePhase.Installing; });
            rejected = false; try { store.Load(false); } catch (InvalidDataException) { rejected = true; }
            check(rejected, "Future choice over a Failed(Installing) record keeps the recovery gate");

            // — 结构完整性先于降级判定：未知枚举不得掩盖损坏（评审 Finding 2） —
            store.Save(Prepared());
            Patch(json => { json["PendingUpdate"]!["Phase"] = 99; json["PendingUpdate"]!["Progress"] = 2.5; });
            rejected = false; try { store.Load(false); } catch (InvalidDataException) { rejected = true; }
            check(rejected, "Future enum with out-of-range progress still routes to explicit repair");

            store.Save(Prepared());
            Patch(json => { json["PendingUpdate"]!["Phase"] = 99; json["PendingUpdate"]!["Blockers"] = null; });
            rejected = false; try { store.Load(false); } catch (InvalidDataException) { rejected = true; }
            check(rejected, "Future enum with null blockers still routes to explicit repair");

            store.Save(failed);
            Patch(json => { var pending = json["PendingUpdate"]!.AsObject(); pending["Choice"] = 99; pending.Remove("Failure"); });
            var incomplete = ""; try { store.Load(false); } catch (InvalidDataException error) { incomplete = error.Message; }
            check(incomplete.Contains("Incomplete update failure", StringComparison.Ordinal),
                "Failed phase with a missing failure record is not masked by a future choice downgrade");

            // — 未知 Phase/Stage 不得按「已知非安装」放行孤儿备份（评审 Finding 3） —
            foreach (var slot in new[] { "Phase", "FailureStage" })
            {
                var gate = new UpdateStore(Path.Combine(root, "gate-" + slot)); Directory.CreateDirectory(gate.DirectoryPath);
                var orphan = Path.Combine(gate.DirectoryPath, "Backups", Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(orphan); File.WriteAllText(Path.Combine(orphan, "part.json"), "orphan copy");
                var node = System.Text.Json.Nodes.JsonNode.Parse(JsonSerializer.Serialize(failed))!.AsObject();
                node["AutomaticCheck"] = "broken";
                if (slot == "Phase") node["PendingUpdate"]!["Phase"] = 99; else node["PendingUpdate"]!["Failure"]!["Stage"] = 99;
                File.WriteAllText(gate.StatePath, node.ToJsonString());
                rejected = false;
                try { gate.RepairableState(); } catch (InvalidDataException error) { rejected = error.Message.Contains("status is unknown", StringComparison.Ordinal); }
                check(rejected, "Unknown " + slot + " is not treated as known-non-installation when backups exist");
            }
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    private static void CheckFailureCompatibility(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-check-failure-store-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new UpdateStore(root); Directory.CreateDirectory(store.DirectoryPath);
            var t0 = DateTimeOffset.FromUnixTimeSeconds(1800000000);
            var legacyNode = System.Text.Json.Nodes.JsonNode.Parse(JsonSerializer.Serialize(new UpdatePreferences { LastCheck = t0 }))!.AsObject();
            legacyNode.Remove("CheckFailure");
            File.WriteAllText(store.StatePath, legacyNode.ToJsonString());
            var legacy = store.Load(true);
            check(legacy.CheckFailure == null && legacy.LastCheck == t0 &&
                UpdatePresentation.Status(legacy) == "尚未发现可安装的更新" &&
                UpdatePresentation.CheckFailureDetail(legacy) == null,
                "Legacy state omitting CheckFailure deserializes as no failure and up-to-date when LastCheck exists");

            legacyNode["LastCheck"] = null;
            File.WriteAllText(store.StatePath, legacyNode.ToJsonString());
            var uncheckedLegacy = store.Load(true);
            check(uncheckedLegacy.CheckFailure == null && uncheckedLegacy.LastCheck == null &&
                UpdatePresentation.Status(uncheckedLegacy) == "尚未检查更新",
                "Legacy state with null LastCheck presents never-checked status");

            var failed = new UpdatePreferences
            {
                CheckFailure = new(t0.AddMinutes(5), "network", 3, "DNS lookup failed")
            };
            store.Save(failed);
            var roundTrip = store.Load(true);
            check(roundTrip.CheckFailure == failed.CheckFailure &&
                UpdatePresentation.Status(roundTrip) == "检查失败，请稍后重试或访问 GitHub 仓库" &&
                !UpdatePresentation.ShowsCheckFailureNotice(roundTrip) &&
                UpdatePresentation.CheckFailureDetail(roundTrip) is { } detail &&
                detail.Contains("network", StringComparison.Ordinal) &&
                detail.Contains("UTC", StringComparison.Ordinal) &&
                detail.Contains("DNS lookup failed", StringComparison.Ordinal),
                "CheckFailure persists across Save/Load and formats failure category, UTC timestamp, and detail");

            var availableWithCheckFailure = roundTrip.Copy();
            var checkToken = availableWithCheckFailure.PendingUpdate.BeginCheck();
            availableWithCheckFailure.PendingUpdate.Found(
                new("0.9.1", "19", "windows", "x64", "stable", "https://example.invalid/update.nupkg", 12, null, "Notes"), checkToken);
            check(UpdatePresentation.Status(availableWithCheckFailure) == "有可用更新" &&
                UpdatePresentation.ShowsCheckFailureNotice(availableWithCheckFailure) &&
                UpdatePresentation.CheckFailureDetail(availableWithCheckFailure) != null,
                "Available release with a subsequent check failure keeps release heading and surfaces check failure notice");

            var verifyFailed = availableWithCheckFailure.Copy();
            var downloadToken = verifyFailed.PendingUpdate.BeginDownload()!.Value;
            verifyFailed.PendingUpdate.Preparing(downloadToken);
            verifyFailed.PendingUpdate.Fail("signature", "Rejected", downloadToken);
            check(!UpdatePresentation.ShowsCheckFailureNotice(verifyFailed) &&
                UpdatePresentation.CheckFailureDetail(verifyFailed) == null,
                "Non-checking failure suppresses stale check failure notice and detail");

            var deferred = roundTrip.Copy();
            deferred.CheckFailure = roundTrip.CheckFailure! with { RetryAfter = t0.AddMinutes(35) };
            store.Save(deferred);
            check(store.Load(true).CheckFailure?.RetryAfter == t0.AddMinutes(35),
                "Deferred RetryAfter timestamp survives Save/Load");

            var nonPositiveCount = roundTrip.Copy();
            nonPositiveCount.CheckFailure = new(t0, "timeout", 0, "", default(DateTimeOffset));
            store.Save(nonPositiveCount);
            var normalized = store.Load(true).CheckFailure;
            check(normalized?.ConsecutiveFailures == 1 && normalized.RetryAfter == null,
                "Non-positive ConsecutiveFailures and default RetryAfter normalize safely");

            var emptyCategory = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(store.StatePath))!.AsObject();
            emptyCategory["CheckFailure"]!["Category"] = " ";
            File.WriteAllText(store.StatePath, emptyCategory.ToJsonString());
            check(store.Load(true).CheckFailure == null,
                "Blank CheckFailure category degrades safely to no failure instead of rejecting state");
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    private static void AtomicWriteRetries(Action<bool, string> check)
    {
        static IOException SharingViolation() => new("Sharing violation", unchecked((int)0x80070020));
        static IOException LockViolation() => new("Lock violation", unchecked((int)0x80070021));

        var elapsed = TimeSpan.Zero;
        var delays = new List<int>();
        void RecordSleep(TimeSpan delay) { delays.Add((int)delay.TotalMilliseconds); elapsed += delay; }

        var policyAttempts = 0;
        UpdateStore.RetryTransientIo(() => { if (++policyAttempts < 3) throw SharingViolation(); }, RecordSleep, () => elapsed);
        check(policyAttempts == 3 && delays.SequenceEqual(new[] { 10, 50 }),
            "Retry policy succeeds on the third attempt after two sharing violations");

        elapsed = TimeSpan.Zero; delays.Clear();
        var lockAttempts = 0;
        UpdateStore.RetryTransientIo(() => { if (++lockAttempts < 2) throw LockViolation(); }, RecordSleep, () => elapsed);
        check(lockAttempts == 2 && delays.SequenceEqual(new[] { 10 }),
            "Retry policy also retries transient Win32 lock violations");

        elapsed = TimeSpan.Zero; delays.Clear();
        var budgetAttempts = 0; var budgetExceeded = false;
        try
        {
            UpdateStore.RetryTransientIo(() =>
            {
                budgetAttempts++;
                elapsed += TimeSpan.FromMilliseconds(495);
                throw SharingViolation();
            }, RecordSleep, () => elapsed);
        }
        catch (IOException error) when (error.HResult == unchecked((int)0x80070020)) { budgetExceeded = true; }
        check(budgetExceeded && budgetAttempts == 1 && delays.Count == 0,
            "Retry policy stops before sleeping past the total UI wait budget");

        var root = Path.Combine(Path.GetTempPath(), "rawlab-atomic-write-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var target = Path.Combine(root, "state.json");
            byte[] initial = "committed"u8.ToArray(), writtenByTempRetry = "after-temp-retry"u8.ToArray(), writtenByMoveRetry = "after-move-retry"u8.ToArray();
            File.WriteAllBytes(target, initial);

            elapsed = TimeSpan.Zero; delays.Clear();
            int writeCalls = 0, moveCalls = 0;
            UpdateStore.WriteAtomic(target, writtenByTempRetry,
                (temporary, bytes) =>
                {
                    if (++writeCalls <= 2) { File.WriteAllText(temporary, "partial"); throw SharingViolation(); }
                    File.WriteAllBytes(temporary, bytes);
                },
                (source, destination) => { moveCalls++; File.Move(source, destination, true); },
                RecordSleep, () => elapsed);
            check(writeCalls == 3 && moveCalls == 1 && delays.SequenceEqual(new[] { 10, 50 }) &&
                File.ReadAllBytes(target).SequenceEqual(writtenByTempRetry) && Directory.GetFiles(root).Length == 1,
                "Atomic write retries transient sharing conflicts during temporary file creation and removes failed temporaries");

            elapsed = TimeSpan.Zero; delays.Clear();
            writeCalls = 0; moveCalls = 0;
            UpdateStore.WriteAtomic(target, writtenByMoveRetry,
                (temporary, bytes) => { writeCalls++; File.WriteAllBytes(temporary, bytes); },
                (source, destination) =>
                {
                    var call = ++moveCalls;
                    if (call == 1) throw SharingViolation();
                    if (call == 2) throw LockViolation();
                    File.Move(source, destination, true);
                },
                RecordSleep, () => elapsed);
            check(writeCalls == 1 && moveCalls == 3 && delays.SequenceEqual(new[] { 10, 50 }) &&
                File.ReadAllBytes(target).SequenceEqual(writtenByMoveRetry) && Directory.GetFiles(root).Length == 1,
                "Atomic write retries transient replace conflicts without rewriting the flushed temporary file");

            File.WriteAllBytes(target, initial);
            elapsed = TimeSpan.Zero; delays.Clear();
            writeCalls = 0; moveCalls = 0; var exhausted = false;
            try
            {
                UpdateStore.WriteAtomic(target, writtenByMoveRetry,
                    (temporary, bytes) => { writeCalls++; File.WriteAllBytes(temporary, bytes); },
                    (_, _) => { moveCalls++; throw SharingViolation(); },
                    RecordSleep, () => elapsed);
            }
            catch (IOException error) when (error.HResult == unchecked((int)0x80070020)) { exhausted = true; }
            check(exhausted && writeCalls == 1 && moveCalls == 4 && delays.SequenceEqual(new[] { 10, 50, 200 }) &&
                File.ReadAllBytes(target).SequenceEqual(initial) && Directory.GetFiles(root).Length == 1,
                "Exhausted sharing retries propagate IOException, preserve prior state and clean up temporary files");

            foreach (var permanent in new Exception[]
            {
                new UnauthorizedAccessException("Access denied"),
                new IOException("Win32 access denied", unchecked((int)0x80070005)),
                new IOException("Disk full", unchecked((int)0x80070070)),
                new IOException("Handle disk full", unchecked((int)0x80070027)),
                new IOException("Generic I/O failure"),
                new DirectoryNotFoundException("Missing parent"),
                new FileNotFoundException("Missing source")
            })
            {
                elapsed = TimeSpan.Zero; delays.Clear();
                var writeFaultCalls = 0; Exception? caughtWrite = null;
                try
                {
                    UpdateStore.WriteAtomic(target, writtenByMoveRetry,
                        (_, _) => { writeFaultCalls++; throw permanent; },
                        (source, destination) => File.Move(source, destination, true),
                        RecordSleep, () => elapsed);
                }
                catch (Exception error) { caughtWrite = error; }
                check(ReferenceEquals(caughtWrite, permanent) && writeFaultCalls == 1 && delays.Count == 0 &&
                    File.ReadAllBytes(target).SequenceEqual(initial) && Directory.GetFiles(root).Length == 1,
                    "Non-transient write failure is not retried: " + permanent.GetType().Name + ":" + permanent.HResult);

                elapsed = TimeSpan.Zero; delays.Clear();
                var moveFaultCalls = 0; Exception? caughtMove = null;
                try
                {
                    UpdateStore.WriteAtomic(target, writtenByMoveRetry,
                        (temporary, bytes) => File.WriteAllBytes(temporary, bytes),
                        (_, _) => { moveFaultCalls++; throw permanent; },
                        RecordSleep, () => elapsed);
                }
                catch (Exception error) { caughtMove = error; }
                check(ReferenceEquals(caughtMove, permanent) && moveFaultCalls == 1 && delays.Count == 0 &&
                    File.ReadAllBytes(target).SequenceEqual(initial) && Directory.GetFiles(root).Length == 1,
                    "Non-transient replace failure is not retried: " + permanent.GetType().Name + ":" + permanent.HResult);
            }
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }
    }
}
