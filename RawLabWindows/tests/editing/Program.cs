using RawLab.Windows;
using System.Text.Json;
using System.Text.Json.Nodes;

ToneControlsChecks.Run();
ColorGradingChecks.Run();
ToneCurveChecks.Run();
HslTargetChecks.Run();
BatchFrozenChecks.Run();
BatchSelectionChecks.Run();
var pendingGrading = JsonSerializer.SerializeToNode(new Adjustments().Capture())!;
pendingGrading["ColorGrading"] = JsonNode.Parse("""{"Shadows":{"Hue":231.25,"Saturation":0},"Midtones":{"Hue":0,"Saturation":0},"Highlights":{"Hue":0,"Saturation":0}}""");
var gradingRestored = pendingGrading.Deserialize<AdjustmentSnapshot>()!.Restore();
if (JsonSerializer.SerializeToNode(gradingRestored.Capture())!["ColorGrading"] == null)
    throw new Exception("Pending grading hue must survive snapshot restore");
AdjustmentTransferChecks.Run();
AdjustmentHistoryChecks.Run();
AdjustmentPresetChecks.Run();

static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
static JsonNode? Processing(Adjustments value) => JsonSerializer.SerializeToNode(value.Capture())!["Processing"];
static void AIDenoisePersistenceChecks()
{
    var original = new Adjustments { Denoise = DenoiseSettings.Clean, DisplayChromaDenoise = 2 };
    var enabled = JsonSerializer.SerializeToNode(original.Capture())!.AsObject();
    enabled["AIDenoiseEnabled"] = true;
    var snapshot = enabled.Deserialize<AdjustmentSnapshot>()!;
    var restored = snapshot.Restore();
    Check(JsonSerializer.SerializeToNode(restored.Capture())!["AIDenoiseEnabled"]?.GetValue<bool>() == true,
        "AI denoise survives saved-edit restore and capture");
    Check(!snapshot.SameAs(original.Capture()), "AI-only change is an effective edit");
    Check(restored.Denoise == DenoiseSettings.Clean && restored.DisplayChromaDenoise == 2,
        "AI retains ordinary denoise parameters");
    enabled.Remove("AIDenoiseEnabled");
    var legacy = enabled.Deserialize<AdjustmentSnapshot>()!.Restore();
    Check(JsonSerializer.SerializeToNode(legacy.Capture())!["AIDenoiseEnabled"]?.GetValue<bool>() == false,
        "Old edits restore with AI disabled");
    foreach (var scope in new[] { new EditorResetScope(EditorResetKind.Group, EditorAdjustmentGroup.Detail),
        new EditorResetScope(EditorResetKind.Tool, Tool: EditorAdjustmentTool.Denoise), new EditorResetScope(EditorResetKind.All) }) {
        var candidate = EditorAdjustmentRules.PrepareReset(scope, new(new("photo.arw", 1, 2, 3), snapshot, null));
        Check(candidate.Status == EditorResetStatus.Ready &&
            JsonSerializer.SerializeToNode(candidate.Candidate!.Settings)!["AIDenoiseEnabled"]?.GetValue<bool>() == false,
            "Detail/tool/all reset clears AI enable state");
    }
    var frozen = BatchJob.Create("photo.arw", snapshot, null, "Neutral");
    Check(JsonSerializer.SerializeToNode(frozen.Copy().Settings)!["AIDenoiseEnabled"]?.GetValue<bool>() == true,
        "Batch snapshot preserves requested AI appearance");
    frozen.AIBackend=3;
    Check(JsonSerializer.Deserialize<BatchJob>(JsonSerializer.Serialize(frozen.Copy()))!.AIBackend==3,
        "Frozen batch preserves requested AI backend through copy and JSON");
    restored.ResetAll();
    Check(JsonSerializer.SerializeToNode(restored.Capture())!["AIDenoiseEnabled"]?.GetValue<bool>() == false,
        "Direct full reset clears AI");
}
AIDenoisePersistenceChecks();
await AIDenoiseJobChecks.Run();
static void ProcessingChecks()
{
    Check(Processing(new Adjustments())?["version"]?.GetValue<int>() == 2,
        "New desktop edits explicitly persist processing v2");
    var old = JsonSerializer.SerializeToNode(new Adjustments().Capture())!.AsObject();
    old.Remove("Processing");
    var restored = old.Deserialize<AdjustmentSnapshot>()!.Restore();
    Check(Processing(restored)?["version"]?.GetValue<int>() == 1,
        "Missing identity restores legacy, not the latest processing default");
    restored.Set(Parameter.Exposure, .7);
    restored.Denoise = DenoiseSettings.Clean;
    restored.ApplyMasterRecipe(MasterRecipe.All[0]);
    restored.ResetAll();
    Check(Processing(restored)?["version"]?.GetValue<int>() == 1 &&
          Processing(restored.Clone())?["version"]?.GetValue<int>() == 1,
        "Ordinary edits, recipes, reset and clone preserve legacy identity");
    var scopedLegacy = PhotoInput.PrepareInputSettings("legacy.jpg", new Adjustments { Processing = ProcessingIdentity.Legacy });
    var scopedIdentity = new OriginalIdentity("legacy.jpg", 12, 34, 56);
    var all = new EditorResetScope(EditorResetKind.All);
    Check(EditorAdjustmentRules.PrepareReset(all, new(scopedIdentity, scopedLegacy.Capture(), null)).Status == EditorResetStatus.NoChange,
        "Neutral legacy reset does not count processing identity as an adjustment");
    scopedLegacy.Set(Parameter.Exposure, .7);
    var scopedReset = EditorAdjustmentRules.PrepareReset(all, new(scopedIdentity, scopedLegacy.Capture(), null));
    Check(scopedReset.Status == EditorResetStatus.Ready && scopedReset.Candidate!.Settings.Processing == ProcessingIdentity.Legacy,
        "Scoped full reset preserves legacy identity");
    Check(JsonSerializer.Deserialize<AdjustmentSnapshot>(JsonSerializer.Serialize(scopedReset.Candidate!.Settings))!.Restore().Processing == ProcessingIdentity.Legacy,
        "Scoped legacy reset survives serialization and restore");
    var current = JsonSerializer.SerializeToNode(restored.Capture())!.AsObject();
    current["Processing"] = JsonNode.Parse("""{"family":"rawlab","version":2,"quality":"standard"}""");
    Check(!restored.Capture().SameAs(current.Deserialize<AdjustmentSnapshot>()!),
        "Snapshot equality detects processing changes even with identical sliders");
    foreach (var invalid in new[] {
        "null",
        """{"family":"other","version":1,"quality":"standard"}""",
        """{"family":"rawlab","version":3,"quality":"standard"}""",
        """{"family":"rawlab","version":0,"quality":"standard"}""",
        """{"family":"rawlab","version":true,"quality":"standard"}""",
        """{"family":"rawlab","version":1,"quality":"fast"}""",
        """{"family":"rawlab","version":1}""",
        """{"family":"rawlab","version":2,"quality":"standard","future":true}"""
    }) {
        var document = JsonSerializer.SerializeToNode(new Adjustments().Capture())!.AsObject();
        document["Processing"] = JsonNode.Parse(invalid);
        try {
            _ = document.Deserialize<AdjustmentSnapshot>()!.Restore();
            throw new Exception("Unknown or malformed processing identity must fail without conversion");
        } catch (JsonException) { }
        catch (InvalidDataException) { }
    }
    Console.WriteLine("PASS: processing identity defaults, legacy restore, reset, snapshot equality and rejection");
}
ViewChecks.Run(Check);
ProcessingChecks();
static void ProtectedProcessingChecks(string root)
{
    var directory = Path.Combine(root, "protected-edits");
    Directory.CreateDirectory(directory);
    var input = Path.Combine(directory, "photo.ARW");
    File.WriteAllText(input, "fixture");
    var store = new EditStore(directory);
    var snapshot = new Adjustments().Capture();
    store.Save(input, snapshot, null);
    var path = Path.Combine(directory, "edits.json");
    var registry = JsonNode.Parse(File.ReadAllText(path))!;
    registry["Records"]!.AsObject().First().Value!["Settings"]!["Processing"]!["version"] = 99;
    var protectedBytes = registry.ToJsonString();
    File.WriteAllText(path, protectedBytes);
    try { _ = new EditStore(directory); throw new Exception("Unknown processing must reject the registry"); }
    catch (InvalidDataException) { }
    try { store.Save(input, snapshot, null); throw new Exception("An already-open store cannot replace future records"); }
    catch (InvalidDataException) { }
    Check(File.ReadAllText(path) == protectedBytes, "Unsupported registry remains byte-identical");
    var journal = new BatchJournal(Path.Combine(root, "protected-batch"));
    Directory.CreateDirectory(journal.DirectoryPath);
    var job = BatchJob.Create(input, snapshot, null, "");
    var future = JsonSerializer.SerializeToNode(job)!;
    future["Settings"]!["Processing"]!["version"] = 99;
    var futureBytes = future.ToJsonString();
    var journalPath = Path.Combine(journal.DirectoryPath, "job.json");
    File.WriteAllText(journalPath, futureBytes);
    try { _ = journal.Load(); throw new Exception("Unknown processing cannot resume"); }
    catch (InvalidDataException) { }
    try { journal.Save(job); throw new Exception("New batch cannot replace an unsupported journal"); }
    catch (InvalidDataException) { }
    Check(File.ReadAllText(journalPath) == futureBytes, "Unsupported journal remains byte-identical");
    Console.WriteLine("PASS: unsupported stored processing blocks restore and replacement");
}
var root = Path.Combine(Path.GetTempPath(), "rawlab-edit-" + Guid.NewGuid());
Directory.CreateDirectory(root);
try
{
    ProtectedProcessingChecks(root);
    // Tool scope must own the full logical tool, independently from its containing group.
    Check(Enum.IsDefined(typeof(EditorResetKind), 4), "Current-tool reset is a first-class scope");
    EditorResetScope Tool(EditorAdjustmentTool tool) {
        var scope = new EditorResetScope((EditorResetKind)4);
        typeof(EditorResetScope).GetProperty("Tool")!.SetValue(scope, tool);
        return scope;
    }
    var toolState = new Adjustments { Processing = ProcessingIdentity.Legacy };
    toolState.ResolveWhiteBalance((5200, 8));
    toolState.Set(Parameter.Exposure, .7); toolState.Set(Parameter.Contrast, 23);
    toolState.SetEffect(PhotoEffectParameter.VignetteMidpoint, 12);
    toolState.SetEffect(PhotoEffectParameter.GrainSize, 45);
    toolState.DisplayChromaDenoise = 1;
    toolState.Geometry = new(StraightenDegrees: 4); toolState.Lens = new(true);
    var toolEdit = new SavedEdit(new("tool.ARW", 12, 34, 56), toolState.Capture(), "film.cube");
    var exposureOnly = EditorAdjustmentRules.PrepareReset(Tool(EditorAdjustmentTool.Exposure), toolEdit);
    Check(exposureOnly.Status == EditorResetStatus.Ready && !exposureOnly.RequiresConfirmation &&
        exposureOnly.Candidate!.Settings.Values[(int)Parameter.Exposure] == 0 &&
        exposureOnly.Candidate.Settings.Values[(int)Parameter.Contrast] == 23 &&
        exposureOnly.Candidate.Settings.Processing == ProcessingIdentity.Legacy,
        "Exposure tool reset preserves contrast and processing identity");
    var vignetteOnly = EditorAdjustmentRules.PrepareReset(Tool(EditorAdjustmentTool.Vignette), toolEdit).Candidate!;
    Check(vignetteOnly.Settings.Effects!.VignetteMidpoint == new PhotoEffectsSettings().VignetteMidpoint &&
        vignetteOnly.Settings.Effects.GrainSize == 45, "Vignette reset clears inactive auxiliary fields while retaining grain");
    Check(EditorAdjustmentRules.PrepareReset(Tool(EditorAdjustmentTool.MasterRecipe), toolEdit).Status == EditorResetStatus.NoChange,
        "No recipe means recipe tool reset is NoChange even with a selected film");
    var filmOnly = EditorAdjustmentRules.PrepareReset(Tool(EditorAdjustmentTool.Film), toolEdit).Candidate!;
    Check(filmOnly.Look == null && filmOnly.Settings.SameAs(toolEdit.Settings), "Film reset owns only selection without a recipe");
    var draftContext = new EditorResetContext("lut", 10, new(TransformTool.Geometry, toolState.Geometry, toolState.Lens));
    var geometryOnly = EditorResetTransaction.Prepare(Tool(EditorAdjustmentTool.Geometry), "tool.ARW", 1, 2, toolEdit, draftContext);
    Check(geometryOnly.Status == EditorResetStatus.Ready && !geometryOnly.RequiresConfirmation &&
        geometryOnly.Candidate!.Settings.Geometry!.IsIdentity && geometryOnly.Candidate.Settings.Lens == toolState.Lens,
        "Geometry tool candidate changes only geometry in the active draft");
    Check(EditorResetTransaction.Prepare(Tool(EditorAdjustmentTool.Lens), "tool.ARW", 1, 2, toolEdit, draftContext).Status == EditorResetStatus.Blocked,
        "Lens tool reset cannot target a geometry draft");
    Check(EditorResetTransaction.Prepare(Tool(EditorAdjustmentTool.Geometry), "tool.ARW", 1, 2, toolEdit, new("lut", 10)).Status == EditorResetStatus.Blocked,
        "Geometry tool requires matching draft");
    Check(!geometryOnly.Matches("tool.ARW", 1, 2, toolEdit with { Settings = toolEdit.Settings with { Processing = ProcessingIdentity.Current } }, draftContext),
        "Prepared reset rejects processing identity changes");
    // S1 regression: reset scope ownership, lossless detach, input validation and candidate isolation.
    var resetIdentity = new OriginalIdentity("fixture.ARW", 12, 34, 56);
    SavedEdit Edit(Adjustments state, string? look = "film.cube") => new(resetIdentity, state.Capture(), look);
    EditorResetScope Group(EditorAdjustmentGroup group) => new(EditorResetKind.Group, group);
    Check(EditorAdjustmentRules.Tools(EditorAdjustmentGroup.Light).SequenceEqual(new[] { EditorAdjustmentTool.Exposure,
        EditorAdjustmentTool.Highlights, EditorAdjustmentTool.Shadows, EditorAdjustmentTool.BlackPoint, EditorAdjustmentTool.WhitePoint, EditorAdjustmentTool.Contrast, EditorAdjustmentTool.ToneCurve }),
        "light tool order follows native ownership");
    foreach (var tool in Enum.GetValues<EditorAdjustmentTool>())
        Check(EditorAdjustmentRules.Tools(EditorAdjustmentRules.GroupFor(tool)).Contains(tool), "every native tool belongs to one group");
    var neutral = new Adjustments(); neutral.ResolveWhiteBalance((5200, 8));
    Check(Enum.GetValues<EditorAdjustmentGroup>().Select(EditorAdjustmentRules.Id).SequenceEqual(
        new[] { "looks", "light", "color", "effects", "detail", "geometry" }), "stable group identifiers");
    foreach (var group in Enum.GetValues<EditorAdjustmentGroup>())
        Check(!EditorAdjustmentRules.IsModified(Group(group), Edit(neutral, null)), "neutral group has no changed marker: " + group);
    Check(EditorAdjustmentRules.PrepareReset(new(EditorResetKind.All), Edit(neutral, null)).Status == EditorResetStatus.NoChange,
        "neutral reset has no candidate and cannot produce an edit");
    var mixedState = neutral.Clone(); mixedState.Set(Parameter.Exposure, .75); mixedState.ExposureMode = 0;
    mixedState.Set(Parameter.Saturation, 23); mixedState.Set(Parameter.Sharpening, 42);
    mixedState.Hsl = mixedState.Hsl.WithValue(0, 2, .5).WithValue(1, 6, -33).WithValue(2, 2, 24);
    mixedState.Effects = new(0, 21, 11, 70, 33, 0, 66, 80);
    mixedState.Denoise = new(false, 13, 40, 27); mixedState.DisplayChromaDenoise = 2;
    mixedState.Geometry = new(PerspectiveHorizontal: .2); mixedState.Lens = new(true, true, false, true, "fixture");
    mixedState.ColorGrading = new() { Shadows = new(231.25, 0), Midtones = new(110.125, 32.375) };
    var mixedEdit = Edit(mixedState); var mixedFrozen = mixedEdit.Settings.Copy();
    Check(Enum.GetValues<EditorAdjustmentGroup>().Select(EditorAdjustmentRules.DefaultTool).SequenceEqual(new[] {
        EditorAdjustmentTool.Film,EditorAdjustmentTool.Exposure,EditorAdjustmentTool.WhiteBalance,EditorAdjustmentTool.Vignette,
        EditorAdjustmentTool.Denoise,EditorAdjustmentTool.Geometry }), "Each group opens its frozen default tool");
    foreach(var tool in Enum.GetValues<EditorAdjustmentTool>()) {
        var ownedState=mixedState.Clone();
        if(EditorAdjustmentRules.ToneParameterFor(tool) is {} toneParameter)ownedState.SetTone(toneParameter,25);
        ownedState.Set(Parameter.Strength,37);ownedState.Set(Parameter.Highlights,11);ownedState.Set(Parameter.Shadows,-14);
        ownedState.Set(Parameter.Contrast,23);ownedState.Set(Parameter.ToneCurve,-19);ownedState.Set(Parameter.Temperature,6000);ownedState.Set(Parameter.Tint,12);
        var edit=Edit(ownedState);var frozen=edit.Settings.Copy();var expected=frozen.Copy();var ownedLook=edit.Look;
        switch(tool) {
            case EditorAdjustmentTool.Film: ownedLook=null;break;
            case EditorAdjustmentTool.MasterRecipe:
                Check(EditorAdjustmentRules.PrepareReset(Tool(tool),edit).Status==EditorResetStatus.NoChange,"Recipe reset without identity does not clear film or strength");continue;
            case EditorAdjustmentTool.WhiteBalance:
                expected.Values[2]=5200;expected.Values[3]=8;expected=expected with{CameraWhiteBalance=true};break;
            case EditorAdjustmentTool.ColorGrading:expected=expected with{ColorGrading=null};break;
            case EditorAdjustmentTool.Hsl:expected=expected with{Hsl=new()};break;
            case EditorAdjustmentTool.Vignette:expected=expected with{Effects=new(GrainAmount:0,GrainSize:66,GrainRoughness:80)};break;
            case EditorAdjustmentTool.Grain:expected=expected with{Effects=new(0,21,11,70,33)};break;
            case EditorAdjustmentTool.Denoise:expected=expected with{Denoise=new(),DisplayChromaDenoise=0};break;
            case EditorAdjustmentTool.Geometry:expected=expected with{Geometry=new()};break;
            case EditorAdjustmentTool.Lens:expected=expected with{Lens=new()};break;
            case EditorAdjustmentTool.BlackPoint:expected=expected with{ToneControls=expected.ToneControls! with{BlackPoint=0}};break;
            case EditorAdjustmentTool.WhitePoint:expected=expected with{ToneControls=expected.ToneControls! with{WhitePoint=0}};break;
            case EditorAdjustmentTool.Vibrance:expected=expected with{ToneControls=expected.ToneControls! with{Vibrance=0}};break;
            default:
                var parameter=EditorAdjustmentRules.ParameterFor(tool);expected.Values[(int)parameter]=parameter==Parameter.Strength ? 100 : 0;
                if(tool==EditorAdjustmentTool.Exposure)expected=expected with{ExposureMode=1};break;
        }
        var prepared=EditorAdjustmentRules.PrepareReset(Tool(tool),edit);
        Check(prepared.Status==EditorResetStatus.Ready && prepared.Candidate!.Look==ownedLook && prepared.Candidate.Settings.SameAs(expected),
            "Current tool owns only its complete field set: "+tool);
        Check(prepared.RequiresConfirmation==(tool is EditorAdjustmentTool.Hsl or EditorAdjustmentTool.ColorGrading),"Whole color tools require ordinary confirmation: "+tool);
        Check(edit.Settings.SameAs(frozen),"Preparing/cancelling tool reset never mutates source: "+tool);
        Check(EditorAdjustmentRules.PrepareReset(Tool(tool),prepared.Candidate!).Status==EditorResetStatus.NoChange,"Repeated tool reset is NoChange: "+tool);
    }
    var resetContext=new EditorResetContext("resolved-film.cube", 10);
    var resetToken=EditorResetTransaction.Prepare(Group(EditorAdjustmentGroup.Light), resetIdentity.Path, 2, 3, mixedEdit, resetContext);
    var exposedCandidate=resetToken.Candidate!;
    exposedCandidate.Settings.Values[(int)Parameter.Exposure]=2;
    Check(resetToken.Candidate!.Settings.Values[(int)Parameter.Exposure]==0,
        "prepared candidate cannot be changed through an exposed Values array");
    var originalValue=mixedEdit.Settings.Values[(int)Parameter.Exposure];
    mixedEdit.Settings.Values[(int)Parameter.Exposure]=1.5;
    Check(resetToken.Matches(resetIdentity.Path,2,3,mixedEdit with{Settings=mixedFrozen},resetContext) &&
        !resetToken.Matches(resetIdentity.Path,2,3,mixedEdit,resetContext),"prepared source Values are isolated and same-revision edits are stale");
    mixedEdit.Settings.Values[(int)Parameter.Exposure]=originalValue;
    foreach(var stale in new[] {
        (File:"different.ARW", Open:2L, Edit:3L, State:mixedEdit, Context:resetContext),
        (File:resetIdentity.Path, Open:4L, Edit:3L, State:mixedEdit, Context:resetContext),
        (File:resetIdentity.Path, Open:2L, Edit:4L, State:mixedEdit, Context:resetContext),
        (File:resetIdentity.Path, Open:2L, Edit:3L, State:mixedEdit with{Identity=resetIdentity with{Modified=99}}, Context:resetContext),
        (File:resetIdentity.Path, Open:2L, Edit:3L, State:mixedEdit with{Look="another-film"}, Context:resetContext),
        (File:resetIdentity.Path, Open:2L, Edit:3L, State:mixedEdit with{Settings=mixedFrozen with{AsShotTint=9}}, Context:resetContext),
        (File:resetIdentity.Path, Open:2L, Edit:3L, State:mixedEdit, Context:resetContext with{Lut="different-resolved-path"}),
        (File:resetIdentity.Path, Open:2L, Edit:3L, State:mixedEdit, Context:resetContext with{TransformGeneration=11})
    }) {
        var invoked=false;
        Check(!resetToken.TryCommit(stale.File,stale.Open,stale.Edit,stale.State,stale.Context,_=>invoked=true) && !invoked,
            "stale prepared reset makes no commit request: "+stale);
    }
    var resetCommits=0;SavedEdit? acceptedReset=null;
    Check(resetToken.TryCommit(resetIdentity.Path,2,3,mixedEdit,resetContext,value=>{++resetCommits;acceptedReset=value;}) &&
        resetCommits==1 && acceptedReset!.Settings.Values[(int)Parameter.Exposure]==0 && acceptedReset.Look=="film.cube",
        "accepted ordinary reset commits exactly once and preserves non-look identity");
    Check(!resetToken.TryCommit(resetIdentity.Path,2,3,mixedEdit,resetContext,_=>++resetCommits) && resetCommits==1,
        "a prepared token cannot be consumed twice");
    var noChangeToken=EditorResetTransaction.Prepare(Group(EditorAdjustmentGroup.Light),resetIdentity.Path,2,3,Edit(neutral,null),resetContext);
    Check(noChangeToken.Status==EditorResetStatus.NoChange && !noChangeToken.TryCommit(resetIdentity.Path,2,3,Edit(neutral,null),resetContext,_=>++resetCommits) && resetCommits==1,
        "unchanged reset makes no commit request");
    var pairDraft=new TransformDraft();pairDraft.Begin(mixedState.Geometry,mixedState.Lens,TransformTool.Lens);
    var pairContext=resetContext with{Draft=new(TransformTool.Lens,pairDraft.Geometry,pairDraft.Lens)};
    var pairToken=EditorResetTransaction.Prepare(Group(EditorAdjustmentGroup.Geometry),resetIdentity.Path,2,3,mixedEdit,pairContext);
    Check(pairToken.TargetsDraft && pairToken.TryCommit(resetIdentity.Path,2,3,mixedEdit,pairContext,value=>pairDraft.Update(value.Settings.Geometry!,value.Settings.Lens!)) &&
        pairDraft.Geometry.IsIdentity && pairDraft.Lens==new LensSettings() && mixedEdit.Settings.SameAs(mixedFrozen),
        "geometry group resets the complete draft pair without changing committed settings");
    var draftBlocked=EditorResetTransaction.Prepare(new(EditorResetKind.All),resetIdentity.Path,2,3,mixedEdit,pairContext);
    Check(draftBlocked.Status==EditorResetStatus.Blocked && !draftBlocked.TryCommit(resetIdentity.Path,2,3,mixedEdit,pairContext,_=>++resetCommits) && resetCommits==1,
        "all reset waits for the active draft and creates no edit");
    var changedDraftContext=pairContext with{Draft=pairContext.Draft! with{Geometry=new GeometrySettings(CropWidth:.8)}};
    var stalePair=EditorResetTransaction.Prepare(Group(EditorAdjustmentGroup.Geometry),resetIdentity.Path,2,3,mixedEdit,pairContext);
    Check(!stalePair.TryCommit(resetIdentity.Path,2,3,mixedEdit,changedDraftContext,_=>++resetCommits) && resetCommits==1,
        "draft pair changes invalidate preparation even without a generation bump");
    pairDraft.Cancel();Check(pairDraft.Geometry==mixedState.Geometry && pairDraft.Lens==mixedState.Lens,"cancel restores both original draft objects");
    foreach (var group in Enum.GetValues<EditorAdjustmentGroup>()) {
        Check(EditorAdjustmentRules.IsModified(Group(group), mixedEdit), "complete stored objects contribute to marker: " + group);
        var prepared = EditorAdjustmentRules.PrepareReset(Group(group), mixedEdit);
        Check(prepared.Status == EditorResetStatus.Ready && prepared.RequiresConfirmation && prepared.Candidate!.Identity == resetIdentity,
            "group candidate retains identity and requests confirmation: " + group);
        var candidate = prepared.Candidate!;
        var expected = mixedFrozen.Copy();
        if (group == EditorAdjustmentGroup.Light) {
            foreach (var index in new[] { 1, 4, 5, 6, 7 }) expected.Values[index] = 0;
            expected = expected with { ExposureMode = 1 };
        }
        if (group == EditorAdjustmentGroup.Color) {
            expected.Values[2] = 5200; expected.Values[3] = 8; expected.Values[8] = 0;
            expected = expected with { CameraWhiteBalance = true, Hsl = new(), ColorGrading = null };
        }
        if (group == EditorAdjustmentGroup.Effects) expected = expected with { Effects = new() };
        if (group == EditorAdjustmentGroup.Detail) { expected.Values[9] = 0; expected = expected with { Denoise = new(), DisplayChromaDenoise = 0 }; }
        if (group == EditorAdjustmentGroup.Geometry) expected = expected with { Geometry = new(), Lens = new() };
        Check(candidate.Settings.SameAs(expected), "group reset preserves every unowned stored field: " + group);
        foreach (var other in Enum.GetValues<EditorAdjustmentGroup>().Where(other => other != group))
            Check(EditorAdjustmentRules.IsModified(Group(other), candidate) == EditorAdjustmentRules.IsModified(Group(other), mixedEdit),
                "unselected group marker survives reset: " + group + " / " + other);
        Check(!EditorAdjustmentRules.IsModified(Group(group), candidate), "selected group restores complete defaults: " + group);
        Check(candidate.Look == (group == EditorAdjustmentGroup.Looks ? null : "film.cube"), "look ownership is preserved");
        candidate.Settings.Values[1] = -3;
        Check(mixedEdit.Settings.SameAs(mixedFrozen), "candidate Values array cannot mutate original");
    }
    var channelReset = EditorAdjustmentRules.PrepareReset(new(EditorResetKind.HslChannel, Channel: 2), mixedEdit);
    Check(channelReset.Status == EditorResetStatus.Ready && !channelReset.RequiresConfirmation &&
        channelReset.Candidate!.Settings.Hsl!.Value(0, 2) == 0 && channelReset.Candidate.Settings.Hsl.Value(2, 2) == 0 &&
        channelReset.Candidate.Settings.Hsl.Value(1, 6) == -33 && channelReset.Candidate.Settings.Values[8] == 23,
        "current HSL channel clears only its three axes");
    var allHsl = EditorAdjustmentRules.PrepareReset(new(EditorResetKind.AllHsl), mixedEdit);
    Check(allHsl.Status == EditorResetStatus.Ready && allHsl.RequiresConfirmation && allHsl.Candidate!.Settings.Hsl!.IsIdentity &&
        allHsl.Candidate.Settings.Values.SequenceEqual(mixedEdit.Settings.Values), "all HSL preserves other color controls");
    var allReset = EditorAdjustmentRules.PrepareReset(new(EditorResetKind.All), mixedEdit).Candidate!;
    Check(allReset.Look == null && allReset.Settings.SameAs(neutral.Capture()), "all reset includes look and full effective defaults");
    var oldSnapshot = new AdjustmentSnapshot((double[])neutral.Capture().Values.Clone(), 0, true, 5200, 8);
    var oldReset = EditorAdjustmentRules.PrepareReset(Group(EditorAdjustmentGroup.Effects), new(resetIdentity, oldSnapshot, null));
    Check(oldReset.Status == EditorResetStatus.NoChange && oldSnapshot.Restore().ExposureMode == 0,
        "missing optional fields retain existing defaults and historical exposure mode");
    foreach (var invalid in new[] {
        mixedFrozen with { Effects = new(0, double.NaN) }, mixedFrozen with { Denoise = new(false, -1) },
        mixedFrozen with { Geometry = new(CropWidth: 0) }, mixedFrozen with { AsShotTint = double.NaN },
        mixedFrozen with { AsShotTemperature = null }, mixedFrozen with { DisplayChromaDenoise = 3 }
    }) Check(EditorAdjustmentRules.PrepareReset(new(EditorResetKind.All), new(resetIdentity, invalid, "film")).Status == EditorResetStatus.Invalid,
        "all reset validates invalid dormant fields before replacing them");
    Check(EditorAdjustmentRules.PrepareReset(new(EditorResetKind.HslChannel, Channel: 8), mixedEdit).Status == EditorResetStatus.Invalid,
        "invalid HSL scope is rejected");
    var unknown = mixedFrozen with { MasterRecipeID = "unknown" };
    Check(EditorAdjustmentRules.PrepareReset(Group(EditorAdjustmentGroup.Looks), new(resetIdentity, unknown, "film")).Status == EditorResetStatus.Blocked,
        "unknown recipe cannot silently become ordinary adjustments");
    foreach (var strength in new[] { 0.0, 50, 100, 200 }) {
        var recipeState = neutral.Clone(); recipeState.ApplyMasterRecipe(MasterRecipe.All[0]);
        recipeState.Set(Parameter.Strength, strength); recipeState.Set(Parameter.Exposure, .75);
        recipeState.Set(Parameter.Contrast, 17.3); recipeState.Set(Parameter.Highlights, 13.7);
        recipeState.Set(Parameter.Shadows, -21.1); recipeState.Set(Parameter.Saturation, 22.9);
        recipeState.Set(Parameter.Tint, 10); recipeState.Hsl = new HslSettings().WithValue(0, 0, .5).WithValue(1, 7, -80);
        var recipeEdit = Edit(recipeState); var recipeFrozen = recipeEdit.Settings.Copy();
        var detached = EditorAdjustmentRules.PrepareReset(Group(EditorAdjustmentGroup.Looks), recipeEdit);
        Check(detached.Status == EditorResetStatus.Ready, "representable recipe detaches at strength " + strength + ": " + detached.Reason);
        foreach(var tool in new[]{EditorAdjustmentTool.Film,EditorAdjustmentTool.MasterRecipe}) {
            var toolDetached=EditorAdjustmentRules.PrepareReset(Tool(tool),recipeEdit);
            Check(toolDetached.Status==detached.Status && toolDetached.Candidate!.Settings.SameAs(detached.Candidate!.Settings) && toolDetached.Candidate.Look==null && toolDetached.RequiresConfirmation,
                "Film/recipe current-tool reset uses the same lossless materialization and confirmation: "+tool+"/"+strength);
            Check(toolDetached.MaterializedFields!.Count>0,"Recipe confirmation carries actual converted fields: "+tool+"/"+strength);
        }
        var detachedState = detached.Candidate!.Settings.Restore();
        Check(detached.Candidate.Look == null && detachedState.MasterRecipeID == null && detachedState[Parameter.Strength] == 100,
            "look and recipe identities are both cleared");
        var before = recipeState.Request("fixture.ARW", null, 64, null); var after = detachedState.Request("fixture.ARW", null, 64, null);
        Check(before.ExposureEv == after.ExposureEv && before.Contrast == after.Contrast && before.Highlights == after.Highlights &&
            before.Shadows == after.Shadows && before.Saturation == after.Saturation && before.WbMode == after.WbMode &&
            before.Temperature == after.Temperature && before.Tint == after.Tint &&
            recipeState.RenderHsl.Values.Select(v => (float)v).SequenceEqual(detachedState.RenderHsl.Values.Select(v => (float)v)),
            "detach preserves exact final core Float fields and HSL for strength " + strength);
        if (strength == 0) Check(detachedState[Parameter.Tint] == 8 && detachedState.CameraWhiteBalance,
            "zero recipe offset becomes stored absolute as-shot tint when identity is cleared");
        Check(detachedState.Hsl.Value(1, 7) == (strength == 200 ? -100 : -80 * strength / 100), "detach retains existing HSL clamp");
        Check(recipeEdit.Settings.SameAs(recipeFrozen), "preparing and discarding a recipe candidate is cancellation without mutation");
        var colorReset = EditorAdjustmentRules.PrepareReset(Group(EditorAdjustmentGroup.Color), recipeEdit).Candidate!.Settings.Restore();
        Check(colorReset.MasterRecipeID == recipeState.MasterRecipeID && colorReset[Parameter.Tint] == 0 &&
            colorReset[Parameter.Exposure] == .75 && colorReset.Hsl.IsIdentity, "color reset clears recipe offsets without replaying recipe");
        var json = System.Text.Json.JsonSerializer.Serialize(detached.Candidate);
        var roundtrip = System.Text.Json.JsonSerializer.Deserialize<SavedEdit>(json)!;
        Check(roundtrip.Identity == resetIdentity && roundtrip.Look == null && roundtrip.Settings.SameAs(detached.Candidate.Settings),
            "candidate JSON retains SavedEdit identity and existing schema");
    }
    var unsafeRecipe = new Adjustments(); unsafeRecipe.ApplyMasterRecipe(MasterRecipe.All[0]); unsafeRecipe.Set(Parameter.Tint, 10);
    Check(EditorAdjustmentRules.PrepareReset(Group(EditorAdjustmentGroup.Looks), Edit(unsafeRecipe)).Status == EditorResetStatus.Blocked,
        "RAW relative tint cannot invent as-shot calibration");
    Check(EditorAdjustmentRules.PrepareReset(Tool(EditorAdjustmentTool.MasterRecipe),Edit(unsafeRecipe)).Status==EditorResetStatus.Blocked,
        "Current recipe cannot bypass missing-WB blocked result");
    unsafeRecipe.Set(Parameter.Tint, 0); unsafeRecipe.Set(Parameter.Temperature, 7000);
    Check(EditorAdjustmentRules.PrepareReset(Group(EditorAdjustmentGroup.Looks), Edit(unsafeRecipe)).Status == EditorResetStatus.Blocked,
        "RAW custom recipe WB also needs real calibration");
    unsafeRecipe.Set(Parameter.Exposure, 4); unsafeRecipe.Set(Parameter.Strength, 200);
    unsafeRecipe.ResolveWhiteBalance((5200, 8));
    Check(EditorAdjustmentRules.PrepareReset(Group(EditorAdjustmentGroup.Looks), Edit(unsafeRecipe)).Status == EditorResetStatus.Blocked,
        "out of range materialized exposure is blocked without clamping");
    unsafeRecipe.Set(Parameter.Strength, 0);
    Check(EditorAdjustmentRules.IsModified(Group(EditorAdjustmentGroup.Light), Edit(unsafeRecipe)), "zero recipe strength retains stored light marker");
    var calibrationFree = new Adjustments(); calibrationFree.ApplyMasterRecipe(MasterRecipe.All[0]);
    calibrationFree.Set(Parameter.Tint, 0);
    Check(EditorAdjustmentRules.PrepareReset(Group(EditorAdjustmentGroup.Looks), Edit(calibrationFree)).Status == EditorResetStatus.Ready,
        "as-shot recipe without relative tint does not require calibration");
    Check(EditorAdjustmentRules.PrepareReset(Group(EditorAdjustmentGroup.Effects), Edit(unsafeRecipe)).Status == EditorResetStatus.NoChange,
        "unrelated scope does not require recipe calibration");
    var clippedTint = neutral.Clone(); clippedTint.ApplyMasterRecipe(MasterRecipe.All[0]);
    clippedTint.Set(Parameter.Tint, 150); clippedTint.Set(Parameter.Strength, 200);
    var clippedDetach = EditorAdjustmentRules.PrepareReset(Group(EditorAdjustmentGroup.Looks), Edit(clippedTint));
    Check(clippedDetach.Status == EditorResetStatus.Ready && clippedDetach.Candidate!.Settings.Values[3] == 150,
        "materialization retains original renderer tint clamp");
    clippedTint.Set(Parameter.Contrast, 100);
    Check(EditorAdjustmentRules.PrepareReset(Group(EditorAdjustmentGroup.Looks), Edit(clippedTint)).Status == EditorResetStatus.Blocked,
        "materialized contrast outside native range is blocked");
    var rasterState = mixedState.Clone(); rasterState.ApplyMasterRecipe(MasterRecipe.All[0]); rasterState.Set(Parameter.Strength, 50);
    var rasterEdit = new SavedEdit(resetIdentity with { Path = "fixture.jpg" }, rasterState.Capture(), "film");
    var rasterDetached = EditorAdjustmentRules.PrepareReset(Group(EditorAdjustmentGroup.Looks), rasterEdit);
    Check(rasterDetached.Status == EditorResetStatus.Ready && rasterDetached.Candidate!.Settings.CameraWhiteBalance &&
        rasterDetached.Candidate.Settings.Values[2] == 6500 && rasterDetached.Candidate.Settings.Values[3] == 0,
        "raster detach follows input preparation and fixed display WB without camera calibration");
    var rasterDefault = EditorAdjustmentRules.PrepareReset(new(EditorResetKind.All), rasterEdit).Candidate!.Settings.Restore();
    Check(rasterDefault.ExposureMode == 2 && rasterDefault.Lens == new LensSettings(false, false, false) && rasterDefault.AsShot == null,
        "raster reset uses sensor exposure and unavailable camera-only defaults");
    var rasterNeutralSnapshot = PhotoInput.PrepareInputSettings("fixture.jpg", new Adjustments()).Capture();
    var rasterMetadataOnly = rasterNeutralSnapshot.Copy() with {
        ExposureMode = 0, CameraWhiteBalance = false, AsShotTemperature = 5200, AsShotTint = 8
    };
    rasterMetadataOnly.Values[2] = 7300; rasterMetadataOnly.Values[3] = 17;
    var rasterMetadataEdit = new SavedEdit(resetIdentity with { Path = "fixture.jpg" }, rasterMetadataOnly, null);
    var rasterMetadataFrozen = rasterMetadataOnly.Copy();
    foreach (var scope in new[] { Group(EditorAdjustmentGroup.Light), Group(EditorAdjustmentGroup.Color), new EditorResetScope(EditorResetKind.All) }) {
        Check(!EditorAdjustmentRules.IsModified(scope, rasterMetadataEdit), "raster RAW-only metadata does not create a marker: " + scope.Kind + "/" + scope.Group);
        Check(EditorAdjustmentRules.PrepareReset(scope, rasterMetadataEdit).Status == EditorResetStatus.NoChange,
            "raster RAW-only metadata does not create a reset candidate: " + scope.Kind + "/" + scope.Group);
    }
    Check(rasterMetadataOnly.SameAs(rasterMetadataFrozen), "raster marker comparison preserves original metadata and Values array");
    var rasterLightChanged = rasterMetadataOnly.Copy(); rasterLightChanged.Values[1] = .5;
    var rasterLightReset = EditorAdjustmentRules.PrepareReset(Group(EditorAdjustmentGroup.Light), rasterMetadataEdit with { Settings = rasterLightChanged });
    Check(rasterLightReset.Status == EditorResetStatus.Ready && rasterLightReset.Candidate!.Settings.ExposureMode == 2 &&
        rasterLightReset.Candidate.Settings.Values[1] == 0 && rasterLightReset.Candidate.Settings.Values[2] == 7300,
        "real raster light reset restores owned exposure defaults and preserves stored WB");
    var rasterColorChanged = rasterMetadataOnly.Copy(); rasterColorChanged.Values[8] = 20;
    var rasterColorReset = EditorAdjustmentRules.PrepareReset(Group(EditorAdjustmentGroup.Color), rasterMetadataEdit with { Settings = rasterColorChanged });
    Check(rasterColorReset.Status == EditorResetStatus.Ready && rasterColorReset.Candidate!.Settings.CameraWhiteBalance &&
        rasterColorReset.Candidate.Settings.Values[2] == 6500 && rasterColorReset.Candidate.Settings.Values[3] == 0 &&
        rasterColorReset.Candidate.Settings.AsShotTemperature == null && rasterColorReset.Candidate.Settings.AsShotTint == null &&
        rasterColorReset.Candidate.Settings.ExposureMode == 0, "real raster color reset restores complete owned WB defaults only");
    var rasterRecipeTint = rasterMetadataOnly.Copy() with { MasterRecipeID = MasterRecipe.All[0].Id };
    rasterRecipeTint.Values[0] = 0; rasterRecipeTint.Values[3] = 0;
    Check(!EditorAdjustmentRules.IsModified(Group(EditorAdjustmentGroup.Color), rasterMetadataEdit with { Settings = rasterRecipeTint }),
        "raster recipe color defaults compare tint with relative zero");
    rasterRecipeTint.Values[3] = 17;
    var rasterRecipeTintEdit = rasterMetadataEdit with { Settings = rasterRecipeTint };
    Check(EditorAdjustmentRules.IsModified(Group(EditorAdjustmentGroup.Color), rasterRecipeTintEdit),
        "raster recipe relative tint remains marked at zero strength");
    var rasterRecipeTintReset = EditorAdjustmentRules.PrepareReset(Group(EditorAdjustmentGroup.Color), rasterRecipeTintEdit);
    Check(rasterRecipeTintReset.Status == EditorResetStatus.Ready && rasterRecipeTintReset.Candidate!.Settings.Values[3] == 0 &&
        rasterRecipeTintReset.Candidate.Settings.MasterRecipeID == rasterRecipeTint.MasterRecipeID,
        "raster color reset clears stored recipe tint without losing recipe identity");
    foreach (var dormant in new[] {
        (EditorAdjustmentGroup.Effects, rasterMetadataOnly.Copy() with { Effects = new(0, 21) }),
        (EditorAdjustmentGroup.Detail, rasterMetadataOnly.Copy() with { Denoise = new(false, 13) }),
        (EditorAdjustmentGroup.Geometry, rasterMetadataOnly.Copy() with { Lens = new(false, false, true) })
    }) {
        var dormantEdit = rasterMetadataEdit with { Settings = dormant.Item2 };
        Check(EditorAdjustmentRules.IsModified(Group(dormant.Item1), dormantEdit) &&
            EditorAdjustmentRules.IsModified(new(EditorResetKind.All), dormantEdit), "raster dormant complete object remains marked: " + dormant.Item1);
        Check(EditorAdjustmentRules.PrepareReset(Group(dormant.Item1), dormantEdit).Status == EditorResetStatus.Ready,
            "raster dormant complete object remains resettable: " + dormant.Item1);
    }
    var exposureSpec = ParameterSpec.All[(int)Parameter.Exposure];
    Check(exposureSpec.Value(exposureSpec.Position(.13)) == .13, "v08 exposure slider uses 0.01 fine grid");
    Check(Math.Abs(ParameterSpec.All[(int)Parameter.Tint].Value(ParameterSpec.All[(int)Parameter.Tint].Position(.3)) - .3) < 1e-10,
        "v08 tint slider retains tenths");
    var wheel = new ParameterWheel();
    Check(wheel.Feed(40,0,false,0,true) == (true,0) && wheel.Feed(40,0,false,1,true) == (true,1), "wheel threshold accumulates to 80 pixels");
    Check(wheel.Feed(800,0,false,126,true) == (true,1) && wheel.Feed(800,0,false,130,true) == (true,0), "wheel limits each event and 125 ms interval");
    Check(wheel.Feed(-40,0,false,260,true) == (true,0) && wheel.Feed(40,0,false,261,true) == (true,0), "reversing clears wheel remainder");
    Check(wheel.Feed(40,0,true,262,true) == (true,0) && wheel.Feed(40,0,true,263,true) == (true,1), "Shift resets remainder without changing direction");
    Check(wheel.Feed(40,0,true,500,true) == (true,0) && wheel.Feed(40,0,true,701,true) == (true,0), "200ms idle clears remainder");
    Check(wheel.Feed(120,0,false,900,false) == (false,0) && wheel.Feed(0,100,false,901,true) == (false,0) &&
          wheel.Feed(double.NaN,0,false,902,true) == (false,0), "disabled, horizontal and invalid events bubble");
    var temperatureRange = NumericRange.For(ParameterSpec.All[(int)Parameter.Temperature]);
    Check(temperatureRange.Position(50000) == 1 && temperatureRange.Position(2000) == 0 &&
          temperatureRange.Value(temperatureRange.Position(5200)) == 5200, "inverse temperature warms to the right and roundtrips");
    Check(new NumericRange(-100,100).Parse("999") == null && new NumericRange(-100,100).Parse("NaN") == null,
        "numeric UI commit rejects out-of-range and nonfinite input without clamping");
    var strictRange=new NumericRange(-100,100);
    Check(strictRange.Parse("0.05")==null && strictRange.Parse("0.05",.05)==.05 && strictRange.Parse("0.050",.05)==.05,
        "Only the exact original off-grid value survives manual confirmation or formatting changes");
    Check(strictRange.Parse("100")==100 && strictRange.Parse("-100")==-100 && strictRange.Parse("")==null && strictRange.Parse("Infinity")==null,
        "Strict UI parser accepts exact boundaries and rejects empty or infinite values");
    Check(new NumericRange(-4,4,.01,FixedDecimals:2).Format(.005)=="0.01", "Old off-grid exposure displays at most two decimals");
    Check(new NumericRange(-4,4,.01,FixedDecimals:2).Parse("0.01",.005)==.005, "Confirming rounded text preserves the exact stored value");
    Check(new NumericRange(0,1,.001,AllowOffGrid:true).Format(.25123456789)=="0.25", "Curve coordinates display at most two decimals");
    var inputSession=new NumericInputSession();
    var cropRange=new NumericRange(0,100,.01,.1,.01,CompactPercent:true);
    var cropInput=new NumericInputSession();var cropOriginal=33.33333333333333;
    cropInput.Bind("crop-source","width",cropRange,cropOriginal);
    Check(cropInput.Text=="33.33" && cropInput.Commit()==null && cropInput.Original==cropOriginal,
        "Crop display has two decimals without changing its original on unchanged confirmation");
    cropInput.Edit("33.33");
    Check(cropInput.Commit()==null && cropInput.Original==cropOriginal,
        "Retyping the visible crop value preserves the full-precision original");
    cropInput.Edit("33.34");Check(cropInput.Commit()==33.34,"Crop accepts an explicit hundredth-percent edit");
    cropInput.Edit("33.345");Check(cropInput.Commit()==null && cropInput.Error==NumericInputError.Grid && cropInput.Text=="33.345",
        "Crop rejects excess decimals and retains the invalid draft");
    cropInput.Edit("101");Check(cropInput.Commit()==null && cropInput.Error==NumericInputError.Range,"Crop rejects out-of-range input");
    Loc.Initialize("de");Check(cropRange.Format(cropOriginal)=="33,33" && cropRange.Parse("33,33",cropOriginal)==cropOriginal,
        "Crop rounded display and unchanged input share the current numeric locale");Loc.Initialize("en");
    inputSession.Bind("source-a","exposure",strictRange,.05);inputSession.Edit("12.3");
    inputSession.Bind("source-b","exposure",strictRange,.05);
    Check(!inputSession.Dirty && inputSession.Text=="0.05" && inputSession.Commit()==null,
        "Source replacement invalidates pending text even when tool and original value are equal");
    inputSession.Edit("12.3");Check(inputSession.Commit()==12.3 && !inputSession.Dirty,"A valid changed blur/Enter returns exactly one commit");
    inputSession.Edit("999");Check(inputSession.Commit()==null && inputSession.Dirty && inputSession.Error==NumericInputError.Range && inputSession.Text=="999",
        "Invalid text and its error survive commit without producing a candidate");
    inputSession.Cancel();Check(!inputSession.Dirty && inputSession.Error==NumericInputError.None,"Escape/navigation cancel clears only the local draft");
    inputSession.Bind("source-b","hsl-blue",strictRange,.05);inputSession.Edit("0.050");
    Check(inputSession.Commit()==null && inputSession.Original==.05,"Unchanged old value does not return a setter candidate");
    Check(new NumericRange(2000,50000,10,Reciprocal:true).Fill(5200,8000) is var fill && fill.Start>0 && fill.End>fill.Start,
        "Warm-temperature fill starts at the real as-shot default on reciprocal coordinates");
    Check(new NumericRange(-4,4).Fill(0,-2)==(.25,.5),"Negative fill joins current to default rather than beginning at the minimum");
    Loc.Initialize("de");Check(new NumericRange(-100,100).Parse("1,2") is {} localized && Math.Abs(localized-1.2)<1e-10 && new NumericRange(-100,100).Format(1.2)=="1,2","German numeric display and commit share one locale");Loc.Initialize("en");
    var fineEffects=new Adjustments();fineEffects.SetEffect(PhotoEffectParameter.GrainAmount,12.3);
    Check(Math.Abs(fineEffects.Effects.GrainAmount-12.3)<1e-10,"effect model preserves the v08 tenth-unit grid");
    Check(typeof(Adjustments).GetProperty("MasterRecipeID") != null, "master recipes must be part of persisted adjustments");
    Check(MasterRecipe.All.Count == 14, "all fourteen shared recipes load");
    foreach (var recipe in MasterRecipe.All) {
        var preset = new Adjustments(); preset.ResolveWhiteBalance((5000, 8));
        preset.Set(Parameter.Temperature, 8000); preset.Set(Parameter.Sharpening, 75);
        preset.Hsl = preset.Hsl.WithValue(0, 7, 90); preset.ApplyMasterRecipe(recipe);
        Check(preset.Hsl.Equals(recipe.Hsl.Settings()) && preset[Parameter.Exposure] == recipe.ExposureDelta &&
              preset[Parameter.Highlights] == recipe.HighlightsDelta && preset[Parameter.Tint] == recipe.TintDelta,
              recipe.Id + " overwrites visible settings and HSL");
        Check(preset[Parameter.Temperature] == 8000 && preset[Parameter.Sharpening] == 75, "unrelated settings survive");
        preset.Hsl = preset.Hsl.WithValue(0, 7, 37).WithValue(1, 5, -80);
        var originalHsl = preset.Hsl;
        foreach (var strength in new[] { 0.0, .5, 1, 2 }) {
            preset.Set(Parameter.Strength, strength * 100);
            var request = preset.Request("fixture.ARW", "look.cube", 64, null);
            Check(Math.Abs(request.ExposureEv - recipe.ExposureDelta * strength) < 1e-5 &&
                  Math.Abs(request.Highlights + recipe.HighlightsDelta * strength / 100) < 1e-5 &&
                  Math.Abs(request.Contrast - (1 + recipe.ContrastDelta * strength / 100)) < 1e-5,
                  "recipe strength scales current controls");
            Check(preset.RenderHsl.Value(0, 7) == 37 * strength &&
                  preset.RenderHsl.Value(1, 5) == Math.Max(-100, -80 * strength) && preset.Hsl.Equals(originalHsl),
                  "HSL scaling preserves fractions and limits without changing visible values");
            var restoredRecipe = System.Text.Json.JsonSerializer.Deserialize<AdjustmentSnapshot>(
                System.Text.Json.JsonSerializer.Serialize(preset.Capture()))!.Restore();
            Check(restoredRecipe.MasterRecipeID == recipe.Id && restoredRecipe.RenderHsl.Equals(preset.RenderHsl), "recipe snapshot roundtrip");
        }
        preset.ClearMasterRecipe();
        Check(preset.MasterRecipeID == null && preset.RenderHsl.Equals(originalHsl), "ordinary HSL remains independent of strength");
    }
    var identityGeometry = new GeometrySettings();
    Check(typeof(GeometrySettings).GetProperty("PerspectiveHorizontal")!=null,
        "v08 geometry persists perspective without extending the existing geometry ABI");
    var perspective=new GeometrySettings(PerspectiveHorizontal:.23,PerspectiveVertical:-.4);
    Check(System.Runtime.InteropServices.Marshal.SizeOf<Native.PerspectiveConfig>()==16 &&
          System.Runtime.InteropServices.Marshal.OffsetOf<Native.PerspectiveConfig>(nameof(Native.PerspectiveConfig.Horizontal)).ToInt32()==8 &&
          perspective.NativePerspectiveConfig() is{Version:1,StructSize:16,Horizontal:.23f,Vertical:-.4f},"additive perspective v1 ABI is 16 bytes");
    var transform=new TransformDraft();var committed=new Adjustments{Geometry=perspective};
    var committedSnapshot=committed.Capture();
    transform.Begin(committed.Geometry,committed.Lens,TransformTool.Geometry);
    var unchangedRejected=false;
    try { transform.Apply(); } catch (InvalidOperationException) { unchangedRejected=true; }
    Check(unchangedRejected && transform.Active && !transform.Dirty,
        "unchanged draft cannot be promoted or create a save request");
    transform.Update(perspective with{CropX=.1,CropWidth=.8,StraightenDegrees=12});
    Check(transform.Dirty && committed.Capture().SameAs(committedSnapshot) && transform.PreviewGeometry.CropWidth==1,
        "geometry draft previews full transformed canvas without changing committed/batch snapshot");
    transform.Cancel();Check(!transform.Active && committed.Capture().SameAs(committedSnapshot),"cancel discards draft only");
    transform.Begin(committed.Geometry,committed.Lens,TransformTool.Lens);transform.Update(new LensSettings(true,true));
    Check(committed.Lens==new LensSettings() && transform.Dirty,"lens correction has an independent unsaved draft");
    var applied=transform.Apply();Check(applied.Lens.Enabled && !transform.Active,"apply returns draft to committed owner");
    var selection=new CropRect(.2,.2,.6,.6);
    foreach(var handle in Enum.GetValues<CropHandle>())foreach(var ratio in new double?[]{null,1,3.0/2,16.0/9})
    {
        var moved=CropInteraction.Dragging(selection,handle,-2,3,6000,4000,ratio);
        Check(moved.X>=-1e-12 && moved.Y>=-1e-12 && moved.Right<=1+1e-12 && moved.Bottom<=1+1e-12 && moved.Width>0 && moved.Height>0,
            "eight crop handles and moving stay inside the canvas: "+handle);
        if(ratio.HasValue && handle!=CropHandle.Move)Check(Math.Abs(moved.Width*6000/(moved.Height*4000)-ratio.Value)<1e-8,"locked ratio survives boundary drag");
    }
    var freeTop=CropInteraction.Dragging(selection,CropHandle.Top,0,.1,6000,4000,null);
    Check(freeTop.Width==selection.Width && Math.Abs(freeTop.Y-.3)<1e-10,"free edge changes only its own axis");
    var rotated=(perspective with{CropX=.1,CropY=.2,CropWidth=.3,CropHeight=.4}).Rotate(1);
    Check(Math.Abs(rotated.CropX-.4)<1e-10 && rotated.CropY==.1 && rotated.CropWidth==.4 && rotated.CropHeight==.3,
        "quarter turn transforms crop coordinates instead of stretching selection");
    foreach(var extent in new[]{.1,.2,.3,.01})foreach(var turns in new[]{-1,1,2,3,4})
    {
        var edge=CropInteraction.Dragging(new(0,0,extent,extent),CropHandle.Move,2,2,6000,4000,null);
        var turned=CropInteraction.Applying(edge,new()).Rotate(turns);
        _=turned.NativeConfig();
        Check(turned.CropX>=0 && turned.CropY>=0 && turned.CropWidth==extent && turned.CropHeight==extent,
            "boundary crop remains valid after quarter turns: "+extent+" / "+turns);
    }
    Check(identityGeometry.IsIdentity && identityGeometry.NativeConfig() is { Version: 1, StructSize: 40, CropWidth: 1, CropHeight: 1 }, "geometry defaults and v1 ABI");
    Check(System.Runtime.InteropServices.Marshal.SizeOf<Native.GeometryConfig>() == 40 &&
          System.Runtime.InteropServices.Marshal.OffsetOf<Native.GeometryConfig>(nameof(Native.GeometryConfig.QuarterTurns)).ToInt32() == 24 &&
          System.Runtime.InteropServices.Marshal.OffsetOf<Native.GeometryConfig>(nameof(Native.GeometryConfig.StraightenDegrees)).ToInt32() == 36, "geometry native layout");
    Check(identityGeometry.Rotate(-1).QuarterTurns == 3 && identityGeometry.Rotate(5).QuarterTurns == 1 && identityGeometry.Rotate(4).IsIdentity, "quarter turn wrapping");
    var crop = identityGeometry.WithCropPercent(CropComponent.X, 30).WithCropPercent(CropComponent.Width, 90);
    Check(crop.CropX == .3 && crop.CropWidth == .7, "crop inputs stay inside the normalized canvas");
    _ = crop.NativeConfig();
    foreach (var invalid in new[] {
        identityGeometry with { CropX = -.1 }, identityGeometry with { CropY = double.NaN },
        identityGeometry with { CropWidth = 0 }, identityGeometry with { CropHeight = double.PositiveInfinity },
        identityGeometry with { CropX = .2, CropWidth = .9 }, identityGeometry with { QuarterTurns = 4 },
        identityGeometry with { StraightenDegrees = 46 }, identityGeometry with { StraightenDegrees = double.NaN }
    }) {
        try { _ = invalid.NativeConfig(); throw new Exception("invalid geometry accepted"); }
        catch (ArgumentOutOfRangeException) { }
    }
    var geometryState = new Adjustments { Geometry = new(.2,.1,.65,.8,1,true,true,12.5) };
    var geometrySnapshot = geometryState.Capture(); var geometryClone = geometryState.Clone();
    geometryState.Geometry = new();
    Check(geometryClone.Geometry == geometrySnapshot.Geometry && !geometrySnapshot.SameAs(geometryState.Capture()), "geometry clone and snapshot freeze independent edits");
    try { _ = (geometrySnapshot with { Geometry = identityGeometry with { CropWidth = 0 } }).Restore(); throw new Exception("invalid saved geometry accepted"); }
    catch (ArgumentOutOfRangeException) { }
    FeatureRegressionChecks.Run(Check);
    var a = Path.Combine(root, "a", "same.ARW");
    var b = Path.Combine(root, "b", "same.ARW");
    foreach (var path in new[] { a, b }) { Directory.CreateDirectory(Path.GetDirectoryName(path)!); File.WriteAllText(path, path); }
    var state = new Adjustments(); state.ResolveWhiteBalance((5200, 8)); state.Set(Parameter.Temperature, 6000); state.Set(Parameter.Exposure, .75);
    Check(state.ExposureMode == 1 && state.Hsl.IsIdentity, "new photos use preview exposure and identity HSL");
    state.Hsl = state.Hsl.WithValue(1, 0, -60);
    var frozenHsl = state.Capture();
    state.Hsl = state.Hsl.WithValue(1, 0, 20);
    Check(frozenHsl.Restore().Hsl.Value(1, 0) == -60 && !frozenHsl.SameAs(state.Capture()), "HSL snapshots freeze values and detect edits");
    state.SetEffect(PhotoEffectParameter.VignetteAmount, -40);
    state.SetEffect(PhotoEffectParameter.GrainAmount, 65);
    state.DisplayChromaDenoise = 1;
    state.Geometry = geometrySnapshot.Geometry!;
    state.Lens = new LensSettings(true,true,false,true,"Maker\n镜头 Model,|\nMount\n1.000000");
    Check(new LensSettings(Manual:true).CoreProfileId == "__rawlab_manual_selection_required__", "manual lens requires selection");
    var saved = state.Capture();
    state.Denoise = DenoiseSettings.Clean;
    Check(!saved.SameAs(state.Capture()), "denoise changes mark the snapshot dirty");
    state.DisplayChromaDenoise = 0;
    Check(!saved.SameAs(state.Capture()), "display chroma changes mark the snapshot dirty");
    state.DisplayChromaDenoise = 1;
    saved = state.Capture();
    var storePath = Path.Combine(root, "edits");
    var store = new EditStore(storePath);
    store.Save(a, saved, "builtin:provia.cube");
    var reopened = new EditStore(storePath);
    var restored = reopened.Find(a)!;
    Check(restored.Settings.SameAs(saved), "settings survive store restart");
    Check(restored.Settings.Restore().Lens == saved.Lens, "lens survives store restart");
    Check(restored.Settings.Restore().Geometry == saved.Geometry, "geometry survives store restart");
    Check(!saved.SameAs(saved with { Geometry = new() }), "geometry changes mark snapshot dirty");
    Check(!saved.SameAs(saved with { Lens = new() }), "lens changes mark the snapshot dirty");
    Check(System.Runtime.InteropServices.Marshal.SizeOf<Native.LensProfile>() == 908 &&
          System.Runtime.InteropServices.Marshal.SizeOf<Native.LensReport>() == 1440 &&
          System.Runtime.InteropServices.Marshal.SizeOf<Native.LensConfig>() == 32, "lens ABI layout");
    Check(!restored.Settings.Restore().CameraWhiteBalance, "custom white balance mode survives");
    Check(restored.Settings.Restore().Denoise == DenoiseSettings.Clean, "denoise survives store restart");
    Check(restored.Settings.Restore().Effects == state.Effects && restored.Settings.Restore().DisplayChromaDenoise == 1,
        "photo effects and display chroma survive store restart");
    var legacy = System.Text.Json.Nodes.JsonNode.Parse(System.Text.Json.JsonSerializer.Serialize(saved))!.AsObject();
    legacy.Remove("Denoise");
    legacy.Remove("Lens");
    legacy.Remove("Geometry");
    Check(System.Text.Json.JsonSerializer.Deserialize<AdjustmentSnapshot>(legacy.ToJsonString())!.Restore().Geometry.IsIdentity, "older records default to identity geometry");
    Check(System.Text.Json.JsonSerializer.Deserialize<AdjustmentSnapshot>(legacy.ToJsonString())!.Restore().Lens == new LensSettings(), "legacy lens is disabled");
    Check(System.Text.Json.JsonSerializer.Deserialize<AdjustmentSnapshot>(legacy.ToJsonString())!.Restore().Denoise == new DenoiseSettings(), "older records default to disabled denoise");
    Check(reopened.Find(b) == null, "same basename does not share edits");
    state.ResetGroup("几何"); Check(state.Geometry.IsIdentity, "geometry group reset");
    state.Geometry = geometrySnapshot.Geometry!;
    state.ResetGroup("镜头"); Check(state.Lens == new LensSettings(), "lens group reset");
    state.Lens = new LensSettings(true);
    state.ResetAll(); Check(state.Geometry.IsIdentity, "reset all clears geometry"); Check(state.Lens == new LensSettings(), "reset all clears lens");
    reopened.Save(a, state.Capture(), null);
    Check(new EditStore(storePath).Find(a)!.Settings.Restore()[Parameter.Exposure] == 0, "reset persists");
    File.AppendAllText(a, "replacement");
    Check(reopened.Find(a) == null, "replaced input does not inherit edits");
    var blocked = Path.Combine(root, "blocked"); File.WriteAllText(blocked, "file");
    try { new EditStore(blocked).Save(b, saved, null); throw new Exception("write failure swallowed"); }
    catch (IOException) { }

    var output = Path.Combine(root, "output"); Directory.CreateDirectory(output);
    var oldOutput = Path.Combine(output, "same-Velvia.jpg"); File.WriteAllText(oldOutput, "existing");
    var job = BatchJob.Create(a, saved, null, "Velvia");
    var invalidTarget=BatchItem.Create(a) with{Selected=true,ValidationError="unsupported RAW"};
    var preflightJob=BatchJob.Create(a,saved,null,"Velvia");preflightJob.Items.Add(invalidTarget);
    Check(!invalidTarget.CanSelect && preflightJob.SelectedCount==0,"Failed RAW preflight cannot become a selected batch target");
    job.OutputDirectory = output;
    job.Items.Add(BatchItem.Create(a) with { Selected = true });
    job.Items.Add(BatchItem.Create(b) with { Selected = true });
    var journal = new BatchJournal(Path.Combine(root, "batch"));
    var rasterSource = Path.Combine(root, "source.PNG");
    var mixed = BatchJob.Create(rasterSource, saved, null, "Mixed");
    mixed.OutputDirectory = output;
    mixed.Items.Add(BatchItem.Create(a) with { Selected = true });
    var mixedCalls = 0;
    BatchRunner.Run(mixed, journal, false, CancellationToken.None, (_, _) => { }, (_, settings, _, destination) => {
        mixedCalls++;
        Check(settings.ExposureMode == 1 && settings[Parameter.Temperature] == 6500 && settings[Parameter.Tint] == 0 &&
              settings.Lens == new LensSettings(false,false,false), "raster source does not leak camera-only settings into RAW targets");
        Check(settings[Parameter.Exposure] == .75 && settings.Geometry == saved.Geometry && settings.Denoise == saved.Denoise,
              "mixed targets retain common frozen editing parameters");
        File.WriteAllText(destination, "mixed");
    });
    Check(mixedCalls == 1 && mixed.Items[0].Status == BatchStatus.Succeeded && mixed.Settings.SameAs(saved),
          "renderer-independent batch normalization preserves the stored source snapshot");
    var calls = new List<string>();
    BatchRunner.Run(job, journal, false, CancellationToken.None, (_, _) => { }, (input, settings, _, destination) => {
        calls.Add(input); Check(settings[Parameter.Exposure] == .75, "frozen source parameters");
        Check(settings.Denoise == DenoiseSettings.Clean, "frozen source denoise");
        Check(settings.Geometry == saved.Geometry, "batch render uses frozen geometry");
        Check(settings.Lens == saved.Lens, "frozen source lens configuration");
        Check(settings.Effects == saved.Effects && settings.DisplayChromaDenoise == 1, "frozen source effects and display chroma");
        if (input == b) throw new InvalidOperationException("invalid RAW");
        File.WriteAllText(destination, "rendered");
    });
    Check(job.Items[0].Status == BatchStatus.Succeeded && job.Items[1].Status == BatchStatus.Failed, "per-file failure result");
    Check(File.ReadAllText(oldOutput) == "existing", "existing output not overwritten");
    calls.Clear();
    BatchRunner.Run(job, journal, true, CancellationToken.None, (_, _) => { }, (input, _, _, destination) => { calls.Add(input); File.WriteAllText(destination, "retry"); });
    Check(calls.SequenceEqual(new[] { b }), "retry skips succeeded items");
    Check(journal.Load()!.Items.All(x => x.Status == BatchStatus.Succeeded), "success persisted");

    var cancelled = BatchJob.Create(a, saved, null, "Velvia"); cancelled.OutputDirectory = output;
    cancelled.Items.Add(BatchItem.Create(a) with { Selected = true }); cancelled.Items.Add(BatchItem.Create(b) with { Selected = true });
    using var cancellation = new CancellationTokenSource();
    BatchRunner.Run(cancelled, journal, false, cancellation.Token, (_, _) => { }, (_, _, _, destination) => { File.WriteAllText(destination, "first"); cancellation.Cancel(); });
    Check(cancelled.Cancelled && cancelled.Items[0].Status == BatchStatus.Succeeded && cancelled.Items[1].Status == BatchStatus.Waiting, "cancel preserves completed output");
    cancelled.Items[1] = cancelled.Items[1] with { Status = BatchStatus.Running };
    journal.Save(cancelled);
    var recovered = journal.Load()!;
    Check(recovered.Settings.Restore().Denoise == DenoiseSettings.Clean, "denoise survives journal recovery");
    Check(recovered.Settings.Restore().Geometry == saved.Geometry, "geometry survives journal recovery");
    Check(recovered.Settings.Restore().Lens == saved.Lens, "lens survives journal recovery");
    Check(recovered.Settings.Restore().Effects == saved.Effects && recovered.Settings.Restore().DisplayChromaDenoise == 1,
        "effects and display chroma survive journal recovery");
    Check(recovered.Interrupted && recovered.Items[1].Status == BatchStatus.Waiting, "interrupted running work recovers");
    Directory.CreateDirectory(Path.Combine(output, "directory-collision.jpg"));
    Check(Path.GetFileName(BatchRunner.UniqueOutput(output, "directory-collision", "jpg")) == "directory-collision-1.jpg", "directory names also occupy output names");
    var storageFailure = BatchJob.Create(a, saved, null, "Velvia"); storageFailure.OutputDirectory = output;
    storageFailure.Items.Add(BatchItem.Create(a) with { Selected = true }); storageFailure.Items.Add(BatchItem.Create(b) with { Selected = true });
    var storageCalls = 0;
    try {
        BatchRunner.Run(storageFailure, journal, false, CancellationToken.None, (_, _) => { }, (_, _, _, _) => {
            storageCalls++; throw new OutputWriteException("output storage unavailable");
        });
        throw new Exception("global output failure swallowed");
    } catch (OutputWriteException) { }
    Check(storageCalls == 1 && journal.Load()!.Interrupted, "global output failure stops and is recoverable");
    var look = Path.Combine(root, "look.cube"); File.WriteAllText(look, "frozen look");
    var draft = BatchJob.Create(a, saved, look, "Look"); journal.FreezeLook(draft); journal.Save(draft);
    File.WriteAllText(look, "changed live look");
    Check(File.ReadAllText(draft.Look!) == "frozen look", "look resource is frozen, not a live path");
    journal.Discard(draft);
    Check(journal.Load() == null && !File.Exists(draft.Look), "discard removes journal and owned look but no source");
    Check(File.Exists(look) && File.Exists(a), "discard preserves original resources");
    Console.WriteLine("PASS: Windows edit persistence, identity, WB, reset, snapshot, collision, failures, retry and recovery");
}
finally { Directory.Delete(root, true); }
