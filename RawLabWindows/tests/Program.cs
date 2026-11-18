using RawLab.Windows.Tests;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length >= 1 && args[0] == "--exif-stub")
            {
                ExifToolSessionChecks.StubMain(args);
                return 0;
            }
            if (args.Length == 3 && args[0] == "--crash-recovery")
            {
                UpdateStoreChecks.Crash(args[1], args[2]);
                return 0;
            }
            if (args.Length == 4 && args[0] == "--lease-child")
            {
                SystemOpenTests.LeaseChild(args[1], args[2], args[3]).GetAwaiter().GetResult();
                return 0;
            }
            if (args.Length == 3 && args[0] == "--comparison-ui-host")
            {
                return ComparisonDefaultChecks.Host(args[1], args[2]);
            }
            if (args.Length >= 2 && args[0] == "--run-isolated")
            {
                return RunIsolated(args[1], args.Skip(2).ToArray());
            }
            Console.Error.WriteLine("Run tests via `dotnet test`.");
            return 1;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex);
            return 1;
        }
    }

    private static int RunIsolated(string name, string[] args)
    {
        static void Check(bool success, string message)
        {
            if (!success) throw new InvalidOperationException(message);
        }
        switch (name)
        {
            case "localization-admission":
                AdmissionChecks.Run(args[0]);
                return 0;
            case "localization-ui":
                return LocalizationUiRunner.RunUi();
            case "unhandled-ui":
                RawLab.Windows.Loc.Initialize("zh-Hans");
                UnhandledExceptionWindowChecks.Run(Check);
                return 0;
            case "default-isolation":
                DefaultIsolationChecks.Run(args[0], Check);
                return 0;
            case "entry-selection":
                EntrySelectionChecks.Run(args[0], Check);
                return 0;
            default:
                throw new ArgumentException("Unknown isolated test mode: " + name);
        }
    }
}
