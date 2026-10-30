using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace RawLab.Windows;

internal enum QuickPresetPhase { Idle, Preparing, Saved, Unchanged, Undone, Failed, UndoFailed }
internal sealed record QuickPresetState(QuickPresetPhase Phase = QuickPresetPhase.Idle,
    AdjustmentPreset? Preset = null, Guid? Transaction = null, string? Message = null);

internal static class QuickPresetView
{
    internal static FrameworkElement Build(IReadOnlyList<AdjustmentPreset> presets, string? libraryError, QuickPresetState state,
        Func<string, string, string?> lookName, Action manage, Action create, Action reload, Action<AdjustmentPreset> apply,
        Action<AdjustmentPreset> multiple, Action undo, Action cancel, bool needsReload, Action reloadPhoto)
    {
        var root = new StackPanel { Margin = new Thickness(2, 4, 2, 4) };
        var busy = state.Phase == QuickPresetPhase.Preparing;
        var actions = new WrapPanel(); root.Children.Add(actions);
        var manageButton = Button("管理预设", "preset.quick.manage", manage); manageButton.IsEnabled = !busy; actions.Children.Add(manageButton);
        var saveButton = Button("保存当前调整为预设…", "preset.quick.create", create); saveButton.IsEnabled = !busy && libraryError == null; actions.Children.Add(saveButton);
        if (state.Preset is { } current) {
            var status = state.Phase switch {
                QuickPresetPhase.Preparing => Loc.Text("正在检查预设…"), QuickPresetPhase.Saved => Loc.Text("已保存"),
                QuickPresetPhase.Unchanged => Loc.Text("未变化"), QuickPresetPhase.Undone => Loc.Text("已撤销"),
                _ => state.Message
            };
            if (status != null) {
                var text = Text(current.Name + " · " + status); AutomationProperties.SetAutomationId(text, "preset.quick.status"); root.Children.Add(text);
            }
            var resultActions = new WrapPanel(); root.Children.Add(resultActions);
            if (state.Phase == QuickPresetPhase.Preparing) resultActions.Children.Add(Button("取消", "preset.quick.cancel", cancel));
            if (state.Phase == QuickPresetPhase.Saved) resultActions.Children.Add(Button("撤销", "preset.quick.undo", undo));
            if (state.Phase is QuickPresetPhase.Failed or QuickPresetPhase.UndoFailed) {
                if (needsReload) resultActions.Children.Add(Button("重新载入已保存调整", "preset.quick.reloadPhoto", reloadPhoto));
                resultActions.Children.Add(Button("重试", "preset.quick.retry", () => { if (state.Phase == QuickPresetPhase.UndoFailed) undo(); else apply(current); }));
                resultActions.Children.Add(Button("取消", "preset.quick.cancel", cancel));
            }
        }
        if (libraryError != null) {
            var error = Text(libraryError); AutomationProperties.SetAutomationId(error, "preset.quick.libraryError"); root.Children.Add(error);
            root.Children.Add(Button("重新载入", "preset.quick.reload", reload)); return root;
        }
        if (presets.Count == 0) {
            var empty = Text(Loc.Text("尚无用户预设")); AutomationProperties.SetAutomationId(empty, "preset.quick.empty"); root.Children.Add(empty);
            root.Children.Add(Text(Loc.Text("保存所选调整，之后可应用到其他照片。")));
        }
        foreach (var preset in presets) {
            var row = new StackPanel { Margin = new Thickness(0, 10, 0, 8) }; root.Children.Add(row);
            var title = Text(preset.Name); title.FontWeight = FontWeights.SemiBold;
            AutomationProperties.SetAutomationId(title, "preset.quick.name." + preset.ID); row.Children.Add(title);
            row.Children.Add(Text(string.Join(" / ", new AdjustmentSummary(preset.Payload).Groups.Select(group =>
                AdjustmentTransferPresentation.Group(group.ID) + " · " + group.Fields.Count))));
            var rowActions = new WrapPanel(); row.Children.Add(rowActions);
            var applyButton = Button("应用到当前照片", "preset.quick.apply." + preset.ID, () => apply(preset)); applyButton.IsEnabled = !busy; rowActions.Children.Add(applyButton);
            var more = Button("更多", "preset.quick.more." + preset.ID, () => { });
            var menu = new ContextMenu(); var multi = new MenuItem { Header = Loc.Text("应用到多张照片") };
            AutomationProperties.SetAutomationId(multi, "preset.quick.multiple." + preset.ID); multi.Click += (_, _) => multiple(preset);
            menu.Items.Add(multi); more.ContextMenu = menu; more.Click += (_, _) => { menu.PlacementTarget = more; menu.IsOpen = true; };
            more.IsEnabled = !busy; rowActions.Children.Add(more);
            var detail = new Expander { Header = Text(Loc.Text("查看调整范围")),
                Content = AdjustmentSummaryView.Build(preset.Payload, lookName, "preset.quick.summary." + preset.ID) };
            AutomationProperties.SetAutomationId(detail, "preset.quick.details." + preset.ID); row.Children.Add(detail);
            root.Children.Add(new Separator());
        }
        return root;
    }
    private static TextBlock Text(string value) => new() { Text = value, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(2, 4, 2, 4) };
    private static Button Button(string key, string id, Action action) => AdjustmentPresetPresentation.Button(key, id, action);
}
