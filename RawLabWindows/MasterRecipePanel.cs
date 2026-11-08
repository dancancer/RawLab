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
    private bool choosingRecipes;
    private readonly Dictionary<string, Button> recipeButtons = new();
    private readonly Dictionary<string,TextBlock> recipeSelectionMarkers=new();
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
            var content = new StackPanel { Margin = new Thickness(4, 5, 4, 5) };
            if (recipe != null) content.Children.Add(new Image { Source = new BitmapImage(new Uri(recipe.ArtworkPath)), Width = 64, Height = 64 });
            else content.Children.Add(new EditorIcon { Kind = "Neutral", Width = 32, Height = 64 });
            var title=new TextBlock { Text = Loc.Text(recipe?.Name ?? "无配方"), MinHeight = 20, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center };
            title.SetResourceReference(TextBlock.FontSizeProperty,"EditorBodySize");content.Children.Add(title);
            var caption=new TextBlock { Text = Loc.Text(recipe?.Subtitle ?? "中性直出"), MinHeight = 32, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center };
            caption.SetResourceReference(TextBlock.FontSizeProperty,"EditorCaptionSize");content.Children.Add(caption);
            var marker=new TextBlock{Text="✓",FontSize=16,FontWeight=FontWeights.Bold,HorizontalAlignment=HorizontalAlignment.Right,
                VerticalAlignment=VerticalAlignment.Top,Visibility=Visibility.Hidden,IsHitTestVisible=false};
            marker.SetResourceReference(TextBlock.ForegroundProperty,"Accent");
            var card=new Grid();card.Children.Add(content);card.Children.Add(marker);
            var button = new Button { Content = card, Style = (Style)FindResource("QuietButton"), Padding = new Thickness(0),
                BorderThickness = new Thickness(0), HorizontalContentAlignment = HorizontalAlignment.Stretch, ToolTip = Loc.Text(recipe?.Summary ?? "中性直出") };
            recipeSelectionMarkers[recipe?.Id ?? ""]=marker;
            AutomationProperties.SetAutomationId(button,"recipe."+(recipe?.Id ?? "neutral"));
            AutomationProperties.SetName(button, Loc.Text(recipe?.Name ?? "无配方"));
            button.Click += (_, _) => {
                if (exporting || !ResolveTransformDraft()) return;
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
