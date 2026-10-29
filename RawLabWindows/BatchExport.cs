using System.IO;
using System.Security.Cryptography;
using System.Text.Json.Serialization;

namespace RawLab.Windows;

public enum BatchStatus { Waiting, Running, Publishing, Succeeded, Failed }

public sealed record BatchFrozenSettings
{
    [JsonRequired] public int Version { get; init; } = 1;
    [JsonRequired] public int SettingsVersion { get; init; } = 1;
    [JsonRequired] public int Ordinal { get; init; }
    private AdjustmentSnapshot settings = new Adjustments().Capture();
    public required AdjustmentSnapshot Settings { get => settings.Copy(); init => settings = value.Copy(); }
    public string? Look { get; init; }
    public string? LookSha256 { get; init; }
    public string LookName { get; init; } = "中性";
    [JsonRequired] public ExportFormat OutputFormat { get; init; }
    public int? LongEdge { get; init; }

    public BatchFrozenSettings Copy() => this with { Settings = Settings.Copy() };
    public static string Checksum(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }
    public void Validate()
    {
        if (Version != 1 || SettingsVersion != 1 || Ordinal < 0 || !Enum.IsDefined(OutputFormat) ||
            LongEdge is {} edge && !ExportSize.IsValid(edge) ||
            Look == null && LookSha256 != null || Look != null &&
            (LookSha256?.Length != 64 || LookSha256.Any(c => !"0123456789abcdef".Contains(c))))
            throw new InvalidDataException("Invalid frozen batch item.");
        _ = Settings.Restore();
    }
    public void VerifyLook()
    {
        if (Look != null && (!File.Exists(Look) || Checksum(Look) != LookSha256))
            throw new InvalidOperationException(Loc.Text("任务使用的外观文件不可用，请重新创建任务。"));
    }
}

public sealed record BatchItem(Guid Id, string Input, OriginalIdentity Identity)
{
    public bool Selected { get; init; }
    public BatchStatus Status { get; init; }
    public string? Output { get; init; }
    public OriginalIdentity? CompletedIdentity { get; init; }
    public string? Error { get; init; }
    public string? ValidationError { get; init; }
    public BatchFrozenSettings? Frozen { get; init; }
    [System.Text.Json.Serialization.JsonIgnore] public bool CanSelect=>ValidationError==null;
    public static BatchItem Create(string input) => new(Guid.NewGuid(), Path.GetFullPath(input), OriginalIdentity.Read(input));
    public string StatusText => ValidationError!=null ? Loc.Text("验证失败") : Status switch {
        BatchStatus.Waiting => Loc.Text("等待导出"), BatchStatus.Running or BatchStatus.Publishing => Loc.Text("正在导出"),
        BatchStatus.Succeeded => Loc.Text("已导出"), _ => Loc.Text("导出失败")
    };
}

public sealed class BatchJob
{
    public const string UniformFrozen = "uniform_frozen", PerTargetFrozen = "per_target_frozen";
    [JsonPropertyName("settings_mode")] public string? SettingsMode { get; set; }
    [JsonIgnore] public string Mode => SettingsMode ?? UniformFrozen;
    public int Version { get; set; } = 1;
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Source { get; set; } = "";
    public AdjustmentSnapshot Settings { get; set; } = new Adjustments().Capture();
    public int AIBackend { get; set; } = 2;
    public string AIDeviceID { get; set; } = "";
    public string? Look { get; set; }
    public string LookName { get; set; } = "中性";
    public string? OutputDirectory { get; set; }
    // Png remains for journals written before the explicit output format was added.
    public bool Png { get; set; }
    public ExportFormat? OutputFormat { get; set; }
    [System.Text.Json.Serialization.JsonIgnore]
    public ExportFormat Format
    {
        get => OutputFormat ?? (Png ? ExportFormat.Png : ExportFormat.Jpeg);
        set { OutputFormat = value; Png = value == ExportFormat.Png; Version = Math.Max(Version, 2); }
    }
    // Null is deliberately the original-size default, including for journals
    // written by older versions that do not have this property.
    public int? LongEdge { get; set; }
    public bool Started { get; set; }
    public bool Interrupted { get; set; }
    public bool Cancelled { get; set; }
    public string? Error { get; set; }
    public List<BatchItem> Items { get; set; } = [];
    public int SelectedCount => Items.Count(x => x.Selected && x.CanSelect);
    public int SucceededCount => Items.Count(x => x.Selected && x.CanSelect && x.Status == BatchStatus.Succeeded);
    public int FailedCount => Items.Count(x => x.Selected && x.CanSelect && x.Status == BatchStatus.Failed);
    public int RemainingCount => SelectedCount - SucceededCount - FailedCount;
    [System.Text.Json.Serialization.JsonIgnore]
    public string Suffix => Format.Suffix();
    public static BatchJob Create(string source, AdjustmentSnapshot settings, string? look, string name) => new() {
        Source = source, Settings = settings.Copy(), Look = look, LookName = name
    };
    public BatchJob Copy() => new() {
        Version=Version, SettingsMode=SettingsMode, Id=Id, Source=Source, Settings=Settings.Copy(), AIBackend=AIBackend, AIDeviceID=AIDeviceID, Look=Look, LookName=LookName,
        OutputDirectory=OutputDirectory, Png=Png, OutputFormat=OutputFormat, LongEdge=LongEdge, Started=Started, Interrupted=Interrupted, Cancelled=Cancelled,
        Error=Error, Items=Items.Select(x => x with { Frozen = x.Frozen?.Copy() }).ToList()
    };
    public BatchFrozenSettings SnapshotFor(BatchItem item) => Mode == PerTargetFrozen
        ? item.Frozen ?? throw new InvalidDataException("Missing frozen batch item.")
        : new() { Ordinal = 0, Settings = PhotoInput.PrepareBatchSettings(Source, item.Input, Settings.Restore()).Capture(),
            Look = Look, LookName = LookName, OutputFormat = Format, LongEdge = LongEdge };
    public string TemporaryPath(BatchItem item) => Path.Combine(OutputDirectory!, $".rawlab-{Id}-{item.Id}.{SnapshotFor(item).OutputFormat.Suffix()}");

    public void Validate()
    {
        if (Version is < 1 or > 3 || Mode is not (UniformFrozen or PerTargetFrozen))
            throw new InvalidDataException(Loc.Text("无法读取此版本的批量任务。"));
        if (AIBackend is not (0 or 2 or 3)) throw new InvalidDataException("Invalid Windows AI backend in batch journal.");
        if (AIDeviceID is not {Length:<=256}) throw new InvalidDataException("Invalid Windows AI device in batch journal.");
        _ = Settings.Restore();
        if (AIBackend == 0 && (Settings.AIDenoiseEnabled || Items.Any(item => item.Frozen?.Settings.AIDenoiseEnabled == true)))
            throw new InvalidDataException(Loc.Text("AI 降噪不支持 CPU，请重新创建使用 GPU 的批量任务。"));
        if (Mode != PerTargetFrozen)
        {
            if (Version == 3 || Items.Any(x => x.Frozen != null)) throw new InvalidDataException("Frozen items require per-target mode.");
            return;
        }
        if (Version != 3 || Items.Count == 0 || Items.Select(x => x.Id).Distinct().Count() != Items.Count ||
            Items.Select(x => x.Identity.FileID ?? Path.GetFullPath(x.Input).ToUpperInvariant()).Distinct().Count() != Items.Count)
            throw new InvalidDataException("Invalid per-target batch.");
        for (var i = 0; i < Items.Count; i++)
        {
            var frozen = Items[i].Frozen;
            if (frozen == null || frozen.Ordinal != i) throw new InvalidDataException("Missing frozen batch item or order.");
            frozen.Validate();
        }
    }
}

public sealed class BatchJournal
{
    public static string DefaultDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RawLab", "Batch");
    public string DirectoryPath { get; }
    private string PathName => Path.Combine(DirectoryPath, "job.json");
    public BatchJournal(string directory) => DirectoryPath = directory;
    public void Save(BatchJob job)
    {
        _ = ReadJob();
        Validate(job);
        AtomicJson.Write(PathName, job);
    }

    public void FreezeLook(BatchJob job)
    {
        if (job.Look == null) return;
        Directory.CreateDirectory(DirectoryPath);
        var copy = Path.Combine(DirectoryPath, job.Id + Path.GetExtension(job.Look));
        File.Copy(job.Look, copy);
        job.Look = copy;
    }

    private static void Validate(BatchJob job)
    {
        job.Validate();
    }

    private BatchJob? ReadJob()
    {
        if (!File.Exists(PathName)) return null;
        var job = AtomicJson.Read<BatchJob>(PathName);
        Validate(job);
        return job;
    }

    public BatchJob? Load()
    {
        var job = ReadJob();
        if (job == null) return null;
        if (job.LongEdge is { } edge && !ExportSize.IsValid(edge)) job.LongEdge = null;
        for (var i = 0; i < job.Items.Count; i++)
        {
            var item = job.Items[i];
            if (item.Status is not (BatchStatus.Running or BatchStatus.Publishing)) continue;
            var published = item.Status == BatchStatus.Publishing && item.Output != null && File.Exists(item.Output) &&
                item.CompletedIdentity?.SameContent(OriginalIdentity.Read(item.Output)) == true;
            job.Items[i] = item with { Status = published ? BatchStatus.Succeeded : BatchStatus.Waiting, Error = null };
            job.Interrupted = true;
            CleanupTemporary(job, item);
        }
        if (job.Started && job.RemainingCount > 0) job.Interrupted = true;
        return job;
    }

    public void Discard(BatchJob job)
    {
        if (File.Exists(PathName)) File.Delete(PathName);
        ReleaseResources(job);
    }

    public void ReleaseResources(BatchJob job)
    {
        foreach (var item in job.Items) CleanupTemporary(job, item);
        if (job.Look != null && Path.GetDirectoryName(job.Look) == DirectoryPath && Path.GetFileNameWithoutExtension(job.Look) == job.Id.ToString())
            File.Delete(job.Look);
        foreach (var item in job.Items)
            if (item.Frozen?.Look is {} look && Path.GetDirectoryName(look) == DirectoryPath &&
                Path.GetFileNameWithoutExtension(look) == item.Id.ToString()) File.Delete(look);
    }

    private static void CleanupTemporary(BatchJob job, BatchItem item)
    {
        if (job.OutputDirectory == null) return;
        try { File.Delete(job.TemporaryPath(item)); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}

public sealed class OutputWriteException(string message, Exception? inner = null) : IOException(message, inner);

public static class BatchRunner
{
    public delegate void Render(string input, Adjustments settings, string? look, string destination);
    public delegate void SizedRender(string input, Adjustments settings, string? look, string destination, int? longEdge);

    public static void Run(BatchJob job, BatchJournal journal, bool failuresOnly, CancellationToken cancellation,
                           Action<BatchJob, string?> changed, Render render) =>
        Run(job, journal, failuresOnly, cancellation, changed,
            (input, settings, look, destination, _) => render(input, settings, look, destination));

    public static void Run(BatchJob job, BatchJournal journal, bool failuresOnly, CancellationToken cancellation,
                           Action<BatchJob, string?> changed, SizedRender render)
    {
        RunCore(job, journal, failuresOnly, cancellation, changed, render);
    }

    private static void RunCore(BatchJob job, BatchJournal journal, bool failuresOnly, CancellationToken cancellation,
                                Action<BatchJob, string?> changed, SizedRender render)
    {
        job.Validate();
        if (job.SelectedCount == 0) throw new InvalidOperationException(Loc.Text("请至少选择一张照片。"));
        if (job.OutputDirectory == null) throw new OutputWriteException(Loc.Text("选择输出文件夹"));
        if (job.Mode == BatchJob.UniformFrozen && job.Look != null && !File.Exists(job.Look)) throw new InvalidOperationException(Loc.Text("任务使用的外观文件不可用，请重新创建任务。"));
        job.Started = true; job.Interrupted = false; job.Cancelled = false; job.Error = null;
        journal.Save(job);
        try
        {
            for (var i = 0; i < job.Items.Count; i++)
            {
                var item = job.Items[i];
                if (!item.Selected || !item.CanSelect || item.Status == BatchStatus.Succeeded || (failuresOnly && item.Status != BatchStatus.Failed)) continue;
                if (cancellation.IsCancellationRequested) { job.Cancelled = true; break; }
                VerifyDestination(job.OutputDirectory);
                job.Items[i] = item with { Status = BatchStatus.Running, Error = null };
                journal.Save(job); changed(job.Copy(), null);
                Export(i, job, journal, cancellation, render);
                changed(job.Copy(), null);
                if(cancellation.IsCancellationRequested) { job.Cancelled=true; break; }
            }
        }
        catch (Exception error)
        {
            job.Interrupted = true; job.Error = error.Message;
            try { journal.Save(job); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            changed(job.Copy(), error.Message);
            throw;
        }
        journal.Save(job); changed(job.Copy(), null);
    }

    private static void Export(int index, BatchJob job, BatchJournal journal, CancellationToken cancellation, SizedRender render)
    {
        var item = job.Items[index];
        var snapshot = job.SnapshotFor(item);
        var temporary = job.TemporaryPath(item);
        try
        {
            try
            {
                if (!item.Identity.SameFile(OriginalIdentity.Read(item.Input))) throw new InvalidOperationException(Loc.Text("原始文件已被替换，请重新选择照片。"));
                if (job.Mode == BatchJob.PerTargetFrozen) snapshot.VerifyLook();
                render(item.Input, snapshot.Settings.Restore(), snapshot.Look, temporary, snapshot.LongEdge);
            }
            catch (OperationCanceledException) when(cancellation.IsCancellationRequested)
            {
                job.Items[index]=item with {Status=BatchStatus.Waiting,Error=null};
                journal.Save(job);
                return;
            }
            catch (Exception error)
            {
                job.Items[index] = item with { Status = BatchStatus.Failed, Error = error.Message };
                journal.Save(job);
                if (IsStorageFailure(error)) throw;
                VerifyDestination(job.OutputDirectory!);
                return;
            }
            var name = Path.GetFileNameWithoutExtension(item.Input) + "-" + SafeName(snapshot.LookName);
            var destination = UniqueOutput(job.OutputDirectory!, name, snapshot.OutputFormat.Suffix());
            item = item with { Status = BatchStatus.Publishing, Output = destination, CompletedIdentity = OriginalIdentity.Read(temporary) };
            job.Items[index] = item;
            journal.Save(job);
            try { File.Move(temporary, destination, overwrite: false); }
            catch (IOException error) { throw new OutputWriteException(Loc.Text("无法写入成片，请检查输出位置和剩余空间。"), error); }
            job.Items[index] = item with { Status = BatchStatus.Succeeded, Error = null };
            journal.Save(job);
        }
        finally { try { File.Delete(temporary); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
    }

    public static string UniqueOutput(string directory, string name, string suffix)
    {
        for (var i = 0; ; i++)
        {
            var path = Path.Combine(directory, name + (i == 0 ? "" : $"-{i}") + "." + suffix);
            if (!File.Exists(path) && !Directory.Exists(path)) return path;
        }
    }
    private static string SafeName(string value) => new(value.Take(80).Select(c => Path.GetInvalidFileNameChars().Contains(c) || c is '/' or '\\' ? '-' : c).ToArray());
    private static bool IsStorageFailure(Exception error) => error is OutputWriteException or UnauthorizedAccessException ||
        (error is IOException && (error.HResult & 0xffff) is 39 or 112 or 5 or 19);
    private static void VerifyDestination(string directory)
    {
        var probe = Path.Combine(directory, ".rawlab-write-" + Guid.NewGuid());
        try { using (var stream = new FileStream(probe, FileMode.CreateNew)) stream.WriteByte(0); File.Delete(probe); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { throw new OutputWriteException(Loc.Text("无法写入输出目录，请检查访问权限和剩余空间。"), error); }
    }
}
