namespace RawLab.Windows;

internal enum UnhandledUiDecision { Exit, Continue }

internal delegate UnhandledUiDecision UnhandledUiPrompt(
    Exception error, string? reportPath, bool saveFailed, bool canContinue);

internal sealed class UnhandledExceptionCoordinator
{
    private readonly AIDiagnosticStore store;
    private readonly Func<bool> canContinue;
    private readonly UnhandledUiPrompt prompt;
    private readonly Action<int> shutdown;
    private bool handlingUiException;
    private bool forceExitAfterPrompt;
    private bool shuttingDown;

    internal UnhandledExceptionCoordinator(
        AIDiagnosticStore store,
        Func<bool> canContinue,
        UnhandledUiPrompt prompt,
        Action<int> shutdown)
    {
        this.store = store;
        this.canContinue = canContinue;
        this.prompt = prompt;
        this.shutdown = shutdown;
    }

    internal string? Record(Exception error, string operation)
    {
        try { return store.Capture(error, new(operation, "", 0, CaptureCancellation: true)); }
        catch { return null; }
    }

    internal void HandleUiException(Exception error, string operation = "unhandled.dispatcher")
    {
        var reportPath = Record(error, operation);
        if (shuttingDown) return;
        if (handlingUiException)
        {
            // Modal error reporting pumps the Dispatcher; record cascading UI faults without
            // stacking dialogs and force exit once the active prompt closes.
            forceExitAfterPrompt = true;
            return;
        }

        var saveFailed = false;
        try { saveFailed = AIDiagnosticStore.SaveFailed(error); } catch { }
        var allowedToContinue = false;
        try { allowedToContinue = canContinue(); } catch { }

        var decision = UnhandledUiDecision.Exit;
        handlingUiException = true;
        forceExitAfterPrompt = false;
        try
        {
            decision = prompt(error, reportPath, saveFailed, allowedToContinue);
        }
        catch (Exception promptError)
        {
            if (!ReferenceEquals(promptError, error))
                Record(promptError, "unhandled.prompt");
            decision = UnhandledUiDecision.Exit;
        }
        finally { handlingUiException = false; }

        if (!allowedToContinue || forceExitAfterPrompt)
            decision = UnhandledUiDecision.Exit;

        if (decision == UnhandledUiDecision.Exit && !shuttingDown)
        {
            shuttingDown = true;
            try { shutdown(1); } catch { }
        }
    }

    internal string? HandleUnobservedTaskException(UnobservedTaskExceptionEventArgs e)
    {
        try { e.SetObserved(); } catch { }
        var flattened = e.Exception.Flatten();
        var target = flattened.InnerExceptions.Count == 1 ? flattened.InnerExceptions[0] : flattened;
        return Record(target, "unhandled.task");
    }

    internal string? HandleAppDomainException(UnhandledExceptionEventArgs e)
    {
        var error = e.ExceptionObject as Exception
            ?? new InvalidOperationException($"Non-Exception unhandled object: {e.ExceptionObject ?? "<null>"}");
        return Record(error, "unhandled.appdomain");
    }
}
