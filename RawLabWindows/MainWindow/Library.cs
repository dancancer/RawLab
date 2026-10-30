using System.ComponentModel;
using System.Diagnostics;
using System.Windows.Automation;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;

namespace RawLab.Windows;
public partial class MainWindow
{
    private void OpenClicked(object sender,RoutedEventArgs e)
    {
        if(exporting)return;
        var dialog=new OpenFileDialog{Title=Loc.Text("打开照片"),Filter=Loc.Text("照片|")+LibraryEntry.ImageFilter+Loc.Text("|所有文件|*.*")};
        if(dialog.ShowDialog(this)==true)OpenFile(dialog.FileName);
    }
    private async void ImportClicked(object sender,RoutedEventArgs e)
    {
        if(exporting || !ResolveTransformDraft())return;
        var dialog=new OpenFileDialog{Title=Loc.Text("导入外观"),Multiselect=true,Filter=Loc.Text("胶片外观|*.cube;*.vlt;*.rlook;*.dcp|CUBE / VLT LUT|*.cube;*.vlt|RawLab RLOOK 外观|*.rlook|DCP 外观|*.dcp")};
        if(dialog.ShowDialog(this)!=true)return;
        var errors=await ImportLookFiles(dialog.FileNames);
        if(errors.Count>0 && !closing)MessageBox.Show(this,string.Join("\n\n",errors),Loc.Text("导入外观"),MessageBoxButton.OK,MessageBoxImage.Warning);
    }
    internal async Task<IReadOnlyList<string>> ImportLookFiles(IEnumerable<string> paths)
    {
        if(exporting || foregroundBusy || transform.Active)return [];
        var input=file;
        var library=lookLibrary;
        var libraryLoadError=lookLibraryLoadError;
        var selected=paths.Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        foregroundBusy=true;RefreshControls();SetStatus(()=>Loc.Text("正在显影…"));
        var errors=new List<string>();var accepted=new List<(string Path,string Name,bool AppearanceUnverified,int CompatibilityMode)>();
        try
        {
            foreach(var path in selected)
            {
                if(closing) break;
                try
                {
                    try { accepted.Add(await ImportOne(path,null)); }
                    catch(LookLibraryException error) when(error.Error is LookLibraryError.MissingColor or LookLibraryError.MissingReference)
                    {
                        var draft=await Task.Run(()=>LUTCompatibility.Inspect(path));
                        if(closing) break;
                        if(draft==null) throw;
                        var dialog=new LUTCompatibilityDialog(this,path,draft,input,this.library.Roots.Select(entry=>entry.Path).ToArray());
                        if(dialog.ShowDialog()==true) accepted.Add(await ImportOne(path,dialog.Draft));
                    }
                }
                catch(Exception error){errors.Add(Path.GetFileName(path)+": "+error.Message);}
            }
            if(!closing && accepted.Count>0)
            {
                foreach(var look in accepted)if(!films.Any(f=>StringComparer.OrdinalIgnoreCase.Equals(f.Path,look.Path)))films.Add(new(look.Name,look.Path,null,AppearanceUnverified:look.AppearanceUnverified,CompatibilityMode:look.CompatibilityMode));
                try
                {
                    settings.ClearMasterRecipe(file == null || PhotoInput.IsRaw(file));
                    lut=accepted[^1].Path;previewDeferred=true;MarkEdited();
                }
                finally { BuildFilms(); }
            }
        }
        catch(Exception error){errors.Add(error.Message);}
        finally{foregroundBusy=false;RefreshControls();if(closing)FinishClose();else ResumePreview();}
        return errors;

        Task<(string Path,string Name,bool AppearanceUnverified,int CompatibilityMode)> ImportOne(string path,LUTCompatibility? compatibility) => Task.Run(()=>{
            var suffix=Path.GetExtension(path).ToLowerInvariant();
            if(compatibility!=null || suffix is ".dcp" or ".vlt" || suffix==".cube" && PInvokeNative.InspectLutColor(path) is 4 or 7 or 8)
            {
                if(library==null) throw libraryLoadError ?? new LookLibraryException(LookLibraryError.InvalidRegistry);
                var imported=library.ImportLook(path,compatibility);
                return (imported.Path,imported.Name,imported.AppearanceUnverified,imported.CompatibilityMode);
            }
            _=LookLibrary.ValidateExternal(path);
            if(input is not null) { using var validator=new RenderEngine(0);validator.Render(input,new Adjustments(),path,64,statistics:false,clipping:false,viewportPreview:true); }
            return (path,library?.DisplayName(path,Path.GetFileNameWithoutExtension(path)) ?? Path.GetFileNameWithoutExtension(path),false,0);
        });
    }

    private async void RenameImportedLook(string path)
    {
        if(exporting || foregroundBusy || transform.Active || lookLibrary==null)return;
        var current=films.FirstOrDefault(f=>StringComparer.OrdinalIgnoreCase.Equals(f.Path,path));
        if(current==null)return;
        var dialog=new LookRenameDialog(this,current.Name);
        if(dialog.ShowDialog()!=true)return;
        var newName=dialog.LookName;
        foregroundBusy=true;RefreshControls();
        try {
            await Task.Run(()=>lookLibrary.RenamePath(path,newName));
            for(var index=0;index<films.Count;index++)
                if(StringComparer.OrdinalIgnoreCase.Equals(films[index].Path,path))films[index]=films[index] with { Name=lookLibrary.DisplayName(path,newName) };
            BuildFilms();
        } catch(Exception error){Report(error);}
        finally{foregroundBusy=false;RefreshControls();if(closing)FinishClose();}
    }
    private void AddFolderClicked(object sender,RoutedEventArgs e)
    {
        var dialog=new OpenFolderDialog{Title=Loc.Text("添加照片目录"),Multiselect=true};
        if(dialog.ShowDialog(this)==true)try { foreach(var path in dialog.FolderNames)library.Add(path); } catch(Exception ex){Report(ex);}
    }
    private async void FolderExpanded(object sender,RoutedEventArgs e) { if(e.OriginalSource is TreeViewItem {DataContext:LibraryEntry entry})try{await entry.Load();}catch(Exception ex){Report(ex);} }
    private void QueueThumbnailRefresh() { if(!closing){thumbnailRefresh.Stop();thumbnailRefresh.Start();} }
    private void ThumbnailLoaded(object sender,RoutedEventArgs e)=>QueueThumbnailRefresh();
    private void ThumbnailUnloaded(object sender,RoutedEventArgs e) { if(sender is Image {DataContext:LibraryEntry entry}){entry.ReleaseThumbnail();visibleThumbnails.Remove(entry);} }
    internal void RefreshVisibleThumbnails()
    {
        var visible=new HashSet<LibraryEntry>();
        var viewportRect=new Rect(0,0,Files.ActualWidth,Files.ActualHeight);
        void Visit(DependencyObject element)
        {
            if(element is Image {DataContext:LibraryEntry entry} image && VisualTreeHelper.GetParent(image) is FrameworkElement tile && tile.ActualWidth>0 && tile.ActualHeight>0)
            {
                // An unloaded Image has zero size; use its reserved tile to start loading.
                var bounds=new Rect(tile.TranslatePoint(new Point(),Files),tile.RenderSize);
                if(Files.Visibility==Visibility.Visible && viewportRect.IntersectsWith(bounds)){visible.Add(entry);entry.IsSelected=entry.Path.Equals(file,StringComparison.OrdinalIgnoreCase);}
            }
            for(var i=0;i<VisualTreeHelper.GetChildrenCount(element);i++)Visit(VisualTreeHelper.GetChild(element,i));
        }
        Visit(Files);
        foreach(var entry in visibleThumbnails.Except(visible))entry.ReleaseThumbnail();
        foreach(var entry in visible.Except(visibleThumbnails))_ = entry.LoadThumbnail();
        visibleThumbnails.Clear();visibleThumbnails.UnionWith(visible);
    }
    private void PhotoSelected(object sender,RoutedEventArgs e)
    {
        if(sender is not Button {DataContext:LibraryEntry entry} || exporting)return;
        OpenFile(entry.Path,entry.Thumbnail);
        if(!StringComparer.OrdinalIgnoreCase.Equals(file,Path.GetFullPath(entry.Path)))return;
        if(selectedThumbnail!=null)selectedThumbnail.IsSelected=false;
        selectedThumbnail=entry;entry.IsSelected=true;QueueThumbnailRefresh();
    }
    private void FilesContextKeyDown(object sender,KeyEventArgs e)
    {
        if(e.Key!=Key.Apps && !(e.Key==Key.F10 && Keyboard.Modifiers==ModifierKeys.Shift))return;
        var button=FindParent<Button>(Keyboard.FocusedElement as DependencyObject);
        contextEntry=button?.DataContext as LibraryEntry ?? Files.SelectedItem as LibraryEntry;
        if(contextEntry==null)return;
        var menu=button?.ContextMenu ?? FileTreeContextMenu;menu.PlacementTarget=(UIElement?)button ?? Files;menu.IsOpen=true;e.Handled=true;
    }
    private void FileSelected(object sender,RoutedPropertyChangedEventArgs<object> e) { if(e.NewValue is LibraryEntry{IsFolder:false} entry && entry.Path!="")OpenFile(entry.Path,entry.Thumbnail); }
    private static T? FindParent<T>(DependencyObject? element) where T : DependencyObject
    {
        while (element != null)
        {
            if (element is T match) return match;
            element = element is Visual ? VisualTreeHelper.GetParent(element) : LogicalTreeHelper.GetParent(element);
        }
        return null;
    }
    private LibraryEntry? ResolveContextEntry(object sender)
    {
        if (sender is MenuItem { Parent: ContextMenu menu } && menu.PlacementTarget is FrameworkElement target && target.DataContext is LibraryEntry entry)
            return entry;
        return contextEntry;
    }
    private void FilesPreviewMouseRightButtonDown(object sender, MouseButtonEventArgs e)
    {
        var source=(DependencyObject)e.OriginalSource;
        contextEntry=null;
        var photoButton=FindParent<Button>(source);
        if (photoButton?.DataContext is LibraryEntry photo && !photo.IsFolder)
        {
            contextEntry=photo;
            if(photoButton.ContextMenu is { } menu) { menu.PlacementTarget=photoButton; menu.IsOpen=true; }
            e.Handled=true;
            return;
        }
        if (FindParent<TreeViewItem>(source) is { DataContext: LibraryEntry entry })
        {
            contextEntry=entry;
            FileTreeContextMenu.PlacementTarget=Files; FileTreeContextMenu.IsOpen=true;
            e.Handled=true;
        }
    }
    private void FileTreeContextMenuOpened(object sender, RoutedEventArgs e)
    {
        var isRoot=contextEntry != null && library.Roots.Contains(contextEntry);
        RemoveRootMenu.IsEnabled=isRoot; RefreshRootMenu.IsEnabled=isRoot;
        ApplyTreeEntryMenu.IsEnabled=CanApplyCurrentSettings;
    }
    private bool CanApplyCurrentSettings => file != null && result != null && !AIBlocksOutput && exactReady && !scheduler.Busy && !previewResize.IsEnabled && !exporting && LookAvailable;
    private void PhotoContextMenuOpened(object sender, RoutedEventArgs e)
    {
        if(sender is not ContextMenu menu) return;
        foreach(var item in menu.Items.OfType<MenuItem>())
            if(string.Equals(item.Header?.ToString(),Loc.Text("应用当前设置"),StringComparison.Ordinal)) item.IsEnabled=CanApplyCurrentSettings;
    }
    private async void OpenInExplorerClicked(object sender, RoutedEventArgs e)
    {
        var entry=ResolveContextEntry(sender);
        if (entry == null || string.IsNullOrEmpty(entry.Path)) return;
        try
        {
            if (entry.IsFolder)
                Process.Start(new ProcessStartInfo(entry.Path) { UseShellExecute=true });
            else
            {
                var item = await Task.Run(() => {
                    Marshal.ThrowExceptionForHR(SHParseDisplayName(entry.Path, IntPtr.Zero, out var parsed, 0, out _));
                    return parsed;
                });
                try { Marshal.ThrowExceptionForHR(SHOpenFolderAndSelectItems(item, 0, IntPtr.Zero, 0)); }
                finally { Marshal.FreeCoTaskMem(item); }
                await EnsureExplorerSelection(entry.Path);
            }
        }
        catch (Exception error) { Report(error); }
    }
    [DllImport("shell32.dll", CharSet=CharSet.Unicode)]
    private static extern int SHParseDisplayName(string name, IntPtr bindContext, out IntPtr item, uint attributes, out uint resultAttributes);
    [DllImport("shell32.dll")]
    private static extern int SHOpenFolderAndSelectItems(IntPtr item, uint count, IntPtr children, uint flags);
    private static async Task EnsureExplorerSelection(string path)
    {
        var parent=Path.GetDirectoryName(path)!;
        dynamic shell=Activator.CreateInstance(Type.GetTypeFromProgID("Shell.Application")!)!;
        try
        {
            var watch=Stopwatch.StartNew(); var stable=0;
            // RAW 目录首次加载可能丢失 Shell 的初始选择，视图就绪后再明确选中。
            while(watch.Elapsed<TimeSpan.FromSeconds(10))
            {
                stable=SelectExplorerItem(shell,parent,path) ? stable+1 : 0;
                if(stable>=3) return;
                await Task.Delay(100);
            }
            throw new IOException(Loc.Text("资源管理器已打开，但未能选中照片。"));
        }
        finally { Marshal.ReleaseComObject(shell); }
    }
    private static bool SelectExplorerItem(dynamic shell,string parent,string path)
    {
        object? windows=null;
        try
        {
            windows=shell.Windows();
            for(var index=0;index<(int)((dynamic)windows).Count;index++)
            {
                object? window=null,view=null,folder=null,self=null,item=null,selected=null,selection=null;
                try
                {
                    window=((dynamic)windows).Item(index); view=((dynamic)window).Document;
                    folder=((dynamic)view).Folder; self=((dynamic)folder).Self;
                    if(!StringComparer.OrdinalIgnoreCase.Equals((string)((dynamic)self).Path,parent)) continue;
                    selected=((dynamic)view).SelectedItems();
                    if((int)((dynamic)selected).Count==1)
                    {
                        selection=((dynamic)selected).Item(0);
                        if(StringComparer.OrdinalIgnoreCase.Equals((string)((dynamic)selection).Path,path)) return true;
                    }
                    item=((dynamic)folder).ParseName(Path.GetFileName(path));
                    if(item!=null) ((dynamic)view).SelectItem(item,1|4|8|16);
                }
                catch(COMException) { }
                catch(Microsoft.CSharp.RuntimeBinder.RuntimeBinderException) { }
                finally
                {
                    foreach(var value in new[]{selection,selected,item,self,folder,view,window})
                        if(value!=null && Marshal.IsComObject(value)) Marshal.ReleaseComObject(value);
                }
            }
            return false;
        }
        finally { if(windows!=null) Marshal.ReleaseComObject(windows); }
    }
    private async void ApplyCurrentSettingsClicked(object sender, RoutedEventArgs e)
    {
        var entry=ResolveContextEntry(sender);
        if (entry == null || string.IsNullOrEmpty(entry.Path)) return;
        if (file == null) { SetStatus(() => Loc.Text("请先打开一张照片作为调整来源。"),true); return; }
        if (AIBlocksOutput || exporting || scheduler.Busy || previewResize.IsEnabled || !exactReady || result == null || transform.Active)
        {
            SetStatus(() => Loc.Text("精确显影完成后才能应用当前设置。"),true); return;
        }
        if (!LookAvailable) { SetStatus(() => Loc.Text("当前外观不可用，不能应用设置。"),true); return; }
        if(!PrepareAdjustmentCommand())return;
        var source=file;var revision=editRevision;var opened=openRevision;
        try
        {
            var payload=AdjustmentTransfer.Capture(AdjustmentScope.Standard,CaptureCurrentEdit(),CurrentTransferContext());
            LibraryEntry[] targets;
            if (entry.IsFolder)
            {
                targets=await Task.Run(()=>new DirectoryInfo(entry.Path).EnumerateFiles()
                    .Where(child=>(child.Attributes&(FileAttributes.Hidden|FileAttributes.ReparsePoint))==0)
                    .Where(child=>LibraryEntry.IsImage(child.FullName))
                    .Select(child=>new LibraryEntry(child.FullName,false)).ToArray());
            }
            else targets=LibraryEntry.IsImage(entry.Path) ? [entry] : [];
            if(file!=source || openRevision!=opened || editRevision!=revision)return;
            var paths=targets.Select(target=>target.Path).Where(path=>!StringComparer.OrdinalIgnoreCase.Equals(path,source)).ToArray();
            if(paths.Length==0){SetStatus(()=>Loc.Text("此目录没有其他照片。"),true);return;}
            await ShowAdjustmentPreflight(payload,paths);
        }
        catch (Exception error) { Report(error); }
    }
    private void RemoveFolderClicked(object sender,RoutedEventArgs e)
    {
        var entry=ResolveContextEntry(sender) ?? Files.SelectedItem as LibraryEntry;
        if(entry != null && library.Roots.Contains(entry))try{library.Remove(entry);}catch(Exception ex){Report(ex);}
    }
    private void RefreshFolderClicked(object sender,RoutedEventArgs e)
    {
        var entry=ResolveContextEntry(sender) ?? Files.SelectedItem as LibraryEntry;
        if(entry != null && library.Roots.Contains(entry)) { var index=library.Roots.IndexOf(entry);library.Roots[index]=new(entry.Path,true); }
    }
    private void LibraryDragOver(object sender,DragEventArgs e)
    {
        e.Handled=true;e.Effects=DragDropEffects.None;
        if(exporting || closing)return;
        if(e.Data.GetDataPresent(DataFormats.FileDrop,false))
            e.Effects=e.AllowedEffects & DragDropEffects.Copy;
    }
    private void LibraryDropped(object sender,DragEventArgs e)
    {
        e.Handled=true;e.Effects=DragDropEffects.None;
        if(UpdateInstallationActive || exporting || closing || (e.AllowedEffects & DragDropEffects.Copy)==0 || e.Data.GetData(DataFormats.FileDrop) is not string[] paths)return;
        var folders=paths.Where(Directory.Exists).ToArray();
        if(folders.Length>0)
        {
            try{foreach(var folder in folders)library.Add(folder);e.Effects=DragDropEffects.Copy;}
            catch(Exception error){Report(error);}
        }
        else if(paths.FirstOrDefault(path=>File.Exists(path) && LibraryEntry.IsImage(path)) is {} raw)
        {
            OpenFile(raw);e.Effects=DragDropEffects.Copy;
        }
    }
    private void FilesDropped(object sender,DragEventArgs e)
    {
        e.Handled=true;e.Effects=DragDropEffects.None;
        if(UpdateInstallationActive || exporting || closing || (e.AllowedEffects & DragDropEffects.Copy)==0 || e.Data.GetData(DataFormats.FileDrop) is not string[] paths)return;
        var folders=paths.Where(Directory.Exists).ToArray();
        try{foreach(var path in folders)library.Add(path);if(folders.Length>0)e.Effects=DragDropEffects.Copy;}catch(Exception ex){Report(ex);}
        if(paths.FirstOrDefault(path=>File.Exists(path) && LibraryEntry.IsImage(path)) is {} raw){OpenFile(raw);e.Effects=DragDropEffects.Copy;}
    }
    private void LibraryToggle(object sender,RoutedEventArgs e)
    {
        workspaceLayout.ToggleFiles(ActualWidth,library.Roots.Count>0);
        SetFileTreeVisible(workspaceLayout.ShowsFiles(ActualWidth,library.Roots.Count>0));
        RefreshControls();
        QueueThumbnailRefresh();
    }
}
