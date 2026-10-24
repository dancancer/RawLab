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
    private record Film(string Name,string? Path,string? Artwork,FilmGroup Group=FilmGroup.Other);
    private record Work(string File,Adjustments Settings,string? Lut,int Edge,bool Interactive,int GpuMode,bool Compare,bool Clipping,bool Refine,long TransformGeneration,long OpenRevision,OriginalIdentity Source,AIDenoiseIdentity? AIIdentity,HslProbeWork? Probe=null);
    private readonly Library library=new();
    private LookLibrary? lookLibrary;
    private Exception? lookLibraryLoadError;
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
    private ToneControlParameter? selectedToneParameter;
    private AtmosphereParameter? selectedAtmosphereParameter;
    private string? file,lut;
    private RenderEngine? engine;
    private bool ready,syncing,interacting,foregroundBusy,closing,closeFinished,exactReady;
    // The modeless batch owns its lifetime; foreground completion must not clear it.
    private bool exporting=>foregroundBusy || batchWindow?.Busy==true;
    private readonly EditorViewState view=new();
    private bool compare=>view.Enabled;
    private bool swipe=>view.Enabled && view.PreferredMode==ComparisonMode.Wipe;
    private bool clipping,choosingFilm,choosingDenoise,choosingPhotoEffects,choosingLens,choosingGeometry,choosingWhiteBalance;
    private RenderedImage? neutralResult;
    private long neutralRevision;
    private NeutralReferenceKey? acceptedReference;
    private NeutralReferenceKey? acceptedAfter;
    private PhotoEffectTool selectedEffect=PhotoEffectTool.Vignette;
    private bool renderFailed;
    private bool choosingHsl,choosingGrading,autoExposing;
    private long editRevision;
    private int? exportLongEdge;
    private string? lastExportedPath;
    private PhotoInfo? photoInfo;
    private PhotoInfoMode photoInfoMode;
    private long photoInfoRevision;
    private LibraryEntry? contextEntry;
    private double dockHeight=344;
    private double libraryWidth=244;
    private RenderedImage? result;
    private int renderedGpuMode;
    private int? rasterPreviousGpuMode;
    private Func<string>? localizedStatus;
    private readonly HashSet<LibraryEntry> visibleThumbnails=[];
    private readonly DispatcherTimer thumbnailRefresh=new(){Interval=TimeSpan.FromMilliseconds(80)};
    private readonly DispatcherTimer previewResize=new(){Interval=TimeSpan.FromMilliseconds(200)};
    private int previewLongEdge=2000,requestedPreviewLongEdge=2000;
    private bool previewDeferred;
    private LibraryEntry? selectedThumbnail;
    private readonly UpdateChecker updates = new(typeof(App).Assembly.GetName().Version?.ToString(3) ?? "unknown");
    private readonly UsageAnalytics usageAnalytics;
    private AboutWindow? aboutWindow;
    private readonly CancellationTokenSource updateCancellation = new();
    private bool startupReported, analyticsDisposed;
    private long photoImportReportedRevision;
    public MainWindow() : this(new UsageAnalytics()) { }
    public MainWindow(UsageAnalytics usageAnalytics) : this(usageAnalytics,null) { }
    internal MainWindow(string lookLibraryDirectory) : this(new UsageAnalytics(),lookLibraryDirectory) { }
    internal MainWindow(UsageAnalytics usageAnalytics,string? lookLibraryDirectory,AIDenoiseJob? aiJob=null)
    {
        this.usageAnalytics = usageAnalytics;
        this.aiJob=aiJob ?? new((identity,snapshot,progress)=>{
            using var worker=new RenderEngine(gpuMode:0,aiBackend:identity.Backend);
            worker.PrepareAI(identity.Source.Path,snapshot,progress);
        });
        InitializeComponent();
        InitializeAI();
        if (!LookLibrary.TryLoad(lookLibraryDirectory, out lookLibrary, out lookLibraryLoadError))
            lookLibrary = null;
        AutomationProperties.SetAutomationId(this,"MainWindow");
        foreach(var control in new FrameworkElement[]{OpenPhoto,CompareButton,CompareModeButton,CompareOff,CompareSide,CompareSwipe,
            MenuCompareOff,MenuCompareSide,MenuCompareSwipe,NeutralCanvas,ResultCanvas,ExportButton,ExportPng,SaveState,Status,Files})
            AutomationProperties.SetAutomationId(control,control.Name);
        AutomationProperties.SetAutomationId(ValueSlider,"ParameterValueSlider");
        AutomationProperties.SetAutomationId(ValueText,"ParameterValueText");
        if(Application.Current!=null)EditorAppearance.Apply(Application.Current.Resources);
        void RefreshLanguage()
        {
            RecipeStrip.Children.Clear(); recipeButtons.Clear();
            BuildTools(); BuildFilms(); BuildMasterRecipes(); BuildResetMenu(); HslEditor.RefreshLanguage();GradingEditor.RefreshLanguage();CurveEditor.RefreshLanguage();GeometryEditor.RefreshLanguage();
            RefreshControls(); RefreshPhotoInfo(); RefreshExportSizeMenu(); RefreshCopyLabels();
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
        foreach(var navigation in new UIElement[]{Groups,Tools,Files,OpenPhoto,AdjustToggleButton,MainMenu})
            navigation.AddHandler(PreviewMouseDownEvent,new MouseButtonEventHandler(ParameterNavigationPressed),true);
        PreviewKeyDown+=(_,e)=>{if(e.Key==Key.System && e.SystemKey is Key.F or Key.F4)CancelParameterInputs();};
        Files.ItemsSource=library.Roots;
        Files.PreviewKeyDown+=FilesContextKeyDown;
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
        ResultCanvas.HoldStarted+=BeginHoldingBefore;
        ResultCanvas.HoldEnded+=EndHoldingBefore;
        NeutralCanvas.ImageBoundsChanged+=RefreshPhotoLabels;
        ResultCanvas.ImageBoundsChanged+=RefreshPhotoLabels;
        PreviewKeyUp+=ViewKeyReleased;
        Activated+=(_,_)=>SyncBeforeKeyState();
        AddHandler(Keyboard.GotKeyboardFocusEvent,new KeyboardFocusChangedEventHandler((_,_)=>SyncBeforeKeyState()),true);
        Deactivated+=(_,_)=>{CancelViewingInput();GradingEditor.CancelInputs();CurveEditor.CancelInputs();};
        MainMenu.AddHandler(MenuItem.SubmenuOpenedEvent,new RoutedEventHandler((_,_)=>CancelViewingInput()));
        CompareButton.ContextMenuOpening+=(_,_)=>CancelViewingInput();
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
            BundledLook.All.TryGetValue(Path.GetFileName(path), out var bundled);
            name=bundled?.Name ?? name;
            var icon=bundled?.ArtworkName ?? (artwork.TryGetValue(name,out var oldIcon) ? oldIcon : null);
            films.Add(new(name,path,icon != null ? Path.Combine(AppContext.BaseDirectory,"FilmIcons",icon+".png") : null,
                FilmGrouping.ForBuiltIn(Path.GetFileName(path))));
        }
        foreach(var look in lookLibrary?.Looks ?? [])
            films.Add(new(look.Name,look.Path,null));
        BuildTools(); BuildFilms(); BuildMasterRecipes(); BuildResetMenu();
        DenoiseEditor.Changed+=(value,dragging)=>{
            if(!ready || syncing || exporting || transform.Active)return;
            settings.Denoise=value;interacting=dragging;RefreshControls();MarkEdited();Schedule();
        };
        PhotoEffectsEditor.Changed+=(value,dragging)=>{
            if(!ready || syncing || exporting || transform.Active)return;
            settings.Effects=value;interacting=dragging;RefreshControls();MarkEdited();Schedule();
        };
        WhiteBalanceEditor.Changed+=(parameter,value,dragging)=>{
            if(!ready || syncing || exporting || transform.Active)return;
            settings.Set(parameter,value);interacting=dragging;RefreshControls();MarkEdited();Schedule();
        };
        WhiteBalanceEditor.ResetRequested+=()=>{
            if(!ready || syncing || exporting || transform.Active)return;
            RequestReset(new(EditorResetKind.Tool,Tool:EditorAdjustmentTool.WhiteBalance));
        };
        GradingEditor.ResetRequested+=RequestReset;
        CurveEditor.Changed+=(value,dragging)=>{
            if(!ready || syncing || exporting || transform.Active)return;
            settings.Curve=value;interacting=dragging;RefreshControls();MarkEdited();Schedule();
        };
        CurveEditor.LegacyChanged+=(value,dragging)=>{
            if(!ready || syncing || exporting || transform.Active)return;
            settings.Set(Parameter.ToneCurve,value);interacting=dragging;RefreshControls();MarkEdited();Schedule();
        };
        GradingEditor.Changed+=(value,dragging)=>{
            if(!ready || syncing || exporting || transform.Active)return;
            settings.ColorGrading=value;interacting=dragging;RefreshControls();MarkEdited();Schedule();
        };
        InitializeHslTarget();
        HslEditor.ResetRequested+=RequestReset;
        PhotoEffectsEditor.ResetRequested+=()=>RequestReset(new(EditorResetKind.Tool,Tool:CurrentTool));
        HslEditor.Changed+=(value,dragging)=>{
            if(!ready || syncing || exporting || transform.Active)return;
            settings.Hsl=value;interacting=dragging;RefreshControls();MarkEdited();Schedule();
        };
        DenoiseEditor.ResetRequested+=()=>RequestReset(new(EditorResetKind.Tool,Tool:EditorAdjustmentTool.Denoise));
        GeometryEditor.ResetRequested+=()=>RequestReset(new(EditorResetKind.Tool,Tool:EditorAdjustmentTool.Geometry));
        LensEditor.ResetRequested+=()=>RequestReset(new(EditorResetKind.Tool,Tool:EditorAdjustmentTool.Lens));
        LensEditor.Changed+=UpdateLensDraft;
        GeometryEditor.Changed+=UpdateGeometryDraft;
        GeometryEditor.OverlayChanged+=RefreshCropDraft;
        ResultCanvas.CropChanged+=UpdateGeometryDraft;
        ResultCanvas.PrepareCropInteraction=GeometryEditor.CommitInputs;
        OrdinaryParameter.Changed+=(value,dragging)=>{
            if(!ready || syncing || exporting || transform.Active)return;
            interacting=dragging;
            if(selectedAtmosphereParameter is {} atmosphere)settings.SetAtmosphere(atmosphere,value);
            else if(selectedToneParameter is {} tone)settings.SetTone(tone,value);else settings.Set(selectedParameter,value);
            MarkEdited();RefreshControls();Schedule();
        };
        OrdinaryParameter.InvalidInput+=()=>SetStatus(() => Loc.Text("请输入有效数字"),true);
        SetPhotoMargin(true);
        ready=true; RefreshControls(); RefreshRenderLabels(); RefreshCopyLabels();
        InitializeEditWorkflow();
        Closing+=WindowClosing;
        Loaded+=async (_,_)=> {
            if (!startupReported) { startupReported = true; this.usageAnalytics.BeginSession(); }
            if (lookLibraryLoadError != null)
                SetStatus(() => lookLibraryLoadError is LookLibraryException ? lookLibraryLoadError.Message : Loc.Text("本地记录损坏。"), true);
            var input=Environment.GetCommandLineArgs().Skip(1).FirstOrDefault(LibraryEntry.IsImage);
            if(input!=null)OpenFile(input);
            await updates.CheckAsync(false, updateCancellation.Token);
        };
    }
}
