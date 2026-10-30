using RawLab.Windows;

static void Check(bool value, string message) { if (!value) throw new Exception(message); Console.WriteLine("PASS: " + message); }
var looks = BundledLook.All.Values.ToArray();
Check(looks.Count(look => FilmGrouping.ForBuiltIn(look.FileName) == FilmGroup.Kodak) == 24, "24 Kodak entries include RawLab Ektar");
Check(looks.Count(look => FilmGrouping.ForBuiltIn(look.FileName) == FilmGroup.Other) == 5, "Five camera looks remain Other");
Check(FilmGrouping.ForBuiltIn("FLog2_to_PROVIA_65grid_V.1.00.cube") == FilmGroup.Fuji, "Legacy Fuji filename keeps its group");
Check(FilmGrouping.ForBuiltIn("unknown.cube") == FilmGroup.Other, "Unknown look falls back to Other");
var input = new[] {
    (Id:"imported:provia", Group:FilmGroup.Other, Neutral:false),
    (Id:"kodak", Group:FilmGroup.Kodak, Neutral:false),
    (Id:"neutral", Group:FilmGroup.Other, Neutral:true),
    (Id:"fuji", Group:FilmGroup.Fuji, Neutral:false),
    (Id:"camera", Group:FilmGroup.Other, Neutral:false)
};
var ordered = FilmGrouping.Arrange(input, item => item.Neutral, item => item.Group);
Check(ordered.Select(item => item.Value.Id).SequenceEqual(new[] {"neutral","fuji","kodak","imported:provia","camera"}), "Flat order preserves neutral and same-name imports");
Check(ordered.Where(item => item.StartsGroup).Select(item => item.Value.Id).SequenceEqual(new[] {"kodak","imported:provia"}), "Only two nonempty-group boundaries receive dividers");
Check(ordered.Select(item => item.Value).ToHashSet().SetEquals(input), "Grouping preserves original identities");
Check(FilmGrouping.Arrange(input.Take(1), item => item.Neutral, item => item.Group).All(item => !item.StartsGroup), "A single group has no leading separator");
Check(FilmGrouping.Arrange(input.Take(0), item => item.Neutral, item => item.Group).Count == 0, "Empty lists have no phantom separators");
LookImportChecks.Run();
var browserItems = new[] {
    new LookBrowserItem("builtin:a", "Été", FilmGroup.Fuji, false),
    new LookBrowserItem("managed:b", "Été custom", FilmGroup.Other, true),
    new LookBrowserItem("builtin:c", "Chrome", FilmGroup.Kodak, false)
};
Check(LookBrowser.Filter(browserItems, LookBrowserCategory.All, " ETE ", []).SequenceEqual(new[]{"builtin:a","managed:b"}), "Search ignores case and accents without changing item identity");
Check(LookBrowser.Filter(browserItems, LookBrowserCategory.Custom, "", []).SequenceEqual(new[]{"managed:b"}), "Custom category keeps managed identities");
var recent = new RecentLooks(Enumerable.Range(0,15).Select(i=>"id"+i));
Check(recent.IDs.Count==12, "Recent looks are bounded to twelve");
recent.Record("builtin:a", browserItems.Select(item=>item.ID).ToHashSet());
recent.Record("managed:b", browserItems.Select(item=>item.ID).ToHashSet());
recent.Record("builtin:a", browserItems.Select(item=>item.ID).ToHashSet());
Check(recent.IDs.SequenceEqual(new[]{"builtin:a","managed:b"}), "Recent looks deduplicate and prune removed entries");
Check(LookBrowser.Filter(browserItems, LookBrowserCategory.Recent, "", recent.IDs).SequenceEqual(recent.IDs), "Recent category preserves application order");
Check(LookBrowser.Filter(browserItems, LookBrowserCategory.All, "absent", []).Count==0, "Unmatched search has no fallback selection");
var layout = new WorkspaceLayout();
Check(layout.PanelHeight(false,600)==220 && layout.PanelHeight(true,600)==344, "Automatic panel separates single and complex controls");
layout.Resize(290,600);
Check(layout.PanelHeight(false,600)==290 && layout.PanelHeight(true,600)==290, "Manual panel height survives tool changes");
layout.RestoreAutomatic();
Check(layout.PanelHeight(false,600)==220 && layout.IsAutomatic, "Automatic height can be restored");
Check(!layout.ShowsFiles(1024,false) && layout.ShowsFiles(1024,true), "Only empty narrow file trees collapse automatically");
layout.ToggleFiles(1024,false);
Check(layout.ShowsFiles(1024,false), "Manual file tree choice survives automatic sizing");
