using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace RawLab.Windows;

internal static class AdjustmentSummaryView
{
    internal static FrameworkElement Build(AdjustmentPayload payload, Func<string, string, string?>? lookName,
        string identifier = "adjustment.summary", bool showGroups = true)
    {
        var model = new AdjustmentSummary(payload);
        var root = new StackPanel { Margin = new Thickness(0, 8, 0, 12) };
        var count = AdjustmentDialogLayout.Text(Loc.Format("将覆盖以下 {0} 项调整；其他调整保留目标原值。", model.Count));
        AutomationProperties.SetAutomationId(count, identifier + ".count"); root.Children.Add(count);
        if (payload.Source.IsHDR) root.Children.Add(AdjustmentDialogLayout.Text("HDR · " + Loc.Text("相对白平衡")));
        root.Children.Add(AdjustmentDialogLayout.Text(Loc.Text(model.IncludesGeometry ? "包含几何或镜头调整。" : "未包含几何与镜头。")));
        if (model.RecipeNote is { } note) root.Children.Add(AdjustmentDialogLayout.Text(note));
        if (!showGroups) return root;
        foreach (var group in model.Groups) {
            var rows = new StackPanel { Margin = new Thickness(16, 4, 0, 8) };
            foreach (var field in group.Fields) {
                var title = AdjustmentDialogLayout.Text(AdjustmentTransferPresentation.Title(field));
                title.FontWeight = FontWeights.SemiBold; title.Margin = new Thickness(0, 6, 0, 2); rows.Children.Add(title);
                var value = AdjustmentDialogLayout.Text(model.ValueText(field, lookName));
                AutomationProperties.SetAutomationId(value, identifier + ".value." + field.ID()); rows.Children.Add(value);
            }
            var section = new Expander {
                Header = AdjustmentDialogLayout.Text(AdjustmentTransferPresentation.Group(group.ID) + " · " + group.Fields.Count),
                Content = rows, Margin = new Thickness(0, 4, 0, 4)
            };
            AutomationProperties.SetAutomationId(section, identifier + ".group." + group.ID); root.Children.Add(section);
        }
        return root;
    }
}
