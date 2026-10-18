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
            button.Click+=(_,_)=>{if(!ResolveTransformDraft())return;OrdinaryParameter.RestoreText();choosingRecipes=false;choosingHsl=false;choosingFilm=false;choosingDenoise=false;choosingPhotoEffects=false;choosingWhiteBalance=false;choosingLens=choosingGeometry=false;selectedParameter=spec.Id;RefreshControls();};
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
            button.Click+=(_,_)=>{if(exporting || !ResolveTransformDraft())return;choosingRecipes=false;choosingHsl=false;choosingFilm=false;choosingDenoise=false;choosingWhiteBalance=false;choosingLens=choosingGeometry=false;choosingPhotoEffects=true;selectedEffect=tool;RefreshControls();};
            Tools.Children.Add(button); effectToolButtons[tool]=(button,ring);
        }
        Tools.Children.Add(GeometryCategory);Tools.Children.Add(LensCategory);FitToolCaptions();
    }
    private void FilmCategoryClicked(object sender,RoutedEventArgs e) { if(!ResolveTransformDraft())return;choosingRecipes=false;choosingHsl=false;choosingFilm=true;choosingDenoise=false;choosingPhotoEffects=false;choosingWhiteBalance=false;choosingLens=choosingGeometry=false;RefreshControls(); }
    private void DenoiseCategoryClicked(object sender,RoutedEventArgs e) { if(!ResolveTransformDraft())return;choosingRecipes=false;choosingHsl=false;choosingDenoise=true;choosingFilm=false;choosingPhotoEffects=false;choosingWhiteBalance=false;choosingLens=choosingGeometry=false;RefreshControls(); }
    private void HslCategoryClicked(object sender,RoutedEventArgs e) { if(!ResolveTransformDraft())return;choosingRecipes=false;choosingHsl=true;choosingDenoise=choosingFilm=choosingPhotoEffects=false;choosingWhiteBalance=false;choosingLens=choosingGeometry=false;RefreshControls(); }
    private void WhiteBalanceCategoryClicked(object sender,RoutedEventArgs e) { if(!ResolveTransformDraft())return;choosingRecipes=false;choosingWhiteBalance=true;choosingHsl=choosingDenoise=choosingFilm=choosingPhotoEffects=false;choosingLens=choosingGeometry=false;RefreshControls(); }
    private void LensCategoryClicked(object sender,RoutedEventArgs e)=>BeginTransform(TransformTool.Lens);
    private void GeometryCategoryClicked(object sender,RoutedEventArgs e)=>BeginTransform(TransformTool.Geometry);
    private void BuildFilms()
    {
        FilmStrip.Children.Clear(); filmButtons.Clear();
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
        var importButton=new Button{Content=importContent,Style=(Style)FindResource("FilmButton"),ToolTip=Loc.Text("导入兼容 CUBE 或 RLOOK，可选择多个文件")};
        AutomationProperties.SetName(importButton,Loc.Text("导入外观"));importButton.Click+=ImportClicked;FilmStrip.Children.Add(importButton);
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
            FilmCategoryRing.Selected=choosingFilm;FilmCategoryRing.InvalidateVisual();
            foreach(var (tool,controls) in effectToolButtons)
            {
                var selected=choosingPhotoEffects && selectedEffect==tool;
                controls.Button.Tag=selected ? "selected" : null;
                controls.Ring.Selected=selected;
                controls.Ring.Progress=settings.IsEffectDefault(tool==PhotoEffectTool.Vignette) ? 0 : 1;
                controls.Ring.InvalidateVisual();
            }
            ExposureMode.SelectedIndex=settings.ExposureMode;
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
        }
        finally { syncing=false; }
    }
    private void UpdateBusy()
    {
        ExportJpeg.IsEnabled=ExportPng.IsEnabled=ExportDng.IsEnabled=BatchExportMenu.IsEnabled=exactReady && !scheduler.Busy && !previewResize.IsEnabled && !exporting && result!=null && LookAvailable && !transform.Active;
        ViewBatchMenu.IsEnabled=CurrentBatch!=null;
        MenuViewBatch.IsEnabled=ViewBatchMenu.IsEnabled;
        AutoExposureButton.IsEnabled=MenuAutoExposure.IsEnabled=file!=null && result!=null && !autoExposing && !exporting && !scheduler.Busy && !transform.Active;
        MenuAsShot.IsEnabled=AsShotButton.IsEnabled;
        ExportButton.IsEnabled=ExportJpeg.IsEnabled || ExportPng.IsEnabled || ExportDng.IsEnabled || ViewBatchMenu.IsEnabled;
        MenuExport.IsEnabled=ExportJpeg.IsEnabled;MenuBatch.IsEnabled=BatchExportMenu.IsEnabled;
        ApplyDraftButton.IsEnabled=CanApplyTransform;
        HistogramSurface.Visibility=result!=null ? Visibility.Visible : Visibility.Collapsed;
        CompareButton.IsEnabled=ClippingButton.IsEnabled=InfoButton.IsEnabled=AdjustToggleButton.IsEnabled=file!=null && !exporting;
        AdjustmentPanel.IsEnabled=!exporting;GpuMode.IsEnabled=!exporting && (file==null || !LibraryEntry.IsRaster(file));
        BusyIndicator.Visibility=scheduler.Busy || previewResize.IsEnabled || exporting ? Visibility.Visible : Visibility.Collapsed;
        RetryButton.Visibility=renderFailed && !scheduler.Busy && !exporting ? Visibility.Visible : Visibility.Collapsed;
        ExportButton.ToolTip=file==null ? Loc.Text("打开 RAW 照片后导出") : transform.Active ? Loc.Text("草稿预览 · 尚未应用") :
            !exactReady || scheduler.Busy || previewResize.IsEnabled ? Loc.Text("请等待预览完成后导出。") : Loc.Text("导出照片（尺寸可选）");
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
