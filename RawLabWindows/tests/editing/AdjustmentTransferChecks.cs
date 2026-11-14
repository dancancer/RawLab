using RawLab.Windows;
using System.Text.Json;
using F = RawLab.Windows.AdjustmentField;
using static RawLab.Windows.AdjustmentPayload;

internal static class AdjustmentTransferChecks
{
    internal static void Run()
    {
        NeutralRawRequestsOnRaster();
        NonRawSourcePreservesRawExposureAndWhiteBalance();
        RecipeSourceScalesOnHDRTarget();
        FullNeutralRecipeOnRaster();
        BuiltinRawRecipesOnRaster();
        var context = new AdjustmentTransferContext("source", true);
        var identity = new OriginalIdentity("photo.arw", 1, 2, 3);
        var settings = new Adjustments(); settings.Set(Parameter.Exposure, 1.25);
        var source = new SavedEdit(identity, settings.Capture(), null);
        var payload = AdjustmentTransfer.Capture(AdjustmentScope.Standard, source, context);
        if (payload.Fields.Any(x => x.Group() == "geometry")) throw new Exception("Default excludes geometry");
        var frozen = AdjustmentPayload.Parse(payload.ToJson());
        settings.Set(Parameter.Exposure, 2);
        var target = new SavedEdit(identity, new Adjustments { Processing = ProcessingIdentity.Legacy }.Capture(), null);
        var candidate = AdjustmentTransfer.Prepare(frozen, target, context);
        if (candidate.Settings.Restore()[Parameter.Exposure] != 1.25 || candidate.Settings.Processing != ProcessingIdentity.Legacy)
            throw new Exception("Frozen logical values preserve target processing");
        Console.WriteLine("PASS: Windows selective payload capture, frozen JSON and processing provenance");
        Vectors(); Scenarios(); AdapterChecks(); TransferNoticeLifecycleChecks();
    }
    private static void Check(bool condition,string message) {if(!condition)throw new Exception(message);}
    private static void Reject(Action action,string message)
    {try {action();}catch(AdjustmentTransferException){return;}throw new Exception(message);}
    private static readonly OriginalIdentity Identity=new("test.arw",1,2,3);
    private static readonly AdjustmentTransferContext Context=new("source",true);
    private static SavedEdit Edit(Adjustments? value=null,string? look=null)=>new(Identity,(value ?? new()).Capture(),look);
    private static AdjustmentPayload Payload(params (F Field,object? Value)[] values)=>new(new("source",true,2),values.ToDictionary(p=>p.Field,p=>Value(p.Value)));
    private static SavedEdit Prepare(AdjustmentPayload payload,Adjustments? target=null,AdjustmentTransferContext? context=null)=>AdjustmentTransfer.Prepare(payload,Edit(target),context ?? Context);
    private static AdjustmentPayload Copy(Adjustments source,params F[] fields)=>AdjustmentTransfer.Capture(AdjustmentScope.Custom(fields),Edit(source),Context);
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
    private static bool SamePayload(AdjustmentPayload a, AdjustmentPayload b) =>
        a.PayloadVersion == b.PayloadVersion &&
        a.ScopeVersion == b.ScopeVersion &&
        a.Source == b.Source &&
        a.Values.Count == b.Values.Count &&
        a.Values.All(pair => b.Values.TryGetValue(pair.Key, out var other) && Same(pair.Value, other));
    private static HashSet<string> ScenarioFixtureAllFieldIDs()
    {
        using var document = JsonDocument.Parse(File.ReadAllText(ResolveFixturePath("Shared/fixtures/adjustment-transfer-scenarios-v1.json")));
        foreach (var scenario in document.RootElement.GetProperty("scenarios").EnumerateArray())
        {
            if (scenario.GetProperty("id").GetString() == "raster-all-preserves-raw-scene-wb-lens")
                return scenario.GetProperty("payload").GetProperty("values").EnumerateObject().Select(p => p.Name).ToHashSet();
        }
        throw new Exception("Missing baseline all-scope scenario in adjustment-transfer-scenarios-v1.json");
    }
    private static void Vectors()
    {
        using var document=JsonDocument.Parse(File.ReadAllText(ResolveFixturePath("Shared/fixtures/adjustment-transfer-v1.json")));
        Check(document.RootElement.GetProperty("fixture_version").GetInt32()==1,"Payload fixture version must be 1");
        var vectors=document.RootElement.GetProperty("vectors");
        Check(vectors.GetArrayLength()>0,"Payload fixture must not be empty");
        var seen=new HashSet<string>();
        foreach(var vector in vectors.EnumerateArray()) {
            var json=vector.GetProperty("payload").GetRawText();var id=vector.GetProperty("id").GetString()!;
            Check(seen.Add(id),"Duplicate vector ID: "+id);
            if(!vector.GetProperty("valid").GetBoolean()) {Reject(()=>AdjustmentPayload.Parse(json),"accepted invalid vector "+id);continue;}
            var payload=AdjustmentPayload.Parse(json);
            Check(SamePayload(payload,AdjustmentPayload.Parse(payload.ToJson())),"round-trip mismatch "+id);
            if(vector.TryGetProperty("neutral_effective",out var expected)) {
                var actual=AdjustmentTransfer.EffectiveNumbers(Prepare(payload).Settings);
                foreach(var field in expected.EnumerateObject())Check(actual[AdjustmentFields.Parse(field.Name)]==(float)field.Value.GetDouble(),"native request mismatch "+id+" "+field.Name);
            }
        }
        Check(seen.Count==vectors.GetArrayLength(),"All shared payload vectors consumed");
        var fixtureFields=ScenarioFixtureAllFieldIDs();
        Check(AdjustmentFields.All.Count==fixtureFields.Count &&
            AdjustmentFields.All.Select(f=>f.ID()).ToHashSet().SetEquals(fixtureFields),"stable field catalog matches scenario fixture");
        Check(AdjustmentTransfer.Capture(AdjustmentScope.All,Edit(),Context).Fields.Select(f=>f.ID()).ToHashSet().SetEquals(fixtureFields),
            "all-scope capture matches scenario fixture");
        Console.WriteLine($"PASS: {seen.Count} shared payload vectors and native request equality");
    }
    private sealed record ScenarioDiff(string Key, string Summary);
    private sealed record ScenarioDivergence(string LedgerId, string Reason, IReadOnlySet<string> ExpectedKeys);
    // 显式例外清单：未登记的分歧（或同一场景出现清单外的字段差异）必红；已修复项仍留在此表也必红（棘轮只减不增）。
    private static readonly IReadOnlyDictionary<string, ScenarioDivergence> KnownScenarioDivergences =
        new Dictionary<string, ScenarioDivergence>();
    private static void Scenarios()
    {
        using var document = JsonDocument.Parse(File.ReadAllText(ResolveFixturePath("Shared/fixtures/adjustment-transfer-scenarios-v1.json")));
        var root = document.RootElement;
        Check(root.GetProperty("fixture_version").GetInt32() == 1, "Scenario fixture version must be 1");
        var scenarios = root.GetProperty("scenarios");
        Check(scenarios.GetArrayLength() > 0, "Scenario fixture must not be empty");
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
                if (!platforms.Contains("windows"))
                {
                    skippedIDs.Add(id);
                    continue;
                }
            }
            evaluatedIDs.Add(id);
            var diffs = EvaluateScenario(id, scenario);
            var actualKeys = diffs.Select(d => d.Key).ToHashSet();
            var summary = string.Join("; ", diffs.Select(d => d.Summary));
            var hasKnown = KnownScenarioDivergences.TryGetValue(id, out var known);
            if (diffs.Count > 0 && !hasKnown)
                problems.Add($"Scenario {id} diverged: {summary}");
            else if (diffs.Count == 0 && hasKnown)
                problems.Add($"Scenario {id} now matches fixture; remove stale divergence ({known!.LedgerId}: {known.Reason})");
            else if (hasKnown && !actualKeys.SetEquals(known!.ExpectedKeys))
                problems.Add($"Scenario {id} divergence keys changed (expected=[{string.Join(", ", known.ExpectedKeys.Order(StringComparer.Ordinal))}], actual=[{string.Join(", ", actualKeys.Order(StringComparer.Ordinal))}]): {summary}");
            else if (hasKnown)
                Console.WriteLine($"KNOWN DIVERGENCE [{id}] ({known!.LedgerId} - {known.Reason}): {summary}");
        }

        Check(seenIDs.Count == scenarios.GetArrayLength(), "All scenario IDs visited");
        Check(evaluatedIDs.Count + skippedIDs.Count == scenarios.GetArrayLength(), "All scenarios accounted for");
        var unknownRegistered = KnownScenarioDivergences.Keys.Except(evaluatedIDs).ToArray();
        Check(unknownRegistered.Length == 0, "Registered divergences do not match evaluated scenarios: " + string.Join(", ", unknownRegistered));
        if (problems.Count > 0) throw new Exception(string.Join(Environment.NewLine, problems));
        Console.WriteLine($"PASS: {evaluatedIDs.Count} Windows transfer scenarios evaluated ({skippedIDs.Count} platform-scoped skipped, {KnownScenarioDivergences.Count} registered divergences)");
    }
    private static List<ScenarioDiff> EvaluateScenario(string id, JsonElement scenario)
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
            "sdr_raster" => new Adjustments { ExposureMode = 2 },
            "hdr" => new Adjustments { HDR = new HDRSettings { Mode = HDRMode.Hdr } },
            _ => throw new Exception($"Scenario {id}: unsupported target kind {kind}")
        };
        if (kind == "sdr_raw" && asShot is { } wb) initialSettings.ResolveWhiteBalance(wb);
        var scenarioContext = new AdjustmentTransferContext(
            "scenario-target",
            kind == "sdr_raw",
            AvailableLookIDs: availableLooks,
            DefaultExposureMode: kind == "sdr_raw" ? 1 : 2,
            ValidateLens: lensValid ? (_ => { }) : null,
            CameraWhiteBalance: kind == "sdr_raw" ? asShot : null);
        var targetState = new SavedEdit(targetIdentity, initialSettings.Capture(), null);
        if (targetSpec.TryGetProperty("seed_payload", out var seedElem) && seedElem.ValueKind != JsonValueKind.Null)
        {
            var seedPayload = AdjustmentPayload.Parse(seedElem.GetRawText());
            Check(SamePayload(seedPayload, AdjustmentPayload.Parse(seedPayload.ToJson())), $"Scenario {id}: seed payload round-trip");
            targetState = AdjustmentTransfer.Prepare(seedPayload, targetState, scenarioContext with { ValidateLens = _ => { } });
        }

        var payload = AdjustmentPayload.Parse(scenario.GetProperty("payload").GetRawText());
        Check(SamePayload(payload, AdjustmentPayload.Parse(payload.ToJson())), $"Scenario {id}: payload round-trip");
        // S3：收集 prepare 期间的忽略/版本提示，与 fixture 声明按集合比较。
        var scenarioNotices = new List<AdjustmentTransferNotice>();
        var expectSpec = scenario.TryGetProperty("platform_expect", out var platformExpect) &&
                         platformExpect.ValueKind == JsonValueKind.Object &&
                         platformExpect.TryGetProperty("windows", out var windowsExpect) &&
                         windowsExpect.ValueKind == JsonValueKind.Object
            ? windowsExpect
            : scenario.GetProperty("expect");
        var expectedStatus = expectSpec.GetProperty("status").GetString()!;
        var diffs = new List<ScenarioDiff>();
        if (expectedStatus == "rejected")
        {
            var expectedReason = expectSpec.TryGetProperty("reason", out var reasonElem) && reasonElem.ValueKind == JsonValueKind.String
                ? reasonElem.GetString()
                : null;
            try
            {
                var unexpected = AdjustmentTransfer.Prepare(payload, targetState, scenarioContext);
                var unexpectedStatus = unexpected.SameAs(targetState) ? "unchanged" : "applied";
                diffs.Add(new("status", $"status expected=rejected({expectedReason ?? "any"}), actual={unexpectedStatus}"));
            }
            catch (AdjustmentTransferException error)
            {
                var actualReason = ErrorReason(error);
                if (expectedReason != null && actualReason != expectedReason)
                    diffs.Add(new("rejected_reason", $"rejected reason expected={expectedReason}, actual={actualReason} ({error.Message})"));
            }
            return diffs;
        }

        var isUnchangedWithoutValues = expectedStatus == "unchanged" &&
            (!expectSpec.TryGetProperty("values", out var vElem) || vElem.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined);
        SavedEdit candidate;
        try
        {
            candidate = AdjustmentTransfer.Prepare(payload, targetState, scenarioContext with { OnTransferNotice = scenarioNotices.Add });
        }
        catch (AdjustmentTransferException error)
        {
            var statusKey = isUnchangedWithoutValues ? $"status:rejected:{ErrorReason(error)}" : "status";
            diffs.Add(new(statusKey, $"status expected={expectedStatus}, actual=rejected({ErrorReason(error)}: {error.Message})"));
            return diffs;
        }
        var actualStatus = candidate.SameAs(targetState) ? "unchanged" : "applied";
        if (actualStatus != expectedStatus)
        {
            var statusKey = isUnchangedWithoutValues ? $"status:{actualStatus}" : "status";
            diffs.Add(new(statusKey, $"status expected={expectedStatus}, actual={actualStatus}"));
        }
        JsonElement noticesSpec = default;
        foreach (var noticeSource in new[] { expectSpec, scenario.GetProperty("expect") })
        {
            if (noticeSource.TryGetProperty("notices_by_platform", out var scopedElem) && scopedElem.ValueKind == JsonValueKind.Object
                && scopedElem.TryGetProperty("windows", out var scopedNotices) && scopedNotices.ValueKind == JsonValueKind.Array)
            { noticesSpec = scopedNotices; break; }
            if (noticeSource.TryGetProperty("notices", out var flatNotices) && flatNotices.ValueKind == JsonValueKind.Array)
            { noticesSpec = flatNotices; break; }
        }
        if (noticesSpec.ValueKind == JsonValueKind.Array)
        {
            var expectedNotices = noticesSpec.EnumerateArray().Select(x => x.GetString()!).ToHashSet();
            var actualNotices = scenarioNotices.Select(notice => notice.FixtureId()).ToHashSet();
            if (!expectedNotices.SetEquals(actualNotices))
                diffs.Add(new("notices", $"notices expected=[{string.Join(", ", expectedNotices.Order(StringComparer.Ordinal))}], actual=[{string.Join(", ", actualNotices.Order(StringComparer.Ordinal))}]"));
        }
        if (isUnchangedWithoutValues && actualStatus == "applied")
        {
            var targetCaptured = AdjustmentTransfer.Capture(AdjustmentScope.All, targetState, scenarioContext).Values;
            var candidateCaptured = AdjustmentTransfer.Capture(AdjustmentScope.All, candidate, scenarioContext).Values;
            foreach (var field in AdjustmentFields.All.OrderBy(f => f.ID(), StringComparer.Ordinal))
            {
                var hasTarget = targetCaptured.TryGetValue(field, out var before);
                var hasCandidate = candidateCaptured.TryGetValue(field, out var after);
                if (!hasTarget && !hasCandidate) continue;
                if (!hasTarget || !hasCandidate || !MatchesJsonValue(after, before))
                {
                    diffs.Add(new("changed:" + field.ID(), $"changed {field.ID()} before={(hasTarget ? JsonSerializer.Serialize(before) : "<missing>")}, after={(hasCandidate ? JsonSerializer.Serialize(after) : "<missing>")}"));
                }
            }
        }
        if (expectSpec.TryGetProperty("values", out var valuesElem) && valuesElem.ValueKind == JsonValueKind.Object)
        {
            var captured = AdjustmentTransfer.Capture(AdjustmentScope.All, candidate, scenarioContext).Values;
            foreach (var prop in valuesElem.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal))
            {
                var field = AdjustmentFields.Parse(prop.Name);
                var hasActual = captured.TryGetValue(field, out var actualVal);
                if (!MatchesJsonValue(hasActual ? actualVal : null, prop.Value))
                    diffs.Add(new("value:" + prop.Name, $"value {prop.Name} expected={prop.Value.GetRawText()}, actual={(hasActual ? JsonSerializer.Serialize(actualVal) : "<missing>")}"));
            }
        }
        if (expectSpec.TryGetProperty("effective", out var effectiveElem) && effectiveElem.ValueKind == JsonValueKind.Object)
        {
            var actualEffective = AdjustmentTransfer.EffectiveNumbers(candidate.Settings);
            foreach (var prop in effectiveElem.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal))
            {
                var field = AdjustmentFields.Parse(prop.Name);
                var expectedNum = prop.Value.GetDouble();
                var hasActual = actualEffective.TryGetValue(field, out var actualNum);
                if (!hasActual || Math.Abs(actualNum - expectedNum) > 1e-6)
                    diffs.Add(new("effective:" + prop.Name, $"effective {prop.Name} expected={expectedNum}, actual={(hasActual ? actualNum.ToString(System.Globalization.CultureInfo.InvariantCulture) : "<missing>")}"));
            }
        }
        return diffs;
    }
    private static string ErrorReason(AdjustmentTransferException error) => error.Failure switch
    {
        AdjustmentFailure.Incompatible => "incompatible",
        AdjustmentFailure.Unrepresentable => "unrepresentable",
        AdjustmentFailure.MissingLook => "missing_look",
        _ => $"other({error.Failure})"
    };
    private static bool MatchesJsonValue(JsonElement? actual, JsonElement expected, double tolerance = 1e-6)
    {
        if (actual is not { } actualValue || actualValue.ValueKind != expected.ValueKind) return false;
        return expected.ValueKind switch
        {
            JsonValueKind.Null or JsonValueKind.True or JsonValueKind.False => true,
            JsonValueKind.String => actualValue.GetString() == expected.GetString(),
            JsonValueKind.Number => Math.Abs(actualValue.GetDouble() - expected.GetDouble()) <= tolerance,
            JsonValueKind.Array => actualValue.GetArrayLength() == expected.GetArrayLength() &&
                actualValue.EnumerateArray().Zip(expected.EnumerateArray()).All(pair => MatchesJsonValue(pair.First, pair.Second, tolerance)),
            JsonValueKind.Object => MatchesJsonObject(actualValue, expected, tolerance),
            _ => false
        };
    }
    private static bool MatchesJsonObject(JsonElement actual, JsonElement expected, double tolerance)
    {
        var actualProps = actual.EnumerateObject().ToDictionary(p => p.Name, p => p.Value);
        var expectedProps = expected.EnumerateObject().ToDictionary(p => p.Name, p => p.Value);
        return actualProps.Count == expectedProps.Count &&
               expectedProps.All(pair => actualProps.TryGetValue(pair.Key, out var av) && MatchesJsonValue(av, pair.Value, tolerance));
    }
    private static void FullNeutralRecipeOnRaster()
    {
        var recipe=MasterRecipe.All[0];
        var raster=Context with {IsRaw=false,AvailableLookIDs=new HashSet<string>{"recipe:"+recipe.Id}};
        var target=new Adjustments {ExposureMode=2};target.ApplyMasterRecipe(recipe);
        var source=target.Capture().Restore();source.Set(Parameter.Tint,0);
        var complete=AdjustmentTransfer.Capture(AdjustmentScope.Standard,Edit(source),Context);
        var applied=AdjustmentTransfer.Prepare(complete,Edit(target),raster);
        Check(!applied.Settings.SameAs(target.Capture()) && applied.Settings.Values[(int)Parameter.Tint]==0,
            "Full neutral RAW recipe clears previous raster tint and counts as changed");
        Check(Number(AdjustmentTransferValues.Values(applied,raster)[F.Tint])==0,"Full neutral recipe exposes zero logical tint");
        Check(AdjustmentTransfer.Prepare(complete,applied,raster).Settings.SameAs(applied.Settings),"Repeated full neutral recipe is unchanged");
    }
    private static void BuiltinRawRecipesOnRaster()
    {
        var raster=Context with {IsRaw=false,AvailableLookIDs=MasterRecipe.All.Select(r=>"recipe:"+r.Id).ToHashSet()};
        foreach(var recipe in MasterRecipe.All) foreach(var strength in new[]{0.0,.5,1.0,2.0}) {
            var source=new Adjustments();source.ApplyMasterRecipe(recipe);source.Set(Parameter.Strength,strength*100);
            var direct=new Adjustments {ExposureMode=2};direct.ApplyMasterRecipe(recipe);direct.Set(Parameter.Strength,strength*100);
            var previous=new Adjustments {ExposureMode=2};previous.ApplyMasterRecipe(MasterRecipe.All[0]);
            foreach(var scope in new[]{AdjustmentScope.Standard,AdjustmentScope.All}) {
                var frozen=AdjustmentPayload.Parse(AdjustmentTransfer.Capture(scope,Edit(source),Context).ToJson());
                var applied=AdjustmentTransfer.Prepare(frozen,Edit(previous),raster);
                var actual=AdjustmentTransferValues.Values(applied,raster);var expected=AdjustmentTransferValues.Values(Edit(direct),raster);
                // Windows 百分比渲染中途转 Float；对比度/饱和度回算有既有舍入，WB 等其他逻辑值仍精确比较。
                Check(actual.All(pair=>pair.Key is F.Contrast or F.Saturation
                    ? Math.Abs(Number(pair.Value)!.Value-Number(expected[pair.Key])!.Value)<1e-6
                    : Same(pair.Value,expected[pair.Key])),"Builtin RAW recipe matches direct raster application: "+recipe.Id);
                Check(AdjustmentTransfer.Prepare(frozen,applied,raster).Settings.SameAs(applied.Settings),"Repeated builtin RAW recipe is unchanged");
            }
            source.Set(Parameter.Tint,recipe.TintDelta+1);
            var edited=AdjustmentTransfer.Capture(AdjustmentScope.Standard,Edit(source),Context);
            Reject(()=>AdjustmentTransfer.Prepare(edited,Edit(previous),raster),"Manually edited full recipe tint blocks raster");
            source.Set(Parameter.Tint,recipe.TintDelta);source.Set(Parameter.Temperature,5400);
            var fixedWB=AdjustmentTransfer.Capture(AdjustmentScope.Standard,Edit(source),Context);
            Reject(()=>AdjustmentTransfer.Prepare(fixedWB,Edit(previous),raster),"Full recipe with fixed WB blocks raster");
        }
        Console.WriteLine("PASS: All builtin RAW recipes match direct raster application at four strengths; edited WB stays blocked");
    }
    private static void NeutralRawRequestsOnRaster()
    {
        var raster=Context with {Identifier="target.jpg",IsRaw=false};
        var target=Edit(new Adjustments {ExposureMode=2});
        var source=new Adjustments();source.ResolveWhiteBalance((5123,17));
        foreach(var mode in new[]{0,1,2}) {
            source.ExposureMode=mode;source.Set(Parameter.Exposure,1.25);
            var standard=AdjustmentTransfer.Capture(AdjustmentScope.Standard,Edit(source),Context);
            var applied=AdjustmentTransfer.Prepare(standard,target,raster);
            Check(!applied.Settings.SameAs(target.Settings) && applied.Settings.Values[1]==1.25,"RAW standard paste keeps other changes on JPEG");
            var values=AdjustmentTransferValues.Values(applied,raster);
            Check(Text(values[F.WhiteBalanceMode])=="none" && applied.Settings.CameraWhiteBalance
                && applied.Settings.Values[2]==6500 && applied.Settings.Values[3]==0 && applied.Settings.ExposureMode==2,
                "JPEG keeps neutral WB and sensor exposure for every RAW exposure mode");
            Check(AdjustmentTransfer.Prepare(standard,applied,raster).Settings.SameAs(applied.Settings),"Repeated RAW standard paste is unchanged");
            source.Set(Parameter.Exposure,0);
            var neutral=AdjustmentTransfer.Capture(AdjustmentScope.Standard,Edit(source),Context);
            Check(AdjustmentTransfer.Prepare(neutral,target,raster).Settings.SameAs(target.Settings),"Neutral RAW standard paste is unchanged on JPEG");
            Check(AdjustmentTransfer.Prepare(Copy(source,F.ExposureMode),target,raster).Settings.SameAs(target.Settings),"RAW exposure mode alone is unchanged on JPEG");
        }
        foreach(var field in AdjustmentFields.WhiteBalance)
            Check(AdjustmentTransfer.Prepare(Copy(source,field),target,raster).Settings.SameAs(target.Settings),"Neutral partial WB is unchanged on JPEG");
        var camera=Payload((F.WhiteBalanceMode,"camera"),(F.Temperature,null),(F.Tint,null));
        var recipe=MasterRecipe.All[0];
        foreach(var strength in new[]{0.0,1.0}) {
            var values=camera.Values.ToDictionary(p=>p.Key,p=>p.Value);values[F.Tint]=Value(0);
            var zero=new AdjustmentPayload(camera.Source with {Recipe=new(recipe.Id,strength,3)},values);
            Check(AdjustmentTransfer.Prepare(zero,target,raster).Settings.SameAs(target.Settings),"Zero recipe tint is neutral on JPEG");
            var nonzero=new AdjustmentPayload(zero.Source,new Dictionary<F,JsonElement>{{F.Tint,Value(5)}});
            Reject(()=>AdjustmentTransfer.Prepare(nonzero,target,raster),"Nonzero recipe tint blocks JPEG even at zero strength");
        }
        foreach(var fixedWB in new[]{Payload((F.WhiteBalanceMode,"temperature"),(F.Temperature,5400),(F.Tint,3.5)),
            Payload((F.Temperature,5400)),Payload((F.Tint,3.5))})
            Reject(()=>AdjustmentTransfer.Prepare(fixedWB,target,raster),"Fixed RAW WB is incompatible with JPEG");
        var rasterFbddNotices=new List<AdjustmentTransferNotice>();
        Check(AdjustmentTransfer.Prepare(Payload((F.RawDenoise,1)),target,raster with {OnTransferNotice=rasterFbddNotices.Add}).Settings.SameAs(target.Settings),
            "Nonzero RAW FBDD is ignored on JPEG instead of rejecting");
        Check(rasterFbddNotices.Contains(AdjustmentTransferNotice.IgnoredRawDenoise),"Ignored JPEG FBDD reports a one-time prompt");
        Console.WriteLine("PASS: Windows neutral RAW default/partial paste on JPEG, unchanged detection and incompatible effective requests");
    }
    private static void NonRawSourcePreservesRawExposureAndWhiteBalance()
    {
        var raster=Context with {Identifier="source.jpg",IsRaw=false};
        var jpeg=new Adjustments {ExposureMode=2};jpeg.Set(Parameter.Exposure,.75);
        var scopes=new[]{AdjustmentScope.All,AdjustmentScope.Standard,
            AdjustmentScope.Custom(new[]{F.Exposure,F.ExposureMode,F.WhiteBalanceMode,F.Temperature,F.Tint}),
            AdjustmentScope.Custom(new[]{F.ExposureMode}),AdjustmentScope.Custom(new[]{F.WhiteBalanceMode})};
        foreach(var mode in new[]{0,1}) foreach(var customWb in new[]{false,true}) {
            var target=new Adjustments {ExposureMode=mode};target.ResolveWhiteBalance((5120,14));
            if(customWb) {target.Set(Parameter.Temperature,5850);target.Set(Parameter.Tint,-18);}
            var before=target.Capture();
            foreach(var scope in scopes) {
                var copy=AdjustmentPayload.Parse(AdjustmentTransfer.Capture(scope,Edit(jpeg),raster).ToJson());
                if(copy[F.ExposureMode] is {} em)Check(Text(em)=="sensor","Non-RAW source captures sensor exposure placeholder");
                if(copy[F.WhiteBalanceMode] is {} wm)Check(Text(wm)=="none","Non-RAW source captures none WB placeholder");
                var applied=AdjustmentTransfer.Prepare(copy,Edit(target),Context).Settings;
                Check(applied.ExposureMode==mode,"Non-RAW paste preserves RAW target ExposureMode "+mode);
                Check(applied.CameraWhiteBalance==before.CameraWhiteBalance &&
                    applied.Values[(int)Parameter.Temperature]==before.Values[(int)Parameter.Temperature] &&
                    applied.Values[(int)Parameter.Tint]==before.Values[(int)Parameter.Tint],
                    "Non-RAW paste preserves RAW target white balance");
                if(copy.Fields.Contains(F.Exposure))Check(applied.Values[(int)Parameter.Exposure]==.75,"Non-RAW paste still applies exposure");
            }
            var neutralJpeg=new Adjustments {ExposureMode=2};
            foreach(var scope in new[]{AdjustmentScope.Standard,AdjustmentScope.All}) {
                var neutralCopy=AdjustmentTransfer.Capture(scope,Edit(neutralJpeg),raster);
                Check(AdjustmentTransfer.Prepare(neutralCopy,Edit(target),Context).Settings.SameAs(before),
                    "Neutral non-RAW paste is unchanged on RAW with custom exposure baseline or WB");
            }
        }
        var rasterTarget=Edit(new Adjustments {ExposureMode=2});
        Check(AdjustmentTransfer.Prepare(AdjustmentTransfer.Capture(AdjustmentScope.Standard,Edit(jpeg),raster),rasterTarget,raster).Settings.ExposureMode==2,
            "Ordinary target still keeps sensor exposure mode");
        foreach(var mode in new[]{0,2}) {
            var rawSource=new Adjustments {ExposureMode=mode};rawSource.ResolveWhiteBalance((5120,14));
            rawSource.Set(Parameter.Temperature,6100);rawSource.Set(Parameter.Tint,9);
            var rawAll=AdjustmentTransfer.Capture(AdjustmentScope.Standard,Edit(rawSource),Context);
            var rawApplied=Prepare(rawAll).Settings;
            Check(rawApplied.ExposureMode==mode && !rawApplied.CameraWhiteBalance &&
                rawApplied.Values[(int)Parameter.Temperature]==6100 && rawApplied.Values[(int)Parameter.Tint]==9,
                "RAW source still transfers ExposureMode and white balance to RAW target");
        }
        Console.WriteLine("PASS: Non-RAW placeholder exposure baseline and white balance are skipped on RAW targets");
    }
    private static void RecipeSourceScalesOnHDRTarget()
    {
        var recipe=MasterRecipe.All[0];
        var hdrContext=new AdjustmentTransferContext("hdr.jpg",false);
        var hdrTarget=new SavedEdit(new("hdr.jpg",1,2,3),new Adjustments {HDR=new HDRSettings {Mode=HDRMode.Hdr}}.Capture(),null);
        var scalarFields=new[]{F.Exposure,F.Contrast,F.Highlights,F.Shadows,F.Saturation};
        foreach(var strength in new[]{0.0,.5,1.0,1.5}) {
            var source=new Adjustments();source.ApplyMasterRecipe(recipe);
            source.Set(Parameter.Strength,strength*100);
            source.Set(Parameter.Exposure,1.2);source.Set(Parameter.Contrast,40);
            source.Set(Parameter.Highlights,-60);source.Set(Parameter.Shadows,60);source.Set(Parameter.Saturation,-20);
            var copy=AdjustmentPayload.Parse(AdjustmentTransfer.Capture(AdjustmentScope.Custom(scalarFields),Edit(source),Context).ToJson());
            var summary=new AdjustmentSummary(copy,System.Globalization.CultureInfo.InvariantCulture,text=>text);
            Check(summary.RecipeNote!=null && summary.RecipeNote.Contains("按此强度换算"),"Recipe summary states strength conversion");
            var applied=AdjustmentTransfer.Prepare(copy,hdrTarget,hdrContext).Settings.HDR!;
            Check(Math.Abs(applied.Exposure-1.2*strength)<1e-9 &&
                Math.Abs(applied.Contrast-40*strength)<1e-9 &&
                Math.Abs(applied.Highlights-(-60*strength))<1e-9 &&
                Math.Abs(applied.Shadows-60*strength)<1e-9 &&
                Math.Abs(applied.Saturation-(-20*strength))<1e-9,
                "Recipe source scalars scale once on HDR target at strength "+strength);
        }
        var overflow=new Adjustments();overflow.ApplyMasterRecipe(recipe);
        overflow.Set(Parameter.Strength,150);overflow.Set(Parameter.Shadows,80);
        var overflowCopy=AdjustmentTransfer.Capture(AdjustmentScope.Custom(new[]{F.Shadows}),Edit(overflow),Context);
        Reject(()=>AdjustmentTransfer.Prepare(overflowCopy,hdrTarget,hdrContext),"Scaled recipe value beyond HDR range is rejected");
        var plain=new Adjustments();plain.Set(Parameter.Exposure,1.2);plain.Set(Parameter.Contrast,40);
        var plainCopy=AdjustmentTransfer.Capture(AdjustmentScope.Custom(new[]{F.Exposure,F.Contrast}),Edit(plain),Context);
        var plainApplied=AdjustmentTransfer.Prepare(plainCopy,hdrTarget,hdrContext).Settings.HDR!;
        Check(plainApplied.Exposure==1.2 && plainApplied.Contrast==40,"Plain source scalars stay unscaled on HDR target");
        Console.WriteLine("PASS: Recipe source strength scales the five shared scalars on HDR targets");
    }
    private static void AdapterChecks()
    {
        Check(Prepare(Payload((F.Exposure,1.2))).Settings.Values[1]==1.2,"Selected decimal exposure keeps its logical Double value");
        Check(Prepare(Payload((F.HslHueRed,13.15))).Settings.Hsl!.Value(0,0)==13.15,"Selected decimal HSL keeps its logical Double value");
        var recipe=MasterRecipe.All[0];var source=new Adjustments();source.ApplyMasterRecipe(recipe);source.Set(Parameter.Strength,50);
        source.Set(Parameter.Exposure,1.4);source.Hsl=source.Hsl.WithValue(0,0,12.375);
        var context=Context with {AvailableLookIDs=new HashSet<string>{"recipe:"+recipe.Id}};
        var selected=Copy(source,F.Exposure,F.HslHueRed);
        var result=Prepare(selected);
        Check(AdjustmentTransfer.EffectiveNumbers(result.Settings)[F.Exposure]==.7f,"recipe contribution applied once");
        Check(result.Settings.Hsl!.Value(0,0)==6.1875,"fractional HSL preserved");
        var defaults=new Adjustments();defaults.ResolveWhiteBalance((5100,11));
        var all=AdjustmentTransfer.Capture(AdjustmentScope.All,Edit(source),context);
        var retained=Prepare(all,defaults,context);
        Check(retained.Settings.MasterRecipeID==recipe.Id && retained.Settings.AsShotTint==11,"complete recipe retains target calibration");
        var legacyValues=all.Values.ToDictionary(p=>p.Key,p=>p.Value);legacyValues[F.HslHueRed]=Value(37.25);
        var legacy=new AdjustmentPayload(all.Source with {Recipe=all.Source.Recipe! with {SettingsVersion=2}},legacyValues);
        var legacyResult=Prepare(legacy,defaults,context);
        Check(legacyResult.Settings.MasterRecipeID==recipe.Id && AdjustmentTransfer.EffectiveNumbers(legacyResult.Settings)[F.HslHueRed]==37.25f,
            "Full legacy HSL is inversely represented in the current Windows renderer");
        Check(AdjustmentTransfer.Capture(AdjustmentScope.All,legacyResult,context).Source.Recipe!.SettingsVersion==2,
            "Recapture preserves the explicitly stored legacy HSL semantics");
        var partial=Prepare(Copy(source,F.Look),defaults,context);
        Check(partial.Settings.MasterRecipeID==null && partial.Look=="recipe-lut:"+recipe.Id,"partial recipe look becomes independent LUT");
        source.Set(Parameter.Strength,0);
        var modified=AdjustmentTransfer.Capture(AdjustmentScope.Modified,Edit(source),context);
        Check(modified.Fields.Contains(F.Exposure),"zero strength does not hide logical edits");
        Reject(()=>Prepare(Payload((F.Exposure,1.0)),source),"zero-scale target cannot represent selected exposure");
        var target=new Adjustments();target.ApplyMasterRecipe(recipe);target.ResolveWhiteBalance((5100,11));target.Set(Parameter.Strength,50);
        target.Set(Parameter.Exposure,1.234);target.Set(Parameter.Contrast,17.789);
        var before=AdjustmentTransfer.EffectiveNumbers(target.Capture());
        var strength=Prepare(Payload((F.Strength,1.0)),target).Settings;
        var after=AdjustmentTransfer.EffectiveNumbers(strength);
        foreach(var field in before.Keys.Where(f=>f!=F.Strength))Check(before[field]==after[field],"strength preserves unselected "+field);
        Check(strength.CameraWhiteBalance==target.CameraWhiteBalance,"strength retains unselected camera WB mode when recipe can represent it");
        var self=AdjustmentTransfer.Capture(AdjustmentScope.All,Edit(target),context);
        Check(Prepare(self,target,context).Settings.SameAs(target.Capture()),"same full recipe is exactly unchanged");
        Reject(()=>Prepare(Payload((F.CropX,.2))),"partial crop cannot silently shrink unselected width");
        foreach(var endpoint in new[]{-5.0,5.0})
            Check(Prepare(Payload((F.Exposure,endpoint))).Settings.Restore()[Parameter.Exposure]==endpoint,
                "ordinary exposure endpoints survive selective transfer");
        Reject(()=>Prepare(Payload((F.Exposure,5.01))),"native exposure range is narrower than payload");
        var denoiseNotices=new List<AdjustmentTransferNotice>();
        Check(Prepare(Payload((F.RawDenoise,1)),context:Context with {OnTransferNotice=denoiseNotices.Add}).Settings.SameAs(Edit(null).Settings),
            "nonzero FBDD is ignored with a notice instead of rejecting");
        Check(denoiseNotices.Contains(AdjustmentTransferNotice.IgnoredRawDenoise),"ignored FBDD reports a one-time prompt");
        var postNotices=new List<AdjustmentTransferNotice>();
        Check(Prepare(Payload((F.PostRGBDenoise,.1)),context:Context with {OnTransferNotice=postNotices.Add}).Settings.SameAs(Edit(null).Settings),
            "nonzero post RGB is ignored with a notice instead of rejecting");
        Check(postNotices.Contains(AdjustmentTransferNotice.IgnoredPostRGBDenoise),"ignored post RGB reports a one-time prompt");
        // Q4：来源处理版本（v2）低于目标（v3）不拒绝，沿用目标处理版本并一次性提示。
        var versionNotices=new List<AdjustmentTransferNotice>();
        Check(Prepare(Payload((F.Exposure,1.25)),context:Context with {OnTransferNotice=versionNotices.Add}).Settings.Restore()[Parameter.Exposure]==1.25,
            "stale source processing version pastes through instead of rejecting");
        Check(versionNotices.Contains(AdjustmentTransferNotice.RetainedTargetProcessingVersion),"retained processing version reports a one-time prompt");
        Reject(()=>Prepare(Payload((F.LensDistortion,true))),"lens enabled requires target calibration");
        var lensValidated=false;var lens=Prepare(Payload((F.LensDistortion,true)),context:Context with {ValidateLens=l=>lensValidated=l.Distortion});
        Check(lensValidated && lens.Settings.Lens!.Distortion,"lens validator called");
        Reject(()=>Prepare(Payload((F.LensProfile,"test-profile")),context:Context with {IsRaw=false}),"raster rejects disabled explicit lens profile");
        var manualLens=new Adjustments {Lens=new LensSettings(Manual:true)};
        foreach(var scope in new[]{AdjustmentScope.All,AdjustmentScope.Custom(new[]{F.LensProfile})}) {
            var copied=AdjustmentTransfer.Capture(scope,Edit(manualLens),Context);
            Check(Text(copied[F.LensProfile])==manualLens.Lens.CoreProfileId,"manual lens uses reserved transport");
            var applied=Prepare(AdjustmentPayload.Parse(copied.ToJson()));
            Check(applied.Settings.Lens!.Manual && applied.Settings.Lens.ProfileId==null,"manual lens preserves nil profile after round-trip");
        }
        var standardManual=AdjustmentTransfer.Capture(AdjustmentScope.Standard,Edit(manualLens),Context);
        Check(standardManual.Fields.All(f=>!AdjustmentFields.Lens.Contains(f)),"default scope excludes manual lens selection");
        var enabledManual=new Adjustments {Lens=new LensSettings(Distortion:true,Manual:true)};
        var enabledPayload=Copy(enabledManual,F.LensDistortion,F.LensProfile);var validatorCalled=false;
        Reject(()=>Prepare(enabledPayload,context:Context with {ValidateLens=_=>validatorCalled=true}),"enabled manual lens without profile rejects");
        Check(!validatorCalled,"missing manual profile rejects before target validation");
        Reject(()=>Prepare(Payload((F.Temperature,5500))),"partial temperature cannot implicitly change camera mode");
        var wb=Prepare(Payload((F.WhiteBalanceMode,"temperature"),(F.Temperature,5500),(F.Tint,15)),defaults);
        Check(!wb.Settings.CameraWhiteBalance && wb.Settings.AsShotTemperature==5100 && wb.Settings.Values[2]==5500 && wb.Settings.Values[3]==15,"fixed WB keeps target calibration");
        var fractionalWB=Prepare(Payload((F.WhiteBalanceMode,"temperature"),(F.Temperature,5500.5),(F.Tint,1.2)),defaults);
        Check(fractionalWB.Settings.Values[2]==5500.5 && fractionalWB.Settings.Values[3]==1.2,"Fixed WB preserves exact selected decimal values when native requests match");
        Reject(()=>Prepare(Payload((F.WhiteBalanceMode,"temperature"),(F.Temperature,5500),(F.Tint,15)),context:Context with {IsRaw=false}),"Fixed RAW WB on raster blocked");
        var ai=new Adjustments{AIDenoiseEnabled=true,Denoise=DenoiseSettings.Clean};
        Reject(()=>AdjustmentTransfer.Capture(AdjustmentScope.All,Edit(ai),Context),"AI all capture blocked");
        Reject(()=>AdjustmentTransfer.Capture(AdjustmentScope.Modified,Edit(ai),Context),"AI modified capture blocked");
        Check(Copy(ai,F.Exposure).Fields.Count==1,"AI custom ordinary field allowed");
        Reject(()=>Prepare(Payload((F.ChromaDenoise,1)),ai),"ordinary denoise target AI blocked");
        Check(Prepare(Payload((F.Exposure,1)),ai).Settings.AIDenoiseEnabled,"other fields preserve AI");
        Console.WriteLine("PASS: Windows recipe, partial fields, WB, lens, denoise and AI transfer boundaries");
    }

    private static void TransferNoticeLifecycleChecks()
    {
        var notices = new[] { AdjustmentTransferNotice.IgnoredRawDenoise };
        var dualNotices = new[] { AdjustmentTransferNotice.IgnoredRawDenoise, AdjustmentTransferNotice.RetainedTargetProcessingVersion };
        var prepared = new PreparedAdjustmentTransfer(
            Guid.NewGuid(),
            AdjustmentTransfer.Capture(AdjustmentScope.Custom([F.Exposure]),
                new SavedEdit(new("source.dng", 1, 2, 3), new Adjustments().Capture(), null),
                new("source.dng", true)),
            [
                new("target-a.jpg", "target-a.jpg", null, null, false, null, null, 0, [AdjustmentTransferNotice.IgnoredRawDenoise]),
                new("target-b.jpg", "target-b.jpg", null, null, true, null, null, 0, [AdjustmentTransferNotice.RetainedTargetProcessingVersion]),
                new("target-err.jpg", "target-err.jpg", null, null, false, null, new InvalidOperationException("blocked"), 0, [AdjustmentTransferNotice.IgnoredPostRGBDenoise])
            ]);
        Check(prepared.EffectiveNotices([]).Count == 0,
            "Prepared notices stay empty before apply outcomes exist");
        Check(prepared.EffectiveNotices([
                new("target-a.jpg", AdjustmentStatus.Skipped),
                new("target-b.jpg", AdjustmentStatus.Failed, Error: new IOException("disk")),
                new("target-err.jpg", AdjustmentStatus.Applied)
            ]).Count == 0,
            "Skipped, failed or errored targets suppress effective transfer notices");
        var effective = prepared.EffectiveNotices([
            new("target-a.jpg", AdjustmentStatus.Applied),
            new("target-b.jpg", AdjustmentStatus.Unchanged),
            new("target-err.jpg", AdjustmentStatus.Blocked)
        ]);
        Check(effective.SequenceEqual(dualNotices),
            "EffectiveNotices collects distinct notices only from valid applied and unchanged targets");

        // W1（#301 残留）对位 #317 IOSAdjustmentPasteNoticeDisplay.showsInSheet：
        // 弹窗在重开或新一轮预检产生结果前，即使存在旧提示也不得展示。
        Check(!AdjustmentPasteNoticeDisplay.ShowsInDialog(notices, hasPasteResults: false),
            "Dialog hides stale notices before the current batch produces paste results");
        Check(AdjustmentPasteNoticeDisplay.ShowsInDialog(notices, hasPasteResults: true),
            "Dialog shows effective notices alongside current paste results");
        Check(!AdjustmentPasteNoticeDisplay.ShowsInDialog([], hasPasteResults: true),
            "Dialog keeps notice row hidden when current batch has no notices");

        // 非当前图批量粘贴 / Unchanged 粘贴不挂起后续渲染提示，避免污染切图或滑杆拖拽。
        var nonCurrentBatch = AdjustmentTransferNoticeState.Prepare(notices, AdjustmentTransferNoticeOrigin.Dialog, appliedCurrentPhoto: false, openRevision: 10, editRevision: 20);
        Check(!nonCurrentBatch.HasPendingRenderNotice,
            "Non-current batch paste does not arm a pending render notice");
        var (afterOtherPhotoRender, leakedOtherPhoto) = nonCurrentBatch.DeliverRender(frameOpenRevision: 11, currentEditRevision: 21, isSettledFrame: true);
        Check(leakedOtherPhoto.Count == 0 && !afterOtherPhotoRender.HasPendingRenderNotice,
            "Non-current batch paste never leaks onto a subsequent photo switch render");

        var unchangedPaste = AdjustmentTransferNoticeState.Prepare(notices, AdjustmentTransferNoticeOrigin.QuickPreset, appliedCurrentPhoto: false, openRevision: 10, editRevision: 20);
        Check(!unchangedPaste.HasPendingRenderNotice,
            "Unchanged quick preset does not arm a pending render notice");
        var (afterSliderDrag, leakedSlider) = unchangedPaste.DeliverRender(frameOpenRevision: 10, currentEditRevision: 21, isSettledFrame: true);
        Check(leakedSlider.Count == 0 && !afterSliderDrag.HasPendingRenderNotice,
            "Unchanged paste never pollutes subsequent slider drag renders");

        // 当前 RAW 粘贴：瞬态 Refine / 缩放防抖帧仅保留读取、不提前消费，确保 ~200ms 后的最终帧不丢失提示。
        var currentRaw = AdjustmentTransferNoticeState.Prepare(notices, AdjustmentTransferNoticeOrigin.QuickPreset, appliedCurrentPhoto: true, openRevision: 10, editRevision: 20);
        Check(currentRaw.HasPendingRenderNotice,
            "Current RAW apply arms pending transfer notice for its settled render");
        var (afterRefine, duringRefine) = currentRaw.DeliverRender(frameOpenRevision: 10, currentEditRevision: 20, isSettledFrame: false);
        Check(duringRefine.SequenceEqual(notices) && afterRefine.HasPendingRenderNotice,
            "Transient Refine or resize frame preserves pending notice instead of dropping the settled RAW notice");
        var (afterSettled, onSettled) = afterRefine.DeliverRender(frameOpenRevision: 10, currentEditRevision: 20, isSettledFrame: true);
        Check(onSettled.SequenceEqual(notices) && !afterSettled.HasPendingRenderNotice && !afterSettled.HasNotices,
            "Settled RAW render consumes the preserved transfer notice once and clears pending state");

        // prepare / invalidate / dispose（关面板/关弹窗）/ 换图 / 手动编辑清理契约。
        var armedDialog = AdjustmentTransferNoticeState.Prepare(notices, AdjustmentTransferNoticeOrigin.Dialog, appliedCurrentPhoto: true, openRevision: 10, editRevision: 20);
        Check(!armedDialog.Invalidate().HasNotices && !armedDialog.Invalidate().HasPendingRenderNotice,
            "Prepare invalidation clears lingering transfer notices");
        Check(!armedDialog.DisposeDialog().HasNotices && !armedDialog.DisposeDialog().HasPendingRenderNotice,
            "Closing the result dialog clears lingering dialog transfer notices");
        Check(!currentRaw.DisposeQuickPreset().HasNotices && !currentRaw.DisposeQuickPreset().HasPendingRenderNotice,
            "Closing the quick preset panel clears lingering quick preset notices");
        Check(!currentRaw.AfterSourceChange().HasNotices && !currentRaw.AfterSourceChange().HasPendingRenderNotice,
            "Source switch clears lingering transfer notices before the next photo opens");
        Check(!currentRaw.AfterUserEdit().HasNotices && !currentRaw.AfterUserEdit().HasPendingRenderNotice,
            "User slider edit invalidates pending transfer notices before render completion");
        var (reopenedPhotoState, leakedReopen) = currentRaw.AfterSourceChange().DeliverRender(frameOpenRevision: 11, currentEditRevision: 21, isSettledFrame: true);
        Check(!reopenedPhotoState.HasNotices && leakedReopen.Count == 0,
            "Cleared source-switch notice never surfaces on the next photo render");

        // W1 复核 Finding 1/4 红测：稳态帧后的横幅引用保持与弹窗/早退编辑生命周期
        Func<string> cleanPreview = () => "预览 1200 × 800 · photo.ARW";
        Func<IReadOnlyList<AdjustmentTransferNotice>, Func<string>> makeBanner =
            list => () => string.Join("；", list.Select(n => n.PromptKey()));
        Func<Func<string>, IReadOnlyList<AdjustmentTransferNotice>, Func<string>> makeCombined =
            (preview, list) => () => preview() + "；" + string.Join("；", list.Select(n => n.PromptKey()));

        // 1) 稳态帧落地后关闭 QuickPresets：ActiveBanner 不得被 Pump 清空，CloseQuickPresets 必须恢复干净预览文案。
        var quickShow = AdjustmentTransferNoticeBannerState.Empty with { LastPreviewStatus = cleanPreview };
        var showResult = quickShow.Show(notices, AdjustmentTransferNoticeOrigin.QuickPreset, appliedCurrentPhoto: true,
            openRevision: 10, editRevision: 20, currentLocalizedStatus: cleanPreview, makeBannerStatus: makeBanner);
        var (afterTransient, transientStatus) = showResult.NextState.DeliverRender(
            frameOpenRevision: 10, currentEditRevision: 20, isSettledFrame: false,
            cleanPreviewStatus: cleanPreview, makeCombinedStatus: list => makeCombined(cleanPreview, list));
        var (afterSettledBanner, settledStatus) = afterTransient.DeliverRender(
            frameOpenRevision: 10, currentEditRevision: 20, isSettledFrame: true,
            cleanPreviewStatus: cleanPreview, makeCombinedStatus: list => makeCombined(cleanPreview, list));
        Check(afterSettledBanner.ActiveBanner != null && ReferenceEquals(afterSettledBanner.ActiveBanner, settledStatus),
            "Settled RAW render preserves active banner handle until panel close or edit clears it");
        var disposeAfterSettled = afterSettledBanner.DisposeQuickPreset(currentLocalizedStatus: settledStatus);
        Check(disposeAfterSettled.NextState.ActiveBanner == null && ReferenceEquals(disposeAfterSettled.StatusToApply, cleanPreview),
            "Closing quick presets after a settled RAW render restores clean preview status");

        // 2) 稳态帧落地后触发早退编辑（如 AIResultReady==false 或 Transform 切换）未重写 SetStatus 时：AfterUserEdit 必须恢复干净预览文案。
        var earlyExitEdit = afterSettledBanner.AfterUserEdit(currentLocalizedStatus: settledStatus);
        Check(earlyExitEdit.NextState.ActiveBanner == null && ReferenceEquals(earlyExitEdit.StatusToApply, cleanPreview),
            "Early-exit user edit after a settled RAW render clears the status banner back to clean preview status");

        // 3) 对齐 #317 ContentView.swift:468：Dialog 来源由 AdjustmentResultDialog 承载，主窗状态栏不得重复写横幅或挂起渲染交付。
        var dialogBase = AdjustmentTransferNoticeBannerState.Empty with { LastPreviewStatus = cleanPreview };
        var dialogShow = dialogBase.Show(notices, AdjustmentTransferNoticeOrigin.Dialog, appliedCurrentPhoto: true,
            openRevision: 10, editRevision: 20, currentLocalizedStatus: cleanPreview, makeBannerStatus: makeBanner);
        Check(dialogShow.StatusToApply == null && !dialogShow.NextState.Pending.HasPendingRenderNotice && dialogShow.NextState.ActiveBanner == null,
            "Dialog origin keeps notices inside the dialog instead of writing MainWindow status or arming pending render");
        var (afterDialogSettled, dialogSettledStatus) = dialogShow.NextState.DeliverRender(
            frameOpenRevision: 10, currentEditRevision: 20, isSettledFrame: true,
            cleanPreviewStatus: cleanPreview, makeCombinedStatus: list => makeCombined(cleanPreview, list));
        Check(ReferenceEquals(dialogSettledStatus, cleanPreview) && afterDialogSettled.ActiveBanner == null,
            "Settled RAW render after dialog paste publishes clean preview status without leaking dialog notices");
        var afterDialogClose = afterDialogSettled.DisposeDialog(currentLocalizedStatus: dialogSettledStatus);
        Check(afterDialogClose.NextState.ActiveBanner == null && afterDialogClose.StatusToApply == null,
            "Closing result dialog leaves MainWindow preview status clean");

        // 4) 进入/取消几何镜头草稿前（editRevision 未变化）触发 AfterUserEdit：待交付提示必须立即清零。
        var pendingBeforeTransform = showResult.NextState.AfterUserEdit(currentLocalizedStatus: showResult.StatusToApply);
        var (afterTransformRender, transformStatus) = pendingBeforeTransform.NextState.DeliverRender(
            frameOpenRevision: 10, currentEditRevision: 20, isSettledFrame: true,
            cleanPreviewStatus: cleanPreview, makeCombinedStatus: list => makeCombined(cleanPreview, list));
        Check(ReferenceEquals(pendingBeforeTransform.StatusToApply, cleanPreview) &&
              ReferenceEquals(transformStatus, cleanPreview) && !afterTransformRender.Pending.HasPendingRenderNotice,
            "Transform start or cancel edit clears pending transfer notices even before editRevision advances");

        Console.WriteLine("PASS: AdjustmentTransferChecks notice display, effective filter, Refine preservation and prepare/dispose/source-switch cleanup");
    }
}
