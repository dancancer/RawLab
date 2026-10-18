using System.Collections.Immutable;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RawLab.Windows;

internal enum LookFormat
{
    Unknown = 0,
    Cube = 1,
    Rlook = 2
}

internal readonly record struct LookValidation(LookFormat Format, uint FormatVersion);

internal enum LookLibraryError
{
    InvalidLook,
    UnreadableSource,
    InvalidRegistry,
    TooLarge,
    OutOfMemory
}

internal sealed class LookLibraryException : Exception
{
    internal LookLibraryException(LookLibraryError error, Exception? inner = null)
        : base(MessageFor(error), inner) => Error = error;

    internal LookLibraryError Error { get; }

    private static string MessageFor(LookLibraryError error) => error switch
    {
        LookLibraryError.UnreadableSource => Loc.Text("无法读取或写入文件，请检查路径和访问权限。"),
        LookLibraryError.InvalidRegistry => Loc.Text("本地记录损坏。"),
        LookLibraryError.TooLarge => Loc.Text("DCP 文件或外观数据超过安全大小限制。"),
        LookLibraryError.OutOfMemory => Loc.Text("内存不足，请关闭其他大型应用或使用适合窗口预览。"),
        _ => Loc.Text("外观文件损坏或不兼容；需要兼容的 CUBE 或 RLOOK 文件。")
    };

    internal static LookLibraryException FromNativeStatus(int status) =>
        status == PInvokeNative.StatusIoError
            ? new(LookLibraryError.UnreadableSource)
            : status == PInvokeNative.StatusOutOfMemory
                ? new(LookLibraryError.OutOfMemory, new OutOfMemoryException())
                : new(LookLibraryError.InvalidLook);
}

internal sealed record ManagedLook(
    string Id,
    string Name,
    string FileName,
    string SourceName,
    LookFormat Format,
    uint FormatVersion)
{
    [JsonIgnore]
    internal string Path { get; init; } = "";
}

internal sealed class LookLibrary
{
    private sealed record Registry(int Version, List<ManagedLook> Looks);

    internal static string DefaultDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RawLab", "Looks");

    private readonly string directory;
    private readonly string registryPath;
    private readonly Func<string, byte[]> compileDcp;
    private readonly Func<string, LookValidation> validateLook;
    private readonly object writeGate = new();
    private ImmutableArray<ManagedLook> looks = [];

    internal static bool TryLoad(string? directory, out LookLibrary? library, out Exception? error)
    {
        try
        {
            library = new LookLibrary(directory);
            error = null;
            return true;
        }
        catch (Exception failure)
        {
            library = null;
            error = failure;
            return false;
        }
    }

    internal LookLibrary(
        string? directory = null,
        Func<string, byte[]>? compileDcp = null,
        Func<string, LookValidation>? validateLook = null)
    {
        this.directory = Path.GetFullPath(directory ?? DefaultDirectory);
        registryPath = Path.Combine(this.directory, "registry.json");
        this.compileDcp = compileDcp ?? DcpCompiler.Compile;
        this.validateLook = validateLook ?? ValidateNative;
        Load();
    }

    internal IReadOnlyList<ManagedLook> Looks => looks;

    internal static LookValidation ValidateExternal(string path) => ValidateNative(path);

    internal ManagedLook ImportLook(string source)
    {
        var fullSource = Path.GetFullPath(source);
        var suffix = Path.GetExtension(fullSource).TrimStart('.').ToLowerInvariant();
        if (suffix is not ("cube" or "rlook" or "dcp"))
            throw new LookLibraryException(LookLibraryError.InvalidLook);
        if (!File.Exists(fullSource) || (File.GetAttributes(fullSource) & FileAttributes.Directory) != 0)
            throw new LookLibraryException(LookLibraryError.UnreadableSource);

        Directory.CreateDirectory(directory);
        var id = Guid.NewGuid().ToString("D");
        var preparedSuffix = suffix == "dcp" ? "rlook" : suffix;
        var staging = Path.Combine(directory, $".import-{id}.{preparedSuffix}");
        var fileName = $"{id}.{preparedSuffix}";
        var installed = Path.Combine(directory, fileName);
        try
        {
            if (suffix == "dcp")
            {
                var bytes = compileDcp(fullSource);
                if (bytes.LongLength > DcpCompiler.MaxOutputBytes)
                    throw new LookLibraryException(LookLibraryError.TooLarge);
                File.WriteAllBytes(staging, bytes);
            }
            else CopyBounded(fullSource, staging);

            var validation = validateLook(staging);
            if (!IsExpected(validation, preparedSuffix))
                throw new LookLibraryException(LookLibraryError.InvalidLook);

            var look = new ManagedLook(
                id,
                Path.GetFileNameWithoutExtension(fullSource),
                fileName,
                Path.GetFileName(fullSource),
                validation.Format,
                validation.FormatVersion) { Path = installed };
            File.Move(staging, installed);
            try
            {
                lock (writeGate)
                {
                    var changed = looks.Append(look).ToImmutableArray();
                    Persist(changed.ToList());
                    looks = changed;
                }
            }
            catch
            {
                TryDelete(installed);
                throw;
            }
            return look;
        }
        finally
        {
            TryDelete(staging);
        }
    }

    internal bool TryGetByPath(string path, out ManagedLook look)
    {
        var fullPath = Path.GetFullPath(path);
        var snapshot = looks;
        look = snapshot.FirstOrDefault(item =>
            StringComparer.OrdinalIgnoreCase.Equals(item.Path, fullPath))!;
        return look != null;
    }

    internal string? IdentityForPath(string? path)
    {
        if (path != null && TryGetByPath(path, out var look)) return "managed:" + look.Id;
        return path;
    }

    internal string? ResolveIdentity(string? identity)
    {
        if (identity?.StartsWith("managed:", StringComparison.Ordinal) == true)
        {
            var id = identity["managed:".Length..];
            var snapshot = looks;
            return snapshot.FirstOrDefault(item => item.Id == id)?.Path;
        }
        return identity;
    }

    // Used when a valid imported look cannot be rendered by the active RAW.
    internal void Remove(ManagedLook look)
    {
        lock (writeGate)
        {
            var snapshot = looks;
            var index = -1;
            for (var candidate = 0; candidate < snapshot.Length; candidate++)
                if (snapshot[candidate].Id == look.Id) { index = candidate; break; }
            if (index < 0) return;
            var staging = Path.Combine(directory, $".remove-{look.FileName}");
            var exists = File.Exists(look.Path);
            if (exists) File.Move(look.Path, staging);
            var committed = false;
            try
            {
                var changed = snapshot.Where((_, candidate) => candidate != index).ToImmutableArray();
                Persist(changed.ToList());
                looks = changed;
                committed = true;
            }
            catch
            {
                if (exists && File.Exists(staging) && !File.Exists(look.Path))
                {
                    try { File.Move(staging, look.Path); } catch { }
                }
                throw;
            }
            finally
            {
                if (committed) TryDelete(staging);
            }
        }
    }

    private void Load()
    {
        if (!File.Exists(registryPath))
        {
            RecoverRemovals();
            return;
        }
        try
        {
            var registry = JsonSerializer.Deserialize<Registry>(File.ReadAllText(registryPath));
            if (registry == null || registry.Version != 1 || registry.Looks == null ||
                registry.Looks.Any(item => item is null || !Valid(item)) ||
                registry.Looks.Select(item => item!.Id).Distinct(StringComparer.OrdinalIgnoreCase).Count() != registry.Looks.Count)
                throw new InvalidDataException();
            looks = registry.Looks.Select(item => item! with { Path = Path.Combine(directory, item!.FileName) }).ToImmutableArray();
            RecoverRemovals();
        }
        catch (Exception error) when (error is JsonException or IOException or UnauthorizedAccessException)
        {
            throw new LookLibraryException(LookLibraryError.InvalidRegistry, error);
        }
    }

    private static bool Valid(ManagedLook item)
    {
        var format = item.Format switch { LookFormat.Cube => "cube", LookFormat.Rlook => "rlook", _ => "" };
        return Guid.TryParse(item.Id, out _) && item.FileName == $"{item.Id}.{format}" &&
            (item.Format == LookFormat.Cube && item.FormatVersion == 0 ||
             item.Format == LookFormat.Rlook && item.FormatVersion is 1 or 2) &&
            !string.IsNullOrWhiteSpace(item.Name) && !string.IsNullOrWhiteSpace(item.SourceName);
    }

    private static bool IsExpected(LookValidation validation, string suffix) => suffix switch
    {
        "cube" => validation.Format == LookFormat.Cube && validation.FormatVersion == 0,
        "rlook" or "dcp" => validation.Format == LookFormat.Rlook && validation.FormatVersion is 1 or 2,
        _ => false
    };

    private static LookValidation ValidateNative(string path)
    {
        var status = PInvokeNative.ValidateLook(path, out var format, out var version);
        if (status != PInvokeNative.StatusOk) throw LookLibraryException.FromNativeStatus(status);
        return new((LookFormat)format, version);
    }

    private static void CopyBounded(string source, string destination)
    {
        using var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read);
        using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        var buffer = new byte[1024 * 1024];
        long total = 0;
        while (true)
        {
            var read = input.Read(buffer, 0, buffer.Length);
            if (read == 0) break;
            if (total > DcpCompiler.MaxOutputBytes - read)
                throw new LookLibraryException(LookLibraryError.TooLarge);
            output.Write(buffer, 0, read);
            total += read;
        }
        output.Flush(flushToDisk: true);
    }

    private void RecoverRemovals()
    {
        if (!Directory.Exists(directory)) return;
        var snapshot = looks;
        var activeFiles = new HashSet<string>(snapshot.Select(item => item.FileName), StringComparer.OrdinalIgnoreCase);
        foreach (var staged in Directory.EnumerateFiles(directory, ".remove-*", SearchOption.TopDirectoryOnly))
        {
            var fileName = Path.GetFileName(staged)[".remove-".Length..];
            var extension = Path.GetExtension(fileName).ToLowerInvariant();
            if (extension is not (".cube" or ".rlook") || !Guid.TryParse(Path.GetFileNameWithoutExtension(fileName), out _))
                continue;
            var original = Path.Combine(directory, fileName);
            if (activeFiles.Contains(fileName))
            {
                if (File.Exists(original)) TryDelete(staged);
                else File.Move(staged, original);
            }
            else TryDelete(staged);
        }
    }

    private void Persist(List<ManagedLook> values)
    {
        var options = new JsonSerializerOptions { WriteIndented = true };
        var temporary = registryPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            Directory.CreateDirectory(directory);
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(stream, new Registry(1, values), options);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, registryPath, overwrite: true);
        }
        finally
        {
            TryDelete(temporary);
        }
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }
}
