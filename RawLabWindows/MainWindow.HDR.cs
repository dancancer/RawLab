using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace RawLab.Windows;

public partial class MainWindow
{
    private HDRSourceInfo? hdrSource;
    private bool hdrSdrPreview, hdrFalseColor, cameraHDRPreflight;
    private readonly DispatcherTimer hdrDisplayTimer = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly Dictionary<HDRFloatImage, BitmapSource> hdrFalseColorCache = new(ReferenceEqualityComparer.Instance);
    private readonly HashSet<HDRFloatImage> hdrFalseColorPending = new(ReferenceEqualityComparer.Instance);
    private int hdrPresentationRevision;
    private CancellationTokenSource hdrPresentationCancellation = new();
    private HDRRenderedPair? hdrPresentationResult, hdrPresentationReference;
    private float hdrPresentationHeadroom = 1;

    private void InitializeHDRPresentation()
    {
        LayoutUpdated += (_, _) => RefreshHDRPresentation();
        hdrDisplayTimer.Tick += (_, _) => {
            ResultHDRSurface.RefreshCapabilities(); NeutralHDRSurface.RefreshCapabilities();
            var headroom = ResultHDRSurface.Headroom;
            if (headroom != hdrPresentationHeadroom) {
                hdrPresentationHeadroom = headroom; InvalidateHDRFalseColor(); RefreshViewingFrames();
            } else RefreshHDRPresentation();
        };
        Closed += (_, _) => { hdrDisplayTimer.Stop(); InvalidateHDRFalseColor(); };
    }
    private void InvalidateHDRFalseColor()
    {
        hdrPresentationRevision++; hdrPresentationCancellation.Cancel();hdrPresentationCancellation.Dispose();hdrPresentationCancellation=new();
        hdrFalseColorCache.Clear(); hdrFalseColorPending.Clear();
    }
    private void PrepareHDRFrames()
    {
        if (!ReferenceEquals(hdrPresentationResult,result?.HDR) || !ReferenceEquals(hdrPresentationReference,neutralResult?.HDR)) {
            hdrPresentationResult=result?.HDR; hdrPresentationReference=neutralResult?.HDR; InvalidateHDRFalseColor();
        }
    }
    private BitmapSource? HDRPresentationBitmap(RenderedImage? frame)
    {
        var image=frame?.HDR?.HDR;
        if (!hdrFalseColor || !settings.IsHDREditing || image==null) return frame?.Image;
        if (hdrFalseColorCache.TryGetValue(image,out var bitmap)) return bitmap;
        if (hdrFalseColorPending.Add(image)) {
            var revision=hdrPresentationRevision; var headroom=hdrPresentationHeadroom;
            var cancellation=hdrPresentationCancellation.Token;
            _=Task.Run(()=>HDRDisplay.FalseColor(image,headroom,cancellation),cancellation).ContinueWith(task=>Dispatcher.InvokeAsync(()=> {
                if(revision!=hdrPresentationRevision)return;
                hdrFalseColorPending.Remove(image);
                if(task.IsCompletedSuccessfully) { hdrFalseColorCache[image]=task.Result; RefreshViewingFrames(); }
                else if(task.Exception!=null) Report(task.Exception.GetBaseException());
            }),TaskScheduler.Default);
        }
        return frame?.Image;
    }
    private void RefreshHDRPresentation()
    {
        if (!IsLoaded) return;
        var active=settings.IsHDREditing && result?.HDR!=null;
        if(active && !hdrDisplayTimer.IsEnabled) {
            ResultHDRSurface.RefreshCapabilities();NeutralHDRSurface.RefreshCapabilities();hdrDisplayTimer.Start();
        } else if(!active)hdrDisplayTimer.Stop();
        var overlays=new FrameworkElement[]{NeutralLabel,FilmLabel,InfoEntryButton,InfoOverlay,LibraryOverlay,BusyIndicator,HslTargetBanner};
        var resultPresented=false;
        void Present(HDRSurface surface,PhotoCanvas canvas,HDRFloatImage? image,HDRFloatImage? reference) {
            Grid.SetRow(surface,Grid.GetRow(canvas));Grid.SetColumn(surface,Grid.GetColumn(canvas));
            Grid.SetRowSpan(surface,Grid.GetRowSpan(canvas));Grid.SetColumnSpan(surface,Grid.GetColumnSpan(canvas));
            surface.Visibility=active && !hdrSdrPreview && surface.Available && !canvas.GeometryEditing && !canvas.ShowClipping
                ? canvas.Visibility : Visibility.Collapsed;
            var presented=surface.ShowFrame(active ? image : null,reference,canvas,hdrSdrPreview,hdrFalseColor,overlays);
            if(ReferenceEquals(surface,ResultHDRSurface))resultPresented=presented;
        }
        var reference=ReferenceCurrent ? neutralResult?.HDR?.HDR : null;
        Present(ResultHDRSurface,ResultCanvas,result?.HDR?.HDR,reference);
        Present(NeutralHDRSurface,NeutralCanvas,reference,null);
        var shown=view.HoldingBefore && ReferenceCurrent ? neutralResult?.HDR : result?.HDR;
        Histogram.SetHdrStatistics(active ? shown?.Statistics.Bins : null, ResultHDRSurface.Headroom);
        if(active && shown!=null) {
            HistogramTitle.Text=Loc.Text("HDR 亮度直方图");
            HistogramSource.Text=Loc.Text(hdrFalseColor ? "HDR 假色" : hdrSdrPreview ? "SDR 兼容预览" : resultPresented ? "自动 HDR" : "HDR 显示不可用，当前显示 SDR。");
            ClipStats.Text=Loc.Format("参考白以上 {0}",shown.Statistics.AboveWhite.ToString("P1",System.Globalization.CultureInfo.CurrentCulture));
        } else HistogramTitle.Text=Loc.Text("RGB 直方图");
        HistogramHeading.Text = HistogramTitle.Text;
    }

    private void RefreshHDRControls()
    {
        HDREditMenu.IsEnabled = file != null && hdrSource != null && !exporting && !transform.Active &&
            !adjustmentReloadRequired && !cameraHDRPreflight;
        HDREditMenu.IsChecked = settings.IsHDREditing;
        HDRPreviewMenu.IsEnabled = HDRSdrPreviewMenu.IsEnabled = HDRFalseColorMenu.IsEnabled = settings.IsHDREditing;
        HDRRenditionMenu.IsEnabled = HDREditMenu.IsEnabled && settings.IsHDREditing;
        HDRLookMenu.IsEnabled = HDRRenditionMenu.IsEnabled;
        HDRCameraMenu.IsEnabled = HDRRenditionMenu.IsEnabled && hdrSource is { IsCameraRaw:true, IsProRAW:false };
        HDRPreviewMenu.IsChecked = !hdrSdrPreview; HDRSdrPreviewMenu.IsChecked = hdrSdrPreview;
        HDRFalseColorMenu.IsChecked = hdrFalseColor;
    }

    private async void HDREditClicked(object sender, RoutedEventArgs e)
    {
        if (file == null || hdrSource == null || cameraHDRPreflight) { RefreshHDRControls(); return; }
        CancelParameterInputs();
        if (!ResolveTransformDraft() || !SaveEdits()) { RefreshHDRControls(); return; }
        var before = settings;
        var candidate = before.Clone();
        var enabled = HDREditMenu.IsChecked;
        var cameraRaw = hdrSource.IsCameraRaw;
        try
        {
            candidate.SetHDRMode(enabled, hdrSource.IsHDR, cameraRaw: cameraRaw, proRAW: hdrSource.IsProRAW);
        }
        catch (Exception error) { RefreshControls(); Report(error); return; }

        if (enabled && cameraRaw)
        {
            var path = file;
            var opened = openRevision;
            var revision = editRevision;
            var edge = previewLongEdge;
            var gpu = GpuMode.SelectedIndex == 0 ? 1 : GpuMode.SelectedIndex == 1 ? 0 : 2;
            bool IsCurrent() => !closing && !exporting && !transform.Active && file == path &&
                openRevision == opened && editRevision == revision;
            cameraHDRPreflight = true;
            RefreshHDRControls();
            try
            {
                await Task.Run(() =>
                {
                    using var validator = new RenderEngine(gpuMode: gpu);
                    var preflight = candidate.Clone();
                    preflight.HDRCameraAIEnabled = false;
                    validator.Render(path, preflight, null, edge, statistics: false, clipping: false);
                });
                if (!IsCurrent()) return;
            }
            catch (Exception error)
            {
                if (IsCurrent()) Report(error);
                return;
            }
            finally
            {
                cameraHDRPreflight = false;
                if (!closing) RefreshHDRControls();
            }
        }

        ResetAITask();
        settings = candidate;
        MarkEdited();
        if (!SaveEdits()) { settings = before; RefreshControls(); return; }
        RefreshControls();
        Schedule();
    }

    private void HDRPreviewClicked(object sender, RoutedEventArgs e) { hdrSdrPreview = false; RefreshHDRControls(); RefreshViewingFrames(); }
    private void HDRSdrPreviewClicked(object sender, RoutedEventArgs e) { hdrSdrPreview = true; RefreshHDRControls(); RefreshViewingFrames(); }
    private void HDRFalseColorClicked(object sender, RoutedEventArgs e) { hdrFalseColor = HDRFalseColorMenu.IsChecked; RefreshViewingFrames(); }

    private void HDRLookClicked(object sender, RoutedEventArgs e)
    {
        if (!HDRLookMenu.IsEnabled || !PrepareAdjustmentCommand() || settings.HDR is not { Mode: HDRMode.Hdr } hdr) return;
        var opened = openRevision;
        var revision = editRevision;
        var draft = hdr;
        var dialog = new Window { Owner=this, Title="HDR LUT", Width=440, SizeToContent=SizeToContent.Height,
            ResizeMode=ResizeMode.NoResize, ShowInTaskbar=false, WindowStartupLocation=WindowStartupLocation.CenterOwner };
        AutomationProperties.SetAutomationId(dialog,"hdr.look");
        var panel = new StackPanel { Margin=new Thickness(24) };
        var name = new TextBlock { TextWrapping=TextWrapping.Wrap };
        var error = new TextBlock { TextWrapping=TextWrapping.Wrap };
        var strength = new ParameterRow { SourceIdentity=opened, KeepInvalidInput=true };
        AutomationProperties.SetAutomationId(strength.Number,"hdr.look.strength.value");
        var pick = new Button { Content=Loc.Text("导入外观…"), Margin=new Thickness(0,6,6,6) };
        var clear = new Button { Content=Loc.Text("中性"), Margin=new Thickness(0,6,6,6) };
        var silver = new Button { Content="HDR Silver", Margin=new Thickness(0,6,6,6) };
        var master = new Button { Content="HDR Silver Master", Margin=new Thickness(0,6,6,6) };
        var apply = new Button { Content=Loc.Text("应用"), IsDefault=true, Margin=new Thickness(6,6,0,0) };
        AutomationProperties.SetAutomationId(pick,"hdr.look.import");
        AutomationProperties.SetAutomationId(clear,"hdr.look.clear");
        AutomationProperties.SetAutomationId(apply,"hdr.look.apply");
        AutomationProperties.SetAutomationId(silver,"hdr.look.silver");
        AutomationProperties.SetAutomationId(master,"hdr.look.silver-master");
        void RefreshDraft() {
            var look = draft.LookSettings;
            name.Text=look.Name ?? "HDR LUT";
            strength.Refresh(Loc.Text("外观强度"),new(0,200,1),look.Strength*100,100,"%",look.Sha256!=null);
            clear.IsEnabled=look.Sha256!=null;
        }
        async Task Load(Func<HDRSettings> load) {
            pick.IsEnabled=clear.IsEnabled=silver.IsEnabled=master.IsEnabled=apply.IsEnabled=strength.IsEnabled=false;
            try { draft=await Task.Run(load); error.Text=""; }
            catch (Exception failure) when (failure is System.IO.IOException or UnauthorizedAccessException or System.Text.Json.JsonException) {
                error.Text=Loc.Text("无法读取外观文件。");
            }
            finally { pick.IsEnabled=silver.IsEnabled=master.IsEnabled=apply.IsEnabled=strength.IsEnabled=true; RefreshDraft(); }
        }
        HDRSettings Bundled(HDRSettings target, bool applyMaster) {
            var directory = System.IO.Path.Combine(AppContext.BaseDirectory,"BundledLooks","HDR");
            var look = HDRNative.ImportLook(System.IO.Path.Combine(directory,"HDR Silver.cube"));
            if (!applyMaster) return target.WithLook(look);
            var payload = AdjustmentPayload.Parse(System.IO.File.ReadAllText(System.IO.Path.Combine(directory,"HDR Silver Master.json")));
            if (AdjustmentPayload.HDRLookValue(payload[AdjustmentField.HdrLook]) != look) throw new HDRSourceException(1,18,10);
            return HDRAdjustmentTransfer.PrepareSettings(payload,target);
        }
        strength.Changed += (value,_) => draft=draft.WithLook(draft.LookSettings with { Strength=value/100 });
        pick.Click += async (_,_) => {
            var picker = new Microsoft.Win32.OpenFileDialog { Title="HDR LUT", Filter="CUBE (*.cube)|*.cube", CheckFileExists=true };
            if (picker.ShowDialog(dialog)!=true) return;
            var before = draft;
            await Load(()=>before.WithLook(HDRNative.ImportLook(picker.FileName)));
        };
        silver.Click += async (_,_) => { var before = draft; await Load(()=>Bundled(before,false)); };
        master.Click += async (_,_) => { var before = draft; await Load(()=>Bundled(before,true)); };
        clear.Click += (_,_) => { draft=draft.WithLook(new()); error.Text=""; RefreshDraft(); };
        apply.Click += (_,_) => { if (draft.LookSettings.Sha256==null || strength.Commit()) dialog.DialogResult=true; };
        var choices = new WrapPanel();
        foreach (var button in new[] { pick,clear,silver,master }) choices.Children.Add(button);
        var actions = new WrapPanel { HorizontalAlignment=HorizontalAlignment.Right };
        actions.Children.Add(new Button { Content=Loc.Text("取消"), IsCancel=true, Margin=new Thickness(0,6,0,0) });
        actions.Children.Add(apply);
        panel.Children.Add(name); panel.Children.Add(choices); panel.Children.Add(strength); panel.Children.Add(error); panel.Children.Add(actions);
        dialog.Content=panel; RefreshDraft();
        if (dialog.ShowDialog()!=true || opened!=openRevision || revision!=editRevision || closing || draft==hdr) return;
        settings.HDR=draft;
        MarkEdited(); RefreshControls(); Schedule();
    }

    private async void HDRCameraClicked(object sender, RoutedEventArgs e)
    {
        if (!HDRCameraMenu.IsEnabled || !PrepareAdjustmentCommand() || file is not { } path ||
            settings.HDR is not { Mode:HDRMode.Hdr } hdr) return;
        var opened = openRevision;
        var revision = editRevision;
        var draft = hdr.CameraSettings;
        var dialog = new Window { Owner=this, Title="HDR RAW", Width=480, SizeToContent=SizeToContent.Height,
            ResizeMode=ResizeMode.NoResize, ShowInTaskbar=false, WindowStartupLocation=WindowStartupLocation.CenterOwner };
        AutomationProperties.SetAutomationId(dialog,"hdr.camera");
        var panel = new StackPanel { Margin=new Thickness(24) };
        var temperature = new ParameterRow { SourceIdentity=opened, KeepInvalidInput=true };
        var tint = new ParameterRow { SourceIdentity=opened, KeepInvalidInput=true };
        var custom = new ComboBox { ItemsSource=new[] { Loc.Text("相机白平衡（按目标照片）"), Loc.Text("自定义") },
            SelectedIndex=draft.CustomWhiteBalance ? 1 : 0 };
        void RefreshWB() {
            temperature.Refresh(Loc.Text("色温"),new(2000,50000,50),draft.CustomWhiteBalance ? draft.Temperature : 6500,6500,"K",draft.CustomWhiteBalance);
            tint.Refresh(Loc.Text("色调"),new(-150,150,1),draft.Tint,0,"",draft.CustomWhiteBalance);
        }
        custom.SelectionChanged += (_,_) => {
            var selected = custom.SelectedIndex==1;
            draft=draft with { CustomWhiteBalance=selected, Temperature=selected ? 6500 : 0, Tint=0 };
            RefreshWB();
        };
        temperature.Changed += (value,_) => draft=draft with { Temperature=value };
        tint.Changed += (value,_) => draft=draft with { Tint=value };
        var exposure = new ComboBox { ItemsSource=new[] { Loc.Text("场景"), Loc.Text("传感器基准") }, SelectedIndex=draft.SensorExposure ? 1 : 0 };
        exposure.SelectionChanged += (_,_) => draft=draft with { SensorExposure=exposure.SelectedIndex==1 };
        var fbdd = new ComboBox { ItemsSource=new[] { Loc.Text("关闭"), "FBDD 1", "FBDD 2" }, SelectedIndex=draft.FbddLevel };
        fbdd.SelectionChanged += (_,_) => draft=draft with { FbddLevel=fbdd.SelectedIndex };
        var crop = new CheckBox { Content=Loc.Text("自动裁切"), IsChecked=draft.LensAutoCrop, IsEnabled=draft.LensActive, Margin=new Thickness(0,6,0,0) };
        CheckBox LensToggle(string title, bool current, Action<bool> update) {
            var toggle = new CheckBox { Content=Loc.Text(title), IsChecked=current, Margin=new Thickness(0,6,0,0) };
            toggle.Click += (_,_) => { update(toggle.IsChecked==true); crop.IsEnabled=draft.LensActive; };
            return toggle;
        }
        crop.Click += (_,_) => draft=draft with { LensAutoCrop=crop.IsChecked==true };
        void AddRow(string label, ComboBox combo, string id) {
            var title = Loc.Text(label);
            panel.Children.Add(new TextBlock { Text=title, Margin=new Thickness(0,6,0,0) });
            AutomationProperties.SetName(combo,title);
            AutomationProperties.SetAutomationId(combo,"hdr.camera."+id);
            panel.Children.Add(combo);
        }
        AddRow("白平衡模式",custom,"wb");
        panel.Children.Add(temperature); panel.Children.Add(tint);
        AddRow("曝光基准",exposure,"exposure");
        if (hdrSource?.SupportsBayerDevelopment == true) AddRow("RAW 降噪",fbdd,"fbdd");
        panel.Children.Add(LensToggle("畸变校正",draft.LensDistortion,value => draft=draft with { LensDistortion=value }));
        panel.Children.Add(LensToggle("横向色差",draft.LensTca,value => draft=draft with { LensTca=value }));
        panel.Children.Add(crop);
        var profileName = new TextBlock { Margin=new Thickness(0,10,0,4), TextWrapping=TextWrapping.Wrap };
        AutomationProperties.SetAutomationId(profileName,"hdr.camera.profile.name");
        var profileError = new TextBlock { Margin=new Thickness(0,4,0,0), TextWrapping=TextWrapping.Wrap };
        var chooseProfile = new Button { Content=Loc.Text("导入相机配置…") };
        var clearProfile = new Button { Content=Loc.Text("清除相机配置"), Margin=new Thickness(6,0,0,0) };
        AutomationProperties.SetAutomationId(chooseProfile,"hdr.camera.profile.import");
        AutomationProperties.SetAutomationId(clearProfile,"hdr.camera.profile.clear");
        void RefreshProfile() {
            profileName.Text=draft.CameraProfile?.Name ?? Loc.Text("HDR 相机配置");
            clearProfile.IsEnabled=draft.CameraProfile!=null;
        }
        var profileActions = new WrapPanel();
        profileActions.Children.Add(chooseProfile);
        profileActions.Children.Add(clearProfile);
        panel.Children.Add(profileName);
        panel.Children.Add(profileActions);
        panel.Children.Add(profileError);
        var actions = new WrapPanel { HorizontalAlignment=HorizontalAlignment.Right, Margin=new Thickness(0,12,0,0) };
        var apply = new Button { Content=Loc.Text("应用"), IsDefault=true };
        AutomationProperties.SetAutomationId(apply,"hdr.camera.apply");
        chooseProfile.Click += async (_,_) => {
            var picker = new Microsoft.Win32.OpenFileDialog { Title=Loc.Text("HDR 相机配置"),
                Filter="DCP / RLOOK (*.dcp;*.rlook)|*.dcp;*.rlook", CheckFileExists=true };
            if (picker.ShowDialog(dialog)!=true) return;
            chooseProfile.IsEnabled=clearProfile.IsEnabled=apply.IsEnabled=false;
            profileError.Text="";
            try {
                var profile = await Task.Run(() => HDRNative.ImportCameraProfile(picker.FileName));
                draft=draft with { CameraProfile=profile };
            } catch (Exception failure) { profileError.Text=failure.Message; }
            finally { chooseProfile.IsEnabled=apply.IsEnabled=true; RefreshProfile(); }
        };
        clearProfile.Click += (_,_) => { draft=draft with { CameraProfile=null }; profileError.Text=""; RefreshProfile(); };
        apply.Click += (_,_) => {
            if (draft.CustomWhiteBalance && (!temperature.Commit() || !tint.Commit())) return;
            if (!draft.LensActive) draft=draft with { LensProfile=null };
            if (draft.IsValid) dialog.DialogResult=true;
        };
        actions.Children.Add(new Button { Content=Loc.Text("取消"), IsCancel=true });
        actions.Children.Add(apply); panel.Children.Add(actions);
        dialog.Content=panel; RefreshWB(); RefreshProfile();
        if (dialog.ShowDialog()!=true || opened!=openRevision || revision!=editRevision || closing || draft==hdr.CameraSettings) return;
        var previous = settings;
        var candidate = previous.Clone();
        candidate.HDR=hdr.WithCameraDevelopment(draft);
        if (!draft.AllowsAI) candidate.HDRCameraAIEnabled = false;
        var edge = previewLongEdge;
        var gpu = GpuMode.SelectedIndex == 0 ? 1 : GpuMode.SelectedIndex == 1 ? 0 : 2;
        bool IsCurrent() => !closing && !exporting && !transform.Active && file==path &&
            opened==openRevision && revision==editRevision;
        cameraHDRPreflight=true; RefreshHDRControls();
        try {
            await Task.Run(() => {
                using var validator = new RenderEngine(gpuMode:gpu);
                var preflight = candidate.Clone();
                preflight.HDRCameraAIEnabled = false;
                validator.Render(path,preflight,null,edge,statistics:false,clipping:false);
            });
            if (!IsCurrent()) return;
            settings=candidate; MarkEdited();
            if (!SaveEdits()) { settings=previous; RefreshControls(); return; }
            RefreshControls(); Schedule();
        } catch (Exception failure) { if (IsCurrent()) Report(failure); }
        finally { cameraHDRPreflight=false; if (!closing) RefreshHDRControls(); }
    }

    private void HDRRenditionClicked(object sender, RoutedEventArgs e)
    {
        if (!HDRRenditionMenu.IsEnabled || !PrepareAdjustmentCommand() || settings.HDR is not { Mode: HDRMode.Hdr } hdr)
            return;
        var opened = openRevision;
        var revision = editRevision;
        var draft = hdr.RenditionSettings;
        var dialog = new Window {
            Owner=this, Title=Loc.Text("HDR 输出与 SDR 底图"), Width=520, SizeToContent=SizeToContent.Height,
            ResizeMode=ResizeMode.NoResize, ShowInTaskbar=false, WindowStartupLocation=WindowStartupLocation.CenterOwner
        };
        AutomationProperties.SetAutomationId(dialog,"hdr.rendition");
        var panel = new StackPanel { Margin=new Thickness(24) };
        var rows = new List<ParameterRow>();
        void Add(string id, string title, NumericRange range, double value, string unit, Action<double> update)
        {
            var row = new ParameterRow { SourceIdentity=opened, Margin=new Thickness(0,3,0,3), KeepInvalidInput=true };
            row.Refresh(Loc.Text(title),range,value,0,unit);
            AutomationProperties.SetAutomationId(row.Slider,"hdr.rendition."+id);
            AutomationProperties.SetAutomationId(row.Number,"hdr.rendition."+id+".value");
            row.Changed += (next,_) => update(next);
            rows.Add(row);
            panel.Children.Add(row);
        }
        Add("peakLimit","HDR 亮度上限",new(0,6),draft.PeakLimitEV,"EV",value => draft=draft with { PeakLimitEV=value });
        panel.Children.Add(new TextBlock { Text="0 EV · " + Loc.Text("不限"), Margin=new Thickness(0,0,0,6) });
        Add("sdrExposure","SDR 底图曝光",new(-4,4),draft.SdrExposureEV,"EV",value => draft=draft with { SdrExposureEV=value });
        Add("sdrContrast","SDR 底图对比度",new(-100,100,1),draft.SdrContrast,"%",value => draft=draft with { SdrContrast=value });
        Add("sdrSaturation","SDR 底图饱和度",new(-100,100,1),draft.SdrSaturation,"%",value => draft=draft with { SdrSaturation=value });
        var actions = new WrapPanel { HorizontalAlignment=HorizontalAlignment.Right, Margin=new Thickness(0,12,0,0) };
        var cancel = new Button { Content=Loc.Text("取消"), IsCancel=true };
        var apply = new Button { Content=Loc.Text("应用"), IsDefault=true };
        AutomationProperties.SetAutomationId(apply,"hdr.rendition.apply");
        apply.Click += (_,_) => {
            foreach (var row in rows) {
                if (row.Commit()) continue;
                row.Number.Focus(); return;
            }
            dialog.DialogResult=true;
        };
        actions.Children.Add(cancel); actions.Children.Add(apply); panel.Children.Add(actions);
        dialog.Content=panel;
        if (dialog.ShowDialog() != true || opened != openRevision || revision != editRevision || closing ||
            draft == hdr.RenditionSettings) return;
        settings.HDR=hdr.WithRendition(draft);
        MarkEdited();
        RefreshControls();
        Schedule();
    }
}
