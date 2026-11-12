using System.IO.Compression;
using System.Text.Json;
using RawLab.Windows;

internal static class UnhandledExceptionChecks
{
    internal static void Run()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-unhandled-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        static void Check(bool value, string message) { if (!value) throw new Exception(message); }

        try
        {
            // 1. UI unhandled exception when app is interactive: recorded, redacted, exportable,
            //    prompts user, and Continue neither throws nor exits.
            var uiStore = new AIDiagnosticStore(Path.Combine(root, "ui-continue"));
            var prompts = 0;
            var shutdownCodes = new List<int>();
            string? promptedReport = null;
            var promptedSaveFailed = true;
            var promptedCanContinue = false;
            var continueCoordinator = new UnhandledExceptionCoordinator(
                uiStore,
                () => true,
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
                () => true,
                (_, _, _, _) => { exitPrompts++; return UnhandledUiDecision.Exit; },
                exitCodes.Add);
            exitCoordinator.HandleUiException(new ApplicationException("fatal UI state"));
            exitCoordinator.HandleUiException(new ApplicationException("secondary fault while shutting down"));
            Check(exitPrompts == 1 && exitCodes.SequenceEqual([1]),
                "Choosing Exit did not shut down cleanly once with code 1");
            Check(Directory.GetFiles(exitStore.DirectoryPath, "*.json").Length == 2,
                "Late exception during shutdown was lost instead of recorded");

            // 3. Startup-incomplete / closing UI failure: forces Exit even if prompt returned Continue.
            var startupStore = new AIDiagnosticStore(Path.Combine(root, "startup-fail"));
            var startupCodes = new List<int>();
            var startupCanContinueSeen = true;
            var startupCoordinator = new UnhandledExceptionCoordinator(
                startupStore,
                () => false,
                (_, _, _, canContinue) => { startupCanContinueSeen = canContinue; return UnhandledUiDecision.Continue; },
                startupCodes.Add);
            startupCoordinator.HandleUiException(new InvalidOperationException("startup failed before main window"), "unhandled.startup");
            Check(!startupCanContinueSeen && startupCodes.SequenceEqual([1]) && startupStore.Latest() != null,
                "Startup failure before main window allowed headless continuation instead of exiting");

            // 4. Re-entrant UI exception while modal prompt is open + prompt throwing itself:
            //    records cascading exception, suppresses nested dialogs, and forces Exit.
            var reentrantStore = new AIDiagnosticStore(Path.Combine(root, "reentrant"));
            var reentrantPrompts = 0;
            var reentrantCodes = new List<int>();
            UnhandledExceptionCoordinator? reentrantCoordinator = null;
            reentrantCoordinator = new UnhandledExceptionCoordinator(
                reentrantStore,
                () => true,
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
                () => true,
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
                () => true,
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
                () => true,
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
                () => true,
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
                () => true,
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

            // 8. Static source contract check for WPF hook wiring in App.xaml.cs.
            VerifySourceContracts(Check);
            Console.WriteLine("PASS: Windows unhandled exception recording, UI/background separation and resilience");
        }
        finally
        {
            Directory.Delete(root, true);
        }
    }

    private static void VerifySourceContracts(Action<bool, string> check)
    {
        var sourceDir = FindProjectDirectory();
        var appSource = File.ReadAllText(Path.Combine(sourceDir, "App.xaml.cs"));
        check(appSource.Contains("DispatcherUnhandledException +=", StringComparison.Ordinal),
            "App.xaml.cs must subscribe DispatcherUnhandledException");
        check(appSource.Contains("TaskScheduler.UnobservedTaskException +=", StringComparison.Ordinal),
            "App.xaml.cs must subscribe TaskScheduler.UnobservedTaskException");
        check(appSource.Contains("AppDomain.CurrentDomain.UnhandledException +=", StringComparison.Ordinal),
            "App.xaml.cs must subscribe AppDomain.CurrentDomain.UnhandledException");
        check(appSource.Contains("e.Handled = true;", StringComparison.Ordinal),
            "OnDispatcherUnhandledException must mark e.Handled = true before coordinated recovery/shutdown");
        var renderingSource = File.ReadAllText(Path.Combine(sourceDir, "MainWindow", "Rendering.cs"));
        check(renderingSource.Contains("finally { current=embeddedScheduler.Finish(ticket); }", StringComparison.Ordinal),
            "PumpEmbedded must release embeddedScheduler ticket in finally when unhandled exception escapes");
    }

    private static string FindProjectDirectory()
    {
        foreach (var start in new[] { AppContext.BaseDirectory, Directory.GetCurrentDirectory() })
        {
            for (var dir = new DirectoryInfo(start); dir != null; dir = dir.Parent)
            {
                if (File.Exists(Path.Combine(dir.FullName, "RawLabWindows.csproj")))
                    return dir.FullName;
                var nested = Path.Combine(dir.FullName, "RawLabWindows", "RawLabWindows.csproj");
                if (File.Exists(nested))
                    return Path.GetDirectoryName(nested)!;
            }
        }
        throw new DirectoryNotFoundException("Cannot locate RawLabWindows.csproj");
    }
}
