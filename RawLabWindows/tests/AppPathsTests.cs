using RawLab.Windows;
using Xunit;

namespace RawLab.Windows.Tests;

[Trait("Category", "Model")]
public sealed class AppPathsTests
{
    [Fact]
    public void DefaultProfileUsesTestIsolationRootAndRoutesStaticDefaults()
    {
        var configuredRoot = Environment.GetEnvironmentVariable(AppPaths.AppDataRootEnvironmentVariable);
        Assert.False(string.IsNullOrWhiteSpace(configuredRoot));

        var expectedRoot = Path.GetFullPath(configuredRoot!.Trim());
        Assert.Equal(expectedRoot, AppPaths.Default.Root);

        var realLocalAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (!string.IsNullOrWhiteSpace(realLocalAppData))
        {
            var realProfile = Path.GetFullPath(Path.Combine(realLocalAppData, "RawLab"));
            Assert.NotEqual(realProfile, AppPaths.Default.Root);
        }

        static void AssertUnderRoot(string root, string candidate)
        {
            var normalizedRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
                + Path.DirectorySeparatorChar;
            var normalizedCandidate = Path.GetFullPath(candidate);
            Assert.StartsWith(normalizedRoot, normalizedCandidate, StringComparison.OrdinalIgnoreCase);
        }

        AssertUnderRoot(expectedRoot, HDRLookSettings.Directory);
        AssertUnderRoot(expectedRoot, HDRCameraProfile.Directory);
        AssertUnderRoot(expectedRoot, AIDiagnosticStore.Default.DirectoryPath);
        AssertUnderRoot(expectedRoot, EditStore.DefaultDirectory);
        AssertUnderRoot(expectedRoot, AdjustmentPresetStore.DefaultDirectory);
        AssertUnderRoot(expectedRoot, BatchJournal.DefaultDirectory);
        AssertUnderRoot(expectedRoot, LookLibrary.DefaultDirectory);
        AssertUnderRoot(expectedRoot, HDRNative.TemporaryRoot);
        AssertUnderRoot(expectedRoot, TempCleanup.DefaultExportStagingDirectory);
        AssertUnderRoot(expectedRoot, UpdateStore.DefaultDirectory);
        AssertUnderRoot(expectedRoot, UsageAnalytics.DefaultSettingsPath);
        AssertUnderRoot(expectedRoot, AIGpuPreferenceStore.DefaultPath);
    }

    [Fact]
    public void CreateDefaultHonorsRawLabAppDataRootOverrideAndFallsBackWhenBlank()
    {
        var previous = Environment.GetEnvironmentVariable(AppPaths.AppDataRootEnvironmentVariable);
        var tempRoot = Path.Combine(Path.GetTempPath(), "rawlab-apppaths-override-" + Guid.NewGuid().ToString("N"));
        try
        {
            Environment.SetEnvironmentVariable(AppPaths.AppDataRootEnvironmentVariable, $"  {tempRoot}  ");
            var overridden = AppPaths.CreateDefault();
            var expectedOverride = Path.GetFullPath(tempRoot);
            Assert.Equal(expectedOverride, overridden.Root);
            Assert.Equal(Path.Combine(expectedOverride, "Edits"), overridden.EditsDirectory);
            Assert.Equal(Path.Combine(expectedOverride, "Looks", "HDR"), overridden.HdrLooksDirectory);
            Assert.Equal(Path.Combine(expectedOverride, "HDRCameraProfiles"), overridden.HdrCameraProfilesDirectory);
            Assert.Equal(Path.Combine(expectedOverride, "Diagnostics", "AI"), overridden.AiDiagnosticsDirectory);
            Assert.Equal(Path.Combine(expectedOverride, "language.txt"), overridden.LanguagePreferencePath);
            Assert.Equal(Path.GetFullPath(Path.GetDirectoryName(expectedOverride) ?? expectedOverride), overridden.LocalApplicationDataRoot);

            foreach (var blank in new[] { null, "", "   " })
            {
                Environment.SetEnvironmentVariable(AppPaths.AppDataRootEnvironmentVariable, blank);
                var fallback = AppPaths.CreateDefault();
                var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                Assert.Equal(Path.GetFullPath(Path.Combine(localAppData, "RawLab")), fallback.Root);
                Assert.Equal(Path.GetFullPath(localAppData), fallback.LocalApplicationDataRoot);
            }
        }
        finally
        {
            Environment.SetEnvironmentVariable(AppPaths.AppDataRootEnvironmentVariable, previous);
        }
    }
}
