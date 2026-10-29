using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace RawLab.Windows;

internal sealed class AdjustmentScopeEditor : Grid
{
    private readonly ComboBox scope = new() { MinWidth = 180, Margin = new Thickness(0, 4, 0, 12) };
    private readonly Dictionary<AdjustmentField, CheckBox> fields = [];
    private readonly bool hdr;
    internal event Action? SelectionChanged;
    internal bool IsCustom => scope.SelectedIndex == 3;
    internal bool HasSelection => !IsCustom || fields.Values.Any(field => field.IsChecked == true);
    internal AdjustmentScope SelectedScope => scope.SelectedIndex switch {
        0 => hdr ? AdjustmentScope.Custom(AdjustmentFields.HDRCommon) : AdjustmentScope.Standard, 1 => AdjustmentScope.All, 2 => AdjustmentScope.Modified,
        _ => AdjustmentScope.Custom(fields.Where(pair => pair.Value.IsChecked == true).Select(pair => pair.Key))
    };

    internal AdjustmentScopeEditor(string prefix,bool hdr=false)
    {
        this.hdr=hdr;
        RowDefinitions.Add(new() { Height = GridLength.Auto }); RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
        var heading = new StackPanel(); Children.Add(heading);
        foreach (var key in new[] { "默认范围", "全部调整", "仅已修改", "自定义" }) scope.Items.Add(Loc.Text(key));
        AutomationProperties.SetAutomationId(scope, prefix + ".scope"); heading.Children.Add(scope);
        heading.Children.Add(AdjustmentDialogLayout.Text(Loc.Text("默认不包含几何与镜头。自定义可逐项选择。")));
        var content = new StackPanel();
        var clear = AdjustmentDialogLayout.Button("清空选择", prefix + ".clear", () => { foreach (var check in fields.Values) check.IsChecked = false; });
        clear.HorizontalAlignment = HorizontalAlignment.Left; content.Children.Add(clear);
        var allowed=hdr ? AdjustmentFields.HDRSupported : AdjustmentFields.All.ToHashSet();
        var defaults=hdr ? AdjustmentFields.HDRCommon : AdjustmentFields.Common;
        foreach (var group in allowed.OrderBy(field=>(int)field).GroupBy(field => field.IsHDRRelative() ? "color" : field.Group())) {
            var title = AdjustmentDialogLayout.Text(AdjustmentTransferPresentation.Group(group.Key));
            title.FontWeight = FontWeights.SemiBold; title.Margin = new Thickness(0, 14, 0, 6); content.Children.Add(title);
            var members = group.ToArray();
            var select = AdjustmentDialogLayout.Button("选择此组", "adjustment.group." + group.Key, () => { foreach (var field in members) fields[field].IsChecked = true; });
            select.HorizontalAlignment = HorizontalAlignment.Left; content.Children.Add(select);
            var grid = new System.Windows.Controls.Primitives.UniformGrid { Columns = 2 }; content.Children.Add(grid);
            foreach (var field in group) {
                var check = new CheckBox { Content = new TextBlock { Text = AdjustmentTransferPresentation.Title(field), TextWrapping = TextWrapping.Wrap },
                    IsChecked = defaults.Contains(field), Margin = new Thickness(0, 4, 12, 4) };
                AutomationProperties.SetName(check, AdjustmentTransferPresentation.Title(field));
                AutomationProperties.SetAutomationId(check, "adjustment.field." + field.ID());
                check.Checked += (_, _) => SelectionChanged?.Invoke(); check.Unchecked += (_, _) => SelectionChanged?.Invoke();
                fields[field] = check; grid.Children.Add(check);
            }
        }
        var scroll = new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        SetRow(scroll, 1); Children.Add(scroll);
        scope.SelectionChanged += (_, _) => { scroll.Visibility = IsCustom ? Visibility.Visible : Visibility.Collapsed; SelectionChanged?.Invoke(); };
        scope.SelectedIndex = 0;
    }
}
