using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RawLab.Windows;

public sealed record RecipeHsl(double[] Hue, double[] Saturation, double[] Lightness)
{
    public HslSettings Settings() => Hue.Length == 8 && Saturation.Length == 8 && Lightness.Length == 8
        ? new(Hue.Concat(Saturation).Concat(Lightness).ToArray())
        : throw new InvalidDataException(Loc.Text("配方 HSL 参数无效。"));
}

public sealed record MasterRecipe(string Id, string Name, string Subtitle, string Summary, string LutFileName,
    double ExposureDelta, double ShadowsDelta, double HighlightsDelta, double ContrastDelta,
    double SaturationDelta, double TintDelta, RecipeHsl Hsl)
{
    [JsonIgnore] public string LutPath => Path.Combine(AppContext.BaseDirectory, "MasterRecipes", LutFileName);
    [JsonIgnore] public string ArtworkPath => Path.Combine(AppContext.BaseDirectory, "MasterRecipeIcons", Id + ".png");
    public static IReadOnlyList<MasterRecipe> All { get; } = Load();
    public static MasterRecipe? Find(string? id) => All.FirstOrDefault(recipe => recipe.Id == id);
    private static IReadOnlyList<MasterRecipe> Load()
    {
        var path = new[] { Path.Combine(AppContext.BaseDirectory, "master-recipes.json"), "Shared/master-recipes.json" }
            .First(File.Exists);
        var recipes = JsonSerializer.Deserialize<MasterRecipe[]>(File.ReadAllText(path),
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? throw new InvalidDataException(Loc.Text("配方目录无效。"));
        if (recipes.Length != 14 || recipes.Select(recipe => recipe.Id).Distinct().Count() != recipes.Length)
            throw new InvalidDataException(Loc.Text("配方目录不完整。"));
        foreach (var recipe in recipes) _ = recipe.Hsl.Settings();
        return Array.AsReadOnly(recipes);
    }
}
