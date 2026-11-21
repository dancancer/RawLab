using System.IO;

namespace RawLab.Windows;

public sealed class UpdatePackageRejectedException(string code, string message, Exception? innerException = null) : Exception(message, innerException)
{
    public string Code { get; } = string.IsNullOrEmpty(code) ? "verification" : code;
}

public interface IDesktopUpdateAdapter
{
    string? UnavailableReason { get; }
    Task ValidateHostTrustAsync() => UnavailableReason == null ? Task.CompletedTask : Task.FromException(new InvalidDataException(UnavailableReason));
    Task<UpdateDescriptor?> CheckAsync(CancellationToken token);
    Task DownloadAsync(UpdateDescriptor release, Action<int> progress, CancellationToken token);
    Task VerifyAsync(UpdateDescriptor release, CancellationToken token);
    void VerifyBeforeInstall(UpdateDescriptor release) { }
    void Install(UpdateDescriptor release, bool restart);
}

public sealed class UnavailableUpdateAdapter(string reason) : IDesktopUpdateAdapter
{
    public string? UnavailableReason => reason;
    public Task<UpdateDescriptor?> CheckAsync(CancellationToken token) => throw new InvalidOperationException(reason);
    public Task DownloadAsync(UpdateDescriptor release, Action<int> progress, CancellationToken token) => throw new InvalidOperationException(reason);
    public Task VerifyAsync(UpdateDescriptor release, CancellationToken token) => throw new InvalidOperationException(reason);
    public void VerifyBeforeInstall(UpdateDescriptor release) => throw new InvalidOperationException(reason);
    public void Install(UpdateDescriptor release, bool restart) => throw new InvalidOperationException(reason);
}
