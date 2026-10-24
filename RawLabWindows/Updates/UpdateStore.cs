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
        var value = JsonSerializer.Deserialize<UpdatePreferences>(File.ReadAllText(StatePath)) ?? throw new InvalidDataException("Missing update state");
        if (value.Channel != "stable" || value.PendingUpdate.Format != 1) throw new InvalidDataException("Unsupported update state");
        return value;
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
        var directory = Path.Combine(updateRoot, "Backups", Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
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
            return directory;
        }
        catch { Directory.Delete(directory, recursive: true); throw; }
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
