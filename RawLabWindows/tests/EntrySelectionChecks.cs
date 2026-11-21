using System.IO;
using System.Windows;

internal static class EntrySelectionChecks
{
    internal static void Run(string repo, Action<bool, string> check)
    {
        var output = Path.Combine(repo, "build", "entry-selection", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(output);
        if (System.Diagnostics.Process.GetCurrentProcess().SessionId == 0 || !Environment.UserInteractive)
        {
            var profile = Path.Combine(output, "unavailable-desktop");
            var code = ComparisonDefaultChecks.Host(repo, profile);
            check(code == 2 && !Directory.Exists(profile) && Application.Current == null,
                "Unavailable native desktop reports NOT REACHED before fixtures or WPF initialization");
        }
    }
}
