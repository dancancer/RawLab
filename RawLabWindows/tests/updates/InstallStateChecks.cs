using System.Text.Json;
using RawLab.Windows;

internal static class InstallStateChecks
{
    internal static void Run(Action<bool, string> check)
    {
        var release = new UpdateDescriptor("0.9.1", "19", "windows", "x64", "stable", "https://example.invalid/update.nupkg", 123, null, "Release");
        var defaults = new UpdatePreferences();
        check(defaults.AutomaticCheck && !defaults.AutomaticInstall, "Only checks are enabled by default");
        var state = new UpdateTaskState(); var checkToken = state.BeginCheck();
        check(state.Found(release, checkToken), "Release becomes available");
        check(!state.Verified(checkToken), "Metadata cannot become a verified package");
        var download = state.BeginDownload()!.Value;
        check(state.Received(.7, download) && state.Received(.2, download) && state.Progress == .7, "Progress is monotonic");
        check(!state.Installing(download), "Downloading cannot bypass verification and admission");
        check(state.Preparing(download) && state.Fail("signature", "Rejected", download), "Signature failure retains verification stage");
        check(!state.Verified(download) && state.Phase == UpdatePhase.Failed, "Late success cannot overwrite failure");
        var restored = JsonSerializer.Deserialize<UpdateTaskState>(JsonSerializer.Serialize(state))!;
        restored.RestoreAfterLaunch("0.8.2", "14", true);
        check(restored.Phase == UpdatePhase.Failed && restored.Failure?.Stage == UpdatePhase.Verifying, "Failure survives reopening");
        var next = state.BeginCheck(); state.Found(release, next); var retry = state.BeginDownload()!.Value;
        check(!state.Preparing(download), "Retry invalidates old callbacks");
        state.Preparing(retry); state.Verified(retry);
        check(!state.Admit([]) && !state.Installing(retry), "Prepared package still needs an installation choice");
        state.Choose(UpdateInstallChoice.AfterTasks);
        check(!state.Admit(["draft", "tasks"]) && !state.Installing(retry), "Drafts and tasks block installation");
        check(state.Admit([]) && state.Installing(retry) && state.AwaitingRestart(retry), "Admission dispatches installer without claiming completion");
        restored = JsonSerializer.Deserialize<UpdateTaskState>(JsonSerializer.Serialize(state))!;
        restored.RestoreAfterLaunch(release.Version, release.Build, false);
        check(restored.Phase == UpdatePhase.Failed, "Untrusted matching startup cannot mark success");
        state.RestoreAfterLaunch(release.Version, release.Build, true);
        check(state.Phase == UpdatePhase.Complete, "Trusted target startup completes update");
        var again = state.BeginCheck(); state.Found(release, again); var auto = state.BeginDownload()!.Value;
        state.Preparing(auto); state.Verified(auto); state.Choose(UpdateInstallChoice.AutomaticOnQuit); state.DisableAutomaticInstallation();
        check(state.Phase == UpdatePhase.Available && !state.Installing(auto), "Turning automatic install off revokes the queued attempt");
        var cancelled = state.BeginDownload()!.Value;
        state.BackupPath = "obsolete"; state.PreviousVersion = "0.8.2"; state.PreviousBuild = "14";
        state.Cancel();
        check(!state.Received(1, cancelled) && !state.Preparing(cancelled), "Cancelled callbacks cannot revive state");
        check(state.BackupPath == null && state.PreviousVersion == null && state.PreviousBuild == null,
            "Cancelled attempts release obsolete backup references");

        var gate = new UpdateInstallGate(); var front = new object(); var other = new object();
        var status = new UpdateSessionStatus(Draft: true); var calls = 0; var succeeds = false;
        gate.Register(front, () => new(), () => true);
        gate.Register(other, () => status, () => { calls++; if (succeeds) status = new(); return succeeds; });
        check(gate.Blockers().Contains("draft"), "A background session blocks installation");
        check(gate.Prepare().Contains("draft") && calls == 0, "Admission does not resolve drafts");
        status = new(TasksRunning: true);
        check(gate.Prepare().Contains("tasks") && calls == 0, "Running work is not killed");
        status = new(Unsaved: true);
        check(gate.Blockers().Contains("unsaved") && calls == 0, "Reading update status never saves edits");
        check(gate.Prepare().Contains("save") && calls == 1, "Save failure blocks installation");
        succeeds = true; check(gate.Prepare().Length == 0 && calls == 2, "Explicit admission saves and rechecks committed edits");
        succeeds = false; status = new(JournalFailed: true); check(gate.Prepare().Contains("journal"), "Unsaved journal remains a blocker");
        gate.Unregister(other); check(gate.Blockers().Length == 0, "Closed sessions leave the gate");
    }
}
