using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;

namespace RawLab.Windows;

public sealed class ToneCurvePanel : StackPanel
{
    private readonly ToneCurveCanvas canvas = new();
    private readonly ParameterRow x = new() { Compact = true }, y = new() { Compact = true }, legacy = new();
    private readonly ParameterRow highlightsRow = new(), lightsRow = new(), darksRow = new(), shadowsRow = new();
    private readonly ParameterRow splitShadowRow = new(), splitMidtoneRow = new(), splitHighlightRow = new();
    private readonly ComboBox points = new() { MinHeight = 30, MinWidth = 140 };
    private readonly Button switchMode = new(), add = new(), remove = new(), reset = new(), resetParametric = new();
    private readonly Button pointModeButton = new(), parametricModeButton = new();
    private readonly Button[] channelButtons = [new(), new(), new(), new()];
    private readonly CheckBox luminosityToggle = new() { Margin = new(0, 4, 0, 4) };
    private readonly CheckBox targetToggle = new() { HorizontalAlignment = HorizontalAlignment.Left, Margin = new(0, 0, 0, 4) };
    private readonly TextBlock targetStatus = new() { TextWrapping = TextWrapping.Wrap, Margin = new(0, 0, 0, 6) };
    private readonly TextBlock mode = new(), hint = new() { TextWrapping = TextWrapping.Wrap }, splitHeader = new() { Margin = new(0, 4, 0, 2) };
    private readonly Grid content = new();
    private readonly Grid exposureAxis = new() { Margin = new Thickness(12, 0, 12, 0) };
    private readonly TextBlock referenceWhite = new() { TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap };
    internal ToneCurveCanvas CanvasControl => canvas;
    internal Grid ExposureAxis => exposureAxis;
    internal TextBlock ReferenceWhiteText => referenceWhite;
    internal ParameterRow XRow => x;
    internal ParameterRow YRow => y;
    internal Button SwitchModeButton => switchMode;
    internal Button RemoveButton => remove;
    internal ToneCurveChannel ActiveChannel => channel;
    internal bool TargetEnabled { get; private set; }
    private readonly StackPanel plot = new(), rows = new(), custom = new(), parametricPanel = new();
    private readonly WrapPanel channelTabs = new() { Margin = new(0, 0, 0, 6) };
    private readonly WrapPanel subModeTabs = new() { Margin = new(0, 0, 0, 6) };
    private readonly WrapPanel actions = new();
    private ToneCurveSettings settings = new();
    private ToneCurveChannel channel = ToneCurveChannel.Rgb;
    private bool showParametric;
    private double scalar;
    private object? source;
    private bool syncing, usesExposureStops, targetWaiting;
    private HslTargetSample? targetSample;
    private HslTargetAvailability? targetNotice;
    private int selected;
    public event Action<ToneCurveSettings, bool>? Changed;
    public event Action<double, bool>? LegacyChanged;
    internal event Action<bool, ToneCurveChannel>? TargetChanged;
    internal event Action? TargetInputCancelled;
    public ToneCurvePanel()
    {
        MaxWidth = 720; Margin = new Thickness(12, 6, 12, 6);
        Children.Add(targetToggle); Children.Add(targetStatus);
        targetStatus.SetResourceReference(TextBlock.ForegroundProperty, "Muted");
        AutomationProperties.SetAutomationId(targetToggle, "curve.target");
        AutomationProperties.SetAutomationId(targetStatus, "curve.target.status");
        targetToggle.Click += (_, _) => { if (!syncing) TargetChanged?.Invoke(targetToggle.IsChecked == true, channel); };

        var channels = Enum.GetValues<ToneCurveChannel>();
        for (var i = 0; i < channels.Length; i++) {
            var ch = channels[i];
            var btn = channelButtons[i];
            btn.MinHeight = 30; btn.Margin = new Thickness(2);
            AutomationProperties.SetAutomationId(btn, $"curve.channel.{ch.ToString().ToLowerInvariant()}");
            btn.Click += (_, _) => {
                if (syncing || channel == ch) return;
                CancelInputs(); TargetInputCancelled?.Invoke();
                channel = ch; selected = 0;
                if (TargetEnabled) TargetChanged?.Invoke(true, channel);
                Refresh(settings, scalar, source, usesExposureStops);
            };
            channelTabs.Children.Add(btn);
        }
        Children.Add(channelTabs);

        pointModeButton.MinHeight = 30; pointModeButton.Margin = new Thickness(2);
        parametricModeButton.MinHeight = 30; parametricModeButton.Margin = new Thickness(2);
        AutomationProperties.SetAutomationId(pointModeButton, "curve.submode.point");
        AutomationProperties.SetAutomationId(parametricModeButton, "curve.submode.parametric");
        pointModeButton.Click += (_, _) => { if (!syncing && showParametric) { showParametric = false; Refresh(settings, scalar, source, usesExposureStops); } };
        parametricModeButton.Click += (_, _) => { if (!syncing && !showParametric) { showParametric = true; Refresh(settings, scalar, source, usesExposureStops); } };
        subModeTabs.Children.Add(pointModeButton); subModeTabs.Children.Add(parametricModeButton);
        Children.Add(subModeTabs);

        AutomationProperties.SetAutomationId(luminosityToggle, "curve.luminosity");
        luminosityToggle.Click += (_, _) => {
            if (syncing || !IsEnabled || !CommitInputs()) return;
            TargetInputCancelled?.Invoke();
            var next = new ToneCurveSettings(settings.Mode, settings.Points, settings.Channels, luminosityToggle.IsChecked == true, settings.Parametric);
            settings = next;
            Changed?.Invoke(settings, false);
            Refresh(settings, scalar, source, usesExposureStops);
        };
        Children.Add(luminosityToggle);

        var header = new WrapPanel { Margin = new Thickness(0, 0, 0, 6) };
        mode.VerticalAlignment = VerticalAlignment.Center; mode.Margin = new Thickness(0, 0, 18, 0);
        header.Children.Add(mode); header.Children.Add(switchMode); Children.Add(header); Children.Add(legacy);
        content.ColumnDefinitions.Add(new()); content.ColumnDefinitions.Add(new());
        content.RowDefinitions.Add(new() { Height = GridLength.Auto }); content.RowDefinitions.Add(new() { Height = GridLength.Auto });
        rows.MinWidth = 190; rows.Children.Add(points); rows.Children.Add(x); rows.Children.Add(y);
        exposureAxis.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        exposureAxis.ColumnDefinitions.Add(new());
        exposureAxis.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var maximum = new TextBlock { Text = "+8 EV" };
        exposureAxis.Children.Add(new TextBlock { Text = "−8 EV" });
        exposureAxis.Children.Add(referenceWhite); Grid.SetColumn(referenceWhite, 1);
        exposureAxis.Children.Add(maximum); Grid.SetColumn(maximum, 2);
        AutomationProperties.SetAutomationId(exposureAxis, "curve.hdr.ev-axis");
        plot.Width = canvas.Width; plot.HorizontalAlignment = HorizontalAlignment.Center;
        plot.Children.Add(canvas); plot.Children.Add(exposureAxis);
        content.Children.Add(plot); content.Children.Add(rows); custom.Children.Add(content); custom.Children.Add(hint);
        actions.Children.Add(add); actions.Children.Add(remove); actions.Children.Add(reset); custom.Children.Add(actions); Children.Add(custom);

        parametricPanel.Children.Add(highlightsRow);
        parametricPanel.Children.Add(lightsRow);
        parametricPanel.Children.Add(darksRow);
        parametricPanel.Children.Add(shadowsRow);
        parametricPanel.Children.Add(splitHeader);
        parametricPanel.Children.Add(splitShadowRow);
        parametricPanel.Children.Add(splitMidtoneRow);
        parametricPanel.Children.Add(splitHighlightRow);
        resetParametric.MinHeight = 32; resetParametric.Margin = new Thickness(2);
        resetParametric.HorizontalAlignment = HorizontalAlignment.Right;
        AutomationProperties.SetAutomationId(resetParametric, "curve.parametric.reset");
        resetParametric.Click += (_, _) => {
            if (!CommitInputs() || settings.Parametric.IsDefault) return;
            TargetInputCancelled?.Invoke();
            settings = new ToneCurveSettings(settings.Mode, settings.Points, settings.Channels, settings.ApplyToLuminosity, new());
            Changed?.Invoke(settings, false);
            Refresh(settings, scalar, source, usesExposureStops);
        };
        parametricPanel.Children.Add(resetParametric);
        Children.Add(parametricPanel);

        foreach (var button in new[] { switchMode, add, remove, reset }) { button.MinHeight = 32; button.Margin = new Thickness(2); }
        AutomationProperties.SetAutomationId(canvas, "curve.canvas"); AutomationProperties.SetAutomationId(points, "curve.points");
        AutomationProperties.SetAutomationId(switchMode, "curve.switch"); AutomationProperties.SetAutomationId(add, "curve.add");
        AutomationProperties.SetAutomationId(remove, "curve.remove"); AutomationProperties.SetAutomationId(reset, "curve.reset");
        AutomationProperties.SetAutomationId(x.Number, "curve.value.x"); AutomationProperties.SetAutomationId(y.Number, "curve.value.y");
        AutomationProperties.SetAutomationId(legacy.Number, "curve.legacy.value");
        AutomationProperties.SetAutomationId(highlightsRow.Number, "curve.parametric.highlights");
        AutomationProperties.SetAutomationId(lightsRow.Number, "curve.parametric.lights");
        AutomationProperties.SetAutomationId(darksRow.Number, "curve.parametric.darks");
        AutomationProperties.SetAutomationId(shadowsRow.Number, "curve.parametric.shadows");
        AutomationProperties.SetAutomationId(splitShadowRow.Number, "curve.parametric.splitShadow");
        AutomationProperties.SetAutomationId(splitMidtoneRow.Number, "curve.parametric.splitMidtone");
        AutomationProperties.SetAutomationId(splitHighlightRow.Number, "curve.parametric.splitHighlight");

        canvas.PrepareEditing = CommitInputs;
        canvas.Changed += Change;
        canvas.SelectionChanged += index => { selected = index; RefreshRows(); };
        points.SelectionChanged += (_, _) => {
            if (syncing || points.SelectedIndex < 0) return;
            canvas.CancelGesture(); x.CancelInput(); y.CancelInput(); selected = points.SelectedIndex;
            Refresh(settings, scalar, source, usesExposureStops);
        };
        x.Changed += (next, dragging) => {
            var active = ActiveChannelSettings();
            if (active.IsInterior(selected)) Change(active.Moving(selected, Normalize(next), active.Points[selected].Y), dragging);
        };
        y.Changed += (next, dragging) => {
            var active = ActiveChannelSettings();
            if (active.CanMoveY(selected)) Change(active.Moving(selected, active.Points[selected].X, Normalize(next)), dragging);
        };
        legacy.Changed += (next, dragging) => { if (!syncing) { scalar = next; LegacyChanged?.Invoke(next, dragging); } };
        highlightsRow.Changed += (next, dragging) => UpdateParametric(settings.Parametric with { Highlights = next }, dragging);
        lightsRow.Changed += (next, dragging) => UpdateParametric(settings.Parametric with { Lights = next }, dragging);
        darksRow.Changed += (next, dragging) => UpdateParametric(settings.Parametric with { Darks = next }, dragging);
        shadowsRow.Changed += (next, dragging) => UpdateParametric(settings.Parametric with { Shadows = next }, dragging);
        splitShadowRow.Changed += (next, dragging) => UpdateParametric(settings.Parametric with { SplitShadow = next }, dragging);
        splitMidtoneRow.Changed += (next, dragging) => UpdateParametric(settings.Parametric with { SplitMidtone = next }, dragging);
        splitHighlightRow.Changed += (next, dragging) => UpdateParametric(settings.Parametric with { SplitHighlight = next }, dragging);

        switchMode.Click += (_, _) => {
            if (!CommitInputs()) return;
            var message = Loc.Text((settings.Mode == ToneCurveMode.Legacy) ? "多点曲线将从直线开始，旧 S 曲线数值会保留。" : "切换到 S 曲线将移除当前控制点，可撤销此操作。");
            if (MessageBox.Show(Window.GetWindow(this), message, Loc.Text("切换曲线模式"), MessageBoxButton.OKCancel, MessageBoxImage.Question) == MessageBoxResult.OK) {
                selected = 0; Change((settings.Mode == ToneCurveMode.Legacy) ? ToneCurveSettings.Identity : new(), false);
            }
        };
        add.Click += (_, _) => {
            var active = ActiveChannelSettings();
            if (!CommitInputs() || active.Points.Count >= 33) return;
            var index = Enumerable.Range(1, active.Points.Count - 1).MaxBy(i => active.Points[i].X - active.Points[i - 1].X);
            var a = active.Points[index - 1]; var b = active.Points[index]; selected = index;
            Change(active.Inserting(a.X + (b.X - a.X) / 2, a.Y + (b.Y - a.Y) / 2), false);
        };
        remove.Click += (_, _) => {
            var active = ActiveChannelSettings();
            if (CommitInputs()) Change(active.Removing(selected), false);
        };
        reset.Click += (_, _) => { if (CommitInputs()) { selected = 0; Change(ToneCurveSettings.Identity, false); } };
        SizeChanged += (_, _) => LayoutControls();
        IsVisibleChanged += (_, _) => { if (!IsVisible) CancelInputs(); };
        RefreshLanguage();
    }

    private ToneCurveSettings ActiveChannelSettings()
    {
        var shape = settings.Shape(channel);
        var effective = shape.Mode == ToneCurveMode.Legacy ? ToneCurveShape.Identity : shape;
        return new(effective.Mode, effective.Points, settings.Channels, settings.ApplyToLuminosity, settings.Parametric);
    }

    private void UpdateParametric(ToneCurveParametric nextParam, bool dragging)
    {
        if (syncing || !IsEnabled || !nextParam.IsValid) return;
        TargetInputCancelled?.Invoke();
        settings = new(settings.Mode, settings.Points, settings.Channels, settings.ApplyToLuminosity, nextParam);
        Changed?.Invoke(settings, dragging);
        Refresh(settings, scalar, source, usesExposureStops);
    }

    internal void SetTarget(bool enabled, ToneCurveChannel targetChannel, bool waiting, HslTargetSample? sample, HslTargetAvailability? notice)
    {
        TargetEnabled = enabled;
        if (enabled && channel != targetChannel) channel = targetChannel;
        targetWaiting = waiting; targetSample = sample; targetNotice = notice;
        RefreshTargetControls();
    }

    private void RefreshTargetControls()
    {
        var wasSyncing = syncing; syncing = true;
        try {
            targetToggle.Content = Loc.Text("目标调整");
            targetToggle.IsChecked = TargetEnabled;
            AutomationProperties.SetName(targetToggle, Loc.Text("目标调整"));
            targetStatus.Visibility = TargetEnabled ? Visibility.Visible : Visibility.Collapsed;
            var key = targetNotice switch {
                HslTargetAvailability.Outside => "请在调整后的照片区域取色。",
                HslTargetAvailability.Stale => "预览已变化，请重新取色。",
                HslTargetAvailability.Nonfinite => "此像素不可取样。",
                HslTargetAvailability.Failed => "取色失败，请重试。",
                _ => "上下拖动调整，方向键微调，Esc 取消"
            };
            targetStatus.Text = targetWaiting ? Loc.Text("正在取色…") : Loc.Text(key);
        } finally { syncing = wasSyncing; }
    }

    public void CancelInputs()
    {
        canvas.CancelGesture(); x.CancelInput(); y.CancelInput(); legacy.CancelInput();
        highlightsRow.CancelInput(); lightsRow.CancelInput(); darksRow.CancelInput(); shadowsRow.CancelInput();
        splitShadowRow.CancelInput(); splitMidtoneRow.CancelInput(); splitHighlightRow.CancelInput();
    }
    private bool CommitInputs() => (channel == ToneCurveChannel.Rgb && settings.Mode == ToneCurveMode.Legacy && !showParametric)
        ? legacy.Commit()
        : (showParametric && channel == ToneCurveChannel.Rgb
            ? highlightsRow.Commit() && lightsRow.Commit() && darksRow.Commit() && shadowsRow.Commit() &&
              splitShadowRow.Commit() && splitMidtoneRow.Commit() && splitHighlightRow.Commit()
            : x.Commit() && y.Commit());
    public void RefreshLanguage()
    {
        channelButtons[0].Content = "RGB";
        channelButtons[1].Content = Loc.Text("红");
        channelButtons[2].Content = Loc.Text("绿");
        channelButtons[3].Content = Loc.Text("蓝");
        pointModeButton.Content = Loc.Text("点曲线");
        parametricModeButton.Content = Loc.Text("参数曲线");
        luminosityToggle.Content = Loc.Text("仅作用于明度");
        splitHeader.Text = Loc.Text("拆分点");
        resetParametric.Content = Loc.Text("重置曲线");
        add.Content = Loc.Text("添加控制点"); remove.Content = Loc.Text("删除控制点"); reset.Content = Loc.Text("重置为直线");
        hint.Text = Loc.Text("点击曲线区域添加控制点，拖动中间点调整。");
        referenceWhite.Text = "0 EV\n" + Loc.Text("参考白");
        RefreshTargetControls();
        Refresh(settings, scalar, source, usesExposureStops);
    }
    public void Refresh(ToneCurveSettings next, double legacyValue, object? identity, bool hdr = false)
    {
        var wasSyncing = syncing; syncing = true;
        try {
            if (!Equals(source, identity) || usesExposureStops != hdr) {
                CancelInputs(); selected = 0; channel = ToneCurveChannel.Rgb;
                showParametric = !next.Parametric.IsDefault && next.Mode == ToneCurveMode.Legacy;
            }
            source = identity; settings = next; scalar = legacyValue; usesExposureStops = hdr;
            var active = ActiveChannelSettings();
            selected = Math.Clamp(selected, 0, Math.Max(0, active.Points.Count - 1));
            var isRgb = channel == ToneCurveChannel.Rgb;
            subModeTabs.Visibility = isRgb ? Visibility.Visible : Visibility.Collapsed;
            pointModeButton.FontWeight = !showParametric ? FontWeights.SemiBold : FontWeights.Normal;
            parametricModeButton.FontWeight = showParametric ? FontWeights.SemiBold : FontWeights.Normal;
            for (var i = 0; i < channelButtons.Length; i++) {
                var item = (ToneCurveChannel)i;
                channelButtons[i].FontWeight = item == channel ? FontWeights.SemiBold : FontWeights.Normal;
                AutomationProperties.SetItemStatus(channelButtons[i], item == channel ? "selected" : "");
            }
            luminosityToggle.IsChecked = settings.ApplyToLuminosity;
            mode.Visibility = switchMode.Visibility = isRgb && !showParametric ? Visibility.Visible : Visibility.Collapsed;
            mode.Text = Loc.Text((settings.Mode == ToneCurveMode.Legacy) ? "S 曲线" : "多点曲线");
            switchMode.Content = Loc.Text((settings.Mode == ToneCurveMode.Legacy) ? "多点曲线" : "S 曲线");
            var showLegacy = isRgb && !showParametric && settings.Mode == ToneCurveMode.Legacy;
            legacy.Visibility = showLegacy ? Visibility.Visible : Visibility.Collapsed;
            custom.Visibility = showLegacy ? Visibility.Collapsed : Visibility.Visible;
            var parametricVisible = isRgb && showParametric;
            rows.Visibility = parametricVisible ? Visibility.Collapsed : Visibility.Visible;
            hint.Visibility = parametricVisible ? Visibility.Collapsed : Visibility.Visible;
            actions.Visibility = parametricVisible ? Visibility.Collapsed : Visibility.Visible;
            parametricPanel.Visibility = parametricVisible ? Visibility.Visible : Visibility.Collapsed;
            exposureAxis.Visibility = hdr ? Visibility.Visible : Visibility.Collapsed;
            var toneCurveSpec = ParameterSpec.All[(int)Parameter.ToneCurve];
            legacy.SourceIdentity = identity; legacy.Refresh(Loc.Text("S 曲线"), NumericRange.For(toneCurveSpec), scalar, 0, toneCurveSpec.Unit);
            RefreshRows();
            RefreshParametricRows();
            canvas.Refresh(active, identity, selected, channel, parametricVisible);
            LayoutControls();
            add.IsEnabled = !showLegacy && active.Points.Count < 33;
            remove.IsEnabled = !showLegacy && active.IsInterior(selected);
            reset.IsEnabled = !showLegacy && !settings.Shape(channel).IsIdentity;
            resetParametric.IsEnabled = !settings.Parametric.IsDefault;
            RefreshTargetControls();
        } finally { syncing = wasSyncing; }
    }
    private double Normalize(double value) => usesExposureStops ? (value + 8) / 16 : value;
    private double Coordinate(double value) => usesExposureStops ? value * 16 - 8 : value;
    private void RefreshRows()
    {
        var wasSyncing = syncing; syncing = true;
        try {
            var active = ActiveChannelSettings();
            points.ItemsSource = Enumerable.Range(1, active.Points.Count).Select(i => Loc.Format("控制点 {0}", i)).ToArray();
            if (channel == ToneCurveChannel.Rgb && !showParametric && settings.Mode == ToneCurveMode.Legacy) return;
            points.SelectedIndex = selected;
            var point = active.Points[selected];
            x.SourceIdentity = y.SourceIdentity = source;
            var range = usesExposureStops ? new NumericRange(-8, 8, .01, .1, .01, AllowOffGrid: true) :
                new NumericRange(0, 1, .001, .01, .001, AllowOffGrid: true);
            var unit = usesExposureStops ? "EV" : "";
            x.Refresh(Loc.Text("输入坐标"), range, Coordinate(point.X), Coordinate(point.X), unit,
                enabled: active.IsInterior(selected), inputScope: (channel, selected));
            y.Refresh(Loc.Text("输出坐标"), range, Coordinate(point.Y), Coordinate(point.X), unit,
                enabled: active.CanMoveY(selected), inputScope: (channel, selected));
        } finally { syncing = wasSyncing; }
    }
    private void RefreshParametricRows()
    {
        var p = settings.Parametric;
        var bandRange = new NumericRange(
            AdjustmentFieldSpec.SubFields.LightCurveParametric.BandMin,
            AdjustmentFieldSpec.SubFields.LightCurveParametric.BandMax, 1, 5, .1);
        highlightsRow.SourceIdentity = lightsRow.SourceIdentity = darksRow.SourceIdentity = shadowsRow.SourceIdentity = source;
        splitShadowRow.SourceIdentity = splitMidtoneRow.SourceIdentity = splitHighlightRow.SourceIdentity = source;
        highlightsRow.Refresh(Loc.Text("高光"), bandRange, p.Highlights, AdjustmentFieldSpec.SubFields.LightCurveParametric.BandDefault, "");
        lightsRow.Refresh(Loc.Text("亮部"), bandRange, p.Lights, AdjustmentFieldSpec.SubFields.LightCurveParametric.BandDefault, "");
        darksRow.Refresh(Loc.Text("暗部"), bandRange, p.Darks, AdjustmentFieldSpec.SubFields.LightCurveParametric.BandDefault, "");
        shadowsRow.Refresh(Loc.Text("阴影"), bandRange, p.Shadows, AdjustmentFieldSpec.SubFields.LightCurveParametric.BandDefault, "");
        var minGap = AdjustmentFieldSpec.SubFields.LightCurveParametric.SplitMinGap;
        var shadowMax = Math.Min(AdjustmentFieldSpec.SubFields.LightCurveParametric.SplitShadowMax, p.SplitMidtone - minGap);
        var midMin = Math.Max(AdjustmentFieldSpec.SubFields.LightCurveParametric.SplitMidtoneMin, p.SplitShadow + minGap);
        var midMax = Math.Min(AdjustmentFieldSpec.SubFields.LightCurveParametric.SplitMidtoneMax, p.SplitHighlight - minGap);
        var highMin = Math.Max(AdjustmentFieldSpec.SubFields.LightCurveParametric.SplitHighlightMin, p.SplitMidtone + minGap);
        splitShadowRow.Refresh(Loc.Text("阴影"), new NumericRange(AdjustmentFieldSpec.SubFields.LightCurveParametric.SplitShadowMin, shadowMax, .01, .05, .001, AllowOffGrid: true),
            p.SplitShadow, AdjustmentFieldSpec.SubFields.LightCurveParametric.SplitShadowDefault, "");
        splitMidtoneRow.Refresh(Loc.Text("中间调"), new NumericRange(midMin, midMax, .01, .05, .001, AllowOffGrid: true),
            p.SplitMidtone, AdjustmentFieldSpec.SubFields.LightCurveParametric.SplitMidtoneDefault, "");
        splitHighlightRow.Refresh(Loc.Text("高光"), new NumericRange(highMin, AdjustmentFieldSpec.SubFields.LightCurveParametric.SplitHighlightMax, .01, .05, .001, AllowOffGrid: true),
            p.SplitHighlight, AdjustmentFieldSpec.SubFields.LightCurveParametric.SplitHighlightDefault, "");
    }
    private void LayoutControls()
    {
        var horizontal = ActualWidth >= 470 && System.Windows.Documents.TextElement.GetFontSize(this) < 20;
        var showRows = !(channel == ToneCurveChannel.Rgb && showParametric);
        content.ColumnDefinitions[0].Width = horizontal ? GridLength.Auto : new(1, GridUnitType.Star);
        content.ColumnDefinitions[1].Width = horizontal && showRows ? new(1, GridUnitType.Star) : new(0);
        Grid.SetRow(rows, horizontal ? 0 : 1); Grid.SetColumn(rows, horizontal ? 1 : 0);
        rows.Margin = new Thickness(horizontal ? 12 : 0, 4, 0, 4);
    }
    private void Change(ToneCurveSettings next, bool dragging)
    {
        if (syncing || !IsEnabled) return;
        settings = settings.Replacing(channel, next.Master);
        Changed?.Invoke(settings, dragging);
        Refresh(settings, scalar, source, usesExposureStops);
    }
}
