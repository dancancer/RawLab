using RawLab.Windows;
using System.Text.Json;

internal static class AdjustmentPresetChecks
{
    private static int checks;
    private static void Check(bool condition, string message)
    { if (!condition) throw new Exception(message); checks++; }
    private static void Reject(Action action, string message, PresetFailure? reason = null)
    {
        try { action(); } catch (AdjustmentPresetException error) {
            Check(reason == null || error.Reason == reason, message + " error kind"); return;
        }
        throw new Exception("Accepted invalid preset operation: " + message);
    }
    private static AdjustmentPayload Payload(double exposure = 1.25) => new(new("source.raw", true, 2),
        new Dictionary<AdjustmentField, JsonElement> { [AdjustmentField.Exposure] = AdjustmentPayload.Value(exposure) });

    internal static void Run()
    {
        var root = Path.Combine(Path.GetTempPath(), "RawLab-presets-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try {
            Lifecycle(Path.Combine(root, "lifecycle"));
            IdentityAndStaleConfirmation(Path.Combine(root, "identity"));
            FailureAndConcurrency(Path.Combine(root, "failures"));
            Vectors(Path.Combine(root, "vectors"));
            Application(Path.Combine(root, "application"));
            Console.WriteLine($"PASS: {checks} user preset store checks with 55 shared vectors");
        } finally { Directory.Delete(root, true); }
    }

    private static void Lifecycle(string directory)
    {
        var store = new AdjustmentPresetStore(directory);
        Check(store.List().Count == 0, "missing preset directory is an empty library");
        Reject(() => store.Create(" \t\u200B", Payload()), "whitespace name", PresetFailure.EmptyName);
        var first = store.Create("  Cafe\u0301 \n", Payload());
        Check(first.Name == "Café" && first.Payload.Source.Identifier == "preset:" + first.ID, "NFC trimmed independent source");
        Check(new AdjustmentPresetStore(directory).List().Single().SameAs(first), "restart preserves entry");
        Reject(() => store.Create("Café", Payload()), "normalized duplicate", PresetFailure.DuplicateName);
        var other = store.Create("café", Payload(.5));
        Check(other.ID != first.ID, "case-sensitive names remain separate");
        var renamed = store.Rename(first, "Morning");
        Check(renamed.ID == first.ID && renamed.CreatedAt == first.CreatedAt && renamed.Payload.Source == first.Payload.Source,
            "rename preserves identity and payload");
        var updated = store.Overwrite(renamed, Payload(2));
        Check(updated.ID == first.ID && updated.CreatedAt == first.CreatedAt && updated.UpdatedAt > renamed.UpdatedAt &&
            AdjustmentPayload.Number(updated.Payload[AdjustmentField.Exposure]) == 2, "overwrite preserves identity and advances time");
        var bytes = File.ReadAllBytes(Path.Combine(directory, "presets.json"));
        Check(store.Rename(updated, updated.Name).SameAs(updated) && File.ReadAllBytes(Path.Combine(directory, "presets.json")).SequenceEqual(bytes),
            "unchanged rename does not rewrite library");
        Reject(() => store.Rename(updated, other.Name), "duplicate rename", PresetFailure.DuplicateName);
        store.Delete(updated); Check(store.List().Single().SameAs(other), "delete preserves other entry");
    }

    private static void IdentityAndStaleConfirmation(string directory)
    {
        var a = Guid.NewGuid().ToString(); var b = Guid.NewGuid().ToString();
        var ids = new Queue<string>([a, a, b]);
        var store = new AdjustmentPresetStore(directory, makeID: () => ids.Dequeue(), clock: () => 7);
        var first = store.Create("A", Payload()); var second = store.Create("B", Payload());
        Check(second.ID == b, "ID collision retries without overwriting first");
        var renamed = new AdjustmentPresetStore(directory, clock: () => 3).Rename(first, "Renamed");
        Check(renamed.UpdatedAt == 8, "clock rollback still advances revision timestamp");
        Reject(() => store.Overwrite(first, Payload(.7)), "stale overwrite", PresetFailure.Changed);
        Reject(() => store.Delete(first), "stale delete", PresetFailure.Changed);
        Reject(() => store.Rename(first, "Later"), "stale rename", PresetFailure.Changed);
        store.Delete(renamed);
        var colliding = new AdjustmentPresetStore(directory, makeID: () => a);
        Reject(() => colliding.Create("Deleted identity", Payload()), "deleted ID is retired", PresetFailure.IdentityCollision);
        Reject(() => colliding.Delete(renamed), "deleted confirmation cannot match new entry", PresetFailure.Changed);
        Check(store.List().Single().SameAs(second), "identity failures preserve remaining entry");
    }

    private static void FailureAndConcurrency(string directory)
    {
        var store = new AdjustmentPresetStore(directory); var initial = store.Create("Initial", Payload());
        var path = Path.Combine(directory, "presets.json"); var bytes = File.ReadAllBytes(path);
        var failing = new AdjustmentPresetStore(directory, write: (_, _) => throw new IOException("injected atomic failure"));
        try { failing.Overwrite(initial, Payload(.2)); throw new Exception("write failure swallowed"); } catch (IOException) { }
        Check(File.ReadAllBytes(path).SequenceEqual(bytes), "failed replacement preserves original bytes");
        var winners = 0;
        Parallel.For(0, 8, index => {
            try { new AdjustmentPresetStore(directory).Rename(initial, "Concurrent " + index); Interlocked.Increment(ref winners); }
            catch (AdjustmentPresetException error) when (error.Reason == PresetFailure.Changed) { }
        });
        Check(winners == 1 && store.List().Count == 1, "only one concurrent stale confirmation can win");
        File.WriteAllText(path, "{broken");
        Reject(() => store.List(), "malformed library", PresetFailure.CorruptLibrary);
        Reject(() => store.Create("New", Payload()), "malformed library blocks replacement", PresetFailure.CorruptLibrary);
        Check(File.ReadAllText(path) == "{broken", "malformed bytes preserved");
    }

    private static void Application(string directory)
    {
        Directory.CreateDirectory(directory);
        var source = Path.Combine(directory, "source.ARW"); var target = Path.Combine(directory, "target.ARW");
        File.WriteAllText(source, "source"); File.WriteAllText(target, "target");
        var store = new EditStore(Path.Combine(directory, "edits")); var session = new AdjustmentTransferSession(store);
        var settings = new Adjustments(); settings.Set(Parameter.Exposure, 1.25); settings.Set(Parameter.Contrast, 20);
        var sourceEdit = new SavedEdit(OriginalIdentity.Read(source), settings.Capture(), null);
        var clipboard = session.Copy(AdjustmentScope.Custom([AdjustmentField.Contrast]), sourceEdit, new(source, true));
        var payload = AdjustmentTransfer.Capture(AdjustmentScope.Custom([AdjustmentField.Exposure]), sourceEdit, new(source, true));
        var preset = new AdjustmentPresetStore(Path.Combine(directory, "presets")).Create("Independent", payload);
        File.Delete(source);
        var baseline = new Adjustments(); baseline.Set(Parameter.Contrast, 35);
        var destination = new AdjustmentTransferTarget(target, new(OriginalIdentity.Read(target), baseline.Capture(), null), new(target, true));
        var operation = session.Prepare(preset.Payload, [destination], AdjustmentHistoryAction.Preset);
        Check(SavedEdit.Same(operation.Targets.Single().Candidate, session.Prepare(payload, [destination]).Targets.Single().Candidate),
            "preset and clipboard produce identical candidate after source removal");
        Check(session.Apply(operation).Single().Status == AdjustmentStatus.Applied &&
            store.Find(target)!.Settings.Restore()[Parameter.Contrast] == 35, "preset changes only selected fields");
        Check(session.Clipboard == clipboard && session.Transactions.Single().Action == AdjustmentHistoryAction.Preset,
            "preset preserves clipboard and records its own action");
        Check(session.UndoPhoto(target).Single().Status == AdjustmentStatus.Applied && session.PhotoHistoryID(target, false) != null, "preset undo uses saved history");
        var unchanged = session.Prepare(Payload(0), [destination], AdjustmentHistoryAction.Preset);
        Check(session.Apply(unchanged).Single().Status == AdjustmentStatus.Unchanged && session.PhotoHistoryID(target, false) != null, "unchanged preset preserves redo");
        Check(session.RedoPhoto(target).Single().Status == AdjustmentStatus.Applied, "preset redo remains applicable");
        var missingLook = new AdjustmentPayload(new("preset:fixture", true, 2), new Dictionary<AdjustmentField, JsonElement> {
            [AdjustmentField.Look] = AdjustmentPayload.Value(new { kind = "managed", id = "missing" }) });
        var prior = store.VersionedState(target);
        Check(session.Apply(session.Prepare(missingLook, [destination], AdjustmentHistoryAction.Preset)).Single().Status == AdjustmentStatus.Blocked &&
            store.VersionedState(target).SameAs(prior), "missing preset look blocks before any write");
    }

    private static void Vectors(string directory)
    {
        Directory.CreateDirectory(directory);
        var store = new AdjustmentPresetStore(directory); var path = Path.Combine(directory, "presets.json");
        using var fixtures = JsonDocument.Parse(File.ReadAllText("Shared/fixtures/adjustment-presets-v1.json"));
        Check(fixtures.RootElement.GetArrayLength() == 55, "complete shared fixture catalog");
        foreach (var fixture in fixtures.RootElement.EnumerateArray()) {
            var id = fixture.GetProperty("id").GetString()!;
            var json = fixture.TryGetProperty("registry_json", out var raw) ? raw.GetString()! : fixture.GetProperty("registry").GetRawText();
            File.WriteAllText(path, json); var bytes = File.ReadAllBytes(path);
            if (fixture.GetProperty("valid").GetBoolean()) {
                var entry = store.List().Single();
                Check(AdjustmentPayload.Number(entry.Payload[AdjustmentField.Exposure]) == 1.25, id);
            } else {
                Reject(() => store.List(), id);
                Reject(() => store.Create("Blocked", Payload()), id + " write blocked");
                Check(File.ReadAllBytes(path).SequenceEqual(bytes), id + " bytes preserved");
            }
        }
    }
}
