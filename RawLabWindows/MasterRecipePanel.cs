using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace RawLab.Windows;

public partial class MainWindow
{
    private bool choosingRecipes;
    private readonly Dictionary<string, Button> recipeButtons = new();
    // ┌─ 当前外观的显示名：标题栏、对比标签、批量任务和导出文件名共用 ─────────────┐
    // │ 大师配方与“中性”按界面语言显示；胶片和导入外观用自己的名字                    │
    // └────────────────────────────────────────────────────────────────────────────┘
    private string LookTitle => settings.Recipe is { } recipe ? Loc.Text(recipe.Name)
        : lut == null ? Loc.Text("中性") : films.FirstOrDefault(film => film.Path == lut)?.Name ?? Path.GetFileNameWithoutExtension(lut);
    private void BuildMasterRecipes()
    {
        Add(null);
        foreach (var recipe in MasterRecipe.All) Add(recipe);
        void Add(MasterRecipe? recipe)
        {
            var content = new StackPanel { Width = 124, Margin = new Thickness(4, 0, 4, 0) };
            if (recipe != null) content.Children.Add(new Image { Source = new BitmapImage(new Uri(recipe.ArtworkPath)), Width = 64, Height = 64 });
            else content.Children.Add(new EditorIcon { Kind = "Neutral", Width = 32, Height = 64 });
            var title=new TextBlock { Text = Loc.Text(recipe?.Name ?? "无配方"), MinHeight = 20, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center };
            title.SetResourceReference(TextBlock.FontSizeProperty,"EditorBodySize");content.Children.Add(title);
            var caption=new TextBlock { Text = Loc.Text(recipe?.Subtitle ?? "中性直出"), MinHeight = 32, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center };
            caption.SetResourceReference(TextBlock.FontSizeProperty,"EditorCaptionSize");content.Children.Add(caption);
            var button = new Button { Content = content, Style = (Style)FindResource("QuietButton"), Padding = new Thickness(0),
                BorderThickness = new Thickness(0), ToolTip = Loc.Text(recipe?.Summary ?? "中性直出") };
            AutomationProperties.SetName(button, Loc.Text(recipe?.Name ?? "无配方"));
            button.Click += (_, _) => {
                if (exporting || !ResolveTransformDraft()) return;
                if (recipe != null) { settings.ApplyMasterRecipe(recipe); lut = recipe.LutPath; }
                else { settings.ClearMasterRecipe(); lut = null; }
                MarkEdited(); RefreshControls(); Schedule();
            };
            RecipeStrip.Children.Add(button); recipeButtons[recipe?.Id ?? ""] = button;
        }
    }
    private void MasterRecipeCategoryClicked(object sender, RoutedEventArgs e)
    {
        if(!ResolveTransformDraft())return;
        choosingRecipes = true; choosingFilm = choosingDenoise = choosingPhotoEffects = choosingHsl = choosingWhiteBalance = choosingLens = choosingGeometry = false; RefreshControls();
    }
    private void RecipeScrollLeftClicked(object sender, RoutedEventArgs e) => RecipeScroller.ScrollToHorizontalOffset(RecipeScroller.HorizontalOffset - RecipeScroller.ViewportWidth * .8);
    private void RecipeScrollRightClicked(object sender, RoutedEventArgs e) => RecipeScroller.ScrollToHorizontalOffset(RecipeScroller.HorizontalOffset + RecipeScroller.ViewportWidth * .8);
    private void RecipeScrollChanged(object sender, ScrollChangedEventArgs e) => UpdateScrollButtons(RecipeScroller, RecipeScrollLeft, RecipeScrollRight);
    private void FilmScrollLeftClicked(object sender, RoutedEventArgs e) => FilmScroller.ScrollToHorizontalOffset(FilmScroller.HorizontalOffset - FilmScroller.ViewportWidth * .8);
    private void FilmScrollRightClicked(object sender, RoutedEventArgs e) => FilmScroller.ScrollToHorizontalOffset(FilmScroller.HorizontalOffset + FilmScroller.ViewportWidth * .8);
    private void FilmScrollChanged(object sender, ScrollChangedEventArgs e) => UpdateScrollButtons(FilmScroller, FilmScrollLeft, FilmScrollRight);
    private static void UpdateScrollButtons(ScrollViewer scroller, Button left, Button right)
    {
        var fullWidth = scroller.ViewportWidth + left.ActualWidth + right.ActualWidth;
        var overflow = scroller.ExtentWidth > fullWidth + 1;
        left.Visibility = right.Visibility = overflow ? Visibility.Visible : Visibility.Collapsed;
        left.IsEnabled = scroller.HorizontalOffset > 1;
        right.IsEnabled = scroller.HorizontalOffset < scroller.ScrollableWidth - 1;
    }
}
