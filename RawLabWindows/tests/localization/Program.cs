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
    Check(Loc.Strings.ContainsKey("水平透视 (%)") && Loc.Strings.ContainsKey("垂直透视 (%)") &&
          Loc.Strings.ContainsKey("裁切、旋转与透视") &&
          Loc.Strings.ContainsKey("旋转与翻转 → 透视 → 拉直 → 裁切；裁切百分比以变换后的画布为基准。"), pair.Key + " perspective labels and processing order help");
    Check(Loc.Strings.ContainsKey("裁切比例") && Loc.Strings.ContainsKey("交换宽高比例") &&
          Loc.Strings.ContainsKey("精确裁切") && Loc.Strings.ContainsKey("应用几何调整") &&
          Loc.Strings.ContainsKey("取消几何调整") && Loc.Strings.ContainsKey("先应用或取消几何调整，再导出。"), pair.Key + " crop draft labels and accessibility");
    Check(Loc.Format("透视：水平 {0:+0.##;-0.##;0}% · 垂直 {1:+0.##;-0.##;0}%", 35, -20).Contains("+35") &&
          Loc.Format("透视：水平 {0:+0.##;-0.##;0}% · 垂直 {1:+0.##;-0.##;0}%", 35, -20).Contains("-20"), pair.Key + " perspective summary arguments");
    Check(Loc.Format("导出 {0} 张", 2).Contains('2'), pair.Key + " formatted arguments");
    Check(Loc.Text("unknown.key") == "unknown.key", pair.Key + " unknown key fallback");
}
