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
        if(transform.Active){transform.Reset();transformPreviewReady=false;++transformGeneration;RefreshCropDraft();RefreshControls();Schedule();return;}
        if(choosingDenoise)settings.Denoise=new();
        else if(choosingHsl)settings.Hsl=new();
        else if(choosingPhotoEffects)settings.ResetEffects(selectedEffect==PhotoEffectTool.Vignette);
        else if(choosingGeometry)settings.Geometry=new();
        else if(choosingLens)settings.Lens=new();
        else if(choosingFilm || choosingRecipes){if(settings.MasterRecipeID!=null){settings.ClearMasterRecipe();lut=null;}settings.Reset(Parameter.Strength);}
        else settings.Reset(selectedParameter);
        MarkEdited();RefreshControls();Schedule();
    }
    private void ResetMenuClicked(object sender,RoutedEventArgs e)
    {
        var menu=new ContextMenu{PlacementTarget=ResetAllButton,Placement=PlacementMode.Top};
        MenuItem Add(string title,RoutedEventHandler action,string? group=null){var item=new MenuItem{Header=Loc.Text(title),Tag=group};item.Click+=action;menu.Items.Add(item);return item;}
        Add("重置当前工具",ResetCurrentToolClicked);
        menu.Items.Add(new Separator());
        foreach(var group in new[]{"输入","明暗","色彩","细节","效果"})Add(group,ResetNamedGroupClicked,group);
        Add("强度",ResetNamedGroupClicked,"胶片");menu.Items.Add(new Separator());Add("全部重置",ResetAllClicked);
        menu.IsOpen=true;
    }
}
