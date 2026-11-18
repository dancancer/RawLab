using System.Globalization;
using System.Text;

namespace RawLab.Windows;

internal enum LookBrowserCategory { All, Fuji, Kodak, Other, Custom, Recent }
internal sealed record LookBrowserItem(string ID,string Name,FilmGroup Group,bool IsCustom);

internal static class LookBrowser
{
    internal static string Title(LookBrowserCategory category)=>category switch {
        LookBrowserCategory.All=>"全部外观",LookBrowserCategory.Fuji=>"Fuji",LookBrowserCategory.Kodak=>"Kodak",
        LookBrowserCategory.Other=>"其他",LookBrowserCategory.Custom=>"用户外观",_=>"最近使用"
    };
    internal static IReadOnlyList<string> Filter(IEnumerable<LookBrowserItem> items,LookBrowserCategory category,string query,IReadOnlyList<string> recent)
    {
        var term=Normalize(query.Trim());
        var matching=items.Where(item=>(term.Length==0 || Normalize(item.Name).Contains(term,StringComparison.Ordinal)) && (category switch {
            LookBrowserCategory.Fuji=>!item.IsCustom && item.Group==FilmGroup.Fuji,
            LookBrowserCategory.Kodak=>!item.IsCustom && item.Group==FilmGroup.Kodak,
            LookBrowserCategory.Other=>item.Group==FilmGroup.Other,
            LookBrowserCategory.Custom=>item.IsCustom,_=>true
        })).Select(item=>item.ID).ToArray();
        return category==LookBrowserCategory.Recent ? recent.Where(matching.Contains).ToArray() : matching;
    }
    private static string Normalize(string value)=>new string(value.Normalize(NormalizationForm.FormD)
        .Where(c=>CharUnicodeInfo.GetUnicodeCategory(c)!=UnicodeCategory.NonSpacingMark).ToArray()).ToUpperInvariant();
}

internal sealed class RecentLooks(IEnumerable<string>? ids=null)
{
    internal IReadOnlyList<string> IDs {get;private set;}=(ids ?? []).Where(id=>!string.IsNullOrEmpty(id)).Distinct(StringComparer.Ordinal).Take(12).ToArray();
    internal void Record(string id,ISet<string> available)
    {
        if(string.IsNullOrEmpty(id) || !available.Contains(id))return;
        IDs=new[]{id}.Concat(IDs.Where(value=>value!=id && available.Contains(value))).Take(12).ToArray();
    }
    internal void Prune(ISet<string> available)=>IDs=IDs.Where(available.Contains).ToArray();
}
