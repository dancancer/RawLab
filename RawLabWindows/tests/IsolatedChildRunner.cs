using System.Diagnostics;

namespace RawLab.Windows.Tests;

internal static class IsolatedChildRunner
{
    internal static ProcessStartInfo CreateStartInfo(params string[] arguments)
    {
        var baseDir = AppContext.BaseDirectory;
        var exeName = OperatingSystem.IsWindows() ? "RawLabWindows.Tests.exe" : "RawLabWindows.Tests";
        var exePath = Path.Combine(baseDir, exeName);
        ProcessStartInfo start;
        if (File.Exists(exePath))
        {
            start = new ProcessStartInfo(exePath) { UseShellExecute = false };
        }
        else
        {
            var dotnet = ResolveDotNet();
            start = new ProcessStartInfo(dotnet) { UseShellExecute = false };
            start.ArgumentList.Add(typeof(IsolatedChildRunner).Assembly.Location);
        }
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        return start;
    }

    internal static void Run(params string[] arguments)
    {
        var start = CreateStartInfo(arguments);
        start.RedirectStandardOutput = true;
        start.RedirectStandardError = true;
        using var process = Process.Start(start) ?? throw new InvalidOperationException("Failed to start isolated test process.");
        var stdoutTask = process.StandardOutput.ReadToEndAsync();
        var stderrTask = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit((int)TimeSpan.FromMinutes(5).TotalMilliseconds))
        {
            try { process.Kill(entireProcessTree: true); } catch { }
            throw new TimeoutException($"Isolated test timed out: {string.Join(' ', arguments)}");
        }
        var stdout = stdoutTask.GetAwaiter().GetResult();
        var stderr = stderrTask.GetAwaiter().GetResult();
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException(
                $"Isolated test '{string.Join(' ', arguments)}' failed with exit code {process.ExitCode}.\nSTDOUT:\n{stdout}\nSTDERR:\n{stderr}");
        }
    }

    internal static string ResolveDotNet()
    {
        var processPath = Environment.ProcessPath;
        if (!string.IsNullOrEmpty(processPath) &&
            string.Equals(Path.GetFileNameWithoutExtension(processPath), "dotnet", StringComparison.OrdinalIgnoreCase))
            return processPath;
        var dotnetRoot = Environment.GetEnvironmentVariable("DOTNET_ROOT");
        if (!string.IsNullOrEmpty(dotnetRoot))
        {
            var candidate = Path.Combine(dotnetRoot, OperatingSystem.IsWindows() ? "dotnet.exe" : "dotnet");
            if (File.Exists(candidate)) return candidate;
        }
        return "dotnet";
    }
}
