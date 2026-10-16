using System.Globalization;
using System.IO;
using System.Reflection;
using System.Text.Json;

namespace RawLab.Windows;

public sealed record LanguageOption(string Code, string NativeName);

public static class Loc
{
    public static IReadOnlyList<LanguageOption> Choices { get; } = [
        new("system", "跟随系统"), new("zh-Hans", "简体中文"), new("en", "English"),
        new("de", "Deutsch"), new("fr", "Français"), new("ja", "日本語"), new("es", "Español")
    ];
    private static readonly string preferenceFile = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RawLab", "language.txt");
    private static Dictionary<string, string> english = new();
    private static Dictionary<string, string> translated = new();
    private static readonly string systemLanguage = CultureInfo.CurrentUICulture.Name;
    public static string Preference { get; private set; } = "system";
    public static string Language { get; private set; } = "en";
    public static IReadOnlyDictionary<string, string> Strings => translated;
    public static event Action? Changed;

    public static string Resolve(string preference, string systemLanguage)
    {
        if (Choices.Any(c => c.Code == preference && preference != "system")) return preference;
        var parts = systemLanguage.Replace('_', '-').ToLowerInvariant().Split('-');
        if (parts[0] == "zh")
            return parts.Any(p => p is "hant" or "tw" or "hk" or "mo") ? "en" : "zh-Hans";
        return Choices.Any(c => c.Code == parts[0] && c.Code != "system") ? parts[0] : "en";
    }

    public static void Initialize(string? preferenceOverride = null)=>Initialize(preferenceOverride,null);
    public static void Initialize(string? preferenceOverride,string? preferencePath)
    {
        var path=preferencePath ?? preferenceFile;
        try { Preference = preferenceOverride ?? (File.Exists(path) ? File.ReadAllText(path).Trim() : "system"); }
        catch (IOException) { Preference = "system"; }
        catch (UnauthorizedAccessException) { Preference = "system"; }
        if (!Choices.Any(c => c.Code == Preference)) Preference = "system";
        Reload();
    }

    public static void SetPreference(string preference)=>SetPreference(preference,null);
    public static void SetPreference(string preference,string? preferencePath)
    {
        if (!Choices.Any(c => c.Code == preference)) throw new ArgumentException(nameof(preference));
        var path=preferencePath ?? preferenceFile;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, preference);
        Preference = preference;
        Reload();
        Changed?.Invoke();
    }

    private static void Reload()
    {
        Language = Resolve(Preference, systemLanguage);
        english = ReadCatalog("en");
        translated = new Dictionary<string, string>(english);
        foreach (var pair in ReadCatalog(Language)) translated[pair.Key] = pair.Value;
    }

    private static Dictionary<string, string> ReadCatalog(string language)
    {
        var assembly = Assembly.GetExecutingAssembly();
        var name = assembly.GetManifestResourceNames().FirstOrDefault(n => n.EndsWith($".Localization.{language}.json", StringComparison.Ordinal));
        if (name == null) return new();
        using var stream = assembly.GetManifestResourceStream(name)!;
        return JsonSerializer.Deserialize<Dictionary<string, string>>(stream) ?? new();
    }

    public static string Text(string key) => translated.GetValueOrDefault(key) ?? english.GetValueOrDefault(key) ?? key;
    public static string Format(string key, params object?[] arguments) =>
        string.Format(CultureInfo.GetCultureInfo(Language), Text(key), arguments);
}
