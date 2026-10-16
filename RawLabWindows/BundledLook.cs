using System.IO;
using System.Text.Json;

namespace RawLab.Windows;

public sealed record BundledLook(string Id, string Name, string FileName, string ArtworkName)
{
    public static IReadOnlyDictionary<string, BundledLook> All { get; } = Load();

    private static IReadOnlyDictionary<string, BundledLook> Load()
    {
        var path = new[] { Path.Combine(AppContext.BaseDirectory, "bundled-looks.json"), "Shared/BundledLooks/catalog.json" }
            .First(File.Exists);
        var entries = JsonSerializer.Deserialize<BundledLook[]>(File.ReadAllText(path),
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? throw new InvalidDataException("Invalid bundled look catalog");
        if (entries.Select(entry => entry.Id).Distinct().Count() != entries.Length)
            throw new InvalidDataException("Duplicate bundled look identity");
        return entries.ToDictionary(entry => entry.FileName, StringComparer.Ordinal);
    }
}
