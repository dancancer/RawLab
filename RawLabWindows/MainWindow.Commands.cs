using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
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
        if(exporting)return;
        var focus=Keyboard.FocusedElement;
        var dialog=new SettingsWindow(GpuMode.SelectedIndex){Owner=this};
        if(dialog.ShowDialog()==true && GpuMode.SelectedIndex!=dialog.Backend)GpuMode.SelectedIndex=dialog.Backend;
        if(focus is UIElement control && control.IsVisible)control.Focus();
    }
    private void ResetNamedGroupClicked(object sender,RoutedEventArgs e)
    {
        if(file==null || exporting || sender is not MenuItem{Tag:string group} || !ResolveTransformDraft())return;
        if(group=="胶片" && settings.MasterRecipeID!=null){settings.ClearMasterRecipe();lut=null;}
        settings.ResetGroup(group);MarkEdited();RefreshControls();Schedule();
    }
    private void ResetCurrentToolClicked(object sender,RoutedEventArgs e)
    {
        if(file==null || exporting)return;
        if(transform.Active){if(transform.Tool==TransformTool.Geometry)GeometryEditor.ResetDraft();else UpdateLensDraft(new());return;}
        if(choosingDenoise)settings.Denoise=new();
        else if(choosingHsl)settings.Hsl=new();
        else if(choosingWhiteBalance)settings.ResetWhiteBalance();
        else if(choosingPhotoEffects)settings.ResetEffects(selectedEffect==PhotoEffectTool.Vignette);
        else if(choosingGeometry)settings.Geometry=new();
        else if(choosingLens)settings.Lens=new();
        else if(choosingFilm || choosingRecipes){if(settings.MasterRecipeID!=null){settings.ClearMasterRecipe();lut=null;}settings.Reset(Parameter.Strength);}
        else settings.Reset(selectedParameter);
        MarkEdited();RefreshControls();Schedule();
    }
    // ┌─ 分组重置的唯一来源：编辑菜单与调整栏的重置菜单都按它生成，叫法一致 ─────┐
    // │ 菜单项写成“重置输入”“重置胶片”这样的动作，不只列出分组名                  │
    // └──────────────────────────────────────────────────────────────────────────┘
    private static readonly string[] ResetGroups=["输入","明暗","色彩","细节","效果","胶片"];
    private MenuItem ResetGroupItem(string group)
    {
        var title=group==ResetGroups[0] ? Loc.Text("输入调整") : Loc.Text(group);
        var item=new MenuItem{Header=Loc.Format("重置{0}",title),Tag=group};
        item.Click+=ResetNamedGroupClicked;return item;
    }
    private void BuildResetMenu()
    {
        var edit=(MenuItem)MainMenu.Items[1];
        foreach(var item in edit.Items.OfType<MenuItem>().Where(item=>item.Tag is string).ToList())edit.Items.Remove(item);
        foreach(var (group,index) in ResetGroups.Select((group,index)=>(group,index)))edit.Items.Insert(index+1,ResetGroupItem(group));
    }
    private void ResetMenuClicked(object sender,RoutedEventArgs e)
    {
        var menu=new ContextMenu{PlacementTarget=ResetAllButton,Placement=PlacementMode.Top};
        void Add(string title,RoutedEventHandler action){var item=new MenuItem{Header=Loc.Text(title)};item.Click+=action;menu.Items.Add(item);}
        Add("重置本工具",ResetCurrentToolClicked);
        menu.Items.Add(new Separator());
        foreach(var group in ResetGroups)menu.Items.Add(ResetGroupItem(group));
        menu.Items.Add(new Separator());Add("重置全部调整",ResetAllClicked);
        ResetAllButton.ContextMenu=menu;menu.IsOpen=true;
    }
}
