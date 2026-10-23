using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
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
    private bool ready, refreshingSize, editingCustomSize,preflighting,closed;
    private volatile bool closeRequested;
    private Task? thumbnailLoading;
    public bool Running { get; private set; }
    public bool Busy=>Running || preflighting;
    public bool Discarded { get; private set; }
    public bool CloseFailed { get; private set; }
    public BatchJob Job => job;
    public event Action<bool>? BusyChanged;
    public event Action<BatchJob, BatchJob, int>? RunCompleted;

    public BatchExportWindow(BatchJob job, BatchJournal journal)
    {
        this.job = job; this.journal = journal;
        InitializeComponent(); Targets.ItemsSource = rows;
        Loc.Changed += RefreshLanguage;
        Closed += (_, _) => {closed=true;Loc.Changed -= RefreshLanguage;};
        Jpeg.IsChecked = job.Format == ExportFormat.Jpeg;
        Png.IsChecked = job.Format == ExportFormat.Png;
        Dng.IsChecked = job.Format == ExportFormat.RenderedDng;
        SourceName.Text = Path.GetFileName(job.Source); SourceName.ToolTip = job.Source;
        Loaded += async (_, _) => {
            try { var source=await Task.Run(() => RenderEngine.Thumbnail(job.Source));if(closed || closeRequested)return;SourceThumbnail.Source=source; } catch (Exception) { }
            if(closed || closeRequested)return;
            await LoadThumbnails();
        };
        Closing += (_, args) => {
            if(Running || preflighting){args.Cancel=true;closeRequested=true;if(Running)CancelExecution();return;}
            if(!job.Started && !Discarded)try{journal.Discard(job);Discarded=true;CloseFailed=false;}catch(Exception error){args.Cancel=true;CloseFailed=true;closeRequested=false;job.Error=error.Message;Refresh();_=LoadThumbnails();}
        };
        ready = true;
        RefreshLanguage();
    }

    private void RefreshLanguage()
    {
        var state = RenderEngine.PrepareInputSettings(job.Source,job.Settings.Restore());
        var raster=LibraryEntry.IsRaster(job.Source);
        var lookName = job.Look == null ? Loc.Text("中性") : job.LookName;
        SourceLook.Text = $"{lookName} · {job.Settings.Values[(int)Parameter.Strength]:0}%";
        SourceSummary.Text = Loc.Format("曝光  {0:+0.00;-0.00;0.00} EV\n白平衡  {1}\n曝光基准  {2}", state[Parameter.Exposure], raster ? Loc.Text("不适用") : state.CameraWhiteBalance ? Loc.Text("拍摄时设置") : Loc.Text("自定义"), raster ? Loc.Text("显示图像") : new[] { Loc.Text("标准显影"), Loc.Text("匹配内嵌预览"), Loc.Text("传感器基准") }[state.ExposureMode]);
        AllSettings.Text = string.Join("\n", ParameterSpec.All.Select(spec => $"{Loc.Text(spec.Title)}  {(spec.Id is Parameter.Temperature or Parameter.Tint && raster ? Loc.Text("不适用") : spec.Id is Parameter.Temperature or Parameter.Tint && state.CameraWhiteBalance ? Loc.Text("按每张照片") : state[spec.Id].ToString("F" + spec.Decimals) + spec.Unit)}"));
        AllSettings.Text += $"\nHSL  {(state.Hsl.IsIdentity ? Loc.Text("未调整") : Loc.Text("已调整"))}";
        // 降噪与镜头逐行沿用编辑器里的名称；关着的开关写"停用"
        AllSettings.Text += "\n" + string.Join("\n", new[] {
            Row("降噪", OnOff(state.Denoise.Enabled)),
            Row("亮度降噪", Number(state.Denoise.Luma)),
            Row("色彩降噪", Number(state.Denoise.Chroma)),
            Row("粗色斑抑制", Number(state.Denoise.Coarse)),
            Row("镜头匹配", Loc.Text(state.Lens.Manual ? "手动" : "自动")),
            Row("畸变矫正", OnOff(state.Lens.Distortion)),
            Row("横向色差", OnOff(state.Lens.Tca)),
            Row("自动裁边", OnOff(state.Lens.AutoCrop))
        });
        var geometry = state.Geometry;
        AllSettings.Text += "\n" + Loc.Format("几何：左边 {0:0.##}% · 顶边 {1:0.##}% · 宽度 {2:0.##}% · 高度 {3:0.##}% · 旋转 {4}° · 拉直 {5:0.##}°",
            geometry.CropX * 100, geometry.CropY * 100, geometry.CropWidth * 100, geometry.CropHeight * 100,
            geometry.QuarterTurns * 90, geometry.StraightenDegrees);
        AllSettings.Text += "\n"+Loc.Format("透视：水平 {0:0.###} · 垂直 {1:0.###}",geometry.PerspectiveHorizontal,geometry.PerspectiveVertical);
        AllSettings.Text += $"\n{Loc.Text("水平翻转")}  {OnOff(geometry.FlipHorizontal)} · {Loc.Text("垂直翻转")}  {OnOff(geometry.FlipVertical)}";
        var effects = state.Effects;
        var chroma = state.DisplayChromaDenoise switch { 1 => Loc.Text("细节优先"), 2 => Loc.Text("去噪优先"), _ => Loc.Text("停用") };
        AllSettings.Text += Loc.Format("\n显示色彩降噪  {0}\n暗角  强度 {1:+0.#;-0.#;0} · 中点 {2:0.#} · 圆度 {3:+0.#;-0.#;0} · 羽化 {4:0.#} · 高光保护 {5:0.#}\n颗粒  强度 {6:0.#} · 大小 {7:0.#} · 粗糙度 {8:0.#}", chroma, effects.VignetteAmount, effects.VignetteMidpoint, effects.VignetteRoundness, effects.VignetteFeather, effects.VignetteHighlights, effects.GrainAmount, effects.GrainSize, effects.GrainRoughness);
        Refresh();
    }

    private static string Row(string title, string value) => $"{Loc.Text(title)}  {value}";
    private static string OnOff(bool on) => Loc.Text(on ? "开启" : "停用");
    private static string Number(double value) => value.ToString("0.#", CultureInfo.GetCultureInfo(Loc.Language));

    private void Refresh()
    {
        Heading.Text = preflighting ? Loc.Text("正在检查照片…") : Running ? cancellation.IsCancellationRequested ? Loc.Text("正在停止…") : Loc.Text("正在导出") :
            job.Interrupted ? Loc.Text("导出已中断") : job.Cancelled ? Loc.Text("导出已取消") : job.Started ? Loc.Text("导出完成") : Loc.Text("批量导出");
        Summary.Text = job.Started ? Loc.Format("成功 {0} 张 · 失败 {1} 张 · 未处理 {2} 张", job.SucceededCount, job.FailedCount, job.RemainingCount) : Loc.Format("已选 {0} 张", job.SelectedCount);
        ErrorText.Text = job.Error ?? ""; ErrorText.Visibility = string.IsNullOrEmpty(job.Error) ? Visibility.Collapsed : Visibility.Visible;
        Progress.Visibility = job.Started || preflighting ? Visibility.Visible : Visibility.Collapsed;Progress.IsIndeterminate=preflighting;
        Progress.Maximum = Math.Max(1, job.SelectedCount); Progress.Value = job.SucceededCount + job.FailedCount;
        SelectionActions.Visibility = job.Started ? Visibility.Collapsed : Visibility.Visible;
        SelectionActions.IsEnabled=!preflighting;
        FormatOptions.IsEnabled = !job.Started && !Running && !preflighting; ChooseFolder.IsEnabled = !Running && !preflighting;
        SizeSelection.IsEnabled = CustomLongEdge.IsEnabled = !job.Started && !Running && !preflighting;
        RefreshSizeControls();
        Destination.Text = job.OutputDirectory == null ? Loc.Text("未选择") : Path.GetFileName(job.OutputDirectory.TrimEnd(Path.DirectorySeparatorChar));
        Destination.ToolTip = job.OutputDirectory;
        EmptyState.Visibility = job.Items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        foreach (var old in rows.Where(row => !job.Items.Any(item => item.Id == row.Item.Id)).ToArray()) rows.Remove(old);
        foreach (var item in job.Items)
        {
            var row = rows.FirstOrDefault(row => row.Item.Id == item.Id);
            if (row == null) { row = new BatchRow(item, Select); rows.Add(row); }
            row.Refresh(item, !job.Started && !preflighting, !Running && !preflighting && item.CanSelect);
        }
        CloseAction.Content = job.Started ? Loc.Text("关闭") : Loc.Text("取消"); CloseAction.IsEnabled = !Running;
        RevealFolder.Visibility = job.SucceededCount > 0 ? Visibility.Visible : Visibility.Collapsed;
        PrimaryAction.Content = Running ? cancellation.IsCancellationRequested ? Loc.Text("正在停止…") : Loc.Text("取消导出") :
            !job.Started ? Loc.Format("导出 {0} 张", job.SelectedCount) : job.RemainingCount > 0 ? Loc.Format("继续未完成的 {0} 张", job.SelectedCount - job.SucceededCount) : Loc.Format("重试失败的 {0} 张", job.FailedCount);
        PrimaryAction.Visibility = !Running && job.Started && job.SucceededCount == job.SelectedCount ? Visibility.Collapsed : Visibility.Visible;
        Footnote.Text=Running ? Loc.Text("当前项完成后停止，已完成的输出会保留。") : Loc.Text("仅用于本次导出，保留各照片原有调整");
        PrimaryAction.IsEnabled = !preflighting && (Running ? !cancellation.IsCancellationRequested : job.SelectedCount > 0 && job.OutputDirectory != null &&
            (!editingCustomSize || ExportSize.Parse(CustomLongEdge.Text) != null));
    }

    private void SaveDraft()
    {
        try { journal.Save(job); job.Error = null; }
        catch (Exception error) { job.Error = Loc.Format("任务未保存：{0}", error.Message); }
        Refresh();
    }
    private void Select(Guid id, bool selected)
    {
        if (job.Started || Running || preflighting) return;
        var index = job.Items.FindIndex(x => x.Id == id);
        if (index >= 0 && job.Items[index].CanSelect) { job.Items[index] = job.Items[index] with { Selected = selected }; SaveDraft(); }
    }
    private async void AddClicked(object sender, RoutedEventArgs e)
    {
        if (Running || job.Started || preflighting) return;
        var picker = new OpenFileDialog { Title = Loc.Text("选择待导出的照片"), Multiselect = true,
            Filter = Loc.Text("照片|") + LibraryEntry.ImageFilter };
        if (picker.ShowDialog(this) != true) return;
        await AddInputs(picker.FileNames);
    }
    internal async Task AddInputs(IEnumerable<string> inputs)
    {
        if(Running || job.Started || preflighting || closed)return;
        CloseFailed=closeRequested=false;preflighting=true;BusyChanged?.Invoke(true);Refresh();var errors=new List<string>();
        var settings=job.Settings.Copy();var look=job.Look;
        try
        {
            var checkedItems=await Task.Run(()=>{
                var accepted=new List<BatchItem>();using var validator=new RenderEngine(0,aiBackend:job.AIBackend);
                foreach(var input in inputs.Distinct(StringComparer.OrdinalIgnoreCase))
                {
                    if(closeRequested)break;
                    try{
                        var item=BatchItem.Create(input);
                        try{var effective=RenderEngine.PrepareBatchSettings(job.Source,input,settings.Restore());
                            validator.Render(input,effective,look,64,statistics:false,clipping:false,viewportPreview:true);item=item with{Selected=true};}
                        catch(Exception error){item=item with{ValidationError=error.Message,Selected=false};}
                        accepted.Add(item);
                    }
                    catch(Exception error){errors.Add(Path.GetFileName(input)+": "+error.Message);}
                }
                return accepted;
            });
            if(closed || closeRequested)return;
            foreach(var item in checkedItems){var index=job.Items.FindIndex(x=>StringComparer.OrdinalIgnoreCase.Equals(x.Input,item.Input));if(index<0)job.Items.Add(item);else job.Items[index]=item;}
            SaveDraft();if(errors.Count>0)job.Error=string.Join("\n",errors);
            await LoadThumbnails();
        }
        catch(Exception error){if(!closed)job.Error=error.Message;}
        finally{preflighting=false;if(!closed){Refresh();if(closeRequested)Close();}BusyChanged?.Invoke(false);}
    }
    private Task LoadThumbnails()
    {
        if(thumbnailLoading is { IsCompleted:false })return thumbnailLoading;
        return thumbnailLoading=ReadThumbnails();
    }
    private async Task ReadThumbnails()
    {
        var attempted=new HashSet<Guid>();
        while(!closed && !closeRequested && rows.FirstOrDefault(row=>row.Thumbnail==null && !attempted.Contains(row.Item.Id)) is {} row)
        {
            attempted.Add(row.Item.Id);
            try {
                var image=await Task.Run(() => RenderEngine.Thumbnail(row.Input));
                if(closed || closeRequested)return;
                if(rows.Contains(row))row.SetThumbnail(image);
            } catch (Exception) { }
        }
    }
    private void SelectAllClicked(object sender, RoutedEventArgs e) => SelectAll(true);
    private void SelectNoneClicked(object sender, RoutedEventArgs e) => SelectAll(false);
    private void SelectAll(bool value)
    {
        if (job.Started || Running || preflighting) return;
        job.Items = job.Items.Select(x => x with { Selected = value && x.CanSelect }).ToList(); SaveDraft();
    }
    private void RemoveClicked(object sender, RoutedEventArgs e)
    {
        if (!job.Started && !Running && sender is FrameworkElement { DataContext: BatchRow row }) { job.Items.RemoveAll(x => x.Id == row.Item.Id); SaveDraft(); }
    }
    private void FolderClicked(object sender, RoutedEventArgs e)
    {
        var picker = new OpenFolderDialog { Title = Loc.Text("选择输出文件夹") };
        if (picker.ShowDialog(this) == true) { job.OutputDirectory = picker.FolderName; SaveDraft(); }
    }
    private void FormatChanged(object sender, RoutedEventArgs e)
    {
        if (ready && !job.Started && !Running)
        {
            job.Format = Dng.IsChecked == true ? ExportFormat.RenderedDng :
                Png.IsChecked == true ? ExportFormat.Png : ExportFormat.Jpeg;
            SaveDraft();
        }
    }
    private void RefreshSizeControls()
    {
        refreshingSize=true;
        try
        {
            if (!editingCustomSize || job.Started)
            {
                var index=job.LongEdge switch { 2048 => 1, 3000 => 2, 4096 => 3, null => 0, _ => 4 };
                SizeSelection.SelectedIndex=index;
                CustomLongEdge.Text=index == 4 ? job.LongEdge?.ToString() ?? "" : "";
                editingCustomSize=index == 4;
            }
            CustomLongEdge.Visibility=editingCustomSize ? Visibility.Visible : Visibility.Collapsed;
        }
        finally { refreshingSize=false; }
    }
    private void ExportSizeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!ready || refreshingSize || job.Started || Running || SizeSelection.SelectedItem is not ComboBoxItem { Tag: string tag }) return;
        if (tag == "custom")
        {
            editingCustomSize=true;
            Refresh(); CustomLongEdge.Focus(); CustomLongEdge.SelectAll();
            return;
        }
        editingCustomSize=false;
        job.LongEdge=tag == "original" ? null : ExportSize.Parse(tag);
        SizeError.Text=""; SaveDraft();
    }
    private void CustomSizeKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) { CommitCustomSize(); e.Handled=true; }
        else if (e.Key == Key.Escape) { editingCustomSize=false; Refresh(); e.Handled=true; }
    }
    private void CustomSizeCommitted(object sender, KeyboardFocusChangedEventArgs e) { if (!refreshingSize && SizeSelection.SelectedItem is ComboBoxItem { Tag: "custom" }) CommitCustomSize(); }
    private void CustomSizeTextChanged(object sender, TextChangedEventArgs e)
    {
        if (!ready || refreshingSize || !editingCustomSize || job.Started || Running) return;
        SizeError.Text=ExportSize.Parse(CustomLongEdge.Text) == null ? Loc.Text("请输入 1 到 65535 之间的整数。") : "";
        PrimaryAction.IsEnabled=job.SelectedCount > 0 && job.OutputDirectory != null && ExportSize.Parse(CustomLongEdge.Text) != null;
    }
    private bool CommitCustomSize()
    {
        var value=ExportSize.Parse(CustomLongEdge.Text);
        if (value is null)
        {
            SizeError.Text=Loc.Text("请输入 1 到 65535 之间的整数。"); return false;
        }
        job.LongEdge=value; SizeError.Text=""; SaveDraft();
        return true;
    }
    private void CloseClicked(object sender, RoutedEventArgs e)
    {
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
        if(preflighting)return;
        if (Running) { CancelExecution(); return; }
        if (job.SelectedCount == 0 || job.OutputDirectory == null) return;
        if (!job.Started && editingCustomSize && !CommitCustomSize()) return;
        CloseFailed=closeRequested=false;Running = true; cancellation = new(); BusyChanged?.Invoke(true); Refresh();
        var before = job.Copy();
        var work = job.Copy(); var failuresOnly = job.Started && job.RemainingCount == 0;
        var runFailed = new HashSet<Guid>();
        var previousStatuses = work.Items.ToDictionary(item => item.Id, item => item.Status);
        try
        {
            await Task.Run(() => {
                if (work.Format != ExportFormat.RenderedDng) ExportMetadata.VerifyAvailable();
                using var engine = new RenderEngine(aiBackend:work.AIBackend);
                BatchRunner.Run(work, journal, failuresOnly, cancellation.Token,
                    (updated, _) => {
                        foreach (var item in updated.Items)
                        {
                            if (item.Status == BatchStatus.Failed && previousStatuses.TryGetValue(item.Id, out var previous) && previous != BatchStatus.Failed)
                                runFailed.Add(item.Id);
                            previousStatuses[item.Id] = item.Status;
                        }
                        Dispatcher.BeginInvoke(new Action(() => { job = updated; Refresh(); }));
                    },
                    (input, settings, look, destination, longEdge) => {
                        engine.Render(input, settings, look, 32, statistics: false, clipping: false);
                        engine.Render(input, settings, look, 0, output: destination, longEdge: longEdge);
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
            job = work;
            RunCompleted?.Invoke(before, job.Copy(), runFailed.Count);
            Running = false; Refresh(); BusyChanged?.Invoke(false);
            if (closeRequested && IsLoaded) Close();
        }
    }

    private async void InspectClicked(object sender, RoutedEventArgs e)
    {
        if (Running || sender is not FrameworkElement { DataContext: BatchRow row }) return;
        var title = new TextBlock { Text = Loc.Text("正在生成本次导出效果…"), Margin = new Thickness(16) };
        var image = new Image { Stretch = Stretch.Uniform, Margin = new Thickness(16) };
        var panel = new DockPanel(); DockPanel.SetDock(title, Dock.Top); panel.Children.Add(title); panel.Children.Add(image);
        var preview = new Window { Title = Loc.Format("{0} · 本次导出效果", row.Name), Owner = this, Width = 820, Height = 620, Content = panel };
        preview.Show();
        var snapshot = job.Copy();
        try
        {
            var frame = await Task.Run(() => {
                if (!row.Item.Identity.SameFile(OriginalIdentity.Read(row.Input))) throw new InvalidOperationException(Loc.Text("原始文件已被替换，请重新选择照片。"));
                if (snapshot.Look != null && !File.Exists(snapshot.Look)) throw new InvalidOperationException(Loc.Text("任务使用的外观文件不可用，请重新创建任务。"));
                using var engine = new RenderEngine(aiBackend:snapshot.AIBackend);
                var settings=RenderEngine.PrepareBatchSettings(snapshot.Source,row.Input,snapshot.Settings.Restore());
                return engine.Render(row.Input, settings, snapshot.Look, 1600, statistics: false, clipping: false);
            });
            if (preview.IsVisible) { image.Source = frame?.Image; title.Text = Loc.Format("{0} · 本次导出效果", snapshot.LookName); }
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
    public bool Selectable=>Editable && Item.CanSelect;
    public bool CanInspect { get; private set; }
    public BitmapSource? Thumbnail { get; private set; }
    public string Name => Path.GetFileName(Item.Input);
    public string Input => Item.Input;
    public bool Selected { get => Item.Selected && Item.CanSelect; set { if (Selectable && value != Selected) select(Item.Id, value); } }
    public string Detail => Item.ValidationError!=null ? Loc.Text("验证失败")+"\n"+Item.ValidationError : Editable ? Path.GetDirectoryName(Input)! : Item.StatusText + (Item.Error == null ? "" : "\n" + Item.Error);
    public bool HasError => Item.ValidationError!=null || Item.Status == BatchStatus.Failed;
    public Visibility EditVisibility => Editable ? Visibility.Visible : Visibility.Collapsed;
    public Visibility OutputVisibility => Item.Status == BatchStatus.Succeeded ? Visibility.Visible : Visibility.Collapsed;
    public BatchRow(BatchItem item, Action<Guid, bool> select) { Item = item; this.select = select; }
    public void Refresh(BatchItem item, bool editable, bool canInspect) { Item = item; Editable = editable; CanInspect = canInspect; PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null)); }
    public void SetThumbnail(BitmapSource? image) { Thumbnail = image; PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Thumbnail))); }
}
