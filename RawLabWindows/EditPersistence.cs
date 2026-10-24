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
    [JsonIgnore(Condition=JsonIgnoreCondition.WhenWritingNull)]
    public ToneControlsSettings? ToneControls { get; init; }
    [JsonIgnore(Condition=JsonIgnoreCondition.WhenWritingNull)]
    public ColorGradingSettings? ColorGrading { get; init; }
    public Adjustments Restore() => Adjustments.FromSnapshot(this);
    public bool SameAs(AdjustmentSnapshot other) => Processing == other.Processing &&
        AIDenoiseEnabled == other.AIDenoiseEnabled && MasterRecipeID == other.MasterRecipeID && ExposureMode == other.ExposureMode && CameraWhiteBalance == other.CameraWhiteBalance &&
        AsShotTemperature == other.AsShotTemperature && AsShotTint == other.AsShotTint && Values.SequenceEqual(other.Values) &&
        (Denoise ?? new()) == (other.Denoise ?? new()) &&
        (Effects ?? new()) == (other.Effects ?? new()) && DisplayChromaDenoise == other.DisplayChromaDenoise &&
        (Hsl ?? new()).Equals(other.Hsl ?? new()) && (Lens ?? new()) == (other.Lens ?? new()) &&
        (Geometry ?? new()) == (other.Geometry ?? new()) && (ToneControls ?? new()) == (other.ToneControls ?? new()) && (ColorGrading ?? new()) == (other.ColorGrading ?? new());
    public AdjustmentSnapshot Copy() => this with { Values = (double[])Values.Clone() };
}

public sealed record OriginalIdentity(string Path, long Length, long Modified, long Created)
{
    [JsonIgnore(Condition=JsonIgnoreCondition.WhenWritingNull)]
    public string? FileID {get;init;}
    public static OriginalIdentity Read(string path)
    {
        if(OperatingSystem.IsWindows())return WindowsFileIdentity.ReadIdentity(path);
        var file = new FileInfo(System.IO.Path.GetFullPath(path));
        if (!file.Exists) throw new FileNotFoundException(Loc.Text("无法访问原始照片。"), path);
        return new(file.FullName, file.Length, file.LastWriteTimeUtc.Ticks, file.CreationTimeUtc.Ticks);
    }
    [JsonIgnore] public string StableKey => FileID ?? System.IO.Path.GetFullPath(Path).ToUpperInvariant();
    public bool SameFile(OriginalIdentity other) => StringComparer.OrdinalIgnoreCase.Equals(Path, other.Path) && SameContent(other);
    public bool SameContent(OriginalIdentity other) => Length == other.Length && Modified == other.Modified && Created == other.Created &&
        (FileID==null || other.FileID==null || FileID==other.FileID);
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

public sealed record SavedEdit(OriginalIdentity Identity, AdjustmentSnapshot Settings, string? Look)
{
    public SavedEdit Copy() => this with {Settings=Settings.Copy()};
    public bool SameAs(SavedEdit? other) => other!=null && Identity.SameFile(other.Identity) && Look==other.Look && Settings.SameAs(other.Settings);
    public static bool Same(SavedEdit? a,SavedEdit? b) => a==null ? b==null : a.SameAs(b);
}

public sealed record VersionedPhotoEdit(OriginalIdentity Identity,SavedEdit? Edit,string? Revision)
{
    public bool SameAs(VersionedPhotoEdit? other) => other!=null && Identity.SameFile(other.Identity) && Revision==other.Revision && SavedEdit.Same(Edit,other.Edit);
    public VersionedPhotoEdit Copy() => this with {Edit=Edit?.Copy()};
}
public sealed class EditPersistenceConflict() : IOException("The photo or saved adjustments changed. Reload before retrying.");

public sealed class EditStore
{
    private sealed record Registry(int Version, Dictionary<string, SavedEdit> Records, Dictionary<string,string>? Revisions = null);
    public static string DefaultDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RawLab", "Edits");
    private readonly string path;
    private readonly Action<string,object> write;

    public EditStore(string directory,Action<string,object>? write = null)
    {
        path = Path.Combine(directory, "edits.json");
        this.write=write ?? AtomicJson.Write;
        _=ReadRegistry();
    }

    private Registry ReadRegistry()
    {
        if (!File.Exists(path)) return new(1,new(StringComparer.OrdinalIgnoreCase),new(StringComparer.OrdinalIgnoreCase));
        var registry = AtomicJson.Read<Registry>(path);
        if (registry.Version != 1) throw new InvalidDataException(Loc.Text("无法读取此版本的调整记录。"));
        foreach (var entry in registry.Records.Values) _ = entry.Settings.Restore();
        return new(1,new(registry.Records,StringComparer.OrdinalIgnoreCase),new(registry.Revisions ?? [],StringComparer.OrdinalIgnoreCase));
    }

    public SavedEdit? Find(string input)
    {
        return VersionedState(input).Edit;
    }

    public VersionedPhotoEdit VersionedState(string input) => ReadVersioned(ReadRegistry(),OriginalIdentity.Read(input));
    private static VersionedPhotoEdit ReadVersioned(Registry registry,OriginalIdentity identity) => new(identity,
        registry.Records.TryGetValue(identity.Path,out var edit) && edit.Identity.SameFile(identity) ? edit.Copy() : null,
        registry.Revisions!.GetValueOrDefault(identity.Path));

    public VersionedPhotoEdit CompareAndSave(VersionedPhotoEdit expected,SavedEdit? edit)
    {
        if(edit!=null) {_=edit.Settings.Restore();if(!edit.Identity.SameFile(expected.Identity))throw new EditPersistenceConflict();}
        using var held=AcquireLock();var registry=ReadRegistry();var current=ReadVersioned(registry,OriginalIdentity.Read(expected.Identity.Path));
        if(!current.SameAs(expected))throw new EditPersistenceConflict();
        if(SavedEdit.Same(current.Edit,edit))return current;
        if(edit==null)registry.Records.Remove(current.Identity.Path);else registry.Records[current.Identity.Path]=edit.Copy();
        var revision=Guid.NewGuid().ToString();registry.Revisions![current.Identity.Path]=revision;
        write(path,registry);
        return new(current.Identity,edit?.Copy(),revision);
    }

    private FileStream AcquireLock()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var start=System.Diagnostics.Stopwatch.StartNew();
        while(true) {
            try {return new FileStream(path+".lock",FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.None);}
            catch(IOException error) when (((error.HResult & 0xffff) is 32 or 11 || OperatingSystem.IsMacOS() && error.HResult==35) &&
                start.Elapsed<TimeSpan.FromSeconds(5)) {Thread.Sleep(10);}
        }
    }

    public void Save(string input, AdjustmentSnapshot settings, string? look)
    {
        Save([input], settings, look);
    }

    public void Save(IEnumerable<string> inputs, AdjustmentSnapshot settings, string? look)
    {
        _ = settings.Restore();
        using var held=AcquireLock();
        var updated = ReadRegistry();var changed=false;
        foreach (var input in inputs)
        {
            var identity = OriginalIdentity.Read(input);
            var edit=new SavedEdit(identity, settings.Copy(), look);
            if(updated.Records.TryGetValue(identity.Path,out var previous) && previous.SameAs(edit))continue;
            updated.Records[identity.Path]=edit;updated.Revisions![identity.Path]=Guid.NewGuid().ToString();changed=true;
        }
        if(changed)write(path,updated);
    }
}
