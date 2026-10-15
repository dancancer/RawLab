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
    private void BuildMasterRecipes()
    {
        Add(null);
        foreach (var recipe in MasterRecipe.All) Add(recipe);
        void Add(MasterRecipe? recipe)
        {
            var content = new StackPanel { Width = 124, Margin = new Thickness(4, 0, 4, 0) };
            if (recipe != null) content.Children.Add(new Image { Source = new BitmapImage(new Uri(recipe.ArtworkPath)), Width = 64, Height = 64 });
            else content.Children.Add(new EditorIcon { Kind = "Neutral", Width = 32, Height = 64 });
            content.Children.Add(new TextBlock { Text = recipe?.Name ?? Loc.Text("无配方"), FontSize = 13*EditorAppearance.TextScale, MinHeight = 20, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center });
            content.Children.Add(new TextBlock { Text = Loc.Text(recipe?.Subtitle ?? "中性直出"), FontSize = 11*EditorAppearance.TextScale, MinHeight = 32,
                Foreground = (Brush)FindResource("Muted"), TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center });
            var button = new Button { Content = content, Style = (Style)FindResource("QuietButton"), Padding = new Thickness(0),
                Background = Brushes.Transparent, BorderThickness = new Thickness(0), ToolTip = Loc.Text(recipe?.Summary ?? "中性直出") };
            AutomationProperties.SetName(button, recipe?.Name ?? Loc.Text("无配方"));
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
        choosingRecipes = true; choosingFilm = choosingDenoise = choosingPhotoEffects = choosingHsl = choosingLens = choosingGeometry = false; RefreshControls();
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
