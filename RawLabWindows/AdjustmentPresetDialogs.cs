using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace RawLab.Windows;

internal static class AdjustmentPresetPresentation
{
    internal static string Error(Exception error) => error is AdjustmentPresetException preset ? Loc.Text(preset.Reason switch {
        PresetFailure.EmptyName => "请输入预设名称。", PresetFailure.DuplicateName => "同名预设已存在，请使用其他名称。",
        PresetFailure.Changed => "预设已变化，请重新载入列表后重试。",
        PresetFailure.CorruptLibrary => "预设库无法读取，原文件保持不变。请从备份恢复后重试。",
        PresetFailure.UnsupportedVersion => "此预设库来自更新版本，请更新应用后重试。",
        _ => "无法创建新的预设标识，请重试。"
    }) : error is AdjustmentTransferException or EditPersistenceConflict ? AdjustmentTransferPresentation.Error(error)
        : Loc.Format("预设操作未完成：{0}", error.Message);

    internal static Button Button(string key, string id, Action action)
    {
        var button = AdjustmentDialogLayout.Button(key, id, action);
        button.Content = new TextBlock { Text = Loc.Text(key), TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center };
        AutomationProperties.SetName(button, Loc.Text(key)); button.MaxWidth = 540; return button;
    }
}

internal sealed class AdjustmentPresetNameDialog : Window
{
    private readonly TextBox name = new() { Margin = new Thickness(0, 4, 0, 12) };
    internal AdjustmentPresetNameDialog(Window owner, string title, string initialName, bool includeScope,
        Func<string, AdjustmentScope, string?> save)
    {
        var root = AdjustmentDialogLayout.Configure(this, owner, title, "preset.name-dialog");
        var heading = new StackPanel(); root.Children.Add(heading);
        heading.Children.Add(AdjustmentDialogLayout.Text(Loc.Text("预设名称")));
        name.Text = initialName; AutomationProperties.SetAutomationId(name, "preset.name");
        AutomationProperties.SetName(name, Loc.Text("预设名称")); heading.Children.Add(name);
        var scope = new AdjustmentScopeEditor("preset.save"); Grid.SetRow(scope, 1); root.Children.Add(scope);
        scope.Visibility = includeScope ? Visibility.Visible : Visibility.Collapsed;
        var footer = new StackPanel { Margin = new Thickness(0, 12, 0, 0) }; Grid.SetRow(footer, 2); root.Children.Add(footer);
        var error = AdjustmentDialogLayout.Text(""); error.SetResourceReference(TextBlock.ForegroundProperty, "ErrorForeground");
        AutomationProperties.SetAutomationId(error, "preset.error"); footer.Children.Add(error);
        var actions = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right }; footer.Children.Add(actions);
        var cancel = AdjustmentPresetPresentation.Button("取消", "preset.cancel", Close); cancel.IsCancel = true; actions.Children.Add(cancel);
        var confirm = AdjustmentPresetPresentation.Button(includeScope ? "保存预设" : "重命名", "preset.save.confirm", () => {
            try { error.Text = save(name.Text, scope.SelectedScope) ?? ""; }
            catch (Exception failure) { error.Text = AdjustmentPresetPresentation.Error(failure); }
            if (error.Text.Length == 0) DialogResult = true;
        });
        confirm.IsDefault = true; actions.Children.Add(confirm);
        void Update() {
            confirm.IsEnabled = AdjustmentPreset.NormalizeName(name.Text).Length > 0 && (!includeScope || scope.HasSelection);
            Height = includeScope ? scope.IsCustom ? 720 : 420 : 300;
        }
        name.TextChanged += (_, _) => Update(); scope.SelectionChanged += Update; Update();
        Loaded += (_, _) => { name.Focus(); name.SelectAll(); };
    }
}

internal enum PresetConfirmationChoice { Cancel, Confirm, SaveAs }
internal sealed class AdjustmentPresetConfirmationDialog : Window
{
    internal PresetConfirmationChoice Choice { get; private set; }
    internal AdjustmentPresetConfirmationDialog(Window owner, AdjustmentPreset preset, bool overwrite)
    {
        var root = AdjustmentDialogLayout.Configure(this, owner, overwrite ? "覆盖预设？" : "删除预设？", "preset.confirmation");
        Height = 300; MinHeight = 240;
        var text = AdjustmentDialogLayout.Text(preset.Name); text.FontWeight = FontWeights.SemiBold; root.Children.Add(text);
        var actions = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right }; Grid.SetRow(actions, 2); root.Children.Add(actions);
        var cancel = AdjustmentPresetPresentation.Button("取消", "preset.confirm.cancel", Close); cancel.IsCancel = true; actions.Children.Add(cancel);
        if (overwrite) actions.Children.Add(AdjustmentPresetPresentation.Button("另存", "preset.confirm.save-as", () => { Choice = PresetConfirmationChoice.SaveAs; DialogResult = false; }));
        var confirm = AdjustmentPresetPresentation.Button(overwrite ? "覆盖" : "删除", "preset.confirm.commit", () => { Choice = PresetConfirmationChoice.Confirm; DialogResult = true; });
        confirm.IsDefault = true; actions.Children.Add(confirm);
    }
}

internal sealed class AdjustmentPresetLibraryDialog : Window
{
    internal bool SaveRequested { get; private set; }
    internal AdjustmentPreset? ApplyRequested { get; private set; }
    private readonly AdjustmentPresetStore store;
    private readonly StackPanel rows = new();
    private readonly TextBlock error = AdjustmentDialogLayout.Text("");
    private readonly Button create;
    private readonly bool canUsePhoto;

    internal AdjustmentPresetLibraryDialog(Window owner, AdjustmentPresetStore store, bool canUsePhoto)
    {
        this.store = store; this.canUsePhoto = canUsePhoto;
        var root = AdjustmentDialogLayout.Configure(this, owner, "我的预设", "preset.library");
        var heading = new StackPanel(); root.Children.Add(heading);
        create = AdjustmentPresetPresentation.Button("保存当前调整为预设…", "preset.create", () => { SaveRequested = true; DialogResult = true; });
        create.HorizontalAlignment = HorizontalAlignment.Left; create.Margin = new Thickness(0, 0, 0, 12); heading.Children.Add(create);
        error.SetResourceReference(TextBlock.ForegroundProperty, "ErrorForeground"); AutomationProperties.SetAutomationId(error, "preset.error"); heading.Children.Add(error);
        var scroll = new ScrollViewer { Content = rows, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }; Grid.SetRow(scroll, 1); root.Children.Add(scroll);
        var actions = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
        actions.Children.Add(AdjustmentPresetPresentation.Button("重新载入", "preset.reload", Reload));
        var close = AdjustmentPresetPresentation.Button("关闭", "preset.close", Close); close.IsCancel = true; actions.Children.Add(close);
        Grid.SetRow(actions, 2); root.Children.Add(actions); Reload();
    }
    private void Reload()
    {
        rows.Children.Clear(); error.Text = "";
        try {
            var presets = store.List(); create.IsEnabled = canUsePhoto;
            if (presets.Count == 0) {
                rows.Children.Add(AdjustmentDialogLayout.Text(Loc.Text("尚无用户预设")));
                rows.Children.Add(AdjustmentDialogLayout.Text(Loc.Text("保存所选调整，之后可应用到其他照片。")));
            }
            foreach (var preset in presets) {
                var row = new StackPanel { Margin = new Thickness(0, 8, 0, 14) }; rows.Children.Add(row);
                var title = AdjustmentDialogLayout.Text(preset.Name); title.FontWeight = FontWeights.SemiBold; row.Children.Add(title);
                AutomationProperties.SetAutomationId(row, "preset.row." + preset.ID);
                row.Children.Add(AdjustmentDialogLayout.Text(Loc.Format("已选 {0} 项", preset.Payload.Fields.Count)));
                var actions = new WrapPanel(); row.Children.Add(actions);
                var apply = AdjustmentPresetPresentation.Button("应用预设", "preset.apply." + preset.ID, () => { ApplyRequested = preset; DialogResult = true; });
                apply.IsEnabled = canUsePhoto; actions.Children.Add(apply);
                actions.Children.Add(AdjustmentPresetPresentation.Button("重命名", "preset.rename." + preset.ID, () => {
                    new AdjustmentPresetNameDialog(this, "重命名预设", preset.Name, false, (name, _) => { store.Rename(preset, name); return null; }).ShowDialog();
                    Reload();
                }));
                actions.Children.Add(AdjustmentPresetPresentation.Button("删除", "preset.delete." + preset.ID, () => {
                    if (new AdjustmentPresetConfirmationDialog(this, preset, false).ShowDialog() != true) return;
                    try { store.Delete(preset); Reload(); } catch (Exception failure) { error.Text = AdjustmentPresetPresentation.Error(failure); }
                }));
                rows.Children.Add(new Separator());
            }
        } catch (Exception failure) { create.IsEnabled = false; error.Text = AdjustmentPresetPresentation.Error(failure); }
    }
}
