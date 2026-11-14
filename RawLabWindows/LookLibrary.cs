using System.Collections.Immutable;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RawLab.Windows;

internal enum LookFormat
{
    Unknown = 0,
    Cube = 1,
    Rlook = 2,
    Vlt = 3
}

internal readonly record struct LookValidation(LookFormat Format, uint FormatVersion, bool AppearanceUnverified = false, int CompatibilityMode = 0);

internal enum LookLibraryError
{
    InvalidLook,
    UnreadableSource,
    InvalidRegistry,
    TooLarge,
    OutOfMemory,
    MissingColor, MissingReference, UnsupportedColor, ConflictingColor, CompatibilityChanged, InvalidName, Changed
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
        LookLibraryError.MissingColor => Loc.Text("LUT 缺少输入或输出颜色信息，未导入。请提供作者的颜色说明。"),
        LookLibraryError.MissingReference => Loc.Text("LUT 缺少颜色配置的参考依据，未导入。请提供来源和使用条件。"),
        LookLibraryError.UnsupportedColor => Loc.Text("LUT 的颜色空间或基础风格暂不支持，未导入。不会自动替换为中性显影。"),
        LookLibraryError.ConflictingColor => Loc.Text("LUT 颜色说明无效或互相冲突，未导入。请核对来源。"),
        LookLibraryError.CompatibilityChanged => Loc.Text("LUT 文件已变化或兼容配置无效，请重新导入并确认。"),
        LookLibraryError.InvalidName => Loc.Text("外观名称不能为空或包含控制字符。"),
        LookLibraryError.Changed => Loc.Text("外观已变化，请重新检查。"),
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
    public bool AppearanceUnverified { get; init; }
    public int CompatibilityMode { get; init; }
}

// 本版本读不懂的条目（通常由更新版本写入或单条元数据损坏）：其余外观照常可用；
// 原文 Json 在任何写回中逐字节透传，Id 仍用于避免新导入条目与它冲突。
internal sealed record UnreadableLook(string? Id, string? Name, string? FileName, string Json);

internal sealed class LookLibrary
{
    private sealed record Registry(int Version, List<ManagedLook> Looks, Dictionary<string,string>? ExternalNames = null);
    private sealed record PersistRegistry(int Version, object[] Looks, Dictionary<string, string>? ExternalNames = null);

    internal static string DefaultDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RawLab", "Looks");

    private readonly string directory;
    private readonly string registryPath;
    private readonly Func<string, DcpImportOptions?, byte[]> compileDcp;
    private readonly Func<string, LookValidation> validateLook;
    private readonly Func<string, LUTCompatibility, byte[]> prepareCompatibility;
    private readonly Func<string> makeId;
    private readonly object writeGate = new();
    private ImmutableArray<ManagedLook> looks = [];
    private ImmutableArray<UnreadableLook> unreadableLooks = [];
    private ImmutableDictionary<string,string> externalNames = ImmutableDictionary.Create<string,string>(StringComparer.OrdinalIgnoreCase);

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
        Func<string, LookValidation>? validateLook = null,
        Func<string, LUTCompatibility, byte[]>? prepareCompatibility = null,
        Func<string, DcpImportOptions?, byte[]>? compileDcpWithOptions = null,
        Func<string>? makeId = null)
    {
        this.directory = Path.GetFullPath(directory ?? DefaultDirectory);
        registryPath = Path.Combine(this.directory, "registry.json");
        if (compileDcpWithOptions != null) this.compileDcp = compileDcpWithOptions;
        else if (compileDcp != null) this.compileDcp = (path, _) => compileDcp(path);
        else this.compileDcp = (path, options) => DcpCompiler.Compile(path, options);
        this.validateLook = validateLook ?? ValidateNative;
        this.prepareCompatibility = prepareCompatibility ?? ((path, draft) => draft.Prepare(path));
        this.makeId = makeId ?? (() => Guid.NewGuid().ToString("D"));
        Load();
    }

    internal IReadOnlyList<ManagedLook> Looks => looks;
    internal IReadOnlyList<UnreadableLook> UnreadableLooks => unreadableLooks;
    internal IReadOnlyList<UnreadableLook> ListUnreadable() => unreadableLooks;

    internal static LookValidation ValidateExternal(string path) => ValidateNative(path);

    internal string DisplayName(string path, string fallback) =>
        TryGetByPath(path,out var managed) ? managed.Name : externalNames.GetValueOrDefault(Path.GetFullPath(path),fallback);

    internal void RenamePath(string path, string name)
    {
        var trimmed=name.Trim();
        if(trimmed.Length==0 || trimmed.Any(char.IsControl)) throw new LookLibraryException(LookLibraryError.InvalidName);
        var fullPath=Path.GetFullPath(path);
        lock(writeGate)
        {
            var changed=looks.Select(look=>StringComparer.OrdinalIgnoreCase.Equals(look.Path,fullPath) ? look with { Name=trimmed } : look).ToImmutableArray();
            var aliases=looks.Any(look=>StringComparer.OrdinalIgnoreCase.Equals(look.Path,fullPath)) ? externalNames : externalNames.SetItem(fullPath,trimmed);
            Persist(changed.ToList(), unreadableLooks, aliases);
            looks=changed;externalNames=aliases;
        }
    }

    internal ManagedLook ImportLook(string source, LUTCompatibility? compatibility = null,
        DcpImportOptions? dcpOptions = null)
    {
        var fullSource = Path.GetFullPath(source);
        var suffix = Path.GetExtension(fullSource).TrimStart('.').ToLowerInvariant();
        if (suffix is not ("cube" or "vlt" or "rlook" or "dcp"))
            throw new LookLibraryException(LookLibraryError.InvalidLook);
        if (dcpOptions != null && suffix != "dcp")
            throw new LookLibraryException(LookLibraryError.InvalidLook);
        if (!File.Exists(fullSource) || (File.GetAttributes(fullSource) & FileAttributes.Directory) != 0)
            throw new LookLibraryException(LookLibraryError.UnreadableSource);

        Directory.CreateDirectory(directory);
        var id = AllocateId();
        var preparedSuffix = suffix == "dcp" ? "rlook" : suffix;
        var staging = Path.Combine(directory, $".import-{id}.{preparedSuffix}");
        var fileName = $"{id}.{preparedSuffix}";
        var installed = Path.Combine(directory, fileName);
        try
        {
            if (compatibility != null)
            {
                if (suffix is not ("cube" or "vlt")) throw new LookLibraryException(LookLibraryError.InvalidLook);
                File.WriteAllBytes(staging, prepareCompatibility(fullSource, compatibility));
            }
            else if (suffix == "dcp")
            {
                var bytes = compileDcp(fullSource, dcpOptions);
                if (bytes.LongLength > DcpCompiler.MaxOutputBytes)
                    throw new LookLibraryException(LookLibraryError.TooLarge);
                File.WriteAllBytes(staging, bytes);
            }
            else CopyBounded(fullSource, staging);

            var validation = validateLook(staging);
            if (compatibility == null && validation.CompatibilityMode != 0)
                throw new LookLibraryException(LookLibraryError.MissingReference);
            if (!IsExpected(validation, preparedSuffix))
                throw new LookLibraryException(LookLibraryError.InvalidLook);

            var look = new ManagedLook(
                id,
                Path.GetFileNameWithoutExtension(fullSource),
                fileName,
                Path.GetFileName(fullSource),
                validation.Format,
                validation.FormatVersion) { Path = installed, AppearanceUnverified = validation.AppearanceUnverified,
                    CompatibilityMode = validation.CompatibilityMode };
            File.Move(staging, installed);
            try
            {
                lock (writeGate)
                {
                    if (looks.Any(item => StringComparer.OrdinalIgnoreCase.Equals(item.Id, id)) ||
                        unreadableLooks.Any(item => StringComparer.OrdinalIgnoreCase.Equals(item.Id, id)))
                        throw new LookLibraryException(LookLibraryError.InvalidRegistry);
                    var changed = looks.Append(look).ToImmutableArray();
                    Persist(changed.ToList(), unreadableLooks);
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

    private string AllocateId()
    {
        lock (writeGate)
        {
            for (var attempt = 0; attempt < 8; attempt++)
            {
                var candidate = makeId();
                if (Guid.TryParse(candidate, out _) &&
                    looks.All(item => !StringComparer.OrdinalIgnoreCase.Equals(item.Id, candidate)) &&
                    unreadableLooks.All(item => !StringComparer.OrdinalIgnoreCase.Equals(item.Id, candidate)))
                    return candidate;
            }
        }
        throw new LookLibraryException(LookLibraryError.InvalidRegistry);
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
            var changed = snapshot.Where((_, candidate) => candidate != index).ToImmutableArray();
            var keepFile = unreadableLooks.Any(item => StringComparer.OrdinalIgnoreCase.Equals(item.FileName, look.FileName));
            var staging = Path.Combine(directory, $".remove-{look.FileName}");
            var exists = !keepFile && File.Exists(look.Path);
            if (exists) File.Move(look.Path, staging);
            var committed = false;
            try
            {
                Persist(changed.ToList(), unreadableLooks);
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

    internal void Remove(UnreadableLook expected) => RemoveUnreadable(expected);

    internal void RemoveUnreadable(UnreadableLook expected)
    {
        lock (writeGate)
        {
            var snapshot = unreadableLooks;
            var index = -1;
            for (var candidate = 0; candidate < snapshot.Length; candidate++)
                if (snapshot[candidate].Id == expected.Id && snapshot[candidate].Json == expected.Json) { index = candidate; break; }
            if (index < 0) throw new LookLibraryException(LookLibraryError.Changed);
            var removed = snapshot[index];
            var changed = snapshot.Where((_, candidate) => candidate != index).ToImmutableArray();
            string? targetPath = null;
            string? staging = null;
            var exists = false;
            if (IsManagedLookFileName(removed.FileName) &&
                removed.FileName is { } fileName &&
                looks.All(item => !StringComparer.OrdinalIgnoreCase.Equals(item.FileName, fileName)) &&
                changed.All(item => !StringComparer.OrdinalIgnoreCase.Equals(item.FileName, fileName)))
            {
                var candidatePath = Path.GetFullPath(Path.Combine(directory, fileName));
                if (StringComparer.OrdinalIgnoreCase.Equals(Path.GetDirectoryName(candidatePath), directory))
                {
                    targetPath = candidatePath;
                    staging = Path.Combine(directory, $".remove-{fileName}");
                    exists = File.Exists(targetPath);
                    if (exists) File.Move(targetPath, staging);
                }
            }
            var committed = false;
            try
            {
                Persist(looks.ToList(), changed);
                unreadableLooks = changed;
                committed = true;
            }
            catch
            {
                if (exists && staging != null && targetPath != null && File.Exists(staging) && !File.Exists(targetPath))
                {
                    try { File.Move(staging, targetPath); } catch { }
                }
                throw;
            }
            finally
            {
                if (committed && staging != null) TryDelete(staging);
            }
        }
    }

    private void Load()
    {
        try
        {
            if (!File.Exists(registryPath))
            {
                RecoverRemovals();
                return;
            }
            using var document = JsonDocument.Parse(File.ReadAllText(registryPath));
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) throw new InvalidDataException();
            var rootNames = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in root.EnumerateObject())
                if (!rootNames.Add(property.Name) || property.Name is not ("Version" or "Looks" or "ExternalNames"))
                    throw new InvalidDataException();
            if (!root.TryGetProperty("Version", out var versionElement) ||
                !TryGetInt32Literal(versionElement, out var version) || version != 1 ||
                !root.TryGetProperty("Looks", out var looksElement) ||
                looksElement.ValueKind != JsonValueKind.Array)
                throw new InvalidDataException();

            var loaded = new List<ManagedLook>();
            var unreadable = new List<UnreadableLook>();
            foreach (var item in looksElement.EnumerateArray())
            {
                if (DecodeItem(item) is { } look)
                    loaded.Add(look with { Path = Path.Combine(directory, look.FileName) });
                else
                    unreadable.Add(new(OptionalText(item, "Id"), OptionalText(item, "Name"), OptionalText(item, "FileName"), item.GetRawText()));
            }
            if (loaded.Select(item => item.Id).Distinct(StringComparer.OrdinalIgnoreCase).Count() != loaded.Count)
                throw new InvalidDataException();

            var aliases = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (root.TryGetProperty("ExternalNames", out var externalElement) && externalElement.ValueKind != JsonValueKind.Null)
            {
                if (externalElement.ValueKind != JsonValueKind.Object) throw new InvalidDataException();
                var seenKeys = new HashSet<string>(StringComparer.Ordinal);
                foreach (var entry in externalElement.EnumerateObject())
                {
                    if (!seenKeys.Add(entry.Name) || entry.Value.ValueKind != JsonValueKind.String ||
                        entry.Value.GetString() is not { } value ||
                        !Path.IsPathFullyQualified(entry.Name) ||
                        string.IsNullOrWhiteSpace(value) ||
                        value.Any(char.IsControl))
                        throw new InvalidDataException();
                    aliases[entry.Name] = value;
                }
            }

            looks = loaded.ToImmutableArray();
            unreadableLooks = unreadable.ToImmutableArray();
            externalNames = aliases.ToImmutableDictionary(StringComparer.OrdinalIgnoreCase);
            RecoverRemovals();
        }
        catch (Exception error) when (error is JsonException or InvalidDataException or InvalidOperationException or IOException or UnauthorizedAccessException)
        {
            throw new LookLibraryException(LookLibraryError.InvalidRegistry, error);
        }
    }

    private static readonly HashSet<string> ItemAllowedKeys =
    [
        "Id", "Name", "FileName", "SourceName", "Format", "FormatVersion",
        "AppearanceUnverified", "CompatibilityMode"
    ];

    // 单条外观读不懂只隔离这一条；注册表本身（语法、版本、未知根键、重复身份、外部别名）出错仍让整个库失败。
    private static ManagedLook? DecodeItem(JsonElement item)
    {
        if (item.ValueKind != JsonValueKind.Object) return null;
        try
        {
            var keys = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in item.EnumerateObject())
                if (!keys.Add(property.Name) || !ItemAllowedKeys.Contains(property.Name))
                    return null;
            if (!item.TryGetProperty("Id", out var idEl) || idEl.ValueKind != JsonValueKind.String || idEl.GetString() is not { } id ||
                !item.TryGetProperty("Name", out var nameEl) || nameEl.ValueKind != JsonValueKind.String || nameEl.GetString() is not { } name ||
                !item.TryGetProperty("FileName", out var fileNameEl) || fileNameEl.ValueKind != JsonValueKind.String || fileNameEl.GetString() is not { } fileName ||
                !item.TryGetProperty("SourceName", out var sourceNameEl) || sourceNameEl.ValueKind != JsonValueKind.String || sourceNameEl.GetString() is not { } sourceName ||
                !item.TryGetProperty("Format", out var formatEl) || !TryGetInt32Literal(formatEl, out var formatValue) ||
                !item.TryGetProperty("FormatVersion", out var versionEl) || !TryGetUInt32Literal(versionEl, out var formatVersion))
                return null;

            var appearanceUnverified = false;
            if (item.TryGetProperty("AppearanceUnverified", out var unverifiedEl))
            {
                if (unverifiedEl.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) return null;
                appearanceUnverified = unverifiedEl.GetBoolean();
            }
            var compatibilityMode = 0;
            if (item.TryGetProperty("CompatibilityMode", out var compatEl))
            {
                if (!TryGetInt32Literal(compatEl, out compatibilityMode)) return null;
            }

            var candidate = new ManagedLook(id, name, fileName, sourceName, (LookFormat)formatValue, formatVersion)
            {
                AppearanceUnverified = appearanceUnverified,
                CompatibilityMode = compatibilityMode
            };
            return Valid(candidate) ? candidate : null;
        }
        catch (InvalidOperationException)
        {
            return null;
        }
    }

    private static string? OptionalText(JsonElement item, string key)
    {
        if (item.ValueKind != JsonValueKind.Object) return null;
        try
        {
            return item.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String
                ? value.GetString()
                : null;
        }
        catch (InvalidOperationException)
        {
            return null;
        }
    }

    private static bool TryGetInt32Literal(JsonElement value, out int result)
    {
        result = 0;
        if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out result)) return false;
        var raw = value.GetRawText();
        return raw.Length > 0 && raw.All(character => character == '-' || character is >= '0' and <= '9');
    }

    private static bool TryGetUInt32Literal(JsonElement value, out uint result)
    {
        result = 0;
        if (value.ValueKind != JsonValueKind.Number || !value.TryGetUInt32(out result)) return false;
        var raw = value.GetRawText();
        return raw.Length > 0 && raw.All(character => character is >= '0' and <= '9');
    }

    private static bool Valid(ManagedLook item)
    {
        var format = item.Format switch { LookFormat.Cube => "cube", LookFormat.Vlt => "vlt", LookFormat.Rlook => "rlook", _ => "" };
        return Guid.TryParse(item.Id, out _) && item.FileName == $"{item.Id}.{format}" &&
            (item.Format == LookFormat.Cube && item.FormatVersion == 0 ||
             item.Format == LookFormat.Vlt && item.FormatVersion == 1 ||
             item.Format == LookFormat.Rlook && item.FormatVersion is 1 or 2) &&
            !string.IsNullOrWhiteSpace(item.Name) && !string.IsNullOrWhiteSpace(item.SourceName);
    }

    private static bool IsExpected(LookValidation validation, string suffix) => suffix switch
    {
        "cube" => validation.Format == LookFormat.Cube && validation.FormatVersion == 0,
        "vlt" => validation.Format == LookFormat.Vlt && validation.FormatVersion == 1,
        "rlook" or "dcp" => validation.Format == LookFormat.Rlook && validation.FormatVersion is 1 or 2,
        _ => false
    };

    private static LookValidation ValidateNative(string path)
    {
        var status = PInvokeNative.ValidateLook(path, out var format, out var version);
        var color = PInvokeNative.InspectLutColor(path);
        if (status != PInvokeNative.StatusOk)
        {
            if (status == PInvokeNative.StatusUnsupported && color is >= 0 and <= 3)
                throw new LookLibraryException(color switch {
                    0 => LookLibraryError.MissingColor, 1 => LookLibraryError.MissingReference,
                    2 => LookLibraryError.UnsupportedColor, _ => LookLibraryError.ConflictingColor });
            throw LookLibraryException.FromNativeStatus(status);
        }
        return new((LookFormat)format, version, color is 4 or 7 or 8, color is 7 or 8 ? color : 0);
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

    private static bool IsManagedLookFileName(string? fileName)
    {
        if (string.IsNullOrWhiteSpace(fileName) || Path.GetFileName(fileName) != fileName ||
            fileName.Contains(':') || fileName.Contains('/') || fileName.Contains('\\'))
            return false;
        var extension = Path.GetExtension(fileName).ToLowerInvariant();
        if (extension is not (".cube" or ".vlt" or ".rlook")) return false;
        var stem = Path.GetFileNameWithoutExtension(fileName);
        return Guid.TryParse(stem, out var parsed) &&
               (string.Equals(stem, parsed.ToString("D"), StringComparison.OrdinalIgnoreCase) ||
                string.Equals(stem, parsed.ToString("N"), StringComparison.OrdinalIgnoreCase));
    }

    private void RecoverRemovals()
    {
        if (!Directory.Exists(directory)) return;
        var activeFiles = new HashSet<string>(
            looks.Select(item => item.FileName)
                .Concat(unreadableLooks.Select(item => item.FileName).OfType<string>().Where(name => name.Length > 0)),
            StringComparer.OrdinalIgnoreCase);
        foreach (var staged in Directory.EnumerateFiles(directory, ".remove-*", SearchOption.TopDirectoryOnly))
        {
            var fileName = Path.GetFileName(staged)[".remove-".Length..];
            if (!IsManagedLookFileName(fileName))
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

    private void Persist(List<ManagedLook> values, ImmutableArray<UnreadableLook> unreadable, ImmutableDictionary<string,string>? aliases = null)
    {
        var options = new JsonSerializerOptions { WriteIndented = true };
        var temporary = registryPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        var aliasMap = (aliases ?? externalNames).ToDictionary(p => p.Key, p => p.Value);
        try
        {
            Directory.CreateDirectory(directory);
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                if (unreadable.Length == 0)
                {
                    JsonSerializer.Serialize(stream, new Registry(1, values, aliasMap), options);
                }
                else
                {
                    var items = values.Cast<object>().Concat(unreadable.Select(item => (object)new RawEntry(item.Json))).ToArray();
                    JsonSerializer.Serialize(stream, new PersistRegistry(1, items, aliasMap), options);
                }
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, registryPath, overwrite: true);
        }
        finally
        {
            TryDelete(temporary);
        }
    }

    // JsonElement 写回会重新转义字符串；读不懂的条目必须按原文写出。
    [JsonConverter(typeof(RawEntryConverter))]
    private sealed record RawEntry(string Json);
    private sealed class RawEntryConverter : JsonConverter<RawEntry>
    {
        public override RawEntry Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) => throw new NotSupportedException();
        public override void Write(Utf8JsonWriter writer, RawEntry value, JsonSerializerOptions options) => writer.WriteRawValue(value.Json);
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }
}
