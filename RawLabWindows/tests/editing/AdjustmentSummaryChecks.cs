using System.Globalization;
using System.Text.Json;
using RawLab.Windows;
using F = RawLab.Windows.AdjustmentField;

internal static class AdjustmentSummaryChecks
{
    internal static void Run()
    {
        using var document = JsonDocument.Parse(File.ReadAllText("Shared/fixtures/adjustment-summary-v1.json"));
        var checks = 0;
        void Check(bool condition, string message) { if (!condition) throw new Exception(message); checks++; }
        foreach (var row in document.RootElement.GetProperty("cases").EnumerateArray()) {
            var id = row.GetProperty("id").GetString();
            var payload = AdjustmentPayload.Parse(row.GetProperty("payload").GetRawText());
            var expected = row.GetProperty("expected");
            var summary = new AdjustmentSummary(payload, CultureInfo.GetCultureInfo("zh-Hans"), key => key);
            Check(summary.Count == expected.GetProperty("count").GetInt32(), id + " count");
            Check(summary.IncludesGeometry == expected.GetProperty("includes_geometry").GetBoolean(), id + " geometry");
            var groups = expected.GetProperty("groups").EnumerateArray().ToArray();
            Check(summary.Groups.Count == groups.Length, id + " group count");
            for (var index = 0; index < groups.Length; index++) {
                Check(summary.Groups[index].ID == groups[index].GetProperty("id").GetString(), id + " group order");
                Check(summary.Groups[index].Fields.Select(field => field.ID()).SequenceEqual(
                    groups[index].GetProperty("fields").EnumerateArray().Select(field => field.GetString())), id + " field order");
            }
            var values = expected.GetProperty("values_zh");
            Check(payload.Fields.Select(field => field.ID()).ToHashSet().SetEquals(values.EnumerateObject().Select(pair => pair.Name)), id + " exact field set");
            foreach (var pair in values.EnumerateObject()) {
                string? LookName(string kind, string look) => (kind, look) switch {
                    ("builtin", "acros") => "Acros", ("recipe", "recipe-v3") => "Recipe V3",
                    ("recipe", "recipe-v4") => "Recipe V4", _ => null
                };
                var actual = summary.ValueText(AdjustmentFields.Parse(pair.Name), LookName);
                Check(actual == pair.Value.GetString(), $"{id} {pair.Name}: {actual}");
            }
            var note = expected.TryGetProperty("recipe_note", out var recipeNote) && recipeNote.ValueKind != JsonValueKind.Null ? recipeNote.GetString() : null;
            Check(summary.RecipeNote == note, id + " recipe note");
        }
        var identity = new OriginalIdentity("scope.arw", 1, 2, 3);
        var settings = new Adjustments(); settings.Set(Parameter.Exposure, 0.7);
        var saved = new SavedEdit(identity, settings.Capture(), null);
        var context = new AdjustmentTransferContext("scope.arw", true);
        var preview = AdjustmentTransfer.PreviewCapture(AdjustmentScope.Modified, saved, saved, context);
        Check(preview.Fields.SetEquals([F.Exposure]) && AdjustmentPayload.Number(preview[F.Exposure]) == 0.7, "Actual modified scope");
        settings.Set(Parameter.Exposure, 0.8);
        try { _ = AdjustmentTransfer.PreviewCapture(AdjustmentScope.All, saved with { Settings = settings.Capture() }, saved, context); throw new Exception("Unsaved preview accepted"); }
        catch (AdjustmentTransferException error) { Check(error.Failure == AdjustmentFailure.Draft, "Unsaved preview rejected"); }
        var empty = saved with { Settings = new Adjustments().Capture() };
        try { _ = AdjustmentTransfer.PreviewCapture(AdjustmentScope.Modified, empty, empty, context); throw new Exception("Empty preview accepted"); }
        catch (AdjustmentTransferException error) { Check(error.Failure == AdjustmentFailure.EmptyScope, "Empty modified scope remains distinct"); }
        var german = new AdjustmentSummary(preview, CultureInfo.GetCultureInfo("de-DE"), key => key);
        Check(german.ValueText(F.Exposure) == "+0,70 EV", "Explicit German numeric locale");
        Console.WriteLine($"PASS: {checks} Windows scope summary checks and shared payload vectors");
    }
}
