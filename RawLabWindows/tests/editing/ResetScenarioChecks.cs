using RawLab.Windows;
using System.Text.Json;

// V-RESET：Windows 消费共享重置场景向量 `reset-scenarios-v1.json`。
// 种子经 `AdjustmentTransfer.Prepare` 写入，重置走生产入口 `EditorAdjustmentRules.PrepareReset`，
// 观察通道复用 `AdjustmentTransfer.Capture` 的 `ToJson()` wire JSON 序列化值；不再本地解析 `@spec_default`，
// 真实序列化分歧显式登记进 KnownResetDivergences。
internal static class ResetScenarioChecks
{
    private static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
    private sealed record ResetDiff(string Key, string Summary);
    private sealed record ResetDivergence(string LedgerId, IReadOnlyDictionary<string, string> FieldReasons)
    {
        internal IReadOnlySet<string> ExpectedKeys => FieldReasons.Keys.ToHashSet(StringComparer.Ordinal);
    }

    // 棘轮上限按 `(scenario, field)` 计数，只减不增；新增任何分歧、空理由、未对齐条目的留档或突破上限均必红。
    // 收口口径（P2-23 / S1）：Windows 基线为 0（0 scenario / 0 field divergences），严禁上调；Mac 基线 4 随 SDR nil->default 收口从 4 -> 0。
    private const int MaxKnownFieldDivergences = 0;

    private static readonly IReadOnlyDictionary<string, ResetDivergence> KnownResetDivergences =
        new Dictionary<string, ResetDivergence>();

    internal static void Run()
    {
        VerifyWirePresenceContract();
        foreach (var (id, div) in KnownResetDivergences)
        {
            Check(!string.IsNullOrWhiteSpace(div.LedgerId), $"Reset divergence {id}: non-blank LedgerId");
            Check(div.FieldReasons.Count > 0, $"Reset divergence {id}: per-field reasons required");
            foreach (var (field, reason) in div.FieldReasons)
                Check(!string.IsNullOrWhiteSpace(reason), $"Reset divergence {id}.{field}: non-blank reason");
        }
        var totalFieldDivergences = KnownResetDivergences.Values.Sum(entry => entry.FieldReasons.Count);
        Check(totalFieldDivergences <= MaxKnownFieldDivergences,
            $"Reset field divergences ({totalFieldDivergences}) must not exceed monotonic ratchet cap ({MaxKnownFieldDivergences})");

        using var document = JsonDocument.Parse(File.ReadAllText(ResolveFixturePath("Shared/fixtures/reset-scenarios-v1.json")));
        var root = document.RootElement;
        Check(root.GetProperty("fixture_version").GetInt32() == 1, "Reset fixture version must be 1");
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
            var diffs = Evaluate(id, scenario);
            var actualKeys = diffs.Select(d => d.Key).ToHashSet();
            var summary = string.Join("; ", diffs.Select(d => d.Summary));
            var hasKnown = KnownResetDivergences.TryGetValue(id, out var known);
            if (diffs.Count > 0 && !hasKnown) problems.Add($"Scenario {id} diverged: {summary}");
            else if (diffs.Count == 0 && hasKnown) problems.Add($"Scenario {id} now matches fixture; remove stale divergence ({known!.LedgerId})");
            else if (hasKnown && !actualKeys.SetEquals(known!.ExpectedKeys))
                problems.Add($"Scenario {id} divergence keys changed (expected=[{string.Join(", ", known.ExpectedKeys.Order(StringComparer.Ordinal))}], actual=[{string.Join(", ", actualKeys.Order(StringComparer.Ordinal))}]): {summary}");
            else if (hasKnown)
            {
                foreach (var diff in diffs)
                    Console.WriteLine($"KNOWN DIVERGENCE [{id}.{diff.Key}] ({known!.LedgerId} - {known.FieldReasons[diff.Key]}): {diff.Summary}");
            }
        }
        Check(seenIDs.Count == scenarios.GetArrayLength(), "All reset scenario IDs visited");
        var unknownRegistered = KnownResetDivergences.Keys.Except(evaluatedIDs).ToArray();
        Check(unknownRegistered.Length == 0, "Registered reset divergences do not match evaluated scenarios: " + string.Join(", ", unknownRegistered));
        if (problems.Count > 0) throw new Exception(string.Join(Environment.NewLine, problems));
        Console.WriteLine($"PASS: {evaluatedIDs.Count} Windows reset scenarios evaluated ({skippedIDs.Count} platform-scoped skipped, {KnownResetDivergences.Count} scenario / {totalFieldDivergences} field divergences; ratchet cap {MaxKnownFieldDivergences})");
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

    private static List<ResetDiff> Evaluate(string id, JsonElement scenario)
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
        var before = observed.Count == 0 ? new Dictionary<string, JsonElement>() :
            WireValues(AdjustmentTransfer.Capture(AdjustmentScope.Custom(observed.ToArray()), seeded, scenarioContext));
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
            var after = observed.Count == 0 ? new Dictionary<string, JsonElement>() :
                WireValues(AdjustmentTransfer.Capture(AdjustmentScope.Custom(observed.ToArray()), candidate, scenarioContext));
            diffs.AddRange(DiffWireValues(before, after, expectValues, untouched));
        }
        return diffs;
    }

    private static IEnumerable<ResetDiff> DiffWireValues(
        IReadOnlyDictionary<string, JsonElement> before,
        IReadOnlyDictionary<string, JsonElement> after,
        JsonElement expectValues,
        IEnumerable<string> untouched)
    {
        foreach (var pair in expectValues.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal))
        {
            JsonElement? actual = after.TryGetValue(pair.Name, out var found) ? found : null;
            if (!Same(actual, pair.Value)) yield return new(pair.Name, $"{pair.Name} expected={Render(pair.Value)}, actual={Render(actual)}");
        }
        foreach (var name in untouched)
        {
            JsonElement? from = before.TryGetValue(name, out var beforeValue) ? beforeValue : null;
            JsonElement? to = after.TryGetValue(name, out var afterValue) ? afterValue : null;
            if (!Same(from, to)) yield return new(name, $"{name} untouched {Render(from)} -> {Render(to)}");
        }
    }

    private static void VerifyWirePresenceContract()
    {
        using var vectorDoc = JsonDocument.Parse(
            "{\"before_values\":{\"geometry.lens.profile_id\":null},\"after_values\":{},\"expect_values\":{\"color.white_balance.temperature_kelvin\":null},\"untouched\":[\"geometry.lens.profile_id\"]}");
        var root = vectorDoc.RootElement;
        var jsonNull = root.GetProperty("before_values").GetProperty("geometry.lens.profile_id");
        Check(!Same(null, jsonNull), "Wire presence contract: missing key must not equal explicit null");
        Check(!Same(jsonNull, null), "Wire presence contract: explicit null must not equal missing key");
        Check(Same(jsonNull, jsonNull), "Wire presence contract: explicit null equals explicit null");
        Check(Same(null, null), "Wire presence contract: missing equals missing");
        var diffs = DiffWireValues(
            ReadWireValues(root.GetProperty("before_values")),
            ReadWireValues(root.GetProperty("after_values")),
            root.GetProperty("expect_values"),
            root.GetProperty("untouched").EnumerateArray().Select(x => x.GetString()!)).ToArray();
        Check(diffs.Any(d => d.Key == "color.white_balance.temperature_kelvin" && d.Summary.Contains("expected=null, actual=<missing>", StringComparison.Ordinal)),
            "Wire presence contract: omitted expect key must fail against explicit null");
        Check(diffs.Any(d => d.Key == "geometry.lens.profile_id" && d.Summary.Contains("null -> <missing>", StringComparison.Ordinal)),
            "Wire presence contract: dropped untouched null key must fail");
    }

    private static Dictionary<string, JsonElement> WireValues(AdjustmentPayload payload)
    {
        using var document = JsonDocument.Parse(payload.ToJson());
        return ReadWireValues(document.RootElement.GetProperty("values"));
    }

    private static Dictionary<string, JsonElement> ReadWireValues(JsonElement valuesElement) =>
        valuesElement.EnumerateObject().ToDictionary(p => p.Name, p => p.Value.Clone());

    private static EditorResetScope ResetScope(JsonElement scope) => scope.GetProperty("kind").GetString() switch
    {
        "tool" => scope.GetProperty("field").GetString() switch
        {
            "light.contrast" => new(EditorResetKind.Tool, Tool: EditorAdjustmentTool.Contrast),
            "detail.sharpening" => new(EditorResetKind.Tool, Tool: EditorAdjustmentTool.Sharpening),
            "hdr.peak_limit_ev" => new(EditorResetKind.Tool, Tool: EditorAdjustmentTool.HdrPeakLimit),
            var field => throw new Exception($"Unsupported single-reset field: {field}")
        },
        "group" => scope.GetProperty("group").GetString() switch
        {
            "light" => new(EditorResetKind.Group, Group: EditorAdjustmentGroup.Light),
            "color" => new(EditorResetKind.Group, Group: EditorAdjustmentGroup.Color),
            "detail" => new(EditorResetKind.Group, Group: EditorAdjustmentGroup.Detail),
            "geometry" => new(EditorResetKind.Group, Group: EditorAdjustmentGroup.Geometry),
            "hdr_rendition" => new(EditorResetKind.Group, Group: EditorAdjustmentGroup.HdrRendition),
            var group => throw new Exception($"Unsupported reset group: {group}")
        },
        "all" => new(EditorResetKind.All),
        var kind => throw new Exception($"Unsupported reset scope kind: {kind}")
    };

    private static AdjustmentField ParseField(string id) => AdjustmentFields.Parse(id);

    private static bool Same(JsonElement? a, JsonElement? b)
    {
        if (a == null || b == null) return a == null && b == null;
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
