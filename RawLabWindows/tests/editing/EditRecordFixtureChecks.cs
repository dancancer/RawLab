using RawLab.Windows;
using System.Text.Json;
using System.Text.Json.Nodes;

// P2-01 (S1): Windows 消费共享持久化编辑记录 fixture `Shared/fixtures/edit-records-v1.json`。
// 登记当前真行为差异前以代码实况逐条核验；不静默修改实现或压低 fixture 期望以迎合现实现状。
internal static class EditRecordFixtureChecks
{
    private sealed record EditRecordDivergence(string LedgerId, string Reason, string? ExpectedObservedSubstring = null);
    private sealed class ExpectationMismatchException(string message) : Exception(message);
    private sealed class HarnessSetupException(string message) : Exception(message);
    private enum EvalCatchScope { ExpectationOnly, ExpectationOrPersistenceRejection }

    // 棘轮上限只减不增；新增任何分歧、空理由、陈旧条目、观测摘要漂移或突破上限均必红。
    // 仅 2 条 Tier-1 X1 扩展块闭集拒读（ToneControlsSettings / AtmosphereSettings 应用 Disallow）；
    // Tier-2 渲染块 14 条与 roundtrip/compat/boundary 全数通过。
    private const int MaxKnownEditRecordDivergences = 2;

    private static readonly IReadOnlyDictionary<string, EditRecordDivergence> KnownEditRecordDivergences =
        new Dictionary<string, EditRecordDivergence>(StringComparer.Ordinal)
        {
            ["x1-tone-controls-unknown-field"] = new(
                "EDIT-DIV-WIN-X1-01",
                "Tier-1 outer_container_or_extension: ToneControlsSettings applies [JsonUnmappedMemberHandling(Disallow)] instead of tolerating unknown extension keys",
                ExpectedObservedSubstring: "UnusableEditRecordException"),
            ["x1-atmosphere-unknown-field"] = new(
                "EDIT-DIV-WIN-X1-02",
                "Tier-1 outer_container_or_extension: AtmosphereSettings applies [JsonUnmappedMemberHandling(Disallow)] instead of tolerating unknown extension keys",
                ExpectedObservedSubstring: "UnusableEditRecordException"),
        };

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new ExpectationMismatchException(message);
    }

    private static void CheckSetup(bool condition, string message)
    {
        if (!condition) throw new HarnessSetupException(message);
    }

    private static bool Approx(double a, double b, double tol = 1e-4) => Math.Abs(a - b) <= tol;

    private static readonly string[] HslChannels = ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"];

    internal static void Run()
    {
        foreach (var (id, div) in KnownEditRecordDivergences)
        {
            CheckSetup(!string.IsNullOrWhiteSpace(div.LedgerId), $"EditRecord divergence {id}: non-blank LedgerId required");
            CheckSetup(!string.IsNullOrWhiteSpace(div.Reason), $"EditRecord divergence {id}: non-blank Reason required");
        }
        CheckSetup(KnownEditRecordDivergences.Count <= MaxKnownEditRecordDivergences,
            $"EditRecord divergences ({KnownEditRecordDivergences.Count}) must not exceed monotonic ratchet cap ({MaxKnownEditRecordDivergences})");

        using var doc = JsonDocument.Parse(File.ReadAllText(ResolveFixturePath("Shared/fixtures/edit-records-v1.json")));
        var root = doc.RootElement;
        CheckSetup(root.GetProperty("fixture_version").GetInt32() == 1, "fixture_version must be 1");
        CheckSetup(root.GetProperty("spec_version").GetInt32() == 1, "spec_version must be 1");

        var roundtripList = root.GetProperty("roundtrip_records").EnumerateArray().ToArray();
        var byId = roundtripList.ToDictionary(r => r.GetProperty("id").GetString()!, r => r.Clone(), StringComparer.Ordinal);
        CheckSetup(roundtripList.Length == byId.Count, "Duplicate roundtrip_records ID");

        var tempRoot = Path.Combine(Path.GetTempPath(), "rawlab-win-edit-fixture-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempRoot);
        try
        {
            var failures = new List<string>();
            var evaluatedIds = new HashSet<string>(StringComparer.Ordinal);

            void Evaluate(string scenarioId, EvalCatchScope catchScope, Action body)
            {
                CheckSetup(evaluatedIds.Add(scenarioId), "Duplicate evaluated scenario ID: " + scenarioId);
                try
                {
                    body();
                    if (KnownEditRecordDivergences.TryGetValue(scenarioId, out var stale))
                        throw new HarnessSetupException($"Stale divergence ledger entry '{scenarioId}' ({stale.LedgerId}): scenario now passes");
                    Console.WriteLine($"PASS: {scenarioId}");
                }
                catch (Exception error) when (
                    error is ExpectationMismatchException ||
                    (catchScope == EvalCatchScope.ExpectationOrPersistenceRejection && error is UnusableEditRecordException))
                {
                    var observed = $"{error.GetType().Name}: {error.Message}";
                    if (KnownEditRecordDivergences.TryGetValue(scenarioId, out var reg))
                    {
                        if (!string.IsNullOrEmpty(reg.ExpectedObservedSubstring) &&
                            !observed.Contains(reg.ExpectedObservedSubstring, StringComparison.Ordinal))
                        {
                            var drift = $"DIVERGENCE DRIFT [{scenarioId}] ({reg.LedgerId}): expected substring '{reg.ExpectedObservedSubstring}', got '{observed}'";
                            failures.Add(drift);
                            Console.WriteLine("FAIL: " + drift);
                        }
                        else
                        {
                            Console.WriteLine($"KNOWN DIVERGENCE [{scenarioId}] ({reg.LedgerId}): {reg.Reason} | observed: {observed}");
                        }
                    }
                    else
                    {
                        var line = $"RED ANCHOR [{scenarioId}]: {observed}";
                        failures.Add(line);
                        Console.WriteLine("FAIL: " + line);
                    }
                }
            }

            // 1. Roundtrip records (setup/save before eval; reload/verify inside eval)
            foreach (var rec in roundtripList)
            {
                var id = rec.GetProperty("id").GetString()!;
                var photoName = rec.GetProperty("photo").GetProperty("name").GetString()!;
                var (built, metadata) = BuildSnapshot(rec);
                var dir = Path.Combine(tempRoot, "rt-" + id);
                Directory.CreateDirectory(dir);
                var photoPath = TouchPhoto(tempRoot, photoName);
                var store = new EditStore(dir);
                store.Save(photoPath, built.Settings, built.Look);
                var hasKeptReceipt = metadata.TryGetProperty("migration_receipt", out var receipt) &&
                    receipt.TryGetProperty("status", out var st) && st.GetString() == ProcessingMigrationReceipt.Kept;
                if (hasKeptReceipt)
                {
                    var beforeEdit = store.Find(photoPath) ?? throw new HarnessSetupException($"{id}: expected saved edit before migration receipt");
                    var identity = OriginalIdentity.Read(photoPath);
                    _ = store.CommitProcessingMigration(identity, beforeEdit.Copy(), beforeEdit.Copy(), ProcessingMigrationReceipt.Kept);
                }

                Evaluate("roundtrip:" + id, EvalCatchScope.ExpectationOnly, () =>
                {
                    var reopened = new EditStore(dir);
                    var reloaded = reopened.Find(photoPath) ?? throw new ExpectationMismatchException($"{id}: reloaded edit must not be null");
                    VerifyEdit(reloaded, rec);
                    if (hasKeptReceipt)
                    {
                        Check(reopened.ReadProcessingMigration(photoPath)?.Status == ProcessingMigrationReceipt.Kept,
                            $"{id}: kept migration receipt must reload");
                    }
                });
            }

            // 2. X1 read-side Two-Tier unknown field scenarios
            foreach (var sc in root.GetProperty("unknown_field_scenarios").EnumerateArray())
            {
                var id = sc.GetProperty("id").GetString()!;
                var baseId = sc.GetProperty("base_record_id").GetString()!;
                var baseRec = byId[baseId];
                var scope = sc.GetProperty("target_scope").GetString()!;
                var key = sc.GetProperty("inject_key").GetString()!;
                var val = sc.GetProperty("inject_value").Clone();
                var expectMode = sc.GetProperty("expect").GetString()!;
                var preserveRawDisk = sc.TryGetProperty("preserve_raw_disk_entry", out var prde) && prde.GetBoolean();

                var (built, _) = BuildSnapshot(baseRec);
                var (sibBuilt, _) = BuildSnapshot(byId["raster-sdr-neutral"]);
                var dir = Path.Combine(tempRoot, "x1-" + id);
                Directory.CreateDirectory(dir);
                var editsFile = Path.Combine(dir, "edits.json");
                var targetPath = TouchPhoto(tempRoot, $"target-{id}.DNG");
                var sibPath = TouchPhoto(tempRoot, $"sibling-{id}.JPG");
                var store = new EditStore(dir);
                store.Save(targetPath, built.Settings, built.Look);
                store.Save(sibPath, sibBuilt.Settings, sibBuilt.Look);

                var registry = JsonNode.Parse(File.ReadAllText(editsFile))!.AsObject();
                var tk = OriginalIdentity.Read(targetPath).Path;
                MutateJsonScope(registry, tk, scope, key, val);
                File.WriteAllText(editsFile, registry.ToJsonString());

                var catchScope = expectMode switch
                {
                    "load_preserving_values" => EvalCatchScope.ExpectationOrPersistenceRejection,
                    "reject_isolating_record" => EvalCatchScope.ExpectationOnly,
                    _ => throw new HarnessSetupException("Unhandled X1 expect mode: " + expectMode)
                };

                Evaluate(id, catchScope, () =>
                {
                    var reopened = new EditStore(dir);
                    if (expectMode == "load_preserving_values")
                    {
                        var loadedTarget = reopened.Find(targetPath) ?? throw new ExpectationMismatchException($"{id}: Tier-1 target record must remain readable");
                        VerifyEdit(loadedTarget, baseRec);
                        var loadedSibling = reopened.Find(sibPath);
                        Check(loadedSibling != null, $"{id}: Tier-1 sibling record must remain readable");
                        if (preserveRawDisk)
                        {
                            var updatedSib = sibBuilt.Settings.Copy();
                            updatedSib.Values[(int)Parameter.Exposure] = 1.25;
                            reopened.Save(sibPath, updatedSib, sibBuilt.Look);

                            var diskAfter = JsonNode.Parse(File.ReadAllText(editsFile))!.AsObject();
                            var recordsAfter = diskAfter["Records"]!.AsObject();
                            if (scope == "store_sibling_entry")
                            {
                                const string extraKey = @"C:\tmp\__future_sibling_photo__.ARW";
                                Check(recordsAfter.ContainsKey(extraKey) && recordsAfter[extraKey]![key] != null,
                                    $"{id}: unknown sibling store entry must stay on disk across sibling save");
                            }
                            else
                            {
                                Check(recordsAfter.ContainsKey(tk), $"{id}: target raw disk entry must stay on disk across sibling save");
                            }
                        }
                    }
                    else
                    {
                        var threw = false;
                        try { _ = reopened.ReadState(targetPath); }
                        catch (UnusableEditRecordException) { threw = true; }
                        Check(threw, $"{id}: Tier-2 unknown key in '{scope}' must reject record with UnusableEditRecordException");
                        Check(reopened.Find(sibPath) != null, $"{id}: healthy sibling must remain readable");
                        if (preserveRawDisk)
                        {
                            var updatedSib = sibBuilt.Settings.Copy();
                            updatedSib.Values[(int)Parameter.Exposure] = 1.25;
                            reopened.Save(sibPath, updatedSib, sibBuilt.Look);

                            var diskAfter = JsonNode.Parse(File.ReadAllText(editsFile))!.AsObject();
                            Check(diskAfter["Records"]!.AsObject().ContainsKey(tk),
                                $"{id}: rejected Tier-2 record bytes must stay on disk across sibling save");
                        }
                    }
                });
            }

            // 3. Cross-version compatibility scenarios
            foreach (var sc in root.GetProperty("compatibility_scenarios").EnumerateArray())
            {
                var id = sc.GetProperty("id").GetString()!;
                var kind = sc.GetProperty("kind").GetString()!;
                var baseRec = byId[sc.GetProperty("base_record_id").GetString()!];

                switch (kind)
                {
                    case "legacy_omitted_extensions":
                    {
                        var (built, _) = BuildSnapshot(baseRec);
                        var dir = Path.Combine(tempRoot, "c-" + id);
                        Directory.CreateDirectory(dir);
                        var editsFile = Path.Combine(dir, "edits.json");
                        var url = TouchPhoto(tempRoot, $"c-{id}.JPG");
                        new EditStore(dir).Save(url, built.Settings, built.Look);

                        var registry = JsonNode.Parse(File.ReadAllText(editsFile))!.AsObject();
                        var tk = OriginalIdentity.Read(url).Path;
                        var settingsObj = registry["Records"]!.AsObject()[tk]!.AsObject()["Settings"]!.AsObject();
                        foreach (var drop in new[] {
                            "Processing", "X3fMode", "MasterRecipeSettingsVersion", "ToneControls",
                            "Atmosphere", "ColorGrading", "Curve", "HDR", "hdrCameraAI", "ProRAWDecodeVersion" })
                            settingsObj.Remove(drop);
                        File.WriteAllText(editsFile, registry.ToJsonString());

                        JsonElement wjson = default;
                        var hasWire = sc.TryGetProperty("legacy_wire_samples", out var lws) &&
                                      lws.TryGetProperty("windows_json", out wjson);
                        var wireDir = Path.Combine(tempRoot, "c-wire-" + id);
                        string? wirePath = null;
                        JsonElement expDecoded = default;
                        if (hasWire)
                        {
                            Directory.CreateDirectory(wireDir);
                            wirePath = TouchPhoto(tempRoot, wjson.GetProperty("photo_name").GetString()!);
                            var wireId = OriginalIdentity.Read(wirePath);
                            var wireJson = wjson.GetProperty("store_json").GetString()!
                                .Replace("\"__PHOTO_PATH__\"", JsonSerializer.Serialize(wireId.Path), StringComparison.Ordinal)
                                .Replace("__IDENTITY_JSON__", JsonSerializer.Serialize(wireId), StringComparison.Ordinal);
                            CheckSetup(!wireJson.Contains("__PHOTO_PATH__", StringComparison.Ordinal) &&
                                       !wireJson.Contains("__IDENTITY_JSON__", StringComparison.Ordinal),
                                $"{id}: failed to substitute windows_json placeholders");
                            File.WriteAllText(Path.Combine(wireDir, "edits.json"), wireJson);
                            expDecoded = wjson.GetProperty("expect_decoded").Clone();
                        }

                        Evaluate(id, EvalCatchScope.ExpectationOrPersistenceRejection, () =>
                        {
                            var loaded = new EditStore(dir).Find(url) ?? throw new ExpectationMismatchException($"{id}: legacy record must load");
                            Check(loaded.Settings.Processing.Version == 1, $"{id}: omitted Processing must default to v1");
                            Check(loaded.Settings.X3fMode == X3fMode.Legacy, $"{id}: omitted X3fMode must default to Legacy");
                            Check(loaded.Settings.HDR == null, $"{id}: omitted HDR must default to null");
                            if (hasWire && wirePath != null)
                            {
                                var wireLoaded = new EditStore(wireDir).Find(wirePath) ?? throw new ExpectationMismatchException($"{id}: legacy windows_json wire sample must load");
                                Check(wireLoaded.Look == expDecoded.GetProperty("look").GetString(), $"{id}: wire Look mismatch");
                                Check(wireLoaded.Settings.Processing.Version == expDecoded.GetProperty("processing_version").GetInt32(), $"{id}: wire Processing.Version");
                                Check((wireLoaded.Settings.X3fMode == X3fMode.Legacy ? "legacy" : "normal-v1") == expDecoded.GetProperty("x3f_mode").GetString(), $"{id}: wire X3fMode");
                                Check(wireLoaded.Settings.HDR == null, $"{id}: wire HDR must default null");
                                Check(!wireLoaded.Settings.CameraWhiteBalance, $"{id}: wire CameraWhiteBalance=false");
                                Check(Approx(wireLoaded.Settings.AsShotTemperature ?? -1, 6500.0), $"{id}: wire AsShotTemperature");
                                Check(Approx(wireLoaded.Settings.AsShotTint ?? -999, 0.0), $"{id}: wire AsShotTint");
                                Check(Approx(wireLoaded.Settings.Values[(int)Parameter.Strength], expDecoded.GetProperty("strength").GetDouble()), $"{id}: wire strength");
                                Check(Approx(wireLoaded.Settings.Values[(int)Parameter.Exposure], expDecoded.GetProperty("exposure").GetDouble()), $"{id}: wire exposure");
                                Check(Approx(wireLoaded.Settings.Values[(int)Parameter.Temperature], expDecoded.GetProperty("temperature").GetDouble()), $"{id}: wire temperature");
                                Check(Approx(wireLoaded.Settings.Values[(int)Parameter.Tint], expDecoded.GetProperty("tint").GetDouble()), $"{id}: wire tint");
                                Check(Approx(wireLoaded.Settings.Values[(int)Parameter.Contrast], expDecoded.GetProperty("contrast").GetDouble()), $"{id}: wire contrast");
                                Check(Approx(wireLoaded.Settings.Values[(int)Parameter.Highlights], expDecoded.GetProperty("highlights").GetDouble()), $"{id}: wire highlights");
                                Check(Approx(wireLoaded.Settings.Values[(int)Parameter.Shadows], expDecoded.GetProperty("shadows").GetDouble()), $"{id}: wire shadows");
                                Check(Approx(wireLoaded.Settings.Values[(int)Parameter.Saturation], expDecoded.GetProperty("saturation").GetDouble()), $"{id}: wire saturation");
                                Check(Approx(wireLoaded.Settings.Values[(int)Parameter.Sharpening], expDecoded.GetProperty("sharpening").GetDouble()), $"{id}: wire sharpening");
                            }
                        });
                        break;
                    }
                    case "sdr_reset_preserves_dormant_hdr":
                    {
                        var (built, _) = BuildSnapshot(baseRec);
                        var dir = Path.Combine(tempRoot, "c-" + id);
                        Directory.CreateDirectory(dir);
                        var url = TouchPhoto(tempRoot, $"c-{id}.ARW");
                        new EditStore(dir).Save(url, built.Settings, built.Look);

                        var aiBaseId = sc.GetProperty("camera_ai_base_record_id").GetString()!;
                        var (builtAi, _) = BuildSnapshot(byId[aiBaseId]);
                        CheckSetup(builtAi.Settings.HDR != null && builtAi.Settings.HDRCameraAIEnabled,
                            $"{id}: camera_ai_base_record_id '{aiBaseId}' must carry HDR subtree and HDRCameraAIEnabled=true");
                        var aiValues = (double[])builtAi.Settings.Values.Clone();
                        aiValues[(int)Parameter.Exposure] = 0.75;
                        var dormantAiSettings = builtAi.Settings with
                        {
                            Values = aiValues,
                            HDR = builtAi.Settings.HDR! with { Mode = HDRMode.Sdr }
                        };
                        var aiDir = Path.Combine(tempRoot, "c-ai-" + id);
                        Directory.CreateDirectory(aiDir);
                        var aiUrl = TouchPhoto(tempRoot, $"c-ai-{id}.DNG");
                        new EditStore(aiDir).Save(aiUrl, dormantAiSettings, builtAi.Look);

                        var expectHdrCamAi = sc.GetProperty("expect").GetProperty("hdr_camera_ai_preserved").GetBoolean();

                        Evaluate(id, EvalCatchScope.ExpectationOnly, () =>
                        {
                            var loadedBefore = new EditStore(dir).ReadState(url);
                            Check(loadedBefore.Edit != null, $"{id}: expected seeded edit");
                            var res = EditorAdjustmentRules.PrepareReset(new(EditorResetKind.All), loadedBefore.Edit!);
                            Check(res.Status == EditorResetStatus.Ready && res.Candidate != null, $"{id}: expected Ready reset candidate");
                            _ = new EditStore(dir).SaveState(res.Candidate!.Identity, res.Candidate);

                            var after = new EditStore(dir).Find(url) ?? throw new ExpectationMismatchException($"{id}: reset record must remain readable");
                            Check(after.Settings.Processing.Version == 2, $"{id}: Processing v2 preserved");
                            Check(after.Settings.X3fMode == X3fMode.Legacy, $"{id}: X3fMode legacy preserved");
                            Check(after.Settings.ProRAWDecodeVersion == 2, $"{id}: ProRAWDecodeVersion 2 preserved");
                            Check(after.Settings.HDR?.Mode == HDRMode.Sdr, $"{id}: dormant HDR mode stays Sdr");
                            Check(Approx(after.Settings.HDR?.Exposure ?? -99, -0.5), $"{id}: dormant HDR exposure preserved");

                            var loadedAiBefore = new EditStore(aiDir).ReadState(aiUrl);
                            Check(loadedAiBefore.Edit != null, $"{id}: expected seeded camera-AI edit");
                            var resAi = EditorAdjustmentRules.PrepareReset(new(EditorResetKind.All), loadedAiBefore.Edit!);
                            Check(resAi.Status == EditorResetStatus.Ready && resAi.Candidate != null,
                                $"{id}: expected Ready camera-AI reset candidate (got {resAi.Status}: {resAi.Reason})");
                            _ = new EditStore(aiDir).SaveState(resAi.Candidate!.Identity, resAi.Candidate);

                            var afterAi = new EditStore(aiDir).Find(aiUrl) ?? throw new ExpectationMismatchException($"{id}: camera-AI reset record must remain readable");
                            Check(afterAi.Settings.HDRCameraAIEnabled == expectHdrCamAi, $"{id}: HDRCameraAIEnabled preserved across SDR reset");
                            Check(afterAi.Settings.HDR?.Mode == HDRMode.Sdr, $"{id}: camera-AI dormant HDR mode stays Sdr");
                            Check(Approx(afterAi.Settings.HDR?.Exposure ?? -99, 0.25), $"{id}: camera-AI dormant HDR exposure preserved");
                            Check(Approx(afterAi.Settings.Values[(int)Parameter.Exposure], 0.0), $"{id}: camera-AI SDR exposure reset to 0");
                        });
                        break;
                    }
                    case "future_processing_version":
                    {
                        var sibRec = byId[sc.GetProperty("sibling_record_id").GetString()!];
                        var (built, _) = BuildSnapshot(baseRec);
                        var (sibBuilt, _) = BuildSnapshot(sibRec);
                        var dir = Path.Combine(tempRoot, "c-" + id);
                        Directory.CreateDirectory(dir);
                        var editsFile = Path.Combine(dir, "edits.json");
                        var targetPath = TouchPhoto(tempRoot, $"c-fut-{id}.ARW");
                        var sibPath = TouchPhoto(tempRoot, $"c-sib-{id}.JPG");
                        var store = new EditStore(dir);
                        store.Save(targetPath, built.Settings, built.Look);
                        store.Save(sibPath, sibBuilt.Settings, sibBuilt.Look);

                        var registry = JsonNode.Parse(File.ReadAllText(editsFile))!.AsObject();
                        var tk = OriginalIdentity.Read(targetPath).Path;
                        var settingsObj = registry["Records"]!.AsObject()[tk]!.AsObject()["Settings"]!.AsObject();
                        settingsObj["Processing"] = new JsonObject
                        {
                            ["family"] = "rawlab",
                            ["version"] = sc.GetProperty("processing_version").GetInt32(),
                            ["quality"] = "standard"
                        };
                        File.WriteAllText(editsFile, registry.ToJsonString());

                        Evaluate(id, EvalCatchScope.ExpectationOnly, () =>
                        {
                            var reopened = new EditStore(dir);
                            var threw = false;
                            try { _ = reopened.ReadState(targetPath); }
                            catch (UnusableEditRecordException) { threw = true; }
                            Check(threw, $"{id}: processing.version=99 must throw UnusableEditRecordException");
                            Check(reopened.Find(sibPath) != null, $"{id}: healthy sibling must remain readable");

                            var updatedSib = sibBuilt.Settings.Copy();
                            updatedSib.Values[(int)Parameter.Exposure] = 1.5;
                            reopened.Save(sibPath, updatedSib, sibBuilt.Look);

                            var diskAfter = JsonNode.Parse(File.ReadAllText(editsFile))!.AsObject();
                            Check(diskAfter["Records"]!.AsObject().ContainsKey(tk),
                                $"{id}: unreadable future record preserved on disk across sibling save");
                        });
                        break;
                    }
                    case "corrupt_entry":
                    {
                        var sibRec = byId[sc.GetProperty("sibling_record_id").GetString()!];
                        var (built, _) = BuildSnapshot(baseRec);
                        var (sibBuilt, _) = BuildSnapshot(sibRec);
                        var dir = Path.Combine(tempRoot, "c-" + id);
                        Directory.CreateDirectory(dir);
                        var editsFile = Path.Combine(dir, "edits.json");
                        var targetPath = TouchPhoto(tempRoot, $"c-bad-{id}.ARW");
                        var sibPath = TouchPhoto(tempRoot, $"c-sib2-{id}.JPG");
                        var store = new EditStore(dir);
                        store.Save(targetPath, built.Settings, built.Look);
                        store.Save(sibPath, sibBuilt.Settings, sibBuilt.Look);

                        var registry = JsonNode.Parse(File.ReadAllText(editsFile))!.AsObject();
                        var tk = OriginalIdentity.Read(targetPath).Path;
                        registry["Records"]!.AsObject()[tk] = "corrupt-entry-payload";
                        File.WriteAllText(editsFile, registry.ToJsonString());

                        Evaluate(id, EvalCatchScope.ExpectationOnly, () =>
                        {
                            var reopened = new EditStore(dir);
                            var threw = false;
                            try { _ = reopened.ReadState(targetPath); }
                            catch (UnusableEditRecordException) { threw = true; }
                            Check(threw, $"{id}: corrupt entry must throw UnusableEditRecordException");
                            Check(reopened.Find(sibPath) != null, $"{id}: healthy sibling must remain readable");

                            var updatedSib = sibBuilt.Settings.Copy();
                            updatedSib.Values[(int)Parameter.Exposure] = 1.1;
                            reopened.Save(sibPath, updatedSib, sibBuilt.Look);

                            var diskText = File.ReadAllText(editsFile);
                            Check(diskText.Contains("corrupt-entry-payload", StringComparison.Ordinal),
                                $"{id}: corrupt entry bytes preserved across sibling save");
                        });
                        break;
                    }
                    case "negative_zero":
                    {
                        var (built, _) = BuildSnapshot(baseRec);
                        var snap = built.Settings.Copy();
                        snap.Values[(int)Parameter.Exposure] = 0.0;
                        var dir = Path.Combine(tempRoot, "c-" + id);
                        Directory.CreateDirectory(dir);
                        var editsFile = Path.Combine(dir, "edits.json");
                        var url = TouchPhoto(tempRoot, $"c-nz-{id}.JPG");
                        new EditStore(dir).Save(url, snap, built.Look);

                        var registry = JsonNode.Parse(File.ReadAllText(editsFile))!.AsObject();
                        var tk = OriginalIdentity.Read(url).Path;
                        var valuesArr = registry["Records"]!.AsObject()[tk]!.AsObject()["Settings"]!.AsObject()["Values"]!.AsArray();
                        valuesArr[(int)Parameter.Exposure] = "__NEG_ZERO_SENTINEL__";
                        var mutated = registry.ToJsonString().Replace("\"__NEG_ZERO_SENTINEL__\"", "-0.0", StringComparison.Ordinal);
                        CheckSetup(mutated.Contains("-0.0", StringComparison.Ordinal), $"{id}: test setup failed to inject -0.0");
                        File.WriteAllText(editsFile, mutated);

                        var assertSignBitPositive = sc.GetProperty("expect").TryGetProperty("assert_sign_bit_positive", out var asbp) && asbp.GetBoolean();

                        Evaluate(id, EvalCatchScope.ExpectationOrPersistenceRejection, () =>
                        {
                            var loaded = new EditStore(dir).Find(url) ?? throw new ExpectationMismatchException($"{id}: negative zero record failed to load");
                            var exposure = loaded.Settings.Values[(int)Parameter.Exposure];
                            Check(exposure == 0.0, $"{id}: -0.0 must load numerically equal to 0.0 (got {exposure})");
                            if (assertSignBitPositive)
                            {
                                Check(!double.IsNegative(exposure),
                                    $"{id}: -0.0 must canonicalize to +0.0 (got {exposure}, IsNegative={double.IsNegative(exposure)})");
                            }
                        });
                        break;
                    }
                    default:
                        throw new HarnessSetupException("Unhandled compat kind: " + kind);
                }
            }

            // 4. Boundary rejection scenarios
            foreach (var sc in root.GetProperty("boundary_scenarios").EnumerateArray())
            {
                var id = sc.GetProperty("id").GetString()!;
                var baseRec = byId[sc.GetProperty("base_record_id").GetString()!];
                var sibRec = byId[sc.GetProperty("sibling_record_id").GetString()!];
                var mutation = sc.GetProperty("mutation");
                var mKind = mutation.GetProperty("kind").GetString()!;

                var (built, _) = BuildSnapshot(baseRec);
                var (sibBuilt, _) = BuildSnapshot(sibRec);
                var dir = Path.Combine(tempRoot, "b-" + id);
                Directory.CreateDirectory(dir);
                var editsFile = Path.Combine(dir, "edits.json");
                var targetPath = TouchPhoto(tempRoot, $"b-t-{id}.DNG");
                var sibPath = TouchPhoto(tempRoot, $"b-s-{id}.JPG");
                var store = new EditStore(dir);
                store.Save(targetPath, built.Settings, built.Look);
                store.Save(sibPath, sibBuilt.Settings, sibBuilt.Look);

                var registry = JsonNode.Parse(File.ReadAllText(editsFile))!.AsObject();
                var tk = OriginalIdentity.Read(targetPath).Path;
                var settingsObj = registry["Records"]!.AsObject()[tk]!.AsObject()["Settings"]!.AsObject();

                switch (mKind)
                {
                    case "out_of_range":
                    {
                        var field = mutation.GetProperty("field").GetString()!;
                        var val = mutation.GetProperty("value").GetDouble();
                        switch (field)
                        {
                            case "light.exposure":
                                settingsObj["Values"]!.AsArray()[(int)Parameter.Exposure] = val;
                                break;
                            case "color.white_balance.temperature_kelvin":
                                settingsObj["Values"]!.AsArray()[(int)Parameter.Temperature] = val;
                                break;
                            case "effects.vignette.amount":
                                settingsObj["Effects"]!.AsObject()["VignetteAmount"] = val;
                                break;
                            case "color.hsl.hue.red":
                                settingsObj["Hsl"]!.AsObject()["Values"]!.AsArray()[0] = val;
                                break;
                            case "color.grading.shadows.hue":
                                settingsObj["ColorGrading"]!.AsObject()["Shadows"]!.AsObject()["Hue"] = val;
                                break;
                            case "hdr.peak_limit_ev":
                                settingsObj["HDR"]!.AsObject()["rendition"]!.AsObject()["peak_limit_ev"] = val;
                                break;
                            default:
                                throw new HarnessSetupException("Unhandled out_of_range field: " + field);
                        }
                        break;
                    }
                    case "crop_overflow":
                        settingsObj["Geometry"]!.AsObject()["CropX"] = mutation.GetProperty("cropX").GetDouble();
                        settingsObj["Geometry"]!.AsObject()["CropWidth"] = mutation.GetProperty("cropWidth").GetDouble();
                        break;
                    case "invalid_exposure_mode":
                        settingsObj["ExposureMode"] = "future_unknown_mode";
                        break;
                    case "non_monotonic_curve":
                        settingsObj["Curve"] = new JsonObject
                        {
                            ["mode"] = "custom",
                            ["points"] = new JsonArray(
                                new JsonArray(0.0, 0.0),
                                new JsonArray(0.6, 0.5),
                                new JsonArray(0.4, 0.8),
                                new JsonArray(1.0, 1.0))
                        };
                        break;
                    default:
                        throw new HarnessSetupException("Unhandled boundary mutation: " + mKind);
                }

                File.WriteAllText(editsFile, registry.ToJsonString());

                Evaluate(id, EvalCatchScope.ExpectationOnly, () =>
                {
                    var reopened = new EditStore(dir);
                    var threw = false;
                    try { _ = reopened.ReadState(targetPath); }
                    catch (UnusableEditRecordException) { threw = true; }
                    Check(threw, $"{id}: invalid boundary value must throw UnusableEditRecordException");
                    Check(reopened.Find(sibPath) != null, $"{id}: sibling must remain readable");
                });
            }

            var unregistered = KnownEditRecordDivergences.Keys.Except(evaluatedIds, StringComparer.Ordinal).ToArray();
            CheckSetup(unregistered.Length == 0, "Unmatched registered edit-record divergences (orphan ledger entries): " + string.Join(", ", unregistered));
            CheckSetup(KnownEditRecordDivergences.Count <= MaxKnownEditRecordDivergences,
                $"EditRecord divergences ({KnownEditRecordDivergences.Count}) exceed ceiling ({MaxKnownEditRecordDivergences})");
            CheckSetup(failures.Count == 0, $"{failures.Count} Windows edit-record scenario(s) failed:\n" + string.Join(Environment.NewLine, failures));
            Console.WriteLine($"PASS: Windows edit-record fixture suite finished with {KnownEditRecordDivergences.Count} registered divergences (cap {MaxKnownEditRecordDivergences}, evaluated {evaluatedIds.Count})");
        }
        finally
        {
            try { Directory.Delete(tempRoot, recursive: true); } catch { }
        }
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

    private static string TouchPhoto(string tempRoot, string name)
    {
        var dir = Path.Combine(tempRoot, "photos");
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, name);
        if (!File.Exists(path)) File.WriteAllText(path, "fixture-" + name);
        return path;
    }

    private static ToneCurveShape ParseCurveShape(JsonElement shapeElem)
    {
        var mode = shapeElem.GetProperty("mode").GetString() == "custom" ? ToneCurveMode.Custom : ToneCurveMode.Legacy;
        var points = shapeElem.GetProperty("points").EnumerateArray()
            .Select(p => new ToneCurvePoint(p[0].GetDouble(), p[1].GetDouble()))
            .ToArray();
        return new ToneCurveShape(mode, points);
    }

    private static ToneCurveSettings ParseCurve(JsonElement curveElem)
    {
        var master = ParseCurveShape(curveElem);
        var channels = new ToneCurveChannels();
        if (curveElem.TryGetProperty("channels", out var chElem))
        {
            ToneCurveShape ReadChannel(string name) =>
                chElem.TryGetProperty(name, out var item) ? ParseCurveShape(item) : new ToneCurveShape();
            channels = new ToneCurveChannels(ReadChannel("red"), ReadChannel("green"), ReadChannel("blue"));
        }
        return new ToneCurveSettings(master.Mode, master.Points, channels);
    }

    private static ColorGradingWheel ParseWheel(JsonElement elem) =>
        new(elem.GetProperty("hue").GetDouble(), elem.GetProperty("saturation").GetDouble());

    private static HDRSettings BuildHDRSettings(JsonElement values, JsonElement metadata, bool activeMode)
    {
        var hdr = new HDRSettings { Mode = activeMode ? HDRMode.Hdr : HDRMode.Sdr };
        if (values.TryGetProperty("light.exposure", out var ev)) hdr = hdr with { Exposure = ev.GetDouble() };
        if (values.TryGetProperty("light.contrast", out var ct)) hdr = hdr with { Contrast = (ct.GetDouble() - 1.0) * 100.0 };
        if (values.TryGetProperty("light.highlights", out var hi)) hdr = hdr with { Highlights = -hi.GetDouble() * 100.0 };
        if (values.TryGetProperty("light.shadows", out var sh)) hdr = hdr with { Shadows = sh.GetDouble() * 100.0 };
        if (values.TryGetProperty("color.saturation", out var sat)) hdr = hdr with { Saturation = (sat.GetDouble() - 1.0) * 100.0 };
        if (values.TryGetProperty("hdr.relative_temperature", out var rt)) hdr = hdr with { Temperature = rt.GetDouble() };
        if (values.TryGetProperty("hdr.relative_tint", out var rtn)) hdr = hdr with { Tint = rtn.GetDouble() };

        var tone = new HDRToneSettings();
        if (values.TryGetProperty("tone.black_point", out var bp)) tone = tone with { BlackPoint = bp.GetDouble() };
        if (values.TryGetProperty("tone.white_point", out var wp)) tone = tone with { WhitePoint = wp.GetDouble() };
        if (values.TryGetProperty("light.s_curve", out var sc)) tone = tone with { CurveStrength = sc.GetDouble() * 100.0 };
        if (values.TryGetProperty("light.curve", out var cv)) tone = tone with { Curve = ParseCurve(cv) };
        hdr = hdr.WithTone(tone);

        var color = new HDRColorSettings();
        if (values.TryGetProperty("color.vibrance", out var vib)) color = color with { Vibrance = vib.GetDouble() };
        var hsl = new HslSettings();
        for (var idx = 0; idx < HslChannels.Length; idx++)
        {
            var ch = HslChannels[idx];
            if (values.TryGetProperty("color.hsl.hue." + ch, out var v0)) hsl = hsl.WithValue(0, idx, v0.GetDouble());
            if (values.TryGetProperty("color.hsl.saturation." + ch, out var v1)) hsl = hsl.WithValue(1, idx, v1.GetDouble());
            if (values.TryGetProperty("color.hsl.lightness." + ch, out var v2)) hsl = hsl.WithValue(2, idx, v2.GetDouble());
        }
        var grading = new ColorGradingSettings();
        if (values.TryGetProperty("color.grading.shadows", out var cgs)) grading = grading with { Shadows = ParseWheel(cgs) };
        if (values.TryGetProperty("color.grading.midtones", out var cgm)) grading = grading with { Midtones = ParseWheel(cgm) };
        if (values.TryGetProperty("color.grading.highlights", out var cgh)) grading = grading with { Highlights = ParseWheel(cgh) };
        color = color with { Hsl = hsl, Grading = grading };
        hdr = hdr.WithColor(color);

        var rendition = new HDRRenditionSettings();
        if (values.TryGetProperty("hdr.peak_limit_ev", out var pk)) rendition = rendition with { PeakLimitEV = pk.GetDouble() };
        if (values.TryGetProperty("hdr.sdr_exposure_ev", out var se)) rendition = rendition with { SdrExposureEV = se.GetDouble() };
        if (values.TryGetProperty("hdr.sdr_contrast", out var sct)) rendition = rendition with { SdrContrast = sct.GetDouble() };
        if (values.TryGetProperty("hdr.sdr_saturation", out var ssat)) rendition = rendition with { SdrSaturation = ssat.GetDouble() };
        hdr = hdr.WithRendition(rendition);

        var fx = new PhotoEffectsSettings();
        if (values.TryGetProperty("effects.vignette.amount", out var va)) fx = fx with { VignetteAmount = va.GetDouble() };
        if (values.TryGetProperty("effects.vignette.midpoint", out var vm)) fx = fx with { VignetteMidpoint = vm.GetDouble() };
        if (values.TryGetProperty("effects.vignette.roundness", out var vr)) fx = fx with { VignetteRoundness = vr.GetDouble() };
        if (values.TryGetProperty("effects.vignette.feather", out var vf)) fx = fx with { VignetteFeather = vf.GetDouble() };
        if (values.TryGetProperty("effects.vignette.highlights", out var vh)) fx = fx with { VignetteHighlights = vh.GetDouble() };
        if (values.TryGetProperty("effects.grain.amount", out var ga)) fx = fx with { GrainAmount = ga.GetDouble() };
        if (values.TryGetProperty("effects.grain.size", out var gs)) fx = fx with { GrainSize = gs.GetDouble() };
        if (values.TryGetProperty("effects.grain.roughness", out var gr)) fx = fx with { GrainRoughness = gr.GetDouble() };
        hdr = hdr.WithEffects(fx);

        var detail = new HDRDetailSettings();
        if (values.TryGetProperty("detail.sharpening", out var dsh)) detail = detail with { Sharpening = dsh.GetDouble() };
        if (values.TryGetProperty("effects.clarity", out var cl)) detail = detail with { Clarity = cl.GetDouble() / 100.0 };
        if (values.TryGetProperty("effects.dehaze", out var dh)) detail = detail with { Dehaze = dh.GetDouble() / 100.0 };
        if (values.TryGetProperty("detail.denoise.post_rgb", out var pr)) detail = detail with { Denoise = pr.GetDouble() };
        hdr = hdr.WithDetail(detail);

        if (values.TryGetProperty("hdr.look", out var lk) && lk.ValueKind == JsonValueKind.Object)
        {
            hdr = hdr.WithLook(new HDRLookSettings(
                lk.GetProperty("sha256").GetString(),
                lk.GetProperty("name").GetString(),
                lk.GetProperty("strength").GetDouble()));
        }

        if (values.TryGetProperty("hdr.camera_development", out var camObj) && camObj.ValueKind == JsonValueKind.Object)
        {
            var customWb = camObj.GetProperty("white_balance_mode").GetString() == "temperature";
            var camTemp = camObj.GetProperty("temperature").GetDouble();
            var camTint = camObj.GetProperty("tint").GetDouble();
            var sensorExp = camObj.GetProperty("exposure_reference").GetString() == "sensor";
            var fbdd = camObj.GetProperty("fbdd_level").GetInt32();
            var lensDist = false;
            var lensTca = false;
            var lensVig = false;
            var lensAutoCrop = true;
            string? lensProf = null;
            HDRCameraProfile? camProf = null;
            if (metadata.TryGetProperty("hdr_camera_development_extra", out var extra) && extra.ValueKind == JsonValueKind.Object)
            {
                if (extra.TryGetProperty("lens_distortion", out var b0)) lensDist = b0.GetBoolean();
                if (extra.TryGetProperty("lens_tca", out var b1)) lensTca = b1.GetBoolean();
                if (extra.TryGetProperty("lens_vignetting", out var b2)) lensVig = b2.GetBoolean();
                if (extra.TryGetProperty("lens_auto_crop", out var b3)) lensAutoCrop = b3.GetBoolean();
                if (extra.TryGetProperty("lens_profile", out var lp) && lp.ValueKind == JsonValueKind.String) lensProf = lp.GetString();
                if (extra.TryGetProperty("camera_profile", out var cp) && cp.ValueKind == JsonValueKind.Object)
                {
                    camProf = new HDRCameraProfile(cp.GetProperty("sha256").GetString()!, cp.GetProperty("name").GetString()!);
                }
            }
            hdr = hdr.WithCameraDevelopment(new HDRCameraDevelopmentSettings(
                customWb, camTemp, camTint, sensorExp, fbdd,
                lensDist, lensTca, lensAutoCrop, lensProf, camProf, lensVig));
        }

        var geom = new GeometrySettings();
        if (values.TryGetProperty("geometry.crop.x", out var gx)) geom = geom with { CropX = gx.GetDouble() };
        if (values.TryGetProperty("geometry.crop.y", out var gy)) geom = geom with { CropY = gy.GetDouble() };
        if (values.TryGetProperty("geometry.crop.width", out var gw)) geom = geom with { CropWidth = gw.GetDouble() };
        if (values.TryGetProperty("geometry.crop.height", out var gh)) geom = geom with { CropHeight = gh.GetDouble() };
        if (values.TryGetProperty("geometry.quarter_turns", out var qt)) geom = geom with { QuarterTurns = qt.GetInt32() };
        if (values.TryGetProperty("geometry.flip_horizontal", out var fh)) geom = geom with { FlipHorizontal = fh.GetBoolean() };
        if (values.TryGetProperty("geometry.flip_vertical", out var fv)) geom = geom with { FlipVertical = fv.GetBoolean() };
        if (values.TryGetProperty("geometry.straighten_degrees", out var stg)) geom = geom with { StraightenDegrees = stg.GetDouble() };
        if (values.TryGetProperty("geometry.perspective.horizontal", out var ph)) geom = geom with { PerspectiveHorizontal = ph.GetDouble() };
        if (values.TryGetProperty("geometry.perspective.vertical", out var pv)) geom = geom with { PerspectiveVertical = pv.GetDouble() };
        return hdr with { Geometry = geom };
    }

    private static ((AdjustmentSnapshot Settings, string? Look) Built, JsonElement Metadata) BuildSnapshot(JsonElement record)
    {
        var metadata = record.GetProperty("metadata");
        var hasSdr = record.TryGetProperty("sdr_values", out var sdrValues) && sdrValues.ValueKind == JsonValueKind.Object;
        var hasHdrValues = record.TryGetProperty("hdr_values", out var hdrValues) && hdrValues.ValueKind == JsonValueKind.Object;
        var hasDormant = record.TryGetProperty("dormant_hdr_values", out var dormantHdr) && dormantHdr.ValueKind == JsonValueKind.Object;
        var hasLocal = record.TryGetProperty("local_values", out var localValues) && localValues.ValueKind == JsonValueKind.Object;
        var hdrEditing = metadata.TryGetProperty("hdr_editing", out var he) && he.GetBoolean();

        var values = new double[ParameterSpec.All.Length];
        values[(int)Parameter.Strength] = 100.0;
        values[(int)Parameter.Temperature] = 6500.0;

        var procVer = metadata.TryGetProperty("processing", out var procObj) && procObj.ValueKind == JsonValueKind.Object &&
                      procObj.TryGetProperty("version", out var procVerEl) ? procVerEl.GetInt32() : 1;
        var processing = procVer == 1 ? ProcessingIdentity.Legacy : procVer == 2 ? ProcessingIdentity.C5 : ProcessingIdentity.Current;
        var x3fStr = metadata.TryGetProperty("x3f_mode", out var x3fEl) && x3fEl.ValueKind == JsonValueKind.String
            ? x3fEl.GetString() : "legacy";
        var x3fMode = x3fStr == "normal-v1" ? X3fMode.Normal : X3fMode.Legacy;
        int? proRawDecodeVersion = metadata.TryGetProperty("pro_raw_decode_version", out var prd) && prd.ValueKind == JsonValueKind.Number
            ? prd.GetInt32() : null;

        double? asShotTemp = null;
        double? asShotTint = null;
        if (metadata.TryGetProperty("as_shot_wb", out var wb) && wb.ValueKind == JsonValueKind.Object)
        {
            asShotTemp = wb.GetProperty("temperature").GetDouble();
            asShotTint = wb.GetProperty("tint").GetDouble();
        }

        string? masterRecipeId = metadata.TryGetProperty("master_recipe_id", out var mri) && mri.ValueKind == JsonValueKind.String
            ? mri.GetString() : null;
        string? look = masterRecipeId != null ? "recipe:" + masterRecipeId : null;
        if (hasSdr && sdrValues.TryGetProperty("looks.reference", out var lookRef) && lookRef.ValueKind == JsonValueKind.Object)
        {
            var lkKind = lookRef.TryGetProperty("kind", out var kEl) && kEl.ValueKind == JsonValueKind.String ? kEl.GetString() : null;
            var lkId = lookRef.TryGetProperty("id", out var iEl) && iEl.ValueKind == JsonValueKind.String ? iEl.GetString() : null;
            switch (lkKind)
            {
                case "recipe" when !string.IsNullOrEmpty(lkId):
                    masterRecipeId = lkId;
                    look = "recipe:" + lkId;
                    break;
                case "builtin" when !string.IsNullOrEmpty(lkId):
                    look = "builtin:" + lkId;
                    break;
                case "managed" when !string.IsNullOrEmpty(lkId):
                    look = lkId;
                    break;
                case "neutral":
                    look = null;
                    break;
            }
        }
        else if (look == null && metadata.TryGetProperty("film_id", out var filmEl) &&
                 filmEl.ValueKind == JsonValueKind.String && !string.IsNullOrEmpty(filmEl.GetString()))
        {
            look = filmEl.GetString();
        }

        var masterRecipeSettingsVersion = metadata.TryGetProperty("master_recipe_settings_version", out var mrv) && mrv.ValueKind == JsonValueKind.Number
            ? mrv.GetInt32() : 3;

        var exposureMode = 1;
        var cameraWhiteBalance = true;
        ToneCurveSettings? curve = null;
        var toneControls = new ToneControlsSettings();
        var grading = new ColorGradingSettings();
        var hsl = new HslSettings();
        var fx = new PhotoEffectsSettings();
        var atm = new AtmosphereSettings();
        var chromaMode = 0;
        var denoise = new DenoiseSettings();
        var geom = new GeometrySettings();
        var lens = new LensSettings();

        if (hasSdr)
        {
            if (sdrValues.TryGetProperty("looks.strength", out var ls)) values[(int)Parameter.Strength] = ls.GetDouble() * 100.0;
            if (sdrValues.TryGetProperty("light.exposure", out var le)) values[(int)Parameter.Exposure] = le.GetDouble();
            if (sdrValues.TryGetProperty("light.exposure_mode", out var em))
            {
                exposureMode = em.GetString() switch { "scene" => 0, "preview" => 1, "sensor" => 2, _ => 1 };
            }
            if (sdrValues.TryGetProperty("light.contrast", out var lc)) values[(int)Parameter.Contrast] = (lc.GetDouble() - 1.0) * 100.0;
            if (sdrValues.TryGetProperty("light.highlights", out var lhi)) values[(int)Parameter.Highlights] = -lhi.GetDouble() * 100.0;
            if (sdrValues.TryGetProperty("light.shadows", out var lsh)) values[(int)Parameter.Shadows] = lsh.GetDouble() * 100.0;
            if (sdrValues.TryGetProperty("light.s_curve", out var lsc)) values[(int)Parameter.ToneCurve] = lsc.GetDouble() * 100.0;
            if (sdrValues.TryGetProperty("color.saturation", out var csa)) values[(int)Parameter.Saturation] = (csa.GetDouble() - 1.0) * 100.0;
            if (sdrValues.TryGetProperty("detail.sharpening", out var dsh)) values[(int)Parameter.Sharpening] = dsh.GetDouble() * 100.0;

            if (sdrValues.TryGetProperty("color.white_balance.mode", out var wbm) && wbm.GetString() == "temperature")
            {
                cameraWhiteBalance = false;
                if (sdrValues.TryGetProperty("color.white_balance.temperature_kelvin", out var kt) && kt.ValueKind == JsonValueKind.Number)
                    values[(int)Parameter.Temperature] = kt.GetDouble();
                if (sdrValues.TryGetProperty("color.white_balance.tint", out var ktn) && ktn.ValueKind == JsonValueKind.Number)
                    values[(int)Parameter.Tint] = ktn.GetDouble();
            }
            else if (asShotTemp is { } t && asShotTint is { } tn)
            {
                values[(int)Parameter.Temperature] = t;
                values[(int)Parameter.Tint] = masterRecipeId == null ? tn : 0.0;
            }

            if (sdrValues.TryGetProperty("light.curve", out var cvObj) && cvObj.ValueKind == JsonValueKind.Object)
            {
                var parsed = ParseCurve(cvObj);
                curve = parsed.IsDefault ? null : parsed;
            }

            if (sdrValues.TryGetProperty("tone.black_point", out var bp)) toneControls = toneControls with { BlackPoint = bp.GetDouble() };
            if (sdrValues.TryGetProperty("tone.white_point", out var wp)) toneControls = toneControls with { WhitePoint = wp.GetDouble() };
            if (sdrValues.TryGetProperty("color.vibrance", out var vib)) toneControls = toneControls with { Vibrance = vib.GetDouble() };

            if (sdrValues.TryGetProperty("color.grading.shadows", out var cgs)) grading = grading with { Shadows = ParseWheel(cgs) };
            if (sdrValues.TryGetProperty("color.grading.midtones", out var cgm)) grading = grading with { Midtones = ParseWheel(cgm) };
            if (sdrValues.TryGetProperty("color.grading.highlights", out var cgh)) grading = grading with { Highlights = ParseWheel(cgh) };

            for (var idx = 0; idx < HslChannels.Length; idx++)
            {
                var ch = HslChannels[idx];
                if (sdrValues.TryGetProperty("color.hsl.hue." + ch, out var v0)) hsl = hsl.WithValue(0, idx, v0.GetDouble());
                if (sdrValues.TryGetProperty("color.hsl.saturation." + ch, out var v1)) hsl = hsl.WithValue(1, idx, v1.GetDouble());
                if (sdrValues.TryGetProperty("color.hsl.lightness." + ch, out var v2)) hsl = hsl.WithValue(2, idx, v2.GetDouble());
            }

            if (sdrValues.TryGetProperty("effects.vignette.amount", out var va)) fx = fx with { VignetteAmount = va.GetDouble() };
            if (sdrValues.TryGetProperty("effects.vignette.midpoint", out var vm)) fx = fx with { VignetteMidpoint = vm.GetDouble() };
            if (sdrValues.TryGetProperty("effects.vignette.roundness", out var vr)) fx = fx with { VignetteRoundness = vr.GetDouble() };
            if (sdrValues.TryGetProperty("effects.vignette.feather", out var vf)) fx = fx with { VignetteFeather = vf.GetDouble() };
            if (sdrValues.TryGetProperty("effects.vignette.highlights", out var vh)) fx = fx with { VignetteHighlights = vh.GetDouble() };
            if (sdrValues.TryGetProperty("effects.grain.amount", out var ga)) fx = fx with { GrainAmount = ga.GetDouble() };
            if (sdrValues.TryGetProperty("effects.grain.size", out var gs)) fx = fx with { GrainSize = gs.GetDouble() };
            if (sdrValues.TryGetProperty("effects.grain.roughness", out var gr)) fx = fx with { GrainRoughness = gr.GetDouble() };

            if (sdrValues.TryGetProperty("effects.clarity", out var cl)) atm = atm with { Clarity = cl.GetDouble() };
            if (sdrValues.TryGetProperty("effects.dehaze", out var dh)) atm = atm with { Dehaze = dh.GetDouble() };

            if (sdrValues.TryGetProperty("detail.denoise.chroma_mode", out var cm)) chromaMode = cm.GetInt32();
            if (sdrValues.TryGetProperty("detail.denoise.wavelet", out var wdObj) && wdObj.ValueKind == JsonValueKind.Object)
            {
                denoise = new DenoiseSettings(
                    wdObj.GetProperty("enabled").GetBoolean(),
                    wdObj.GetProperty("luma").GetDouble(),
                    wdObj.GetProperty("chroma").GetDouble(),
                    wdObj.GetProperty("coarse").GetDouble());
            }

            if (sdrValues.TryGetProperty("geometry.crop.x", out var gx)) geom = geom with { CropX = gx.GetDouble() };
            if (sdrValues.TryGetProperty("geometry.crop.y", out var gy)) geom = geom with { CropY = gy.GetDouble() };
            if (sdrValues.TryGetProperty("geometry.crop.width", out var gw)) geom = geom with { CropWidth = gw.GetDouble() };
            if (sdrValues.TryGetProperty("geometry.crop.height", out var gh)) geom = geom with { CropHeight = gh.GetDouble() };
            if (sdrValues.TryGetProperty("geometry.quarter_turns", out var qt)) geom = geom with { QuarterTurns = qt.GetInt32() };
            if (sdrValues.TryGetProperty("geometry.flip_horizontal", out var fh)) geom = geom with { FlipHorizontal = fh.GetBoolean() };
            if (sdrValues.TryGetProperty("geometry.flip_vertical", out var fv)) geom = geom with { FlipVertical = fv.GetBoolean() };
            if (sdrValues.TryGetProperty("geometry.straighten_degrees", out var stg)) geom = geom with { StraightenDegrees = stg.GetDouble() };
            if (sdrValues.TryGetProperty("geometry.perspective.horizontal", out var ph)) geom = geom with { PerspectiveHorizontal = ph.GetDouble() };
            if (sdrValues.TryGetProperty("geometry.perspective.vertical", out var pv)) geom = geom with { PerspectiveVertical = pv.GetDouble() };

            if (sdrValues.TryGetProperty("geometry.lens.distortion", out var ld)) lens = lens with { Distortion = ld.GetBoolean() };
            if (sdrValues.TryGetProperty("geometry.lens.tca", out var lt)) lens = lens with { Tca = lt.GetBoolean() };
            if (sdrValues.TryGetProperty("geometry.lens.vignetting", out var lv)) lens = lens with { Vignetting = lv.GetBoolean() };
            if (sdrValues.TryGetProperty("geometry.lens.auto_crop", out var lac)) lens = lens with { AutoCrop = lac.GetBoolean() };
            if (sdrValues.TryGetProperty("geometry.lens.profile_id", out var lpid) && lpid.ValueKind == JsonValueKind.String)
                lens = lens with { Manual = true, ProfileId = lpid.GetString() };
        }
        else if (asShotTemp is { } t && asShotTint is { } tn)
        {
            values[(int)Parameter.Temperature] = t;
            values[(int)Parameter.Tint] = masterRecipeId == null ? tn : 0.0;
        }

        if (metadata.TryGetProperty("lens_extra", out var lensExtra) && lensExtra.ValueKind == JsonValueKind.Object)
        {
            if (lensExtra.TryGetProperty("focal_length", out var fl) && fl.ValueKind == JsonValueKind.Number)
                lens = lens with { FocalLength = fl.GetDouble() };
            if (lensExtra.TryGetProperty("crop_factor", out var cf) && cf.ValueKind == JsonValueKind.Number)
                lens = lens with { CropFactor = cf.GetDouble() };
        }

        HDRSettings? hdr = null;
        if (hdrEditing && hasHdrValues) hdr = BuildHDRSettings(hdrValues, metadata, activeMode: true);
        else if (hasDormant) hdr = BuildHDRSettings(dormantHdr, metadata, activeMode: false);

        var aiDenoise = hasLocal && localValues.TryGetProperty("local.ai_denoise_enabled", out var ai) && ai.GetBoolean();
        var hdrCameraAi = hasLocal && localValues.TryGetProperty("local.hdr_camera_ai_enabled", out var hai) && hai.GetBoolean();

        var snapshot = new AdjustmentSnapshot(
            values, exposureMode, cameraWhiteBalance, asShotTemp, asShotTint,
            denoise, fx, chromaMode, hsl, masterRecipeId, lens, geom, hdr)
        {
            Processing = processing,
            X3fMode = x3fMode,
            AIDenoiseEnabled = aiDenoise,
            HDRCameraAIEnabled = hdrCameraAi,
            MasterRecipeSettingsVersion = masterRecipeSettingsVersion,
            ToneControls = toneControls.IsIdentity ? null : toneControls,
            Atmosphere = atm.IsIdentity ? null : atm,
            ColorGrading = grading.IsDefault ? null : grading,
            Curve = curve,
            ProRAWDecodeVersion = proRawDecodeVersion
        };
        _ = snapshot.Restore();
        return ((snapshot, look), metadata);
    }

    private static void VerifyCurve(JsonElement expected, ToneCurveSettings actual, string label, List<string> mismatches)
    {
        var expMode = expected.GetProperty("mode").GetString() ?? "legacy";
        if ((actual.Mode == ToneCurveMode.Custom ? "custom" : "legacy") != expMode)
            mismatches.Add($"{label}: curve mode mismatch");
        var expPts = expected.GetProperty("points").EnumerateArray().ToArray();
        if (actual.Points.Count != expPts.Length)
        {
            mismatches.Add($"{label}: curve point count mismatch (expected={expPts.Length}, actual={actual.Points.Count})");
        }
        else
        {
            for (var i = 0; i < expPts.Length; i++)
            {
                if (!Approx(actual.Points[i].X, expPts[i][0].GetDouble()) || !Approx(actual.Points[i].Y, expPts[i][1].GetDouble()))
                    mismatches.Add($"{label}: curve point {i} mismatch");
            }
        }
        if (expected.TryGetProperty("channels", out var chObj) && chObj.ValueKind == JsonValueKind.Object)
        {
            foreach (var (cname, shape) in new[] {
                ("red", actual.Channels.Red), ("green", actual.Channels.Green), ("blue", actual.Channels.Blue) })
            {
                if (!chObj.TryGetProperty(cname, out var expShape)) continue;
                var em = expShape.GetProperty("mode").GetString() ?? "legacy";
                if ((shape.Mode == ToneCurveMode.Custom ? "custom" : "legacy") != em)
                    mismatches.Add($"{label}: curve channel {cname} mode");
                var epts = expShape.GetProperty("points").EnumerateArray().ToArray();
                if (shape.Points.Count != epts.Length)
                {
                    mismatches.Add($"{label}: curve channel {cname} count (expected={epts.Length}, actual={shape.Points.Count})");
                }
                else
                {
                    for (var i = 0; i < epts.Length; i++)
                    {
                        if (!Approx(shape.Points[i].X, epts[i][0].GetDouble()) || !Approx(shape.Points[i].Y, epts[i][1].GetDouble()))
                            mismatches.Add($"{label}: curve channel {cname}[{i}]");
                    }
                }
            }
        }
    }

    private static void VerifyEdit(SavedEdit actual, JsonElement record)
    {
        var id = record.GetProperty("id").GetString()!;
        var metadata = record.GetProperty("metadata");
        var hasSdr = record.TryGetProperty("sdr_values", out var sdrValues) && sdrValues.ValueKind == JsonValueKind.Object;
        var hasHdr = record.TryGetProperty("hdr_values", out var hdrValues) && hdrValues.ValueKind == JsonValueKind.Object;
        var hasDormant = record.TryGetProperty("dormant_hdr_values", out var dormant) && dormant.ValueKind == JsonValueKind.Object;
        var hasLocal = record.TryGetProperty("local_values", out var localValues) && localValues.ValueKind == JsonValueKind.Object;
        var hdrEditing = metadata.TryGetProperty("hdr_editing", out var he) && he.GetBoolean();
        var s = actual.Settings;
        var mismatches = new List<string>();
        void Expect(bool cond, string message) { if (!cond) mismatches.Add(message); }

        string? expRecipe = metadata.TryGetProperty("master_recipe_id", out var mri) && mri.ValueKind == JsonValueKind.String
            ? mri.GetString() : null;
        if (hasSdr && sdrValues.TryGetProperty("looks.reference", out var lrCheck) && lrCheck.ValueKind == JsonValueKind.Object &&
            lrCheck.TryGetProperty("kind", out var lrKind) && lrKind.GetString() == "recipe" &&
            lrCheck.TryGetProperty("id", out var lrId) && lrId.ValueKind == JsonValueKind.String)
        {
            expRecipe = lrId.GetString();
        }
        Expect(s.MasterRecipeID == expRecipe, $"MasterRecipeID (expected={expRecipe ?? "<null>"}, actual={s.MasterRecipeID ?? "<null>"})");

        string? expectedLook = expRecipe != null ? "recipe:" + expRecipe : null;
        if (hasSdr && sdrValues.TryGetProperty("looks.reference", out var expLookRef) && expLookRef.ValueKind == JsonValueKind.Object)
        {
            var lkKind = expLookRef.TryGetProperty("kind", out var kEl) && kEl.ValueKind == JsonValueKind.String ? kEl.GetString() : null;
            var lkId = expLookRef.TryGetProperty("id", out var iEl) && iEl.ValueKind == JsonValueKind.String ? iEl.GetString() : null;
            expectedLook = lkKind switch
            {
                "recipe" => !string.IsNullOrEmpty(lkId) ? "recipe:" + lkId : null,
                "builtin" => !string.IsNullOrEmpty(lkId) ? "builtin:" + lkId : null,
                "managed" => !string.IsNullOrEmpty(lkId) ? lkId : null,
                "neutral" => null,
                _ => expectedLook
            };
        }
        else if (expectedLook == null && metadata.TryGetProperty("film_id", out var expFid) &&
                 expFid.ValueKind == JsonValueKind.String && !string.IsNullOrEmpty(expFid.GetString()))
        {
            expectedLook = expFid.GetString();
        }
        Expect(actual.Look == expectedLook, $"SavedEdit.Look (expected={expectedLook ?? "<null>"}, actual={actual.Look ?? "<null>"})");

        if (metadata.TryGetProperty("processing", out var proc) && proc.ValueKind == JsonValueKind.Object)
        {
            Expect(s.Processing.Family == proc.GetProperty("family").GetString(), "Processing.Family");
            Expect(s.Processing.Version == proc.GetProperty("version").GetInt32(), "Processing.Version");
            Expect(s.Processing.Quality == proc.GetProperty("quality").GetString(), "Processing.Quality");
        }
        if (metadata.TryGetProperty("x3f_mode", out var x3f) && x3f.ValueKind == JsonValueKind.String)
            Expect((s.X3fMode == X3fMode.Legacy ? "legacy" : "normal-v1") == x3f.GetString(), "X3fMode");
        if (metadata.TryGetProperty("master_recipe_settings_version", out var mrv) && mrv.ValueKind == JsonValueKind.Number)
            Expect(s.MasterRecipeSettingsVersion == mrv.GetInt32(), "MasterRecipeSettingsVersion");
        if (metadata.TryGetProperty("pro_raw_decode_version", out var prd))
        {
            int? expPrd = prd.ValueKind == JsonValueKind.Number ? prd.GetInt32() : null;
            Expect(s.ProRAWDecodeVersion == expPrd, "ProRAWDecodeVersion");
        }
        if (metadata.TryGetProperty("as_shot_wb", out var wb) && wb.ValueKind == JsonValueKind.Object)
        {
            Expect(Approx(s.AsShotTemperature ?? -1, wb.GetProperty("temperature").GetDouble()) &&
                   Approx(s.AsShotTint ?? -999, wb.GetProperty("tint").GetDouble()), "AsShot WB");
        }
        Expect((s.HDR?.Mode == HDRMode.Hdr) == hdrEditing, "IsHDREditing mismatch");

        if (hasSdr)
        {
            if (sdrValues.TryGetProperty("looks.strength", out var ls)) Expect(Approx(s.Values[(int)Parameter.Strength] / 100.0, ls.GetDouble()), "looks.strength");
            if (sdrValues.TryGetProperty("light.exposure", out var le)) Expect(Approx(s.Values[(int)Parameter.Exposure], le.GetDouble()), "exposure");
            if (sdrValues.TryGetProperty("light.exposure_mode", out var em))
            {
                var actualEm = s.ExposureMode == 0 ? "scene" : s.ExposureMode == 1 ? "preview" : "sensor";
                Expect(actualEm == em.GetString(), "exposure_mode");
            }
            if (sdrValues.TryGetProperty("light.contrast", out var lc)) Expect(Approx(1.0 + s.Values[(int)Parameter.Contrast] / 100.0, lc.GetDouble()), "contrast");
            if (sdrValues.TryGetProperty("light.highlights", out var lhi)) Expect(Approx(-s.Values[(int)Parameter.Highlights] / 100.0, lhi.GetDouble()), "highlights");
            if (sdrValues.TryGetProperty("light.shadows", out var lsh)) Expect(Approx(s.Values[(int)Parameter.Shadows] / 100.0, lsh.GetDouble()), "shadows");
            if (sdrValues.TryGetProperty("light.s_curve", out var lsc)) Expect(Approx(s.Values[(int)Parameter.ToneCurve] / 100.0, lsc.GetDouble()), "s_curve");
            if (sdrValues.TryGetProperty("light.curve", out var cv)) VerifyCurve(cv, s.Curve ?? new ToneCurveSettings(), id + ".sdr", mismatches);

            var toneControls = s.ToneControls ?? new ToneControlsSettings();
            if (sdrValues.TryGetProperty("tone.black_point", out var bp)) Expect(Approx(toneControls.BlackPoint, bp.GetDouble()), "black_point");
            if (sdrValues.TryGetProperty("tone.white_point", out var wp)) Expect(Approx(toneControls.WhitePoint, wp.GetDouble()), "white_point");
            if (sdrValues.TryGetProperty("color.vibrance", out var vib)) Expect(Approx(toneControls.Vibrance, vib.GetDouble()), "vibrance");

            var grading = s.ColorGrading ?? new ColorGradingSettings();
            if (sdrValues.TryGetProperty("color.grading.shadows", out var cgs))
                Expect(Approx(grading.Shadows.Hue, cgs.GetProperty("hue").GetDouble()) && Approx(grading.Shadows.Saturation, cgs.GetProperty("saturation").GetDouble()), "grading.shadows");
            if (sdrValues.TryGetProperty("color.grading.midtones", out var cgm))
                Expect(Approx(grading.Midtones.Hue, cgm.GetProperty("hue").GetDouble()) && Approx(grading.Midtones.Saturation, cgm.GetProperty("saturation").GetDouble()), "grading.midtones");
            if (sdrValues.TryGetProperty("color.grading.highlights", out var cgh))
                Expect(Approx(grading.Highlights.Hue, cgh.GetProperty("hue").GetDouble()) && Approx(grading.Highlights.Saturation, cgh.GetProperty("saturation").GetDouble()), "grading.highlights");

            if (sdrValues.TryGetProperty("color.white_balance.mode", out var wbm))
            {
                var modeStr = wbm.GetString();
                if (modeStr == "temperature")
                {
                    Expect(!s.CameraWhiteBalance, "wb mode custom");
                    if (sdrValues.TryGetProperty("color.white_balance.temperature_kelvin", out var kt) && kt.ValueKind == JsonValueKind.Number)
                        Expect(Approx(s.Values[(int)Parameter.Temperature], kt.GetDouble()), "wb temp");
                    if (sdrValues.TryGetProperty("color.white_balance.tint", out var ktn) && ktn.ValueKind == JsonValueKind.Number)
                        Expect(Approx(s.Values[(int)Parameter.Tint], ktn.GetDouble()), "wb tint");
                }
                else if (modeStr == "as_shot")
                {
                    Expect(s.CameraWhiteBalance, "wb mode as_shot");
                }
            }
            if (sdrValues.TryGetProperty("color.saturation", out var csa)) Expect(Approx(1.0 + s.Values[(int)Parameter.Saturation] / 100.0, csa.GetDouble()), "saturation");

            var hsl = s.Hsl ?? new HslSettings();
            for (var idx = 0; idx < HslChannels.Length; idx++)
            {
                var ch = HslChannels[idx];
                if (sdrValues.TryGetProperty("color.hsl.hue." + ch, out var v0)) Expect(Approx(hsl.Value(0, idx), v0.GetDouble()), $"hsl.hue.{ch}");
                if (sdrValues.TryGetProperty("color.hsl.saturation." + ch, out var v1)) Expect(Approx(hsl.Value(1, idx), v1.GetDouble()), $"hsl.sat.{ch}");
                if (sdrValues.TryGetProperty("color.hsl.lightness." + ch, out var v2)) Expect(Approx(hsl.Value(2, idx), v2.GetDouble()), $"hsl.lit.{ch}");
            }

            var fx = s.Effects ?? new PhotoEffectsSettings();
            if (sdrValues.TryGetProperty("effects.vignette.amount", out var va)) Expect(Approx(fx.VignetteAmount, va.GetDouble()), "vignette.amount");
            if (sdrValues.TryGetProperty("effects.vignette.midpoint", out var vm)) Expect(Approx(fx.VignetteMidpoint, vm.GetDouble()), "vignette.midpoint");
            if (sdrValues.TryGetProperty("effects.vignette.roundness", out var vr)) Expect(Approx(fx.VignetteRoundness, vr.GetDouble()), "vignette.roundness");
            if (sdrValues.TryGetProperty("effects.vignette.feather", out var vf)) Expect(Approx(fx.VignetteFeather, vf.GetDouble()), "vignette.feather");
            if (sdrValues.TryGetProperty("effects.vignette.highlights", out var vh)) Expect(Approx(fx.VignetteHighlights, vh.GetDouble()), "vignette.highlights");
            if (sdrValues.TryGetProperty("effects.grain.amount", out var ga)) Expect(Approx(fx.GrainAmount, ga.GetDouble()), "grain.amount");
            if (sdrValues.TryGetProperty("effects.grain.size", out var gs)) Expect(Approx(fx.GrainSize, gs.GetDouble()), "grain.size");
            if (sdrValues.TryGetProperty("effects.grain.roughness", out var gr)) Expect(Approx(fx.GrainRoughness, gr.GetDouble()), "grain.roughness");

            var atm = s.Atmosphere ?? new AtmosphereSettings();
            if (sdrValues.TryGetProperty("effects.clarity", out var cl)) Expect(Approx(atm.Clarity, cl.GetDouble()), "clarity");
            if (sdrValues.TryGetProperty("effects.dehaze", out var dh)) Expect(Approx(atm.Dehaze, dh.GetDouble()), "dehaze");
            if (sdrValues.TryGetProperty("detail.sharpening", out var dsh)) Expect(Approx(s.Values[(int)Parameter.Sharpening] / 100.0, dsh.GetDouble()), "sharpening");
            if (sdrValues.TryGetProperty("detail.denoise.chroma_mode", out var cm)) Expect(s.DisplayChromaDenoise == cm.GetInt32(), "chroma_mode");
            if (sdrValues.TryGetProperty("detail.denoise.wavelet", out var wdObj) && wdObj.ValueKind == JsonValueKind.Object)
            {
                if (s.Denoise is not { } dn)
                {
                    mismatches.Add("expected Denoise non-null");
                }
                else
                {
                    Expect(dn.Enabled == wdObj.GetProperty("enabled").GetBoolean(), "wavelet.enabled");
                    Expect(Approx(dn.Luma, wdObj.GetProperty("luma").GetDouble()), "wavelet.luma");
                    Expect(Approx(dn.Chroma, wdObj.GetProperty("chroma").GetDouble()), "wavelet.chroma");
                    Expect(Approx(dn.Coarse, wdObj.GetProperty("coarse").GetDouble()), "wavelet.coarse");
                    if (wdObj.TryGetProperty("preset", out var presetEl) && presetEl.ValueKind == JsonValueKind.String)
                    {
                        var actualPreset = dn.Preset switch { 0 => "detail", 1 => "clean", _ => "custom" };
                        Expect(actualPreset == presetEl.GetString(), $"wavelet.preset (expected={presetEl.GetString()}, actual={actualPreset})");
                    }
                }
            }

            var geom = s.Geometry ?? new GeometrySettings();
            if (sdrValues.TryGetProperty("geometry.crop.x", out var gx)) Expect(Approx(geom.CropX, gx.GetDouble()), "cropX");
            if (sdrValues.TryGetProperty("geometry.crop.y", out var gy)) Expect(Approx(geom.CropY, gy.GetDouble()), "cropY");
            if (sdrValues.TryGetProperty("geometry.crop.width", out var gw)) Expect(Approx(geom.CropWidth, gw.GetDouble()), "cropW");
            if (sdrValues.TryGetProperty("geometry.crop.height", out var gh)) Expect(Approx(geom.CropHeight, gh.GetDouble()), "cropH");
            if (sdrValues.TryGetProperty("geometry.quarter_turns", out var qt)) Expect(geom.QuarterTurns == qt.GetInt32(), "quarterTurns");
            if (sdrValues.TryGetProperty("geometry.flip_horizontal", out var fh)) Expect(geom.FlipHorizontal == fh.GetBoolean(), "flipH");
            if (sdrValues.TryGetProperty("geometry.flip_vertical", out var fv)) Expect(geom.FlipVertical == fv.GetBoolean(), "flipV");
            if (sdrValues.TryGetProperty("geometry.straighten_degrees", out var stg)) Expect(Approx(geom.StraightenDegrees, stg.GetDouble()), "straighten");
            if (sdrValues.TryGetProperty("geometry.perspective.horizontal", out var ph)) Expect(Approx(geom.PerspectiveHorizontal, ph.GetDouble()), "perspH");
            if (sdrValues.TryGetProperty("geometry.perspective.vertical", out var pv)) Expect(Approx(geom.PerspectiveVertical, pv.GetDouble()), "perspV");

            var lens = s.Lens ?? new LensSettings();
            if (sdrValues.TryGetProperty("geometry.lens.distortion", out var ld)) Expect(lens.Distortion == ld.GetBoolean(), "lens.distortion");
            if (sdrValues.TryGetProperty("geometry.lens.tca", out var lt)) Expect(lens.Tca == lt.GetBoolean(), "lens.tca");
            if (sdrValues.TryGetProperty("geometry.lens.vignetting", out var lv)) Expect(lens.Vignetting == lv.GetBoolean(), "lens.vignetting");
            if (sdrValues.TryGetProperty("geometry.lens.auto_crop", out var lac)) Expect(lens.AutoCrop == lac.GetBoolean(), "lens.autoCrop");
            if (sdrValues.TryGetProperty("geometry.lens.profile_id", out var lpid))
            {
                string? expPid = lpid.ValueKind == JsonValueKind.String ? lpid.GetString() : null;
                Expect(lens.ProfileId == expPid, "lens.profileID");
            }
        }

        if (metadata.TryGetProperty("lens_extra", out var lensExtra) && lensExtra.ValueKind == JsonValueKind.Object)
        {
            var lens = s.Lens ?? new LensSettings();
            if (lensExtra.TryGetProperty("focal_length", out var fl) && fl.ValueKind == JsonValueKind.Number)
                Expect(Approx(lens.FocalLength ?? -1, fl.GetDouble()), "lens.focalLength");
            if (lensExtra.TryGetProperty("crop_factor", out var cf) && cf.ValueKind == JsonValueKind.Number)
                Expect(Approx(lens.CropFactor ?? -1, cf.GetDouble()), "lens.cropFactor");
        }

        if (hdrEditing ? hasHdr : hasDormant)
        {
            var hdrCheck = hdrEditing ? hdrValues : dormant;
            if (s.HDR is not { } hdr)
            {
                mismatches.Add("expected HDR subtree to be preserved");
            }
            else
            {
                Expect((hdr.Mode == HDRMode.Hdr) == hdrEditing, "HDR.Mode mismatch");
                if (hdrCheck.TryGetProperty("light.exposure", out var hev)) Expect(Approx(hdr.Exposure, hev.GetDouble()), "hdr.exposure");
                if (hdrCheck.TryGetProperty("light.contrast", out var hct)) Expect(Approx(1.0 + hdr.Contrast / 100.0, hct.GetDouble()), "hdr.contrast");
                if (hdrCheck.TryGetProperty("light.highlights", out var hhi)) Expect(Approx(-hdr.Highlights / 100.0, hhi.GetDouble()), "hdr.highlights");
                if (hdrCheck.TryGetProperty("light.shadows", out var hsh)) Expect(Approx(hdr.Shadows / 100.0, hsh.GetDouble()), "hdr.shadows");
                if (hdrCheck.TryGetProperty("color.saturation", out var hsat)) Expect(Approx(1.0 + hdr.Saturation / 100.0, hsat.GetDouble()), "hdr.saturation");
                if (hdrCheck.TryGetProperty("hdr.relative_temperature", out var hrt)) Expect(Approx(hdr.Temperature, hrt.GetDouble()), "hdr.temp");
                if (hdrCheck.TryGetProperty("hdr.relative_tint", out var hrtn)) Expect(Approx(hdr.Tint, hrtn.GetDouble()), "hdr.tint");

                // HDR Tone block
                if (hdrCheck.TryGetProperty("light.s_curve", out var hsc)) Expect(Approx(hdr.ToneSettings.CurveStrength / 100.0, hsc.GetDouble()), "hdr.s_curve");
                if (hdrCheck.TryGetProperty("tone.black_point", out var hbp)) Expect(Approx(hdr.ToneSettings.BlackPoint, hbp.GetDouble()), "hdr.black_point");
                if (hdrCheck.TryGetProperty("tone.white_point", out var hwp)) Expect(Approx(hdr.ToneSettings.WhitePoint, hwp.GetDouble()), "hdr.white_point");
                if (hdrCheck.TryGetProperty("light.curve", out var hcv)) VerifyCurve(hcv, hdr.ToneSettings.Curve, id + ".hdr", mismatches);

                // HDR Color block
                if (hdrCheck.TryGetProperty("color.vibrance", out var hvib)) Expect(Approx(hdr.ColorSettings.Vibrance, hvib.GetDouble()), "hdr.vibrance");
                for (var idx = 0; idx < HslChannels.Length; idx++)
                {
                    var ch = HslChannels[idx];
                    if (hdrCheck.TryGetProperty("color.hsl.hue." + ch, out var hv0)) Expect(Approx(hdr.ColorSettings.Hsl.Value(0, idx), hv0.GetDouble()), $"hdr.hsl.hue.{ch}");
                    if (hdrCheck.TryGetProperty("color.hsl.saturation." + ch, out var hv1)) Expect(Approx(hdr.ColorSettings.Hsl.Value(1, idx), hv1.GetDouble()), $"hdr.hsl.sat.{ch}");
                    if (hdrCheck.TryGetProperty("color.hsl.lightness." + ch, out var hv2)) Expect(Approx(hdr.ColorSettings.Hsl.Value(2, idx), hv2.GetDouble()), $"hdr.hsl.lit.{ch}");
                }
                if (hdrCheck.TryGetProperty("color.grading.shadows", out var hcgs))
                    Expect(Approx(hdr.ColorSettings.Grading.Shadows.Hue, hcgs.GetProperty("hue").GetDouble()) &&
                           Approx(hdr.ColorSettings.Grading.Shadows.Saturation, hcgs.GetProperty("saturation").GetDouble()), "hdr.grading.shadows");
                if (hdrCheck.TryGetProperty("color.grading.midtones", out var hcgm))
                    Expect(Approx(hdr.ColorSettings.Grading.Midtones.Hue, hcgm.GetProperty("hue").GetDouble()) &&
                           Approx(hdr.ColorSettings.Grading.Midtones.Saturation, hcgm.GetProperty("saturation").GetDouble()), "hdr.grading.midtones");
                if (hdrCheck.TryGetProperty("color.grading.highlights", out var hcgh))
                    Expect(Approx(hdr.ColorSettings.Grading.Highlights.Hue, hcgh.GetProperty("hue").GetDouble()) &&
                           Approx(hdr.ColorSettings.Grading.Highlights.Saturation, hcgh.GetProperty("saturation").GetDouble()), "hdr.grading.highlights");

                // HDR Rendition block
                if (hdrCheck.TryGetProperty("hdr.peak_limit_ev", out var hpk)) Expect(Approx(hdr.RenditionSettings.PeakLimitEV, hpk.GetDouble()), "hdr.peakLimit");
                if (hdrCheck.TryGetProperty("hdr.sdr_exposure_ev", out var hse)) Expect(Approx(hdr.RenditionSettings.SdrExposureEV, hse.GetDouble()), "hdr.sdrExp");
                if (hdrCheck.TryGetProperty("hdr.sdr_contrast", out var hsct)) Expect(Approx(hdr.RenditionSettings.SdrContrast, hsct.GetDouble()), "hdr.sdrContrast");
                if (hdrCheck.TryGetProperty("hdr.sdr_saturation", out var hssat)) Expect(Approx(hdr.RenditionSettings.SdrSaturation, hssat.GetDouble()), "hdr.sdrSat");

                // HDR Effects block
                if (hdrCheck.TryGetProperty("effects.vignette.amount", out var hva)) Expect(Approx(hdr.EffectSettings.VignetteAmount, hva.GetDouble()), "hdr.vignette.amount");
                if (hdrCheck.TryGetProperty("effects.vignette.midpoint", out var hvm)) Expect(Approx(hdr.EffectSettings.VignetteMidpoint, hvm.GetDouble()), "hdr.vignette.midpoint");
                if (hdrCheck.TryGetProperty("effects.vignette.roundness", out var hvr)) Expect(Approx(hdr.EffectSettings.VignetteRoundness, hvr.GetDouble()), "hdr.vignette.roundness");
                if (hdrCheck.TryGetProperty("effects.vignette.feather", out var hvf)) Expect(Approx(hdr.EffectSettings.VignetteFeather, hvf.GetDouble()), "hdr.vignette.feather");
                if (hdrCheck.TryGetProperty("effects.vignette.highlights", out var hvh)) Expect(Approx(hdr.EffectSettings.VignetteHighlights, hvh.GetDouble()), "hdr.vignette.highlights");
                if (hdrCheck.TryGetProperty("effects.grain.amount", out var hga)) Expect(Approx(hdr.EffectSettings.GrainAmount, hga.GetDouble()), "hdr.grain.amount");
                if (hdrCheck.TryGetProperty("effects.grain.size", out var hgs)) Expect(Approx(hdr.EffectSettings.GrainSize, hgs.GetDouble()), "hdr.grain.size");
                if (hdrCheck.TryGetProperty("effects.grain.roughness", out var hgr)) Expect(Approx(hdr.EffectSettings.GrainRoughness, hgr.GetDouble()), "hdr.grain.roughness");

                // HDR Detail block
                if (hdrCheck.TryGetProperty("effects.clarity", out var hcl)) Expect(Approx(hdr.DetailSettings.Clarity * 100.0, hcl.GetDouble()), "hdr.clarity");
                if (hdrCheck.TryGetProperty("effects.dehaze", out var hdh)) Expect(Approx(hdr.DetailSettings.Dehaze * 100.0, hdh.GetDouble()), "hdr.dehaze");
                if (hdrCheck.TryGetProperty("detail.sharpening", out var hdsh)) Expect(Approx(hdr.DetailSettings.Sharpening, hdsh.GetDouble()), "hdr.sharpening");
                if (hdrCheck.TryGetProperty("detail.denoise.post_rgb", out var hpr)) Expect(Approx(hdr.DetailSettings.Denoise, hpr.GetDouble()), "hdr.denoise");

                // HDR Look block
                if (hdrCheck.TryGetProperty("hdr.look", out var hlk) && hlk.ValueKind == JsonValueKind.Object)
                {
                    Expect(hdr.LookSettings.Sha256 == hlk.GetProperty("sha256").GetString() &&
                           hdr.LookSettings.Name == hlk.GetProperty("name").GetString() &&
                           Approx(hdr.LookSettings.Strength, hlk.GetProperty("strength").GetDouble()), "hdr.look");
                }

                // HDR CameraDevelopment block
                if (hdrCheck.TryGetProperty("hdr.camera_development", out var hcam) && hcam.ValueKind == JsonValueKind.Object)
                {
                    Expect((hdr.CameraSettings.CustomWhiteBalance ? "temperature" : "as_shot") == hcam.GetProperty("white_balance_mode").GetString(), "hdr.cam.wb");
                    Expect(Approx(hdr.CameraSettings.Temperature, hcam.GetProperty("temperature").GetDouble()), "hdr.cam.temp");
                    Expect(Approx(hdr.CameraSettings.Tint, hcam.GetProperty("tint").GetDouble()), "hdr.cam.tint");
                    Expect((hdr.CameraSettings.SensorExposure ? "sensor" : "metadata") == hcam.GetProperty("exposure_reference").GetString(), "hdr.cam.expRef");
                    Expect(hdr.CameraSettings.FbddLevel == hcam.GetProperty("fbdd_level").GetInt32(), "hdr.cam.fbdd");
                    if (metadata.TryGetProperty("hdr_camera_development_extra", out var hextra) && hextra.ValueKind == JsonValueKind.Object)
                    {
                        if (hextra.TryGetProperty("lens_distortion", out var hld)) Expect(hdr.CameraSettings.LensDistortion == hld.GetBoolean(), "hdr.cam.lensDistortion");
                        if (hextra.TryGetProperty("lens_tca", out var hlt)) Expect(hdr.CameraSettings.LensTca == hlt.GetBoolean(), "hdr.cam.lensTca");
                        if (hextra.TryGetProperty("lens_vignetting", out var hlv)) Expect(hdr.CameraSettings.LensVignetting == hlv.GetBoolean(), "hdr.cam.lensVignetting");
                        if (hextra.TryGetProperty("lens_auto_crop", out var hlac)) Expect(hdr.CameraSettings.LensAutoCrop == hlac.GetBoolean(), "hdr.cam.lensAutoCrop");
                        if (hextra.TryGetProperty("lens_profile", out var hlp) && hlp.ValueKind == JsonValueKind.String)
                            Expect(hdr.CameraSettings.LensProfile == hlp.GetString(), "hdr.cam.lensProfile");
                        if (hextra.TryGetProperty("camera_profile", out var hcp) && hcp.ValueKind == JsonValueKind.Object)
                        {
                            Expect(hdr.CameraSettings.CameraProfile?.Sha256 == hcp.GetProperty("sha256").GetString(), "hdr.cam.camProfile.sha256");
                            Expect(hdr.CameraSettings.CameraProfile?.Name == hcp.GetProperty("name").GetString(), "hdr.cam.camProfile.name");
                        }
                    }
                }

                // HDR Geometry block
                if (hdrCheck.TryGetProperty("geometry.crop.x", out var hgx)) Expect(Approx(hdr.Geometry.CropX, hgx.GetDouble()), "hdr.cropX");
                if (hdrCheck.TryGetProperty("geometry.crop.y", out var hgy)) Expect(Approx(hdr.Geometry.CropY, hgy.GetDouble()), "hdr.cropY");
                if (hdrCheck.TryGetProperty("geometry.crop.width", out var hgw)) Expect(Approx(hdr.Geometry.CropWidth, hgw.GetDouble()), "hdr.cropW");
                if (hdrCheck.TryGetProperty("geometry.crop.height", out var hgh)) Expect(Approx(hdr.Geometry.CropHeight, hgh.GetDouble()), "hdr.cropH");
                if (hdrCheck.TryGetProperty("geometry.quarter_turns", out var hqt)) Expect(hdr.Geometry.QuarterTurns == hqt.GetInt32(), "hdr.quarterTurns");
                if (hdrCheck.TryGetProperty("geometry.flip_horizontal", out var hfh)) Expect(hdr.Geometry.FlipHorizontal == hfh.GetBoolean(), "hdr.flipH");
                if (hdrCheck.TryGetProperty("geometry.flip_vertical", out var hfv)) Expect(hdr.Geometry.FlipVertical == hfv.GetBoolean(), "hdr.flipV");
                if (hdrCheck.TryGetProperty("geometry.straighten_degrees", out var hstg)) Expect(Approx(hdr.Geometry.StraightenDegrees, hstg.GetDouble()), "hdr.straighten");
                if (hdrCheck.TryGetProperty("geometry.perspective.horizontal", out var hph)) Expect(Approx(hdr.Geometry.PerspectiveHorizontal, hph.GetDouble()), "hdr.perspH");
                if (hdrCheck.TryGetProperty("geometry.perspective.vertical", out var hpv)) Expect(Approx(hdr.Geometry.PerspectiveVertical, hpv.GetDouble()), "hdr.perspV");
            }
        }

        if (hasLocal && localValues.TryGetProperty("local.ai_denoise_enabled", out var ai))
            Expect(s.AIDenoiseEnabled == ai.GetBoolean(), "AIDenoiseEnabled");
        if (hasLocal && localValues.TryGetProperty("local.hdr_camera_ai_enabled", out var hai))
            Expect(s.HDRCameraAIEnabled == hai.GetBoolean(), "HDRCameraAIEnabled");

        if (mismatches.Count > 0)
            throw new ExpectationMismatchException($"{id}: {mismatches.Count} field mismatch(es): {string.Join("; ", mismatches)}");
    }

    private static void MutateJsonScope(JsonObject registry, string targetKey, string scope, string key, JsonElement value)
    {
        var injected = JsonNode.Parse(value.GetRawText());
        var records = registry["Records"]!.AsObject();
        if (scope == "store_root") { registry[key] = injected; return; }
        if (scope == "store_sibling_entry")
        {
            records[@"C:\tmp\__future_sibling_photo__.ARW"] = new JsonObject { [key] = injected };
            return;
        }
        var entry = records[targetKey]!.AsObject();
        if (scope == "record_root") { entry[key] = injected; return; }
        var settings = entry["Settings"]!.AsObject();
        JsonObject targetObj = scope switch
        {
            "settings_root" => settings,
            "processing" => settings["Processing"]!.AsObject(),
            "tone_controls" => settings["ToneControls"]!.AsObject(),
            "atmosphere" => settings["Atmosphere"]!.AsObject(),
            "color_grading" => settings["ColorGrading"]!.AsObject(),
            "color_grading_zone" => settings["ColorGrading"]!.AsObject()["Shadows"]!.AsObject(),
            "tone_curve" => settings["Curve"]!.AsObject(),
            "tone_curve_channels" => settings["Curve"]!.AsObject()["channels"]!.AsObject(),
            "geometry" => settings["Geometry"]!.AsObject(),
            "lens" => settings["Lens"]!.AsObject(),
            "denoise" => settings["Denoise"]!.AsObject(),
            "effects" => settings["Effects"]!.AsObject(),
            "hdr" => settings["HDR"]!.AsObject(),
            "hdr_tone" => settings["HDR"]!.AsObject()["tone"]!.AsObject(),
            "hdr_color" => settings["HDR"]!.AsObject()["color"]!.AsObject(),
            "hdr_rendition" => settings["HDR"]!.AsObject()["rendition"]!.AsObject(),
            "hdr_effects" => settings["HDR"]!.AsObject()["effects"]!.AsObject(),
            "hdr_detail" => settings["HDR"]!.AsObject()["detail"]!.AsObject(),
            "hdr_look" => settings["HDR"]!.AsObject()["look"]!.AsObject(),
            "hdr_camera_development" => settings["HDR"]!.AsObject()["camera_development"]!.AsObject(),
            "hdr_camera_profile" => settings["HDR"]!.AsObject()["camera_development"]!.AsObject()["camera_profile"]!.AsObject(),
            _ => throw new Exception("Unhandled scope: " + scope)
        };
        targetObj[key] = injected;
    }
}
