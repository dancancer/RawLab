using System.Text.Json.Serialization;

namespace RawLab.Windows;

public enum UpdatePhase { Idle, Checking, Available, Downloading, Verifying, PackageReady, WaitingForTasks, ReadyToInstall, Installing, PendingRestart, Complete, Failed }
public enum UpdateInstallChoice { None, RestartNow, AfterTasks, OnQuit, AutomaticOnQuit }
public sealed record UpdateDescriptor(string Version, string Build, string Platform, string Architecture, string Channel,
    string AssetUrl, long Size, string? Sha256, string Notes)
{
    public string Identity => string.Join("|", Platform, Architecture, Channel, Version, Build, AssetUrl, Sha256 ?? "");
}
public sealed record UpdateFailure(UpdatePhase Stage, string Code, string Detail);

public sealed class UpdateTaskState
{
    public int Format { get; set; } = 1;
    [JsonInclude] public UpdatePhase Phase { get; private set; }
    [JsonInclude] public Guid Attempt { get; private set; } = Guid.NewGuid();
    [JsonInclude] public UpdateDescriptor? Release { get; private set; }
    [JsonInclude] public UpdateFailure? Failure { get; private set; }
    [JsonInclude] public UpdateInstallChoice Choice { get; private set; }
    [JsonInclude] public double Progress { get; private set; }
    [JsonInclude] public string[] Blockers { get; private set; } = [];
    public string? BackupPath { get; set; }
    public string? PreviousVersion { get; set; }
    public string? PreviousBuild { get; set; }

    public Guid BeginCheck()
    {
        if (Release == null || Choice is not (UpdateInstallChoice.OnQuit or UpdateInstallChoice.AutomaticOnQuit)) { Choice = UpdateInstallChoice.None; Release = null; }
        Attempt = Guid.NewGuid(); Phase = UpdatePhase.Checking; Failure = null;
        Progress = 0; Blockers = []; BackupPath = null; PreviousVersion = null; PreviousBuild = null; return Attempt;
    }
    public bool Found(UpdateDescriptor? release, Guid token)
    {
        if (!Accepts(token, UpdatePhase.Checking)) return false;
        if (release?.Identity != Release?.Identity) Choice = UpdateInstallChoice.None;
        Release = release; Phase = release == null ? UpdatePhase.Idle : UpdatePhase.Available; return true;
    }
    public Guid? BeginDownload()
    {
        if (Phase != UpdatePhase.Available || Release == null) return null;
        Attempt = Guid.NewGuid(); Phase = UpdatePhase.Downloading; Failure = null; Progress = 0; return Attempt;
    }
    public bool Received(double fraction, Guid token)
    {
        if (!Accepts(token, UpdatePhase.Downloading) || !double.IsFinite(fraction)) return false;
        Progress = Math.Clamp(fraction, Progress, 1); return true;
    }
    public bool Preparing(Guid token)
    {
        if (!Accepts(token, UpdatePhase.Downloading)) return false;
        Phase = UpdatePhase.Verifying; Progress = 1; return true;
    }
    public bool Verified(Guid token)
    {
        if (!Accepts(token, UpdatePhase.Verifying)) return false;
        Phase = UpdatePhase.PackageReady; return true;
    }
    public bool Choose(UpdateInstallChoice choice)
    {
        if (!Prepared || choice == UpdateInstallChoice.None) return false;
        Choice = choice; return true;
    }
    public bool Admit(string[] reasons)
    {
        if (!Prepared || Choice == UpdateInstallChoice.None) return false;
        Blockers = reasons; Phase = reasons.Length == 0 ? UpdatePhase.ReadyToInstall : UpdatePhase.WaitingForTasks;
        return reasons.Length == 0;
    }
    public bool Installing(Guid token)
    {
        if (!Accepts(token, UpdatePhase.ReadyToInstall) || Choice == UpdateInstallChoice.None || Blockers.Length != 0) return false;
        Phase = UpdatePhase.Installing; return true;
    }
    public bool AwaitingRestart(Guid token)
    {
        if (!Accepts(token, UpdatePhase.Installing)) return false;
        Phase = UpdatePhase.PendingRestart; return true;
    }
    public bool Fail(string code, string detail, Guid token)
    {
        if (token != Attempt || Phase is UpdatePhase.Idle or UpdatePhase.Available or UpdatePhase.Complete or UpdatePhase.Failed) return false;
        if (Phase != UpdatePhase.Checking) Choice = UpdateInstallChoice.None;
        Failure = new(Phase, code, detail); Phase = UpdatePhase.Failed;
        Attempt = Guid.NewGuid(); Blockers = []; return true;
    }
    public void Cancel(bool preservingChoice = false)
    {
        if (Phase is UpdatePhase.Installing or UpdatePhase.PendingRestart) return;
        Attempt = Guid.NewGuid(); Phase = Release == null ? UpdatePhase.Idle : UpdatePhase.Available;
        if (!preservingChoice) Choice = UpdateInstallChoice.None;
        Failure = null; Progress = 0; Blockers = [];
        BackupPath = null; PreviousVersion = null; PreviousBuild = null;
    }
    public void DisableAutomaticInstallation() { if (Choice == UpdateInstallChoice.AutomaticOnQuit) Cancel(); }
    public void RestoreAfterLaunch(string version, string build, bool trusted)
    {
        Attempt = Guid.NewGuid(); Blockers = [];
        if (Phase is not (UpdatePhase.Available or UpdatePhase.Checking) && !(Phase == UpdatePhase.Failed && Failure?.Stage == UpdatePhase.Checking)) Choice = UpdateInstallChoice.None;
        if (Phase is UpdatePhase.Failed or UpdatePhase.Complete or UpdatePhase.Idle or UpdatePhase.Available) return;
        if (Phase is (UpdatePhase.Installing or UpdatePhase.PendingRestart) && trusted && Release?.Version == version && Release?.Build == build)
        { Phase = UpdatePhase.Complete; Failure = null; BackupPath = null; PreviousVersion = null; PreviousBuild = null; }
        else { Failure = new(Phase, "interrupted", ""); Phase = UpdatePhase.Failed; }
    }
    [JsonIgnore] public bool Prepared => Phase is UpdatePhase.PackageReady or UpdatePhase.WaitingForTasks or UpdatePhase.ReadyToInstall;
    private bool Accepts(Guid token, UpdatePhase phase) => Attempt == token && Phase == phase;
    public UpdateTaskState Copy()
    {
        var result = (UpdateTaskState)MemberwiseClone(); result.Blockers = (string[])Blockers.Clone(); return result;
    }
}

public sealed class UpdatePreferences
{
    public bool AutomaticCheck { get; set; } = true;
    public bool AutomaticInstall { get; set; }
    public string? SkippedVersion { get; set; }
    public DateTimeOffset? RemindAfter { get; set; }
    public DateTimeOffset? LastCheck { get; set; }
    public string Channel { get; set; } = "stable";
    public UpdateTaskState PendingUpdate { get; set; } = new();
    public string? RecoveryReceipt { get; set; }
    public UpdateStateRepairReceipt? StateRepairReceipt { get; set; }
    public UpdatePreferences Copy() => new() { AutomaticCheck = AutomaticCheck, AutomaticInstall = AutomaticInstall,
        SkippedVersion = SkippedVersion, RemindAfter = RemindAfter, LastCheck = LastCheck, Channel = Channel, PendingUpdate = PendingUpdate.Copy(), RecoveryReceipt = RecoveryReceipt, StateRepairReceipt = StateRepairReceipt };
}

public sealed record UpdateStateRepairReceipt(Guid Id, string Sha256);
