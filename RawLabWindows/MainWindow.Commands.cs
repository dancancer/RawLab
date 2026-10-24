using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Automation;
using System.Windows.Input;

namespace RawLab.Windows;

public partial class MainWindow
{
    private void ExitClicked(object sender,RoutedEventArgs e)=>Close();
    private void MainExportClicked(object sender,RoutedEventArgs e)=>ExportMenuClicked(ExportButton,e);
    private async void OpenExportedClicked(object sender,RoutedEventArgs e)
    {
        if(lastExportedPath==null)return;
        try
        {
            var item=await Task.Run(()=>{System.Runtime.InteropServices.Marshal.ThrowExceptionForHR(SHParseDisplayName(lastExportedPath,IntPtr.Zero,out var parsed,0,out _));return parsed;});
            try{System.Runtime.InteropServices.Marshal.ThrowExceptionForHR(SHOpenFolderAndSelectItems(item,0,IntPtr.Zero,0));}
            finally{System.Runtime.InteropServices.Marshal.FreeCoTaskMem(item);}
            await EnsureExplorerSelection(lastExportedPath);
        }
        catch(Exception error){Report(error);}
    }
    private void SettingsClicked(object sender,RoutedEventArgs e)
    {
        PreserveUpdateNavigation();
        var focus=Keyboard.FocusedElement;
        var dialog=new SettingsWindow(GpuMode.SelectedIndex,()=>ShowSoftwareUpdates(true)){Owner=this};
        if(dialog.ShowDialog()==true && GpuMode.SelectedIndex!=dialog.Backend)GpuMode.SelectedIndex=dialog.Backend;
        if(softwareUpdateWindow?.IsVisible!=true && focus is UIElement control && control.IsVisible)control.Focus();
    }
    private void ResetCurrentToolClicked(object sender,RoutedEventArgs e) => RequestReset(new(EditorResetKind.Tool,Tool:CurrentTool));
    private bool resetMenuInitialized;
    private void BuildResetMenu()
    {
        var edit=(MenuItem)MainMenu.Items[1];
        if(!resetMenuInitialized) {
            edit.SubmenuOpened+=(_,_)=>PopulateEditResetMenu(edit.Items);
            resetMenuInitialized=true;
        }
        PopulateEditResetMenu(edit.Items);
    }
    private void PopulateEditResetMenu(ItemCollection items)
    {
        foreach(var item in items.OfType<MenuItem>().Where(item=>item.Tag is EditorResetScope).ToArray())items.Remove(item);
        PopulateResetMenu(items,false);
    }
    private void PopulateResetMenu(ItemCollection items,bool clear=true)
    {
        if(clear)items.Clear();
        void Add(string title,EditorResetScope scope) {
            var prepared=PrepareReset(scope);
            var item=new MenuItem { Header=title,Tag=scope,
                IsEnabled=file!=null && !exporting && pendingAllReset==null &&
                    (scope.Kind==EditorResetKind.All && transform.Active ? WorkspaceEdit() is {} edit && EditorAdjustmentRules.IsModified(scope,edit) || GeometryEditor.HasInvalidInput : prepared is { Status: EditorResetStatus.Ready or EditorResetStatus.Blocked } || HasPendingAIReset(scope)) };
            item.Click+=(_,_)=>RequestReset(scope);items.Add(item);
        }
        if(CurrentTool==EditorAdjustmentTool.ColorGrading) {
            Add(Loc.Text("重置当前分区"),new(EditorResetKind.GradingZone,Zone:GradingEditor.SelectedZone));
            Add(Loc.Text("重置颜色分级"),new(EditorResetKind.AllGrading));
        } else if(CurrentTool==EditorAdjustmentTool.Hsl) {
            Add(Loc.Format("重置当前颜色（{0}）",HslEditor.SelectedChannelName),new(EditorResetKind.HslChannel,Channel:HslEditor.SelectedChannel));
            Add(Loc.Text("重置全部 HSL…"),new(EditorResetKind.AllHsl));
        } else Add(Loc.Format("重置{0}",Loc.Text(EditorAdjustmentRules.Title(CurrentTool))),new(EditorResetKind.Tool,Tool:CurrentTool));
        var group=EditorAdjustmentRules.GroupFor(CurrentTool);
        Add(Loc.Format("重置{0}组…",Loc.Text(EditorAdjustmentRules.Title(group))),new(EditorResetKind.Group,group));
        Add(Loc.Text("重置全部调整…"),new(EditorResetKind.All));
    }
    private void ResetMenuClicked(object sender,RoutedEventArgs e)
    {
        var menu=new ContextMenu{PlacementTarget=ResetAllButton,Placement=PlacementMode.Top};
        PopulateResetMenu(menu.Items);ResetAllButton.ContextMenu=menu;menu.IsOpen=true;
    }
    private sealed record PendingAllReset(string File,long OpenRevision,EditorAdjustmentTool Tool,EditorAdjustmentGroup? Group);
    private PendingAllReset? pendingAllReset;
    private bool pendingResetReady,resetContinuationQueued;
    private void RequestReset(EditorResetScope scope)
    {
        if(file==null || exporting || closing || pendingAllReset!=null)return;
        if(scope.Kind==EditorResetKind.All && transform.Active) {
            // Neutral unchanged drafts need no leave/re-enter preview or save.
            if(!transform.Dirty && !GeometryEditor.HasInvalidInput && WorkspaceEdit() is {} unchanged &&
                EditorAdjustmentRules.PrepareReset(scope,unchanged).Status==EditorResetStatus.NoChange)return;
            pendingAllReset=new(file,openRevision,CurrentTool,expandedGroup);
            if(!ResolveTransformDraft()) {pendingAllReset=null;RefreshControls();return;}
            pendingResetReady=true;RefreshControls();QueuePendingReset();return;
        }
        ExecuteReset(scope);
    }
    private void QueuePendingReset()
    {
        if(pendingAllReset==null || !pendingResetReady || resetContinuationQueued || !exactReady || scheduler.Busy || previewResize.IsEnabled)return;
        resetContinuationQueued=true;
        Dispatcher.BeginInvoke(new Action(()=>{
            resetContinuationQueued=false;
            if(pendingAllReset is not {} intent || !pendingResetReady)return;
            if(file!=intent.File || openRevision!=intent.OpenRevision || closing) {pendingAllReset=null;pendingResetReady=false;return;}
            if(!exactReady || scheduler.Busy || previewResize.IsEnabled)return;
            pendingResetReady=false;
            ExecuteReset(new(EditorResetKind.All));
            pendingAllReset=null;
            // The explicit Apply/Discard survives cancellation of the second confirmation.
            // Re-entry always uses the new committed settings, never the abandoned draft.
            SelectTool(intent.Tool);expandedGroup=intent.Group;RefreshControls();
        }));
    }
    private void ExecuteReset(EditorResetScope scope)
    {
        var prepared=PrepareReset(scope);if(prepared==null)return;
        if(prepared.Status==EditorResetStatus.NoChange) {
            if(HasPendingAIReset(scope)) {ResetAITask();RefreshControls();Schedule();}
            if(transform.Active && transform.Tool==TransformTool.Geometry && GeometryEditor.HasInvalidInput &&
                (scope.Kind==EditorResetKind.Group && scope.Group==EditorAdjustmentGroup.Geometry || scope.Kind==EditorResetKind.Tool && scope.Tool==EditorAdjustmentTool.Geometry))
                GeometryEditor.Begin(transform.Geometry);
            return;
        }
        if(prepared.Status!=EditorResetStatus.Ready) {
            var key=prepared.Status==EditorResetStatus.Invalid ? "当前照片或调整记录无效，无法安全重置。" : prepared.Reason switch {
                "Unknown master recipe." => "当前配方不可用，无法安全重置外观。",
                "Recipe white balance needs real as-shot calibration." => "缺少拍摄时白平衡数据，无法保留配方效果。",
                "Geometry reset requires an active draft." or "Geometry reset requires a matching active draft." or
                "Resolve the active draft before preparing this reset." => "预览尚未就绪，请稍后重试。",
                _ => "现有参数范围无法保留配方的全部效果。你可以取消，或另行确认重置全部调整。"
            };
            MessageBox.Show(this,Loc.Text(key),Loc.Text("无法重置调整"),MessageBoxButton.OK,MessageBoxImage.Information);return;
        }
        var revision=editRevision;
        if(prepared.RequiresConfirmation && !ConfirmReset(scope,prepared))return;
        if(!CommitReset(prepared,revision))SetStatus(()=>Loc.Text("照片或调整已变化，请重新确认重置。"),true);
    }
    private bool ConfirmReset(EditorResetScope scope,EditorResetTransaction prepared)
    {
        var grading=scope.Kind==EditorResetKind.AllGrading || scope.Kind==EditorResetKind.Tool && scope.Tool==EditorAdjustmentTool.ColorGrading;
        var hsl=scope.Kind==EditorResetKind.AllHsl || scope.Kind==EditorResetKind.Tool && scope.Tool==EditorAdjustmentTool.Hsl;
        var groupName=Loc.Text(EditorAdjustmentRules.Title(scope.Group));
        var title=scope.Kind==EditorResetKind.All ? Loc.Text("重置全部调整？") : grading ? Loc.Text("重置颜色分级") : hsl ? Loc.Text("重置全部 HSL？") :
            scope.Kind==EditorResetKind.Group ? Loc.Format("重置{0}组？",groupName) : Loc.Format("重置{0}？",Loc.Text(EditorAdjustmentRules.Title(scope.Tool)));
        var message=scope.Kind==EditorResetKind.All ? Loc.Text("恢复当前照片的全部调整，不改写原始照片。") : grading ? Loc.Text("恢复阴影、中间调和高光的颜色分级默认值？") : hsl ?
            Loc.Text("八个色域的色相、饱和度和明度都会恢复为 0。其他调整保持不变。") :
            scope.Kind==EditorResetKind.Group ? Loc.Format("此操作只恢复{0}组内的调整，其他分组保持不变。",groupName) : "";
        if(scope.Kind==EditorResetKind.All)message=System.IO.Path.GetFileName(file)+"\n\n"+message;
        if(prepared.MaterializedFields.Count>0)message+="\n\n"+Loc.Format("将以下项目转为独立调整，以保留其他分组的当前效果：{0}",string.Join("、",prepared.MaterializedFields.Select(Loc.Text)));
        var dialog=new Window { Title=title,Owner=this,Width=520,MaxHeight=Math.Max(240,ActualHeight-80),SizeToContent=SizeToContent.Height,
            ResizeMode=ResizeMode.NoResize,ShowInTaskbar=false,WindowStartupLocation=WindowStartupLocation.CenterOwner };
        AutomationProperties.SetAutomationId(dialog,"editor.reset.confirmation");
        KeyboardNavigation.SetTabNavigation(dialog,KeyboardNavigationMode.Cycle);
        var grid=new Grid { Margin=new Thickness(24) };grid.RowDefinitions.Add(new(){Height=new GridLength(1,GridUnitType.Star)});grid.RowDefinitions.Add(new(){Height=GridLength.Auto});
        grid.Children.Add(new ScrollViewer { VerticalScrollBarVisibility=ScrollBarVisibility.Auto,Content=new TextBlock {Text=message,TextWrapping=TextWrapping.Wrap} });
        var actions=new WrapPanel { HorizontalAlignment=HorizontalAlignment.Right,Margin=new Thickness(0,16,0,0) };
        var cancel=new Button {Content=Loc.Text("取消"),IsCancel=true};cancel.Click+=(_,_)=>dialog.DialogResult=false;
        var reset=new Button {Content=Loc.Text("重置"),IsDefault=true};reset.Click+=(_,_)=>dialog.DialogResult=true;
        actions.Children.Add(cancel);actions.Children.Add(reset);Grid.SetRow(actions,1);grid.Children.Add(actions);dialog.Content=grid;
        var focus=Keyboard.FocusedElement;var confirmed=dialog.ShowDialog()==true;if(focus is UIElement control && control.IsVisible)control.Focus();return confirmed;
    }
}
