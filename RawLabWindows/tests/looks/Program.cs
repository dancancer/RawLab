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
LookLibraryToleranceChecks.Run();
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
Check(layout.Mode == WorkspaceMode.Editing && layout.LibraryAt(1440) == LibraryPresentation.Docked &&
    layout.LibraryAt(1024) == LibraryPresentation.Hidden && layout.ShowsInspector(true), "Edit uses a docked library at wide sizes and a right inspector");
layout.ResizeLibrary(300);
layout.ResizeInspector(332);
Check(layout.LibraryWidth == 288 && layout.InspectorWidthAt(1440) == 332 && layout.InspectorWidthAt(1024) == 280,
    "Width limits are independent and the narrow inspector leaves the remembered width intact");
layout.ToggleLibrary(1024);
Check(layout.LibraryAt(1024) == LibraryPresentation.Drawer, "Narrow file navigation opens a drawer");
layout.SetMode(WorkspaceMode.Preview);
Check(layout.LibraryAt(1024) == LibraryPresentation.Hidden && !layout.ShowsInspector(true), "Preview gives the photograph both panes' space");
Check(layout.DismissTransient() && layout.Mode == WorkspaceMode.Editing &&
    layout.LibraryAt(1024) == LibraryPresentation.Drawer, "Escape restores the editing workspace and its drawer");
layout.WindowResized(1024, 1440);
Check(layout.LibraryAt(1440) == LibraryPresentation.Docked && layout.LibraryAt(1024) == LibraryPresentation.Hidden,
    "Crossing the compact breakpoint closes the transient drawer");
layout.ToggleInspector();
layout.SetMode(WorkspaceMode.Selection);
layout.SetMode(WorkspaceMode.Preview);
Check(layout.DismissTransient() && layout.Mode == WorkspaceMode.Selection && !layout.ShowsInspector(true),
    "Escape restores Select when Preview opened from Select");
layout.ToggleLibrary(1024);
layout.PhotoOpened();
Check(layout.Mode == WorkspaceMode.Editing && layout.LibraryAt(1024) == LibraryPresentation.Hidden && !layout.ShowsInspector(true),
    "Opening a photo from Select restores Edit with its independent inspector preference");

var marks = new WorkspacePhotoSelection();
string[] photos = ["a", "b", "c", "d"];
marks.Toggle("b", photos, false);
marks.Toggle("d", photos, true);
Check(marks.Marks.SetEquals(["b", "c", "d"]), "Shift extends the selection across one folder");
marks.BeforeOpening("d");
Check(marks.Marks.SetEquals(["b"]), "Double-click restores marks as they were before the first click");
marks.ForgetRange();
marks.Toggle("x", ["x","y"], true);
Check(marks.Marks.SetEquals(["b","x"]), "Folder changes preserve marked photos and start a new range");
marks.Remove(["b"]);
Check(marks.Marks.SetEquals(["x"]), "Transferring one photo leaves unaccepted selections available");
