using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using Microsoft.Win32;

namespace RawLab.Windows;

internal sealed class BatchSelectionWindow : Window
{
    private readonly MainWindow editor;
    private readonly StackPanel rows=new();
    private readonly ScrollViewer scroll;
    private readonly TextBlock summary=AdjustmentDialogLayout.Text("");
    private readonly TextBlock source=AdjustmentDialogLayout.Text("");
    private readonly Button sync,export,history,task;
    private double offset;
    private bool preparing,pendingReturn;
    private readonly WrapPanel selectionActions=new();
    internal BatchSelectionWindow(MainWindow editor)
    {
        this.editor=editor;
        var root=AdjustmentDialogLayout.Configure(this,editor,"批量编辑","collection.window");Width=880;Height=760;
        var header=new StackPanel();root.Children.Add(header);
        var actions=selectionActions;header.Children.Add(actions);
        actions.Children.Add(AdjustmentDialogLayout.Button("添加照片","collection.add",()=>{
            var picker=new OpenFileDialog{Multiselect=true,Filter=Loc.Text("照片|")+LibraryEntry.ImageFilter};
            if(picker.ShowDialog(this)==true){editor.AddCollectionPhotos(picker.FileNames);Refresh();}
        }));
        actions.Children.Add(AdjustmentDialogLayout.Button("全选","collection.select-all",()=>{editor.Collection.SelectAll(true);Refresh();}));
        actions.Children.Add(AdjustmentDialogLayout.Button("取消全选","collection.select-none",()=>{editor.Collection.SelectAll(false);Refresh();}));
        header.Children.Add(summary);
        scroll=new ScrollViewer{Content=rows,VerticalScrollBarVisibility=ScrollBarVisibility.Auto};Grid.SetRow(scroll,1);root.Children.Add(scroll);
        scroll.ScrollChanged+=(_,_)=>offset=scroll.VerticalOffset;
        var footer=new StackPanel();Grid.SetRow(footer,2);root.Children.Add(footer);footer.Children.Add(source);
        var buttons=new WrapPanel{HorizontalAlignment=HorizontalAlignment.Right};footer.Children.Add(buttons);
        history=AdjustmentDialogLayout.Button("上次同步记录","collection.history",()=>editor.ShowCollectionHistory(this));buttons.Children.Add(history);
        task=AdjustmentDialogLayout.Button("查看批量任务…","collection.task",editor.ViewCollectionExport);buttons.Children.Add(task);
        sync=AdjustmentDialogLayout.Button("同步调整","collection.sync",async()=>{
            preparing=true;RefreshButtons();
            try{await editor.SynchronizeCollection(this);}finally{preparing=false;Refresh();}
        });buttons.Children.Add(sync);
        export=AdjustmentDialogLayout.Button("逐张导出","collection.export",()=>{new CollectionExportDialog(this,editor).ShowDialog();Refresh();});buttons.Children.Add(export);
        buttons.Children.Add(AdjustmentDialogLayout.Button("关闭","collection.close",Close));
        Activated+=(_,_)=>{if(!preparing)Refresh();};
        Closing+=(_,_)=>{if(preparing)editor.CancelCollectionOperation();};
    }
    internal void Refresh(bool restorePosition=false)
    {
        pendingReturn|=restorePosition;
        editor.Collection.RefreshFailures();var position=offset;rows.Children.Clear();
        if(editor.Collection.Photos.Count==0)rows.Children.Add(AdjustmentDialogLayout.Text(Loc.Text("添加照片后，可同步调整、逐张微调并导出。")));
        foreach(var photo in editor.Collection.Photos) {
            var panel=new StackPanel{Margin=new Thickness(0,8,0,12)};rows.Children.Add(panel);
            var row=new DockPanel();panel.Children.Add(row);
            var selection=new CheckBox{IsChecked=editor.Collection.Selected.Contains(photo.ID),Margin=new Thickness(0,0,12,0),VerticalAlignment=VerticalAlignment.Center};
            AutomationProperties.SetAutomationId(selection,"collection.select."+photo.ID);
            selection.Checked+=(_,_)=>{editor.Collection.Select(photo.ID,true);RefreshButtons();};
            selection.Unchecked+=(_,_)=>{editor.Collection.Select(photo.ID,false);RefreshButtons();};row.Children.Add(selection);
            var edit=AdjustmentDialogLayout.Button("编辑","collection.edit."+photo.ID,()=>{offset=scroll.VerticalOffset;editor.EditCollectionPhoto(photo.ID);});
            DockPanel.SetDock(edit,Dock.Right);row.Children.Add(edit);
            var remove=AdjustmentDialogLayout.Button("移除","collection.remove."+photo.ID,()=>{editor.Collection.Remove(photo.ID);Refresh();});
            DockPanel.SetDock(remove,Dock.Right);row.Children.Add(remove);
            var image=new Image{Width=64,Height=52,Stretch=Stretch.Uniform,Margin=new Thickness(0,0,12,0)};row.Children.Add(image);
            var name=AdjustmentDialogLayout.Text(Path.GetFileName(photo.Path));name.ToolTip=photo.Path;name.VerticalAlignment=VerticalAlignment.Center;row.Children.Add(name);
            if(editor.Collection.Failures.TryGetValue(photo.ID,out var failure)) {
                edit.IsEnabled=false;var error=AdjustmentDialogLayout.Text(failure);error.SetResourceReference(TextBlock.ForegroundProperty,"ErrorForeground");panel.Children.Add(error);
            }else _=LoadThumbnail(photo.Path,image);
        }
        scroll.ScrollToVerticalOffset(position);RefreshButtons();
        if(pendingReturn)Dispatcher.BeginInvoke(new Action(()=>{
            if(!IsVisible || editor.Collection.Photos.Count==0)return;
            var index=Math.Clamp(editor.Collection.ReturnPosition,0,editor.Collection.Photos.Count-1);
            if(rows.Children[index] is FrameworkElement row){row.BringIntoView();pendingReturn=false;}
        }),System.Windows.Threading.DispatcherPriority.Loaded);
    }
    private async Task LoadThumbnail(string path,Image image)
    {
        try{var thumbnail=await Task.Run(()=>RenderEngine.Thumbnail(path));if(IsVisible)image.Source=thumbnail;}catch(Exception){}
    }
    private void RefreshButtons()
    {
        summary.Text=Loc.Format("已选择 {0} 张",editor.Collection.Selected.Count);
        var id=editor.CollectionSourceID;var count=id==null ? 0 : editor.Collection.SynchronizationTargets(id).Count;
        source.Text=id==null ? Loc.Text("先进入一张照片，将它作为同步来源。") :
            Loc.Format("来源：{0} · 目标 {1} 张",Path.GetFileName(editor.CollectionSourcePath),count);
        if(id!=null && count==0)source.Text+="\n"+Loc.Text("排除来源照片后没有可同步的目标。");
        sync.IsEnabled=!preparing && !editor.CollectionBusy && count>0;
        export.IsEnabled=!preparing && !editor.CollectionBusy && editor.Collection.Selected.Count>0;
        history.Visibility=editor.Collection.LastSynchronization==null ? Visibility.Collapsed : Visibility.Visible;
        task.Visibility=editor.CollectionHasExport ? Visibility.Visible : Visibility.Collapsed;
        rows.IsEnabled=selectionActions.IsEnabled=!preparing && !editor.CollectionBusy;
        history.IsEnabled=!preparing && !editor.CollectionBusy;
        task.IsEnabled=!preparing;
    }
}

internal sealed class CollectionExportDialog : Window
{
    private readonly MainWindow editor;
    private readonly HashSet<string> skipping=new(StringComparer.Ordinal);
    private readonly StackPanel rows=new();
    private readonly TextBlock message=AdjustmentDialogLayout.Text("");
    private readonly Button confirm;
    private readonly StackPanel configuration=new();
    private bool checking,closed;
    private int generation;
    private CollectionExportReview? review;
    private ExportFormat format=ExportFormat.Jpeg;
    private readonly ComboBox formats=new(){MinWidth=150};
    private readonly TextBox edge=new(){MinWidth=100};
    private string? directory;
    internal CollectionExportDialog(Window owner,MainWindow editor)
    {
        this.editor=editor;var root=AdjustmentDialogLayout.Configure(this,owner,"逐张导出","collection.export-review");
        var header=configuration;root.Children.Add(header);
        header.Children.Add(AdjustmentDialogLayout.Text(Loc.Text("将按每张照片已保存的调整导出。跳过只影响本次导出。")));
        var output=new WrapPanel();header.Children.Add(output);
        formats.ItemsSource=Enum.GetValues<ExportFormat>();formats.SelectedItem=format;output.Children.Add(formats);
        formats.SelectionChanged+=(_,_)=>{format=(ExportFormat)formats.SelectedItem;Invalidate();};
        output.Children.Add(AdjustmentDialogLayout.Text(Loc.Text("导出长边像素（留空为原尺寸）")));output.Children.Add(edge);
        edge.TextChanged+=(_,_)=>Invalidate();
        var destination=AdjustmentDialogLayout.Text(Loc.Text("请选择输出文件夹。"));header.Children.Add(destination);
        header.Children.Add(AdjustmentDialogLayout.Button("选择输出文件夹","collection.export-folder",()=>{
            var picker=new OpenFolderDialog();if(picker.ShowDialog(this)==true){directory=picker.FolderName;destination.Text=directory;Invalidate();}
        }));
        var scroll=new ScrollViewer{Content=rows,VerticalScrollBarVisibility=ScrollBarVisibility.Auto};Grid.SetRow(scroll,1);root.Children.Add(scroll);
        var footer=new StackPanel();Grid.SetRow(footer,2);root.Children.Add(footer);footer.Children.Add(message);
        AutomationProperties.SetAutomationId(message,"collection.export-count");
        var actions=new WrapPanel{HorizontalAlignment=HorizontalAlignment.Right};footer.Children.Add(actions);
        actions.Children.Add(AdjustmentDialogLayout.Button("取消","collection.export-cancel",Close));
        confirm=AdjustmentDialogLayout.Button("开始导出 {0} 张","collection.export-confirm",async()=>await Confirm());actions.Children.Add(confirm);
        Closed+=(_,_)=>{closed=true;CancelCheck();};
        Deactivated+=(_,_)=>CancelCheck();
        RefreshRows();Invalidate();
    }
    private void Invalidate()
    {
        review=null;
        if(confirm==null)return;
        var count=editor.Collection.SelectedPhotos.Count(photo=>!skipping.Contains(photo.ID));
        confirm.Content=Loc.Format("开始导出 {0} 张",count);confirm.IsEnabled=count>0 && !checking;
        message.Text=count==0 ? Loc.Text("没有可导出的照片，请取消跳过或重新选择。") : "";
    }
    private void RefreshRows()
    {
        rows.Children.Clear();editor.Collection.RefreshFailures();
        foreach(var photo in editor.Collection.SelectedPhotos) {
            var row=new StackPanel{Margin=new Thickness(0,10,0,14)};rows.Children.Add(row);
            row.Children.Add(AdjustmentDialogLayout.Text(Path.GetFileName(photo.Path)));
            var checkedRow=review?.Rows.FirstOrDefault(item=>item.Photo.ID==photo.ID);
            var draft=editor.CollectionDraftFailure(photo.ID);
            var error=checkedRow?.Error ?? editor.Collection.Failures.GetValueOrDefault(photo.ID) ?? draft;
            if(error!=null){var label=AdjustmentDialogLayout.Text(error);label.SetResourceReference(TextBlock.ForegroundProperty,"ErrorForeground");row.Children.Add(label);}
            var draftActions=new List<Button>();
            if(draft!=null) {
                var actions=new WrapPanel();row.Children.Add(actions);
                draftActions.Add(AdjustmentDialogLayout.Button("应用并保存草稿","collection.draft-apply",()=>Resolve(photo.ID,true)));
                draftActions.Add(AdjustmentDialogLayout.Button("放弃草稿","collection.draft-discard",()=>Resolve(photo.ID,false)));
                foreach(var button in draftActions){button.IsEnabled=!skipping.Contains(photo.ID);actions.Children.Add(button);}
            }
            var skip=new CheckBox{Content=Loc.Text("仅本次跳过"),IsChecked=skipping.Contains(photo.ID)};row.Children.Add(skip);
            skip.Checked+=(_,_)=>{skipping.Add(photo.ID);foreach(var button in draftActions)button.IsEnabled=false;Invalidate();};skip.Unchecked+=(_,_)=>{skipping.Remove(photo.ID);foreach(var button in draftActions)button.IsEnabled=true;Invalidate();};
            if(checkedRow?.Settings is {} settings)row.Children.Add(new Expander{Header=Loc.Text("最终已保存参数"),
                Content=AdjustmentDialogLayout.Text(BatchSettingsText.Describe(settings,checkedRow.LookName ?? Loc.Text("中性"),photo.Path))});
        }
    }
    private void Resolve(string id,bool apply)
    {
        var success=editor.ResolveCollectionDraft(id,apply);Invalidate();RefreshRows();
        if(!success)message.Text=editor.CollectionDraftFailure(id) ?? Loc.Text("草稿未保存，请重试。");
    }
    private void CancelCheck()
    {
        if(!checking)return;
        ++generation;checking=false;editor.CancelCollectionOperation();
        configuration.IsEnabled=rows.IsEnabled=true;Invalidate();
    }
    private async Task Confirm()
    {
        if(checking || closed)return;
        var request=++generation;
        try {
            var longEdge=string.IsNullOrWhiteSpace(edge.Text) ? (int?)null : ExportSize.Parse(edge.Text) ?? throw new ArgumentException(Loc.Text("请输入 1 到 65535 之间的整数。"));
            checking=true;confirm.IsEnabled=configuration.IsEnabled=rows.IsEnabled=false;
            message.Text=Loc.Text("正在检查照片…");
            var prepared=await editor.PrepareCollectionExportAsync(skipping,format,longEdge,directory ?? "");
            if(closed || request!=generation)return;
            checking=false;
            if(prepared==null){Invalidate();return;}
            review=prepared;RefreshRows();
            if(review.Ready){editor.FreezeCollectionExport(review,autoStart:true);DialogResult=true;return;}
            message.Text=review.Rows.Count==0 ? Loc.Text("没有可导出的照片，请取消跳过或重新选择。") : Loc.Format("实际导出 {0} 张",review.Rows.Count);
        }catch(Exception error){if(!closed && request==generation){Invalidate();message.Text=error.Message;}}
        finally{if(request==generation){checking=false;configuration.IsEnabled=rows.IsEnabled=true;confirm.IsEnabled=editor.Collection.SelectedPhotos.Any(photo=>!skipping.Contains(photo.ID));}}
    }
}
