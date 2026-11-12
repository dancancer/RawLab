using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;

// 真实 MainWindow 入口回归：覆盖不可用记录恢复弹窗钩子/模态窗与完整重置链路（含迁移回执清理及撤销行为）。
internal static class EditDurabilityWindowChecks
{
    private const BindingFlags PrivateInstance = BindingFlags.Instance | BindingFlags.NonPublic;

    internal static void Run(string output, Action<bool, string> check)
    {
        TestWindowState.PreserveExistingBatch(BatchJournal.DefaultDirectory);
        Directory.CreateDirectory(output);
        var ownsApp = Application.Current == null;
        var previous = Loc.Preference;
        Loc.Initialize("zh-Hans");
        var app = ownsApp ? TestWindowState.CreateApplication() : Application.Current!;
        foreach (var pair in Loc.Strings) app.Resources[pair.Key] = pair.Value;
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        try
        {
            RunCore(output, check);
        }
        finally
        {
            Loc.Initialize(previous);
            if (ownsApp) app.Shutdown();
        }
    }

    internal static void RunCore(string output, Action<bool, string> check)
    {
        Directory.CreateDirectory(output);
        UnusableRecordOpenTriggersConfirmationHookAndResetsOnlyTargetPhoto(output, check);
        RealMainWindowResetClearsReceiptUpdatesControlsAndUndoKeepsReceiptAbsent(output, check);
    }

    // 覆盖 OpenFile -> RestoreEdits catch -> ConfirmResetUnusableRecord（confirmUnusableRecordReset 钩子与真实模态窗）-> TransferSession.ResetToUnmodified。
    private static void UnusableRecordOpenTriggersConfirmationHookAndResetsOnlyTargetPhoto(string output, Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetFullPath(output), "unusable-" + Guid.NewGuid().ToString("N")[..8]);
        var lookRoot = Path.Combine(root, "looks");
        Directory.CreateDirectory(root);
        var brokenPhoto = Path.Combine(root, "broken.png");
        var hdrBrokenPhoto = Path.Combine(root, "hdr-broken.png");
        var dialogBrokenPhoto = Path.Combine(root, "dialog-broken.png");
        var siblingPhoto = Path.Combine(root, "sibling.png");
        foreach (var path in new[] { brokenPhoto, hdrBrokenPhoto, dialogBrokenPhoto, siblingPhoto })
            WritePng(path);

        var storeDirectory = Path.Combine(root, "edits");
        var seedStore = new EditStore(storeDirectory);
        var brokenId = OriginalIdentity.Read(brokenPhoto);
        var hdrId = OriginalIdentity.Read(hdrBrokenPhoto);
        var dialogBrokenId = OriginalIdentity.Read(dialogBrokenPhoto);
        var siblingId = OriginalIdentity.Read(siblingPhoto);

        foreach (var id in new[] { brokenId, dialogBrokenId, siblingId })
        {
            var legacy = LegacyEdit(id);
            seedStore.SaveState(id, legacy);
            check(ProcessingMigration.TryBuildCandidate(legacy, SampleMigrationResult(), out var migrated),
                "Seed migration candidate for " + Path.GetFileName(id.Path));
            seedStore.CommitProcessingMigration(id, legacy, migrated!, ProcessingMigrationReceipt.Migrated);
        }

        var hdrSettings = new Adjustments { HDR = new HDRSettings { Mode = HDRMode.Hdr, Exposure = 0.5 } };
        seedStore.SaveState(hdrId, new SavedEdit(hdrId, hdrSettings.Capture(), null));

        var editsPath = Path.Combine(storeDirectory, "edits.json");
        var registryNode = JsonNode.Parse(File.ReadAllText(editsPath))!;
        var recordsNode = registryNode["Records"]!.AsObject();
        recordsNode[brokenId.Path]!["Settings"]!["Atmosphere"] = JsonNode.Parse("{\"Clarity\":500,\"Dehaze\":0}");
        recordsNode[dialogBrokenId.Path]!["Settings"]!["Hsl"] = JsonNode.Parse("{\"Values\":[]}");
        recordsNode[hdrId.Path]!["Settings"]!["ProRAWDecodeVersion"] = 99;
        File.WriteAllText(editsPath, registryNode.ToJsonString());

        var editsBeforeDecline = File.ReadAllText(editsPath);
        string siblingRecordBefore;
        string siblingReceiptBefore;
        using (var beforeDoc = JsonDocument.Parse(editsBeforeDecline))
        {
            siblingRecordBefore = beforeDoc.RootElement.GetProperty("Records").GetProperty(siblingId.Path).GetRawText();
            siblingReceiptBefore = beforeDoc.RootElement.GetProperty("MigrationReceipts").GetProperty(siblingId.Path).GetRawText();
        }

        var window = new MainWindow(lookRoot);
        TestWindowState.Isolate(window, root, editDirectory: storeDirectory);
        DispatcherTimer? timer = null;
        window.Show();
        window.UpdateLayout();
        try
        {
            var store = Get<EditStore>(window, "editStore");

            // 1) 取消恢复（confirmUnusableRecordReset 返回 false）：不打开该照片、不改动磁盘记录与回执。
            string? hookInput = null;
            Exception? hookError = null;
            window.confirmUnusableRecordReset = (input, error) =>
            {
                hookInput = input;
                hookError = error;
                return false;
            };
            window.OpenFile(brokenPhoto);
            SettleWindow(window);
            check(StringComparer.OrdinalIgnoreCase.Equals(hookInput, brokenId.Path) &&
                  hookError is UnusableEditRecordException { InnerException: ArgumentOutOfRangeException },
                "OpenFile routes out-of-range sub-setting failure through confirmUnusableRecordReset hook");
            check(GetNullable<string>(window, "file") == null && File.ReadAllText(editsPath) == editsBeforeDecline,
                "Declining unusable-record reset aborts photo open and preserves disk edits.json byte-identical");

            // 2) 确认恢复（confirmUnusableRecordReset 返回 true）：ResetToUnmodified 仅删除目标照片记录与迁移回执，并以默认设置打开。
            hookInput = null;
            hookError = null;
            window.confirmUnusableRecordReset = (input, error) =>
            {
                hookInput = input;
                hookError = error;
                return true;
            };
            window.OpenFile(brokenPhoto);
            SettleWindow(window);
            window.UpdateLayout();
            check(StringComparer.OrdinalIgnoreCase.Equals(hookInput, brokenId.Path) && hookError is UnusableEditRecordException,
                "Confirming unusable-record reset invokes hook for target photo");
            check(StringComparer.OrdinalIgnoreCase.Equals(GetNullable<string>(window, "file"), brokenId.Path) &&
                  GetNullable<PhotoEditState>(window, "currentEditRecord") is { Edit: null } &&
                  GetNullable<ProcessingMigrationReceipt>(window, "processingMigrationReceipt") == null &&
                  Get<Adjustments>(window, "settings")[Parameter.Exposure] == 0,
                "Confirming unusable-record reset opens target photo in unmodified default state");
            check(window.ProcessingMigrationState.Visibility == Visibility.Collapsed &&
                  window.RollbackProcessingMigrationButton.Visibility == Visibility.Collapsed,
                "Confirming unusable-record reset hides migration receipt controls");
            check(store.ReadState(brokenPhoto).Edit == null && store.ReadProcessingMigration(brokenPhoto) == null,
                "Confirming unusable-record reset deletes target photo record and receipt from store");

            // 3) 活跃 HDR 不兼容版本（HDRModeException.InvalidSettings）同样走同一恢复入口。
            hookInput = null;
            hookError = null;
            window.OpenFile(hdrBrokenPhoto);
            SettleWindow(window);
            check(StringComparer.OrdinalIgnoreCase.Equals(hookInput, hdrId.Path) &&
                  hookError is HDRModeException { Failure: HDRModeFailure.InvalidSettings },
                "Incompatible active ProRAW HDR record triggers confirmUnusableRecordReset hook");
            check(StringComparer.OrdinalIgnoreCase.Equals(GetNullable<string>(window, "file"), hdrId.Path) &&
                  GetNullable<PhotoEditState>(window, "currentEditRecord") is { Edit: null } &&
                  !Get<Adjustments>(window, "settings").IsHDREditing &&
                  store.ReadState(hdrBrokenPhoto).Edit == null,
                "Confirming active HDR unusable-record reset clears target record and opens unmodified");

            // 4) 不挂钩子时，真实模态对话框（editor.reset.unusable）点击「重置全部调整」走通同一恢复链路，且邻近照片不受影响。
            window.confirmUnusableRecordReset = null;
            var sawUnusableDialog = false;
            var watch = Stopwatch.StartNew();
            timer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(20) };
            timer.Tick += (_, _) =>
            {
                var dialog = Application.Current!.Windows.OfType<Window>()
                    .FirstOrDefault(candidate => AutomationProperties.GetAutomationId(candidate) == "editor.reset.unusable");
                if (dialog == null) return;
                if (watch.Elapsed > TimeSpan.FromSeconds(30))
                {
                    dialog.Close();
                    timer.Stop();
                    throw new TimeoutException("Unusable-record confirmation dialog timed out");
                }
                sawUnusableDialog = true;
                var resetButton = PhotoFeatureChecks.Descendants<Button>(dialog)
                    .Single(button => Equals(button.Content, Loc.Text("重置全部调整")));
                PhotoFeatureChecks.Click(resetButton);
            };
            timer.Start();
            window.OpenFile(dialogBrokenPhoto);
            timer.Stop();
            SettleWindow(window);
            check(sawUnusableDialog &&
                  StringComparer.OrdinalIgnoreCase.Equals(GetNullable<string>(window, "file"), dialogBrokenId.Path) &&
                  store.ReadState(dialogBrokenPhoto).Edit == null &&
                  store.ReadProcessingMigration(dialogBrokenPhoto) == null,
                "Real editor.reset.unusable modal dialog confirms ResetToUnmodified for malformed record");

            using (var afterDoc = JsonDocument.Parse(File.ReadAllText(editsPath)))
            {
                check(afterDoc.RootElement.GetProperty("Records").GetProperty(siblingId.Path).GetRawText() == siblingRecordBefore &&
                      afterDoc.RootElement.GetProperty("MigrationReceipts").GetProperty(siblingId.Path).GetRawText() == siblingReceiptBefore,
                    "Recovering unusable records preserves sibling photo record and receipt byte-identical");
            }
        }
        finally
        {
            timer?.Stop();
            CloseApproved(window);
            InteractionChecks.PumpUntil(() => !window.IsVisible);
            DeleteQuietly(root);
        }
    }

    // 覆盖 RequestReset(All) -> ExecuteReset -> ConfirmReset -> CommitReset -> MarkEditedCore -> SaveEditsCore -> CommitResetEdit -> ClearProcessingMigrationReceiptState，
    // 以及 UndoAdjustmentMenu 点击后只恢复调整数值、不恢复已清除迁移回执（方案 b）。
    private static void RealMainWindowResetClearsReceiptUpdatesControlsAndUndoKeepsReceiptAbsent(string output, Action<bool, string> check)
    {
        foreach (var initialStatus in new[] {
            ProcessingMigrationReceipt.Migrated,
            ProcessingMigrationReceipt.Kept,
            ProcessingMigrationReceipt.RolledBack
        })
        {
            var root = Path.Combine(Path.GetFullPath(output), "reset-" + initialStatus + "-" + Guid.NewGuid().ToString("N")[..8]);
            var lookRoot = Path.Combine(root, "looks");
            Directory.CreateDirectory(root);
            var photo = Path.Combine(root, "photo.png");
            var sibling = Path.Combine(root, "sibling.png");
            WritePng(photo);
            WritePng(sibling);

            var storeDirectory = Path.Combine(root, "edits");
            var seedStore = new EditStore(storeDirectory);
            var identity = OriginalIdentity.Read(photo);
            var siblingId = OriginalIdentity.Read(sibling);

            var before = LegacyEdit(identity);
            var siblingBefore = LegacyEdit(siblingId);
            seedStore.SaveState(identity, before);
            seedStore.SaveState(siblingId, siblingBefore);

            check(ProcessingMigration.TryBuildCandidate(siblingBefore, SampleMigrationResult(), out var siblingMigrated),
                "Seed sibling migration for " + initialStatus);
            seedStore.CommitProcessingMigration(siblingId, siblingBefore, siblingMigrated!, ProcessingMigrationReceipt.Migrated);

            check(ProcessingMigration.TryBuildCandidate(before, SampleMigrationResult(), out var migrated),
                "Seed target migration for " + initialStatus);
            if (initialStatus == ProcessingMigrationReceipt.Kept)
                seedStore.CommitProcessingMigration(identity, before, before, ProcessingMigrationReceipt.Kept);
            else
            {
                var migratedState = seedStore.CommitProcessingMigration(identity, before, migrated!, ProcessingMigrationReceipt.Migrated);
                if (initialStatus == ProcessingMigrationReceipt.RolledBack)
                    seedStore.RollbackProcessingMigration(identity, migratedState);
            }

            var window = new MainWindow(lookRoot);
            TestWindowState.Isolate(window, root, editDirectory: storeDirectory);
            DispatcherTimer? timer = null;
            window.Show();
            window.UpdateLayout();
            try
            {
                var store = Get<EditStore>(window, "editStore");

                // 1) 打开照片：内存回执与迁移状态控件按 initialStatus 呈现。
                window.OpenFile(photo);
                SettleWindow(window);
                window.UpdateLayout();
                check(GetNullable<ProcessingMigrationReceipt>(window, "processingMigrationReceipt")?.Status == initialStatus,
                    "OpenFile loads migration receipt into MainWindow for status " + initialStatus);
                check(window.ProcessingMigrationState.Visibility == Visibility.Visible &&
                      window.RollbackProcessingMigrationButton.Visibility ==
                          (initialStatus == ProcessingMigrationReceipt.Migrated ? Visibility.Visible : Visibility.Collapsed),
                    "MainWindow migration controls reflect loaded receipt for status " + initialStatus);

                // 2) 局部重置（单工具 Contrast）：保留磁盘与内存迁移回执及控件可见性。
                var partialScope = new EditorResetScope(EditorResetKind.Tool, Tool: EditorAdjustmentTool.Contrast);
                var partialPrepared = window.PrepareReset(partialScope);
                check(partialPrepared is { Status: EditorResetStatus.Ready },
                    "Partial tool reset is ready on MainWindow for status " + initialStatus);
                var partialRevision = Get<long>(window, "editRevision");
                check(window.CommitReset(partialPrepared!, partialRevision),
                    "Partial tool CommitReset succeeds on MainWindow for status " + initialStatus);
                SettleWindow(window);
                window.UpdateLayout();
                check(Get<Adjustments>(window, "settings")[Parameter.Contrast] == 0 &&
                      store.ReadProcessingMigration(photo)?.Status == initialStatus &&
                      GetNullable<ProcessingMigrationReceipt>(window, "processingMigrationReceipt")?.Status == initialStatus &&
                      window.ProcessingMigrationState.Visibility == Visibility.Visible,
                    "Partial tool reset on MainWindow preserves migration receipt and UI state for status " + initialStatus);

                var preResetSnapshot = Get<Adjustments>(window, "settings").Capture();
                var preResetProcessing = Get<Adjustments>(window, "settings").Processing;
                var preResetExposure = Get<Adjustments>(window, "settings")[Parameter.Exposure];

                // 3) 真实完整重置入口：RequestReset(All) -> ExecuteReset -> ConfirmReset 模态窗 -> CommitReset -> MarkEditedCore(true)
                //    -> SaveEditsCore(true) -> CommitResetEdit -> ClearProcessingMigrationReceiptState。
                var sawResetDialog = false;
                var watch = Stopwatch.StartNew();
                timer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(20) };
                timer.Tick += (_, _) =>
                {
                    var dialog = Application.Current!.Windows.OfType<Window>()
                        .FirstOrDefault(candidate => AutomationProperties.GetAutomationId(candidate) == "editor.reset.confirmation");
                    if (dialog == null) return;
                    if (watch.Elapsed > TimeSpan.FromSeconds(30))
                    {
                        dialog.Close();
                        timer.Stop();
                        throw new TimeoutException("All-reset confirmation dialog timed out");
                    }
                    sawResetDialog = true;
                    var confirmButton = PhotoFeatureChecks.Descendants<Button>(dialog)
                        .Single(button => Equals(button.Content, Loc.Text("重置")));
                    PhotoFeatureChecks.Click(confirmButton);
                };
                timer.Start();
                Invoke(window, "RequestReset", new EditorResetScope(EditorResetKind.All));
                timer.Stop();
                SettleWindow(window);
                window.UpdateLayout();

                check(sawResetDialog, "RequestReset(All) opens real editor.reset.confirmation modal dialog for status " + initialStatus);
                check(Get<Adjustments>(window, "settings")[Parameter.Exposure] == 0 &&
                      Get<Adjustments>(window, "settings").Processing == preResetProcessing &&
                      store.Find(photo) is { } neutralSaved &&
                      neutralSaved.Settings.Processing == preResetProcessing,
                    "Full reset through MainWindow writes neutral SavedEdit retaining Processing for status " + initialStatus);
                check(store.ReadProcessingMigration(photo) == null &&
                      new EditStore(storeDirectory).ReadProcessingMigration(photo) == null &&
                      store.ReadProcessingMigration(sibling)?.Status == ProcessingMigrationReceipt.Migrated,
                    "Full reset through MainWindow removes only target photo migration receipt on disk for status " + initialStatus);
                check(GetNullable<ProcessingMigrationReceipt>(window, "processingMigrationReceipt") == null &&
                      window.ProcessingMigrationState.Visibility == Visibility.Collapsed &&
                      window.RollbackProcessingMigrationButton.Visibility == Visibility.Collapsed,
                    "Full reset through MainWindow clears in-memory receipt and collapses migration controls for status " + initialStatus);
                try
                {
                    store.RollbackProcessingMigration(identity, store.ReadState(photo));
                    throw new Exception("Rollback succeeded after real MainWindow all-reset");
                }
                catch (AdjustmentOperationExpiredException) { }

                // 4) 真实菜单撤销（UndoAdjustmentMenu -> UndoAdjustmentClicked -> RunPhotoHistory -> UndoPhoto -> AdoptSavedEdit）：
                //    锁定方案 (b) 语义——恢复重置前的参数值，但迁移回执保持 nil、控件保持隐藏、回退仍抛已过期异常。
                window.UndoAdjustmentMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
                SettleWindow(window);
                window.UpdateLayout();

                check(Math.Abs(Get<Adjustments>(window, "settings")[Parameter.Exposure] - preResetExposure) < 1e-5 &&
                      Get<Adjustments>(window, "settings").Capture().SameAs(preResetSnapshot) &&
                      store.Find(photo) is { } undoneSaved &&
                      undoneSaved.Settings.SameAs(preResetSnapshot),
                    "MainWindow Undo after all-reset restores pre-reset adjustment values for status " + initialStatus);
                check(GetNullable<ProcessingMigrationReceipt>(window, "processingMigrationReceipt") == null &&
                      store.ReadProcessingMigration(photo) == null &&
                      new EditStore(storeDirectory).ReadProcessingMigration(photo) == null &&
                      window.ProcessingMigrationState.Visibility == Visibility.Collapsed &&
                      window.RollbackProcessingMigrationButton.Visibility == Visibility.Collapsed,
                    "MainWindow Undo after all-reset keeps migration receipt nil and UI controls collapsed for status " + initialStatus);
                try
                {
                    store.RollbackProcessingMigration(identity, store.ReadState(photo));
                    throw new Exception("Rollback succeeded after MainWindow Undo of all-reset");
                }
                catch (AdjustmentOperationExpiredException) { }
            }
            finally
            {
                timer?.Stop();
                CloseApproved(window);
                InteractionChecks.PumpUntil(() => !window.IsVisible);
                DeleteQuietly(root);
            }
        }
    }

    private static SavedEdit LegacyEdit(OriginalIdentity identity)
    {
        var settings = new Adjustments { Processing = ProcessingIdentity.C5 };
        settings.Set(Parameter.Exposure, 0.7);
        settings.Set(Parameter.Contrast, 18);
        return new SavedEdit(identity, settings.Capture(), null);
    }

    private static Native.ProcessingMigrationResult SampleMigrationResult() => new() {
        Version = 1, StructSize = 80, SourceVersion = 2, TargetVersion = 3,
        Disposition = 1, EvaluationCount = 8,
        ExposureEv = 1.1f, Contrast = 1.18f, Highlights = 0f, Shadows = 0f,
        Saturation = 1f, BlackPoint = 0f, WhitePoint = 0f, Vibrance = 0f,
        Clarity = 0f, Dehaze = 0f, RgbRmse = .002f, P99Error = .01f,
        WorstTileRmse = .004f, DetailRmse = .003f
    };

    private static void WritePng(string path)
    {
        var bitmap = new WriteableBitmap(2, 2, 96, 96, PixelFormats.Bgr24, null);
        bitmap.WritePixels(new Int32Rect(0, 0, 2, 2), new byte[] { 64, 96, 128, 128, 96, 64, 80, 110, 140, 140, 110, 80 }, 6, 0);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = File.Create(path);
        encoder.Save(stream);
    }

    private static void SettleWindow(MainWindow window)
    {
        var scheduler = Get<object>(window, "scheduler");
        var embedded = Get<object>(window, "embeddedScheduler");
        var busyScheduler = scheduler.GetType().GetProperty("Busy")!;
        var busyEmbedded = embedded.GetType().GetProperty("Busy")!;
        InteractionChecks.PumpUntil(() =>
            !(bool)busyScheduler.GetValue(scheduler)! &&
            !(bool)busyEmbedded.GetValue(embedded)! &&
            (GetNullable<string>(window, "file") == null ||
             Get<bool>(window, "exactReady") ||
             Get<bool>(window, "renderFailed")));
    }

    private static void CloseApproved(MainWindow window)
    {
        typeof(MainWindow).GetField("updateQuitApproved", PrivateInstance)!.SetValue(window, true);
        window.Close();
    }

    private static void DeleteQuietly(string directory)
    {
        for (var attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
                return;
            }
            catch (IOException) when (attempt < 4) { Thread.Sleep(40); }
            catch (UnauthorizedAccessException) when (attempt < 4) { Thread.Sleep(40); }
        }
    }

    private static T Get<T>(object owner, string name) =>
        (T)owner.GetType().GetField(name, PrivateInstance)!.GetValue(owner)!;

    private static T? GetNullable<T>(object owner, string name) =>
        (T?)owner.GetType().GetField(name, PrivateInstance)!.GetValue(owner);

    private static object? Invoke(object owner, string name, params object[] args) =>
        owner.GetType().GetMethod(name, PrivateInstance)!.Invoke(owner, args);
}
