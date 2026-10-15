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
public partial class MainWindow : Window
{
    internal Slider ValueSlider => OrdinaryParameter.Slider;
    internal TextBox ValueText => OrdinaryParameter.Number;
    private Button ResetParameterButton => OrdinaryParameter.ResetButton;
    private record Film(string Name,string? Path,string? Artwork);
    private record Work(string File,Adjustments Settings,string? Lut,int Edge,bool Interactive,int GpuMode,bool Compare,bool Clipping,bool Refine,long TransformGeneration);
    private readonly Library library=new();
    private readonly Viewport viewport=new();
    private readonly List<Film> films=[];
    private readonly LatestWork<Work> scheduler=new();
    private record EmbeddedWork(string Path,long Revision);
    private readonly LatestWork<EmbeddedWork> embeddedScheduler=new();
    private long openRevision;
    private readonly Dictionary<Parameter,(Button Button,AdjustmentRing Ring)> toolButtons=[];
    private readonly Dictionary<PhotoEffectTool,(Button Button,AdjustmentRing Ring)> effectToolButtons=[];
    private readonly Dictionary<string,Button> filmButtons=new(StringComparer.OrdinalIgnoreCase);
    private Adjustments settings=new();
    private Parameter selectedParameter=Parameter.Exposure;
    private string? file,lut;
    private RenderEngine? engine;
    private bool ready,syncing,interacting,foregroundBusy,closing,closeFinished,exactReady;
    // The modeless batch owns its lifetime; foreground completion must not clear it.
    private bool exporting=>foregroundBusy || batchWindow?.Busy==true;
    private bool compare=true,clipping,choosingFilm,choosingDenoise,choosingPhotoEffects,choosingLens,choosingGeometry,swipe;
    private PhotoEffectTool selectedEffect=PhotoEffectTool.Vignette;
    private bool renderFailed;
    private bool choosingHsl,autoExposing;
    private long editRevision;
    private int? exportLongEdge;
    private string? lastExportedPath;
    private PhotoInfo? photoInfo;
    private PhotoInfoMode photoInfoMode;
    private long photoInfoRevision;
    private LibraryEntry? contextEntry;
    private double dockHeight=288;
    private double libraryWidth=244;
    private RenderedImage? result;
    private int renderedGpuMode;
    private Func<string>? localizedStatus;
    private readonly HashSet<LibraryEntry> visibleThumbnails=[];
    private readonly DispatcherTimer thumbnailRefresh=new(){Interval=TimeSpan.FromMilliseconds(80)};
    private readonly DispatcherTimer previewResize=new(){Interval=TimeSpan.FromMilliseconds(200)};
    private int previewLongEdge=2000,requestedPreviewLongEdge=2000;
    private LibraryEntry? selectedThumbnail;
    private readonly UpdateChecker updates = new(typeof(App).Assembly.GetName().Version?.ToString(3) ?? "unknown");
    private AboutWindow? aboutWindow;
    private readonly CancellationTokenSource updateCancellation = new();
    public MainWindow()
    {
        InitializeComponent();
        if(Application.Current!=null)EditorAppearance.Apply(Application.Current.Resources);
        void RefreshLanguage()
        {
            RecipeStrip.Children.Clear(); recipeButtons.Clear();
            BuildTools(); BuildFilms(); BuildMasterRecipes(); HslEditor.RefreshLanguage();GeometryEditor.RefreshLanguage();
            RefreshControls(); RefreshPhotoInfo(); RefreshExportSizeMenu();
            RefreshRenderLabels();
            RefreshSaveNotice();
            if (localizedStatus != null) { var statusText=localizedStatus(); Status.Text=statusText; Status.ToolTip=statusText; }
            RefreshComparisonToolTip();
            updates.RefreshLanguage();
        }
        Loc.Changed += RefreshLanguage;
        Closed += (_, _) => Loc.Changed -= RefreshLanguage;
        UpdateNotice.DataContext = updates;
        void RefreshUpdateNotice() => UpdateNotice.Visibility = updates.HasUpdate ? Visibility.Visible : Visibility.Collapsed;
        updates.PropertyChanged += (_, _) => RefreshUpdateNotice();
        RefreshUpdateNotice();
        Closed += (_, _) => updateCancellation.Cancel();
        Files.ItemsSource=library.Roots;
        Files.PreviewKeyDown+=FilesContextKeyDown;
        library.Roots.CollectionChanged+=(_,_)=>LibraryHint.Visibility=library.Roots.Count>0 ? Visibility.Visible : Visibility.Collapsed;
        AdjustmentPanel.Visibility=AdjustmentSplitter.Visibility=Visibility.Collapsed;DockRow.MinHeight=0;DockRow.Height=new(0);SplitterRow.Height=new(0);
        thumbnailRefresh.Tick+=(_,_)=>{thumbnailRefresh.Stop();RefreshVisibleThumbnails();};
        Files.AddHandler(ScrollViewer.ScrollChangedEvent,new ScrollChangedEventHandler((_,_)=>QueueThumbnailRefresh()));
        Files.SizeChanged+=(_,_)=>QueueThumbnailRefresh();
        Files.Loaded+=(_,_)=>QueueThumbnailRefresh();
        EditorArea.SizeChanged+=(_,_)=>{InfoOverlay.MaxWidth=Math.Max(80,Math.Min(380,EditorArea.ActualWidth-268));UpdateDockMinimum();};
        DockHeader.SizeChanged+=(_,_)=>UpdateDockMinimum();
        ToolsScroller.SizeChanged+=(_,_)=>UpdateDockMinimum();
        NeutralCanvas.Viewport=ResultCanvas.Viewport=viewport;
        ResultCanvas.PreviewSizeChanged+=UpdatePreviewSize;
        viewport.ResolutionChanged+=()=>{if(!syncing)UpdatePreviewSize(viewport.ActualPixels ? 0 : ResultCanvas.PreviewLongEdge);};
        previewResize.Tick+=(_,_)=>CommitPreviewSize();
        films.Add(new("中性",null,null));
        var artwork=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase) {
            ["PROVIA"]="provia",["Velvia"]="velvia",["ASTIA"]="astia",["ACROS"]="acros",
            ["PRO Neg.Std"]="pro-neg-std",["CLASSIC Neg."]="classic-neg",["CLASSIC CHROME"]="classic-chrome",
            ["ETERNA"]="eterna",["ETERNA BB"]="eterna-bb",["REALA ACE"]="reala-ace" };
        var root=Path.Combine(AppContext.BaseDirectory,"LUTs");
        if(Directory.Exists(root))foreach(var path in Directory.GetFiles(root,"*.cube").Order())
        {
            var name=Path.GetFileNameWithoutExtension(path).Replace("FLog2_to_","").Replace("_65grid_V.1.00","").Replace('-', ' ');
            films.Add(new(name,path,artwork.TryGetValue(name,out var icon) ? Path.Combine(AppContext.BaseDirectory,"FilmIcons",icon+".png") : null));
        }
        lut=films.FirstOrDefault(f=>f.Name=="PROVIA")?.Path;
        BuildTools(); BuildFilms(); BuildMasterRecipes();
        DenoiseEditor.Changed+=(value,dragging)=>{
            if(!ready || syncing || exporting || transform.Active)return;
            settings.Denoise=value;interacting=dragging;RefreshControls();MarkEdited();Schedule();
        };
        PhotoEffectsEditor.Changed+=(value,dragging)=>{
            if(!ready || syncing || exporting || transform.Active)return;
            settings.Effects=value;interacting=dragging;RefreshControls();MarkEdited();Schedule();
        };
        HslEditor.Changed+=(value,dragging)=>{
            if(!ready || syncing || exporting || transform.Active)return;
            settings.Hsl=value;interacting=dragging;RefreshControls();MarkEdited();Schedule();
        };
        LensEditor.Changed+=UpdateLensDraft;
        GeometryEditor.Changed+=UpdateGeometryDraft;
        GeometryEditor.OverlayChanged+=RefreshCropDraft;
        ResultCanvas.CropChanged+=UpdateGeometryDraft;
        OrdinaryParameter.Changed+=(value,dragging)=>{
            if(!ready || syncing || exporting || transform.Active)return;
            interacting=dragging;settings.Set(selectedParameter,value);MarkEdited();RefreshControls();Schedule();
        };
        OrdinaryParameter.InvalidInput+=()=>SetStatus(() => Loc.Text("请输入有限数值。"),true);
        ready=true; RefreshControls();
        InitializeEditWorkflow();
        Closing+=WindowClosing;
        Loaded+=async (_,_)=> {
            var input=Environment.GetCommandLineArgs().Skip(1).FirstOrDefault(LibraryEntry.IsRaw);
            if(input!=null)OpenFile(input);
            await updates.CheckAsync(false, updateCancellation.Token);
        };
    }
    private void AboutClicked(object sender, RoutedEventArgs e)
    {
        if (aboutWindow == null)
        {
            aboutWindow = new AboutWindow(updates) { Owner = this };
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
            Parameter.ToneCurve,Parameter.Saturation,Parameter.Temperature,Parameter.Tint,Parameter.Sharpening})
        {
            if(id==Parameter.Temperature)Tools.Children.Add(HslCategory);
            if(id==Parameter.Sharpening)Tools.Children.Add(DenoiseCategory);
            var spec=ParameterSpec.All[(int)id];
            var ring=new AdjustmentRing{Width=40,Height=40};
            var grid=new Grid(); grid.Children.Add(ring); grid.Children.Add(new EditorIcon{Kind=spec.Id.ToString(),Width=20,Height=20});
            var stack=new StackPanel(); stack.Children.Add(grid); stack.Children.Add(new TextBlock{Text=Loc.Text(spec.Title),FontSize=11*EditorAppearance.TextScale,MaxWidth=70,TextWrapping=TextWrapping.Wrap,TextAlignment=TextAlignment.Center,HorizontalAlignment=HorizontalAlignment.Center,Margin=new Thickness(0,4,0,0)});
            var button=new Button{Content=stack,Style=(Style)FindResource("ToolButton"),ToolTip=Loc.Text(spec.Title)};
            AutomationProperties.SetName(button,Loc.Text(spec.Title));
            button.Click+=(_,_)=>{if(!ResolveTransformDraft())return;OrdinaryParameter.RestoreText();choosingRecipes=false;choosingHsl=false;choosingFilm=false;choosingDenoise=false;choosingPhotoEffects=false;choosingLens=choosingGeometry=false;selectedParameter=spec.Id;RefreshControls();};
            Tools.Children.Add(button); toolButtons[spec.Id]=(button,ring);
        }
        foreach(var (tool,title,icon) in new[] {
            (PhotoEffectTool.Vignette,Loc.Text("暗角"),"Clipping"), (PhotoEffectTool.Grain,Loc.Text("颗粒"),"Film")
        })
        {
            var ring=new AdjustmentRing{Width=40,Height=40};
            var grid=new Grid(); grid.Children.Add(ring); grid.Children.Add(new EditorIcon{Kind=icon,Width=20,Height=20});
            var stack=new StackPanel(); stack.Children.Add(grid); stack.Children.Add(new TextBlock{Text=title,FontSize=11*EditorAppearance.TextScale,MaxWidth=70,TextWrapping=TextWrapping.Wrap,HorizontalAlignment=HorizontalAlignment.Center,Margin=new Thickness(0,4,0,0)});
            var button=new Button{Content=stack,Style=(Style)FindResource("ToolButton"),ToolTip=tool==PhotoEffectTool.Vignette ? Loc.Text("Vignette / 暗角") : Loc.Text("Grain / 颗粒")};
            AutomationProperties.SetName(button,title);
            AutomationProperties.SetAutomationId(button,tool.ToString());
            button.Click+=(_,_)=>{if(exporting || !ResolveTransformDraft())return;choosingRecipes=false;choosingHsl=false;choosingFilm=false;choosingDenoise=false;choosingLens=choosingGeometry=false;choosingPhotoEffects=true;selectedEffect=tool;RefreshControls();};
            Tools.Children.Add(button); effectToolButtons[tool]=(button,ring);
        }
        Tools.Children.Add(GeometryCategory);Tools.Children.Add(LensCategory);
    }
    private void FilmCategoryClicked(object sender,RoutedEventArgs e) { if(!ResolveTransformDraft())return;choosingRecipes=false;choosingHsl=false;choosingFilm=true;choosingDenoise=false;choosingPhotoEffects=false;choosingLens=choosingGeometry=false;RefreshControls(); }
    private void DenoiseCategoryClicked(object sender,RoutedEventArgs e) { if(!ResolveTransformDraft())return;choosingRecipes=false;choosingHsl=false;choosingDenoise=true;choosingFilm=false;choosingPhotoEffects=false;choosingLens=choosingGeometry=false;RefreshControls(); }
    private void HslCategoryClicked(object sender,RoutedEventArgs e) { if(!ResolveTransformDraft())return;choosingRecipes=false;choosingHsl=true;choosingDenoise=choosingFilm=choosingPhotoEffects=false;choosingLens=choosingGeometry=false;RefreshControls(); }
    private void LensCategoryClicked(object sender,RoutedEventArgs e)=>BeginTransform(TransformTool.Lens);
    private void GeometryCategoryClicked(object sender,RoutedEventArgs e)=>BeginTransform(TransformTool.Geometry);
    private void BuildFilms()
    {
        FilmStrip.Children.Clear(); filmButtons.Clear();
        foreach(var film in films)
        {
            var stack=new StackPanel();
            if(film.Artwork!=null && File.Exists(film.Artwork))stack.Children.Add(new Image{Source=new BitmapImage(new Uri(film.Artwork)),Width=64,Height=64});
            else stack.Children.Add(new EditorIcon{Kind=film.Path==null ? "Neutral" : "Film",Width=32,Height=64});
            var displayName=film.Path==null ? Loc.Text("中性") : film.Name;
            stack.Children.Add(new TextBlock{Text=displayName,FontSize=11*EditorAppearance.TextScale,Width=80,MinHeight=30,TextWrapping=TextWrapping.Wrap,TextAlignment=TextAlignment.Center,Margin=new Thickness(0,5,0,0)});
            var button=new Button{Content=stack,Style=(Style)FindResource("FilmButton"),ToolTip=film.Path ?? Loc.Text("中性显影")};
            AutomationProperties.SetName(button,displayName);
            button.Click+=(_,_)=>{if(exporting || !ResolveTransformDraft())return;settings.ClearMasterRecipe();lut=film.Path;MarkEdited();RefreshControls();Schedule();};
            FilmStrip.Children.Add(button); filmButtons[film.Path ?? ""]=button;
        }
        var importContent=new StackPanel();
        importContent.Children.Add(new EditorIcon{Kind="Add",Width=26,Height=64});
        importContent.Children.Add(new TextBlock{Text=Loc.Text("导入外观"),FontSize=11*EditorAppearance.TextScale,Height=30,TextAlignment=TextAlignment.Center,Margin=new Thickness(0,5,0,0)});
        var importButton=new Button{Content=importContent,Style=(Style)FindResource("FilmButton"),ToolTip=Loc.Text("导入兼容 CUBE 或 RLOOK，可选择多个文件")};
        AutomationProperties.SetName(importButton,Loc.Text("导入外观"));importButton.Click+=ImportClicked;FilmStrip.Children.Add(importButton);
    }
    private void RefreshControls()
    {
        if(!ready)return;
        syncing=true;
        try
        {
            var spec=ParameterSpec.All[(int)selectedParameter];
            OrdinaryParameter.Refresh(Loc.Text(spec.Title),NumericRange.For(spec),settings[selectedParameter],settings.Default(selectedParameter),spec.Unit);
            AutomationProperties.SetName(ValueSlider,Loc.Text(spec.Title));
            AutomationProperties.SetName(ValueText,Loc.Format("{0}数值（{1}）",Loc.Text(spec.Title),spec.Unit));
            var canAdjust=file!=null && !exporting && !choosingFilm && !choosingPhotoEffects && (selectedParameter!=Parameter.Strength || lut!=null) && (selectedParameter is not(Parameter.Temperature or Parameter.Tint) || settings.AsShot!=null);
            ValueSlider.IsEnabled=ValueText.IsEnabled=canAdjust;
            FilmPanel.Visibility=choosingFilm ? Visibility.Visible : Visibility.Collapsed;
            MasterRecipePanel.Visibility=choosingRecipes ? Visibility.Visible : Visibility.Collapsed;
            MasterRecipeCategoryRing.Selected=choosingRecipes;MasterRecipeCategoryRing.Progress=settings.MasterRecipeID==null ? 0 : 1;MasterRecipeCategoryRing.InvalidateVisual();
            foreach(var pair in recipeButtons)pair.Value.Foreground=pair.Key==(settings.MasterRecipeID ?? "") ? Brushes.Gold : (Brush)FindResource("Foreground");
            ParameterPanel.Visibility=choosingRecipes || choosingFilm || choosingDenoise || choosingPhotoEffects || choosingHsl || choosingLens || choosingGeometry ? Visibility.Collapsed : Visibility.Visible;
            LensEditor.Visibility=choosingLens ? Visibility.Visible : Visibility.Collapsed;
            LensSurface.Visibility=LensEditor.Visibility;
            LensEditor.IsEnabled=file!=null && !exporting;LensEditor.Refresh(PreviewLens,result?.Lens);
            LensCategory.IsEnabled=file!=null && !exporting;
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
            ExposureMode.IsEnabled=ExposureMode.IsEnabled && !transform.Active;
            ResetParameterButton.IsEnabled=ResetGroupButton.IsEnabled=canAdjust;
            AsShotButton.IsEnabled=file!=null && !exporting && settings.AsShot!=null && !transform.Active;
            DraftActions.Visibility=transform.Active ? Visibility.Visible : Visibility.Collapsed;
            ApplyDraftButton.IsEnabled=CanApplyTransform;
            foreach(var (id,controls) in toolButtons)
            {
                var selected=!choosingRecipes && !choosingHsl && !choosingFilm && !choosingDenoise && !choosingPhotoEffects && !choosingLens && !choosingGeometry && id==selectedParameter;
                controls.Button.Tag=selected ? "selected" : null;
                controls.Ring.Selected=selected;
                var p=ParameterSpec.All[(int)id]; var origin=p.Position(settings.Default(id)); var offset=p.Position(settings[id])-origin;
                controls.Ring.Progress=offset==0 ? 0 : offset/(offset<0 ? origin : 1-origin); controls.Ring.InvalidateVisual();
            }
            foreach(var pair in filmButtons)pair.Value.Tag=pair.Key==(lut ?? "") ? "selected" : null;
            var filmName=settings.Recipe?.Name ?? films.FirstOrDefault(f=>f.Path==lut)?.Name ?? Loc.Text("中性");
            ActiveFilm.Text=filmName;FilmLabelText.Text=lut==null ? Loc.Text("调整后") : filmName;ActiveFilm.ToolTip=filmName;
            NeutralLabel.Visibility=FilmLabel.Visibility=compare && result!=null ? Visibility.Visible : Visibility.Collapsed;
            RefreshComparisonLayout();
            CompareButton.Tag=compare ? "selected" : null;
            ClippingButton.Tag=clipping ? "selected" : null;
            InfoButton.Tag=photoInfoMode == PhotoInfoMode.Hidden ? null : "selected";
            LibraryToggleButton.Tag=LibraryPanel.Visibility==Visibility.Visible ? "selected" : null;
            AdjustToggleButton.Tag=AdjustmentPanel.Visibility==Visibility.Visible ? "selected" : null;
            UpdateBusy();
            RefreshExportSizeMenu();
        }
        finally { syncing=false; }
    }
    private static SolidColorBrush Brush(string color)=>(SolidColorBrush)new BrushConverter().ConvertFromString(color)!;
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
        HistogramSurface.Visibility=file!=null ? Visibility.Visible : Visibility.Collapsed;
        CompareButton.IsEnabled=ClippingButton.IsEnabled=InfoButton.IsEnabled=AdjustToggleButton.IsEnabled=file!=null && !exporting;
        AdjustmentPanel.IsEnabled=!exporting;GpuMode.IsEnabled=!exporting;
        BusyIndicator.Visibility=scheduler.Busy || previewResize.IsEnabled || exporting ? Visibility.Visible : Visibility.Collapsed;
        RetryButton.Visibility=renderFailed && !scheduler.Busy && !exporting ? Visibility.Visible : Visibility.Collapsed;
        ExportButton.ToolTip=file==null ? Loc.Text("打开 RAW 照片后导出") : transform.Active ? Loc.Text("草稿预览 · 尚未应用") :
            !exactReady || scheduler.Busy || previewResize.IsEnabled ? Loc.Text("精确预览完成后可导出") : Loc.Text("导出照片（尺寸可选）");
        ToolTipService.SetShowOnDisabled(ExportButton,true);
        ToolTipService.SetShowOnDisabled(ExportJpeg,true);ToolTipService.SetShowOnDisabled(ExportPng,true);ToolTipService.SetShowOnDisabled(ExportDng,true);
    }
    private void SetStatus(string text,bool error=false) { localizedStatus=null; Status.Text=text; Status.ToolTip=text; Status.Foreground=Brush(error ? "#FFAB92" : "#B5B8C0"); }
    private void SetStatus(Func<string> text,bool error=false) { SetStatus(text(),error); localizedStatus=text; }
    private void RefreshRenderLabels()
    {
        if (result == null) { if (file != null && !renderFailed) BackendLabel.Text=Loc.Text("相机预览 · 正在显影"); return; }
        BackendLabel.Text=$"{(result.Backend==3 ? "Direct3D 11 · GPU" : renderedGpuMode==0 ? "CPU" : Loc.Text("CPU · GPU 已回退"))} · sRGB";
        ClipStats.Text=Loc.Format("暗部 {0:P1}   高光 {1:P1} · 显示图统计", result.Shadows, result.Highlights);
        BaselineLabel.Text=Loc.Format("基础偏移 {0:+0.00;-0.00;0.00} EV", result.Baseline);
        AsShotButton.ToolTip=result.WhiteBalance==null ? Loc.Text("此 RAW 缺少有效校准，使用相机原始白平衡") : Loc.Format("拍摄时：{0} K / {1}", result.WhiteBalance.Value.Temperature, result.WhiteBalance.Value.Tint);
    }
    private void RetryClicked(object sender,RoutedEventArgs e)=>Schedule();
    private void Report(Exception error)=>SetStatus(error is DllNotFoundException or BadImageFormatException or EntryPointNotFoundException
        ? Loc.Text("无法加载显影组件。请通过 build.ps1 构建，并保留程序目录内的 DLL。") : error.Message,true);
    internal void OpenFile(string path,BitmapSource? placeholder=null)
    {
        if(exporting || closing)return;
        try
        {
            path=Path.GetFullPath(path);
            if(!LibraryEntry.IsRaw(path))throw new InvalidOperationException(Loc.Text("请选择支持的 RAW 文件。"));
            if(!ResolveTransformDraft() || !SaveEdits())return;
            RestoreEdits(path);
            lastExportedPath=null;ExportRevealButton.Visibility=Visibility.Collapsed;
            if(file==null){AdjustmentPanel.Visibility=AdjustmentSplitter.Visibility=Visibility.Visible;DockRow.MinHeight=216;DockRow.Height=new(dockHeight);SplitterRow.Height=new(6);}
            previewResize.Stop();previewLongEdge=requestedPreviewLongEdge=2000;
            file=path; interacting=false; exactReady=false; result=null; photoInfo=null; ++photoInfoRevision; syncing=true;viewport.Fit();
            RefreshComparisonToolTip();
            viewport.SetSourceSize(0,0);
            NeutralCanvas.SetImage(placeholder,null); ResultCanvas.SetImage(placeholder,null);ResultCanvas.SetComparison(placeholder,null); Histogram.Bins=null; Histogram.InvalidateVisual(); ClipStats.Text="";
            previewLongEdge=requestedPreviewLongEdge=ResultCanvas.PreviewLongEdge>0 ? ResultCanvas.PreviewLongEdge : 2000;
            syncing=false;
            RefreshPhotoInfo();
            BackendLabel.Text=Loc.Text("相机预览 · 正在显影");BaselineLabel.Text="";
            Title="RawLab · "+Path.GetFileName(path); Welcome.Visibility=Visibility.Collapsed;
            embeddedScheduler.Submit(new(path,++openRevision));PumpEmbedded();
            _ = LoadPhotoInfo(path, photoInfoRevision);
            RefreshControls(); Schedule(initialPreview:true);QueueThumbnailRefresh();
        }
        catch(Exception ex) { Report(ex); }
    }
    private async Task LoadPhotoInfo(string path, long revision)
    {
        var info = await Task.Run(() => PhotoInfoReader.Read(path));
        if (closing || revision != photoInfoRevision || !StringComparer.OrdinalIgnoreCase.Equals(path, file)) return;
        photoInfo = info;
        RefreshPhotoInfo();
    }
    private void RefreshPhotoInfo()
    {
        if (photoInfo == null || photoInfoMode == PhotoInfoMode.Hidden)
        {
            InfoOverlay.Visibility = Visibility.Collapsed;
            InfoFileText.Text = InfoCaptureText.Text = "";
            return;
        }
        var text = photoInfoMode == PhotoInfoMode.File ? photoInfo.FileLine : photoInfo.CaptureLine;
        if (string.IsNullOrWhiteSpace(text))
        {
            InfoOverlay.Visibility = Visibility.Collapsed;
            InfoFileText.Text = InfoCaptureText.Text = "";
            return;
        }
        InfoFileText.Text = photoInfoMode == PhotoInfoMode.File ? text : "";
        InfoCaptureText.Text = photoInfoMode == PhotoInfoMode.Capture ? text : "";
        InfoOverlay.Visibility = Visibility.Visible;
    }
    private void InfoClicked(object sender, RoutedEventArgs e)
    {
        photoInfoMode = photoInfoMode.Next();
        RefreshPhotoInfo(); RefreshControls();
    }
    private async void PumpEmbedded()
    {
        var ticket=embeddedScheduler.Start();if(ticket==null)return;
        EmbeddedPreview? preview=null;
        try{preview=await Task.Run(()=>RenderEngine.ReadEmbeddedPreview(ticket.Value.Path));}
        catch(Exception ex) when(ex is IOException or InvalidOperationException or DllNotFoundException or BadImageFormatException or EntryPointNotFoundException) { }
        var current=embeddedScheduler.Finish(ticket);
        if(closing)return;
        if(current && ticket.Value.Revision==openRevision && ticket.Value.Path==file && preview!=null && settings.Geometry.IsIdentity)
        {
            if(viewport.SourceSize.Width==0)viewport.SetSourceSize(preview.Width,preview.Height);
            if(result==null && !renderFailed && preview.Image!=null)
            {
                NeutralCanvas.SetImage(preview.Image,null);ResultCanvas.SetImage(preview.Image,null);ResultCanvas.SetComparison(preview.Image,null);
                SetStatus(() => Loc.Text("相机内嵌预览 · 正在显影…"));
            }
        }
        PumpEmbedded();
    }
    private void UpdatePreviewSize(int edge)
    {
        if(syncing || file==null || closing || (edge==requestedPreviewLongEdge && (edge==previewLongEdge || previewResize.IsEnabled)))return;
        requestedPreviewLongEdge=edge;previewResize.Stop();
        if(exporting)return;
        if(edge==previewLongEdge){UpdateBusy();return;}
        if(settings.Denoise.Enabled && edge>0 && previewLongEdge>0){previewResize.Start();UpdateBusy();}
        else CommitPreviewSize();
    }
    private void CommitPreviewSize()
    {
        previewResize.Stop();previewLongEdge=requestedPreviewLongEdge;Schedule(initialPreview:result==null);
    }
    private int RenderEdge(bool proxy)=>proxy && previewLongEdge==0 ? 2000 : previewLongEdge;
    private void Schedule(bool initialPreview=false)
    {
        if(!ready || file==null || exporting || closing)return;
        if(transform.Active){transformPreviewReady=false;RefreshCropDraft();}
        if(!settings.Denoise.Enabled && previewResize.IsEnabled){previewResize.Stop();previewLongEdge=requestedPreviewLongEdge;}
        if(!LookAvailable){exactReady=false;result=null;renderFailed=true;SetStatus(() => Loc.Text("上次使用的外观不可用，请重新导入或选择外观。"),true);UpdateBusy();return;}
        renderFailed=false;
        var proxy=interacting || initialPreview;
        var previewSettings=settings.Clone();previewSettings.Geometry=PreviewGeometry;previewSettings.Lens=PreviewLens;
        scheduler.Submit(new(file,previewSettings,lut,RenderEdge(proxy),proxy,GpuMode.SelectedIndex==0 ? 1 : GpuMode.SelectedIndex==1 ? 0 : 2,compare,clipping,initialPreview,transformGeneration));
        exactReady=false; SetStatus(() => interacting ? Loc.Text("正在生成交互预览…") : Loc.Text("正在显影…")); UpdateBusy();
        Pump();
    }
    private async void Pump()
    {
        var ticket=scheduler.Start(); if(ticket==null)return;
        RenderedImage? neutral=null,rendered=null; Exception? failure=null;
        try
        {
            (neutral,rendered)=await Task.Run(()=> {
                engine ??= new(); var w=ticket.Value;engine.SetGpuMode(w.GpuMode);
                var frame=engine.RenderPreview(w.File,w.Settings,w.Lut,w.Edge,w.Interactive,w.Compare,w.Clipping);
                return(frame.Neutral,frame.Result);
            });
        }
        catch(Exception ex) { failure=ex; }
        var current=scheduler.Finish(ticket);
        if(closing) { FinishClose(); return; }
        var work=ticket.Value;
        // A current-file proxy may publish while dragging; stale exact work never publishes.
        if(work.File==file && work.Lut==lut && work.Settings.Geometry==PreviewGeometry && work.Settings.Lens==PreviewLens && work.TransformGeneration==transformGeneration && work.Compare==compare && work.Clipping==clipping && (current || (work.Interactive && interacting && work.Edge==RenderEdge(true))))
        {
            if(failure!=null) { if(current){result=null;exactReady=false;transformPreviewReady=false;renderFailed=true;RefreshCropDraft();Report(failure);} }
            else if(rendered!=null && neutral!=null)
            {
                result=rendered;if(!transform.Active)settings.ResolveWhiteBalance(rendered.WhiteBalance);
                // The core supplies the post-geometry canvas before preview/export resizing.
                syncing=true;
                try { viewport.SetSourceSize(rendered.NativeWidth,rendered.NativeHeight); }
                finally { syncing=false; }
                renderedGpuMode=work.GpuMode;
                NeutralCanvas.SetImage(neutral.Image,neutral.Clipping); ResultCanvas.SetImage(rendered.Image,rendered.Clipping);
                ResultCanvas.SetComparison(neutral.Image,neutral.Clipping);
                Histogram.Bins=rendered.Histogram; Histogram.InvalidateVisual();
                RefreshRenderLabels();
                exactReady=current && !work.Interactive && !transform.Active;
                if(transform.Active)
                {
                    transformPreviewReady=current && !work.Interactive;
                    if(transform.Tool==TransformTool.Geometry)GeometryEditor.SetCanvasSize(rendered.NativeWidth,rendered.NativeHeight);
                    RefreshCropDraft();
                }
                SetStatus(() => $"{(work.Interactive ? Loc.Text("交互预览") : work.Edge==0 ? Loc.Text("原尺寸") : Loc.Text("预览"))} {rendered.Image.PixelWidth} × {rendered.Image.PixelHeight} · {Path.GetFileName(work.File)}");
                RefreshControls();
                UpdatePreviewSize(ResultCanvas.PreviewLongEdge);
            }
        }
        // A quick RAW proxy shortens the blank wait. Only its exact successor enables export.
        if(current && work.Refine && failure==null && work.File==file && !interacting)Schedule();
        UpdateBusy(); Pump();
    }
    private void ExposureModeChanged(object sender,SelectionChangedEventArgs e) { if(!ready || syncing || exporting || transform.Active)return;settings.ExposureMode=ExposureMode.SelectedIndex;MarkEdited();Schedule(); }
    private void GpuModeChanged(object sender,SelectionChangedEventArgs e) { if(ready && !exporting)Schedule(); }
    private void ResetGroupClicked(object sender,RoutedEventArgs e) { if(exporting || !ResolveTransformDraft())return;var group=ParameterSpec.All[(int)selectedParameter].Group;if(group=="胶片" && settings.MasterRecipeID!=null){settings.ClearMasterRecipe();lut=null;}settings.ResetGroup(group);MarkEdited();RefreshControls();Schedule(); }
    private void ResetAllClicked(object sender,RoutedEventArgs e) { if(file==null || exporting || !ResolveTransformDraft())return;if(settings.MasterRecipeID!=null)lut=null;settings.ResetAll();MarkEdited();RefreshControls();Schedule(); }
    private async void AutoExposureClicked(object sender,RoutedEventArgs e)
    {
        if(file==null || result==null || autoExposing || exporting || transform.Active)return;
        var path=file;var snapshot=settings.Clone();var revision=editRevision;var photoRevision=openRevision;
        autoExposing=true;RefreshControls();
        try
        {
            var ev=await Task.Run(()=>{using var meter=new RenderEngine();return meter.AutoExposure(path,snapshot);});
            if(closing || file!=path || openRevision!=photoRevision || editRevision!=revision || !snapshot.Capture().SameAs(settings.Capture()))return;
            settings.Set(Parameter.Exposure,NumericRange.For(ParameterSpec.All[(int)Parameter.Exposure]).Clamp(ev));MarkEdited();Schedule();
        }
        catch(Exception error) {if(!closing && file==path && openRevision==photoRevision && editRevision==revision)Report(error);}
        finally {autoExposing=false;if(!closing)RefreshControls();}
    }
    private void AsShotClicked(object sender,RoutedEventArgs e) { if(transform.Active || exporting)return;settings.ResetWhiteBalance();MarkEdited();RefreshControls();Schedule(); }
    private void OpenClicked(object sender,RoutedEventArgs e)
    {
        if(exporting)return;
        var dialog=new OpenFileDialog{Title=Loc.Text("打开 RAW 照片"),Filter=Loc.Text("RAW 照片|")+string.Join(';',LibraryEntry.RawExtensions.Select(x=>"*."+x))+Loc.Text("|所有文件|*.*")};
        if(dialog.ShowDialog(this)==true)OpenFile(dialog.FileName);
    }
    private async void ImportClicked(object sender,RoutedEventArgs e)
    {
        if(exporting || file==null || !ResolveTransformDraft())return;
        var dialog=new OpenFileDialog{Title=Loc.Text("导入胶片外观"),Multiselect=true,Filter=Loc.Text("胶片外观|*.cube;*.rlook|CUBE LUT|*.cube|RawLab DCP 外观|*.rlook")};
        if(dialog.ShowDialog(this)!=true)return;
        var errors=await ImportLookFiles(dialog.FileNames);
        if(errors.Count>0 && !closing)MessageBox.Show(this,string.Join("\n\n",errors),Loc.Text("导入外观"),MessageBoxButton.OK,MessageBoxImage.Warning);
    }
    internal async Task<IReadOnlyList<string>> ImportLookFiles(IEnumerable<string> paths)
    {
        if(exporting || file==null || transform.Active)return [];
        var input=file;var selected=paths.Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        foregroundBusy=true;RefreshControls();SetStatus(()=>Loc.Text("正在显影…"));
        var errors=new List<string>();var accepted=new List<string>();
        try
        {
            await Task.Run(()=>{
                using var validator=new RenderEngine(0);
                foreach(var path in selected)
                {
                    try{validator.Render(input,new Adjustments(),path,64,statistics:false,clipping:false,viewportPreview:true);accepted.Add(path);}
                    catch(Exception error){errors.Add(Path.GetFileName(path)+": "+error.Message);}
                }
            });
            if(!closing && accepted.Count>0)
            {
                settings.ClearMasterRecipe();
                foreach(var path in accepted)if(!films.Any(f=>StringComparer.OrdinalIgnoreCase.Equals(f.Path,path)))films.Add(new(Path.GetFileNameWithoutExtension(path),path,null));
                lut=accepted[^1];MarkEdited();BuildFilms();
            }
        }
        catch(Exception error){errors.Add(error.Message);}
        finally{foregroundBusy=false;RefreshControls();if(closing)FinishClose();else Schedule();}
        return errors;
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
    private bool CanApplyCurrentSettings => file != null && result != null && exactReady && !scheduler.Busy && !previewResize.IsEnabled && !exporting && LookAvailable;
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
        if (exporting || scheduler.Busy || previewResize.IsEnabled || !exactReady || result == null || transform.Active)
        {
            SetStatus(() => Loc.Text("精确显影完成后才能应用当前设置。"),true); return;
        }
        if (!LookAvailable) { SetStatus(() => Loc.Text("当前外观不可用，不能应用设置。"),true); return; }
        var snapshot=settings.Capture(); var look=CurrentLookIdentity();
        try
        {
            LibraryEntry[] targets;
            if (entry.IsFolder)
            {
                targets=await Task.Run(()=>new DirectoryInfo(entry.Path).EnumerateFiles()
                    .Where(child=>(child.Attributes&(FileAttributes.Hidden|FileAttributes.ReparsePoint))==0)
                    .Where(child=>LibraryEntry.IsRaw(child.FullName))
                    .Select(child=>new LibraryEntry(child.FullName,false)).ToArray());
            }
            else targets=LibraryEntry.IsRaw(entry.Path) ? [entry] : [];
            if (targets.Length == 0) { SetStatus(() => Loc.Text("目录中没有直接 RAW 照片。"),true); return; }
            var answer=MessageBox.Show(this,
                Loc.Format("将覆盖 {0} 张照片的本机编辑记录。不会修改 RAW 文件。继续？", targets.Length),
                Loc.Text("应用当前设置"),MessageBoxButton.YesNo,MessageBoxImage.Question);
            if (answer != MessageBoxResult.Yes) return;
            SaveSettingsCopies(targets.Select(target=>target.Path),snapshot,look);
            SetStatus(() => Loc.Format("已应用当前设置到 {0} 张照片。", targets.Length),false);
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
    private void FilesDropped(object sender,DragEventArgs e)
    {
        if(exporting || e.Data.GetData(DataFormats.FileDrop) is not string[] paths)return;
        try{foreach(var path in paths.Where(Directory.Exists))library.Add(path);}catch(Exception ex){Report(ex);}
        if(paths.FirstOrDefault(LibraryEntry.IsRaw) is {} raw)OpenFile(raw);
    }
    private void LibraryToggle(object sender,RoutedEventArgs e)
    {
        var visible=LibraryPanel.Visibility==Visibility.Visible;
        if(visible)libraryWidth=LibraryColumn.ActualWidth;
        LibraryPanel.Visibility=LibrarySplitter.Visibility=visible ? Visibility.Collapsed : Visibility.Visible;
        LibraryColumn.MinWidth=visible ? 0 : 180;
        LibraryColumn.Width=new(visible ? 0 : libraryWidth);
        LibrarySplitterColumn.Width=new(visible ? 0 : 5);
        RefreshControls();
        QueueThumbnailRefresh();
    }
    private void CompareClicked(object sender,RoutedEventArgs e)=>ZoomClicked(sender,e);
    private void ExportMenuClicked(object sender,RoutedEventArgs e)=>ZoomClicked(sender,e);
    private void CompareOffClicked(object sender,RoutedEventArgs e)=>SetComparisonMode(false,false);
    private void CompareSideClicked(object sender,RoutedEventArgs e)=>SetComparisonMode(true,false);
    private void CompareSwipeClicked(object sender,RoutedEventArgs e)=>SetComparisonMode(true,true);
    internal void SetComparisonMode(bool enabled,bool sliding)
    {
        if(transform.Active && !ResolveTransformDraft())return;
        var changed=compare!=enabled;
        compare=enabled;swipe=enabled && sliding;
        RefreshComparisonLayout();
        RefreshComparisonToolTip();
        Grid.SetColumnSpan(NeutralLabel,swipe ? 2 : 1);
        FilmLabel.HorizontalAlignment=swipe ? HorizontalAlignment.Right : HorizontalAlignment.Left;
        CompareOff.IsChecked=!enabled;CompareSide.IsChecked=enabled && !sliding;CompareSwipe.IsChecked=swipe;
        RefreshControls();
        if(changed)Schedule();
    }
    private void RefreshComparisonLayout()
    {
        var sideBySide=file!=null && compare && !swipe;
        NeutralCanvas.Visibility=sideBySide ? Visibility.Visible : Visibility.Collapsed;
        NeutralColumn.Width=sideBySide ? new(1,GridUnitType.Star) : new(0);
        ResultCanvas.ComparisonEnabled=file!=null && swipe;
    }
    private void RefreshComparisonToolTip() => ResultCanvas.ToolTip=file==null ? null : swipe ? Loc.Text("拖动分隔线对比；方向键微调，Home 居中。拖动照片平移，滚轮缩放。") : Loc.Text("拖动平移，滚轮缩放，双击适合窗口。");
    private void DockToggle(object sender,RoutedEventArgs e)
    {
        if(file==null)return;
        var visible=AdjustmentPanel.Visibility==Visibility.Visible;
        if(visible)dockHeight=DockRow.ActualHeight;
        AdjustmentPanel.Visibility=visible ? Visibility.Collapsed : Visibility.Visible;
        AdjustmentSplitter.Visibility=visible ? Visibility.Collapsed : Visibility.Visible;
        DockRow.MinHeight=visible ? 0 : 216; DockRow.Height=new(visible ? 0 : dockHeight);SplitterRow.Height=new(visible ? 0 : 6);
        RefreshControls();
        UpdateDockMinimum();
    }
    private void UpdateDockMinimum()
    {
        if(AdjustmentPanel.Visibility==Visibility.Visible && EditorArea.ActualHeight>0)
        {
            DockRow.MinHeight=216;
            DockRow.MaxHeight=Math.Max(216,EditorArea.ActualHeight-166);
            if(DockRow.Height.Value>DockRow.MaxHeight)DockRow.Height=new(DockRow.MaxHeight);
        }
    }
    private void HistogramClicked(object sender,RoutedEventArgs e)=>HistogramPanel.Visibility=HistogramPanel.Visibility==Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
    private void ClippingClicked(object sender,RoutedEventArgs e) { clipping=!clipping;NeutralCanvas.ShowClipping=ResultCanvas.ShowClipping=clipping;NeutralCanvas.InvalidateVisual();ResultCanvas.InvalidateVisual();RefreshControls();Schedule(); }
    private void ZoomClicked(object sender,RoutedEventArgs e) { if(sender is Button button && button.ContextMenu is {} menu){menu.PlacementTarget=button;menu.IsOpen=true;} }
    private void FitClicked(object sender,RoutedEventArgs e) {if(!transform.Active)viewport.Fit();}
    private void ActualClicked(object sender,RoutedEventArgs e) {if(!transform.Active)viewport.Actual();}
    private void ZoomInClicked(object sender,RoutedEventArgs e) {if(!transform.Active)viewport.Magnify(1.25);}
    private void ZoomOutClicked(object sender,RoutedEventArgs e) {if(!transform.Active)viewport.Magnify(.8);}
    private void KeyPressed(object sender,KeyEventArgs e)
    {
        if(e.OriginalSource is TextBoxBase or ComboBox || Keyboard.FocusedElement is TextBoxBase or ComboBox)return;
        if(e.Key==Key.O && Keyboard.Modifiers==ModifierKeys.Control)OpenClicked(sender,e);
        else if(e.Key==Key.F)FitClicked(sender,e); else if(e.Key==Key.D1)ActualClicked(sender,e);
        else if(e.Key is Key.Add or Key.OemPlus)ZoomInClicked(sender,e); else if(e.Key is Key.Subtract or Key.OemMinus)ZoomOutClicked(sender,e);
        else if(e.Key==Key.I)InfoClicked(sender,e);
    }
    private void ExportJpegClicked(object sender,RoutedEventArgs e)=>Export(ExportFormat.Jpeg);
    private void ExportPngClicked(object sender,RoutedEventArgs e)=>Export(ExportFormat.Png);
    private void ExportDngClicked(object sender,RoutedEventArgs e)=>Export(ExportFormat.RenderedDng);
    private void ExportOriginalSizeClicked(object sender,RoutedEventArgs e) { exportLongEdge=null; RefreshExportSizeMenu(); }
    private void ExportSizeClicked(object sender,RoutedEventArgs e)
    {
        if (sender is MenuItem { Tag: string text } && int.TryParse(text, out var edge))
        {
            exportLongEdge=ExportSize.IsValid(edge) ? edge : null;
            RefreshExportSizeMenu();
        }
    }
    private void ExportCustomSizeClicked(object sender,RoutedEventArgs e)
    {
        var value=LongEdgeDialog.Show(this,exportLongEdge);
        if (value is not null) { exportLongEdge=value; RefreshExportSizeMenu(); }
    }
    private void RefreshExportSizeMenu()
    {
        if (ExportOriginalSize == null) return;
        ExportOriginalSize.IsChecked=exportLongEdge == null;
        ExportSize2048.IsChecked=exportLongEdge == 2048;
        ExportSize3000.IsChecked=exportLongEdge == 3000;
        ExportSize4096.IsChecked=exportLongEdge == 4096;
        ExportCustomSize.IsChecked=exportLongEdge.HasValue && exportLongEdge != 2048 && exportLongEdge != 3000 && exportLongEdge != 4096;
        ExportCustomSize.Header=ExportCustomSize.IsChecked == true ? Loc.Format("自定义 {0} px", exportLongEdge) : Loc.Text("自定义…");
    }
    private async void Export(ExportFormat format)
    {
        if(!exactReady || scheduler.Busy || previewResize.IsEnabled || exporting || file==null || engine==null)return;
        var suffix=format.Suffix();
        var dialog=new SaveFileDialog{Title=Loc.Text("全分辨率导出"),Filter=format switch {
                ExportFormat.Jpeg => Loc.Text("导出 JPEG")+"|*.jpg;*.jpeg",
                ExportFormat.Png => Loc.Text("导出 16-bit PNG")+"|*.png",
                ExportFormat.RenderedDng => Loc.Text("DNG · 渲染型")+"|*.dng",
                _ => throw new ArgumentOutOfRangeException(nameof(format))
            },DefaultExt="."+suffix,AddExtension=true,OverwritePrompt=true,
            FileName=Path.GetFileNameWithoutExtension(file)+"-"+(films.FirstOrDefault(f=>f.Path==lut)?.Name ?? "neutral")};
        dialog.FileOk += (_, args) => {
            if (!format.AcceptsPath(dialog.FileName))
            {
                args.Cancel = true;
                MessageBox.Show(this, Loc.Format("请选择 {0} 文件扩展名。", format.Title()), Loc.Text("导出"),
                    MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        };
        if(dialog.ShowDialog(this)!=true)return;
        await ExportPhoto(format,dialog.FileName);
    }
    internal async Task ExportPhoto(ExportFormat format,string destination)
    {
        if(!exactReady || scheduler.Busy || previewResize.IsEnabled || exporting || file==null || engine==null || closing)return;
        if(Path.GetFullPath(destination).Equals(Path.GetFullPath(file),StringComparison.OrdinalIgnoreCase)){SetStatus(() => Loc.Text("不能覆盖原始 RAW。"),true);return;}
        var input=file;var adjustment=settings.Clone();var film=lut;
        // Render to a sibling temporary file, then replace only after encoding succeeds.
        var temp=Path.Combine(Path.GetDirectoryName(destination)!,".rawlab-"+Guid.NewGuid().ToString("N")+"."+format.Suffix());
        var size=exportLongEdge;
        foregroundBusy=true;RefreshControls();SetStatus(() => Loc.Text("正在全分辨率导出…"));
        try
        {
            using var sourceLock = WindowsFileIdentity.OpenReadLock(input);
            if (WindowsFileIdentity.IsSameFile(sourceLock, destination))
            {
                SetStatus(() => Loc.Text("不能覆盖原始 RAW。"), true);
                return;
            }
            await Task.Run(()=>engine.Render(input,adjustment,film,0,false,temp,longEdge:size));
            if (WindowsFileIdentity.IsSameFile(sourceLock, destination))
            {
                SetStatus(() => Loc.Text("不能覆盖原始 RAW。"), true);
                return;
            }
            File.Move(temp,destination,true);
            lastExportedPath=destination;ExportRevealButton.Visibility=Visibility.Visible;
            SetStatus(() => Loc.Format("已导出（{0}）：{1}", (engine.LastBackend==3 ? "Direct3D 11" : "CPU"), destination));
        }
        catch(Exception ex){Report(ex);}
        finally {try{if(File.Exists(temp))File.Delete(temp);}catch(IOException){} foregroundBusy=false;RefreshControls();if(closing)FinishClose();else UpdatePreviewSize(requestedPreviewLongEdge);}
    }
    private void WindowClosing(object? sender,CancelEventArgs e)
    {
        if(!ResolveTransformDraft() || !SaveEdits()){e.Cancel=true;return;}
        closing=true;
        previewResize.Stop();
        if(batchWindow is {} batch)
        {
            batch.Close();
            if(batch.IsVisible && !batch.Busy){e.Cancel=true;closing=false;return;}
        }
        thumbnailRefresh.Stop();foreach(var entry in visibleThumbnails)entry.ReleaseThumbnail();visibleThumbnails.Clear();
        if(scheduler.Busy || exporting){e.Cancel=true;closing=true;IsEnabled=false;SetStatus(() => Loc.Text("正在完成当前任务后关闭…"));return;}
        closeFinished=true;engine?.Dispose();engine=null;
    }
    private void FinishClose()
    {
        if(closeFinished || scheduler.Active!=null || exporting)return;
        closeFinished=true;engine?.Dispose();engine=null;Closing-=WindowClosing;Close();
    }
}
