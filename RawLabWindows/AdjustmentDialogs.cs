using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;

namespace RawLab.Windows;

internal static class AdjustmentDialogLayout
{
    internal static Grid Configure(Window dialog,Window owner,string title,string id)
    {
        dialog.Owner=owner;dialog.Title=Loc.Text(title);dialog.Width=680;dialog.Height=660;dialog.MinWidth=480;dialog.MinHeight=360;
        dialog.MaxHeight=SystemParameters.WorkArea.Height-40;dialog.ShowInTaskbar=false;dialog.WindowStartupLocation=WindowStartupLocation.CenterOwner;
        dialog.SetResourceReference(Window.StyleProperty,typeof(Window));AutomationProperties.SetAutomationId(dialog,id);
        KeyboardNavigation.SetTabNavigation(dialog,KeyboardNavigationMode.Cycle);
        var root=new Grid{Margin=new Thickness(24)};
        root.RowDefinitions.Add(new(){Height=GridLength.Auto});root.RowDefinitions.Add(new(){Height=new(1,GridUnitType.Star)});root.RowDefinitions.Add(new(){Height=GridLength.Auto});
        dialog.Content=root;return root;
    }
    internal static TextBlock Text(string value)=>new(){Text=value,TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,0,0,8)};
    internal static Button Button(string key,string id,Action action)
    {
        var button=new Button{Content=Loc.Text(key),Margin=new Thickness(8,0,0,0),MinWidth=88};
        AutomationProperties.SetAutomationId(button,id);button.Click+=(_,_)=>action();return button;
    }
}

internal sealed class AdjustmentScopeDialog : Window
{
    private readonly AdjustmentScopeEditor editor = new("adjustment.copy");
    internal AdjustmentScope SelectedScope => editor.SelectedScope;
    internal AdjustmentScopeDialog(Window owner, string source, Func<AdjustmentScope, string?> copy, string title = "复制调整", string confirmTitle = "复制调整")
    {
        var root = AdjustmentDialogLayout.Configure(this, owner, title, "adjustment.copy");
        root.Children.Add(AdjustmentDialogLayout.Text(Path.GetFileName(source)));
        Grid.SetRow(editor, 1); root.Children.Add(editor);
        var footer = new StackPanel { Margin = new Thickness(0, 12, 0, 0) };
        var error = AdjustmentDialogLayout.Text(""); error.SetResourceReference(TextBlock.ForegroundProperty, "ErrorForeground"); footer.Children.Add(error);
        var actions = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right }; footer.Children.Add(actions);
        var cancel = AdjustmentDialogLayout.Button("取消", "adjustment.cancel", Close); cancel.IsCancel = true; actions.Children.Add(cancel);
        var confirm = AdjustmentDialogLayout.Button(confirmTitle, "adjustment.copy.confirm", () => {
            error.Text = copy(SelectedScope) ?? ""; if (error.Text.Length == 0) DialogResult = true;
        });
        confirm.IsDefault = true; actions.Children.Add(confirm); Grid.SetRow(footer, 2); root.Children.Add(footer);
        void Update() { Height = editor.IsCustom ? 660 : 340; confirm.IsEnabled = editor.HasSelection; }
        editor.SelectionChanged += Update; Update();
    }
}

internal sealed class AdjustmentResultDialog : Window
{
    private readonly StackPanel rows=new();
    private readonly TextBlock summary=AdjustmentDialogLayout.Text("");
    private readonly Button apply;
    private readonly Button reload;
    private readonly Button undo;
    private readonly Button redo;
    private readonly Func<IReadOnlyList<AdjustmentHistoryPart>> historyParts;
    private readonly HashSet<string> skipping=new(StringComparer.OrdinalIgnoreCase);
    private IReadOnlyList<AdjustmentOutcome> outcomes;
    private bool preview;
    private readonly string? sourceSummary;
    internal AdjustmentResultDialog(Window owner,string title,IReadOnlyList<AdjustmentOutcome> initial,bool preview,
        Func<IReadOnlySet<string>,IReadOnlyList<AdjustmentOutcome>> run,Action? reloadSaved=null,string? sourceSummary=null,
        Func<IReadOnlyList<AdjustmentHistoryPart>>? historyParts=null,Action<bool>? changeHistory=null)
    {
        this.preview=preview;outcomes=initial;this.sourceSummary=sourceSummary;
        this.historyParts=historyParts ?? (()=>[]);
        var root=AdjustmentDialogLayout.Configure(this,owner,title,"adjustment.results");root.Children.Add(summary);
        AutomationProperties.SetAutomationId(summary,"adjustment.results.summary");
        var scroll=new ScrollViewer{Content=rows,VerticalScrollBarVisibility=ScrollBarVisibility.Auto};Grid.SetRow(scroll,1);root.Children.Add(scroll);
        var actions=new WrapPanel{HorizontalAlignment=HorizontalAlignment.Right,Margin=new Thickness(0,16,0,0)};
        undo=AdjustmentDialogLayout.Button("撤销","adjustment.results.undo",()=>{changeHistory?.Invoke(true);Refresh();});actions.Children.Add(undo);
        redo=AdjustmentDialogLayout.Button("重做","adjustment.results.redo",()=>{changeHistory?.Invoke(false);Refresh();});actions.Children.Add(redo);
        var close=AdjustmentDialogLayout.Button("关闭","adjustment.results.close",()=>Close());close.IsCancel=true;actions.Children.Add(close);
        reload=AdjustmentDialogLayout.Button("重新载入调整","adjustment.results.reload",()=>{Close();reloadSaved?.Invoke();});actions.Children.Add(reload);
        apply=AdjustmentDialogLayout.Button(preview ? "应用调整" : "重试","adjustment.results.apply",()=>{
            outcomes=run(skipping);this.preview=false;Refresh();
        });apply.IsDefault=true;actions.Children.Add(apply);Grid.SetRow(actions,2);root.Children.Add(actions);Refresh();
    }
    private void Refresh()
    {
        rows.Children.Clear();
        var parts=historyParts();
        var states=parts.ToDictionary(p=>p.Identity.Path,p=>p.State,StringComparer.OrdinalIgnoreCase);
        bool WasUndone(AdjustmentOutcome outcome)=>outcome.Status==AdjustmentStatus.Applied &&
            states.TryGetValue(outcome.TargetID,out var state) && state!=AdjustmentHistoryState.Applied;
        summary.Text=preview ? Loc.Format("已预检 {0} 张照片。确认后保存所选调整。",outcomes.Count) :
            Loc.Format("已保存 {0} 张 · 未变化 {1} 张 · 已跳过 {2} 张 · 已撤销 {3} 张 · 未完成 {4} 张",outcomes.Count(o=>o.Status==AdjustmentStatus.Applied && !WasUndone(o)),
                outcomes.Count(o=>o.Status==AdjustmentStatus.Unchanged),outcomes.Count(o=>o.Status==AdjustmentStatus.Skipped),
                outcomes.Count(WasUndone),
                outcomes.Count(o=>o.Status is AdjustmentStatus.Blocked or AdjustmentStatus.Conflict or AdjustmentStatus.Failed));
        if(sourceSummary!=null)summary.Text=sourceSummary+"\n"+summary.Text;
        foreach(var outcome in outcomes) {
            var row=new StackPanel{Margin=new Thickness(0,10,0,12)};rows.Children.Add(row);
            var heading=AdjustmentDialogLayout.Text(Path.GetFileName(outcome.TargetID));heading.FontWeight=FontWeights.SemiBold;heading.ToolTip=outcome.TargetID;row.Children.Add(heading);
            var status=preview && outcome.Status==AdjustmentStatus.Blocked && outcome.Error==null ? Loc.Text("可应用") : AdjustmentTransferPresentation.Status(outcome.Status);
            if(WasUndone(outcome))status=Loc.Text(states[outcome.TargetID]==AdjustmentHistoryState.Undone ? "已撤销" : "重做已失效");
            row.Children.Add(AdjustmentDialogLayout.Text(status));
            if(outcome.Error!=null) {
                var error=AdjustmentDialogLayout.Text(outcome.Status==AdjustmentStatus.Applied ? Loc.Text("调整已保存，当前照片需要重新载入。") : AdjustmentTransferPresentation.Error(outcome.Error));
                error.ToolTip=outcome.Error.Message;row.Children.Add(error);
                if(outcome.Status==AdjustmentStatus.Applied)continue;
                var skip=new CheckBox{Content=Loc.Text("跳过"),IsChecked=skipping.Contains(outcome.TargetID)};
                AutomationProperties.SetAutomationId(skip,"adjustment.skip."+Path.GetFileName(outcome.TargetID));
                skip.Checked+=(_,_)=>{skipping.Add(outcome.TargetID);UpdateApply();};skip.Unchecked+=(_,_)=>{skipping.Remove(outcome.TargetID);UpdateApply();};row.Children.Add(skip);
            }
        }
        apply.Content=Loc.Text(preview ? "应用调整" : "重试");UpdateApply();
        reload.Visibility=outcomes.Any(o=>o.Status==AdjustmentStatus.Applied && o.Error!=null) ? Visibility.Visible : Visibility.Collapsed;
        undo.Visibility=redo.Visibility=parts.Count>0 ? Visibility.Visible : Visibility.Collapsed;
        var appliedCount=parts.Count(p=>p.State==AdjustmentHistoryState.Applied);var undoneCount=parts.Count(p=>p.State==AdjustmentHistoryState.Undone);
        undo.Content=Loc.Text("撤销")+" · "+appliedCount;redo.Content=Loc.Text("重做")+" · "+undoneCount;
        undo.IsEnabled=appliedCount>0;redo.IsEnabled=undoneCount>0;
    }
    private void UpdateApply()
    {
        var remaining=outcomes.Count(outcome=>!skipping.Contains(outcome.TargetID));
        apply.IsEnabled=remaining>0 && !outcomes.Any(outcome=>outcome.RequiresHistoryDecision && !skipping.Contains(outcome.TargetID)) &&
            (preview || outcomes.Any(outcome=>outcome.Status is AdjustmentStatus.Blocked or AdjustmentStatus.Conflict or AdjustmentStatus.Failed));
        if(preview) {
            summary.Text=Loc.Format("已预检 {0} 张照片。确认后保存所选调整。",remaining);
            if(sourceSummary!=null)summary.Text=sourceSummary+"\n"+summary.Text;
        }
        if(remaining==0)summary.Text+="\n"+Loc.Text("没有可应用的目标，请取消跳过或重新选择。");
    }

}

internal sealed class AdjustmentHistoryDialog : Window
{
    private readonly StackPanel rows=new();
    internal AdjustmentHistoryDialog(Window owner,Func<IReadOnlyList<AdjustmentHistoryTransaction>> transactions,Action<Guid,bool> run)
    {
        var root=AdjustmentDialogLayout.Configure(this,owner,"本次会话历史","adjustment.history");
        root.Children.Add(AdjustmentDialogLayout.Text(Loc.Text("历史仅保留在本次会话；已保存的调整会在重新打开时恢复。")));
        var scroll=new ScrollViewer{Content=rows,VerticalScrollBarVisibility=ScrollBarVisibility.Auto};Grid.SetRow(scroll,1);root.Children.Add(scroll);
        var close=AdjustmentDialogLayout.Button("关闭","adjustment.history.close",()=>Close());close.IsCancel=true;close.HorizontalAlignment=HorizontalAlignment.Right;Grid.SetRow(close,2);root.Children.Add(close);
        void Refresh() {
            rows.Children.Clear();
            foreach(var transaction in transactions().Reverse()) {
                var panel=new StackPanel{Margin=new Thickness(0,10,0,14)};rows.Children.Add(panel);
                var title=AdjustmentDialogLayout.Text(Loc.Text(transaction.Action switch { AdjustmentHistoryAction.Paste=>"粘贴调整", AdjustmentHistoryAction.Preset=>"应用预设", AdjustmentHistoryAction.Synchronize=>"同步调整", _=>"调整照片" }));title.FontWeight=FontWeights.SemiBold;panel.Children.Add(title);
                foreach(var part in transaction.Parts)panel.Children.Add(AdjustmentDialogLayout.Text(part.DisplayName+" · "+Loc.Text(part.State switch {
                    AdjustmentHistoryState.Applied=>"已保存",AdjustmentHistoryState.Undone=>"已撤销",_=>"重做已失效"})));
                var actions=new WrapPanel();panel.Children.Add(actions);
                foreach(var undo in new[]{true,false}) {
                    var button=AdjustmentDialogLayout.Button(undo ? "撤销" : "重做",(undo ? "adjustment.undo." : "adjustment.redo.")+transaction.ID,()=>{run(transaction.ID,undo);Refresh();});
                    button.IsEnabled=transaction.Parts.Any(p=>p.State==(undo ? AdjustmentHistoryState.Applied : AdjustmentHistoryState.Undone));actions.Children.Add(button);
                }
            }
            if(rows.Children.Count==0)rows.Children.Add(AdjustmentDialogLayout.Text(Loc.Text("本次会话暂无编辑历史。")));
        }
        Refresh();
    }
}
