using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

namespace RawLab.Windows;

public partial class BatchExportWindow : Window
{
    private BatchJob job;
    private readonly BatchJournal journal;
    private readonly ObservableCollection<BatchRow> rows = [];
    private CancellationTokenSource cancellation = new();
    private bool ready, closeRequested;
    public bool Running { get; private set; }
    public bool Discarded { get; private set; }
    public BatchJob Job => job;
    public event Action<bool>? RunningChanged;

    public BatchExportWindow(BatchJob job, BatchJournal journal)
    {
        this.job = job; this.journal = journal;
        InitializeComponent(); Targets.ItemsSource = rows;
        Jpeg.IsChecked = !job.Png; Png.IsChecked = job.Png;
        SourceName.Text = Path.GetFileName(job.Source); SourceName.ToolTip = job.Source;
        SourceLook.Text = $"{job.LookName} · {job.Settings.Values[(int)Parameter.Strength]:0}%";
        var state = job.Settings.Restore();
        SourceSummary.Text = $"曝光  {state[Parameter.Exposure]:+0.00;-0.00;0.00} EV\n白平衡  {(state.CameraWhiteBalance ? "拍摄时设置" : "自定义")}\n曝光基准  {new[] { "标准显影", "匹配内嵌预览", "传感器基准" }[state.ExposureMode]}";
        AllSettings.Text = string.Join("\n", ParameterSpec.All.Select(spec => $"{spec.Title}  {(spec.Id is Parameter.Temperature or Parameter.Tint && state.CameraWhiteBalance ? "按每张照片" : state[spec.Id].ToString("F" + spec.Decimals) + spec.Unit)}"));
        ready = true; Refresh();
        AllSettings.Text += $"\n降噪  {(state.Denoise.Enabled ? "开启" : "关闭")}\n亮度降噪  {state.Denoise.Luma:F0}\n色彩降噪  {state.Denoise.Chroma:F0}\n粗颗粒降噪  {state.Denoise.Coarse:F0}";
        Loaded += async (_, _) => {
            try { SourceThumbnail.Source = await Task.Run(() => RenderEngine.Thumbnail(job.Source)); } catch (Exception) { }
            await LoadThumbnails();
        };
        Closing += (_, args) => { if (Running) { args.Cancel = true; closeRequested = true; CancelExecution(); } };
    }

    private void Refresh()
    {
        Heading.Text = Running ? cancellation.IsCancellationRequested ? "正在停止…" : "正在导出" :
            job.Interrupted ? "导出已中断" : job.Cancelled ? "导出已取消" : job.Started ? "导出完成" : "批量导出";
        Summary.Text = job.Started ? $"成功 {job.SucceededCount} 张 · 失败 {job.FailedCount} 张 · 未处理 {job.RemainingCount} 张" : $"已选 {job.SelectedCount} 张";
        ErrorText.Text = job.Error ?? ""; ErrorText.Visibility = string.IsNullOrEmpty(job.Error) ? Visibility.Collapsed : Visibility.Visible;
        Progress.Visibility = job.Started ? Visibility.Visible : Visibility.Collapsed;
        Progress.Maximum = Math.Max(1, job.SelectedCount); Progress.Value = job.SucceededCount + job.FailedCount;
        SelectionActions.Visibility = job.Started ? Visibility.Collapsed : Visibility.Visible;
        FormatOptions.IsEnabled = !job.Started && !Running; ChooseFolder.IsEnabled = !Running;
        Destination.Text = job.OutputDirectory == null ? "未选择" : Path.GetFileName(job.OutputDirectory.TrimEnd(Path.DirectorySeparatorChar));
        Destination.ToolTip = job.OutputDirectory;
        EmptyState.Visibility = job.Items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        foreach (var old in rows.Where(row => !job.Items.Any(item => item.Id == row.Item.Id)).ToArray()) rows.Remove(old);
        foreach (var item in job.Items)
        {
            var row = rows.FirstOrDefault(row => row.Item.Id == item.Id);
            if (row == null) { row = new BatchRow(item, Select); rows.Add(row); }
            row.Refresh(item, !job.Started, !Running);
        }
        CloseAction.Content = job.Started ? "关闭" : "取消"; CloseAction.IsEnabled = !Running;
        RevealFolder.Visibility = job.SucceededCount > 0 ? Visibility.Visible : Visibility.Collapsed;
        PrimaryAction.Content = Running ? cancellation.IsCancellationRequested ? "正在停止…" : "取消导出" :
            !job.Started ? $"导出 {job.SelectedCount} 张" : job.RemainingCount > 0 ? $"继续未完成的 {job.SelectedCount - job.SucceededCount} 张" : $"重试失败的 {job.FailedCount} 张";
        PrimaryAction.Visibility = !Running && job.Started && job.SucceededCount == job.SelectedCount ? Visibility.Collapsed : Visibility.Visible;
        PrimaryAction.IsEnabled = Running ? !cancellation.IsCancellationRequested : job.SelectedCount > 0 && job.OutputDirectory != null;
    }

    private void SaveDraft()
    {
        try { journal.Save(job); job.Error = null; }
        catch (Exception error) { job.Error = "任务未保存：" + error.Message; }
        Refresh();
    }
    private void Select(Guid id, bool selected)
    {
        if (job.Started || Running) return;
        var index = job.Items.FindIndex(x => x.Id == id);
        if (index >= 0) { job.Items[index] = job.Items[index] with { Selected = selected }; SaveDraft(); }
    }
    private async void AddClicked(object sender, RoutedEventArgs e)
    {
        if (Running || job.Started) return;
        var picker = new OpenFileDialog { Title = "选择待导出的 RAW 照片", Multiselect = true,
            Filter = "RAW 照片|" + string.Join(';', LibraryEntry.RawExtensions.Select(x => "*." + x)) };
        if (picker.ShowDialog(this) != true) return;
        var errors = new List<string>();
        foreach (var input in picker.FileNames)
        {
            try
            {
                var item = BatchItem.Create(input) with { Selected = true };
                var existing = job.Items.FindIndex(x => StringComparer.OrdinalIgnoreCase.Equals(x.Input, item.Input));
                if (existing < 0) job.Items.Add(item); else job.Items[existing] = job.Items[existing] with { Selected = true };
            }
            catch (Exception error) { errors.Add(Path.GetFileName(input) + "：" + error.Message); }
        }
        SaveDraft();
        if (errors.Count > 0) { job.Error = string.Join("\n", errors); Refresh(); }
        await LoadThumbnails();
    }
    private async Task LoadThumbnails()
    {
        foreach (var row in rows.Where(row => row.Thumbnail == null).ToArray())
        {
            try { row.SetThumbnail(await Task.Run(() => RenderEngine.Thumbnail(row.Input))); } catch (Exception) { }
        }
    }
    private void SelectAllClicked(object sender, RoutedEventArgs e) => SelectAll(true);
    private void SelectNoneClicked(object sender, RoutedEventArgs e) => SelectAll(false);
    private void SelectAll(bool value)
    {
        if (job.Started || Running) return;
        job.Items = job.Items.Select(x => x with { Selected = value }).ToList(); SaveDraft();
    }
    private void RemoveClicked(object sender, RoutedEventArgs e)
    {
        if (!job.Started && !Running && sender is FrameworkElement { DataContext: BatchRow row }) { job.Items.RemoveAll(x => x.Id == row.Item.Id); SaveDraft(); }
    }
    private void FolderClicked(object sender, RoutedEventArgs e)
    {
        var picker = new OpenFolderDialog { Title = "选择输出文件夹" };
        if (picker.ShowDialog(this) == true) { job.OutputDirectory = picker.FolderName; SaveDraft(); }
    }
    private void FormatChanged(object sender, RoutedEventArgs e) { if (ready && !job.Started && !Running) { job.Png = Png.IsChecked == true; SaveDraft(); } }
    private void CloseClicked(object sender, RoutedEventArgs e)
    {
        if (!job.Started && !Running)
        {
            try { journal.Discard(job); Discarded = true; }
            catch (Exception error) { job.Error = error.Message; Refresh(); return; }
        }
        Close();
    }
    private void RevealFolderClicked(object sender, RoutedEventArgs e) { if (job.OutputDirectory != null) Process.Start(new ProcessStartInfo(job.OutputDirectory) { UseShellExecute = true }); }
    private void RevealClicked(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: BatchRow { Item.Output: {} path } })
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
    }
    public void CancelExecution() { cancellation.Cancel(); Refresh(); }
    private async void PrimaryClicked(object sender, RoutedEventArgs e)
    {
        if (Running) { CancelExecution(); return; }
        if (job.SelectedCount == 0 || job.OutputDirectory == null) return;
        Running = true; cancellation = new(); RunningChanged?.Invoke(true); Refresh();
        var work = job.Copy(); var failuresOnly = job.Started && job.RemainingCount == 0;
        try
        {
            await Task.Run(() => {
                ExportMetadata.VerifyAvailable();
                using var engine = new RenderEngine();
                BatchRunner.Run(work, journal, failuresOnly, cancellation.Token,
                    (updated, _) => Dispatcher.BeginInvoke(new Action(() => { job = updated; Refresh(); })),
                    (input, settings, look, destination) => {
                        engine.Render(input, settings, look, 32, statistics: false, clipping: false);
                        engine.Render(input, settings, look, 0, output: destination);
                    });
            });
        }
        catch (Exception error)
        {
            work.Error = error.Message; work.Interrupted = true;
            try { journal.Save(work); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
        finally
        {
            job = work; Running = false; Refresh(); RunningChanged?.Invoke(false);
            if (closeRequested && IsLoaded) Close();
        }
    }

    private async void InspectClicked(object sender, RoutedEventArgs e)
    {
        if (Running || sender is not FrameworkElement { DataContext: BatchRow row }) return;
        var title = new TextBlock { Text = "正在生成本次导出效果…", Margin = new Thickness(16) };
        var image = new Image { Stretch = Stretch.Uniform, Margin = new Thickness(16) };
        var panel = new DockPanel(); DockPanel.SetDock(title, Dock.Top); panel.Children.Add(title); panel.Children.Add(image);
        var preview = new Window { Title = row.Name + " · 本次导出效果", Owner = this, Width = 820, Height = 620, Content = panel };
        preview.Show();
        var snapshot = job.Copy();
        try
        {
            var frame = await Task.Run(() => {
                if (!row.Item.Identity.SameFile(OriginalIdentity.Read(row.Input))) throw new InvalidOperationException("原始文件已被替换。");
                if (snapshot.Look != null && !File.Exists(snapshot.Look)) throw new InvalidOperationException("任务外观不可用。");
                using var engine = new RenderEngine();
                return engine.Render(row.Input, snapshot.Settings.Restore(), snapshot.Look, 1600, statistics: false, clipping: false);
            });
            if (preview.IsVisible) { image.Source = frame?.Image; title.Text = snapshot.LookName + " · 本次导出效果"; }
        }
        catch (Exception error) { if (preview.IsVisible) title.Text = error.Message; }
    }
}

public sealed class BatchRow : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    private readonly Action<Guid, bool> select;
    public BatchItem Item { get; private set; }
    public bool Editable { get; private set; }
    public bool CanInspect { get; private set; }
    public BitmapSource? Thumbnail { get; private set; }
    public string Name => Path.GetFileName(Item.Input);
    public string Input => Item.Input;
    public bool Selected { get => Item.Selected; set { if (value != Selected) select(Item.Id, value); } }
    public string Detail => Editable ? Path.GetDirectoryName(Input)! : Item.StatusText + (Item.Error == null ? "" : "\n" + Item.Error);
    public Brush DetailColor => Item.Status == BatchStatus.Failed ? Brushes.LightSalmon : Brushes.LightGray;
    public Visibility EditVisibility => Editable ? Visibility.Visible : Visibility.Collapsed;
    public Visibility OutputVisibility => Item.Status == BatchStatus.Succeeded ? Visibility.Visible : Visibility.Collapsed;
    public BatchRow(BatchItem item, Action<Guid, bool> select) { Item = item; this.select = select; }
    public void Refresh(BatchItem item, bool editable, bool canInspect) { Item = item; Editable = editable; CanInspect = canInspect; PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null)); }
    public void SetThumbnail(BitmapSource? image) { Thumbnail = image; PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Thumbnail))); }
}
