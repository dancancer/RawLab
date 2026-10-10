using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;

namespace RawLab.Windows;

public partial class MainWindow
{
    private EditStore? editStore;
    private bool editDirty;
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
        editNoticeTimer.Tick += (_, _) => { editNoticeTimer.Stop(); if (RetrySave.Visibility != Visibility.Visible) SaveState.Text = ""; };
        Deactivated += (_, _) => SaveEdits();
        try { editStore = new EditStore(EditStore.DefaultDirectory); }
        catch (Exception error) { SetSaveNotice("无法读取调整记录", error.Message, true); }
        try { previousBatch = batchJournal.Load(); }
        catch (Exception error) { Report(new IOException("无法读取上次批量任务：" + error.Message, error)); }
        RefreshBatchNotice(); UpdateBusy();
    }

    private void MarkEdited()
    {
        if (!ready || syncing || file == null) return;
        editDirty = true;
        if (RetrySave.Visibility != Visibility.Visible) SaveState.Text = "";
        editSaveTimer.Stop(); editSaveTimer.Start();
    }

    private bool SaveEdits()
    {
        editSaveTimer.Stop();
        if (!editDirty || file == null) return true;
        try
        {
            editStore ??= new EditStore(EditStore.DefaultDirectory);
            editStore.Save(file, settings.Capture(), CurrentLookIdentity());
            editDirty = false; SetSaveNotice("调整已保存", "", false);
            return true;
        }
        catch (Exception error) { SetSaveNotice("调整未保存", error.Message, true); return false; }
    }

    internal string? CurrentLookIdentity()
    {
        if (lut != null && StringComparer.OrdinalIgnoreCase.Equals(Path.GetDirectoryName(lut), Path.Combine(AppContext.BaseDirectory, "LUTs")))
            return "builtin:" + Path.GetFileName(lut);
        return lut;
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
        var saved = editStore?.Find(input);
        settings = saved?.Settings.Restore() ?? new Adjustments();
        lut = saved == null ? films.FirstOrDefault(f => f.Name == "PROVIA")?.Path : saved.Look;
        if (lut?.StartsWith("builtin:", StringComparison.Ordinal) == true)
            lut = Path.Combine(AppContext.BaseDirectory, "LUTs", Path.GetFileName(lut[8..]));
        if (lut != null && !films.Any(f => StringComparer.OrdinalIgnoreCase.Equals(f.Path, lut)))
        {
            films.Add(new(Path.GetFileNameWithoutExtension(lut), lut, null)); BuildFilms();
        }
        editDirty = false;
        if (saved != null) SetSaveNotice("已恢复上次调整", "", false);
        else if (RetrySave.Visibility != Visibility.Visible) SaveState.Text = "";
    }

    private void SetSaveNotice(string text, string detail, bool failed)
    {
        SaveState.Text = text; SaveState.ToolTip = detail;
        SaveState.Foreground = failed ? Brushes.LightSalmon : (Brush)FindResource("Muted");
        RetrySave.Visibility = failed ? Visibility.Visible : Visibility.Collapsed;
        editNoticeTimer.Stop(); if (!failed) editNoticeTimer.Start();
    }
    private void RetrySaveClicked(object sender, RoutedEventArgs e)
    {
        if (editDirty) { SaveEdits(); return; }
        try { editStore = new EditStore(EditStore.DefaultDirectory); SetSaveNotice("调整记录可用", "", false); }
        catch (Exception error) { SetSaveNotice("无法读取调整记录", error.Message, true); }
    }

    private void BatchExportClicked(object sender, RoutedEventArgs e)
    {
        if (file == null || !exactReady || scheduler.Busy || exporting || !LookAvailable) return;
        var previous = CurrentBatch;
        if (previous is { Started: true } && previous.SucceededCount < previous.SelectedCount)
        {
            var answer = MessageBox.Show(this, "继续查看上次未完成的任务吗？选择“否”会新建任务，已导出的文件会保留。",
                "上次批量任务尚未完成", MessageBoxButton.YesNoCancel, MessageBoxImage.Question);
            if (answer == MessageBoxResult.Cancel) return;
            if (answer == MessageBoxResult.Yes) { ShowBatchClicked(sender, e); return; }
        }
        try
        {
            if (batchWindow != null) { batchWindow.Close(); batchWindow = null; }
            if (previous != null) batchJournal.Discard(previous);
            var job = BatchJob.Create(file, settings.Capture(), lut, films.FirstOrDefault(f => f.Path == lut)?.Name ?? "中性");
            batchJournal.FreezeLook(job); batchJournal.Save(job); previousBatch = job;
            ShowBatch(job);
        }
        catch (Exception error) { Report(error); }
    }

    private void ShowBatchClicked(object sender, RoutedEventArgs e)
    {
        if (batchWindow != null) { batchWindow.Activate(); return; }
        if (previousBatch != null) ShowBatch(previousBatch);
    }
    private void ShowBatch(BatchJob job)
    {
        var window = new BatchExportWindow(job, batchJournal) { Owner = this };
        batchWindow = window;
        window.RunningChanged += active => {
            exporting = active; RefreshControls(); RefreshBatchNotice();
            if (!active && closing && !scheduler.Busy) FinishClose();
        };
        window.Closed += (_, _) => {
            previousBatch = window.Discarded ? null : window.Job;
            if (batchWindow == window) batchWindow = null;
            RefreshBatchNotice(); UpdateBusy();
        };
        window.Show(); RefreshBatchNotice(); UpdateBusy();
    }
    private void RefreshBatchNotice()
    {
        var job = CurrentBatch;
        BatchNotice.Visibility = job is { Started: true } && job.SucceededCount < job.SelectedCount ? Visibility.Visible : Visibility.Collapsed;
        ViewBatchMenu.IsEnabled = job != null;
    }
}
