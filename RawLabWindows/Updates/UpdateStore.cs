using System.IO;
using System.Security.Cryptography;
using System.Text.Json;

namespace RawLab.Windows;

public sealed class UpdateStore(string directory)
{
    public string DirectoryPath { get; } = directory;
    public string StatePath => Path.Combine(DirectoryPath, "state.json");
    public static string DefaultDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RawLab", "Updates");
    public UpdatePreferences Load(bool automaticCheck)
    {
        if (!File.Exists(StatePath)) return new() { AutomaticCheck = automaticCheck };
        RequireOrdinary(DirectoryPath); RequireOrdinary(StatePath);
        var data = File.ReadAllBytes(StatePath);
        using var document = JsonDocument.Parse(data);
        var root = document.RootElement;
        static void RequireFields(JsonElement element, params string[] names)
        {
            if (element.ValueKind != JsonValueKind.Object || names.Any(name => !element.TryGetProperty(name, out _)))
                throw new InvalidDataException("Incomplete update state");
        }
        RequireFields(root, "AutomaticCheck", "AutomaticInstall", "Channel", "PendingUpdate");
        RequireFields(root.GetProperty("PendingUpdate"), "Format", "Phase", "Attempt", "Choice", "Progress", "Blockers");
        var value = JsonSerializer.Deserialize<UpdatePreferences>(data) ?? throw new InvalidDataException("Missing update state");
        if (value.Channel != "stable" || value.PendingUpdate == null || value.PendingUpdate.Format != 1) throw new InvalidDataException("Unsupported update state");
        if (!Enum.IsDefined(value.PendingUpdate.Phase) || !Enum.IsDefined(value.PendingUpdate.Choice) ||
            value.PendingUpdate.Failure is {} failure && !Enum.IsDefined(failure.Stage) ||
            !double.IsFinite(value.PendingUpdate.Progress) || value.PendingUpdate.Progress is < 0 or > 1 || value.PendingUpdate.Blockers == null)
            throw new InvalidDataException("Unsupported update state");
        // 失败阶段决定启动恢复门禁，缺失字段不能被默认值掩盖。
        if (value.PendingUpdate.Phase == UpdatePhase.Failed)
        {
            var failed = value.PendingUpdate.Failure;
            if (failed == null || failed.Stage is UpdatePhase.Idle or UpdatePhase.Available or UpdatePhase.Complete or UpdatePhase.Failed ||
                string.IsNullOrEmpty(failed.Code) || failed.Detail == null)
                throw new InvalidDataException("Incomplete update failure");
        }
        if (value.StateRepairReceipt is {} receipt)
        {
            var archive = RepairedStateArchive(receipt);
            RequireOrdinary(Path.GetDirectoryName(Path.GetDirectoryName(archive)!)!);
            RequireOrdinary(Path.GetDirectoryName(archive)!); RequireOrdinary(archive);
            if (!CryptographicOperations.FixedTimeEquals(SHA256.HashData(File.ReadAllBytes(archive)), Convert.FromHexString(receipt.Sha256)))
                throw new InvalidDataException("State repair archive changed");
        }
        return value;
    }
    public string RepairedStateArchive(UpdateStateRepairReceipt receipt) => Path.Combine(DirectoryPath, "StateRecoveries", receipt.Id.ToString("N"), "state.json");
    public byte[] RepairableState()
    {
        RequireOrdinary(DirectoryPath); RequireOrdinary(StatePath); var data = File.ReadAllBytes(StatePath);
        var knownNonInstallation = false;
        JsonDocument? document = null;
        try { document = JsonDocument.Parse(data); } catch (JsonException) { }
        using (document)
        {
            if (document?.RootElement is { ValueKind: JsonValueKind.Object } root)
            {
                if (root.TryGetProperty("Channel", out var channel) && channel.GetString() != "stable" ||
                    root.TryGetProperty("StateRepairReceipt", out var receipt) && receipt.ValueKind != JsonValueKind.Null)
                    throw new InvalidDataException("Unsupported update state cannot be rebuilt");
                if (root.TryGetProperty("RecoveryReceipt", out var recovery) && recovery.ValueKind != JsonValueKind.Null) {
                    if (recovery.ValueKind != JsonValueKind.String) throw new InvalidDataException("Invalid recovery receipt");
                    new UpdateDataBackup(Path.GetDirectoryName(DirectoryPath)!, DirectoryPath).VerifyCompletedRecovery(recovery.GetString()!);
                }
                if (root.TryGetProperty("PendingUpdate", out var pending))
                {
                    if (pending.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Unknown pending update state");
                    static bool Installation(JsonElement element) => element.TryGetInt32(out var number) &&
                        (number == (int)UpdatePhase.Installing || number == (int)UpdatePhase.PendingRestart);
                    if (pending.TryGetProperty("Format", out var format) && format.GetInt32() != 1 ||
                        pending.TryGetProperty("Phase", out var phase) && (!phase.TryGetInt32(out var number) || !Enum.IsDefined(typeof(UpdatePhase), number) || Installation(phase)) ||
                        pending.TryGetProperty("BackupPath", out var path) && path.ValueKind != JsonValueKind.Null ||
                        pending.TryGetProperty("PreviousVersion", out var previousVersion) && previousVersion.ValueKind != JsonValueKind.Null ||
                        pending.TryGetProperty("PreviousBuild", out var previousBuild) && previousBuild.ValueKind != JsonValueKind.Null ||
                        pending.TryGetProperty("Choice", out var choice) && (!choice.TryGetInt32(out var choiceNumber) || !Enum.IsDefined(typeof(UpdateInstallChoice), choiceNumber)) ||
                        pending.TryGetProperty("Failure", out var failure) && failure.ValueKind == JsonValueKind.Object &&
                            failure.TryGetProperty("Stage", out var stage) && (!stage.TryGetInt32(out var stageNumber) || !Enum.IsDefined(typeof(UpdatePhase), stageNumber) || Installation(stage)))
                        throw new InvalidDataException("Unsupported update state cannot be rebuilt");
                }
                if (root.TryGetProperty("PendingUpdate", out var known) && known.ValueKind == JsonValueKind.Object &&
                    new[] { "Format", "Phase", "Attempt", "Choice", "Progress", "Blockers" }.All(name => known.TryGetProperty(name, out _))) {
                    try {
                        var decoded = known.Deserialize<UpdateTaskState>();
                        knownNonInstallation = decoded != null && (decoded.Phase != UpdatePhase.Failed || decoded.Failure is {} detail &&
                            detail.Stage is not (UpdatePhase.Idle or UpdatePhase.Available or UpdatePhase.Complete or UpdatePhase.Failed) && !string.IsNullOrEmpty(detail.Code));
                    } catch (JsonException) { }
                }
            }
        }
        var readable = false; try { Load(false); readable = true; } catch { }
        if (readable) throw new InvalidDataException("Update state is readable; reopen the app");
        foreach (var name in new[] { "Backups", "Recoveries" })
        {
            var path = Path.Combine(DirectoryPath, name);
            if (!Path.Exists(path)) continue;
            RequireOrdinary(path);
            var entries = Directory.GetFileSystemEntries(path);
            if (entries.Length != 0) {
                if (!knownNonInstallation) throw new InvalidDataException("Installation or data recovery status is unknown");
                foreach (var entry in entries) {
                    var entryName = Path.GetFileName(entry);
                    if (!Guid.TryParse(entryName, out _) && !(name == "Backups" && entryName.StartsWith(".staging-", StringComparison.Ordinal) && Guid.TryParse(entryName[9..], out _)))
                        throw new InvalidDataException("Unknown backup entry");
                    RequireOrdinary(entry);
                }
            }
        }
        if (Path.Exists(Path.Combine(DirectoryPath, "recovery-in-progress.json"))) throw new InvalidDataException("Data recovery is unfinished");
        return data;
    }
    public UpdatePreferences RepairState(byte[] expected)
    {
        if (!RepairableState().SequenceEqual(expected)) throw new InvalidDataException("Update state changed; reopen the app");
        var receipt = new UpdateStateRepairReceipt(Guid.NewGuid(), Convert.ToHexString(SHA256.HashData(expected)));
        var archive = RepairedStateArchive(receipt); Directory.CreateDirectory(Path.GetDirectoryName(archive)!);
        RequireOrdinary(Path.GetDirectoryName(Path.GetDirectoryName(archive)!)!); RequireOrdinary(Path.GetDirectoryName(archive)!);
        // 原始字节先落盘，再原子替换；中断期间不会出现缺失状态而开放编辑。
        WriteAtomic(archive, expected);
        if (!RepairableState().SequenceEqual(expected)) throw new InvalidDataException("Update state changed");
        var next = new UpdatePreferences { AutomaticCheck = false, StateRepairReceipt = receipt };
        try {
            using var document = JsonDocument.Parse(expected);
            if (document.RootElement.TryGetProperty("RecoveryReceipt", out var recovery) && recovery.ValueKind == JsonValueKind.String)
                next.RecoveryReceipt = recovery.GetString();
        } catch (JsonException) { }
        // 修复只重建设置，备份和恢复前数据留到健康启动再回收或归档。
        Save(next);
        return next;
    }
    private static void RequireOrdinary(string path)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new IOException("Linked update state cannot be rebuilt");
    }
    public void Save(UpdatePreferences preferences) => WriteAtomic(StatePath, JsonSerializer.SerializeToUtf8Bytes(preferences));
    public static void WriteAtomic(string path, byte[] data)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            { file.Write(data); file.Flush(true); }
            File.Move(temporary, path, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}

public sealed record UpdateBackupManifest(int Format, DateTimeOffset Created, string PreviousVersion, string TargetVersion, Dictionary<string, string> Files, string? PreviousBuild = null);
public sealed class UpdateDataBackup(string dataRoot, string updateRoot)
{
    private static readonly string[] DataDirectories = ["Edits", "Looks", "Presets", "Batch"];
    public string Create(string previous, string target, string? previousBuild = null)
    {
        var id = Guid.NewGuid().ToString("N");
        var directory = Path.Combine(updateRoot, "Backups", ".staging-" + id);
        var completed = Path.Combine(updateRoot, "Backups", id); Directory.CreateDirectory(directory);
        var files = new Dictionary<string, string>(StringComparer.Ordinal);
        try
        {
            foreach (var name in DataDirectories)
            {
                var source = Path.Combine(dataRoot, name);
                if (!Directory.Exists(source)) continue;
                CopyTree(source, Path.Combine(directory, name), name, files);
            }
            UpdateStore.WriteAtomic(Path.Combine(directory, "manifest.json"), JsonSerializer.SerializeToUtf8Bytes(
                new UpdateBackupManifest(1, DateTimeOffset.UtcNow, previous, target, files, previousBuild)));
            Directory.Move(directory, completed);
            return completed;
        }
        catch { if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true); throw; }
    }
    private static void CopyTree(string source, string destination, string prefix, Dictionary<string, string> files)
    {
        RequireOrdinary(source); Directory.CreateDirectory(destination);
        foreach (var entry in Directory.EnumerateFileSystemEntries(source))
        {
            RequireOrdinary(entry);
            var name = Path.GetFileName(entry); var output = Path.Combine(destination, name); var relative = prefix + "/" + name;
            if (Directory.Exists(entry)) CopyTree(entry, output, relative, files);
            else
            {
                using var input = new FileStream(entry, FileMode.Open, FileAccess.Read, FileShare.Read);
                using (var copy = new FileStream(output, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
                { input.CopyTo(copy); copy.Flush(true); }
                input.Position = 0; var hash = SHA256.HashData(input);
                using var copied = File.OpenRead(output);
                if (!CryptographicOperations.FixedTimeEquals(hash, SHA256.HashData(copied))) throw new IOException("Backup differs from source");
                files[relative] = Convert.ToHexString(hash);
            }
        }
    }
    public UpdateBackupManifest Verify(string directory)
    {
        if (!StringComparer.OrdinalIgnoreCase.Equals(Path.GetDirectoryName(Path.GetFullPath(directory)), Path.GetFullPath(Path.Combine(updateRoot, "Backups"))))
            throw new InvalidDataException("Invalid backup location");
        RequireOrdinary(directory);
        RequireOrdinary(Path.GetDirectoryName(directory)!); RequireOrdinary(Path.Combine(directory, "manifest.json"));
        var manifest = JsonSerializer.Deserialize<UpdateBackupManifest>(File.ReadAllText(Path.Combine(directory, "manifest.json"))) ?? throw new InvalidDataException("Missing backup manifest");
        if (manifest.Format != 1) throw new InvalidDataException("Unsupported backup format");
        foreach (var (name, hash) in manifest.Files)
        {
            var parts = name.Split('/');
            if (parts.Length < 2 || !DataDirectories.Contains(parts[0]) || parts.Any(part => part.Length == 0 || part is "." or ".." || part.IndexOfAny(['\\', ':']) >= 0))
                throw new InvalidDataException("Invalid backup entry");
            var file = directory;
            foreach (var part in parts) { file = Path.Combine(file, part); RequireOrdinary(file); }
            using var input = File.OpenRead(file);
            if (!CryptographicOperations.FixedTimeEquals(SHA256.HashData(input), Convert.FromHexString(hash))) throw new IOException("Backup has changed");
        }
        return manifest;
    }
    public void Discard(string directory)
    {
        if (!Guid.TryParse(Path.GetFileName(directory), out _)) throw new InvalidDataException("Invalid backup name");
        Verify(directory);
        Directory.Delete(directory, recursive: true);
    }
    public void DiscardUnreferencedBackups(string? retaining, string? recoveryReceipt = null)
    {
        if (HasPendingRecovery) return;
        var retainedBackup=retaining==null ? null : Path.TrimEndingDirectorySeparator(Path.GetFullPath(retaining));
        var retainedRecovery=recoveryReceipt==null ? null : Path.TrimEndingDirectorySeparator(Path.GetFullPath(recoveryReceipt));
        var root = Path.Combine(updateRoot, "Backups");
        if (Directory.Exists(root)) {
            RequireOrdinary(root);
            foreach (var entry in Directory.GetFileSystemEntries(root)) {
                if (StringComparer.OrdinalIgnoreCase.Equals(Path.TrimEndingDirectorySeparator(Path.GetFullPath(entry)), retainedBackup)) continue;
                var name = Path.GetFileName(entry);
                if (name.StartsWith(".staging-", StringComparison.Ordinal) && Guid.TryParse(name[9..], out _)) {
                    // 未发布的 staging 不会被安装状态引用；保留一天避免干扰其他进程正在复制的备份。
                    if (DateTime.UtcNow - Directory.GetLastWriteTimeUtc(entry) >= TimeSpan.FromDays(1)) {
                        try { RequireOrdinary(entry); Directory.Delete(entry, true); } catch { }
                    }
                } else if (Guid.TryParse(name, out _)) {
                    try { Discard(entry); }
                    catch { try { Archive(entry, "IncompleteBackups"); } catch { } }
                }
            }
        }
        var recoveries = Path.Combine(updateRoot, "Recoveries");
        if (Directory.Exists(recoveries)) {
            RequireOrdinary(recoveries);
            foreach (var entry in Directory.GetFileSystemEntries(recoveries))
                if (!StringComparer.OrdinalIgnoreCase.Equals(Path.TrimEndingDirectorySeparator(Path.GetFullPath(entry)), retainedRecovery) && Guid.TryParse(Path.GetFileName(entry), out _)) {
                    // 保留可能唯一的恢复前编辑，活动恢复目录中只留下仍有引用的记录。
                    try { Archive(entry, "RecoveryArchives"); } catch { }
                }
        }
    }
    private void Archive(string entry, string name)
    {
        RequireOrdinary(entry);
        var parent = Path.Combine(updateRoot, name); Directory.CreateDirectory(parent); RequireOrdinary(parent);
        var destination = Path.Combine(parent, Path.GetFileName(entry));
        if (!Path.Exists(destination)) Directory.Move(entry, destination);
    }
    public void VerifyCompletedRecovery(string path)
    {
        var directory = Path.GetFullPath(path);
        if (!StringComparer.OrdinalIgnoreCase.Equals(Path.GetDirectoryName(directory), Path.GetFullPath(Path.Combine(updateRoot, "Recoveries"))) ||
            !Guid.TryParse(Path.GetFileName(directory), out var id)) throw new InvalidDataException("Invalid recovery receipt location");
        RequireOrdinary(Path.GetDirectoryName(directory)!); RequireOrdinary(directory);
        var receipt = Path.Combine(directory, "receipt.json"); RequireOrdinary(receipt);
        var saved = JsonSerializer.Deserialize<Recovery>(File.ReadAllText(receipt));
        if (saved?.Id != id || !saved.Restored) throw new InvalidDataException("Invalid recovery receipt");
    }

    private sealed record Recovery(Guid Id, string[] Originals, bool Restored);
    private string RecoveryJournal => Path.Combine(updateRoot, "recovery-in-progress.json");
    public bool HasPendingRecovery => File.Exists(RecoveryJournal);
    private string RecoveryRoot(Recovery recovery) => Path.Combine(updateRoot, "Recoveries", recovery.Id.ToString("N"));

    // 日志先落盘，再逐个移动目录；中断期间不能开放编辑。
    public string Restore(string directory, Action<string>? afterMove = null)
    {
        var manifest = Verify(directory); RequireOrdinary(dataRoot); RequireOrdinary(updateRoot);
        if (HasPendingRecovery) Rollback(ReadRecovery());
        var recovery = new Recovery(Guid.NewGuid(), DataDirectories.Where(name => Directory.Exists(Path.Combine(dataRoot, name))).ToArray(), false);
        var root = RecoveryRoot(recovery); var staged = Path.Combine(root, "staged");
        Directory.CreateDirectory(Path.GetDirectoryName(root)!); RequireOrdinary(Path.GetDirectoryName(root)!);
        Directory.CreateDirectory(Path.Combine(root, "original"));
        foreach (var name in DataDirectories)
        {
            Directory.CreateDirectory(Path.Combine(staged, name));
            if (recovery.Originals.Contains(name)) RequireOrdinary(Path.Combine(dataRoot, name));
        }
        foreach (var (name, hash) in manifest.Files)
        {
            var destination = Path.Combine(staged, name); Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            using (var input = File.OpenRead(Path.Combine(directory, name)))
            using (var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            { input.CopyTo(output); output.Flush(true); }
            using var copied = File.OpenRead(destination);
            if (!CryptographicOperations.FixedTimeEquals(SHA256.HashData(copied), Convert.FromHexString(hash))) throw new IOException("Backup changed during recovery");
        }
        WriteRecovery(recovery, RecoveryJournal);
        try
        {
            foreach (var name in DataDirectories)
            {
                var current = Path.Combine(dataRoot, name);
                if (recovery.Originals.Contains(name)) Directory.Move(current, Path.Combine(root, "original", name));
                afterMove?.Invoke(name); Directory.Move(Path.Combine(staged, name), current);
            }
            var completed = recovery with { Restored = true };
            WriteRecovery(completed, Path.Combine(root, "receipt.json")); WriteRecovery(completed, RecoveryJournal);
            return root;
        }
        catch { Rollback(recovery); throw; }
    }
    public void FinishRecovery(string receipt)
    {
        if (!HasPendingRecovery) return;
        var recovery = ReadRecovery(); var root = RecoveryRoot(recovery);
        if (!recovery.Restored || !StringComparer.OrdinalIgnoreCase.Equals(Path.GetFullPath(root), Path.GetFullPath(receipt)))
            throw new InvalidDataException("Recovery has not completed");
        RequireOrdinary(Path.Combine(root, "receipt.json"));
        var saved = JsonSerializer.Deserialize<Recovery>(File.ReadAllText(Path.Combine(root, "receipt.json")));
        if (saved?.Id != recovery.Id || !saved.Restored) throw new InvalidDataException("Invalid recovery receipt");
        File.Delete(RecoveryJournal);
    }
    private Recovery ReadRecovery()
    {
        RequireOrdinary(RecoveryJournal);
        var value = JsonSerializer.Deserialize<Recovery>(File.ReadAllText(RecoveryJournal)) ?? throw new InvalidDataException("Missing recovery journal");
        if (value.Originals.Distinct().Count() != value.Originals.Length || value.Originals.Any(name => !DataDirectories.Contains(name)))
            throw new InvalidDataException("Invalid recovery journal");
        var root = RecoveryRoot(value); RequireOrdinary(Path.GetDirectoryName(root)!); RequireOrdinary(root); RequireOrdinary(Path.Combine(root, "original"));
        return value;
    }
    private void Rollback(Recovery recovery)
    {
        var root = RecoveryRoot(recovery);
        foreach (var name in DataDirectories)
        {
            var current = Path.Combine(dataRoot, name); var original = Path.Combine(root, "original", name); var hasOriginal = Directory.Exists(original);
            if (hasOriginal || !recovery.Originals.Contains(name))
            {
                if (Directory.Exists(current))
                {
                    var discarded = Path.Combine(root, "discarded", Guid.NewGuid().ToString("N")); Directory.CreateDirectory(discarded);
                    Directory.Move(current, Path.Combine(discarded, name));
                }
                if (hasOriginal) { RequireOrdinary(original); Directory.Move(original, current); }
            }
            else if (!Directory.Exists(current)) throw new IOException("Missing original directory: " + name);
        }
        File.Delete(RecoveryJournal);
    }
    private static void WriteRecovery(Recovery value, string path) => UpdateStore.WriteAtomic(path, JsonSerializer.SerializeToUtf8Bytes(value));
    private static void RequireOrdinary(string path)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new IOException("Linked data entries cannot be backed up or restored");
    }
}
