using Microsoft.Win32;
using System.IO;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation;
using System.Windows.Media;

namespace RawLab.Windows;

internal sealed class LUTCompatibilityDialog : Window
{
    internal LUTCompatibility Draft { get; private set; }
    private readonly LUTCompatibility original;
    private readonly string lookPath;
    private readonly LUTPreviewService service = new();
    private readonly Dictionary<string, LUTPreviewFrame> frames = new();
    private readonly Dictionary<string, (Button Button, Image Image)> thumbnails = new();
    private readonly StackPanel fields = new(), advancedFields = new(), referenceFields = new();
    private readonly WrapPanel candidates = new();
    private readonly Image before = new() { Height = 200, Stretch = Stretch.Uniform }, after = new() { Height = 200, Stretch = Stretch.Uniform };
    private readonly TextBlock beforeLabel = AdjustmentDialogLayout.Text(Loc.Text("未应用 LUT"));
    private readonly TextBlock sourceLabel = AdjustmentDialogLayout.Text(""), conditionsLabel = AdjustmentDialogLayout.Text("");
    private readonly TextBlock notice = AdjustmentDialogLayout.Text(""), referenceName = AdjustmentDialogLayout.Text(""), comparison = AdjustmentDialogLayout.Text("");
    private readonly TextBlock assumptions = AdjustmentDialogLayout.Text("");
    private readonly Button confirm, compare, more;
    private readonly LUTReferenceConditions referenceConditions = new();
    private readonly List<CheckBox> referenceChecks = new();
    private readonly TextBox referenceNotes = new() { MinHeight = 54, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap };
    private LUTPreviewFrame? baseline, reference;
    private bool displayInput, showAll, closed;
    private string? source;
    private CancellationTokenSource sourceWork = new(), selectionWork = new(), referenceWork = new(), comparisonWork = new();

    internal LUTCompatibilityDialog(Window owner, string path, LUTCompatibility draft, string? photo, IReadOnlyList<string> photoFolders)
    {
        original = draft; Draft = LUTCompatibility.Parse(draft.SnapshotJSON())!; lookPath = path;
        var root = AdjustmentDialogLayout.Configure(this, owner, "兼容导入", "look.compatibility");
        Width = 920; Height = 820; MinWidth = 560;
        var heading = new StackPanel(); heading.Children.Add(AdjustmentDialogLayout.Text(Path.GetFileName(path)));
        heading.Children.Add(Text("先比较候选效果，再选择导入。候选包含推测，不能证明已还原作者效果。")); root.Children.Add(heading);
        var scroll = new ScrollViewer { Content = fields, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Grid.SetRow(scroll, 1); root.Children.Add(scroll);
        var choosePhoto = AdjustmentDialogLayout.Button("从照片库选择", "look.compatibility.photo", () => {
            var picker = new LUTPhotoLibraryPicker(this, photoFolders);
            if (picker.ShowDialog() == true && picker.SelectedPhoto is string selected) _ = LoadPhoto(selected);
        });
        fields.Children.Add(choosePhoto); fields.Children.Add(sourceLabel); fields.Children.Add(conditionsLabel); fields.Children.Add(notice);
        fields.Children.Add(Text("候选效果")); fields.Children.Add(Text("排列顺序不代表准确度。未识别的颜色空间、范围和基础图像仍属于假设。"));
        if (draft.FixedContract) fields.Children.Add(Text("文件已有完整颜色参数，仅缺少参考依据；这些参数将原样保留。"));
        fields.Children.Add(candidates);
        more = AdjustmentDialogLayout.Button("查看其他方案（包括 Log 输入）", "look.compatibility.more", () => { showAll = !showAll; BuildCandidates(); });
        fields.Children.Add(more); fields.Children.Add(assumptions);
        var images = new Grid { Margin = new Thickness(0, 12, 0, 16) };
        images.ColumnDefinitions.Add(new()); images.ColumnDefinitions.Add(new());
        var left = new StackPanel { Margin = new Thickness(0, 0, 8, 0) }; left.Children.Add(beforeLabel); left.Children.Add(before);
        var right = new StackPanel { Margin = new Thickness(8, 0, 0, 0) }; right.Children.Add(Text("所选方案")); right.Children.Add(after); Grid.SetColumn(right, 1);
        images.Children.Add(left); images.Children.Add(right); fields.Children.Add(images);
        var referenceSection = new Expander { Header = Loc.Text("对照参考图（可选）"), Content = referenceFields, Margin = new Thickness(0, 0, 0, 16) };
        AutomationProperties.SetAutomationId(referenceSection, "look.compatibility.reference-section"); fields.Children.Add(referenceSection);
        referenceFields.Children.Add(AdjustmentDialogLayout.Button("选择参考图", "look.compatibility.reference", () => {
            var picker = new OpenFileDialog { Title = Loc.Text("选择参考图"), Filter = Loc.Text("照片|") + "*.jpg;*.jpeg;*.png;*.tif;*.tiff" };
            if (picker.ShowDialog(this) == true) _ = LoadReference(picker.FileName);
        }));
        referenceFields.Children.Add(referenceName); referenceFields.Children.Add(Text("可先目视比较。计算差异前，请核对以下条件；结果只描述此预览与参考的接近程度，不认证作者效果。"));
        AddReferenceCheck("参考图来自同一张原图", value => referenceConditions.SameSource = value);
        AddReferenceCheck("方向、裁切和构图一致", value => referenceConditions.SameGeometry = value);
        AddReferenceCheck("基础显影、白平衡、曝光和 LUT 强度与上述预览条件一致", value => referenceConditions.SameProcessing = value);
        AddReferenceCheck("参考输出为 sRGB，或已按正确配置转换为 sRGB", value => referenceConditions.KnownSRGB = value);
        referenceFields.Children.Add(Text("参考来源、软件版本及处理条件")); referenceFields.Children.Add(referenceNotes);
        AutomationProperties.SetAutomationId(referenceNotes, "look.compatibility.reference-notes");
        compare = AdjustmentDialogLayout.Button("计算与参考的差异", "look.compatibility.compare", () => _ = Compare());
        referenceNotes.TextChanged += (_, _) => { referenceConditions.ReferenceSource = referenceNotes.Text; ClearComparison(); Update(); };
        referenceFields.Children.Add(compare); referenceFields.Children.Add(comparison);
        var advanced = new Expander { Header = Loc.Text("高级颜色设置"), Content = advancedFields, Margin = new Thickness(0, 0, 0, 12) };
        AutomationProperties.SetAutomationId(advanced, "look.compatibility.advanced"); fields.Children.Add(advanced);
        if (draft.ExtremeValues) {
            var extreme = new CheckBox { Content = Text("文件含极端数值，我理解可能出现截断或异常颜色。") };
            extreme.Checked += (_, _) => { Draft.ConfirmedExtremeValues = true; Update(); };
            extreme.Unchecked += (_, _) => { Draft.ConfirmedExtremeValues = false; Update(); }; fields.Children.Add(extreme);
        }
        var actions = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0) };
        var cancel = AdjustmentDialogLayout.Button("取消", "look.compatibility.cancel", Close); cancel.IsCancel = true; actions.Children.Add(cancel);
        confirm = AdjustmentDialogLayout.Button("确认兼容导入", "look.compatibility.confirm", () => DialogResult = true); confirm.IsDefault = true; actions.Children.Add(confirm);
        Grid.SetRow(actions, 2); root.Children.Add(actions);
        BuildAdvanced(); BuildCandidates(); Update();
        Loaded += (_, _) => { if (photo != null) _ = LoadPhoto(photo); };
        Closed += (_, _) => { closed = true; sourceWork.Cancel(); selectionWork.Cancel(); referenceWork.Cancel(); comparisonWork.Cancel(); service.Dispose(); };
    }
    private static TextBlock Text(string key) => AdjustmentDialogLayout.Text(Loc.Text(key));
    private void AddReferenceCheck(string label, Action<bool> set)
    {
        var check = new CheckBox { Content = Text(label), Margin = new Thickness(0, 4, 0, 4) };
        check.Checked += (_, _) => { set(true); ClearComparison(); if (compare != null) Update(); };
        check.Unchecked += (_, _) => { set(false); ClearComparison(); if (compare != null) Update(); };
        referenceChecks.Add(check); referenceFields.Children.Add(check);
    }
    private void ResetConditions() { foreach (var check in referenceChecks) check.IsChecked = false; referenceNotes.Text = ""; ClearComparison(); }
    private void ClearComparison() { comparisonWork.Cancel(); comparisonWork = new(); comparison.Text = ""; }
    private void Update()
    {
        frames.TryGetValue(Draft.PreviewKey, out var selected); after.Source = selected?.Image;
        before.Source = (reference ?? baseline)?.Image; beforeLabel.Text = Loc.Text(reference == null ? "未应用 LUT" : "参考图");
        confirm.IsEnabled = Draft.CanImport && (source == null || selected != null);
        compare.IsEnabled = selected != null && reference != null && referenceConditions.CanCompare;
        assumptions.Text = original.Candidates.FirstOrDefault(candidate => original.Applying(candidate, displayInput)?.PreviewKey == Draft.PreviewKey)?.AssumptionsName(Draft.Base) ?? "";
        conditionsLabel.Text = Loc.Text(displayInput ? "预览条件：已显影照片，无额外调整，LUT 强度 100%，输出 sRGB，长边 512 像素。" :
            "预览条件：C5 显影，相机白平衡，场景曝光归一化，曝光 0，无额外调整，LUT 强度 100%，输出 sRGB，长边 512 像素。");
        foreach (var (key, thumbnail) in thumbnails) {
            thumbnail.Button.BorderThickness = new Thickness(key == Draft.PreviewKey ? 2 : 1);
            thumbnail.Button.BorderBrush = key == Draft.PreviewKey ? Brushes.Goldenrod : Brushes.DimGray;
            thumbnail.Image.Source = frames.GetValueOrDefault(key)?.Image; thumbnail.Button.IsEnabled = thumbnail.Image.Source != null;
        }
    }
    private void BuildCandidates()
    {
        candidates.Children.Clear(); thumbnails.Clear();
        var choices = original.Candidates.Select(candidate => (Candidate: candidate, Draft: original.Applying(candidate, displayInput))).Where(value => value.Draft != null).ToArray();
        foreach (var (entry, index) in (showAll ? choices : choices.Take(4)).Select((value, index) => (value, index))) {
            var draft = entry.Draft!; var image = new Image { Height = 110, Stretch = Stretch.Uniform };
            var content = new StackPanel { Width = 176 }; content.Children.Add(image); content.Children.Add(AdjustmentDialogLayout.Text(Loc.Format("方案 {0}", index + 1))); content.Children.Add(AdjustmentDialogLayout.Text(entry.Candidate.BasisName));
            var button = new Button { Content = content, Padding = new Thickness(8), Margin = new Thickness(0, 0, 10, 10), IsEnabled = false };
            AutomationProperties.SetAutomationId(button, "look.compatibility." + entry.Candidate.Id);
            button.Click += (_, _) => { var old = Draft; Draft = original.Applying(entry.Candidate, displayInput)!; Draft.ConfirmedExtremeValues = old.ConfirmedExtremeValues; if (old.Base != Draft.Base || old.Signal("input", "reference") != Draft.Signal("input", "reference")) referenceChecks[2].IsChecked = false; BuildAdvanced(); Changed(); };
            candidates.Children.Add(button); thumbnails[draft.PreviewKey] = (button, image);
        }
        more.Visibility = choices.Length > 4 ? Visibility.Visible : Visibility.Collapsed;
        more.Content = Loc.Text(showAll ? "收起其他方案" : "查看其他方案（包括 Log 输入）");
    }
    private void BuildAdvanced()
    {
        advancedFields.Children.Clear();
        var spaces = new Dictionary<string, string> { [""] = Loc.Text("请选择") };
        foreach (var space in LUTCompatibility.Spaces) spaces[space] = LUTCompatibility.SpaceName(space);
        var ranges = new Dictionary<string, string> { ["full"] = Loc.Text("完整范围"), ["legal10"] = Loc.Text("视频范围（10 位 64–940）") };
        var references = new Dictionary<string, string> { ["scene"] = Loc.Text("场景线性"), ["display"] = Loc.Text("显示图像") };
        foreach (var signal in new[] { "input", "output" }) {
            var input = signal == "input";
            Choice(input ? "输入颜色" : "输出颜色", Draft.Signal(signal, "space"), spaces, value => { Draft.SelectSpace(signal, value); referenceChecks[2].IsChecked = false; BuildAdvanced(); Changed(); });
            if (Draft.Signal(signal, "space") == "linear-srgb") Choice(input ? "输入参考" : "输出参考", Draft.Signal(signal, "reference"), references, value => {
                Draft.Contract[signal]!["reference"] = value; if (input) Draft.Contract["base_rendering"] = value == "scene" ? "none" : "rawlab-neutral-v1";
                referenceChecks[2].IsChecked = false; BuildAdvanced(); Changed();
            });
            Choice(input ? "输入范围" : "输出范围", Draft.Signal(signal, "range"), ranges, value => { Draft.Contract[signal]!["range"] = value; Changed(); });
        }
        Choice("插值方式", Draft.Contract["interpolation"]!.GetValue<string>(), new() { ["linear"] = Loc.Text("三线性"), ["tetrahedral"] = Loc.Text("四面体") }, value => { Draft.Contract["interpolation"] = value; Changed(); });
        if (Draft.Signal("input", "reference") == "display") Choice("基础图像", Draft.Base, new() {
            ["rawlab-neutral-v1"] = Loc.Text("RawLab 中性显影（近似）"), ["source-display"] = Loc.Text("已显影的照片（JPEG 等）") }, value => { Draft.Contract["base_rendering"] = value; referenceChecks[2].IsChecked = false; Changed(); });
        advancedFields.Children.Add(Text(Draft.Base == "rawlab-neutral-v1" ? "使用 RawLab 中性显影作为基础，不代表还原了相机的标准风格。" :
            Draft.Base == "source-display" ? "仅用于已显影且基础风格匹配的照片，不能直接用于 RAW。" : ""));
        void Choice(string label, string selected, Dictionary<string, string> values, Action<string> change) {
            advancedFields.Children.Add(Text(label));
            if (Draft.FixedContract) { advancedFields.Children.Add(AdjustmentDialogLayout.Text(values.GetValueOrDefault(selected, selected))); return; }
            var combo = new ComboBox { ItemsSource = values, DisplayMemberPath = "Value", SelectedValuePath = "Key", SelectedValue = selected, MinHeight = 32, Margin = new Thickness(0, 0, 0, 10) };
            AutomationProperties.SetName(combo, Loc.Text(label)); combo.SelectionChanged += (_, _) => { if (combo.SelectedValue is string value) change(value); }; advancedFields.Children.Add(combo);
        }
    }
    private void Changed() { referenceChecks[2].IsChecked = false; ClearComparison(); Update(); _ = PreviewSelected(); }
    private async Task LoadPhoto(string file)
    {
        sourceWork.Cancel(); selectionWork.Cancel(); referenceWork.Cancel(); ClearComparison(); sourceWork = new(); var token = sourceWork.Token;
        reference = null; referenceName.Text = "";
        source = file; sourceLabel.Text = Path.GetFileName(file); var acknowledged = Draft.ConfirmedExtremeValues;
        Draft = LUTCompatibility.Parse(original.SnapshotJSON())!; Draft.ConfirmedExtremeValues = acknowledged;
        frames.Clear(); baseline = null; ResetConditions();
        notice.Text = Loc.Text("正在生成预览…"); BuildAdvanced(); Update();
        try {
            var loaded = await service.Load(lookPath, file, token); if (closed || token.IsCancellationRequested) return;
            baseline = loaded.Baseline; displayInput = loaded.DisplayInput; BuildCandidates(); Update();
            foreach (var candidate in original.Candidates) {
                if (closed || token.IsCancellationRequested) return;
                var draft = original.Applying(candidate, displayInput); if (draft == null) continue;
                try { var frame = await service.Render(draft, token); if (closed || token.IsCancellationRequested) return; frames[draft.PreviewKey] = frame; Update(); }
                catch (OperationCanceledException) { return; }
                catch (Exception) { if (!closed && !token.IsCancellationRequested && thumbnails.TryGetValue(draft.PreviewKey, out var item)) item.Button.ToolTip = Loc.Text("无法生成预览，请检查照片、LUT 和颜色配置。"); }
            }
            notice.Text = "";
        } catch (OperationCanceledException) { }
        catch (Exception) { if (!closed && !token.IsCancellationRequested) notice.Text = Loc.Text("无法生成预览，请检查照片、LUT 和颜色配置。"); }
    }
    private async Task PreviewSelected()
    {
        selectionWork.Cancel(); selectionWork = new(); var token = selectionWork.Token; var sourceToken = sourceWork.Token;
        if (source == null || !Draft.HasCompleteContract || frames.ContainsKey(Draft.PreviewKey)) return;
        var snapshot = LUTCompatibility.Parse(DraftSnapshot(Draft))!; var key = snapshot.PreviewKey;
        try { var frame = await service.Render(snapshot, token); if (closed || token.IsCancellationRequested || sourceToken.IsCancellationRequested) return; frames[key] = frame; notice.Text = ""; Update(); }
        catch (OperationCanceledException) { }
        catch (Exception) { if (!closed && !token.IsCancellationRequested && !sourceToken.IsCancellationRequested) notice.Text = Loc.Text("无法生成预览，请检查照片、LUT 和颜色配置。"); }
    }
    private static string DraftSnapshot(LUTCompatibility value) => value.SnapshotJSON();
    private async Task LoadReference(string file)
    {
        referenceWork.Cancel(); referenceWork = new(); var token = referenceWork.Token; ResetConditions(); reference = null; referenceName.Text = Path.GetFileName(file); Update();
        try { var image = await service.Reference(file, token); if (closed || token.IsCancellationRequested) return; reference = image; Update(); }
        catch (OperationCanceledException) { }
        catch (Exception) { if (!closed && !token.IsCancellationRequested) comparison.Text = Loc.Text("无法生成预览，请检查照片、LUT 和颜色配置。"); }
    }
    private async Task Compare()
    {
        ClearComparison(); var token = comparisonWork.Token;
        if (!referenceConditions.CanCompare || reference == null || !frames.TryGetValue(Draft.PreviewKey, out var selected)) return;
        var conditions = new LUTReferenceConditions { SameSource = referenceConditions.SameSource, SameGeometry = referenceConditions.SameGeometry,
            SameProcessing = referenceConditions.SameProcessing, KnownSRGB = referenceConditions.KnownSRGB, ReferenceSource = referenceConditions.ReferenceSource };
        try {
            var result = await service.Compare(selected, reference, conditions, token); if (closed || token.IsCancellationRequested) return;
            comparison.Text = Loc.Format("平均差异 {0}/255 · 最大差异 {1}/255", (result.Mean * 255).ToString("F2", CultureInfo.CurrentCulture), (result.Maximum * 255).ToString("F2", CultureInfo.CurrentCulture)) + "\n" +
                Loc.Format("通道边界像素：方案 {0}% · 参考 {1}%", (result.CandidateBoundary * 100).ToString("F1", CultureInfo.CurrentCulture), (result.ReferenceBoundary * 100).ToString("F1", CultureInfo.CurrentCulture)) + "\n" +
                Loc.Text("边界比例仅供观察，不能据此判定配置或风格错误。") + "\n" +
                Loc.Text("按已确认条件比较缩小后的 sRGB 像素；差异越小表示越接近此参考，效果仍未验证。");
        } catch (OperationCanceledException) { }
        catch (Exception error) { if (!closed && !token.IsCancellationRequested) comparison.Text = error.Message; }
    }
}
