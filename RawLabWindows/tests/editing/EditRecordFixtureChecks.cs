using RawLab.Windows;
using System.Text.Json;
using System.Text.Json.Nodes;

// P2-01 (S1): Windows 消费共享持久化编辑记录 fixture `Shared/fixtures/edit-records-v1.json`。
// 登记当前真行为差异前以代码实况逐条核验；不静默修改实现或压低 fixture 期望以迎合现实现状。
internal static class EditRecordFixtureChecks
{
    private sealed record EditRecordDivergence(string LedgerId, string Reason);

    // 棘轮上限只减不增；新增任何分歧、空理由、陈旧条目或突破上限均必红。
    // 16 条 X1 闭集拒读 + 1 条 IEEE -0.0 读侧保留负号分歧 = 17。
    private const int MaxKnownEditRecordDivergences = 17;

    private static readonly IReadOnlyDictionary<string, EditRecordDivergence> KnownEditRecordDivergences =
        new Dictionary<string, EditRecordDivergence>(StringComparer.Ordinal)
        {
            ["x1-processing-unknown-field"] = new("P2-01-WIN-X1-01",
                "ProcessingIdentity applies [JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)] instead of tolerating unknown future keys"),
            ["x1-tone-controls-unknown-field"] = new("P2-01-WIN-X1-02",
                "ToneControlsSettings applies [JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)] instead of tolerating unknown future keys"),
            ["x1-atmosphere-unknown-field"] = new("P2-01-WIN-X1-03",
                "AtmosphereSettings applies [JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)] instead of tolerating unknown future keys"),
            ["x1-color-grading-unknown-field"] = new("P2-01-WIN-X1-04",
                "ColorGradingSettings applies [JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)] instead of tolerating unknown future keys"),
            ["x1-color-grading-zone-unknown-field"] = new("P2-01-WIN-X1-05",
                "ColorGradingWheel applies [JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)] instead of tolerating unknown future keys"),
            ["x1-tone-curve-unknown-field"] = new("P2-01-WIN-X1-06",
                "ToneCurveShape.Parse enforces closed key set {mode, points[, channels]} instead of tolerating unknown future keys"),
            ["x1-tone-curve-channels-unknown-field"] = new("P2-01-WIN-X1-07",
                "ToneCurveSettings.Parse rejects unknown channel names outside {red, green, blue}"),
            ["x1-hdr-root-unknown-field"] = new("P2-01-WIN-X1-08",
                "HDRSettingsJsonConverter.Read enforces closed top-level HDR key set instead of tolerating unknown future keys"),
            ["x1-hdr-tone-unknown-field"] = new("P2-01-WIN-X1-09",
                "HDRSettingsJsonConverter.ReadTone enforces closed key set {black_point, curve, curve_strength, white_point}"),
            ["x1-hdr-color-unknown-field"] = new("P2-01-WIN-X1-10",
                "HDRSettingsJsonConverter.ReadColor enforces closed key set {grading, hsl, vibrance}"),
            ["x1-hdr-rendition-unknown-field"] = new("P2-01-WIN-X1-11",
                "HDRSettingsJsonConverter.ReadRendition enforces closed key set {peak_limit_ev, sdr_contrast, sdr_exposure_ev, sdr_saturation}"),
            ["x1-hdr-effects-unknown-field"] = new("P2-01-WIN-X1-12",
                "HDRSettingsJsonConverter.ReadEffects enforces closed EffectsKeys sequence equality"),
            ["x1-hdr-detail-unknown-field"] = new("P2-01-WIN-X1-13",
                "HDRSettingsJsonConverter.ReadDetail enforces closed key set {clarity, dehaze, denoise, sharpening}"),
            ["x1-hdr-look-unknown-field"] = new("P2-01-WIN-X1-14",
                "HDRSettingsJsonConverter.ReadLook enforces closed key set {name, sha256, strength}"),
            ["x1-hdr-camera-development-unknown-field"] = new("P2-01-WIN-X1-15",
                "HDRSettingsJsonConverter.ReadCameraDevelopment enforces closed camera_development key set"),
            ["x1-hdr-camera-profile-unknown-field"] = new("P2-01-WIN-X1-16",
                "HDRSettingsJsonConverter.ReadCameraDevelopment enforces closed camera_profile key set {name, sha256}"),
            ["compat-negative-zero-canonicalized"] = new("P2-01-WIN-COMPAT-01",
                "System.Text.Json preserves IEEE -0.0 (double.IsNegative == true) rather than canonicalizing to +0.0 on read"),
        };

    private static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
    private static bool Approx(double a, double b, double tol = 1e-4) => Math.Abs(a - b) <= tol;

    private static readonly string[] HslChannels = ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"];

    internal static void Run()
    {
        foreach (var (id, div) in KnownEditRecordDivergences)
        {
            Check(!string.IsNullOrWhiteSpace(div.LedgerId), $"EditRecord divergence {id}: non-blank LedgerId required");
            Check(!string.IsNullOrWhiteSpace(div.Reason), $"EditRecord divergence {id}: non-blank Reason required");
        }
        Check(KnownEditRecordDivergences.Count <= MaxKnownEditRecordDivergences,
            $"EditRecord divergences ({KnownEditRecordDivergences.Count}) must not exceed monotonic ratchet cap ({MaxKnownEditRecordDivergences})");

        using var doc = JsonDocument.Parse(File.ReadAllText(ResolveFixturePath("Shared/fixtures/edit-records-v1.json")));
        var root = doc.RootElement;
        Check(root.GetProperty("fixture_version").GetInt32() == 1, "fixture_version must be 1");
        Check(root.GetProperty("spec_version").GetInt32() == 1, "spec_version must be 1");

        var roundtripList = root.GetProperty("roundtrip_records").EnumerateArray().ToArray();
        var byId = roundtripList.ToDictionary(r => r.GetProperty("id").GetString()!, r => r.Clone(), StringComparer.Ordinal);
        Check(roundtripList.Length == byId.Count, "Duplicate roundtrip_records ID");

        var tempRoot = Path.Combine(Path.GetTempPath(), "rawlab-win-edit-fixture-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempRoot);
        try
        {
            var failures = new List<string>();
            var evaluatedIds = new HashSet<string>(StringComparer.Ordinal);

            void Collect(string scenarioId, Action body)
            {
                Check(evaluatedIds.Add(scenarioId), "Duplicate evaluated scenario ID: " + scenarioId);
                try
                {
                    body();
                    if (KnownEditRecordDivergences.TryGetValue(scenarioId, out var stale))
                        throw new Exception($"Stale divergence ledger entry '{scenarioId}' ({stale.LedgerId}): scenario now passes");
                    Console.WriteLine($"PASS: {scenarioId}");
                }
                catch (Exception error)
                {
                    if (KnownEditRecordDivergences.TryGetValue(scenarioId, out var reg))
                    {
                        Console.WriteLine($"KNOWN DIVERGENCE [{scenarioId}] ({reg.LedgerId}): {reg.Reason} | observed: {error.Message}");
                    }
                    else
                    {
                        var line = $"RED ANCHOR [{scenarioId}]: {error.Message}";
                        failures.Add(line);
                        Console.WriteLine("FAIL: " + line);
                    }
                }
            }

            // 1. Roundtrip records
            foreach (var rec in roundtripList)
            {
                var id = rec.GetProperty("id").GetString()!;
                Collect("roundtrip:" + id, () =>
                {
                    var photoName = rec.GetProperty("photo").GetProperty("name").GetString()!;
                    var (built, metadata) = BuildSnapshot(rec);
                    var dir = Path.Combine(tempRoot, "rt-" + id);
                    Directory.CreateDirectory(dir);
                    var photoPath = TouchPhoto(tempRoot, photoName);
                    var store = new EditStore(dir);
                    store.Save(photoPath, built.Settings, built.Look);
                    if (metadata.TryGetProperty("migration_receipt", out var receipt) &&
                        receipt.TryGetProperty("status", out var st) && st.GetString() == ProcessingMigrationReceipt.Kept)
                    {
                        var beforeEdit = store.Find(photoPath) ?? throw new Exception($"{id}: expected saved edit before migration receipt");
                        var identity = OriginalIdentity.Read(photoPath);
                        _ = store.CommitProcessingMigration(identity, beforeEdit.Copy(), beforeEdit.Copy(), ProcessingMigrationReceipt.Kept);
                    }
                    var reopened = new EditStore(dir);
                    var reloaded = reopened.Find(photoPath) ?? throw new Exception($"{id}: reloaded edit must not be null");
                    VerifyEdit(reloaded, rec);
                    if (metadata.TryGetProperty("migration_receipt", out var receipt2) &&
                        receipt2.TryGetProperty("status", out var st2) && st2.GetString() == ProcessingMigrationReceipt.Kept)
                    {
                        Check(reopened.ReadProcessingMigration(photoPath)?.Status == ProcessingMigrationReceipt.Kept,
                            $"{id}: kept migration receipt must reload");
                    }
                });
            }

            // 2. X1 read-side unknown field scenarios
            foreach (var sc in root.GetProperty("unknown_field_scenarios").EnumerateArray())
            {
                var id = sc.GetProperty("id").GetString()!;
                var baseId = sc.GetProperty("base_record_id").GetString()!;
                var baseRec = byId[baseId];
                var scope = sc.GetProperty("target_scope").GetString()!;
                var key = sc.GetProperty("inject_key").GetString()!;
                var val = sc.GetProperty("inject_value").Clone();
                Collect(id, () =>
                {
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

                    var reopened = new EditStore(dir);
                    var loadedTarget = reopened.Find(targetPath) ?? throw new Exception($"{id}: target record must remain readable");
                    VerifyEdit(loadedTarget, baseRec);
                    var loadedSibling = reopened.Find(sibPath);
                    Check(loadedSibling != null, $"{id}: sibling record must remain readable");
                });
            }

            // 3. Cross-version compatibility scenarios
            foreach (var sc in root.GetProperty("compatibility_scenarios").EnumerateArray())
            {
                var id = sc.GetProperty("id").GetString()!;
                var kind = sc.GetProperty("kind").GetString()!;
                var baseRec = byId[sc.GetProperty("base_record_id").GetString()!];
                Collect(id, () =>
                {
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

                            var loaded = new EditStore(dir).Find(url) ?? throw new Exception($"{id}: legacy record must load");
                            Check(loaded.Settings.Processing.Version == 1, $"{id}: omitted Processing must default to v1");
                            Check(loaded.Settings.X3fMode == X3fMode.Legacy, $"{id}: omitted X3fMode must default to Legacy");
                            Check(loaded.Settings.HDR == null, $"{id}: omitted HDR must default to null");
                            break;
                        }
                        case "sdr_reset_preserves_dormant_hdr":
                        {
                            var (built, _) = BuildSnapshot(baseRec);
                            var dir = Path.Combine(tempRoot, "c-" + id);
                            Directory.CreateDirectory(dir);
                            var url = TouchPhoto(tempRoot, $"c-{id}.ARW");
                            var store = new EditStore(dir);
                            store.Save(url, built.Settings, built.Look);
                            var loadedBefore = new EditStore(dir).ReadState(url);
                            Check(loadedBefore.Edit != null, $"{id}: expected seeded edit");
                            var res = EditorAdjustmentRules.PrepareReset(new(EditorResetKind.All), loadedBefore.Edit!);
                            Check(res.Status == EditorResetStatus.Ready && res.Candidate != null, $"{id}: expected Ready reset candidate");
                            _ = new EditStore(dir).SaveState(res.Candidate!.Identity, res.Candidate);

                            var after = new EditStore(dir).Find(url) ?? throw new Exception($"{id}: reset record must remain readable");
                            Check(after.Settings.Processing.Version == 2, $"{id}: Processing v2 preserved");
                            Check(after.Settings.X3fMode == X3fMode.Legacy, $"{id}: X3fMode legacy preserved");
                            Check(after.Settings.ProRAWDecodeVersion == 2, $"{id}: ProRAWDecodeVersion 2 preserved");
                            Check(after.Settings.HDR?.Mode == HDRMode.Sdr, $"{id}: dormant HDR mode stays Sdr");
                            Check(Approx(after.Settings.HDR?.Exposure ?? -99, -0.5), $"{id}: dormant HDR exposure preserved");
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
                            Check(mutated.Contains("-0.0", StringComparison.Ordinal), $"{id}: test setup failed to inject -0.0");
                            File.WriteAllText(editsFile, mutated);

                            var loaded = new EditStore(dir).Find(url) ?? throw new Exception($"{id}: negative zero record failed to load");
                            var exposure = loaded.Settings.Values[(int)Parameter.Exposure];
                            Check(exposure == 0.0 && !double.IsNegative(exposure),
                                $"{id}: -0.0 must canonicalize to +0.0 (got {exposure}, IsNegative={double.IsNegative(exposure)})");
                            break;
                        }
                        default:
                            throw new Exception("Unhandled compat kind: " + kind);
                    }
                });
            }

            // 4. Boundary rejection scenarios
            foreach (var sc in root.GetProperty("boundary_scenarios").EnumerateArray())
            {
                var id = sc.GetProperty("id").GetString()!;
                var baseRec = byId[sc.GetProperty("base_record_id").GetString()!];
                var sibRec = byId[sc.GetProperty("sibling_record_id").GetString()!];
                var mutation = sc.GetProperty("mutation");
                var mKind = mutation.GetProperty("kind").GetString()!;
                Collect(id, () =>
                {
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
                                    throw new Exception("Unhandled out_of_range field: " + field);
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
                            throw new Exception("Unhandled boundary mutation: " + mKind);
                    }

                    File.WriteAllText(editsFile, registry.ToJsonString());

                    var reopened = new EditStore(dir);
                    var threw = false;
                    try { _ = reopened.ReadState(targetPath); }
                    catch (UnusableEditRecordException) { threw = true; }
                    Check(threw, $"{id}: invalid boundary value must throw UnusableEditRecordException");
                    Check(reopened.Find(sibPath) != null, $"{id}: sibling must remain readable");
                });
            }

            var unregistered = KnownEditRecordDivergences.Keys.Except(evaluatedIds, StringComparer.Ordinal).ToArray();
            Check(unregistered.Length == 0, "Unmatched registered edit-record divergences: " + string.Join(", ", unregistered));
            Check(failures.Count == 0, $"{failures.Count} Windows edit-record scenario(s) failed:\n" + string.Join(Environment.NewLine, failures));
            Console.WriteLine($"PASS: Windows edit-record fixture suite finished with {KnownEditRecordDivergences.Count} registered divergences (cap {MaxKnownEditRecordDivergences})");
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
        var sdrValues = record.GetProperty("sdr_values");
        var hasHdrValues = record.TryGetProperty("hdr_values", out var hdrValues) && hdrValues.ValueKind == JsonValueKind.Object;
        var hasDormant = record.TryGetProperty("dormant_hdr_values", out var dormantHdr) && dormantHdr.ValueKind == JsonValueKind.Object;
        var hasLocal = record.TryGetProperty("local_values", out var localValues) && localValues.ValueKind == JsonValueKind.Object;
        var hdrEditing = metadata.TryGetProperty("hdr_editing", out var he) && he.GetBoolean();

        var values = new double[ParameterSpec.All.Length];
        values[(int)Parameter.Strength] = 100.0;
        values[(int)Parameter.Temperature] = 6500.0;

        var procVer = metadata.GetProperty("processing").GetProperty("version").GetInt32();
        var processing = procVer == 1 ? ProcessingIdentity.Legacy : procVer == 2 ? ProcessingIdentity.C5 : ProcessingIdentity.Current;
        var x3fMode = metadata.GetProperty("x3f_mode").GetString() == "legacy" ? X3fMode.Legacy : X3fMode.Normal;
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
        if (sdrValues.TryGetProperty("looks.reference", out var lookRef) && lookRef.ValueKind == JsonValueKind.Object &&
            lookRef.TryGetProperty("kind", out var lkKind) && lkKind.GetString() == "recipe" &&
            lookRef.TryGetProperty("id", out var lkId) && lkId.ValueKind == JsonValueKind.String)
        {
            masterRecipeId = lkId.GetString();
        }
        var masterRecipeSettingsVersion = metadata.TryGetProperty("master_recipe_settings_version", out var mrv) && mrv.ValueKind == JsonValueKind.Number
            ? mrv.GetInt32() : 3;

        if (sdrValues.TryGetProperty("looks.strength", out var ls)) values[(int)Parameter.Strength] = ls.GetDouble() * 100.0;
        if (sdrValues.TryGetProperty("light.exposure", out var le)) values[(int)Parameter.Exposure] = le.GetDouble();
        var exposureMode = 1;
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

        var cameraWhiteBalance = true;
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

        ToneCurveSettings? curve = null;
        if (sdrValues.TryGetProperty("light.curve", out var cvObj) && cvObj.ValueKind == JsonValueKind.Object)
        {
            var parsed = ParseCurve(cvObj);
            curve = parsed.IsDefault ? null : parsed;
        }

        var toneControls = new ToneControlsSettings();
        if (sdrValues.TryGetProperty("tone.black_point", out var bp)) toneControls = toneControls with { BlackPoint = bp.GetDouble() };
        if (sdrValues.TryGetProperty("tone.white_point", out var wp)) toneControls = toneControls with { WhitePoint = wp.GetDouble() };
        if (sdrValues.TryGetProperty("color.vibrance", out var vib)) toneControls = toneControls with { Vibrance = vib.GetDouble() };

        var grading = new ColorGradingSettings();
        if (sdrValues.TryGetProperty("color.grading.shadows", out var cgs)) grading = grading with { Shadows = ParseWheel(cgs) };
        if (sdrValues.TryGetProperty("color.grading.midtones", out var cgm)) grading = grading with { Midtones = ParseWheel(cgm) };
        if (sdrValues.TryGetProperty("color.grading.highlights", out var cgh)) grading = grading with { Highlights = ParseWheel(cgh) };

        var hsl = new HslSettings();
        for (var idx = 0; idx < HslChannels.Length; idx++)
        {
            var ch = HslChannels[idx];
            if (sdrValues.TryGetProperty("color.hsl.hue." + ch, out var v0)) hsl = hsl.WithValue(0, idx, v0.GetDouble());
            if (sdrValues.TryGetProperty("color.hsl.saturation." + ch, out var v1)) hsl = hsl.WithValue(1, idx, v1.GetDouble());
            if (sdrValues.TryGetProperty("color.hsl.lightness." + ch, out var v2)) hsl = hsl.WithValue(2, idx, v2.GetDouble());
        }

        var fx = new PhotoEffectsSettings();
        if (sdrValues.TryGetProperty("effects.vignette.amount", out var va)) fx = fx with { VignetteAmount = va.GetDouble() };
        if (sdrValues.TryGetProperty("effects.vignette.midpoint", out var vm)) fx = fx with { VignetteMidpoint = vm.GetDouble() };
        if (sdrValues.TryGetProperty("effects.vignette.roundness", out var vr)) fx = fx with { VignetteRoundness = vr.GetDouble() };
        if (sdrValues.TryGetProperty("effects.vignette.feather", out var vf)) fx = fx with { VignetteFeather = vf.GetDouble() };
        if (sdrValues.TryGetProperty("effects.vignette.highlights", out var vh)) fx = fx with { VignetteHighlights = vh.GetDouble() };
        if (sdrValues.TryGetProperty("effects.grain.amount", out var ga)) fx = fx with { GrainAmount = ga.GetDouble() };
        if (sdrValues.TryGetProperty("effects.grain.size", out var gs)) fx = fx with { GrainSize = gs.GetDouble() };
        if (sdrValues.TryGetProperty("effects.grain.roughness", out var gr)) fx = fx with { GrainRoughness = gr.GetDouble() };

        var atm = new AtmosphereSettings();
        if (sdrValues.TryGetProperty("effects.clarity", out var cl)) atm = atm with { Clarity = cl.GetDouble() };
        if (sdrValues.TryGetProperty("effects.dehaze", out var dh)) atm = atm with { Dehaze = dh.GetDouble() };

        var chromaMode = sdrValues.TryGetProperty("detail.denoise.chroma_mode", out var cm) ? cm.GetInt32() : 0;
        var denoise = new DenoiseSettings();
        if (sdrValues.TryGetProperty("detail.denoise.wavelet", out var wdObj) && wdObj.ValueKind == JsonValueKind.Object)
        {
            denoise = new DenoiseSettings(
                wdObj.GetProperty("enabled").GetBoolean(),
                wdObj.GetProperty("luma").GetDouble(),
                wdObj.GetProperty("chroma").GetDouble(),
                wdObj.GetProperty("coarse").GetDouble());
        }

        var geom = new GeometrySettings();
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

        var lens = new LensSettings();
        if (sdrValues.TryGetProperty("geometry.lens.distortion", out var ld)) lens = lens with { Distortion = ld.GetBoolean() };
        if (sdrValues.TryGetProperty("geometry.lens.tca", out var lt)) lens = lens with { Tca = lt.GetBoolean() };
        if (sdrValues.TryGetProperty("geometry.lens.vignetting", out var lv)) lens = lens with { Vignetting = lv.GetBoolean() };
        if (sdrValues.TryGetProperty("geometry.lens.auto_crop", out var lac)) lens = lens with { AutoCrop = lac.GetBoolean() };
        if (sdrValues.TryGetProperty("geometry.lens.profile_id", out var lpid) && lpid.ValueKind == JsonValueKind.String)
            lens = lens with { Manual = true, ProfileId = lpid.GetString() };

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
        var look = masterRecipeId != null ? "recipe:" + masterRecipeId : null;
        return ((snapshot, look), metadata);
    }

    private static void VerifyCurve(JsonElement expected, ToneCurveSettings actual, string label)
    {
        var expMode = expected.GetProperty("mode").GetString() ?? "legacy";
        Check((actual.Mode == ToneCurveMode.Custom ? "custom" : "legacy") == expMode, $"{label}: curve mode mismatch");
        var expPts = expected.GetProperty("points").EnumerateArray().ToArray();
        Check(actual.Points.Count == expPts.Length, $"{label}: curve point count mismatch");
        for (var i = 0; i < expPts.Length; i++)
        {
            Check(Approx(actual.Points[i].X, expPts[i][0].GetDouble()) && Approx(actual.Points[i].Y, expPts[i][1].GetDouble()),
                $"{label}: curve point {i} mismatch");
        }
        if (expected.TryGetProperty("channels", out var chObj))
        {
            foreach (var (cname, shape) in new[] {
                ("red", actual.Channels.Red), ("green", actual.Channels.Green), ("blue", actual.Channels.Blue) })
            {
                if (!chObj.TryGetProperty(cname, out var expShape)) continue;
                var em = expShape.GetProperty("mode").GetString() ?? "legacy";
                Check((shape.Mode == ToneCurveMode.Custom ? "custom" : "legacy") == em, $"{label}: curve channel {cname} mode");
                var epts = expShape.GetProperty("points").EnumerateArray().ToArray();
                Check(shape.Points.Count == epts.Length, $"{label}: curve channel {cname} count");
                for (var i = 0; i < epts.Length; i++)
                {
                    Check(Approx(shape.Points[i].X, epts[i][0].GetDouble()) && Approx(shape.Points[i].Y, epts[i][1].GetDouble()),
                        $"{label}: curve channel {cname}[{i}]");
                }
            }
        }
    }

    private static void VerifyEdit(SavedEdit actual, JsonElement record)
    {
        var id = record.GetProperty("id").GetString()!;
        var metadata = record.GetProperty("metadata");
        var sdrValues = record.GetProperty("sdr_values");
        var hasHdr = record.TryGetProperty("hdr_values", out var hdrValues) && hdrValues.ValueKind == JsonValueKind.Object;
        var hasDormant = record.TryGetProperty("dormant_hdr_values", out var dormant) && dormant.ValueKind == JsonValueKind.Object;
        var hasLocal = record.TryGetProperty("local_values", out var localValues) && localValues.ValueKind == JsonValueKind.Object;
        var hdrEditing = metadata.TryGetProperty("hdr_editing", out var he) && he.GetBoolean();
        var s = actual.Settings;

        string? expRecipe = metadata.TryGetProperty("master_recipe_id", out var mri) && mri.ValueKind == JsonValueKind.String
            ? mri.GetString() : null;
        Check(s.MasterRecipeID == expRecipe, $"{id}: MasterRecipeID mismatch");
        Check(actual.Look == (expRecipe != null ? "recipe:" + expRecipe : null), $"{id}: SavedEdit.Look mismatch");
        Check(s.Processing.Version == metadata.GetProperty("processing").GetProperty("version").GetInt32(), $"{id}: Processing.Version");
        Check((s.X3fMode == X3fMode.Legacy ? "legacy" : "normal-v1") == metadata.GetProperty("x3f_mode").GetString(), $"{id}: X3fMode");
        if (metadata.TryGetProperty("master_recipe_settings_version", out var mrv) && mrv.ValueKind == JsonValueKind.Number)
            Check(s.MasterRecipeSettingsVersion == mrv.GetInt32(), $"{id}: MasterRecipeSettingsVersion");
        if (metadata.TryGetProperty("pro_raw_decode_version", out var prd))
        {
            int? expPrd = prd.ValueKind == JsonValueKind.Number ? prd.GetInt32() : null;
            Check(s.ProRAWDecodeVersion == expPrd, $"{id}: ProRAWDecodeVersion");
        }
        if (metadata.TryGetProperty("as_shot_wb", out var wb) && wb.ValueKind == JsonValueKind.Object)
        {
            Check(Approx(s.AsShotTemperature ?? -1, wb.GetProperty("temperature").GetDouble()) &&
                  Approx(s.AsShotTint ?? -999, wb.GetProperty("tint").GetDouble()), $"{id}: AsShot WB");
        }
        Check((s.HDR?.Mode == HDRMode.Hdr) == hdrEditing, $"{id}: IsHDREditing mismatch");

        if (sdrValues.TryGetProperty("looks.strength", out var ls)) Check(Approx(s.Values[(int)Parameter.Strength] / 100.0, ls.GetDouble()), $"{id}: looks.strength");
        if (sdrValues.TryGetProperty("light.exposure", out var le)) Check(Approx(s.Values[(int)Parameter.Exposure], le.GetDouble()), $"{id}: exposure");
        if (sdrValues.TryGetProperty("light.exposure_mode", out var em))
        {
            var actualEm = s.ExposureMode == 0 ? "scene" : s.ExposureMode == 1 ? "preview" : "sensor";
            Check(actualEm == em.GetString(), $"{id}: exposure_mode");
        }
        if (sdrValues.TryGetProperty("light.contrast", out var lc)) Check(Approx(1.0 + s.Values[(int)Parameter.Contrast] / 100.0, lc.GetDouble()), $"{id}: contrast");
        if (sdrValues.TryGetProperty("light.highlights", out var lhi)) Check(Approx(-s.Values[(int)Parameter.Highlights] / 100.0, lhi.GetDouble()), $"{id}: highlights");
        if (sdrValues.TryGetProperty("light.shadows", out var lsh)) Check(Approx(s.Values[(int)Parameter.Shadows] / 100.0, lsh.GetDouble()), $"{id}: shadows");
        if (sdrValues.TryGetProperty("light.s_curve", out var lsc)) Check(Approx(s.Values[(int)Parameter.ToneCurve] / 100.0, lsc.GetDouble()), $"{id}: s_curve");
        if (sdrValues.TryGetProperty("light.curve", out var cv)) VerifyCurve(cv, s.Curve ?? new ToneCurveSettings(), id + ".sdr");

        var toneControls = s.ToneControls ?? new ToneControlsSettings();
        if (sdrValues.TryGetProperty("tone.black_point", out var bp)) Check(Approx(toneControls.BlackPoint, bp.GetDouble()), $"{id}: black_point");
        if (sdrValues.TryGetProperty("tone.white_point", out var wp)) Check(Approx(toneControls.WhitePoint, wp.GetDouble()), $"{id}: white_point");
        if (sdrValues.TryGetProperty("color.vibrance", out var vib)) Check(Approx(toneControls.Vibrance, vib.GetDouble()), $"{id}: vibrance");

        var grading = s.ColorGrading ?? new ColorGradingSettings();
        if (sdrValues.TryGetProperty("color.grading.shadows", out var cgs))
            Check(Approx(grading.Shadows.Hue, cgs.GetProperty("hue").GetDouble()) && Approx(grading.Shadows.Saturation, cgs.GetProperty("saturation").GetDouble()), $"{id}: grading.shadows");
        if (sdrValues.TryGetProperty("color.grading.midtones", out var cgm))
            Check(Approx(grading.Midtones.Hue, cgm.GetProperty("hue").GetDouble()) && Approx(grading.Midtones.Saturation, cgm.GetProperty("saturation").GetDouble()), $"{id}: grading.midtones");
        if (sdrValues.TryGetProperty("color.grading.highlights", out var cgh))
            Check(Approx(grading.Highlights.Hue, cgh.GetProperty("hue").GetDouble()) && Approx(grading.Highlights.Saturation, cgh.GetProperty("saturation").GetDouble()), $"{id}: grading.highlights");

        if (sdrValues.TryGetProperty("color.white_balance.mode", out var wbm) && wbm.GetString() == "temperature")
        {
            Check(!s.CameraWhiteBalance, $"{id}: wb mode custom");
            if (sdrValues.TryGetProperty("color.white_balance.temperature_kelvin", out var kt)) Check(Approx(s.Values[(int)Parameter.Temperature], kt.GetDouble()), $"{id}: wb temp");
            if (sdrValues.TryGetProperty("color.white_balance.tint", out var ktn)) Check(Approx(s.Values[(int)Parameter.Tint], ktn.GetDouble()), $"{id}: wb tint");
        }
        if (sdrValues.TryGetProperty("color.saturation", out var csa)) Check(Approx(1.0 + s.Values[(int)Parameter.Saturation] / 100.0, csa.GetDouble()), $"{id}: saturation");

        var hsl = s.Hsl ?? new HslSettings();
        for (var idx = 0; idx < HslChannels.Length; idx++)
        {
            var ch = HslChannels[idx];
            if (sdrValues.TryGetProperty("color.hsl.hue." + ch, out var v0)) Check(Approx(hsl.Value(0, idx), v0.GetDouble()), $"{id}: hsl.hue.{ch}");
            if (sdrValues.TryGetProperty("color.hsl.saturation." + ch, out var v1)) Check(Approx(hsl.Value(1, idx), v1.GetDouble()), $"{id}: hsl.sat.{ch}");
            if (sdrValues.TryGetProperty("color.hsl.lightness." + ch, out var v2)) Check(Approx(hsl.Value(2, idx), v2.GetDouble()), $"{id}: hsl.lit.{ch}");
        }

        var fx = s.Effects ?? new PhotoEffectsSettings();
        if (sdrValues.TryGetProperty("effects.vignette.amount", out var va)) Check(Approx(fx.VignetteAmount, va.GetDouble()), $"{id}: vignette.amount");
        if (sdrValues.TryGetProperty("effects.vignette.midpoint", out var vm)) Check(Approx(fx.VignetteMidpoint, vm.GetDouble()), $"{id}: vignette.midpoint");
        if (sdrValues.TryGetProperty("effects.vignette.roundness", out var vr)) Check(Approx(fx.VignetteRoundness, vr.GetDouble()), $"{id}: vignette.roundness");
        if (sdrValues.TryGetProperty("effects.vignette.feather", out var vf)) Check(Approx(fx.VignetteFeather, vf.GetDouble()), $"{id}: vignette.feather");
        if (sdrValues.TryGetProperty("effects.vignette.highlights", out var vh)) Check(Approx(fx.VignetteHighlights, vh.GetDouble()), $"{id}: vignette.highlights");
        if (sdrValues.TryGetProperty("effects.grain.amount", out var ga)) Check(Approx(fx.GrainAmount, ga.GetDouble()), $"{id}: grain.amount");
        if (sdrValues.TryGetProperty("effects.grain.size", out var gs)) Check(Approx(fx.GrainSize, gs.GetDouble()), $"{id}: grain.size");
        if (sdrValues.TryGetProperty("effects.grain.roughness", out var gr)) Check(Approx(fx.GrainRoughness, gr.GetDouble()), $"{id}: grain.roughness");

        var atm = s.Atmosphere ?? new AtmosphereSettings();
        if (sdrValues.TryGetProperty("effects.clarity", out var cl)) Check(Approx(atm.Clarity, cl.GetDouble()), $"{id}: clarity");
        if (sdrValues.TryGetProperty("effects.dehaze", out var dh)) Check(Approx(atm.Dehaze, dh.GetDouble()), $"{id}: dehaze");
        if (sdrValues.TryGetProperty("detail.sharpening", out var dsh)) Check(Approx(s.Values[(int)Parameter.Sharpening] / 100.0, dsh.GetDouble()), $"{id}: sharpening");
        if (sdrValues.TryGetProperty("detail.denoise.chroma_mode", out var cm)) Check(s.DisplayChromaDenoise == cm.GetInt32(), $"{id}: chroma_mode");
        if (sdrValues.TryGetProperty("detail.denoise.wavelet", out var wdObj) && wdObj.ValueKind == JsonValueKind.Object)
        {
            var dn = s.Denoise ?? throw new Exception($"{id}: expected Denoise non-null");
            Check(dn.Enabled == wdObj.GetProperty("enabled").GetBoolean(), $"{id}: wavelet.enabled");
            Check(Approx(dn.Luma, wdObj.GetProperty("luma").GetDouble()) &&
                  Approx(dn.Chroma, wdObj.GetProperty("chroma").GetDouble()) &&
                  Approx(dn.Coarse, wdObj.GetProperty("coarse").GetDouble()), $"{id}: wavelet values");
        }

        var geom = s.Geometry ?? new GeometrySettings();
        if (sdrValues.TryGetProperty("geometry.crop.x", out var gx)) Check(Approx(geom.CropX, gx.GetDouble()), $"{id}: cropX");
        if (sdrValues.TryGetProperty("geometry.crop.y", out var gy)) Check(Approx(geom.CropY, gy.GetDouble()), $"{id}: cropY");
        if (sdrValues.TryGetProperty("geometry.crop.width", out var gw)) Check(Approx(geom.CropWidth, gw.GetDouble()), $"{id}: cropW");
        if (sdrValues.TryGetProperty("geometry.crop.height", out var gh)) Check(Approx(geom.CropHeight, gh.GetDouble()), $"{id}: cropH");
        if (sdrValues.TryGetProperty("geometry.quarter_turns", out var qt)) Check(geom.QuarterTurns == qt.GetInt32(), $"{id}: quarterTurns");
        if (sdrValues.TryGetProperty("geometry.flip_horizontal", out var fh)) Check(geom.FlipHorizontal == fh.GetBoolean(), $"{id}: flipH");
        if (sdrValues.TryGetProperty("geometry.flip_vertical", out var fv)) Check(geom.FlipVertical == fv.GetBoolean(), $"{id}: flipV");
        if (sdrValues.TryGetProperty("geometry.straighten_degrees", out var stg)) Check(Approx(geom.StraightenDegrees, stg.GetDouble()), $"{id}: straighten");
        if (sdrValues.TryGetProperty("geometry.perspective.horizontal", out var ph)) Check(Approx(geom.PerspectiveHorizontal, ph.GetDouble()), $"{id}: perspH");
        if (sdrValues.TryGetProperty("geometry.perspective.vertical", out var pv)) Check(Approx(geom.PerspectiveVertical, pv.GetDouble()), $"{id}: perspV");

        if (sdrValues.TryGetProperty("geometry.lens.distortion", out var ld))
        {
            var lens = s.Lens ?? new LensSettings();
            Check(lens.Distortion == ld.GetBoolean(), $"{id}: lens.distortion");
            Check(lens.Tca == sdrValues.GetProperty("geometry.lens.tca").GetBoolean(), $"{id}: lens.tca");
            Check(lens.Vignetting == sdrValues.GetProperty("geometry.lens.vignetting").GetBoolean(), $"{id}: lens.vignetting");
            Check(lens.AutoCrop == sdrValues.GetProperty("geometry.lens.auto_crop").GetBoolean(), $"{id}: lens.autoCrop");
            string? expPid = sdrValues.TryGetProperty("geometry.lens.profile_id", out var lpid) && lpid.ValueKind == JsonValueKind.String
                ? lpid.GetString() : null;
            Check(lens.ProfileId == expPid, $"{id}: lens.profileID");
        }

        if (hdrEditing ? hasHdr : hasDormant)
        {
            var hdrCheck = hdrEditing ? hdrValues : dormant;
            var hdr = s.HDR ?? throw new Exception($"{id}: expected HDR subtree to be preserved");
            Check((hdr.Mode == HDRMode.Hdr) == hdrEditing, $"{id}: HDR.Mode mismatch");
            if (hdrCheck.TryGetProperty("light.exposure", out var hev)) Check(Approx(hdr.Exposure, hev.GetDouble()), $"{id}: hdr.exposure");
            if (hdrCheck.TryGetProperty("light.contrast", out var hct)) Check(Approx(1.0 + hdr.Contrast / 100.0, hct.GetDouble()), $"{id}: hdr.contrast");
            if (hdrCheck.TryGetProperty("light.highlights", out var hhi)) Check(Approx(-hdr.Highlights / 100.0, hhi.GetDouble()), $"{id}: hdr.highlights");
            if (hdrCheck.TryGetProperty("light.shadows", out var hsh)) Check(Approx(hdr.Shadows / 100.0, hsh.GetDouble()), $"{id}: hdr.shadows");
            if (hdrCheck.TryGetProperty("color.saturation", out var hsat)) Check(Approx(1.0 + hdr.Saturation / 100.0, hsat.GetDouble()), $"{id}: hdr.saturation");
            if (hdrCheck.TryGetProperty("hdr.relative_temperature", out var hrt)) Check(Approx(hdr.Temperature, hrt.GetDouble()), $"{id}: hdr.temp");
            if (hdrCheck.TryGetProperty("hdr.relative_tint", out var hrtn)) Check(Approx(hdr.Tint, hrtn.GetDouble()), $"{id}: hdr.tint");
            if (hdrCheck.TryGetProperty("hdr.peak_limit_ev", out var hpk)) Check(Approx(hdr.RenditionSettings.PeakLimitEV, hpk.GetDouble()), $"{id}: hdr.peakLimit");
            if (hdrCheck.TryGetProperty("hdr.sdr_exposure_ev", out var hse)) Check(Approx(hdr.RenditionSettings.SdrExposureEV, hse.GetDouble()), $"{id}: hdr.sdrExp");
            if (hdrCheck.TryGetProperty("hdr.sdr_contrast", out var hsct)) Check(Approx(hdr.RenditionSettings.SdrContrast, hsct.GetDouble()), $"{id}: hdr.sdrContrast");
            if (hdrCheck.TryGetProperty("hdr.sdr_saturation", out var hssat)) Check(Approx(hdr.RenditionSettings.SdrSaturation, hssat.GetDouble()), $"{id}: hdr.sdrSat");
            if (hdrCheck.TryGetProperty("detail.denoise.post_rgb", out var hpr)) Check(Approx(hdr.DetailSettings.Denoise, hpr.GetDouble()), $"{id}: hdr.denoise");
            if (hdrCheck.TryGetProperty("light.curve", out var hcv)) VerifyCurve(hcv, hdr.ToneSettings.Curve, id + ".hdr");
            if (hdrCheck.TryGetProperty("hdr.look", out var hlk) && hlk.ValueKind == JsonValueKind.Object)
            {
                Check(hdr.LookSettings.Sha256 == hlk.GetProperty("sha256").GetString() &&
                      hdr.LookSettings.Name == hlk.GetProperty("name").GetString() &&
                      Approx(hdr.LookSettings.Strength, hlk.GetProperty("strength").GetDouble()), $"{id}: hdr.look");
            }
            if (hdrCheck.TryGetProperty("hdr.camera_development", out var hcam) && hcam.ValueKind == JsonValueKind.Object)
            {
                Check((hdr.CameraSettings.CustomWhiteBalance ? "temperature" : "as_shot") == hcam.GetProperty("white_balance_mode").GetString(), $"{id}: hdr.cam.wb");
                Check(Approx(hdr.CameraSettings.Temperature, hcam.GetProperty("temperature").GetDouble()), $"{id}: hdr.cam.temp");
                Check(Approx(hdr.CameraSettings.Tint, hcam.GetProperty("tint").GetDouble()), $"{id}: hdr.cam.tint");
                Check((hdr.CameraSettings.SensorExposure ? "sensor" : "metadata") == hcam.GetProperty("exposure_reference").GetString(), $"{id}: hdr.cam.expRef");
                Check(hdr.CameraSettings.FbddLevel == hcam.GetProperty("fbdd_level").GetInt32(), $"{id}: hdr.cam.fbdd");
                if (metadata.TryGetProperty("hdr_camera_development_extra", out var hextra) && hextra.ValueKind == JsonValueKind.Object)
                {
                    if (hextra.TryGetProperty("lens_profile", out var hlp) && hlp.ValueKind == JsonValueKind.String)
                        Check(hdr.CameraSettings.LensProfile == hlp.GetString(), $"{id}: hdr.cam.lensProfile");
                    if (hextra.TryGetProperty("camera_profile", out var hcp) && hcp.ValueKind == JsonValueKind.Object)
                        Check(hdr.CameraSettings.CameraProfile?.Sha256 == hcp.GetProperty("sha256").GetString(), $"{id}: hdr.cam.camProfile");
                }
            }
        }

        if (hasLocal && localValues.TryGetProperty("local.ai_denoise_enabled", out var ai))
            Check(s.AIDenoiseEnabled == ai.GetBoolean(), $"{id}: AIDenoiseEnabled");
        if (hasLocal && localValues.TryGetProperty("local.hdr_camera_ai_enabled", out var hai))
            Check(s.HDRCameraAIEnabled == hai.GetBoolean(), $"{id}: HDRCameraAIEnabled");
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
