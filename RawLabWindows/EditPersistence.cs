using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RawLab.Windows;

[JsonConverter(typeof(X3fModeConverter))]
public enum X3fMode { Legacy = 0, Normal = 1 }

public sealed class X3fModeConverter : JsonConverter<X3fMode>
{
    public override X3fMode Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options) =>
        reader.TokenType == JsonTokenType.String ? reader.GetString() switch {
            "legacy" => X3fMode.Legacy, "normal-v1" => X3fMode.Normal,
            _ => throw new JsonException("Unsupported X3F rendering mode")
        } : throw new JsonException("Invalid X3F rendering mode");
    public override void Write(Utf8JsonWriter writer, X3fMode value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value switch {
            X3fMode.Legacy => "legacy", X3fMode.Normal => "normal-v1",
            _ => throw new JsonException("Unsupported X3F rendering mode")
        });
}

[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record ProcessingIdentity(
    [property: JsonPropertyName("family"), JsonRequired] string Family,
    [property: JsonPropertyName("version"), JsonRequired] int Version,
    [property: JsonPropertyName("quality"), JsonRequired] string Quality)
{
    public static readonly ProcessingIdentity Legacy = new("rawlab", 1, "standard");
    public static readonly ProcessingIdentity C5 = new("rawlab", 2, "standard");
    public static readonly ProcessingIdentity Current = new("rawlab", 3, "standard");

    public static ProcessingIdentity Require(ProcessingIdentity? value)
    {
        if (value is not { Family: "rawlab", Version: 1 or 2 or 3, Quality: "standard" })
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
    GeometrySettings? Geometry = null,
    HDRSettings? HDR = null)
{
    public ProcessingIdentity Processing { get; init; } = ProcessingIdentity.Legacy;
    public X3fMode X3fMode { get; init; } = X3fMode.Legacy;
    public bool AIDenoiseEnabled { get; init; }
    [JsonPropertyName("hdrCameraAI")]
    [JsonIgnore(Condition=JsonIgnoreCondition.WhenWritingDefault)]
    public bool HDRCameraAIEnabled { get; init; }
    internal bool ActiveAIDenoise => HDR is { Mode: HDRMode.Hdr } ? HDRCameraAIEnabled : AIDenoiseEnabled;
    public int MasterRecipeSettingsVersion { get; init; } = 3;
    [JsonIgnore(Condition=JsonIgnoreCondition.WhenWritingNull)]
    public ToneControlsSettings? ToneControls { get; init; }
    [JsonIgnore(Condition=JsonIgnoreCondition.WhenWritingNull)]
    public AtmosphereSettings? Atmosphere { get; init; }
    [JsonIgnore(Condition=JsonIgnoreCondition.WhenWritingNull)]
    public ColorGradingSettings? ColorGrading { get; init; }
    [JsonIgnore(Condition=JsonIgnoreCondition.WhenWritingNull)]
    public ToneCurveSettings? Curve { get; init; }
    [JsonIgnore(Condition=JsonIgnoreCondition.WhenWritingNull)]
    public int? ProRAWDecodeVersion { get; init; }
    public Adjustments Restore() => Adjustments.FromSnapshot(this);
    public bool SameAs(AdjustmentSnapshot other) => Processing == other.Processing && X3fMode == other.X3fMode &&
        AIDenoiseEnabled == other.AIDenoiseEnabled && MasterRecipeID == other.MasterRecipeID && MasterRecipeSettingsVersion == other.MasterRecipeSettingsVersion && ExposureMode == other.ExposureMode && CameraWhiteBalance == other.CameraWhiteBalance &&
        AsShotTemperature == other.AsShotTemperature && AsShotTint == other.AsShotTint && Values.SequenceEqual(other.Values) &&
        (Denoise ?? new()) == (other.Denoise ?? new()) &&
        (Effects ?? new()) == (other.Effects ?? new()) && DisplayChromaDenoise == other.DisplayChromaDenoise &&
        (Hsl ?? new()).Equals(other.Hsl ?? new()) && (Lens ?? new()) == (other.Lens ?? new()) &&
        (Geometry ?? new()) == (other.Geometry ?? new()) && (ToneControls ?? new()) == (other.ToneControls ?? new()) &&
        (Atmosphere ?? new()) == (other.Atmosphere ?? new()) &&
        (ColorGrading ?? new()) == (other.ColorGrading ?? new()) && (Curve ?? new()) == (other.Curve ?? new()) &&
        HDR == other.HDR && HDRCameraAIEnabled == other.HDRCameraAIEnabled && ProRAWDecodeVersion == other.ProRAWDecodeVersion;
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
    public void RequireCurrent()
    {
        if(!SameFile(Read(Path)))throw new PhotoChangedException();
    }
    [JsonIgnore] public string StableKey => FileID ?? System.IO.Path.GetFullPath(Path).ToUpperInvariant();
    public bool SameFile(OriginalIdentity other) => StringComparer.OrdinalIgnoreCase.Equals(Path, other.Path) && SameContent(other);
    public bool SameContent(OriginalIdentity other) => Length == other.Length && Modified == other.Modified && Created == other.Created &&
        (FileID==null || other.FileID==null || FileID==other.FileID);
}

public static class AtomicJson
{
    // Windows 上替换正被打开的文件会短暂失败（访问被拒绝或共享冲突）；只在这个短窗口内重试。
    private static readonly TimeSpan TransientLimit = TimeSpan.FromSeconds(2);

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
            Retry(() => { File.Move(temporary, path, overwrite: true); return true; });
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    // 读取不持存储锁：允许删除共享，写入方仍能原子替换，本次读取得到替换前的完整内容。
    public static T Read<T>(string path) => Retry(() => {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        return JsonSerializer.Deserialize<T>(stream) ?? throw new InvalidDataException(Loc.Text("本地记录损坏。"));
    });

    private static TResult Retry<TResult>(Func<TResult> action)
    {
        var clock = System.Diagnostics.Stopwatch.StartNew();
        while (true)
        {
            try { return action(); }
            catch (Exception error) when (OperatingSystem.IsWindows() && Transient(error) && clock.Elapsed < TransientLimit) { Thread.Sleep(10); }
        }
    }

    private static bool Transient(Exception error) => error is UnauthorizedAccessException ||
        error is IOException and not FileNotFoundException and not DirectoryNotFoundException && (error.HResult & 0xffff) is 32 or 33;
}

public sealed record SavedEdit(OriginalIdentity Identity, AdjustmentSnapshot Settings, string? Look)
{
    public SavedEdit Copy() => this with {Settings=Settings.Copy()};
    public bool SameAs(SavedEdit? other) => other!=null && Identity.SameFile(other.Identity) && Look==other.Look && Settings.SameAs(other.Settings);
    public static bool Same(SavedEdit? a,SavedEdit? b) => a==null ? b==null : a.SameAs(b);
}

public sealed record PhotoEditState(OriginalIdentity Identity,SavedEdit? Edit)
{
    public bool SameAs(PhotoEditState? other) => other!=null && Identity.SameFile(other.Identity) && SavedEdit.Same(Edit,other.Edit);
    public PhotoEditState Copy() => this with {Edit=Edit?.Copy()};
}
public sealed class PhotoChangedException() : IOException("The original photo changed. Select it again.");
public sealed class AdjustmentOperationExpiredException() : InvalidOperationException("This adjustment operation is no longer current.");
public sealed class AdjustmentHistoryOrderException() : InvalidOperationException("Undo or redo the photo's edits in history order.");

public sealed class EditStore
{
    private sealed record Registry(int Version, Dictionary<string, SavedEdit> Records,
        [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
        Dictionary<string, ProcessingMigrationReceipt>? MigrationReceipts = null);
    public static string DefaultDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RawLab", "Edits");
    private readonly string path;
    private readonly Action<string,object> write;
    public event Action<PhotoEditState>? Changed;
    private void NotifyChanged(PhotoEditState state)
    {
        if (Changed is not {} handlers) return;
        foreach (Action<PhotoEditState> handler in handlers.GetInvocationList()) {
            try { handler(state.Copy()); }
            catch { /* 观察者失败不把已成功写盘的调整报告为保存失败。 */ }
        }
    }

    public EditStore(string directory,Action<string,object>? write = null)
    {
        path = Path.Combine(directory, "edits.json");
        this.write=write ?? AtomicJson.Write;
        _=ReadRegistry();
    }

    private Registry ReadRegistry()
    {
        if (!File.Exists(path)) return new(1,new(StringComparer.OrdinalIgnoreCase));
        var registry = AtomicJson.Read<Registry>(path);
        if (registry.Version != 1) throw new InvalidDataException(Loc.Text("无法读取此版本的调整记录。"));
        foreach (var entry in registry.Records.Values) _ = entry.Settings.Restore();
        var receipts = registry.MigrationReceipts == null ? null :
            new Dictionary<string,ProcessingMigrationReceipt>(registry.MigrationReceipts,StringComparer.OrdinalIgnoreCase);
        if (receipts != null)
            foreach (var receipt in receipts.Values)
            {
                if (!receipt.IsKnownStatus || !receipt.IsValid || !receipt.Identity.SameFile(receipt.Before.Identity) ||
                    !receipt.Identity.SameFile(receipt.After.Identity))
                    throw new InvalidDataException(Loc.Text("本地记录损坏。"));
                _ = receipt.Before.Settings.Restore(); _ = receipt.After.Settings.Restore();
            }
        return new(1,new(registry.Records,StringComparer.OrdinalIgnoreCase),receipts);
    }

    public SavedEdit? Find(string input)
    {
        return ReadState(input).Edit;
    }

    public PhotoEditState ReadState(string input) => ReadRecord(ReadRegistry(),OriginalIdentity.Read(input));
    private static PhotoEditState ReadRecord(Registry registry,OriginalIdentity identity) => new(identity,
        registry.Records.TryGetValue(identity.Path,out var edit) && edit.Identity.SameFile(identity) ? edit.Copy() : null);

    public PhotoEditState SaveState(OriginalIdentity identity,SavedEdit? edit)
    {
        if(edit!=null) {_=edit.Settings.Restore();if(!edit.Identity.SameFile(identity))throw new PhotoChangedException();}
        PhotoEditState saved;
        using (AcquireLock()) {
            var registry=ReadRegistry();identity.RequireCurrent();
            var current=ReadRecord(registry,identity);
            if(SavedEdit.Same(current.Edit,edit))return current;
            if(edit==null)registry.Records.Remove(identity.Path);else registry.Records[identity.Path]=edit.Copy();
            write(path,registry);
            saved=new(identity,edit?.Copy());
        }
        NotifyChanged(saved);
        return saved;
    }

    public ProcessingMigrationReceipt? ReadProcessingMigration(string input)
    {
        var identity = OriginalIdentity.Read(input);
        var registry = ReadRegistry();
        return registry.MigrationReceipts?.TryGetValue(identity.Path,out var receipt) == true &&
            receipt.Identity.SameFile(identity) ? receipt.Copy() : null;
    }

    public PhotoEditState CommitProcessingMigration(OriginalIdentity expectedIdentity, SavedEdit expectedBefore,
        SavedEdit candidate, string status)
    {
        if (!expectedIdentity.SameFile(expectedBefore.Identity) || !expectedIdentity.SameFile(candidate.Identity) ||
            status is not (ProcessingMigrationReceipt.Migrated or ProcessingMigrationReceipt.Kept) ||
            expectedBefore.Settings.Processing.Version is not (1 or 2))
            throw new InvalidDataException(Loc.Text("调整记录无效，原有文件未被覆盖。"));
        if (status == ProcessingMigrationReceipt.Migrated && candidate.Settings.Processing != ProcessingIdentity.Current)
            throw new InvalidDataException(Loc.Text("调整记录无效，原有文件未被覆盖。"));
        if (status == ProcessingMigrationReceipt.Kept && !candidate.SameAs(expectedBefore))
            throw new InvalidDataException(Loc.Text("调整记录无效，原有文件未被覆盖。"));
        _ = expectedBefore.Settings.Restore(); _ = candidate.Settings.Restore();
        PhotoEditState saved;
        using (AcquireLock()) {
        var registry=ReadRegistry();expectedIdentity.RequireCurrent();
        var current=ReadRecord(registry,expectedIdentity);
        if (!current.SameAs(new PhotoEditState(expectedIdentity,expectedBefore)))
            throw new AdjustmentOperationExpiredException();
        var records=new Dictionary<string,SavedEdit>(registry.Records,StringComparer.OrdinalIgnoreCase);
        var receipts=registry.MigrationReceipts == null
            ? new Dictionary<string,ProcessingMigrationReceipt>(StringComparer.OrdinalIgnoreCase)
            : new Dictionary<string,ProcessingMigrationReceipt>(registry.MigrationReceipts,StringComparer.OrdinalIgnoreCase);
        var receipt=new ProcessingMigrationReceipt(expectedIdentity,expectedBefore.Copy(),candidate.Copy(),status);
        records[expectedIdentity.Path]=candidate.Copy();receipts[expectedIdentity.Path]=receipt;
        write(path,new Registry(1,records,receipts));
        saved=new(expectedIdentity,candidate.Copy());
        }
        NotifyChanged(saved);
        return saved;
    }

    public PhotoEditState RollbackProcessingMigration(OriginalIdentity identity, PhotoEditState expectedCurrent)
    {
        if (!identity.SameFile(expectedCurrent.Identity)) throw new PhotoChangedException();
        PhotoEditState saved;
        using (AcquireLock()) {
        var registry=ReadRegistry();identity.RequireCurrent();
        var storedReceipts=registry.MigrationReceipts;
        if (storedReceipts == null || !storedReceipts.TryGetValue(identity.Path,out var receipt) ||
            receipt.Status != ProcessingMigrationReceipt.Migrated)
            throw new AdjustmentOperationExpiredException();
        var current=ReadRecord(registry,identity);
        if (!current.SameAs(expectedCurrent)) throw new AdjustmentOperationExpiredException();
        var records=new Dictionary<string,SavedEdit>(registry.Records,StringComparer.OrdinalIgnoreCase);
        var receipts=new Dictionary<string,ProcessingMigrationReceipt>(registry.MigrationReceipts!,StringComparer.OrdinalIgnoreCase);
        records[identity.Path]=receipt.Before.Copy();
        receipts[identity.Path]=receipt with { Status=ProcessingMigrationReceipt.RolledBack };
        write(path,new Registry(1,records,receipts));
        saved=new(identity,receipt.Before.Copy());
        }
        NotifyChanged(saved);
        return saved;
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
        var changed = new List<PhotoEditState>();
        using (AcquireLock()) {
            var updated = ReadRegistry();
            foreach (var input in inputs) {
                var identity = OriginalIdentity.Read(input);
                var edit=new SavedEdit(identity, settings.Copy(), look);
                if(updated.Records.TryGetValue(identity.Path,out var previous) && previous.SameAs(edit))continue;
                updated.Records[identity.Path]=edit;changed.Add(new(identity,edit));
            }
            if(changed.Count>0)write(path,updated);
        }
        foreach(var state in changed)NotifyChanged(state);
    }
}
