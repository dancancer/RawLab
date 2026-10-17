using RawLab.Windows;

static void Check(bool condition, string name)
{
    if (!condition) throw new Exception(name);
    Console.WriteLine("PASS " + name);
}

Check(Loc.Resolve("system", "de-DE") == "de", "Regional system language");
Check(Loc.Resolve("system", "zh-Hans-CN") == "zh-Hans", "Simplified Chinese");
Check(Loc.Resolve("system", "zh-Hant-TW") == "en", "Unsupported Chinese script");
Check(Loc.Resolve("system", "pt-BR") == "en", "Unsupported language fallback");
Check(Loc.Resolve("ja", "fr-FR") == "ja", "Explicit language selection");
foreach (var (argument, composed) in new[] {
    ("\"暗角强度\"", false), ("titles[i + 1]", false), ("recipe?.Subtitle ?? \"中性直出\"", false),
    ("selected ? \"暗角\" : \"颗粒\"", false), ("(spec.IsVignette ? \"暗角\" : \"颗粒\")+titles[(int)spec.Id]", true),
    ("\"重置\"+name", true), ("(\"重置\" + name)", true), ("$\"重置{name}\"", true), ("string.Concat(a, b)", true) })
    Check(StaticKeyChecks.IsComposed(argument) == composed, "Composed-key scanner classifies " + argument);
var keyArguments = StaticKeyChecks.Arguments(StaticKeyChecks.SourceDirectory()).ToList();
var composedKeys = keyArguments.Where(argument => StaticKeyChecks.IsComposed(argument.Text))
    .Select(argument => "\n  " + argument.Location + ": " + argument.Text).ToList();
Check(keyArguments.Count > 150 && composedKeys.Count == 0,
    $"{keyArguments.Count} Loc calls use static keys" + string.Concat(composedKeys));
var expected = new Dictionary<string, string> { ["en"] = "Language", ["zh-Hans"] = "语言",
    ["de"] = "Sprache", ["fr"] = "Langue", ["ja"] = "言語", ["es"] = "Idioma" };
foreach (var pair in expected)
{
    Loc.Initialize(pair.Key);
    Check(Loc.Text("语言") == pair.Value, pair.Key + " embedded catalog");
    Check(Loc.Strings.Count > 250, pair.Key + " full catalog");
    Check(Loc.Strings.ContainsKey("裁切与旋转") && Loc.Strings.ContainsKey("拉直角度") &&
          Loc.Strings.ContainsKey("宽度 (%)") && Loc.Strings.ContainsKey("重置几何"), pair.Key + " geometry labels");
    Check(Loc.Format("导出 {0} 张", 2).Contains('2'), pair.Key + " formatted arguments");
    Check(Loc.Text("unknown.key") == "unknown.key", pair.Key + " unknown key fallback");
    var missing = keyArguments.SelectMany(argument => StaticKeyChecks.Literals(argument.Text)
        .Where(key => !Loc.Strings.ContainsKey(key)).Select(key => "\n  " + argument.Location + ": " + key)).ToList();
    Check(missing.Count == 0, pair.Key + " literal keys inside Loc calls are catalogued" + string.Concat(missing));
}
