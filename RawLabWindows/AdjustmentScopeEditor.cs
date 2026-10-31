using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace RawLab.Windows;

internal sealed class AdjustmentScopeEditor : Grid
{
    private readonly ComboBox scope = new() { MinWidth = 180, Margin = new Thickness(0, 4, 0, 12) };
    private readonly Dictionary<AdjustmentField, CheckBox> fields = [];
    private readonly bool hdr;
    private readonly Func<AdjustmentScope, AdjustmentPayload>? capture;
    private readonly Func<string, string, string?>? lookName;
    private readonly string prefix;
    private readonly StackPanel summary = new();
    private readonly Dictionary<AdjustmentField, TextBlock> values = [];
    private readonly Dictionary<string, (TextBlock Title, AdjustmentField[] Members)> groupTitles = [];
    private AdjustmentPayload? preview;
    internal event Action? SelectionChanged;
    internal bool IsCustom => scope.SelectedIndex == 3;
    internal bool HasSelection => capture != null ? preview != null : !IsCustom || fields.Values.Any(field => field.IsChecked == true);
    internal AdjustmentScope SelectedScope => scope.SelectedIndex switch {
        0 => hdr ? AdjustmentScope.Custom(AdjustmentFields.HDRCommon) : AdjustmentScope.Standard, 1 => AdjustmentScope.All, 2 => AdjustmentScope.Modified,
        _ => AdjustmentScope.Custom(fields.Where(pair => pair.Value.IsChecked == true).Select(pair => pair.Key))
    };

    internal AdjustmentScopeEditor(string prefix,bool hdr=false, Func<AdjustmentScope, AdjustmentPayload>? capture=null, Func<string, string, string?>? lookName=null)
    {
        this.hdr=hdr; this.capture=capture; this.lookName=lookName; this.prefix=prefix;
        RowDefinitions.Add(new() { Height = GridLength.Auto }); RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
        var heading = new StackPanel(); Children.Add(heading);
        foreach (var key in new[] { "默认范围", "全部调整", "仅已修改", "自定义" }) scope.Items.Add(Loc.Text(key));
        AutomationProperties.SetAutomationId(scope, prefix + ".scope"); heading.Children.Add(scope);
        if (capture == null) heading.Children.Add(AdjustmentDialogLayout.Text(Loc.Text("默认不包含几何与镜头。自定义可逐项选择。")));
        var content = new StackPanel();
        var clear = AdjustmentDialogLayout.Button("清空选择", prefix + ".clear", () => { foreach (var check in fields.Values) check.IsChecked = false; });
        clear.HorizontalAlignment = HorizontalAlignment.Left; content.Children.Add(clear);
        var allowed=hdr ? AdjustmentFields.HDRSupported : AdjustmentFields.All.ToHashSet();
        var defaults=hdr ? AdjustmentFields.HDRCommon : AdjustmentFields.Common;
        foreach (var group in allowed.OrderBy(field=>(int)field).GroupBy(field => field.IsHDRRelative() ? "color" : field.Group())) {
            var title = AdjustmentDialogLayout.Text(AdjustmentTransferPresentation.Group(group.Key));
            title.FontWeight = FontWeights.SemiBold; title.Margin = new Thickness(0, 14, 0, 6); content.Children.Add(title);
            var members = group.ToArray();
            groupTitles[group.Key] = (title, members);
            var select = AdjustmentDialogLayout.Button("选择此组", "adjustment.group." + group.Key, () => { foreach (var field in members) fields[field].IsChecked = true; });
            select.HorizontalAlignment = HorizontalAlignment.Left; content.Children.Add(select);
            var grid = new System.Windows.Controls.Primitives.UniformGrid { Columns = 2 }; content.Children.Add(grid);
            foreach (var field in group) {
                var label = new StackPanel();
                label.Children.Add(AdjustmentDialogLayout.Text(AdjustmentTransferPresentation.Title(field)));
                var detail = AdjustmentDialogLayout.Text(""); detail.Visibility = Visibility.Collapsed;
                AutomationProperties.SetAutomationId(detail, prefix + ".custom.value." + field.ID()); label.Children.Add(detail); values[field] = detail;
                var check = new CheckBox { Content = label,
                    IsChecked = defaults.Contains(field), Margin = new Thickness(0, 4, 12, 4) };
                AutomationProperties.SetName(check, AdjustmentTransferPresentation.Title(field));
                AutomationProperties.SetAutomationId(check, "adjustment.field." + field.ID());
                check.Checked += (_, _) => Changed(); check.Unchecked += (_, _) => Changed();
                fields[field] = check; grid.Children.Add(check);
            }
        }
        var body = new StackPanel(); body.Children.Add(summary); body.Children.Add(content);
        var scroll = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        SetRow(scroll, 1); Children.Add(scroll);
        scope.SelectionChanged += (_, _) => { content.Visibility = IsCustom ? Visibility.Visible : Visibility.Collapsed; Changed(); };
        scope.SelectedIndex = 0;
    }

    private void Changed()
    {
        summary.Children.Clear(); preview = null;
        if (capture != null) {
            try {
                preview = capture(SelectedScope);
                summary.Children.Add(AdjustmentSummaryView.Build(preview, lookName, prefix + ".summary", !IsCustom));
            } catch (Exception error) {
                var empty = error is AdjustmentTransferException { Failure: AdjustmentFailure.EmptyScope };
                var isModified = SelectedScope.Kind == "modified";
                var message = AdjustmentDialogLayout.Text(empty ? Loc.Text(isModified ? "尚无已修改的调整。" : "未选择任何调整。")
                    : AdjustmentTransferPresentation.Error(error));
                AutomationProperties.SetAutomationId(message, prefix + ".summary." + (empty ? "empty" : "error"));
                summary.Children.Add(message);
            }
        }
        var model = preview == null ? null : new AdjustmentSummary(preview);
        foreach (var pair in values) {
            var selected = preview?.Fields.Contains(pair.Key) == true;
            pair.Value.Text = selected ? model!.ValueText(pair.Key, lookName) : "";
            pair.Value.Visibility = selected ? Visibility.Visible : Visibility.Collapsed;
        }
        foreach (var pair in groupTitles)
            pair.Value.Title.Text = AdjustmentTransferPresentation.Group(pair.Key) + " · " +
                pair.Value.Members.Count(field => fields.TryGetValue(field, out var check) && check.IsChecked == true) + "/" + pair.Value.Members.Length;
        SelectionChanged?.Invoke();
    }
}
