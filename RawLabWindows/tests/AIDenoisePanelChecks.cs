using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;

internal static class AIDenoisePanelChecks
{
    internal static void Run(string output,Action<bool,string> check)
    {
        var app=Application.Current ?? TestWindowState.CreateApplication();
        var previousLanguage=Loc.Preference;
        var panel=new DenoisePanel();panel.Refresh(DenoiseSettings.Clean);
        var host=new Window { Width=440, Height=400, ShowInTaskbar=false, WindowStyle=WindowStyle.None, Opacity=0, Content=panel };
        host.Show();
        try {
        panel.RefreshAI(true,false,true,new(AIDenoiseStatus.Idle));
        var toggle=(CheckBox)panel.FindName("AIEnabledBox");var ordinary=(StackPanel)panel.FindName("OrdinaryDenoise");
        check(toggle.IsEnabled && toggle.IsChecked==false && ordinary.IsEnabled,"Idle AI preserves ordinary controls");
        bool? enabled=null;var cancelled=false;var retry=false;
        panel.AIChanged+=v=>enabled=v;panel.AICancelRequested+=()=>cancelled=true;panel.AIRetryRequested+=()=>retry=true;
        toggle.IsChecked=true;check(enabled==true,"AI toggle dispatches explicit preparation request");
        panel.RefreshAI(true,false,true,new(AIDenoiseStatus.Running,2,7,70));
        check(toggle.IsChecked==true && !ordinary.IsEnabled && ((ProgressBar)panel.FindName("AIProgress")).Value==.1,
            "Pending AI reports real progress and retains disabled ordinary parameters");
        ((Button)panel.FindName("AICancel")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));check(cancelled,"Cancel remains reachable while preparing");
        panel.RefreshAI(true,true,true,new(AIDenoiseStatus.Cancelled));
        check(toggle.IsChecked==true && ((Button)panel.FindName("AIRetry")).Visibility==Visibility.Visible,
            "Cancelled rebuild preserves enabled appearance with explicit retry");
        ((Button)panel.FindName("AIRetry")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));check(retry,"Retry dispatches a new explicit request");
        try {
        foreach(var language in new[]{"zh-Hans","en","de","fr","ja","es"}) {
            Loc.Initialize(language);foreach(var pair in Loc.Strings)app.Resources[pair.Key]=pair.Value;
            var localized=new DenoisePanel {FontSize=14};localized.Refresh(DenoiseSettings.Clean);
            check((((CheckBox)localized.FindName("AIEnabledBox")).Content as TextBlock)?.Text==Loc.Text("AI 降噪（实验）"),"AI toggle uses selected language: "+language);
            foreach (var (camera, gpu, message) in new[] {
                (new HDRCameraDevelopmentSettings(FbddLevel: 1), 0, "请先关闭 FBDD，再使用 HDR AI 降噪。"),
                (new HDRCameraDevelopmentSettings(FbddLevel: 2), 0, "请先关闭 FBDD，再使用 HDR AI 降噪。"),
                (new HDRCameraDevelopmentSettings(CameraProfile: new(new string('a',64), "D65")), 0, "请先清除 HDR 相机配置，再使用 AI 降噪。"),
                (new HDRCameraDevelopmentSettings(), 2, "HDR 编辑目前使用 CPU。请将 GPU 模式设为自动或关闭。")
            }) {
                var hint=PhotoInput.HDRCameraAIUnavailableHint(new HDRSettings {CameraDevelopment=camera},gpu);
                localized.RefreshAI(true,false,false,new(AIDenoiseStatus.Idle),hint);
                check(((TextBlock)localized.FindName("AIStatus")).Text==Loc.Text(message) &&
                    !((CheckBox)localized.FindName("AIEnabledBox")).IsEnabled,
                    "Disabled HDR AI explains its camera/GPU restriction: "+language+" / "+message);
            }
            var surface=new Border {Background=(Brush)app.FindResource("Surface"),Padding=new Thickness(12),Child=localized};
            foreach(var state in new[]{new AIDenoiseState(AIDenoiseStatus.Running,3,90,140),
                new AIDenoiseState(AIDenoiseStatus.Failed,Error:"Fixture failure detail"),new AIDenoiseState(AIDenoiseStatus.Ready)}) {
                localized.RefreshAI(true,true,true,state);surface.Measure(new Size(440,double.PositiveInfinity));
                surface.Arrange(new Rect(new Point(),surface.DesiredSize));surface.UpdateLayout();
                check(surface.DesiredSize.Width<=440,"AI localized panel stays within available width: "+language);
                var bitmap=new RenderTargetBitmap(440,(int)Math.Ceiling(surface.ActualHeight),96,96,PixelFormats.Pbgra32);bitmap.Render(surface);
                Directory.CreateDirectory(output);using var stream=File.Create(Path.Combine(output,$"ai-{language}-{state.Status}.png"));
                var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));encoder.Save(stream);
            }
        }
        } finally {
            Loc.Initialize(previousLanguage);foreach(var pair in Loc.Strings)app.Resources[pair.Key]=pair.Value;
        }
        panel.RefreshAI(false,false,false,new(AIDenoiseStatus.Idle));
        check(((StackPanel)panel.FindName("AISurface")).Visibility==Visibility.Collapsed,"AI-off build hides unused experimental controls");

        var aiStrengthRow = (ParameterRow)panel.FindName("AIStrength");
        double? observedBlend = null;
        panel.AIStrengthChanged += (v, _) => observedBlend = v;
        panel.Refresh(DenoiseSettings.Clean);
        panel.RefreshAI(true, true, true, new(AIDenoiseStatus.Ready), aiStrength: 62.5);
        check(aiStrengthRow.Visibility == Visibility.Visible && aiStrengthRow.Number.Text == "62.5",
            "AI strength slider is visible in SDR when AI is enabled and shows current blend percentage");
        aiStrengthRow.Slider.Value = 0.35;
        check(observedBlend == 35, "AI strength slider dispatches updated DualDn blend percentage");
        panel.Refresh(DenoiseSettings.Clean, hdrStrength: 0.4);
        check(((StackPanel)panel.FindName("AISurface")).Visibility == Visibility.Collapsed,
            "AI strength slider stays hidden inside HDR mode");

        // On-demand AI model package panel states, button enablement, and single-click dispatch
        panel.Refresh(DenoiseSettings.Clean);
        var modelSection = (StackPanel)panel.FindName("AIModelSection");
        var modelProgress = (ProgressBar)panel.FindName("AIModelProgress");
        var modelStatus = (TextBlock)panel.FindName("AIModelStatus");
        var modelNotice = (TextBlock)panel.FindName("AIModelNotice");
        var downloadBtn = (Button)panel.FindName("AIModelDownload");
        var retryBtn = (Button)panel.FindName("AIModelRetry");
        var cancelBtn = (Button)panel.FindName("AIModelCancel");
        var licenseBtn = (Button)panel.FindName("AIModelLicense");
        var removeBtn = (Button)panel.FindName("AIModelRemove");

        var downloadClicks = 0;
        var cancelClicks = 0;
        var licenseClicks = 0;
        var removeClicks = 0;
        panel.AIModelDownloadRequested += () => downloadClicks++;
        panel.AIModelCancelRequested += () => cancelClicks++;
        panel.AIModelLicenseRequested += () => licenseClicks++;
        panel.AIModelRemoveRequested += () => removeClicks++;

        const ulong archiveBytes = 294_125_075UL;
        const ulong unpackedBytes = 333_603_381UL;

        // 1. NotInstalled
        panel.RefreshAI(true, false, false, new(AIDenoiseStatus.Idle),
            modelState: AIModelPackageState.NotInstalled(archiveBytes, unpackedBytes), canDownloadModel: true, canRemoveModel: false);
        check(modelSection.Visibility == Visibility.Visible &&
              modelStatus.Text == Loc.Format("尚未下载 AI 降噪模型（约 {0} MB）。", "294") &&
              modelNotice.Visibility == Visibility.Visible &&
              downloadBtn.Visibility == Visibility.Visible && downloadBtn.IsEnabled &&
              licenseBtn.Visibility == Visibility.Visible &&
              removeBtn.Visibility == Visibility.Collapsed &&
              !toggle.IsEnabled,
            "NotInstalled state shows size, non-commercial notice, download and license buttons with AI toggle disabled");
        downloadBtn.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        check(downloadClicks == 1, "Clicking Download dispatches exactly one download request");
        licenseBtn.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        check(licenseClicks == 1, "Clicking License dispatches license dialog request");

        // Export busy disables download button
        panel.RefreshAI(true, false, false, new(AIDenoiseStatus.Idle),
            modelState: AIModelPackageState.NotInstalled(archiveBytes, unpackedBytes), canDownloadModel: false, canRemoveModel: false);
        check(!downloadBtn.IsEnabled, "Download button disables while export is active");

        // 2. Downloading
        panel.RefreshAI(true, false, false, new(AIDenoiseStatus.Idle),
            modelState: AIModelPackageState.Downloading(147_062_537UL, archiveBytes, unpackedBytes));
        check(modelProgress.Visibility == Visibility.Visible && !modelProgress.IsIndeterminate &&
              Math.Abs(modelProgress.Value - 0.5) < 0.01 &&
              modelStatus.Text == Loc.Format("正在下载 AI 降噪模型… {0} / {1} MB", "147", "294") &&
              cancelBtn.Visibility == Visibility.Visible && cancelBtn.IsEnabled &&
              downloadBtn.Visibility == Visibility.Collapsed,
            "Downloading state shows real progress, MB counters, and cancel button");
        cancelBtn.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        check(cancelClicks == 1, "Clicking Cancel during download dispatches cancel request");

        // 3. Verifying
        panel.RefreshAI(true, false, false, new(AIDenoiseStatus.Idle),
            modelState: AIModelPackageState.Verifying(archiveBytes, unpackedBytes));
        check(modelProgress.Visibility == Visibility.Visible && modelProgress.IsIndeterminate &&
              modelStatus.Text == Loc.Text("正在校验 AI 降噪模型…") &&
              cancelBtn.Visibility == Visibility.Visible,
            "Verifying state shows indeterminate progress, verifying text, and cancel button");

        // 4. Installing
        panel.RefreshAI(true, false, false, new(AIDenoiseStatus.Idle),
            modelState: AIModelPackageState.Installing(archiveBytes, unpackedBytes));
        check(modelProgress.Visibility == Visibility.Visible && modelProgress.IsIndeterminate &&
              modelStatus.Text == Loc.Text("正在安装 AI 降噪模型…") &&
              cancelBtn.Visibility == Visibility.Visible,
            "Installing state shows indeterminate progress, installing text, and cancel button");

        // 5. Cancelled
        panel.RefreshAI(true, false, false, new(AIDenoiseStatus.Idle),
            modelState: AIModelPackageState.Cancelled(archiveBytes, unpackedBytes), canDownloadModel: true);
        check(modelStatus.Text.Contains(Loc.Text("已取消下载 AI 降噪模型。"), StringComparison.Ordinal) &&
              modelStatus.Text.Contains(Loc.Format("尚未下载 AI 降噪模型（约 {0} MB）。", "294"), StringComparison.Ordinal) &&
              downloadBtn.Visibility == Visibility.Visible && downloadBtn.IsEnabled,
            "Cancelled state shows cancelled notice, archive size, and re-enabled download button");

        // 6. Failed
        var httpErr = new AIModelPackageException(AIModelPackageErrorCode.HttpNotFound, httpStatusCode: 404);
        panel.RefreshAI(true, false, false, new(AIDenoiseStatus.Idle),
            modelState: AIModelPackageState.Failed(httpErr, archiveBytes, unpackedBytes), canDownloadModel: true);
        check(modelStatus.Text == Loc.Text("服务器上暂未找到模型文件（HTTP 404），请稍后重试或更新应用。") &&
              retryBtn.Visibility == Visibility.Visible && retryBtn.IsEnabled &&
              downloadBtn.Visibility == Visibility.Collapsed &&
              licenseBtn.Visibility == Visibility.Visible,
            "Failed state shows localized error reason, retry button, and license link");
        retryBtn.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        check(downloadClicks == 2, "Clicking Retry dispatches exactly one download request");

        // 7. Installed (Downloaded) — remove button reflects guard
        var downloadedSource = new AIModelDirectorySource(AIModelDirectoryKind.Downloaded, Path.Combine(output, "fake-model"));
        panel.RefreshAI(true, false, true, new(AIDenoiseStatus.Idle),
            modelState: AIModelPackageState.Installed(downloadedSource, unpackedBytes), canDownloadModel: true, canRemoveModel: false);
        check(modelStatus.Text == Loc.Format("已下载 AI 降噪模型（约 {0} MB）。", "334") &&
              removeBtn.Visibility == Visibility.Visible && !removeBtn.IsEnabled &&
              licenseBtn.Visibility == Visibility.Visible,
            "Downloaded installed state disables Remove while AI/export/batch guard is active");
        panel.RefreshAI(true, false, true, new(AIDenoiseStatus.Idle),
            modelState: AIModelPackageState.Installed(downloadedSource, unpackedBytes), canDownloadModel: true, canRemoveModel: true);
        check(removeBtn.IsEnabled, "Downloaded installed state enables Remove when idle");
        removeBtn.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        check(removeClicks == 1, "Clicking Remove dispatches remove confirmation request");

        // 8. Installed (Bundled / Override) and Unavailable (including missing DirectML hardware) hide download management
        panel.RefreshAI(true, false, true, new(AIDenoiseStatus.Idle),
            modelState: AIModelPackageState.Installed(new AIModelDirectorySource(AIModelDirectoryKind.Bundled, output), unpackedBytes));
        check(modelSection.Visibility == Visibility.Collapsed, "Bundled model hides download management section");
        var hardwareHint = Loc.Text("AI 降噪需要支持 DirectML 的 D3D12 硬件显卡。");
        panel.RefreshAI(true, false, false, new(AIDenoiseStatus.Idle), unavailableHint: hardwareHint,
            modelState: AIModelPackageState.Unavailable(), canDownloadModel: false, canRemoveModel: false);
        check(modelSection.Visibility == Visibility.Collapsed &&
              downloadBtn.Visibility == Visibility.Collapsed &&
              retryBtn.Visibility == Visibility.Collapsed &&
              ((TextBlock)panel.FindName("AIStatus")).Text == hardwareHint,
            "Unavailable DirectML hardware hides model download controls while keeping hardware notice");
        panel.RefreshAI(true, false, false, new(AIDenoiseStatus.Idle), unavailableHint: hardwareHint,
            modelState: AIModelPackageState.Installed(downloadedSource, unpackedBytes), canDownloadModel: false, canRemoveModel: true);
        check(modelSection.Visibility == Visibility.Visible &&
              removeBtn.Visibility == Visibility.Visible && removeBtn.IsEnabled &&
              downloadBtn.Visibility == Visibility.Collapsed &&
              ((TextBlock)panel.FindName("AIStatus")).Text == hardwareHint,
            "Already-downloaded models stay removable when DirectML hardware becomes unavailable");

        // 8b. Batch export effect inspection ("查看应用后的效果") blocks model removal via Busy/BusyChanged
        VerifyBatchInspectGuardsModelRemoval(output, check);

        // 9. License text fallbacks when nothing is bundled
        var emptyDir = Path.Combine(output, "empty-license-probe-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(emptyDir);
        try {
            check(AIModelLicenseWindow.ReadDualDnLicense(null, emptyDir).Contains("CC BY-NC 4.0", StringComparison.Ordinal) &&
                  AIModelLicenseWindow.ReadRestormerLicense(null, emptyDir).Contains("Restormer Academic Public License", StringComparison.Ordinal),
                "License viewer provides embedded DualDn and Restormer notices when nothing is bundled");
            File.WriteAllText(Path.Combine(emptyDir, "DualDn-LICENSE.txt"), "Installed DualDn license text");
            check(AIModelLicenseWindow.ReadDualDnLicense(emptyDir, emptyDir) == "Installed DualDn license text",
                "License viewer prefers license file from installed model directory");
        } finally {
            if (Directory.Exists(emptyDir)) Directory.Delete(emptyDir, true);
        }

        // 10. Multi-language real child-control layout fit & state screenshots for all visible model states
        try {
            const double panelWidth = 360;
            foreach (var language in new[] { "zh-Hans", "en", "de", "fr", "ja", "es" }) {
                Loc.Initialize(language); foreach (var pair in Loc.Strings) app.Resources[pair.Key] = pair.Value;
                var modelStates = new (string Name, AIModelPackageState State, bool CanStart)[] {
                    ("notInstalled", AIModelPackageState.NotInstalled(archiveBytes, unpackedBytes), false),
                    ("downloading", AIModelPackageState.Downloading(147_062_537UL, archiveBytes, unpackedBytes), false),
                    ("verifying", AIModelPackageState.Verifying(archiveBytes, unpackedBytes), false),
                    ("installing", AIModelPackageState.Installing(archiveBytes, unpackedBytes), false),
                    ("cancelled", AIModelPackageState.Cancelled(archiveBytes, unpackedBytes), false),
                    ("failed", AIModelPackageState.Failed(httpErr, archiveBytes, unpackedBytes), false),
                    ("installed", AIModelPackageState.Installed(downloadedSource, unpackedBytes), true),
                };
                foreach (var (name, mState, canStartAI) in modelStates) {
                    var statePanel = new DenoisePanel { FontSize = 14 }; statePanel.Refresh(DenoiseSettings.Clean);
                    statePanel.RefreshAI(true, false, canStartAI, new(AIDenoiseStatus.Idle), modelState: mState, canDownloadModel: true, canRemoveModel: true);
                    var surface = new Border { Width = panelWidth, Background = (Brush)app.FindResource("Surface"), Padding = new Thickness(12), Child = statePanel };
                    surface.Measure(new Size(panelWidth, double.PositiveInfinity));
                    var height = Math.Max(1, Math.Ceiling(surface.DesiredSize.Height));
                    surface.Arrange(new Rect(0, 0, panelWidth, height)); surface.UpdateLayout();
                    CheckAIModelSectionLayout(surface, statePanel, panelWidth, $"{language}/{name}", check);
                    if (language is "zh-Hans" or "en" && name is "notInstalled" or "downloading" or "failed" or "installed") {
                        var bitmap = new RenderTargetBitmap((int)panelWidth, (int)height, 96, 96, PixelFormats.Pbgra32);
                        bitmap.Render(surface);
                        Directory.CreateDirectory(output);
                        using var stream = File.Create(Path.Combine(output, $"ai-model-{language}-{name}.png"));
                        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap)); encoder.Save(stream);
                    }
                }
            }
        } finally {
            Loc.Initialize(previousLanguage); foreach (var pair in Loc.Strings) app.Resources[pair.Key] = pair.Value;
        }
        } finally {
            host.Close();
        }
    }

    private static void VerifyBatchInspectGuardsModelRemoval(string output, Action<bool, string> check)
    {
        var root = Path.Combine(output, "batch-inspect-remove-guard-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(root);
        MainWindow? window = null;
        try {
            window = TestWindowState.CreateIsolatedWindow(root, width: 1200, height: 800);
            var paths = window.Paths;
            var manifestBytes = Encoding.UTF8.GetBytes("{\"version\":1}");
            var manifestSha = Convert.ToHexString(SHA256.HashData(manifestBytes)).ToLowerInvariant();
            var descriptor = new AIModelPackageDescriptor(
                SchemaVersion: 1,
                Platform: "windows-x64",
                Url: "https://example.invalid/test.tar.gz",
                ArchiveName: "test.tar.gz",
                ArchiveSha256: new string('a', 64),
                ArchiveBytes: 64,
                ManifestSha256: manifestSha,
                UnpackedBytes: (ulong)manifestBytes.Length,
                Entries: [new AIModelArchiveEntry("manifest.json", AIModelArchiveEntryKind.File, (ulong)manifestBytes.Length, manifestSha)]);
            var installedDir = Path.Combine(paths.DualDnModelDirectory, manifestSha);
            Directory.CreateDirectory(installedDir);
            File.WriteAllBytes(Path.Combine(installedDir, "manifest.json"), manifestBytes);

            var sampleImage = Path.Combine(root, "sample.png");
            var sampleBitmap = BitmapSource.Create(16, 16, 96, 96, PixelFormats.Bgr24, null, new byte[16 * 16 * 3], 16 * 3);
            var png = new PngBitmapEncoder(); png.Frames.Add(BitmapFrame.Create(sampleBitmap));
            using (var fs = File.Create(sampleImage)) png.Save(fs);

            window.Show();
            var store = new AIModelPackageStore(paths.DualDnModelDirectory, descriptor, allowLoopbackHttp: false);
            var manager = new AIModelPackageManager(
                store,
                isRuntimeSupported: () => true,
                isHardwareAvailable: () => true,
                dispatch: action => {
                    if (window.Dispatcher.HasShutdownStarted) return;
                    if (window.Dispatcher.CheckAccess()) action();
                    else window.Dispatcher.BeginInvoke(action);
                });
            window.CurrentFile = sampleImage;
            window.SetAIModelManagerForTests(manager);
            window.SelectToolForTests(EditorAdjustmentTool.Denoise);
            window.RefreshControlsForTests();
            DrainDispatcher();

            var removeBtn = (Button)window.DenoiseEditor.FindName("AIModelRemove");
            check(window.ToolMode == EditorToolMode.Denoise &&
                  removeBtn.Visibility == Visibility.Visible &&
                  window.CanRemoveDownloadedAIModelForTests && removeBtn.IsEnabled,
                "Before batch inspect, downloaded AI model removal is visible and enabled");

            var job = BatchJob.Create(sampleImage, new Adjustments().Capture(), null, "Neutral");
            job.Items.Add(BatchItem.Create(sampleImage) with { Selected = true });
            window.BatchJournalInstance.Save(job);
            window.ShowBatchForTests(job);
            DrainDispatcher();

            var batch = window.BatchWindowInstance!;
            using var inspectEntered = new ManualResetEventSlim(false);
            using var releaseInspect = new ManualResetEventSlim(false);
            batch.BeforeInspectRenderForTests = () => {
                inspectEntered.Set();
                releaseInspect.Wait(TimeSpan.FromSeconds(10));
            };

            var inspectTask = batch.InspectRowAsync(batch.Rows[0], showPreviewWindow: false);
            try {
                check(inspectEntered.Wait(TimeSpan.FromSeconds(10)), "Batch inspect entered background render worker");
                DrainDispatcher();
                check(batch.Busy, "BatchExportWindow.Busy is true while effect inspection is running");
                check(!window.CanRemoveDownloadedAIModelForTests && !removeBtn.IsEnabled,
                    "AI model removal guard and button disable while batch effect inspection is active");
                var removedWhileInspecting = window.TryRemoveDownloadedAIModelForTests();
                check(!removedWhileInspecting && Directory.Exists(installedDir) && File.Exists(Path.Combine(installedDir, "manifest.json")),
                    "AI model removal handler refuses to delete model files during active batch inspection");
            } finally {
                releaseInspect.Set();
            }

            WaitForTaskOnDispatcher(inspectTask, TimeSpan.FromSeconds(10));
            DrainDispatcher();
            check(!batch.Busy && window.CanRemoveDownloadedAIModelForTests && removeBtn.IsEnabled,
                "AI model removal re-enables once batch effect inspection completes");
            check(window.TryRemoveDownloadedAIModelForTests() && !Directory.Exists(installedDir),
                "AI model removal succeeds after batch effect inspection finishes");

            batch.Close();
            DrainDispatcher();
        } finally {
            window?.Close();
            DrainDispatcher();
            if (Directory.Exists(root)) try { Directory.Delete(root, true); } catch { }
        }
    }

    private static void DrainDispatcher()
    {
        var frame = new DispatcherFrame();
        Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() => frame.Continue = false));
        Dispatcher.PushFrame(frame);
    }

    private static void WaitForTaskOnDispatcher(Task task, TimeSpan timeout)
    {
        if (task.IsCompleted) return;
        var dispatcher = Dispatcher.CurrentDispatcher;
        var frame = new DispatcherFrame();
        var timer = new DispatcherTimer { Interval = timeout };
        timer.Tick += (_, _) => { timer.Stop(); frame.Continue = false; };
        timer.Start();
        _ = task.ContinueWith(_ => dispatcher.BeginInvoke(new Action(() => { timer.Stop(); frame.Continue = false; })), TaskScheduler.Default);
        Dispatcher.PushFrame(frame);
        timer.Stop();
    }

    private static void CheckAIModelSectionLayout(Border surface, DenoisePanel panel, double availableWidth, string context, Action<bool, string> check)
    {
        const double tolerance = 0.5;
        var section = (StackPanel)panel.FindName("AIModelSection");
        var dpi = VisualTreeHelper.GetDpi(surface).PixelsPerDip;
        check(section.Visibility == Visibility.Visible && section.ActualWidth > 0 && section.ActualHeight > 0,
            $"AI model section is visibly laid out ({context})");
        var sectionBounds = section.TransformToAncestor(surface).TransformBounds(new Rect(0, 0, section.ActualWidth, section.ActualHeight));
        check(sectionBounds.Left >= -tolerance && sectionBounds.Top >= -tolerance &&
              sectionBounds.Right <= availableWidth + tolerance && sectionBounds.Bottom <= surface.ActualHeight + tolerance,
            $"AI model section stays within {availableWidth:0}px host bounds ({context}: right={sectionBounds.Right:0.0})");

        foreach (var textName in new[] { "AIModelStatus", "AIModelNotice" }) {
            var tb = (TextBlock)panel.FindName(textName);
            if (tb.Visibility != Visibility.Visible) continue;
            var inSection = tb.TransformToAncestor(section).TransformBounds(new Rect(0, 0, tb.ActualWidth, tb.ActualHeight));
            var inSurface = tb.TransformToAncestor(surface).TransformBounds(new Rect(0, 0, tb.ActualWidth, tb.ActualHeight));
            var formatted = new FormattedText(
                tb.Text,
                CultureInfo.CurrentUICulture,
                tb.FlowDirection,
                new Typeface(tb.FontFamily, tb.FontStyle, tb.FontWeight, tb.FontStretch),
                tb.FontSize,
                Brushes.Black,
                dpi) {
                MaxTextWidth = Math.Max(1, tb.ActualWidth),
            };
            check(tb.TextWrapping == TextWrapping.Wrap && tb.TextTrimming == TextTrimming.None && !string.IsNullOrWhiteSpace(tb.Text),
                $"{textName} wraps without trimming ({context})");
            check(tb.ActualWidth > 0 && tb.ActualHeight > 0 &&
                  inSection.Left >= -tolerance && inSection.Right <= section.ActualWidth + tolerance &&
                  inSection.Bottom <= section.ActualHeight + tolerance &&
                  inSurface.Right <= availableWidth + tolerance &&
                  formatted.Width <= tb.ActualWidth + 1.0 &&
                  formatted.Height <= tb.ActualHeight + 2.0,
                $"{textName} fits wrapped without clipping ({context}: fmt={formatted.Width:0.0}x{formatted.Height:0.0}, actual={tb.ActualWidth:0.0}x{tb.ActualHeight:0.0})");
        }

        var progress = (ProgressBar)panel.FindName("AIModelProgress");
        if (progress.Visibility == Visibility.Visible) {
            var pBounds = progress.TransformToAncestor(section).TransformBounds(new Rect(0, 0, progress.ActualWidth, progress.ActualHeight));
            check(progress.ActualWidth > 0 && progress.ActualHeight > 0 &&
                  pBounds.Left >= -tolerance && pBounds.Right <= section.ActualWidth + tolerance,
                $"AIModelProgress fits inside section ({context})");
        }

        var visibleButtons = new List<(string Name, Rect Bounds)>();
        foreach (var buttonName in new[] { "AIModelDownload", "AIModelRetry", "AIModelCancel", "AIModelLicense", "AIModelRemove" }) {
            var btn = (Button)panel.FindName(buttonName);
            if (btn.Visibility != Visibility.Visible) continue;
            var inSection = btn.TransformToAncestor(section).TransformBounds(new Rect(0, 0, btn.ActualWidth, btn.ActualHeight));
            var inSurface = btn.TransformToAncestor(surface).TransformBounds(new Rect(0, 0, btn.ActualWidth, btn.ActualHeight));
            var desiredWidth = Math.Max(0, btn.DesiredSize.Width - btn.Margin.Left - btn.Margin.Right);
            var desiredHeight = Math.Max(0, btn.DesiredSize.Height - btn.Margin.Top - btn.Margin.Bottom);
            var labelText = btn.Content as string ?? "";
            var presenter = FindDescendant<ContentPresenter>(btn);
            var labelFits = true;
            if (presenter != null && labelText.Length > 0) {
                var formattedLabel = new FormattedText(
                    labelText,
                    CultureInfo.CurrentUICulture,
                    btn.FlowDirection,
                    new Typeface(btn.FontFamily, btn.FontStyle, btn.FontWeight, btn.FontStretch),
                    btn.FontSize,
                    Brushes.Black,
                    dpi);
                labelFits = formattedLabel.Width <= presenter.ActualWidth + 1.5 && formattedLabel.Height <= presenter.ActualHeight + 2.0;
            }
            check(btn.ActualWidth > 0 && btn.ActualHeight > 0 &&
                  inSection.Left >= -tolerance && inSection.Top >= -tolerance &&
                  inSection.Right <= section.ActualWidth + tolerance &&
                  inSection.Bottom <= section.ActualHeight + tolerance &&
                  inSurface.Right <= availableWidth + tolerance &&
                  desiredWidth <= btn.ActualWidth + tolerance &&
                  desiredHeight <= btn.ActualHeight + tolerance &&
                  labelFits,
                $"{buttonName} fits without overflow or clipping ({context}: actual={btn.ActualWidth:0.0}x{btn.ActualHeight:0.0}, sectionW={section.ActualWidth:0.0}, right={inSurface.Right:0.0})");
            visibleButtons.Add((buttonName, inSection));
        }

        for (var i = 0; i < visibleButtons.Count; i++) {
            for (var j = i + 1; j < visibleButtons.Count; j++) {
                var overlap = Rect.Intersect(visibleButtons[i].Bounds, visibleButtons[j].Bounds);
                check(overlap.IsEmpty || overlap.Width <= tolerance || overlap.Height <= tolerance,
                    $"Buttons {visibleButtons[i].Name} and {visibleButtons[j].Name} do not overlap ({context})");
            }
        }
    }

    private static T? FindDescendant<T>(DependencyObject root) where T : DependencyObject
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is T match) return match;
            if (FindDescendant<T>(child) is { } nested) return nested;
        }
        return null;
    }
}
