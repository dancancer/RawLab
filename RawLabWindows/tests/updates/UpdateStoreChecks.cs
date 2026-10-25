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
        StateRepair(check);
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
                check(Rejected(() => store.Load(false)) && Rejected(() => store.RepairableState()), "Future enum state cannot open editing or be reset: " + field);
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
            File.WriteAllBytes(store.StatePath, damaged); var backups = Path.Combine(store.DirectoryPath, "Backups");
            Directory.CreateDirectory(Path.Combine(backups, "prior"));
            check(Rejected(() => store.RepairableState()), "Installation evidence blocks uncertain state repair");
            Directory.Delete(backups, true); File.WriteAllText(Path.Combine(store.DirectoryPath, "recovery-in-progress.json"), "journal");
            check(Rejected(() => store.RepairableState()) && File.ReadAllBytes(store.StatePath).SequenceEqual(damaged),
                "An interrupted recovery remains blocked without changing damaged state");
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }
}
