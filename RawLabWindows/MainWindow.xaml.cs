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
    private record Film(string Name,string? Path,string? Artwork,FilmGroup Group=FilmGroup.Other,bool AppearanceUnverified=false,int CompatibilityMode=0);
    private record Work(string File,Adjustments Settings,string? Lut,int Edge,bool Interactive,int GpuMode,bool Compare,bool Refine,long TransformGeneration,long OpenRevision,OriginalIdentity? Source,AIDenoiseIdentity? AIIdentity,HslProbeWork? Probe=null,long SourceGeneration=0,long LookGeneration=0,WbProbeWork? WbProbe=null);
    private AppPaths appPaths;
    private readonly Library library;
    private LookLibrary? lookLibrary;
    private Exception? lookLibraryLoadError;
    private readonly Viewport viewport=new();
    private readonly List<Film> films=[];
    private readonly LatestWork<Work> scheduler=new();
    private record EmbeddedWork(string Path,long Revision);
    private readonly LatestWork<EmbeddedWork> embeddedScheduler=new();
    private readonly EditorPersistenceCoordinator persistence;
    private readonly Dictionary<Parameter,(Button Button,AdjustmentRing Ring)> toolButtons=[];
    private readonly Dictionary<PhotoEffectTool,(Button Button,AdjustmentRing Ring)> effectToolButtons=[];
    private readonly Dictionary<string,Button> filmButtons=new(StringComparer.OrdinalIgnoreCase);
    private Adjustments settings=new();
    private Parameter selectedParameter=Parameter.Exposure;
    private ToneControlParameter? selectedToneParameter;
    private AtmosphereParameter? selectedAtmosphereParameter;
    private HDRRenditionParameter? selectedHdrRenditionParameter;
    private string? file,lut;
    private RenderEngine? engine;
    private bool ready,syncing,interacting,foregroundBusy,closing,closeFinished,exactReady;
    // The modeless batch owns its lifetime; foreground completion must not clear it.
    private bool exporting=>foregroundBusy || batchWindow?.Busy==true;
    private readonly EditorViewState view=new();
    private bool compare=>view.Enabled;
    private bool swipe=>view.Enabled && view.PreferredMode==ComparisonMode.Wipe;
    private bool clipping;
    private EditorToolMode toolMode = EditorToolMode.Parameter;
    private RenderedImage? neutralResult;
    private long neutralRevision;
    private NeutralReferenceKey? acceptedReference;
    private NeutralReferenceKey? acceptedAfter;
    private PhotoEffectTool selectedEffect=PhotoEffectTool.Vignette;
    private bool renderFailed;
    private bool autoExposing;
    private int? exportLongEdge;
    private OutputSharpening exportOutputSharpening = OutputSharpening.Off;
    private string? lastExportedPath;
    private PhotoInfo? photoInfo;
    private PhotoInfoMode photoInfoMode;
    private long photoInfoRevision;
    private LibraryEntry? contextEntry;
    private RenderedImage? result;
    private int renderedGpuMode;
    private int? rasterPreviousGpuMode;
    private Func<string>? localizedStatus;
    private readonly HashSet<LibraryEntry> visibleThumbnails=[];
    private readonly DispatcherTimer thumbnailRefresh=new(){Interval=TimeSpan.FromMilliseconds(80)};
    private readonly DispatcherTimer previewResize=new(){Interval=TimeSpan.FromMilliseconds(200)};
    private int previewLongEdge=2000,requestedPreviewLongEdge=2000;
    private bool previewDeferred;
    private UsageAnalytics usageAnalytics;
    private DiagnosticSessionStore diagnosticSession;
    private AboutWindow? aboutWindow;
    private bool startupReported, analyticsDisposed;
    private long photoImportReportedRevision;
    public MainWindow() : this(AppPaths.Default) { }
    public MainWindow(UsageAnalytics usageAnalytics) : this(AppPaths.Default, usageAnalytics) { }
    internal MainWindow(string lookLibraryDirectory) : this(AppPaths.Default, new UsageAnalytics(), lookLibraryDirectory) { }
    internal MainWindow(UsageAnalytics usageAnalytics,string? lookLibraryDirectory,AIDenoiseJob? aiJob=null,DesktopUpdateController? desktopUpdates=null)
        : this(AppPaths.Default, usageAnalytics, lookLibraryDirectory, aiJob, desktopUpdates) { }
    internal MainWindow(
        AppPaths appPaths,
        UsageAnalytics? usageAnalytics = null,
        string? lookLibraryDirectory = null,
        AIDenoiseJob? aiJob = null,
        DesktopUpdateController? desktopUpdates = null,
        EditStore? editStore = null,
        BatchJournal? batchJournal = null,
        AdjustmentPresetStore? presetStore = null,
        Library? library = null,
        AIGpuPreferenceStore? aiPreferenceStore = null,
        AIDiagnosticStore? aiDiagnostics = null)
    {
        this.appPaths = appPaths;
        ReadEmbeddedPreviewHook = path => RenderEngine.ReadEmbeddedPreview(path, appPaths: this.appPaths);
        this.usageAnalytics = usageAnalytics ?? new UsageAnalytics(appPaths.UsageSettingsPath);
        this.library = library ?? new(appPaths.FoldersPath);
        this.persistence = new EditorPersistenceCoordinator(
            editStore,
            () => new EditStore(this.appPaths.EditsDirectory),
            action => Dispatcher.BeginInvoke(action));
        this.persistence.DeferredExternalCheckReady += FlushDeferredExternalEditsCheckIfNeeded;
        this.batchJournal = batchJournal ?? new(appPaths.BatchDirectory);
        this.presetStore = presetStore ?? new(appPaths.PresetsDirectory);
        this.aiPreferenceStore = aiPreferenceStore ?? new(appPaths.AiGpuPreferencesPath);
        this.aiDiagnostics = aiDiagnostics ?? new(appPaths.AiDiagnosticsDirectory);
        this.diagnosticSession = new(appPaths.DiagnosticsDirectory);
        this.diagnosticSession.ResumeOnLaunch();
        workspaceWidthsPath = appPaths.WorkspaceWidthsPath;
        recentLooksPath = appPaths.RecentLooksPath;
        photoPreviewCacheDirectory = appPaths.EditedPhotoPreviewCacheDirectory;
        exportStagingDirectory = appPaths.ExportStagingDirectory;
        aiPreference = this.aiPreferenceStore.Read();
        this.desktopUpdates = desktopUpdates ?? new(new UnavailableUpdateAdapter("configuration"), new(), new(appPaths.UpdatesDirectory), typeof(App).Assembly.GetName().Version?.ToString(3) ?? "unknown", "");
        this.aiJob = aiJob ?? new((identity,snapshot,progress)=>{
            using var worker = CreateRenderEngine(gpuMode:0, aiBackend:identity.Backend, aiDeviceID:identity.DeviceID);
            worker.PrepareAI(identity.Source.Path,snapshot,progress);
        },(error,identity)=>this.aiDiagnostics.Capture(error,new("prepare",identity.DeviceID,identity.Backend,
            identity.Source.Path,Devices:RenderEngine.GetAIDevices().JSON,ModelDirectory:RenderEngine.BundledAIModel)));
        InitializeComponent();
        InitializeAI();
        if (!LookLibrary.TryLoad(lookLibraryDirectory ?? appPaths.LooksDirectory, out lookLibrary, out lookLibraryLoadError))
            lookLibrary = null;
        AutomationProperties.SetAutomationId(this,"MainWindow");
        foreach(var control in new FrameworkElement[]{OpenPhoto,CompareButton,CompareModeButton,CompareOff,CompareSide,CompareSwipe,
            MenuCompareOff,MenuCompareSide,MenuCompareSwipe,NeutralCanvas,ResultCanvas,ExportButton,ExportPng,SaveState,Status,Files})
            AutomationProperties.SetAutomationId(control,control.Name);
        AutomationProperties.SetAutomationId(ValueSlider,"ParameterValueSlider");
        AutomationProperties.SetAutomationId(ValueText,"ParameterValueText");
        InitializeHDRPresentation();
        if(Application.Current!=null)EditorAppearance.Apply(Application.Current.Resources);
        void RefreshLanguage()
        {
            RecipeStrip.Children.Clear(); recipeButtons.Clear();
            RefreshLookCategories();BuildTools(); BuildFilms(); BuildMasterRecipes(); BuildResetMenu(); HslEditor.RefreshLanguage();GradingEditor.RefreshLanguage();PointColorEditor.RefreshLanguage();SelectiveColorEditor.RefreshLanguage();BwMixerEditor.RefreshLanguage();CalibrationEditor.RefreshLanguage();CurveEditor.RefreshLanguage();GeometryEditor.RefreshLanguage();PhotoEffectsEditor.RefreshLanguage();
            RefreshControls(); RefreshPhotoInfo(); RefreshExportSizeMenu(); RefreshCopyLabels();
            RefreshRenderLabels();
            RefreshSaveNotice();
            RefreshInspection();
            if (localizedStatus != null) { var statusText=localizedStatus(); Status.Text=statusText; Status.ToolTip=statusText; }
            RefreshWorkspaceBrowserLayout();
            foreach(var entry in galleries.SelectMany(gallery=>gallery.Photos).Distinct())entry.RefreshPhotoStatus();
        }
        Loc.Changed += RefreshLanguage;
        Closed += (_, _) => Loc.Changed -= RefreshLanguage;
        foreach(var navigation in new UIElement[]{Groups,Tools,OpenPhoto,AdjustToggleButton,MainMenu})
            navigation.AddHandler(PreviewMouseDownEvent,new MouseButtonEventHandler(ParameterNavigationPressed),true);
        PreviewKeyDown+=(_,e)=>{if(e.Key==Key.System && e.SystemKey is Key.F or Key.F4)CancelParameterInputs();};
        InitializeWorkspace();
        thumbnailRefresh.Tick+=(_,_)=>{thumbnailRefresh.Stop();RefreshVisibleThumbnails();};
        EditorArea.SizeChanged+=(_,_)=>InfoOverlay.MaxWidth=Math.Max(80,Math.Min(380,EditorArea.ActualWidth-32));
        NeutralCanvas.Viewport=ResultCanvas.Viewport=viewport;
        ResultCanvas.PreviewSizeChanged+=UpdatePreviewSize;
        ResultCanvas.HoldStarted+=BeginHoldingBefore;
        ResultCanvas.HoldEnded+=EndHoldingBefore;
        NeutralCanvas.ImageBoundsChanged+=RefreshPhotoLabels;
        ResultCanvas.ImageBoundsChanged+=()=>{RefreshPhotoLabels();if(settings.IsHDREditing)RefreshHDRPresentation();};
        PreviewKeyUp+=ViewKeyReleased;
        Activated+=(_,_)=>SyncBeforeKeyState();
        AddHandler(Keyboard.GotKeyboardFocusEvent,new KeyboardFocusChangedEventHandler((_,_)=>SyncBeforeKeyState()),true);
        Deactivated+=(_,_)=>{if(!preservingUpdateNavigation){CancelViewingInput();CancelCanvasProbeInputs();GradingEditor.CancelInputs();PointColorEditor.CancelInputs();SelectiveColorEditor.CancelInputs();BwMixerEditor.CancelInputs();CalibrationEditor.CancelInputs();CurveEditor.CancelInputs();}};
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
            films.Add(new(look.Name,look.Path,null,AppearanceUnverified:look.AppearanceUnverified,CompatibilityMode:look.CompatibilityMode));
        LoadRecentLooks();RefreshLookCategories();BuildTools(); BuildFilms(); BuildMasterRecipes(); BuildResetMenu();
        DenoiseEditor.Changed+=(value,dragging)=>{
            if(!ready || syncing || exporting || transform.Active)return;
            settings.Denoise=value;interacting=dragging;RefreshControls();MarkEdited();Schedule();
        };
        DenoiseEditor.HDRChanged+=(value,dragging)=>{
            if(!ready || syncing || exporting || transform.Active || settings.HDR is not { Mode: HDRMode.Hdr } hdr)return;
            settings.HDR=hdr.WithDetail(hdr.DetailSettings with { Denoise=value });
            interacting=dragging;RefreshControls();MarkEdited();Schedule();
        };
        PhotoEffectsEditor.Changed+=(value,dragging)=>{
            if(!ready || syncing || exporting || transform.Active)return;
            settings.EditingEffects=value;interacting=dragging;RefreshControls();MarkEdited();Schedule();
        };
        PhotoEffectsEditor.FilmOpticsChanged+=(value,dragging)=>{
            if(!ready || syncing || exporting || transform.Active || settings.IsHDREditing)return;
            settings.FilmOptics=value;interacting=dragging;RefreshControls();MarkEdited();Schedule();
        };
        WhiteBalanceEditor.Changed+=(parameter,value,dragging)=>{
            if(!ready || syncing || exporting || transform.Active)return;
            if (file != null && PhotoInput.IsRaster(file) && !settings.IsHDREditing) settings.SetRasterWhiteBalance(parameter,value);
            else settings.Set(parameter,value);
            interacting=dragging;RefreshControls();MarkEdited();Schedule();
        };
        WhiteBalanceEditor.ResetRequested+=()=>{
            if(!ready || syncing || exporting || transform.Active)return;
            RequestReset(new(EditorResetKind.Tool,Tool:EditorAdjustmentTool.WhiteBalance));
        };
        GradingEditor.ResetRequested+=RequestReset;
        CurveEditor.Changed+=(value,dragging)=>{
            if(!ready || syncing || exporting || transform.Active)return;
            settings.EditingCurve=value;interacting=dragging;RefreshControls();MarkEdited();Schedule();
        };
        CurveEditor.LegacyChanged+=(value,dragging)=>{
            if(!ready || syncing || exporting || transform.Active)return;
            settings.Set(Parameter.ToneCurve,ParameterSpec.All[(int)Parameter.ToneCurve].ToCanonical(value));interacting=dragging;RefreshControls();MarkEdited();Schedule();
        };
        GradingEditor.Changed+=(value,dragging)=>{
            if(!ready || syncing || exporting || transform.Active)return;
            settings.EditingGrading=value;interacting=dragging;RefreshControls();MarkEdited();Schedule();
        };
        InitializeHslTarget();
        InitializeInspection();
        InitializeWbProbe();
        InitializePointColorProbe();
        HslEditor.ResetRequested+=RequestReset;
        PointColorEditor.Changed+=(value,dragging)=>{
            if(!ready || syncing || exporting || transform.Active)return;
            settings.PointColor=value;interacting=dragging;RefreshControls();MarkEdited();Schedule();
        };
        PointColorEditor.ResetRequested+=()=>RequestReset(new(EditorResetKind.Tool,Tool:EditorAdjustmentTool.PointColor));
        SelectiveColorEditor.Changed+=(value,dragging)=>{
            if(!ready || syncing || exporting || transform.Active)return;
            settings.SelectiveColor=value;interacting=dragging;RefreshControls();MarkEdited();Schedule();
        };
        SelectiveColorEditor.ResetRequested+=()=>RequestReset(new(EditorResetKind.Tool,Tool:EditorAdjustmentTool.SelectiveColor));
        BwMixerEditor.Changed+=(value,dragging)=>{
            if(!ready || syncing || exporting || transform.Active)return;
            settings.BwMixer=value;interacting=dragging;RefreshControls();MarkEdited();Schedule();
        };
        BwMixerEditor.ResetRequested+=()=>RequestReset(new(EditorResetKind.Tool,Tool:EditorAdjustmentTool.BwMixer));
        CalibrationEditor.Changed+=(value,dragging)=>{
            if(!ready || syncing || exporting || transform.Active)return;
            settings.Calibration=value;interacting=dragging;RefreshControls();MarkEdited();Schedule();
        };
        CalibrationEditor.ResetRequested+=()=>RequestReset(new(EditorResetKind.Tool,Tool:EditorAdjustmentTool.CameraCalibration));
        PhotoEffectsEditor.ResetRequested+=()=>RequestReset(new(EditorResetKind.Tool,Tool:CurrentTool));
        HslEditor.Changed+=(value,dragging)=>{
            if(!ready || syncing || exporting || transform.Active)return;
            settings.EditingHsl=value;interacting=dragging;RefreshControls();MarkEdited();Schedule();
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
            if(selectedHdrRenditionParameter is {} rendition)settings.SetHDRRendition(rendition,value);
            else if(selectedAtmosphereParameter is {} atmosphere)settings.SetAtmosphere(atmosphere,value);
            else if(selectedToneParameter is {} tone)settings.SetTone(tone,value);
            else if(selectedParameter==Parameter.Sharpening && !settings.IsHDREditing)settings.ApplySharpenV2Edit(amount:ParameterSpec.All[(int)Parameter.Sharpening].ToCanonical(value));
            else settings.Set(selectedParameter,ParameterSpec.All[(int)selectedParameter].ToCanonical(value));
            MarkEdited();RefreshControls();Schedule();
        };
        SharpenRadiusRow.Changed += (value, dragging) => {
            if (!ready || syncing || exporting || transform.Active || settings.IsHDREditing) return;
            interacting = dragging;
            settings.ApplySharpenV2Edit(radius: value);
            MarkEdited(); RefreshControls();
            if (sharpenMaskPreviewActive) RefreshSharpenMaskPreview();
            Schedule();
        };
        SharpenDetailRow.Changed += (value, dragging) => {
            if (!ready || syncing || exporting || transform.Active || settings.IsHDREditing) return;
            interacting = dragging;
            settings.ApplySharpenV2Edit(detail: value);
            MarkEdited(); RefreshControls(); Schedule();
        };
        SharpenMaskingRow.Changed += (value, dragging) => {
            if (!ready || syncing || exporting || transform.Active || settings.IsHDREditing) return;
            interacting = dragging;
            settings.ApplySharpenV2Edit(masking: value);
            MarkEdited(); RefreshControls();
            if (sharpenMaskPreviewActive) RefreshSharpenMaskPreview();
            Schedule();
        };
        SharpenMaskingRow.AltDraggingChanged += active => SetSharpenMaskPreview(active);
        SharpenRadiusRow.InvalidInput += () => SetStatus(() => Loc.Text("请输入有效数字"), true);
        SharpenDetailRow.InvalidInput += () => SetStatus(() => Loc.Text("请输入有效数字"), true);
        SharpenMaskingRow.InvalidInput += () => SetStatus(() => Loc.Text("请输入有效数字"), true);
        LookStrengthRow.Changed += (value, dragging) => {
            if (!ready || syncing || exporting || transform.Active) return;
            interacting = dragging;
            settings.Set(Parameter.Strength, ParameterSpec.All[(int)Parameter.Strength].ToCanonical(value));
            MarkEdited(); RefreshControls(); Schedule();
        };
        LookStrengthRow.InvalidInput += () => SetStatus(() => Loc.Text("请输入有效数字"), true);
        HdrLookStrengthRow.Changed += (value, dragging) => {
            if (!ready || syncing || exporting || transform.Active || settings.HDR is not { Mode: HDRMode.Hdr } hdr || hdr.LookSettings.Sha256 == null) return;
            interacting = dragging;
            settings.HDR = hdr.WithLook(hdr.LookSettings with { Strength = value / 100 });
            MarkEdited(); RefreshControls(); Schedule();
        };
        HdrLookStrengthRow.InvalidInput += () => SetStatus(() => Loc.Text("请输入有效数字"), true);
        OrdinaryParameter.InvalidInput+=()=>SetStatus(() => Loc.Text("请输入有效数字"),true);
        SetPhotoMargin(true);
        ready=true; RefreshControls(); RefreshRenderLabels(); RefreshCopyLabels();
        InitializeEditWorkflow();
        InitializeSoftwareUpdates();
        Closing+=WindowClosing;
        Loaded+=async (_,_)=> {
            if (!startupReported) { startupReported = true; this.usageAnalytics.BeginSession(); }
            if (lookLibraryLoadError != null)
                SetStatus(() => lookLibraryLoadError is LookLibraryException ? lookLibraryLoadError.Message : Loc.Text("本地记录损坏。"), true);
            await this.desktopUpdates.PerformStartupCheckAsync();
        };
    }

    private void SharpenLuminanceV2Changed(object sender, RoutedEventArgs e)
    {
        if (!ready || syncing || exporting || transform.Active || settings.IsHDREditing) return;
        settings.ApplySharpenV2Edit(luminanceV2: SharpenLuminanceV2Check.IsChecked == true);
        MarkEdited(); RefreshControls(); Schedule();
    }

    private void SharpenMaskPreviewDown(object sender, MouseButtonEventArgs e) => SetSharpenMaskPreview(true);
    private void SharpenMaskPreviewUp(object sender, MouseButtonEventArgs e) => SetSharpenMaskPreview(false);
    private void SharpenMaskPreviewLost(object sender, MouseEventArgs e) => SetSharpenMaskPreview(false);
}
