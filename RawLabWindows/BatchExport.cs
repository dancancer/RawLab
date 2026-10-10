using System.IO;

namespace RawLab.Windows;

public enum BatchStatus { Waiting, Running, Publishing, Succeeded, Failed }

public sealed record BatchItem(Guid Id, string Input, OriginalIdentity Identity)
{
    public bool Selected { get; init; }
    public BatchStatus Status { get; init; }
    public string? Output { get; init; }
    public OriginalIdentity? CompletedIdentity { get; init; }
    public string? Error { get; init; }
    public static BatchItem Create(string input) => new(Guid.NewGuid(), Path.GetFullPath(input), OriginalIdentity.Read(input));
    public string StatusText => Status switch {
        BatchStatus.Waiting => "等待导出", BatchStatus.Running or BatchStatus.Publishing => "正在导出",
        BatchStatus.Succeeded => "已导出", _ => "导出失败"
    };
}

public sealed class BatchJob
{
    public int Version { get; set; } = 1;
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Source { get; set; } = "";
    public AdjustmentSnapshot Settings { get; set; } = new Adjustments().Capture();
    public string? Look { get; set; }
    public string LookName { get; set; } = "中性";
    public string? OutputDirectory { get; set; }
    public bool Png { get; set; }
    public bool Started { get; set; }
    public bool Interrupted { get; set; }
    public bool Cancelled { get; set; }
    public string? Error { get; set; }
    public List<BatchItem> Items { get; set; } = [];
    public int SelectedCount => Items.Count(x => x.Selected);
    public int SucceededCount => Items.Count(x => x.Selected && x.Status == BatchStatus.Succeeded);
    public int FailedCount => Items.Count(x => x.Selected && x.Status == BatchStatus.Failed);
    public int RemainingCount => SelectedCount - SucceededCount - FailedCount;
    public string Suffix => Png ? "png" : "jpg";
    public static BatchJob Create(string source, AdjustmentSnapshot settings, string? look, string name) => new() {
        Source = source, Settings = settings.Copy(), Look = look, LookName = name
    };
    public BatchJob Copy() => new() {
        Version=Version, Id=Id, Source=Source, Settings=Settings.Copy(), Look=Look, LookName=LookName,
        OutputDirectory=OutputDirectory, Png=Png, Started=Started, Interrupted=Interrupted, Cancelled=Cancelled,
        Error=Error, Items=Items.Select(x => x with { }).ToList()
    };
    public string TemporaryPath(BatchItem item) => Path.Combine(OutputDirectory!, $".rawlab-{Id}-{item.Id}.{Suffix}");
}

public sealed class BatchJournal
{
    public static string DefaultDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RawLab", "Batch");
    public string DirectoryPath { get; }
    private string PathName => Path.Combine(DirectoryPath, "job.json");
    public BatchJournal(string directory) => DirectoryPath = directory;
    public void Save(BatchJob job) => AtomicJson.Write(PathName, job);

    public void FreezeLook(BatchJob job)
    {
        if (job.Look == null) return;
        Directory.CreateDirectory(DirectoryPath);
        var copy = Path.Combine(DirectoryPath, job.Id + Path.GetExtension(job.Look));
        File.Copy(job.Look, copy);
        job.Look = copy;
    }

    public BatchJob? Load()
    {
        if (!File.Exists(PathName)) return null;
        var job = AtomicJson.Read<BatchJob>(PathName);
        if (job.Version != 1) throw new InvalidDataException("无法读取此版本的批量任务。");
        _ = job.Settings.Restore();
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
        foreach (var item in job.Items) CleanupTemporary(job, item);
        if (job.Look != null && Path.GetDirectoryName(job.Look) == DirectoryPath && Path.GetFileNameWithoutExtension(job.Look) == job.Id.ToString())
            File.Delete(job.Look);
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

    public static void Run(BatchJob job, BatchJournal journal, bool failuresOnly, CancellationToken cancellation,
                           Action<BatchJob, string?> changed, Render render)
    {
        if (job.SelectedCount == 0) throw new InvalidOperationException("请至少选择一张 RAW。");
        if (job.OutputDirectory == null) throw new OutputWriteException("请选择输出文件夹。");
        if (job.Look != null && !File.Exists(job.Look)) throw new InvalidOperationException("任务外观不可用，请重新创建任务。");
        job.Started = true; job.Interrupted = false; job.Cancelled = false; job.Error = null;
        journal.Save(job);
        try
        {
            for (var i = 0; i < job.Items.Count; i++)
            {
                var item = job.Items[i];
                if (!item.Selected || item.Status == BatchStatus.Succeeded || (failuresOnly && item.Status != BatchStatus.Failed)) continue;
                if (cancellation.IsCancellationRequested) { job.Cancelled = true; break; }
                VerifyDestination(job.OutputDirectory);
                job.Items[i] = item with { Status = BatchStatus.Running, Error = null };
                journal.Save(job); changed(job.Copy(), null);
                Export(i, job, journal, render);
                changed(job.Copy(), null);
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

    private static void Export(int index, BatchJob job, BatchJournal journal, Render render)
    {
        var item = job.Items[index];
        var temporary = job.TemporaryPath(item);
        try
        {
            try
            {
                if (!item.Identity.SameFile(OriginalIdentity.Read(item.Input))) throw new InvalidOperationException("原始文件已被替换，请重新选择。");
                render(item.Input, job.Settings.Restore(), job.Look, temporary);
            }
            catch (Exception error)
            {
                job.Items[index] = item with { Status = BatchStatus.Failed, Error = error.Message };
                journal.Save(job);
                if (IsStorageFailure(error)) throw;
                VerifyDestination(job.OutputDirectory!);
                return;
            }
            var name = Path.GetFileNameWithoutExtension(item.Input) + "-" + SafeName(job.LookName);
            var destination = UniqueOutput(job.OutputDirectory!, name, job.Suffix);
            item = item with { Status = BatchStatus.Publishing, Output = destination, CompletedIdentity = OriginalIdentity.Read(temporary) };
            job.Items[index] = item;
            journal.Save(job);
            try { File.Move(temporary, destination, overwrite: false); }
            catch (IOException error) { throw new OutputWriteException("无法发布成片，请检查输出目录。", error); }
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
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { throw new OutputWriteException("输出文件夹不可写，请检查权限和剩余空间。", error); }
    }
}
