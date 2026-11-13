using RawLab.Windows;
using System.Globalization;
using System.Text.Json;
using F = RawLab.Windows.AdjustmentField;

// P1 第③步：Windows 消费共享重置场景向量 `reset-scenarios-v1.json`。
// 种子经 `AdjustmentTransfer.Prepare` 写入，重置走生产入口 `EditorAdjustmentRules.PrepareReset`，
// 观察通道复用 `AdjustmentTransfer.Capture`；`@spec_default` 期望引用 spec 表的 windows 默认值
// （按 scale_from_protocol 反映射）。与现状的分歧按第①步棘轮模式登记进 KnownResetDivergences。
internal static class ResetScenarioChecks
{
    private static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
    private sealed record ResetDiff(string Key, string Summary);
    private sealed record ResetDivergence(string LedgerId, string Reason, IReadOnlySet<string> ExpectedKeys);

    // 显式例外清单：未登记的分歧（或清单外字段差异）必红；已修复项仍留档也必红（棘轮只减不增）。
    // 现状：Windows 捕获把 RawDenoise 固定输出为 0 占位（AdjustmentTransferValues.Values 的
    // Put(F.RawDenoise,0)，SDR 管线不建模该键），而 spec windows 默认为 null。
    private static readonly IReadOnlyDictionary<string, ResetDivergence> KnownResetDivergences =
        new Dictionary<string, ResetDivergence>
        {
            ["all-reset-raw"] = new("windows-raw-denoise-placeholder",
                "capture emits 0 placeholder for raw_level while spec default is null",
                new HashSet<string> { "detail.denoise.raw_level" }),
        };

    internal static void Run()
    {
        using var document = JsonDocument.Parse(File.ReadAllText(ResolveFixturePath("Shared/fixtures/reset-scenarios-v1.json")));
        var root = document.RootElement;
        Check(root.GetProperty("fixture_version").GetInt32() == 1, "Reset fixture version must be 1");
        var specFields = LoadSpecFields();
        var scenarios = root.GetProperty("scenarios");
        Check(scenarios.GetArrayLength() > 0, "Reset fixture must not be empty");
        var seenIDs = new HashSet<string>();
        var evaluatedIDs = new HashSet<string>();
        var skippedIDs = new HashSet<string>();
        var problems = new List<string>();
        foreach (var scenario in scenarios.EnumerateArray())
        {
            var id = scenario.GetProperty("id").GetString() ?? throw new Exception("Scenario missing id");
            Check(seenIDs.Add(id), "Duplicate scenario ID: " + id);
            if (scenario.TryGetProperty("platforms", out var platformsElem) && platformsElem.ValueKind == JsonValueKind.Array)
            {
                var platforms = platformsElem.EnumerateArray().Select(item => item.GetString()!).ToHashSet();
                if (!platforms.Contains("windows")) { skippedIDs.Add(id); continue; }
            }
            evaluatedIDs.Add(id);
            var diffs = Evaluate(id, scenario, specFields);
            var actualKeys = diffs.Select(d => d.Key).ToHashSet();
            var summary = string.Join("; ", diffs.Select(d => d.Summary));
            var hasKnown = KnownResetDivergences.TryGetValue(id, out var known);
            if (diffs.Count > 0 && !hasKnown) problems.Add($"Scenario {id} diverged: {summary}");
            else if (diffs.Count == 0 && hasKnown) problems.Add($"Scenario {id} now matches fixture; remove stale divergence ({known!.LedgerId}: {known.Reason})");
            else if (hasKnown && !actualKeys.SetEquals(known!.ExpectedKeys))
                problems.Add($"Scenario {id} divergence keys changed (expected=[{string.Join(", ", known.ExpectedKeys.Order(StringComparer.Ordinal))}], actual=[{string.Join(", ", actualKeys.Order(StringComparer.Ordinal))}]): {summary}");
            else if (hasKnown) Console.WriteLine($"KNOWN DIVERGENCE [{id}] ({known!.LedgerId} - {known.Reason}): {summary}");
        }
        Check(seenIDs.Count == scenarios.GetArrayLength(), "All reset scenario IDs visited");
        var unknownRegistered = KnownResetDivergences.Keys.Except(evaluatedIDs).ToArray();
        Check(unknownRegistered.Length == 0, "Registered reset divergences do not match evaluated scenarios: " + string.Join(", ", unknownRegistered));
        if (problems.Count > 0) throw new Exception(string.Join(Environment.NewLine, problems));
        Console.WriteLine($"PASS: {evaluatedIDs.Count} Windows reset scenarios evaluated ({skippedIDs.Count} platform-scoped skipped, {KnownResetDivergences.Count} registered divergences)");
    }

    private static Dictionary<string, JsonElement> LoadSpecFields()
    {
        using var spec = JsonDocument.Parse(File.ReadAllText(ResolveFixturePath("Shared/specs/adjustment-fields-v1.json")));
        return spec.RootElement.GetProperty("fields").EnumerateArray()
            .ToDictionary(field => field.GetProperty("field_id").GetString()!, field => field.Clone());
    }

    private static string ResolveFixturePath(string relativePath)
    {
        if (File.Exists(relativePath)) return relativePath;
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, relativePath);
            if (File.Exists(candidate)) return candidate;
        }
        throw new FileNotFoundException("Shared fixture not found: " + relativePath);
    }

    private static List<ResetDiff> Evaluate(string id, JsonElement scenario, Dictionary<string, JsonElement> specFields)
    {
        var targetSpec = scenario.GetProperty("target");
        var kind = targetSpec.GetProperty("kind").GetString() ?? throw new Exception($"Scenario {id}: missing target kind");
        (double Temperature, double Tint)? asShot = null;
        if (targetSpec.TryGetProperty("as_shot_wb", out var wbElem) && wbElem.ValueKind == JsonValueKind.Array)
        {
            var items = wbElem.EnumerateArray().Select(x => x.GetDouble()).ToArray();
            asShot = (items[0], items[1]);
        }
        var lensValid = targetSpec.GetProperty("lens_valid").GetBoolean();
        var availableLooks = targetSpec.GetProperty("available_looks").EnumerateArray().Select(x => x.GetString()!).ToHashSet();
        var targetIdentity = new OriginalIdentity(kind == "sdr_raw" ? "scenario-target.arw" : "scenario-target.jpg", 1, 2, 3);
        var initialSettings = kind switch
        {
            "sdr_raw" => new Adjustments(),
            "hdr" => new Adjustments { HDR = new HDRSettings { Mode = HDRMode.Hdr } },
            _ => throw new Exception($"Scenario {id}: unsupported target kind {kind}")
        };
        if (kind == "sdr_raw" && asShot is { } wb) initialSettings.ResolveWhiteBalance(wb);
        var scenarioContext = new AdjustmentTransferContext("scenario-target", kind == "sdr_raw",
            AvailableLookIDs: availableLooks, DefaultExposureMode: kind == "sdr_raw" ? 1 : 2,
            ValidateLens: lensValid ? (_ => { }) : null, CameraWhiteBalance: kind == "sdr_raw" ? asShot : null);
        var seeded = new SavedEdit(targetIdentity, initialSettings.Capture(), null);
        if (targetSpec.TryGetProperty("seed_payload", out var seedElem) && seedElem.ValueKind != JsonValueKind.Null)
            seeded = AdjustmentTransfer.Prepare(AdjustmentPayload.Parse(seedElem.GetRawText()), seeded, scenarioContext with { ValidateLens = _ => { } });

        var expect = scenario.GetProperty("expect");
        var expectValues = expect.GetProperty("values");
        var untouched = expect.GetProperty("untouched").EnumerateArray().Select(x => x.GetString()!).ToArray();
        var observed = expectValues.EnumerateObject().Select(p => ParseField(p.Name))
            .Concat(untouched.Select(ParseField)).ToHashSet();
        var diffs = new List<ResetDiff>();
        var before = observed.Count == 0 ? new Dictionary<F, JsonElement?>() :
            AdjustmentTransfer.Capture(AdjustmentScope.Custom(observed.ToArray()), seeded, scenarioContext).Values.ToDictionary(p => p.Key, p => (JsonElement?)p.Value.Clone());
        var result = EditorAdjustmentRules.PrepareReset(ResetScope(scenario.GetProperty("scope")), seeded);
        var status = result.Status switch
        {
            EditorResetStatus.Ready => "changed",
            EditorResetStatus.NoChange => "unchanged",
            // Windows 把 Invalid 与 Blocked 都归为「未完成重置」；本向量无 blocked 场景，合并观察。
            _ => "blocked"
        };
        var expectedStatus = expect.GetProperty("status").GetString()!;
        if (status != expectedStatus) diffs.Add(new("status", $"status expected={expectedStatus}, actual={status}"));
        if (result.Status == EditorResetStatus.Ready)
        {
            var candidate = result.Candidate!;
            var after = observed.Count == 0 ? new Dictionary<F, JsonElement?>() :
                AdjustmentTransfer.Capture(AdjustmentScope.Custom(observed.ToArray()), candidate, scenarioContext).Values.ToDictionary(p => p.Key, p => (JsonElement?)p.Value.Clone());
            foreach (var pair in expectValues.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal))
            {
                var field = ParseField(pair.Name);
                var expected = Expectation(pair.Value, pair.Name, specFields);
                after.TryGetValue(field, out var actual);
                if (!Same(actual, expected)) diffs.Add(new(pair.Name, $"{pair.Name} expected={Render(expected)}, actual={Render(actual)}"));
            }
            foreach (var name in untouched)
            {
                var field = ParseField(name);
                before.TryGetValue(field, out var from); after.TryGetValue(field, out var to);
                if (!Same(from, to)) diffs.Add(new(name, $"{name} untouched {Render(from)} -> {Render(to)}"));
            }
        }
        return diffs;
    }

    private static EditorResetScope ResetScope(JsonElement scope) => scope.GetProperty("kind").GetString() switch
    {
        "tool" => scope.GetProperty("field").GetString() switch
        {
            "light.contrast" => new(EditorResetKind.Tool, Tool: EditorAdjustmentTool.Contrast),
            "detail.sharpening" => new(EditorResetKind.Tool, Tool: EditorAdjustmentTool.Sharpening),
            var field => throw new Exception($"Unsupported single-reset field: {field}")
        },
        "group" => scope.GetProperty("group").GetString() switch
        {
            "light" => new(EditorResetKind.Group, Group: EditorAdjustmentGroup.Light),
            "color" => new(EditorResetKind.Group, Group: EditorAdjustmentGroup.Color),
            "geometry" => new(EditorResetKind.Group, Group: EditorAdjustmentGroup.Geometry),
            var group => throw new Exception($"Unsupported reset group: {group}")
        },
        "all" => new(EditorResetKind.All),
        var kind => throw new Exception($"Unsupported reset scope kind: {kind}")
    };

    private static F ParseField(string id) => Enum.GetValues<F>().FirstOrDefault(field => field.ID() == id);

    /// @spec_default：spec 表本端默认值按 scale_from_protocol 反映射回协议空间。
    private static JsonElement Expectation(JsonElement marker, string fieldID, Dictionary<string, JsonElement> specFields)
    {
        if (marker.ValueKind == JsonValueKind.String && marker.GetString() == "@spec_default")
        {
            var model = specFields[fieldID].GetProperty("model").GetProperty("windows");
            var def = model.GetProperty("default");
            if (def.ValueKind is JsonValueKind.Null or JsonValueKind.True or JsonValueKind.False || def.ValueKind != JsonValueKind.Number) return def.Clone();
            var value = def.GetDouble();
            var mapped = model.GetProperty("scale_from_protocol").GetString() switch
            {
                "p" => value,
                "p * 100" => value / 100,
                "(p - 1) * 100" => value / 100 + 1,
                "p - 1" => value + 1,
                "-p * 100" => -value / 100,
                "-p" => -value,
                var scale => throw new Exception($"Unsupported scale_from_protocol for {fieldID}: {scale}")
            };
            return JsonDocument.Parse(mapped.ToString("R", CultureInfo.InvariantCulture)).RootElement.Clone();
        }
        return marker.Clone();
    }

    private static bool Same(JsonElement? a, JsonElement? b)
    {
        if (a == null || b == null) return (a == null || a.Value.ValueKind == JsonValueKind.Null) && (b == null || b.Value.ValueKind == JsonValueKind.Null);
        if (a.Value.ValueKind != b.Value.ValueKind) return false;
        return a.Value.ValueKind switch
        {
            JsonValueKind.Number => Math.Abs(a.Value.GetDouble() - b.Value.GetDouble()) <= 1e-6,
            JsonValueKind.String => a.Value.GetString() == b.Value.GetString(),
            JsonValueKind.Object => a.Value.EnumerateObject().Count() == b.Value.EnumerateObject().Count() &&
                a.Value.EnumerateObject().All(p => b.Value.TryGetProperty(p.Name, out var v) && Same(p.Value, v)),
            JsonValueKind.Array => a.Value.GetArrayLength() == b.Value.GetArrayLength() &&
                a.Value.EnumerateArray().Zip(b.Value.EnumerateArray()).All(pair => Same(pair.First, pair.Second)),
            JsonValueKind.Null or JsonValueKind.True or JsonValueKind.False => true,
            _ => false
        };
    }

    private static string Render(JsonElement? value) => value == null ? "<missing>" : value.Value.GetRawText();
}
