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
}
