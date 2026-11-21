using System.IO;

namespace RawLab.Windows;

internal sealed class AppPaths
{
    internal const string AppDataRootEnvironmentVariable = "RAWLAB_APPDATA_ROOT";

    internal static AppPaths Default { get; } = CreateDefault();

    internal string LocalApplicationDataRoot { get; }
    internal string Root { get; }

    internal string EditsDirectory => Path.Combine(Root, "Edits");
    internal string PresetsDirectory => Path.Combine(Root, "Presets");
    internal string BatchDirectory => Path.Combine(Root, "Batch");
    internal string LooksDirectory => Path.Combine(Root, "Looks");
    internal string HdrLooksDirectory => Path.Combine(Root, "Looks", "HDR");
    internal string HdrCameraProfilesDirectory => Path.Combine(Root, "HDRCameraProfiles");
    internal string UpdatesDirectory => Path.Combine(Root, "Updates");
    internal string EditedPhotoPreviewCacheDirectory => Path.Combine(Root, "Cache", "EditedPhotoPreviews");
    internal string DualDnCacheDirectory => Path.Combine(Root, "Cache", "DualDn");
    internal string HdrCacheDirectory => Path.Combine(Root, "Cache", "HDR");
    internal string ExportStagingDirectory => Path.Combine(Root, "Cache", "ExportStaging");
    internal string AiDiagnosticsDirectory => Path.Combine(Root, "Diagnostics", "AI");
    internal string AiGpuPreferencesPath => Path.Combine(Root, "ai-gpu.json");
    internal string LanguagePreferencePath => Path.Combine(Root, "language.txt");
    internal string FoldersPath => Path.Combine(Root, "folders.json");
    internal string RecentLooksPath => Path.Combine(Root, "recent-looks.json");
    internal string WorkspaceWidthsPath => Path.Combine(Root, "workspace-widths.json");
    internal string UsageSettingsPath => Path.Combine(Root,
#if RAWLAB_RUM_LOCAL
        "usage-local.json");
#else
        "usage.json");
#endif

    internal AppPaths(string root, string? localApplicationDataRoot = null)
    {
        if (string.IsNullOrWhiteSpace(root))
            throw new ArgumentException("Root path cannot be empty.", nameof(root));
        Root = Path.GetFullPath(root);
        LocalApplicationDataRoot = Path.GetFullPath(localApplicationDataRoot ?? Path.GetDirectoryName(Root) ?? Root);
    }

    internal static AppPaths CreateIsolated(string baseDirectory) =>
        new(Path.Combine(Path.GetFullPath(baseDirectory), "profile-" + Guid.NewGuid().ToString("N")[..8]));

    internal static AppPaths CreateDefault()
    {
        var overrideRoot = Environment.GetEnvironmentVariable(AppDataRootEnvironmentVariable);
        if (!string.IsNullOrWhiteSpace(overrideRoot))
        {
            return new AppPaths(Path.GetFullPath(overrideRoot.Trim()));
        }
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return new AppPaths(Path.Combine(localAppData, "RawLab"), localAppData);
    }
}
