using System.IO;
using System.Runtime.InteropServices;
using Velopack;
using Velopack.Locators;

namespace RawLab.Windows;

public interface IDesktopUpdateAdapter
{
    string? UnavailableReason { get; }
    Task ValidateHostTrustAsync() => UnavailableReason == null ? Task.CompletedTask : Task.FromException(new InvalidDataException(UnavailableReason));
    Task<UpdateDescriptor?> CheckAsync(CancellationToken token);
    Task DownloadAsync(UpdateDescriptor release, Action<int> progress, CancellationToken token);
    Task VerifyAsync(UpdateDescriptor release, CancellationToken token);
    void Install(UpdateDescriptor release, bool restart);
}

public sealed class UnavailableUpdateAdapter(string reason) : IDesktopUpdateAdapter
{
    public string? UnavailableReason => reason;
    public Task<UpdateDescriptor?> CheckAsync(CancellationToken token) => throw new InvalidOperationException(reason);
    public Task DownloadAsync(UpdateDescriptor release, Action<int> progress, CancellationToken token) => throw new InvalidOperationException(reason);
    public Task VerifyAsync(UpdateDescriptor release, CancellationToken token) => throw new InvalidOperationException(reason);
    public void Install(UpdateDescriptor release, bool restart) => throw new InvalidOperationException(reason);
}

public sealed class VelopackUpdateAdapter : IDesktopUpdateAdapter
{
    public string? UnavailableReason => null;
    private readonly UpdateTrustConfiguration trust;
    private readonly IVelopackLocator locator;
    private readonly SignedUpdateSource source;
    private readonly UpdateManager manager;
    private UpdateInfo? update;
    private string? verifiedIdentity;

    private VelopackUpdateAdapter(UpdateTrustConfiguration trust, IVelopackLocator locator, string currentVersion)
    {
        this.trust = trust; this.locator = locator;
        source = new SignedUpdateSource(trust, currentVersion);
        manager = new UpdateManager(source, new UpdateOptions { AllowVersionDowngrade = false, ExplicitChannel = "stable", MaximumDeltasBeforeFallback = -1 }, locator);
    }
    public static IDesktopUpdateAdapter Create(string currentVersion)
    {
        var trust = UpdateTrustConfiguration.Load();
        if (trust == null) return new UnavailableUpdateAdapter("configuration");
        if (!OperatingSystem.IsWindows() || RuntimeInformation.ProcessArchitecture != Architecture.X64) return new UnavailableUpdateAdapter("architecture");
        var locator = VelopackLocator.Current;
        if (locator.AppId != "RawLab.Desktop" || locator.CurrentlyInstalledVersion == null || locator.IsPortable || locator.Channel != "stable")
            return new UnavailableUpdateAdapter("installation");
        var local = Path.GetFullPath(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)) + Path.DirectorySeparatorChar;
        if (locator.RootAppDir == null || !Path.GetFullPath(locator.RootAppDir).StartsWith(local, StringComparison.OrdinalIgnoreCase) ||
            locator.AppContentDir == null || locator.UpdateExePath == null) return new UnavailableUpdateAdapter("installation");
        return new VelopackUpdateAdapter(trust, locator, currentVersion);
    }
    public Task ValidateHostTrustAsync()
    {
        if (string.IsNullOrEmpty(trust.PublisherKeySha256)) return Task.CompletedTask;
        return Task.Run(() => {
            AuthenticodeTrust.Verify(Path.Combine(locator.AppContentDir!, "RawLab.exe"), trust.PublisherKeySha256);
            AuthenticodeTrust.Verify(Path.Combine(locator.AppContentDir!, "RawLab.dll"), trust.PublisherKeySha256);
            AuthenticodeTrust.Verify(locator.UpdateExePath!, trust.PublisherKeySha256);
        }).WaitAsync(TimeSpan.FromSeconds(30));
    }
    public async Task<UpdateDescriptor?> CheckAsync(CancellationToken token)
    {
        await ValidateHostTrustAsync(); token.ThrowIfCancellationRequested();
        verifiedIdentity = null; source.CheckCancellation = token;
        update = await manager.CheckForUpdatesAsync(); token.ThrowIfCancellationRequested();
        return update == null ? null : source.Manifest?.Descriptor ?? throw new InvalidDataException("Missing signed descriptor");
    }
    public async Task DownloadAsync(UpdateDescriptor release, Action<int> progress, CancellationToken token)
    {
        Require(release); verifiedIdentity = null;
        await manager.DownloadUpdatesAsync(update!, progress, token); token.ThrowIfCancellationRequested();
    }
    public async Task VerifyAsync(UpdateDescriptor release, CancellationToken token)
    {
        Require(release); var path = PackagePath();
        await Task.Run(() => { token.ThrowIfCancellationRequested(); UpdatePackageVerifier.Verify(path, source.Manifest!, trust.PublisherKeySha256); token.ThrowIfCancellationRequested(); }, token);
        verifiedIdentity = release.Identity;
    }
    public void Install(UpdateDescriptor release, bool restart)
    {
        Require(release);
        if (verifiedIdentity != release.Identity || source.Manifest!.ExpiresAt <= DateTimeOffset.UtcNow) throw new InvalidDataException("Reverify the package before installation");
        UpdatePackageVerifier.Verify(PackagePath(), source.Manifest, trust.PublisherKeySha256);
        if (!string.IsNullOrEmpty(trust.PublisherKeySha256)) AuthenticodeTrust.Verify(locator.UpdateExePath!, trust.PublisherKeySha256);
        // 框架等待本进程正常退出；不调用会立即结束进程的 ApplyUpdatesAndRestart。
        manager.WaitExitThenApplyUpdates(update!.TargetFullRelease, silent: true, restart: restart);
    }
    private void Require(UpdateDescriptor release)
    {
        if (update == null || source.Manifest?.Descriptor.Identity != release.Identity) throw new InvalidDataException("Recheck update metadata");
    }
    private string PackagePath() => Path.Combine(locator.PackagesDir ?? throw new InvalidDataException("Missing package directory"), source.Manifest!.FileName);
}
