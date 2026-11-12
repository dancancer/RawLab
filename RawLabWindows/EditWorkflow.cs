using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace RawLab.Windows;

public partial class MainWindow
{
    private EditStore? editStore;
    private bool editDirty;
    private bool pendingMigrationReceiptClear;
    internal Func<string, Exception, bool>? confirmUnusableRecordReset;
    private bool updateJournalLoadFailed;
    private string? saveNoticeKey;
    private readonly DispatcherTimer editSaveTimer = new() { Interval = TimeSpan.FromMilliseconds(400) };
    private readonly DispatcherTimer editNoticeTimer = new() { Interval = TimeSpan.FromSeconds(3) };
    private readonly BatchJournal batchJournal = new(BatchJournal.DefaultDirectory);
    private BatchJob? previousBatch;
    private BatchExportWindow? batchWindow;
    private bool LookAvailable => settings.IsHDREditing || lut == null || File.Exists(lut);
    private BatchJob? CurrentBatch => batchWindow?.Job ?? previousBatch;

    private void InitializeEditWorkflow()
    {
        editSaveTimer.Tick += (_, _) => { editSaveTimer.Stop(); SaveEdits(); };
        editNoticeTimer.Tick += (_, _) => { editNoticeTimer.Stop(); if (RetrySave.Visibility != Visibility.Visible) {SaveState.Text = "";saveNoticeKey=null;} };
        Deactivated += (_, _) => {
            if (quickPreset.Phase == QuickPresetPhase.Preparing) CancelQuickPreset();
            if(preservingUpdateNavigation)return;
            // 浏览预设不结束参数输入；其他窗口失活仍按原规则取消半输入。
            if(!OwnedWindows.OfType<AdjustmentPresetLibraryDialog>().Any(window=>window.IsVisible))CancelParameterInputs();
            CancelEditGesture();SaveEdits();
        };
        try { editStore = new EditStore(EditStore.DefaultDirectory); }
        catch (Exception error) { SetSaveNotice("无法读取调整记录", AdjustmentTransferPresentation.Detail(error), true); }
        try { previousBatch = batchJournal.Load(); }
        catch (Exception error) { updateJournalLoadFailed=true;Report(new IOException(Loc.Format("无法读取上次批量任务：{0}", AdjustmentTransferPresentation.Detail(error)), error)); }
        RefreshBatchNotice(); UpdateBusy();
        InitializeAdjustmentHistory();
    }

    private void MarkEdited() => MarkEditedCore(false);

    private void MarkEditedCore(bool clearMigrationReceipt)
    {
        CancelProcessingMigration();
        if (quickPreset.Phase == QuickPresetPhase.Preparing) CancelQuickPreset();
        ++editRevision;
        if (!ready || syncing || file == null) return;
        editDirty = true;
        if (clearMigrationReceipt) pendingMigrationReceiptClear = true;
        if (RetrySave.Visibility != Visibility.Visible) {SaveState.Text = "";saveNoticeKey=null;}
        editSaveTimer.Stop();
        if(!interacting)SaveEditsCore(clearMigrationReceipt);
    }

    private bool SaveEdits() => SaveEditsCore(false);

    private bool SaveEditsCore(bool clearMigrationReceipt)
    {
        editSaveTimer.Stop();
        if(editGesture!=null && interacting)return true;
        if (!editDirty || file == null) return true;
        var clearReceipt = clearMigrationReceipt || pendingMigrationReceiptClear;
        try
        {
            if (clearReceipt) CommitResetEdit(settings.Capture());
            else CommitCurrentEdit(settings.Capture());
            editGesture=null;editDirty = false;pendingMigrationReceiptClear = false;
            if (clearReceipt) ClearProcessingMigrationReceiptState();
            SetSaveNotice("调整已保存", "", false);
            return true;
        }
        catch (Exception error) {
            SetSaveNotice("调整未保存 · 重试", AdjustmentTransferPresentation.Detail(error), true);return false;
        }
    }

    // 重置全部调整经确认后显式清除该照片的处理迁移回执；随后撤销只恢复调整参数，不恢复已清除的迁移回执（回退仍保持已过期）。
    private AdjustmentOutcome CommitResetEdit(AdjustmentSnapshot snapshot)
    {
        if(file==null)throw new InvalidOperationException("No photo is open.");
        var candidate=new SavedEdit(OriginalIdentity.Read(file),snapshot,CurrentLookIdentity());
        var before=currentEditRecord ?? new PhotoEditState(candidate.Identity,null);
        SavedEdit? defaultEdit=null;
        if(before.Edit==null) {
            var defaults=PhotoInput.PrepareDefaultSettings(file);defaults.ResolveWhiteBalance(settings.AsShot);
            defaultEdit=new(candidate.Identity,defaults.Capture(),null);
        }
        var result=TransferSession.CommitEdit(before,candidate,defaultEdit,clearMigrationReceipt:true);
        if(result.Status is not (AdjustmentStatus.Applied or AdjustmentStatus.Unchanged))throw result.Error ?? new InvalidOperationException("Adjustment was not saved.");
        var previousLook=before.Edit?.Look;
        currentEditRecord=result.Saved;
        RecordRecentLook(previousLook,result.Saved?.Edit?.Look);
        if(acceptedPhotoPreviewResources is {} resources)CacheCurrentPhotoPreview(resources);
        return result;
    }

    private SavedEdit CaptureCurrentEdit() => new(OriginalIdentity.Read(file ?? throw new InvalidOperationException()),
        settings.Capture(),CurrentLookIdentity());
    private EditorResetContext CurrentResetContext() => new(lut,transformGeneration,
        transform.Active ? new(transform.Tool,transform.Geometry,transform.Lens) : null,
        transform.Active && transform.Tool==TransformTool.Geometry && GeometryEditor.HasInvalidInput);

    internal EditorResetTransaction? PrepareReset(EditorResetScope scope)
    {
        if(!ready || syncing || file==null || closing || exporting)return null;
        try { return EditorResetTransaction.Prepare(scope,file,openRevision,editRevision,CaptureCurrentEdit(),CurrentResetContext()); }
        catch(IOException) { return null; }
        catch(UnauthorizedAccessException) { return null; }
    }

    internal bool CommitReset(EditorResetTransaction prepared,long expectedRevision)
    {
        if(!ready || syncing || file==null || closing || exporting || editRevision!=expectedRevision)return false;
        SavedEdit current;
        try { current=CaptureCurrentEdit(); }
        catch(IOException) { return false; }
        catch(UnauthorizedAccessException) { return false; }
        return prepared.TryCommit(file,openRevision,editRevision,current,CurrentResetContext(),candidate=>{
            if(prepared.TargetsDraft)
            {
                transform.Update(candidate.Settings.Geometry ?? new(),candidate.Settings.Lens ?? new());
                ++transformGeneration;transformPreviewReady=false;interacting=false;
                if(transform.Tool==TransformTool.Geometry)GeometryEditor.Begin(transform.Geometry);
                RefreshCropDraft();RefreshControls();Schedule();return;
            }
            settings=candidate.Settings.Restore();
            if(EditorAdjustmentRules.ResetsAI(prepared.Scope))ResetAITask();
            // 身份未变时保留已解析的 LUT 路径及界面映射，避免把保存身份当成路径。
            if(candidate.Look!=current.Look)
            {
                lut=candidate.Look==null ? null : lookLibrary?.ResolveIdentity(candidate.Look) ?? candidate.Look;
                if(settings.Recipe is {} recipe)lut=recipe.LutPath;
                if(lut?.StartsWith("builtin:",StringComparison.Ordinal)==true)
                    lut=Path.Combine(AppContext.BaseDirectory,"LUTs",Path.GetFileName(lut[8..]));
            }
            interacting=false;
            MarkEditedCore(EditorAdjustmentRules.ClearsMigrationReceipt(prepared.Scope));RefreshControls();Schedule();
        });
    }

    internal string? CurrentLookIdentity()
    {
        if (settings.Recipe is {} recipe) return "recipe:" + recipe.Id;
        if(lut!=null && MasterRecipe.All.FirstOrDefault(r=>StringComparer.OrdinalIgnoreCase.Equals(r.LutPath,lut)) is {} independent)
            return "recipe-lut:"+independent.Id;
        if (lut != null && StringComparer.OrdinalIgnoreCase.Equals(Path.GetDirectoryName(lut), Path.Combine(AppContext.BaseDirectory, "LUTs")))
            return "builtin:" + Path.GetFileName(lut);
        return lookLibrary?.IdentityForPath(lut) ?? lut;
    }

    internal void SaveSettingsCopy(string input, AdjustmentSnapshot snapshot, string? look)
    {
        SaveSettingsCopies([input], snapshot, look);
    }

    internal void SaveSettingsCopies(IEnumerable<string> inputs, AdjustmentSnapshot snapshot, string? look)
    {
        editStore ??= new EditStore(EditStore.DefaultDirectory);
        editStore.Save(inputs, snapshot, look);
    }

    private void RestoreEdits(string input)
    {
        editStore ??= new EditStore(EditStore.DefaultDirectory);
        PhotoEditState nextRecord;
        Adjustments nextSettings;
        try
        {
            nextRecord = editStore.ReadState(input);
            // New HDR sources start in HDR mode; an existing snapshot without HDR
            // remains the legacy SDR record by construction.
            nextSettings = nextRecord.Edit?.Settings.Restore() ?? PhotoInput.PrepareDefaultSettings(input);
            if (nextRecord.Edit != null && nextSettings.IsHDREditing)
            {
                nextSettings.RequireActiveHDRDecodeVersion();
                var proRAW = PhotoInput.IsRaw(input) &&
                    PhotoInput.ProbeCameraRaw(input, out var info, nextSettings.Processing.Version) == HDRProbeState.Supported
                    ? info?.IsProRAW
                    : false;
                if (nextSettings.ProRAWDecodeVersion != null) nextSettings.RequireHDRDecodeVersion(proRAW == true);
                else if (proRAW == true) nextSettings.RequireActiveHDRDecodeVersion(true);
            }
        }
        catch (Exception error) when (error is UnusableEditRecordException or HDRModeException { Failure: HDRModeFailure.InvalidSettings })
        {
            if (!ConfirmResetUnusableRecord(input, error)) throw;
            nextRecord = TransferSession.ResetToUnmodified(input);
            nextSettings = PhotoInput.PrepareDefaultSettings(input);
        }
        try { nextRecord = TransferSession.RepairLegacyNormalX3f(nextRecord, nextSettings); }
        catch (AdjustmentOperationExpiredException)
        {
            nextRecord = editStore.ReadState(input);
            nextSettings = nextRecord.Edit?.Settings.Restore() ?? PhotoInput.PrepareDefaultSettings(input);
            nextSettings.RepairLegacyNormalX3f(input);
            TransferSession.RememberExternalSave(nextRecord);
        }
        var saved = nextRecord.Edit;
        currentEditRecord=nextRecord;processingMigrationReceipt=editStore.ReadProcessingMigration(input);editGesture=null;pendingMigrationReceiptClear=false;settings=nextSettings;
        lut = saved == null ? null : ResolveLook(saved);
        if (settings.MasterRecipeID == null && lut != null && !films.Any(f => StringComparer.OrdinalIgnoreCase.Equals(f.Path, lut)))
        {
            var managed=lookLibrary?.Looks.FirstOrDefault(look=>StringComparer.OrdinalIgnoreCase.Equals(look.Path,lut));
            films.Add(new(managed?.Name ?? lookLibrary?.DisplayName(lut,Path.GetFileNameWithoutExtension(lut)) ?? Path.GetFileNameWithoutExtension(lut), lut, null,
                AppearanceUnverified:managed?.AppearanceUnverified ?? false, CompatibilityMode:managed?.CompatibilityMode ?? 0)); BuildFilms();
        }
        editDirty = false;
        if (saved != null) SetSaveNotice("已恢复上次调整", "", false);
        else if (RetrySave.Visibility != Visibility.Visible) {SaveState.Text = "";saveNoticeKey=null;}
    }

    private bool ConfirmResetUnusableRecord(string input, Exception error)
    {
        if (confirmUnusableRecordReset != null) return confirmUnusableRecordReset(input, error);
        if (!IsLoaded || !IsVisible) return false;
        var message = Path.GetFileName(input) + "\n\n" + AdjustmentTransferPresentation.Detail(error) + "\n\n" +
            Loc.Text("恢复当前照片的全部调整，不改写原始照片。");
        var dialog = new Window {
            Title = Loc.Text("无法读取调整记录"), Owner = this, Width = 520,
            MaxHeight = Math.Max(240, ActualHeight - 80), SizeToContent = SizeToContent.Height,
            ResizeMode = ResizeMode.NoResize, ShowInTaskbar = false,
            WindowStartupLocation = WindowStartupLocation.CenterOwner
        };
        AutomationProperties.SetAutomationId(dialog, "editor.reset.unusable");
        KeyboardNavigation.SetTabNavigation(dialog, KeyboardNavigationMode.Cycle);
        var grid = new Grid { Margin = new Thickness(24) };
        grid.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new() { Height = GridLength.Auto });
        grid.Children.Add(new ScrollViewer {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap }
        });
        var actions = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0) };
        var cancel = new Button { Content = Loc.Text("取消"), IsCancel = true, IsDefault = true };
        cancel.Click += (_, _) => dialog.DialogResult = false;
        var reset = new Button { Content = Loc.Text("重置全部调整"), Margin = new Thickness(8, 0, 0, 0) };
        reset.Click += (_, _) => dialog.DialogResult = true;
        actions.Children.Add(cancel);
        actions.Children.Add(reset);
        Grid.SetRow(actions, 1);
        grid.Children.Add(actions);
        dialog.Content = grid;
        var focus = Keyboard.FocusedElement;
        var confirmed = dialog.ShowDialog() == true;
        if (focus is UIElement control && control.IsVisible) control.Focus();
        return confirmed;
    }

    private void RefreshSaveNotice(){if(saveNoticeKey!=null)SaveState.Text=Loc.Text(saveNoticeKey);}
    private void SetSaveNotice(string key, string detail, bool failed)
    {
        saveNoticeKey=key;SaveState.Text = Loc.Text(key); SaveState.ToolTip = detail;
        SaveState.SetResourceReference(System.Windows.Controls.TextBlock.ForegroundProperty,failed ? "ErrorForeground" : "Muted");
        RetrySave.Visibility = failed ? Visibility.Visible : Visibility.Collapsed;
        editNoticeTimer.Stop(); if (!failed) editNoticeTimer.Start();
    }
    private void RetrySaveClicked(object sender, RoutedEventArgs e)
    {
        try {
            if(file!=null && currentEditRecord is {} record && !OriginalIdentity.Read(file).SameFile(record.Identity)) {
                if(MessageBox.Show(this,Loc.Text("原始文件已被替换。是否放弃未保存的调整并重新打开照片？"),
                    "RawLab",MessageBoxButton.YesNo,MessageBoxImage.Question,MessageBoxResult.No)==MessageBoxResult.Yes)
                    ReloadCurrentAdjustments();
                return;
            }
        }catch(Exception error){ShowAdjustmentError(error);return;}
        if(transformSaveFailed && transform.Active) { ApplyTransformDraft(); return; }
        if (editDirty) { SaveEdits(); return; }
        try { editStore = new EditStore(EditStore.DefaultDirectory); SetSaveNotice("调整记录可用", "", false); }
        catch (Exception error) { SetSaveNotice("无法读取调整记录", AdjustmentTransferPresentation.Detail(error), true); }
    }

    private void BatchExportClicked(object sender, RoutedEventArgs e)
    {
        if (file == null || AIBlocksOutput || !exactReady || scheduler.Busy || exporting || batchWindow?.Busy==true || !LookAvailable) return;
        var previous = CurrentBatch;
        if (previous is { Started: true } && previous.SucceededCount < previous.SelectedCount)
        {
            var answer = MessageBox.Show(this, Loc.Text("继续查看上次任务，或保留已导出文件并新建任务。"),
                Loc.Text("上次批量任务尚未完成"), MessageBoxButton.YesNoCancel, MessageBoxImage.Question);
            if (answer == MessageBoxResult.Cancel) return;
            if (answer == MessageBoxResult.Yes) { ShowBatchClicked(sender, e); return; }
        }
        try
        {
            if (batchWindow != null) { batchWindow.Close();if(batchWindow?.IsVisible==true)return;batchWindow=null; }
            if (previous != null) batchJournal.Discard(previous);
            var job = BatchJob.Create(file, settings.Capture(), settings.IsHDREditing ? null : lut, LookTitle);
            job.SourceIsProRAW = hdrSource?.IsProRAW == true;
            job.SourceSupportsCameraHDR = hdrSource?.IsCameraRaw == true;
            job.AIBackend=RequestedAIBackend;job.AIDeviceID=aiPreference.DeviceID;
            batchJournal.FreezeLook(job); batchJournal.Save(job); previousBatch = job;
            ShowBatch(job);
        }
        catch (Exception error) { Report(error); }
    }

    private void ShowBatchClicked(object sender, RoutedEventArgs e)
    {
        if(CurrentBatch==null)return;
        if(CurrentBatch.Mode!=BatchJob.PerTargetFrozen && !ResolveTransformDraft())return;
        if (batchWindow != null) { batchWindow.Activate(); return; }
        if (previousBatch != null) ShowBatch(previousBatch);
    }
    private void ShowBatch(BatchJob job,bool autoStart=false)
    {
        var window = new BatchExportWindow(job, batchJournal,backend=>new RenderEngine(aiBackend:backend,
            aiDeviceID:job.AIDeviceID,aiDiagnostics:aiDiagnostics),aiDiagnostics,
            editStore is {} store ? new BatchHDRPreparation(store,ResolveLook) : null) { Owner = this, IsEnabled = !UpdateInstallationActive };
        batchWindow = window;
        window.RunCompleted += (before, after, runFailedCount) =>
        {
            var succeeded = Math.Clamp(after.SucceededCount - before.SucceededCount, 0, UsageAnalytics.MaxCount);
            var failed = Math.Clamp(runFailedCount, 0, UsageAnalytics.MaxCount);
            var outcome = after.Interrupted ? BatchOutcome.Interrupted : after.Cancelled ? BatchOutcome.Cancelled :
                failed > 0 || after.FailedCount > 0 ? BatchOutcome.Partial : BatchOutcome.Completed;
            usageAnalytics.Record(new BatchExportCompletedEvent(outcome, succeeded, failed));
        };
        window.BusyChanged += active => {
            var closeFailed=!active && closing && window.CloseFailed;
            if(closeFailed){RecoverFailedClose(window);return;}
            if(!active && !exporting && !closing)ResumePreview();
            RefreshControls(); RefreshBatchNotice();
            if(!active && closing && scheduler.Active==null)FinishClose();
        };
        window.Closed += (_, _) => {
            previousBatch = window.Discarded ? null : window.Job;
            if (batchWindow == window) batchWindow = null;
            RefreshBatchNotice(); UpdateBusy();
        };
        window.Show(); RefreshBatchNotice(); UpdateBusy();
        if(autoStart)_=window.StartExecution();
    }
    private void RecoverFailedClose(BatchExportWindow window)
    {
        closing=false;IsEnabled=true;
        if(Application.Current is App app)app.SetSystemPhotoAdmission(true);
        ResumePreview();QueueThumbnailRefresh();
        RefreshControls();RefreshBatchNotice();
        SetStatus(window.Job.Error ?? Loc.Text("任务未保存。"),true);
    }
    private void RefreshBatchNotice()
    {
        var job = CurrentBatch;
        BatchNotice.Visibility = job is { Started: true } && job.SucceededCount < job.SelectedCount ? Visibility.Visible : Visibility.Collapsed;
        ViewBatchMenu.IsEnabled = job != null;
    }
}
