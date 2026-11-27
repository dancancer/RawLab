namespace RawLab.Windows;

/// <summary>
/// WPF-free observable state machine for on-demand AI model download, verification, installation, and removal.
/// Never starts network work implicitly; only explicit user actions trigger downloads.
/// </summary>
internal sealed class AIModelPackageManager
{
    private readonly object gate = new();
    private readonly Func<bool> isRuntimeSupported;
    private readonly Func<bool> isHardwareAvailable;
    private readonly Func<string?> overrideProvider;
    private readonly Func<string?> bundledProvider;
    private readonly Action<Action> dispatch;

    private AIModelPackageState state = AIModelPackageState.Unavailable();
    private CancellationTokenSource? activeCancellation;
    private TaskCompletionSource? activeCompletion;

    internal AIModelPackageStore Store { get; }

    internal AIModelPackageState State
    {
        get { lock (gate) return state; }
    }

    internal event Action<AIModelPackageState>? StateChanged;
    internal event Action? InstallStateChanged;

    internal AIModelPackageManager(
        AIModelPackageStore store,
        Func<bool> isRuntimeSupported,
        Func<bool>? isHardwareAvailable = null,
        Func<string?>? overrideProvider = null,
        Func<string?>? bundledProvider = null,
        Action<Action>? dispatch = null)
    {
        Store = store;
        this.isRuntimeSupported = isRuntimeSupported;
        this.isHardwareAvailable = isHardwareAvailable ?? (() => true);
        this.overrideProvider = overrideProvider ?? (() => null);
        this.bundledProvider = bundledProvider ?? (() => null);
        this.dispatch = dispatch ?? (action => action());
        Refresh();
    }

    internal void Refresh()
    {
        AIModelPackageState? next;
        lock (gate)
        {
            if (state.IsBusy) return;
            next = ComputeDiskStateLocked();
            if (next == state) return;
            state = next;
        }
        NotifyStateChanged(next);
    }

    /// <summary>
    /// 仅由用户显式点击“下载模型”或“重试”触发。
    /// </summary>
    internal void StartDownload()
    {
        AIModelPackageDescriptor? maybeDescriptor = null;
        CancellationTokenSource? maybeCancellation = null;
        TaskCompletionSource? maybeCompletion = null;
        var wasInstalled = false;
        AIModelPackageState? initialState = null;
        AIModelPackageState? rejectedState = null;

        lock (gate)
        {
            if (state.IsBusy || state.IsInstalled || !isRuntimeSupported() || Store.Descriptor == null) return;
            if (!isHardwareAvailable())
            {
                var refreshed = ComputeDiskStateLocked();
                if (refreshed != state)
                {
                    state = refreshed;
                    rejectedState = refreshed;
                }
            }
            else
            {
                maybeDescriptor = Store.Descriptor;
                wasInstalled = state.IsInstalled;
                maybeCancellation = new CancellationTokenSource();
                maybeCompletion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                activeCancellation = maybeCancellation;
                activeCompletion = maybeCompletion;
                initialState = AIModelPackageState.Downloading(0, maybeDescriptor.ArchiveBytes, maybeDescriptor.UnpackedBytes);
                state = initialState;
            }
        }

        if (rejectedState != null)
        {
            NotifyStateChanged(rejectedState);
            return;
        }
        if (initialState == null || maybeDescriptor == null || maybeCancellation == null || maybeCompletion == null) return;
        var descriptor = maybeDescriptor;
        var cancellation = maybeCancellation;
        var completion = maybeCompletion;

        NotifyStateChanged(initialState);

        _ = Task.Run(async () =>
        {
            try
            {
                _ = await Store.DownloadAndInstallAsync(cancellation.Token, phase =>
                {
                    AIModelPackageState? progressState = null;
                    lock (gate)
                    {
                        if (!ReferenceEquals(activeCancellation, cancellation) || cancellation.IsCancellationRequested)
                            return;
                        progressState = phase.Kind switch
                        {
                            AIModelInstallPhaseKind.Downloading => AIModelPackageState.Downloading(phase.CompletedBytes, phase.TotalBytes, descriptor.UnpackedBytes),
                            AIModelInstallPhaseKind.Verifying => AIModelPackageState.Verifying(descriptor.ArchiveBytes, descriptor.UnpackedBytes),
                            AIModelInstallPhaseKind.Installing => AIModelPackageState.Installing(descriptor.ArchiveBytes, descriptor.UnpackedBytes),
                            _ => state,
                        };
                        if (progressState == state) return;
                        state = progressState;
                    }
                    NotifyStateChanged(progressState);
                }).ConfigureAwait(false);

                AIModelPackageState finalState;
                bool notifyInstallChange;
                lock (gate)
                {
                    if (!ReferenceEquals(activeCancellation, cancellation)) return;
                    activeCancellation = null;
                    finalState = ComputeDiskStateLocked();
                    state = finalState;
                    notifyInstallChange = finalState.IsInstalled != wasInstalled || finalState.IsInstalled;
                }
                cancellation.Dispose();
                if (notifyInstallChange) NotifyInstallStateChanged();
                NotifyStateChanged(finalState);
            }
            catch (Exception error)
            {
                var mapped = error switch
                {
                    AIModelPackageException pkg => pkg,
                    OperationCanceledException => new AIModelPackageException(AIModelPackageErrorCode.Cancelled),
                    _ when cancellation.IsCancellationRequested => new AIModelPackageException(AIModelPackageErrorCode.Cancelled),
                    _ => new AIModelPackageException(AIModelPackageErrorCode.FileSystemError, error.Message, innerException: error),
                };

                AIModelPackageState finalState;
                var notifyInstallChange = false;
                lock (gate)
                {
                    if (!ReferenceEquals(activeCancellation, cancellation)) return;
                    activeCancellation = null;
                    if (mapped.Code == AIModelPackageErrorCode.Cancelled || cancellation.IsCancellationRequested)
                    {
                        // 取消若发生在最终原子改名窗口内，以磁盘真实结果为准，不误报已取消。
                        if (Store.ResolveModelDirectory(overrideProvider(), bundledProvider()) is { } resolved)
                        {
                            finalState = AIModelPackageState.Installed(resolved, descriptor.UnpackedBytes);
                            notifyInstallChange = !wasInstalled;
                        }
                        else
                        {
                            finalState = AIModelPackageState.Cancelled(descriptor.ArchiveBytes, descriptor.UnpackedBytes);
                        }
                    }
                    else
                    {
                        finalState = AIModelPackageState.Failed(mapped, descriptor.ArchiveBytes, descriptor.UnpackedBytes);
                    }
                    state = finalState;
                }
                cancellation.Dispose();
                if (notifyInstallChange) NotifyInstallStateChanged();
                NotifyStateChanged(finalState);
            }
            finally
            {
                lock (gate)
                {
                    if (ReferenceEquals(activeCompletion, completion))
                        activeCompletion = null;
                }
                completion.TrySetResult();
            }
        });
    }

    internal void CancelDownload()
    {
        CancellationTokenSource? cancellation;
        lock (gate) cancellation = activeCancellation;
        try { cancellation?.Cancel(); }
        catch (ObjectDisposedException) { }
    }

    internal void RemoveDownloadedModel()
    {
        lock (gate)
        {
            if (state.IsBusy) return;
        }

        AIModelPackageState nextState;
        var removed = false;
        try
        {
            Store.RemoveInstalledPackages();
            lock (gate)
            {
                nextState = ComputeDiskStateLocked();
                state = nextState;
                removed = true;
            }
        }
        catch (Exception error)
        {
            var mapped = error as AIModelPackageException
                ?? new AIModelPackageException(AIModelPackageErrorCode.RemoveFailed, error.Message, innerException: error);
            lock (gate)
            {
                var diskState = ComputeDiskStateLocked();
                if (diskState.IsInstalled && diskState.InstalledSource is { } source)
                {
                    nextState = AIModelPackageState.Installed(source, diskState.UnpackedBytes, mapped);
                }
                else if (Store.Descriptor is { } descriptor && isRuntimeSupported() && isHardwareAvailable())
                {
                    nextState = AIModelPackageState.Failed(mapped, descriptor.ArchiveBytes, descriptor.UnpackedBytes);
                }
                else
                {
                    nextState = diskState;
                }
                state = nextState;
            }
        }

        NotifyStateChanged(nextState);
        if (removed) NotifyInstallStateChanged();
    }

    internal Task ActiveCompletion
    {
        get { lock (gate) return activeCompletion?.Task ?? Task.CompletedTask; }
    }

    private AIModelPackageState ComputeDiskStateLocked()
    {
        if (!isRuntimeSupported())
            return AIModelPackageState.Unavailable();
        var unpackedBytes = Store.Descriptor?.UnpackedBytes ?? 0;
        if (Store.ResolveModelDirectory(overrideProvider(), bundledProvider()) is { } source)
            return AIModelPackageState.Installed(source, unpackedBytes);
        if (!isHardwareAvailable() || Store.Descriptor is not { } descriptor)
            return AIModelPackageState.Unavailable();
        return AIModelPackageState.NotInstalled(descriptor.ArchiveBytes, descriptor.UnpackedBytes);
    }

    private void NotifyStateChanged(AIModelPackageState snapshot) =>
        dispatch(() => StateChanged?.Invoke(snapshot));

    private void NotifyInstallStateChanged() =>
        dispatch(() => InstallStateChanged?.Invoke());
}
