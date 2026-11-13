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
            UnreadableEntry(Path.Combine(root, "unreadable"));
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

    // 新版本写入的预设（未知字段、未来版本）只让这一条不可用，其余照常列出、应用和修改。
    private static void UnreadableEntry(string directory)
    {
        var store = new AdjustmentPresetStore(directory); var valid = store.Create("Valid", Payload());
        var path = Path.Combine(directory, "presets.json"); var text = File.ReadAllText(path); var future = Guid.NewGuid().ToString();
        var raw = "{ \"id\": \"" + future + "\", \"name\": \"Future\", \"created_at\": 1, \"updated_at\": 1,\n  \"payload\": { \"payload_version\": 9 }, \"future_field\": \"caf\\u00e9\" }";
        Check(text.Contains("\"presets\":["), "library splice point");
        File.WriteAllText(path, text.Replace("\"presets\":[", "\"presets\":[" + raw + ","));
        var listed = store.List().Single();
        Check(listed.SameAs(valid) && AdjustmentPayload.Number(listed.Payload[AdjustmentField.Exposure]) == 1.25,
            "unreadable entry leaves the remaining preset usable");
        var unreadable = store.ListUnreadable().Single();
        Check(unreadable.ID == future && unreadable.Name == "Future" && unreadable.Json == raw, "unreadable entry keeps identity and original text");
        var created = store.Create("Created", Payload(.5));
        var updated = store.Overwrite(store.Rename(valid, "Renamed"), Payload(2));
        Check(File.ReadAllText(path).Contains(raw) && store.ListUnreadable().Single().Json == raw && store.List().Count == 2,
            "create, rename and overwrite pass the unreadable entry through unchanged");
        Reject(() => store.Create("Future", Payload()), "unreadable entry name stays reserved", PresetFailure.DuplicateName);
        Reject(() => new AdjustmentPresetStore(directory, makeID: () => future).Create("Collision", Payload()),
            "unreadable entry ID stays reserved", PresetFailure.IdentityCollision);
        var dialogItems = PresetLibraryDataSource.Load(store);
        Check(dialogItems.Count == 3 && dialogItems.Any(item => item.IsCorrupt && item.DisplayName == "Future（损坏）" && item.ID == future),
            "corrupt preset is surfaced in preset library dialog data source with damaged label");
        store.Delete(updated); store.Delete(created);
        Check(store.List().Count == 0 && File.ReadAllText(path).Contains(raw), "deleting readable presets keeps the unreadable entry");
        var onlyCorrupt = PresetLibraryDataSource.Load(store);
        Check(onlyCorrupt.Count == 1 && onlyCorrupt.Single().IsCorrupt && onlyCorrupt.Single().Unreadable == unreadable,
            "dialog data source contains only the corrupt item when all valid presets deleted");
        store.Delete(unreadable);
        Check(store.ListUnreadable().Count == 0 && PresetLibraryDataSource.Load(store).Count == 0 && !File.ReadAllText(path).Contains(raw),
            "corrupt preset can be removed and clears from dialog data source and disk");
    }

    private static void Application(string directory)
    {
        Directory.CreateDirectory(directory);
        var source = Path.Combine(directory, "source.ARW"); var target = Path.Combine(directory, "target.ARW");
        File.WriteAllText(source, "source"); File.WriteAllText(target, "target");
        var store = new EditStore(Path.Combine(directory, "edits")); var session = new AdjustmentTransferSession(store);
        var settings = new Adjustments { ToneControls = new(-37.25,42.5,18.125) }; settings.Set(Parameter.Exposure, 1.25); settings.Set(Parameter.Contrast, 20);
        var sourceEdit = new SavedEdit(OriginalIdentity.Read(source), settings.Capture(), null);
        var clipboard = session.Copy(AdjustmentScope.Custom([AdjustmentField.Contrast]), sourceEdit, new(source, true));
        var payload = AdjustmentTransfer.Capture(AdjustmentScope.Custom([AdjustmentField.Exposure, AdjustmentField.BlackPoint, AdjustmentField.WhitePoint, AdjustmentField.Vibrance]), sourceEdit, new(source, true));
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
        Check(store.Find(target)!.Settings.Restore().ToneControls == settings.ToneControls, "preset redo restores all independent tone fields");
        var missingLook = new AdjustmentPayload(new("preset:fixture", true, 2), new Dictionary<AdjustmentField, JsonElement> {
            [AdjustmentField.Look] = AdjustmentPayload.Value(new { kind = "managed", id = "missing" }) });
        var prior = store.ReadState(target);
        Check(session.Apply(session.Prepare(missingLook, [destination], AdjustmentHistoryAction.Preset)).Single().Status == AdjustmentStatus.Blocked &&
            store.ReadState(target).SameAs(prior), "missing preset look blocks before any write");
    }

    // 注册表本身无法解读的向量仍让整个库失败；其余无效向量只是单条预设读不懂。
    private static readonly HashSet<string> RegistryFailures = [
        "future-registry", "unknown-registry-field", "duplicate-id", "duplicate-name", "invalid-retired-id", "overlapping-retired-id",
        "duplicate-retired-id", "registry-decimal", "registry-exponent", "registry-rounded-fraction", "registry-boolean", "registry-string",
        "registry-null", "json-unquoted-metadata-key", "json-single-quoted-key", "json-trailing-document", "json-trailing-comma", "json-comment",
        "duplicate-root-key", "duplicate-escaped-root-key"
    ];

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
            } else if (!RegistryFailures.Contains(id)) {
                using var registry = JsonDocument.Parse(json);
                var entryJson = registry.RootElement.GetProperty("presets")[0].GetRawText();
                Check(store.List().Count == 0 && store.ListUnreadable().Single().Json == entryJson, id + " isolated as unreadable entry");
                var created = store.Create("Writable", Payload());
                Check(store.List().Single().SameAs(created) && File.ReadAllText(path).Contains(entryJson), id + " entry passed through unchanged");
            } else {
                Reject(() => store.List(), id);
                Reject(() => store.Create("Blocked", Payload()), id + " write blocked");
                Check(File.ReadAllBytes(path).SequenceEqual(bytes), id + " bytes preserved");
            }
        }
    }
}
