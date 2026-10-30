using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;

namespace RawLab.Windows;

public partial class MainWindow
{
    private LookBrowserCategory lookCategory;
    private string lookQuery="";
    private RecentLooks recentLooks=new();
    private string recentLooksPath=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"RawLab","recent-looks.json");
    private bool updatingLookCategories;

    private string LookBrowserID(Film film)=>film.Path==null ? "" : IsBuiltInLook(film.Path)
        ? "builtin:"+Path.GetFileName(film.Path) : lookLibrary?.IdentityForPath(film.Path) ?? film.Path;
    private IEnumerable<Film> AvailableBrowserFilms()=>films.Where(film=>film.Path!=null && File.Exists(film.Path));
    private HashSet<string> AvailableBrowserIDs()=>AvailableBrowserFilms().Select(LookBrowserID).ToHashSet(StringComparer.Ordinal);
    private void LoadRecentLooks()
    {
        try {recentLooks=new(File.Exists(recentLooksPath) ? AtomicJson.Read<string[]>(recentLooksPath) : []);}
        catch(Exception error) when(error is IOException or UnauthorizedAccessException or JsonException){recentLooks=new();}
    }
    private void RecordRecentLook(string? before,string? after)
    {
        if(after==null || before==after)return;
        var available=AvailableBrowserIDs();
        if(!available.Contains(after))return;
        recentLooks.Record(after,available);
        try {AtomicJson.Write(recentLooksPath,recentLooks.IDs);}
        catch(Exception error) when(error is IOException or UnauthorizedAccessException){Debug.WriteLine(error);}
        if(lookCategory==LookBrowserCategory.Recent)BuildFilms();
    }
    private IReadOnlyList<Film> VisibleBrowserFilms()
    {
        var available=AvailableBrowserFilms().ToArray();
        recentLooks.Prune(available.Select(LookBrowserID).ToHashSet(StringComparer.Ordinal));
        var items=available.Select(film=>new LookBrowserItem(LookBrowserID(film),film.Name,film.Group,!IsBuiltInLook(film.Path!)));
        var ids=LookBrowser.Filter(items,lookCategory,lookQuery,recentLooks.IDs);
        var byID=available.GroupBy(LookBrowserID).ToDictionary(group=>group.Key,group=>group.First(),StringComparer.Ordinal);
        var visible=ids.Select(id=>byID[id]).ToList();
        if(lookCategory==LookBrowserCategory.All && string.IsNullOrWhiteSpace(lookQuery))visible.InsertRange(0,films.Where(film=>film.Path==null));
        return visible;
    }
    private void RefreshLookCategories()
    {
        updatingLookCategories=true;
        try {
            LookCategory.Items.Clear();
            foreach(var category in Enum.GetValues<LookBrowserCategory>())LookCategory.Items.Add(new ComboBoxItem{Content=Loc.Text(LookBrowser.Title(category)),Tag=category});
            LookCategory.SelectedIndex=(int)lookCategory;
        } finally {updatingLookCategories=false;}
    }
    private void LookCategoryChanged(object sender,SelectionChangedEventArgs e)
    {
        if(updatingLookCategories || LookCategory.SelectedItem is not ComboBoxItem{Tag:LookBrowserCategory category})return;
        lookCategory=category;BuildFilms();RefreshControls();
    }
    private void LookSearchChanged(object sender,TextChangedEventArgs e)
    {
        if(FilmStrip==null)return;
        lookQuery=LookSearch.Text;BuildFilms();RefreshControls();
    }
    private void ClearLookSearch(object sender,RoutedEventArgs e)
    {
        if(string.IsNullOrWhiteSpace(LookSearch.Text)){lookCategory=LookBrowserCategory.All;RefreshLookCategories();BuildFilms();RefreshControls();}
        else LookSearch.Clear();
    }
}
