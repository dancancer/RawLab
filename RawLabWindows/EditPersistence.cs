using System.IO;
using System.Text.Json;

namespace RawLab.Windows;

public sealed record AdjustmentSnapshot(
    double[] Values,
    int ExposureMode,
    bool CameraWhiteBalance,
    double? AsShotTemperature,
    double? AsShotTint,
    DenoiseSettings? Denoise = null,
    PhotoEffectsSettings? Effects = null,
    int DisplayChromaDenoise = 0)
{
    public Adjustments Restore() => Adjustments.FromSnapshot(this);
    public bool SameAs(AdjustmentSnapshot other) => ExposureMode == other.ExposureMode && CameraWhiteBalance == other.CameraWhiteBalance &&
        AsShotTemperature == other.AsShotTemperature && AsShotTint == other.AsShotTint && Values.SequenceEqual(other.Values) &&
        (Denoise ?? new()) == (other.Denoise ?? new()) &&
        (Effects ?? new()) == (other.Effects ?? new()) && DisplayChromaDenoise == other.DisplayChromaDenoise;
    public AdjustmentSnapshot Copy() => this with { Values = (double[])Values.Clone() };
}

public sealed record OriginalIdentity(string Path, long Length, long Modified, long Created)
{
    public static OriginalIdentity Read(string path)
    {
        var file = new FileInfo(System.IO.Path.GetFullPath(path));
        if (!file.Exists) throw new FileNotFoundException("无法访问原始照片。", path);
        return new(file.FullName, file.Length, file.LastWriteTimeUtc.Ticks, file.CreationTimeUtc.Ticks);
    }
    public bool SameFile(OriginalIdentity other) => StringComparer.OrdinalIgnoreCase.Equals(Path, other.Path) && SameContent(other);
    public bool SameContent(OriginalIdentity other) => Length == other.Length && Modified == other.Modified && Created == other.Created;
}

public static class AtomicJson
{
    public static void Write<T>(string path, T value)
    {
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
        var temporary = path + "." + Guid.NewGuid() + ".tmp";
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(stream, value);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, path, overwrite: true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    public static T Read<T>(string path) => JsonSerializer.Deserialize<T>(File.ReadAllText(path)) ?? throw new InvalidDataException("本地记录损坏。");
}

public sealed record SavedEdit(OriginalIdentity Identity, AdjustmentSnapshot Settings, string? Look);

public sealed class EditStore
{
    private sealed record Registry(int Version, Dictionary<string, SavedEdit> Records);
    public static string DefaultDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RawLab", "Edits");
    private readonly string path;
    private Dictionary<string, SavedEdit> records = new(StringComparer.OrdinalIgnoreCase);

    public EditStore(string directory)
    {
        path = Path.Combine(directory, "edits.json");
        if (!File.Exists(path)) return;
        var registry = AtomicJson.Read<Registry>(path);
        if (registry.Version != 1) throw new InvalidDataException("无法读取此版本的调整记录。");
        records = new(registry.Records, StringComparer.OrdinalIgnoreCase);
    }

    public SavedEdit? Find(string input)
    {
        var identity = OriginalIdentity.Read(input);
        return records.TryGetValue(identity.Path, out var entry) && entry.Identity.SameFile(identity) ? entry : null;
    }

    public void Save(string input, AdjustmentSnapshot settings, string? look)
    {
        Save([input], settings, look);
    }

    public void Save(IEnumerable<string> inputs, AdjustmentSnapshot settings, string? look)
    {
        var updated = new Dictionary<string, SavedEdit>(records, StringComparer.OrdinalIgnoreCase);
        foreach (var input in inputs)
        {
            var identity = OriginalIdentity.Read(input);
            updated[identity.Path] = new(identity, settings.Copy(), look);
        }
        AtomicJson.Write(path, new Registry(1, updated));
        records = updated;
    }
}
