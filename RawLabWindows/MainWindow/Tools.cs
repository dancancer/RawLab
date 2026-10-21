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
    private Button? importLookButton;

    private void AboutClicked(object sender, RoutedEventArgs e)
    {
        if (aboutWindow == null)
        {
            aboutWindow = new AboutWindow(updates, usageAnalytics) { Owner = this };
            aboutWindow.Closed += (_, _) => aboutWindow = null;
            aboutWindow.Show();
        }
        else aboutWindow.Activate();
    }
    private void BuildTools()
    {
        Tools.Children.Clear();toolButtons.Clear();effectToolButtons.Clear();
        Tools.Children.Add(FilmCategory);Tools.Children.Add(MasterRecipeCategory);
        foreach(var id in new[]{Parameter.Strength,Parameter.Exposure,Parameter.Highlights,Parameter.Shadows,Parameter.Contrast,
            Parameter.ToneCurve,Parameter.Saturation,Parameter.Sharpening})
        {
            if(id==Parameter.Sharpening)
            {
                Tools.Children.Add(HslCategory);
                Tools.Children.Add(WhiteBalanceCategory);
                Tools.Children.Add(DenoiseCategory);
            }
            var spec=ParameterSpec.All[(int)id];
            var ring=new AdjustmentRing{Width=40,Height=40};
            var grid=new Grid(); grid.Children.Add(ring); grid.Children.Add(new EditorIcon{Kind=spec.Id.ToString(),Width=20,Height=20});
            var caption=new TextBlock{Text=Loc.Text(spec.Title),MaxWidth=70,TextWrapping=TextWrapping.Wrap,TextAlignment=TextAlignment.Center,HorizontalAlignment=HorizontalAlignment.Center,Margin=new Thickness(0,4,0,0)};
            caption.SetResourceReference(TextBlock.FontSizeProperty,"EditorCaptionSize");
            var stack=new StackPanel();stack.Children.Add(grid);stack.Children.Add(caption);
            var button=new Button{Content=stack,Style=(Style)FindResource("ToolButton"),ToolTip=Loc.Text(spec.Title)};
            AutomationProperties.SetName(button,Loc.Text(spec.Title));
            button.Click+=(_,_)=>SelectTool(ToolFor(spec.Id));
            Tools.Children.Add(button); toolButtons[spec.Id]=(button,ring);
        }
        foreach(var (tool,title,icon) in new[] {
            (PhotoEffectTool.Vignette,Loc.Text("暗角"),"Vignette"), (PhotoEffectTool.Grain,Loc.Text("颗粒"),"Grain")
        })
        {
            var ring=new AdjustmentRing{Width=40,Height=40};
            var grid=new Grid(); grid.Children.Add(ring); grid.Children.Add(new EditorIcon{Kind=icon,Width=20,Height=20});
            var caption=new TextBlock{Text=title,MaxWidth=70,TextWrapping=TextWrapping.Wrap,HorizontalAlignment=HorizontalAlignment.Center,Margin=new Thickness(0,4,0,0)};
            caption.SetResourceReference(TextBlock.FontSizeProperty,"EditorCaptionSize");
            var stack=new StackPanel();stack.Children.Add(grid);stack.Children.Add(caption);
            var button=new Button{Content=stack,Style=(Style)FindResource("ToolButton"),ToolTip=title};
            AutomationProperties.SetName(button,title);
            AutomationProperties.SetAutomationId(button,tool.ToString());
            button.Click+=(_,_)=>SelectTool(tool==PhotoEffectTool.Vignette ? EditorAdjustmentTool.Vignette : EditorAdjustmentTool.Grain);
            Tools.Children.Add(button); effectToolButtons[tool]=(button,ring);
        }
        Tools.Children.Add(GeometryCategory);Tools.Children.Add(LensCategory);BuildWorkspaceNavigation();FitToolCaptions();
    }
    private void FilmCategoryClicked(object sender,RoutedEventArgs e) => SelectTool(EditorAdjustmentTool.Film);
    private void DenoiseCategoryClicked(object sender,RoutedEventArgs e) => SelectTool(EditorAdjustmentTool.Denoise);
    private void HslCategoryClicked(object sender,RoutedEventArgs e) => SelectTool(EditorAdjustmentTool.Hsl);
    private void WhiteBalanceCategoryClicked(object sender,RoutedEventArgs e) => SelectTool(EditorAdjustmentTool.WhiteBalance);
    private void LensCategoryClicked(object sender,RoutedEventArgs e) => SelectTool(EditorAdjustmentTool.Lens);
    private void GeometryCategoryClicked(object sender,RoutedEventArgs e) => SelectTool(EditorAdjustmentTool.Geometry);

    private EditorAdjustmentGroup? expandedGroup = EditorAdjustmentGroup.Light;
    private readonly Dictionary<EditorAdjustmentGroup,Button> groupButtons = [];
    private readonly Dictionary<EditorAdjustmentTool,(Button Button,AdjustmentRing Ring)> workspaceTools = [];
    private EditorAdjustmentTool CurrentTool => choosingFilm ? EditorAdjustmentTool.Film : choosingRecipes ? EditorAdjustmentTool.MasterRecipe :
        choosingHsl ? EditorAdjustmentTool.Hsl : choosingWhiteBalance ? EditorAdjustmentTool.WhiteBalance : choosingDenoise ? EditorAdjustmentTool.Denoise :
        choosingGeometry ? EditorAdjustmentTool.Geometry : choosingLens ? EditorAdjustmentTool.Lens :
        choosingPhotoEffects ? selectedEffect==PhotoEffectTool.Vignette ? EditorAdjustmentTool.Vignette : EditorAdjustmentTool.Grain : ToolFor(selectedParameter);
    private static EditorAdjustmentTool ToolFor(Parameter parameter) => parameter switch {
        Parameter.Temperature or Parameter.Tint => EditorAdjustmentTool.WhiteBalance,
        _ => Enum.GetValues<EditorAdjustmentTool>().First(tool => (tool is EditorAdjustmentTool.Strength or EditorAdjustmentTool.Exposure or
            EditorAdjustmentTool.Highlights or EditorAdjustmentTool.Shadows or EditorAdjustmentTool.Contrast or EditorAdjustmentTool.ToneCurve or
            EditorAdjustmentTool.Saturation or EditorAdjustmentTool.Sharpening) && EditorAdjustmentRules.ParameterFor(tool)==parameter)
    };
    private void BuildWorkspaceNavigation()
    {
        Groups.Children.Clear();groupButtons.Clear();workspaceTools.Clear();
        foreach(var group in Enum.GetValues<EditorAdjustmentGroup>()) {
            var button=new Button { Content=Loc.Text(EditorAdjustmentRules.Title(group)),MinHeight=36,MinWidth=80,Padding=new Thickness(12,5,12,5) };
            AutomationProperties.SetAutomationId(button,"editor.group."+EditorAdjustmentRules.Id(group));
            button.Click+=(_,_)=>SelectGroup(group);groupButtons[group]=button;Groups.Children.Add(button);
        }
        workspaceTools[EditorAdjustmentTool.Film]=(FilmCategory,FilmCategoryRing);
        workspaceTools[EditorAdjustmentTool.MasterRecipe]=(MasterRecipeCategory,MasterRecipeCategoryRing);
        workspaceTools[EditorAdjustmentTool.WhiteBalance]=(WhiteBalanceCategory,WhiteBalanceCategoryRing);
        workspaceTools[EditorAdjustmentTool.Hsl]=(HslCategory,HslCategoryRing);
        workspaceTools[EditorAdjustmentTool.Denoise]=(DenoiseCategory,DenoiseCategoryRing);
        workspaceTools[EditorAdjustmentTool.Geometry]=(GeometryCategory,GeometryCategoryRing);
        workspaceTools[EditorAdjustmentTool.Lens]=(LensCategory,LensCategoryRing);
        foreach(var (parameter,controls) in toolButtons)workspaceTools[ToolFor(parameter)]=controls;
        foreach(var (tool,controls) in effectToolButtons)workspaceTools[tool==PhotoEffectTool.Vignette ? EditorAdjustmentTool.Vignette : EditorAdjustmentTool.Grain]=controls;
        foreach(var (tool,controls) in workspaceTools)AutomationProperties.SetAutomationId(controls.Button,tool.ToString());
        // 同一描述表决定工具顺序、默认工具与重置范围。
        Tools.Children.Clear();foreach(var group in Enum.GetValues<EditorAdjustmentGroup>())foreach(var tool in EditorAdjustmentRules.Tools(group))Tools.Children.Add(workspaceTools[tool].Button);
    }
    private void SelectGroup(EditorAdjustmentGroup group)
    {
        if(file==null || exporting || pendingAllReset!=null)return;
        if(expandedGroup==group) {
            if(!ResolveTransformDraft())return;
            dockHeight=DockRow.ActualHeight;expandedGroup=null;RefreshWorkspaceNavigation();
            DockRow.MinHeight=0;DockRow.Height=GridLength.Auto;AdjustmentSplitter.Visibility=Visibility.Collapsed;SplitterRow.Height=new(0);
            return;
        }
        SelectTool(EditorAdjustmentRules.DefaultTool(group));
    }
    private void SelectTool(EditorAdjustmentTool tool)
    {
        if(file==null || exporting || pendingAllReset!=null)return;
        OrdinaryParameter.RestoreText();
        if(tool is EditorAdjustmentTool.Geometry or EditorAdjustmentTool.Lens) {
            BeginTransform(tool==EditorAdjustmentTool.Geometry ? TransformTool.Geometry : TransformTool.Lens);
            if(!transform.Active || (transform.Tool==TransformTool.Geometry)!=(tool==EditorAdjustmentTool.Geometry))return;
        } else {
            if(!ResolveTransformDraft())return;
            choosingFilm=tool==EditorAdjustmentTool.Film;choosingRecipes=tool==EditorAdjustmentTool.MasterRecipe;
            choosingHsl=tool==EditorAdjustmentTool.Hsl;choosingWhiteBalance=tool==EditorAdjustmentTool.WhiteBalance;
            choosingDenoise=tool==EditorAdjustmentTool.Denoise;choosingPhotoEffects=tool is EditorAdjustmentTool.Vignette or EditorAdjustmentTool.Grain;
            choosingGeometry=choosingLens=false;
            if(choosingPhotoEffects)selectedEffect=tool==EditorAdjustmentTool.Vignette ? PhotoEffectTool.Vignette : PhotoEffectTool.Grain;
            else if(!choosingFilm && !choosingRecipes && !choosingHsl && !choosingWhiteBalance && !choosingDenoise)selectedParameter=EditorAdjustmentRules.ParameterFor(tool);
        }
        var wasCollapsed=expandedGroup==null;expandedGroup=EditorAdjustmentRules.GroupFor(tool);
        if(wasCollapsed){DockRow.Height=new(dockHeight);DockRow.MinHeight=216;AdjustmentSplitter.Visibility=Visibility.Visible;SplitterRow.Height=new(6);UpdateDockMinimum();}
        RefreshControls();
    }
    private SavedEdit? WorkspaceEdit()
    {
        if(file==null)return null;
        try {
            var edit=CaptureCurrentEdit();return transform.Active ? edit with { Settings=edit.Settings.Copy() with { Geometry=transform.Geometry,Lens=transform.Lens } } : edit;
        } catch(Exception error) when(error is IOException or UnauthorizedAccessException) {return null;}
    }
    private void RefreshWorkspaceNavigation()
    {
        var edit=WorkspaceEdit();
        bool Modified(EditorResetScope scope) {try{return edit!=null && EditorAdjustmentRules.IsModified(scope,edit);}catch(ArgumentException){return false;}catch(InvalidDataException){return false;}}
        foreach(var (group,button) in groupButtons) {
            var modified=Modified(new(EditorResetKind.Group,group));var selected=expandedGroup==group;
            button.Content=Loc.Text(EditorAdjustmentRules.Title(group))+(modified ? " •" : "");button.Tag=selected ? "selected" : null;
            AutomationProperties.SetName(button,Loc.Text(EditorAdjustmentRules.Title(group)));
            AutomationProperties.SetItemStatus(button,string.Join(" · ",new[]{selected ? Loc.Format("收起{0}组",Loc.Text(EditorAdjustmentRules.Title(group))) : Loc.Format("展开{0}组",Loc.Text(EditorAdjustmentRules.Title(group))),modified ? Loc.Text("已调整") : ""}.Where(value=>value.Length>0)));
            button.IsEnabled=file!=null && !exporting && pendingAllReset==null;
        }
        foreach(var (tool,controls) in workspaceTools) {
            controls.Button.Visibility=expandedGroup==EditorAdjustmentRules.GroupFor(tool) ? Visibility.Visible : Visibility.Collapsed;
            var modified=Modified(new(EditorResetKind.Tool,Tool:tool));
            controls.Ring.Progress=modified ? (controls.Ring.Progress==0 ? 1 : controls.Ring.Progress) : 0;controls.Ring.InvalidateVisual();
            AutomationProperties.SetItemStatus(controls.Button,string.Join(" · ",new[]{CurrentTool==tool ? Loc.Text("当前工具") : "",modified ? Loc.Text("已调整") : ""}.Where(value=>value.Length>0)));
        }
        var expanded=expandedGroup!=null;
        DockHeader.Visibility=ToolsScroller.Visibility=expanded ? Visibility.Visible : Visibility.Collapsed;
        if(!expanded)foreach(var panel in new FrameworkElement[]{ParameterPanel,FilmPanel,MasterRecipePanel,DenoiseSurface,LensSurface,GeometrySurface,HslSurface,WhiteBalanceSurface,PhotoEffectsSurface,DraftActions})panel.Visibility=Visibility.Collapsed;
    }
    private void BuildFilms()
    {
        FilmStrip.Children.Clear(); filmButtons.Clear(); importLookButton=null;
        foreach(var item in FilmGrouping.Arrange(films,film=>film.Path==null,film=>film.Group))
        {
            var film=item.Value;
            if(item.StartsGroup)
            {
                var divider=new Border{Width=1,Height=84,Margin=new Thickness(12,0,12,0)};
                divider.SetResourceReference(Border.BackgroundProperty,"Outline");
                AutomationProperties.SetAutomationId(divider,"film.group-divider."+film.Group);
                FilmStrip.Children.Add(divider);
            }
            var stack=new StackPanel();
            if(film.Artwork!=null && File.Exists(film.Artwork))stack.Children.Add(new Image{Source=new BitmapImage(new Uri(film.Artwork)),Width=64,Height=64});
            else stack.Children.Add(new EditorIcon{Kind=film.Path==null ? "Neutral" : "Film",Width=32,Height=64});
            var displayName=film.Path==null ? Loc.Text("中性") : film.Name;
            var additional=film.Path!=null && BundledLook.All.ContainsKey(Path.GetFileName(film.Path));
            var caption=new TextBlock{Text=displayName,Width=additional ? 132 : 80,MinHeight=30,TextWrapping=TextWrapping.Wrap,TextAlignment=TextAlignment.Center,Margin=new Thickness(0,5,0,0)};
            caption.SetResourceReference(TextBlock.FontSizeProperty,"EditorCaptionSize");stack.Children.Add(caption);
            var button=new Button{Content=stack,Style=(Style)FindResource("FilmButton"),ToolTip=film.Path ?? Loc.Text("中性显影")};
            if(additional)button.Width=146;
            AutomationProperties.SetName(button,displayName);
            button.Click+=(_,_)=>{
                if(exporting || !ResolveTransformDraft() || (settings.MasterRecipeID == null && lut == film.Path))return;
                settings.ClearMasterRecipe();
                lut=film.Path;
                usageAnalytics.Record(new FilmSelectedEvent(film.Path == null ? FilmKind.None : IsBuiltInLook(film.Path) ? FilmKind.BuiltIn : FilmKind.Custom));
                MarkEdited();RefreshControls();Schedule();
            };
            FilmStrip.Children.Add(button); filmButtons[film.Path ?? ""]=button;
        }
        var importContent=new StackPanel();
        importContent.Children.Add(new EditorIcon{Kind="Add",Width=26,Height=64});
        var importCaption=new TextBlock{Text=Loc.Text("导入外观"),MinHeight=30,TextWrapping=TextWrapping.Wrap,TextAlignment=TextAlignment.Center,Margin=new Thickness(0,5,0,0)};
        importCaption.SetResourceReference(TextBlock.FontSizeProperty,"EditorCaptionSize");importContent.Children.Add(importCaption);
        var importButton=new Button{Content=importContent,Style=(Style)FindResource("FilmButton"),ToolTip=Loc.Text("导入兼容 CUBE、RLOOK 或 DCP，可选择多个文件")};
        AutomationProperties.SetName(importButton,Loc.Text("导入外观"));importButton.IsEnabled=!exporting;importButton.Click+=ImportClicked;FilmStrip.Children.Add(importButton);
        importLookButton=importButton;
    }
    private void RefreshControls()
    {
        if(!ready)return;
        syncing=true;
        try
        {
            var raster=file!=null && LibraryEntry.IsRaster(file);
            if(raster)settings=RenderEngine.PrepareInputSettings(file!,settings);
            if(raster)
            {
                rasterPreviousGpuMode ??= GpuMode.SelectedIndex;
                GpuMode.SelectedIndex=1;
            }
            else if(rasterPreviousGpuMode is {} previousMode)
            {rasterPreviousGpuMode=null;GpuMode.SelectedIndex=previousMode;}
            var spec=ParameterSpec.All[(int)selectedParameter];
            OrdinaryParameter.Refresh(Loc.Text(spec.Title),NumericRange.For(spec),settings[selectedParameter],settings.Default(selectedParameter),spec.Unit);
            AutomationProperties.SetName(ValueSlider,Loc.Text(spec.Title));
            AutomationProperties.SetName(ValueText,Loc.Format("{0}数值（{1}）",Loc.Text(spec.Title),spec.Unit));
            var canAdjust=file!=null && !exporting && !choosingFilm && !choosingPhotoEffects && (selectedParameter!=Parameter.Strength || lut!=null) && (selectedParameter is not(Parameter.Temperature or Parameter.Tint) || settings.AsShot!=null);
            ValueSlider.IsEnabled=ValueText.IsEnabled=canAdjust;
            FilmPanel.Visibility=choosingFilm ? Visibility.Visible : Visibility.Collapsed;
            MasterRecipePanel.Visibility=choosingRecipes ? Visibility.Visible : Visibility.Collapsed;
            MasterRecipeCategory.Tag=choosingRecipes ? "selected" : null;MasterRecipeCategoryRing.Selected=choosingRecipes;MasterRecipeCategoryRing.Progress=settings.MasterRecipeID==null ? 0 : 1;MasterRecipeCategoryRing.InvalidateVisual();
            foreach(var pair in recipeButtons)pair.Value.Tag=pair.Key==(settings.MasterRecipeID ?? "") ? "selected" : null;
            ParameterPanel.Visibility=choosingRecipes || choosingFilm || choosingDenoise || choosingPhotoEffects || choosingHsl || choosingWhiteBalance || choosingLens || choosingGeometry ? Visibility.Collapsed : Visibility.Visible;
            LensEditor.Visibility=choosingLens ? Visibility.Visible : Visibility.Collapsed;
            LensSurface.Visibility=LensEditor.Visibility;
            LensEditor.IsEnabled=file!=null && !raster && !exporting;LensEditor.Refresh(PreviewLens,result?.Lens);
            LensCategory.IsEnabled=file!=null && !raster && !exporting;
            LensCategory.Tag=choosingLens ? "selected" : null;
            LensCategoryRing.Selected=choosingLens;LensCategoryRing.Progress=settings.Lens.Enabled ? 1 : 0;LensCategoryRing.InvalidateVisual();
            GeometrySurface.Visibility=choosingGeometry ? Visibility.Visible : Visibility.Collapsed;
            GeometryEditor.IsEnabled=file!=null && !exporting;GeometryEditor.Refresh(transform.Active ? transform.Geometry : settings.Geometry);
            GeometryCategory.IsEnabled=file!=null && !exporting;GeometryCategory.Tag=choosingGeometry ? "selected" : null;
            GeometryCategoryRing.Selected=choosingGeometry;GeometryCategoryRing.Progress=settings.Geometry.IsIdentity ? 0 : 1;GeometryCategoryRing.InvalidateVisual();
            HslSurface.Visibility=choosingHsl ? Visibility.Visible : Visibility.Collapsed;
            HslEditor.IsEnabled=file!=null && !exporting;HslEditor.Refresh(settings.Hsl);
            HslCategory.Tag=choosingHsl ? "selected" : null;
            HslCategoryRing.Selected=choosingHsl;HslCategoryRing.Progress=settings.Hsl.IsIdentity ? 0 : 1;HslCategoryRing.InvalidateVisual();
            WhiteBalanceSurface.Visibility=choosingWhiteBalance ? Visibility.Visible : Visibility.Collapsed;
            WhiteBalanceEditor.IsEnabled=file!=null && !raster && !exporting;
            WhiteBalanceEditor.Refresh(settings,WhiteBalanceEditor.IsEnabled && settings.AsShot!=null);
            WhiteBalanceCategory.IsEnabled=file!=null && !raster && !exporting;
            WhiteBalanceCategory.Tag=choosingWhiteBalance ? "selected" : null;
            WhiteBalanceCategoryRing.Selected=choosingWhiteBalance;
            var temperatureSpec=ParameterSpec.All[(int)Parameter.Temperature];
            var temperatureOrigin=temperatureSpec.Position(settings.Default(Parameter.Temperature));
            var temperatureOffset=temperatureSpec.Position(settings[Parameter.Temperature])-temperatureOrigin;
            var temperatureProgress=temperatureOffset==0 ? 0 : temperatureOffset/(temperatureOffset<0 ? temperatureOrigin : 1-temperatureOrigin);
            var tintSpec=ParameterSpec.All[(int)Parameter.Tint];
            var tintOrigin=tintSpec.Position(settings.Default(Parameter.Tint));
            var tintOffset=tintSpec.Position(settings[Parameter.Tint])-tintOrigin;
            var tintProgress=tintOffset==0 ? 0 : tintOffset/(tintOffset<0 ? tintOrigin : 1-tintOrigin);
            WhiteBalanceCategoryRing.Progress=Math.Abs(temperatureProgress)>=Math.Abs(tintProgress) ? temperatureProgress : tintProgress;
            WhiteBalanceCategoryRing.InvalidateVisual();
            AutoExposureButton.Visibility=selectedParameter==Parameter.Exposure ? Visibility.Visible : Visibility.Collapsed;
            AutoExposureButton.IsEnabled=file!=null && result!=null && !autoExposing && !exporting && !scheduler.Busy && !transform.Active;
            DenoiseEditor.Visibility=choosingDenoise ? Visibility.Visible : Visibility.Collapsed;
            DenoiseSurface.Visibility=DenoiseEditor.Visibility;
            DenoiseEditor.IsEnabled=file!=null && !exporting;DenoiseEditor.Refresh(settings.Denoise);
            PhotoEffectsSurface.Visibility=choosingPhotoEffects ? Visibility.Visible : Visibility.Collapsed;
            PhotoEffectsEditor.IsEnabled=file!=null && !exporting;PhotoEffectsEditor.Refresh(settings.Effects,selectedEffect);
            DenoiseCategory.Tag=choosingDenoise ? "selected" : null;
            DenoiseCategoryRing.Selected=choosingDenoise;
            DenoiseCategoryRing.Progress=settings.Denoise.Enabled ? 1 : 0;DenoiseCategoryRing.InvalidateVisual();
            FilmCategory.Tag=choosingFilm ? "selected" : null;
            FilmCategory.IsEnabled=!exporting;
            FilmCategoryRing.Selected=choosingFilm;FilmCategoryRing.InvalidateVisual();
            if(importLookButton!=null)importLookButton.IsEnabled=!exporting;
            foreach(var (tool,controls) in effectToolButtons)
            {
                var selected=choosingPhotoEffects && selectedEffect==tool;
                controls.Button.Tag=selected ? "selected" : null;
                controls.Ring.Selected=selected;
                controls.Ring.Progress=settings.IsEffectDefault(tool==PhotoEffectTool.Vignette) ? 0 : 1;
                controls.Ring.InvalidateVisual();
            }
            ExposureMode.SelectedIndex=settings.ExposureMode;
            ProcessingVersion.SelectedIndex=settings.Processing.Version-1;
            ProcessingVersion.IsEnabled=file!=null && !exporting && !transform.Active && pendingAllReset==null;
            ExposureMode.IsEnabled=ResetAllButton.IsEnabled=file!=null && !exporting;
            ExposureMode.IsEnabled=ExposureMode.IsEnabled && !raster && !transform.Active;
            ResetParameterButton.IsEnabled=ResetGroupButton.IsEnabled=canAdjust;
            AsShotButton.IsEnabled=file!=null && !exporting && settings.AsShot!=null && !transform.Active;
            DraftActions.Visibility=transform.Active ? Visibility.Visible : Visibility.Collapsed;
            ApplyDraftButton.IsEnabled=CanApplyTransform;
            foreach(var (id,controls) in toolButtons)
            {
                controls.Button.IsEnabled=file!=null && !exporting;
                var selected=!choosingRecipes && !choosingHsl && !choosingFilm && !choosingDenoise && !choosingPhotoEffects && !choosingWhiteBalance && !choosingLens && !choosingGeometry && id==selectedParameter;
                controls.Button.Tag=selected ? "selected" : null;
                controls.Ring.Selected=selected;
                var p=ParameterSpec.All[(int)id]; var origin=p.Position(settings.Default(id)); var offset=p.Position(settings[id])-origin;
                controls.Ring.Progress=offset==0 ? 0 : offset/(offset<0 ? origin : 1-origin); controls.Ring.InvalidateVisual();
            }
            foreach(var pair in filmButtons)pair.Value.Tag=pair.Key==(lut ?? "") ? "selected" : null;
            var lookTitle=LookTitle;
            ActiveFilm.Text=lookTitle;FilmLabelText.Text=lut==null ? Loc.Text("调整后") : lookTitle;ActiveFilm.ToolTip=lookTitle;
            NeutralLabel.Visibility=FilmLabel.Visibility=compare && result!=null ? Visibility.Visible : Visibility.Collapsed;
            RefreshComparisonLayout();
            RefreshComparisonSelection();
            ClippingButton.Tag=clipping ? "selected" : null;
            InfoButton.Tag=photoInfoMode == PhotoInfoMode.Hidden ? null : "selected";
            LibraryToggleButton.Tag=LibraryPanel.Visibility==Visibility.Visible ? "selected" : null;
            AdjustToggleButton.Tag=AdjustmentPanel.Visibility==Visibility.Visible ? "selected" : null;
            UpdateBusy();
            RefreshExportSizeMenu();
            RefreshWorkspaceNavigation();
        }
        finally { syncing=false; }
    }
    private void UpdateBusy()
    {
        ExportJpeg.IsEnabled=ExportPng.IsEnabled=ExportDng.IsEnabled=BatchExportMenu.IsEnabled=pendingAllReset==null && exactReady && !scheduler.Busy && !previewResize.IsEnabled && !exporting && result!=null && LookAvailable && !transform.Active;
        ViewBatchMenu.IsEnabled=CurrentBatch!=null;
        MenuViewBatch.IsEnabled=ViewBatchMenu.IsEnabled;
        AutoExposureButton.IsEnabled=MenuAutoExposure.IsEnabled=file!=null && result!=null && !autoExposing && !exporting && !scheduler.Busy && !transform.Active;
        MenuAsShot.IsEnabled=AsShotButton.IsEnabled;
        ExportButton.IsEnabled=ExportJpeg.IsEnabled || ExportPng.IsEnabled || ExportDng.IsEnabled || ViewBatchMenu.IsEnabled;
        MenuExport.IsEnabled=ExportJpeg.IsEnabled;MenuBatch.IsEnabled=BatchExportMenu.IsEnabled;
        ApplyDraftButton.IsEnabled=CanApplyTransform;
        QueuePendingReset();
        MenuImportLook.IsEnabled=!exporting;
        HistogramSurface.Visibility=result!=null ? Visibility.Visible : Visibility.Collapsed;
        RefreshStateToolTips();
        CompareButton.IsEnabled=ClippingButton.IsEnabled=InfoButton.IsEnabled=AdjustToggleButton.IsEnabled=file!=null && !exporting;
        AdjustmentPanel.IsEnabled=!exporting && !pendingResetReady;GpuMode.IsEnabled=!exporting && (file==null || !LibraryEntry.IsRaster(file));
        BusyIndicator.Visibility=scheduler.Busy || previewResize.IsEnabled || exporting ? Visibility.Visible : Visibility.Collapsed;
        RetryButton.Visibility=renderFailed && !scheduler.Busy && !exporting ? Visibility.Visible : Visibility.Collapsed;
        ExportButton.ToolTip=file==null ? Loc.Text("载入照片后可用") : transform.Active ? Loc.Text("草稿未应用，无法导出或复制设置。") :
            renderFailed ? Status.Text :
            !exactReady || scheduler.Busy || previewResize.IsEnabled ? Loc.Text("请等待预览完成后导出。") : Loc.Text("导出");
        ToolTipService.SetShowOnDisabled(ExportButton,true);
        ToolTipService.SetShowOnDisabled(ExportJpeg,true);ToolTipService.SetShowOnDisabled(ExportPng,true);ToolTipService.SetShowOnDisabled(ExportDng,true);
    }
    private void SetStatus(string text,bool error=false) { localizedStatus=null; Status.Text=text; Status.ToolTip=text; Status.SetResourceReference(TextBlock.ForegroundProperty,error ? "ErrorForeground" : "StatusForeground"); }
    private void SetStatus(Func<string> text,bool error=false) { SetStatus(text(),error); localizedStatus=text; }
    private void RefreshRenderLabels()
    {
        // 没有显影结果：正在打开时说明在显影；空闲或失败时只留平台与色彩空间，不沿用过时的进度
        if (result == null) { BackendLabel.Text=file != null && !renderFailed ? Loc.Text("相机预览 · 正在显影") : "Windows · sRGB"; return; }
        BackendLabel.Text=$"{(result.Backend==3 ? "Direct3D 11 · GPU" : renderedGpuMode==0 || (file!=null && LibraryEntry.IsRaster(file)) ? "CPU" : Loc.Text("CPU · GPU 已回退"))} · sRGB";
        ClipStats.Text=Loc.Format("暗部 {0:P1}   高光 {1:P1} · 显示图统计", result.Shadows, result.Highlights);
        var raster=file!=null && LibraryEntry.IsRaster(file);
        BaselineLabel.Text=raster ? Loc.Text("显示图像") : Loc.Format("基础偏移 {0:+0.00;-0.00;0.00} EV", result.Baseline);
        AsShotButton.ToolTip=raster ? Loc.Text("不适用") : result.WhiteBalance==null ? Loc.Text("此 RAW 缺少有效校准，使用相机原始白平衡") : Loc.Format("拍摄时：{0} K / {1}", result.WhiteBalance.Value.Temperature, result.WhiteBalance.Value.Tint);
    }
    private void RetryClicked(object sender,RoutedEventArgs e)=>Schedule();
    private void Report(Exception error)=>SetStatus(error is DllNotFoundException or BadImageFormatException or EntryPointNotFoundException
        ? Loc.Text("无法加载显影组件。请通过 build.ps1 构建，并保留程序目录内的 DLL。") : error.Message,true);
}
