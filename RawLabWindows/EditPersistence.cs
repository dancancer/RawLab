using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RawLab.Windows;

[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record ProcessingIdentity(
    [property: JsonPropertyName("family"), JsonRequired] string Family,
    [property: JsonPropertyName("version"), JsonRequired] int Version,
    [property: JsonPropertyName("quality"), JsonRequired] string Quality)
{
    public static readonly ProcessingIdentity Legacy = new("rawlab", 1, "standard");
    public static readonly ProcessingIdentity Current = new("rawlab", 2, "standard");

    public static ProcessingIdentity Require(ProcessingIdentity? value)
    {
        if (value is not { Family: "rawlab", Version: 1 or 2, Quality: "standard" })
            throw new InvalidDataException(Loc.Text("不支持此处理版本，原有记录未被覆盖。"));
        return value;
    }
}

public sealed record AdjustmentSnapshot(
    double[] Values,
    int ExposureMode,
    bool CameraWhiteBalance,
    double? AsShotTemperature,
    double? AsShotTint,
    DenoiseSettings? Denoise = null,
    PhotoEffectsSettings? Effects = null,
    int DisplayChromaDenoise = 0,
    HslSettings? Hsl = null,
    string? MasterRecipeID = null,
    LensSettings? Lens = null,
    GeometrySettings? Geometry = null)
{
    public ProcessingIdentity Processing { get; init; } = ProcessingIdentity.Legacy;
    public bool AIDenoiseEnabled { get; init; }
    public Adjustments Restore() => Adjustments.FromSnapshot(this);
    public bool SameAs(AdjustmentSnapshot other) => Processing == other.Processing &&
        AIDenoiseEnabled == other.AIDenoiseEnabled && MasterRecipeID == other.MasterRecipeID && ExposureMode == other.ExposureMode && CameraWhiteBalance == other.CameraWhiteBalance &&
        AsShotTemperature == other.AsShotTemperature && AsShotTint == other.AsShotTint && Values.SequenceEqual(other.Values) &&
        (Denoise ?? new()) == (other.Denoise ?? new()) &&
        (Effects ?? new()) == (other.Effects ?? new()) && DisplayChromaDenoise == other.DisplayChromaDenoise &&
        (Hsl ?? new()).Equals(other.Hsl ?? new()) && (Lens ?? new()) == (other.Lens ?? new()) &&
        (Geometry ?? new()) == (other.Geometry ?? new());
    public AdjustmentSnapshot Copy() => this with { Values = (double[])Values.Clone() };
}

public sealed record OriginalIdentity(string Path, long Length, long Modified, long Created)
{
    public static OriginalIdentity Read(string path)
    {
        var file = new FileInfo(System.IO.Path.GetFullPath(path));
        if (!file.Exists) throw new FileNotFoundException(Loc.Text("无法访问原始照片。"), path);
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

    public static T Read<T>(string path) => JsonSerializer.Deserialize<T>(File.ReadAllText(path)) ?? throw new InvalidDataException(Loc.Text("本地记录损坏。"));
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
        records = ReadRecords();
    }

    private Dictionary<string, SavedEdit> ReadRecords()
    {
        if (!File.Exists(path)) return new(StringComparer.OrdinalIgnoreCase);
        var registry = AtomicJson.Read<Registry>(path);
        if (registry.Version != 1) throw new InvalidDataException(Loc.Text("无法读取此版本的调整记录。"));
        foreach (var entry in registry.Records.Values) _ = entry.Settings.Restore();
        return new(registry.Records, StringComparer.OrdinalIgnoreCase);
    }

    public SavedEdit? Find(string input)
    {
        records = ReadRecords();
        var identity = OriginalIdentity.Read(input);
        return records.TryGetValue(identity.Path, out var entry) && entry.Identity.SameFile(identity) ? entry : null;
    }

    public void Save(string input, AdjustmentSnapshot settings, string? look)
    {
        Save([input], settings, look);
    }

    public void Save(IEnumerable<string> inputs, AdjustmentSnapshot settings, string? look)
    {
        _ = settings.Restore();
        var updated = ReadRecords();
        foreach (var input in inputs)
        {
            var identity = OriginalIdentity.Read(input);
            updated[identity.Path] = new(identity, settings.Copy(), look);
        }
        AtomicJson.Write(path, new Registry(1, updated));
        records = updated;
    }
}
