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
