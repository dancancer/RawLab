using System.Runtime.CompilerServices;
using RawLab.Windows;

namespace RawLab.Windows.Tests;

internal static class TestIsolationInitializer
{
    [ModuleInitializer]
    internal static void Initialize()
    {
        if (string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable(AppPaths.AppDataRootEnvironmentVariable)))
        {
            var isolatedRoot = Path.Combine(
                Path.GetTempPath(),
                "rawlab-windows-tests-appdata",
                $"{Environment.ProcessId}-{Guid.NewGuid():N}");
            Directory.CreateDirectory(isolatedRoot);
            Environment.SetEnvironmentVariable(AppPaths.AppDataRootEnvironmentVariable, isolatedRoot);
        }
    }
}
