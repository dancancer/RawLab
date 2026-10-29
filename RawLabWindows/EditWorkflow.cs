using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;

namespace RawLab.Windows;

public partial class MainWindow
{
    private EditStore? editStore;
    private bool editDirty;
    private bool updateJournalLoadFailed;
    private string? saveNoticeKey;
    private readonly DispatcherTimer editSaveTimer = new() { Interval = TimeSpan.FromMilliseconds(400) };
    private readonly DispatcherTimer editNoticeTimer = new() { Interval = TimeSpan.FromSeconds(3) };
    private readonly BatchJournal batchJournal = new(BatchJournal.DefaultDirectory);
    private BatchJob? previousBatch;
    private BatchExportWindow? batchWindow;
    private bool LookAvailable => lut == null || File.Exists(lut);
    private BatchJob? CurrentBatch => batchWindow?.Job ?? previousBatch;

    private void InitializeEditWorkflow()
    {
        editSaveTimer.Tick += (_, _) => { editSaveTimer.Stop(); SaveEdits(); };
        editNoticeTimer.Tick += (_, _) => { editNoticeTimer.Stop(); if (RetrySave.Visibility != Visibility.Visible && !adjustmentReloadRequired) {SaveState.Text = "";saveNoticeKey=null;} };
        Deactivated += (_, _) => {
            if(preservingUpdateNavigation)return;
            // 浏览预设不结束参数输入；其他窗口失活仍按原规则取消半输入。
            if(!OwnedWindows.OfType<AdjustmentPresetLibraryDialog>().Any(window=>window.IsVisible))CancelParameterInputs();
            CancelEditGesture();SaveEdits();
        };
        try { editStore = new EditStore(EditStore.DefaultDirectory); }
        catch (Exception error) { SetSaveNotice("无法读取调整记录", error.Message, true); }
        try { previousBatch = batchJournal.Load(); }
        catch (Exception error) { updateJournalLoadFailed=true;Report(new IOException(Loc.Format("无法读取上次批量任务：{0}", error.Message), error)); }
        RefreshBatchNotice(); UpdateBusy();
        InitializeAdjustmentHistory();
    }

    private void MarkEdited()
    {
        ++editRevision;
        if (!ready || syncing || file == null) return;
        editDirty = true;
        if (RetrySave.Visibility != Visibility.Visible) {SaveState.Text = "";saveNoticeKey=null;}
        editSaveTimer.Stop();
        if(!interacting)SaveEdits();
    }

    private bool SaveEdits()
    {
        editSaveTimer.Stop();
        if(editGesture!=null && interacting)return true;
        if (!editDirty || file == null) return true;
        try
        {
            CommitCurrentEdit(settings.Capture());
            editGesture=null;editDirty = false; SetSaveNotice("调整已保存", "", false);
            return true;
        }
        catch (Exception error) {
            if(error is EditPersistenceConflict){adjustmentReloadRequired=true;RefreshControls();}
            SetSaveNotice(adjustmentReloadRequired ? "照片或调整已变化，请重新打开后重试。" : "调整未保存 · 重试", error.Message, true);return false;
        }
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
            if(ResetsAI(prepared.Scope))ResetAITask();
            // 身份未变时保留已解析的 LUT 路径及界面映射，避免把保存身份当成路径。
            if(candidate.Look!=current.Look)
            {
                lut=candidate.Look==null ? null : lookLibrary?.ResolveIdentity(candidate.Look) ?? candidate.Look;
                if(settings.Recipe is {} recipe)lut=recipe.LutPath;
                if(lut?.StartsWith("builtin:",StringComparison.Ordinal)==true)
                    lut=Path.Combine(AppContext.BaseDirectory,"LUTs",Path.GetFileName(lut[8..]));
            }
            MarkEdited();RefreshControls();Schedule();
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
        currentEditRecord=editStore.VersionedState(input);editGesture=null;adjustmentReloadRequired=false;
        var saved = currentEditRecord.Edit;
        settings = saved?.Settings.Restore() ?? new Adjustments();
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

    private void RefreshSaveNotice(){if(saveNoticeKey!=null)SaveState.Text=Loc.Text(saveNoticeKey);}
    private void SetSaveNotice(string key, string detail, bool failed)
    {
        saveNoticeKey=key;SaveState.Text = Loc.Text(key); SaveState.ToolTip = detail;
        SaveState.SetResourceReference(System.Windows.Controls.TextBlock.ForegroundProperty,failed ? "ErrorForeground" : "Muted");
        RetrySave.Visibility = failed && !adjustmentReloadRequired ? Visibility.Visible : Visibility.Collapsed;
        editNoticeTimer.Stop(); if (!failed) editNoticeTimer.Start();
    }
    private void RetrySaveClicked(object sender, RoutedEventArgs e)
    {
        if(transformSaveFailed && transform.Active) { ApplyTransformDraft(); return; }
        if (editDirty) { SaveEdits(); return; }
        try { editStore = new EditStore(EditStore.DefaultDirectory); SetSaveNotice("调整记录可用", "", false); }
        catch (Exception error) { SetSaveNotice("无法读取调整记录", error.Message, true); }
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
            var job = BatchJob.Create(file, settings.Capture(), lut, LookTitle);
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
    private void ShowBatch(BatchJob job)
    {
        var window = new BatchExportWindow(job, batchJournal,backend=>new RenderEngine(aiBackend:backend,
            aiDeviceID:job.AIDeviceID,aiDiagnostics:aiDiagnostics),aiDiagnostics) { Owner = this, IsEnabled = !UpdateInstallationActive };
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
    }
    private void RecoverFailedClose(BatchExportWindow window)
    {
        closing=false;IsEnabled=true;
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
