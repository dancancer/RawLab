using System.IO;
using System.Text;
using System.Text.Json;

namespace RawLab.Windows;

public enum PresetFailure { EmptyName, DuplicateName, Changed, CorruptLibrary, UnsupportedVersion, IdentityCollision }
public sealed class AdjustmentPresetException(PresetFailure reason, AdjustmentPreset? existing = null) : IOException(reason.ToString())
{
    public PresetFailure Reason { get; } = reason;
    public AdjustmentPreset? Existing { get; } = existing;
}

public sealed record AdjustmentPreset(string ID, string Name, long CreatedAt, long UpdatedAt, AdjustmentPayload Payload)
{
    public bool SameAs(AdjustmentPreset other) => ID == other.ID && Name == other.Name && CreatedAt == other.CreatedAt &&
        UpdatedAt == other.UpdatedAt && Payload.PayloadVersion == other.Payload.PayloadVersion && Payload.ScopeVersion == other.Payload.ScopeVersion &&
        Payload.Source == other.Payload.Source && Payload.Values.Count == other.Payload.Values.Count &&
        Payload.Values.All(pair => AdjustmentPayload.Same(pair.Value, other.Payload[pair.Key]));

    public void Validate()
    {
        if (!CanonicalID(ID) || Name.Length == 0 || Name != NormalizeName(Name) || CreatedAt < 0 || UpdatedAt < CreatedAt ||
            Payload.Source.Identifier != "preset:" + ID) throw new AdjustmentPresetException(PresetFailure.CorruptLibrary);
        Payload.Validate();
    }
    public static string NormalizeName(string name) => name.Trim(TrimCharacters).Normalize(NormalizationForm.FormC);
    internal static bool CanonicalID(string id) => Guid.TryParseExact(id, "D", out var value) && value.ToString("D") == id;
    private static readonly char[] TrimCharacters = Enumerable.Range(9, 5).Concat(Enumerable.Range(0x2000, 12))
        .Concat(new[] { 0x20, 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 }).Select(value => (char)value).ToArray();
}

public sealed class AdjustmentPresetStore
{
    private sealed record Registry(List<AdjustmentPreset> Presets, List<string> RetiredIDs);
    public static string DefaultDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RawLab", "Presets");
    public string DirectoryPath { get; }
    private readonly string path;
    private readonly Action<string, object> write;
    private readonly Func<string> makeID;
    private readonly Func<long> clock;

    public AdjustmentPresetStore(string directory, Action<string, object>? write = null, Func<string>? makeID = null, Func<long>? clock = null)
    {
        DirectoryPath = directory; path = Path.Combine(directory, "presets.json");
        this.write = write ?? AtomicJson.Write;
        this.makeID = makeID ?? (() => Guid.NewGuid().ToString("D"));
        this.clock = clock ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    }
    public IReadOnlyList<AdjustmentPreset> List() => Read().Presets.AsReadOnly();

    public AdjustmentPreset Create(string name, AdjustmentPayload payload)
    {
        name = ValidatedName(name); payload.Validate();
        using var held = AcquireLock();
        var registry = Read(); RequireAvailableName(name, registry);
        string? id = null;
        for (var attempt = 0; attempt < 8; attempt++) {
            var candidate = makeID();
            if (AdjustmentPreset.CanonicalID(candidate) && !registry.RetiredIDs.Contains(candidate) && registry.Presets.All(item => item.ID != candidate)) {
                id = candidate; break;
            }
        }
        if (id == null) throw new AdjustmentPresetException(PresetFailure.IdentityCollision);
        var now = Math.Max(0, clock());
        var preset = new AdjustmentPreset(id, name, now, now, IndependentPayload(payload, id));
        registry.Presets.Add(preset); Write(registry); return preset;
    }
    public AdjustmentPreset Overwrite(AdjustmentPreset expected, AdjustmentPayload payload) => Update(expected, expected.Name, payload);
    public AdjustmentPreset Rename(AdjustmentPreset expected, string name) => Update(expected, ValidatedName(name), expected.Payload);
    public void Delete(AdjustmentPreset expected)
    {
        using var held = AcquireLock(); var registry = Read();
        registry.Presets.RemoveAt(MatchingIndex(expected, registry)); registry.RetiredIDs.Add(expected.ID); Write(registry);
    }
    private AdjustmentPreset Update(AdjustmentPreset expected, string name, AdjustmentPayload payload)
    {
        var frozen = IndependentPayload(payload, expected.ID);
        using var held = AcquireLock(); var registry = Read(); var index = MatchingIndex(expected, registry);
        RequireAvailableName(name, registry, expected.ID);
        var candidate = expected with { Name = name, Payload = frozen };
        if (candidate.SameAs(expected)) return expected;
        if (expected.UpdatedAt == long.MaxValue) throw new AdjustmentPresetException(PresetFailure.CorruptLibrary);
        candidate = candidate with { UpdatedAt = Math.Max(clock(), expected.UpdatedAt + 1) };
        registry.Presets[index] = candidate; Write(registry); return candidate;
    }
    private static AdjustmentPayload IndependentPayload(AdjustmentPayload payload, string id)
    {
        payload.Validate();
        return new(payload.Source with { Identifier = "preset:" + id }, payload.Values.ToDictionary(pair => pair.Key, pair => pair.Value));
    }
    private static int MatchingIndex(AdjustmentPreset expected, Registry registry)
    {
        var index = registry.Presets.FindIndex(item => item.ID == expected.ID);
        if (index < 0 || !registry.Presets[index].SameAs(expected)) throw new AdjustmentPresetException(PresetFailure.Changed);
        return index;
    }
    private static string ValidatedName(string name)
    {
        var normalized = AdjustmentPreset.NormalizeName(name);
        return normalized.Length > 0 ? normalized : throw new AdjustmentPresetException(PresetFailure.EmptyName);
    }
    private static void RequireAvailableName(string name, Registry registry, string? excluding = null)
    {
        if (registry.Presets.FirstOrDefault(item => item.ID != excluding && item.Name == name) is { } duplicate)
            throw new AdjustmentPresetException(PresetFailure.DuplicateName, duplicate);
    }

    private Registry Read()
    {
        if (!File.Exists(path)) return new([], []);
        var text = File.ReadAllText(path);
        try {
            using var document = JsonDocument.Parse(text);
            var root = document.RootElement;
            Keys(root, ["registry_version", "presets"], ["retired_ids"]);
            if (Integer(root.GetProperty("registry_version")) != 1) throw new AdjustmentPresetException(PresetFailure.UnsupportedVersion);
            var entries = new List<AdjustmentPreset>();
            foreach (var item in root.GetProperty("presets").EnumerateArray()) {
                Keys(item, ["id", "name", "created_at", "updated_at", "payload"]);
                var preset = new AdjustmentPreset(Text(item.GetProperty("id")), Text(item.GetProperty("name")),
                    Integer(item.GetProperty("created_at")), Integer(item.GetProperty("updated_at")),
                    AdjustmentPayload.Parse(item.GetProperty("payload").GetRawText()));
                preset.Validate(); entries.Add(preset);
            }
            var retired = root.TryGetProperty("retired_ids", out var ids) ? ids.EnumerateArray().Select(Text).ToList() : [];
            if (retired.Any(id => !AdjustmentPreset.CanonicalID(id)) || retired.Distinct(StringComparer.Ordinal).Count() != retired.Count ||
                entries.Select(item => item.ID).Distinct(StringComparer.Ordinal).Count() != entries.Count ||
                entries.Select(item => item.Name).Distinct(StringComparer.Ordinal).Count() != entries.Count || entries.Any(item => retired.Contains(item.ID)))
                throw new AdjustmentPresetException(PresetFailure.CorruptLibrary);
            return new(entries, retired);
        } catch (AdjustmentPresetException) { throw; }
          catch (AdjustmentTransferException error) {
            throw new AdjustmentPresetException(error.Failure == AdjustmentFailure.UnsupportedVersion ? PresetFailure.UnsupportedVersion : PresetFailure.CorruptLibrary);
        } catch (Exception error) when (error is JsonException or InvalidOperationException or KeyNotFoundException or FormatException or ArgumentException) {
            throw new AdjustmentPresetException(PresetFailure.CorruptLibrary);
        }
    }
    private static string Text(JsonElement value) => value.ValueKind == JsonValueKind.String && value.GetString() is { } text
        ? text : throw new AdjustmentPresetException(PresetFailure.CorruptLibrary);
    private static long Integer(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt64(out var number) ||
            value.GetRawText().Any(character => character != '-' && character is not (>= '0' and <= '9')))
            throw new AdjustmentPresetException(PresetFailure.CorruptLibrary);
        return number;
    }
    private static void Keys(JsonElement value, string[] required, string[]? optional = null)
    {
        if (value.ValueKind != JsonValueKind.Object) throw new AdjustmentPresetException(PresetFailure.CorruptLibrary);
        var keys = value.EnumerateObject().Select(property => property.Name).ToArray();
        if (keys.Distinct(StringComparer.Ordinal).Count() != keys.Length || required.Any(key => !keys.Contains(key)) ||
            keys.Any(key => !required.Contains(key) && optional?.Contains(key) != true))
            throw new AdjustmentPresetException(PresetFailure.CorruptLibrary);
    }
    private void Write(Registry registry)
    {
        foreach (var item in registry.Presets) item.Validate();
        write(path, new { registry_version = 1, presets = registry.Presets.Select(item => new {
            id = item.ID, name = item.Name, created_at = item.CreatedAt, updated_at = item.UpdatedAt,
            payload = JsonSerializer.Deserialize<JsonElement>(item.Payload.ToJson())
        }).ToArray(), retired_ids = registry.RetiredIDs });
    }
    private FileStream AcquireLock()
    {
        Directory.CreateDirectory(DirectoryPath);
        var elapsed = System.Diagnostics.Stopwatch.StartNew();
        while (true) {
            try { return new FileStream(path + ".lock", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
            catch (IOException error) when (((error.HResult & 0xffff) is 32 or 11 || OperatingSystem.IsMacOS() && error.HResult == 35) &&
                elapsed.Elapsed < TimeSpan.FromSeconds(5)) { Thread.Sleep(10); }
        }
    }
}
