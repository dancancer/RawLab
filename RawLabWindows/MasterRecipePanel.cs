using System.Globalization;
using System.IO;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace RawLab.Windows;

public partial class MainWindow
{
    private readonly Dictionary<string, Button> recipeButtons = new();
    // ┌─ 当前外观的显示名：标题栏、对比标签、批量任务和导出文件名共用 ─────────────┐
    // │ 大师配方与“中性”按界面语言显示；胶片和导入外观用自己的名字                    │
    // └────────────────────────────────────────────────────────────────────────────┘
    private string LookTitle => settings.HDR is { Mode: HDRMode.Hdr } hdr ? hdr.LookSettings.Name ?? Loc.Text("中性")
        : settings.Recipe is { } recipe ? Loc.Text(recipe.Name)
        : lut == null ? Loc.Text("中性") : films.FirstOrDefault(film => film.Path == lut)?.Name ?? Path.GetFileNameWithoutExtension(lut);
    private void BuildMasterRecipes()
    {
        Add(null);
        foreach (var recipe in MasterRecipe.All) Add(recipe);
        void Add(MasterRecipe? recipe)
        {
            var content = new StackPanel();
            var artwork = new Grid { Width = 46, Height = 46 };
            if (recipe != null && File.Exists(recipe.ArtworkPath)) artwork.Children.Add(new Image { Source = new BitmapImage(new Uri(recipe.ArtworkPath)), Width = 46, Height = 46 });
            else artwork.Children.Add(new EditorIcon { Kind = recipe == null ? "Neutral" : "Photo", Width = 28, Height = 46 });
            content.Children.Add(artwork);
            var title = new TextBlock { Text = Loc.Text(recipe?.Name ?? "无配方"), FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, Margin = new Thickness(0, 5, 0, 0) };
            title.SetResourceReference(TextBlock.FontSizeProperty, "EditorCaptionSize"); content.Children.Add(title);
            var caption = new TextBlock { Text = Loc.Text(recipe?.Subtitle ?? "中性直出"), MinHeight = 28, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, Margin = new Thickness(0, 2, 0, 0) };
            caption.SetResourceReference(TextBlock.FontSizeProperty, "EditorCaptionSize"); content.Children.Add(caption);
            var button = new Button
            {
                Content = content,
                Style = (Style)FindResource("QuietButton"),
                Padding = new Thickness(3, 5, 3, 5),
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                VerticalContentAlignment = VerticalAlignment.Top,
                ToolTip = recipe == null ? Loc.Text("中性直出") : $"{Loc.Text(recipe.Name)} · {Loc.Text(recipe.Summary)}"
            };
            AutomationProperties.SetAutomationId(button,"recipe."+(recipe?.Id ?? "neutral"));
            AutomationProperties.SetName(button, Loc.Text(recipe?.Name ?? "无配方"));
            button.Click += (_, _) => {
                if (exporting || !ResolveTransformDraft() || (recipe == null && settings.MasterRecipeID == null)) return;
                if (recipe != null) { settings.ApplyMasterRecipe(recipe); lut = recipe.LutPath; }
                else {
                    try { settings.ClearMasterRecipe(file == null || PhotoInput.IsRaw(file)); }
                    catch (Exception error) { Report(error); return; }
                    lut = null;
                }
                MarkEdited(); RefreshControls(); Schedule();
            };
            RecipeStrip.Children.Add(button); recipeButtons[recipe?.Id ?? ""] = button;
        }
    }
    private void MasterRecipeCategoryClicked(object sender, RoutedEventArgs e) => SelectTool(EditorAdjustmentTool.MasterRecipe);
}
