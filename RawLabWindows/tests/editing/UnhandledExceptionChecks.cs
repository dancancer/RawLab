using System.IO.Compression;
using System.Text.Json;
using RawLab.Windows;

internal static class UnhandledExceptionChecks
{
    private static readonly UnhandledUiState InteractiveState =
        new(StartupCompleted: true, HasShutdownStarted: false, HasShutdownFinished: false, HasInteractiveEditor: true);

    internal static void Run()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-unhandled-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        static void Check(bool value, string message) { if (!value) throw new Exception(message); }

        try
        {
            // 1. UI unhandled exception when editor is interactive: recorded, redacted, exportable,
            //    prompts user with canContinue=true, and Continue neither throws nor exits.
            var uiStore = new AIDiagnosticStore(Path.Combine(root, "ui-continue"));
            var prompts = 0;
            var shutdownCodes = new List<int>();
            string? promptedReport = null;
            var promptedSaveFailed = true;
            var promptedCanContinue = false;
            var continueCoordinator = new UnhandledExceptionCoordinator(
                uiStore,
                () => InteractiveState,
                (_, reportPath, saveFailed, canContinue) =>
                {
                    prompts++;
                    promptedReport = reportPath;
                    promptedSaveFailed = saveFailed;
                    promptedCanContinue = canContinue;
                    return UnhandledUiDecision.Continue;
                },
                shutdownCodes.Add);

            const string privatePath = @"D:\Private Photos\未公开样片.ARW";
            continueCoordinator.HandleUiException(
                new InvalidOperationException("Dispatcher crash 0x80004003 while opening " + privatePath));
            Check(prompts == 1 && promptedCanContinue && !promptedSaveFailed && promptedReport != null && File.Exists(promptedReport),
                "UI unhandled exception was not recorded before prompting");
            Check(shutdownCodes.Count == 0, "Choosing Continue unexpectedly shut down the process");
            var uiJson = File.ReadAllText(promptedReport!);
            using (var doc = JsonDocument.Parse(uiJson))
            {
                Check(doc.RootElement.GetProperty("operation").GetString() == "unhandled.dispatcher",
                    "UI unhandled exception report lost its operation tag");
                Check(doc.RootElement.GetProperty("error_type").GetString() == typeof(InvalidOperationException).FullName,
                    "UI unhandled exception report lost its exception type");
            }
            Check(!uiJson.Contains("Private Photos") && !uiJson.Contains("未公开样片") && uiJson.Contains("0x80004003"),
                "UI unhandled exception report leaked personal path or lost HRESULT");
            var exportedZip = Path.Combine(root, "ui-diagnostic.zip");
            uiStore.Export(promptedReport!, exportedZip);
            using (var archive = ZipFile.OpenRead(exportedZip))
            {
                Check(archive.GetEntry("diagnostic.json") != null && archive.Entries.Count == 3,
                    "Unhandled exception report cannot be exported through AIDiagnosticStore.Export");
            }

            // 2. UI unhandled exception choosing Exit + post-shutdown suppression:
            //    exits once with code 1; late exceptions during shutdown are still recorded without re-prompting.
            var exitStore = new AIDiagnosticStore(Path.Combine(root, "ui-exit"));
            var exitPrompts = 0;
            var exitCodes = new List<int>();
            var exitCoordinator = new UnhandledExceptionCoordinator(
                exitStore,
                () => InteractiveState,
                (_, _, _, _) => { exitPrompts++; return UnhandledUiDecision.Exit; },
                exitCodes.Add);
            exitCoordinator.HandleUiException(new ApplicationException("fatal UI state"));
            exitCoordinator.HandleUiException(new ApplicationException("secondary fault while shutting down"));
            Check(exitPrompts == 1 && exitCodes.SequenceEqual([1]),
                "Choosing Exit did not shut down cleanly once with code 1");
            Check(Directory.GetFiles(exitStore.DirectoryPath, "*.json").Length == 2,
                "Late exception during shutdown was lost instead of recorded");

            // 3. Non-interactive UI states (startup incomplete, shutdown started/finished, recovery/closing window,
            //    or throwing state reader): classify operation, disable Continue, defer shutdown until prompt closes,
            //    and force exit code 1 even if prompt returns Continue.
            (string CaseName, Func<UnhandledUiState> StateReader, string ExpectedOperation)[] nonContinuableCases =
            [
                ("startup-incomplete", () => new(StartupCompleted: false, HasShutdownStarted: false, HasShutdownFinished: false, HasInteractiveEditor: true), "unhandled.startup"),
                ("shutdown-started", () => new(StartupCompleted: true, HasShutdownStarted: true, HasShutdownFinished: false, HasInteractiveEditor: true), "unhandled.dispatcher"),
                ("shutdown-finished", () => new(StartupCompleted: true, HasShutdownStarted: false, HasShutdownFinished: true, HasInteractiveEditor: true), "unhandled.dispatcher"),
                ("non-interactive-window", () => new(StartupCompleted: true, HasShutdownStarted: false, HasShutdownFinished: false, HasInteractiveEditor: false), "unhandled.dispatcher"),
                ("faulting-state-reader", () => throw new InvalidOperationException("dispatcher state unavailable"), "unhandled.startup"),
            ];
            foreach (var (caseName, stateReader, expectedOperation) in nonContinuableCases)
            {
                var stateStore = new AIDiagnosticStore(Path.Combine(root, caseName));
                var stateCodes = new List<int>();
                var canContinueSeen = true;
                var shutdownPremature = false;
                var stateCoordinator = new UnhandledExceptionCoordinator(
                    stateStore,
                    stateReader,
                    (_, _, _, canContinue) =>
                    {
                        canContinueSeen = canContinue;
                        shutdownPremature = stateCodes.Count != 0;
                        return UnhandledUiDecision.Continue;
                    },
                    stateCodes.Add);
                stateCoordinator.HandleUiException(new InvalidOperationException(caseName));
                var stateReport = stateStore.Latest();
                Check(!canContinueSeen && !shutdownPremature && stateCodes.SequenceEqual([1]) && stateReport != null,
                    $"Non-continuable UI state '{caseName}' failed to defer and force exit code 1");
                using var doc = JsonDocument.Parse(File.ReadAllText(stateReport!));
                Check(doc.RootElement.GetProperty("operation").GetString() == expectedOperation,
                    $"Non-continuable UI state '{caseName}' recorded wrong operation tag");
            }

            // 4. Re-entrant UI exception while modal prompt is open + prompt throwing itself:
            //    records cascading exception, suppresses nested dialogs, and forces Exit.
            var reentrantStore = new AIDiagnosticStore(Path.Combine(root, "reentrant"));
            var reentrantPrompts = 0;
            var reentrantCodes = new List<int>();
            UnhandledExceptionCoordinator? reentrantCoordinator = null;
            reentrantCoordinator = new UnhandledExceptionCoordinator(
                reentrantStore,
                () => InteractiveState,
                (_, _, _, _) =>
                {
                    reentrantPrompts++;
                    reentrantCoordinator!.HandleUiException(new InvalidOperationException("timer tick fault inside modal loop"));
                    return UnhandledUiDecision.Continue;
                },
                reentrantCodes.Add);
            reentrantCoordinator.HandleUiException(new InvalidOperationException("initial UI fault"));
            Check(reentrantPrompts == 1 && reentrantCodes.SequenceEqual([1]) &&
                  Directory.GetFiles(reentrantStore.DirectoryPath, "*.json").Length == 2,
                "Cascading UI exception during modal prompt stacked dialogs or allowed continuing");

            var brokenPromptStore = new AIDiagnosticStore(Path.Combine(root, "broken-prompt"));
            var brokenPromptCodes = new List<int>();
            var brokenPromptCoordinator = new UnhandledExceptionCoordinator(
                brokenPromptStore,
                () => InteractiveState,
                (_, _, _, _) => throw new InvalidOperationException("WPF dialog creation failed"),
                brokenPromptCodes.Add);
            brokenPromptCoordinator.HandleUiException(new InvalidOperationException("original crash"));
            Check(brokenPromptCodes.SequenceEqual([1]) &&
                  Directory.GetFiles(brokenPromptStore.DirectoryPath, "*.json").Length == 2,
                "Throwing prompt masked original crash or failed to exit");

            // 5. Unhandled OperationCanceledException capture vs ordinary AI cancellation:
            var cancelStore = new AIDiagnosticStore(Path.Combine(root, "cancellation"));
            var cancelCoordinator = new UnhandledExceptionCoordinator(
                cancelStore,
                () => InteractiveState,
                (_, _, _, _) => UnhandledUiDecision.Continue,
                _ => throw new Exception("Continue must not shut down"));
            cancelCoordinator.HandleUiException(new TaskCanceledException("unexpected cancellation escaped async void"));
            var cancelReport = cancelStore.Latest();
            Check(cancelReport != null &&
                  JsonDocument.Parse(File.ReadAllText(cancelReport)).RootElement.GetProperty("error_type").GetString() == typeof(TaskCanceledException).FullName,
                "Unhandled cancellation escaping to global hook was not recorded");
            Check(cancelStore.Capture(new OperationCanceledException(), new("prepare", "", 2)) == null,
                "Ordinary AI task cancellation should still be ignored by AIDiagnosticStore");

            // 6. Background TaskScheduler.UnobservedTaskException:
            //    marks Observed, unwraps single inner exception, records without prompting or exiting.
            var bgStore = new AIDiagnosticStore(Path.Combine(root, "bg-task"));
            var bgCoordinator = new UnhandledExceptionCoordinator(
                bgStore,
                () => InteractiveState,
                (_, _, _, _) => throw new Exception("Background unobserved task must not block on UI prompt"),
                _ => throw new Exception("Background unobserved task must not shut down the app"));
            var unobservedArgs = new UnobservedTaskExceptionEventArgs(
                new AggregateException(new InvalidOperationException("background thumbnail task fault")));
            var bgReport = bgCoordinator.HandleUnobservedTaskException(unobservedArgs);
            Check(unobservedArgs.Observed && bgReport != null && File.Exists(bgReport),
                "UnobservedTaskException was not marked Observed or was not recorded");
            using (var doc = JsonDocument.Parse(File.ReadAllText(bgReport!)))
            {
                Check(doc.RootElement.GetProperty("operation").GetString() == "unhandled.task" &&
                      doc.RootElement.GetProperty("error_type").GetString() == typeof(InvalidOperationException).FullName,
                    "Single-fault UnobservedTaskException did not unwrap inner exception type");
            }
            var multiArgs = new UnobservedTaskExceptionEventArgs(
                new AggregateException(new IOException("io-1"), new InvalidDataException("data-2")));
            var multiReport = bgCoordinator.HandleUnobservedTaskException(multiArgs);
            Check(multiArgs.Observed && multiReport != null &&
                  File.ReadAllText(multiReport).Contains("io-1") && File.ReadAllText(multiReport).Contains("data-2"),
                "Multi-fault UnobservedTaskException lost one of its inner exceptions");

            // 7. AppDomain.UnhandledException & diagnostic I/O failure resilience:
            var domainStore = new AIDiagnosticStore(Path.Combine(root, "appdomain"));
            var domainCoordinator = new UnhandledExceptionCoordinator(
                domainStore,
                () => InteractiveState,
                (_, _, _, _) => throw new Exception("Terminating AppDomain handler must not pump UI"),
                _ => throw new Exception("Terminating AppDomain handler must not call Dispatcher Shutdown"));
            var domainReport = domainCoordinator.HandleAppDomainException(
                new UnhandledExceptionEventArgs(new AccessViolationException("native thread fault"), isTerminating: true));
            var nonExceptionReport = domainCoordinator.HandleAppDomainException(
                new UnhandledExceptionEventArgs("raw-clr-fault-object", isTerminating: true));
            Check(domainReport != null && nonExceptionReport != null &&
                  Directory.GetFiles(domainStore.DirectoryPath, "*.json").Length == 2,
                "AppDomain.UnhandledException failed to record Exception or non-Exception payload");

            var blockedPath = Path.Combine(root, "blocked-file");
            File.WriteAllText(blockedPath, "not-a-directory");
            var blockedStore = new AIDiagnosticStore(blockedPath);
            var saveFailedObserved = false;
            var blockedCodes = new List<int>();
            var blockedCoordinator = new UnhandledExceptionCoordinator(
                blockedStore,
                () => InteractiveState,
                (_, report, saveFailed, _) => { Check(report == null, "Blocked store unexpectedly returned path"); saveFailedObserved = saveFailed; return UnhandledUiDecision.Exit; },
                blockedCodes.Add);
            blockedCoordinator.HandleUiException(new Exception("ui fault with unwritable disk"));
            Check(saveFailedObserved && blockedCodes.SequenceEqual([1]),
                "Unwritable diagnostic directory threw or failed to surface saveFailed");
            Check(blockedCoordinator.HandleUnobservedTaskException(
                    new UnobservedTaskExceptionEventArgs(new AggregateException(new Exception("bg fault")))) == null,
                "Unwritable diagnostic directory threw inside UnobservedTaskException");
            Check(blockedCoordinator.HandleAppDomainException(
                    new UnhandledExceptionEventArgs(new Exception("domain fault"), isTerminating: true)) == null,
                "Unwritable diagnostic directory threw inside AppDomain.UnhandledException");

            Console.WriteLine("PASS: Windows unhandled exception recording, UI/background separation and resilience");
        }
        finally
        {
            Directory.Delete(root, true);
        }
    }
}
