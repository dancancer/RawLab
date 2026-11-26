using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Automation;

namespace RawLab.Windows;

public partial class LensPanel : UserControl
{
    private LensSettings value = new();
    private LensInfo? info;
    private bool supportsProfileCorrection = true;
    private bool syncing = true;
    public event Action? ResetRequested;
    public event Action<LensSettings>? Changed;
    public LensPanel()
    {
        InitializeComponent();
        Chooser.Closed+=(_,_)=>ProfileButton.Focus();
        Search.PreviewKeyDown+=(_,e)=>{if(e.Key==Key.Escape){Chooser.IsOpen=false;e.Handled=true;}else if(e.Key==Key.Down){Profiles.Focus();e.Handled=true;}};
        Profiles.PreviewKeyDown+=(_,e)=>{if(e.Key==Key.Escape){Chooser.IsOpen=false;e.Handled=true;}else if(e.Key==Key.Enter){UseSelectedProfile();e.Handled=true;}};
        Profiles.PreviewMouseLeftButtonUp+=(_,_)=>UseSelectedProfile();
        DefringePurpleAmountRow.Compact = DefringePurpleHueRow.Compact = DefringeGreenAmountRow.Compact = DefringeGreenHueRow.Compact = true;
        DefringePurpleAmountRow.Changed += (v, dragging) => { if (!dragging) Publish(value with { DefringePurpleAmount = v }); else PublishPreview(value with { DefringePurpleAmount = v }); };
        DefringePurpleHueRow.Changed += (v, dragging) => { if (!dragging) Publish(value with { DefringePurpleHue = v }); else PublishPreview(value with { DefringePurpleHue = v }); };
        DefringeGreenAmountRow.Changed += (v, dragging) => { if (!dragging) Publish(value with { DefringeGreenAmount = v }); else PublishPreview(value with { DefringeGreenAmount = v }); };
        DefringeGreenHueRow.Changed += (v, dragging) => { if (!dragging) Publish(value with { DefringeGreenHue = v }); else PublishPreview(value with { DefringeGreenHue = v }); };
        Loaded += (_, _) => Loc.Changed += RefreshLanguage;
        Unloaded += (_, _) => Loc.Changed -= RefreshLanguage;
        Refresh(value, null, supportsProfileCorrection);
    }
    private void PublishPreview(LensSettings next)
    {
        if (syncing || !IsEnabled) return;
        value = next;
        Changed?.Invoke(next);
    }
    private void RefreshLanguage()
    {
        if (IsLoaded) Dispatcher.BeginInvoke(new Action(() => Refresh(value, info, supportsProfileCorrection)));
    }
    public void Refresh(LensSettings settings, LensInfo? report, bool profileCorrectionSupported = true) {
        syncing = true;
        value = settings; info = report; supportsProfileCorrection = profileCorrectionSupported;
        Automatic.IsChecked = !value.Manual; Manual.IsChecked = value.Manual;
        Automatic.IsEnabled = Manual.IsEnabled = AutoCrop.IsEnabled = supportsProfileCorrection;
        Distortion.IsChecked = value.Distortion; Tca.IsChecked = value.Tca; Vignetting.IsChecked = value.Vignetting; AutoCrop.IsChecked = value.AutoCrop;
        var title = value.Manual ? info?.Candidates.FirstOrDefault(p => p.Id == value.ProfileId)?.Title : info?.SelectedLens;
        SelectedTitle.Text = string.IsNullOrEmpty(title) ? value.Manual ? Loc.Text("选择镜头") : Loc.Text("未匹配镜头") : title;
        ProfileButton.ToolTip = SelectedTitle.Text;
        ProfileButton.IsEnabled = supportsProfileCorrection && value.Manual && info?.Candidates.Count > 0;
        var matches=info?.Candidates.Where(p=>p.IsMatch).ToArray() ?? [];
        var candidate=value.Manual ? info?.Candidates.FirstOrDefault(p=>p.Id==value.ProfileId) : matches.Length==1 ? matches[0] : null;
        var inputAllowed=supportsProfileCorrection && info?.State is not (2 or 3 or 7 or 8 or 9);
        Distortion.IsEnabled=supportsProfileCorrection && (value.Distortion || inputAllowed && candidate?.HasDistortion==true);
        Tca.IsEnabled=supportsProfileCorrection && (value.Tca || inputAllowed && candidate?.HasTca==true);
        Vignetting.IsEnabled=supportsProfileCorrection && (value.Vignetting || inputAllowed && candidate!=null);
        var unavailable=!supportsProfileCorrection ? Loc.Text("仅 RAW 照片支持镜头校正。")
            : info==null ? Loc.Text("镜头信息尚未就绪") : !inputAllowed ? info.Message
            : candidate==null ? Loc.Text("未匹配镜头，请手动选择") : null;
        Explain(Distortion,unavailable ?? (candidate?.HasDistortion==true ? null : Loc.Text("畸变标定不可用")));
        Explain(Tca,unavailable ?? (candidate?.HasTca==true ? null : Loc.Text("横向色差标定不可用")));
        Explain(Vignetting,unavailable);
        StatusText.Text = supportsProfileCorrection ? (info?.Message ?? Loc.Text("镜头信息尚未就绪")) : Loc.Text("仅 RAW 照片支持镜头校正。");
        StatusText.ToolTip = info?.DetectedLens;
        // 按显示精度判断：四舍五入后是 0.0% 的裁边不值得报告
        var crop = info == null ? 0 : (1 - 1 / info.CropScale) * 100;
        CropText.Text = supportsProfileCorrection && crop >= .05 ? Loc.Format("裁边 {0}%", crop.ToString("F1", CultureInfo.GetCultureInfo(Loc.Language))) : "";
        var amountRange = new NumericRange(
            AdjustmentFieldSpec.Fields.GeometryLensDefringePurpleAmount.WindowsModel.Min!.Value,
            AdjustmentFieldSpec.Fields.GeometryLensDefringePurpleAmount.WindowsModel.Max!.Value,
            Grid: 1, Wheel: 1, FineWheel: 1, FixedDecimals: 0);
        var hueRange = new NumericRange(
            AdjustmentFieldSpec.Fields.GeometryLensDefringePurpleHue.WindowsModel.Min!.Value,
            AdjustmentFieldSpec.Fields.GeometryLensDefringePurpleHue.WindowsModel.Max!.Value,
            Grid: 1, Wheel: 1, FineWheel: 1, FixedDecimals: 0);
        DefringePurpleAmountRow.Refresh(Loc.Text("紫边数量"), amountRange, value.DefringePurpleAmount, 0, inputScope: "lens.defringePurpleAmount");
        DefringePurpleHueRow.Refresh(Loc.Text("紫边色相"), hueRange, value.DefringePurpleHue, 50, inputScope: "lens.defringePurpleHue");
        DefringeGreenAmountRow.Refresh(Loc.Text("绿边数量"), amountRange, value.DefringeGreenAmount, 0, inputScope: "lens.defringeGreenAmount");
        DefringeGreenHueRow.Refresh(Loc.Text("绿边色相"), hueRange, value.DefringeGreenHue, 50, inputScope: "lens.defringeGreenHue");
        FilterProfiles();
        syncing = false;
    }
    private static void Explain(CheckBox control,string? reason)
    {
        control.ToolTip=reason;
        ToolTipService.SetShowOnDisabled(control,true);
        AutomationProperties.SetHelpText(control,reason ?? "");
    }
    private void Publish(LensSettings next) {
        if (syncing || !IsEnabled) return;
        Refresh(next, info); Changed?.Invoke(next);
    }
    private void ModeChanged(object sender, RoutedEventArgs e) => Publish(value with { Manual = ReferenceEquals(sender, Manual) });
    private void SwitchChanged(object sender, RoutedEventArgs e) => Publish(value with {
        Distortion = Distortion.IsChecked == true, Tca = Tca.IsChecked == true, Vignetting = Vignetting.IsChecked == true, AutoCrop = AutoCrop.IsChecked == true });
    private void ResetClicked(object sender, RoutedEventArgs e) { if (!syncing && IsEnabled) ResetRequested?.Invoke(); }
    private void ChooseClicked(object sender, RoutedEventArgs e) { Chooser.IsOpen = true; Search.Focus(); }
    private void SearchChanged(object sender, TextChangedEventArgs e) { if (!syncing) FilterProfiles(); }
    private void FilterProfiles() {
        var previous = syncing; syncing = true;
        var profiles = info?.Candidates.Where(p => p.Title.Contains(Search.Text, StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(p => p.IsMatch).ThenBy(p => p.Title).ToArray() ?? [];
        Profiles.ItemsSource = profiles;
        EmptyText.Visibility = profiles.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        syncing = previous;
    }
    private void ProfileChanged(object sender, SelectionChangedEventArgs e) {
        // 方向键只移动候选，Enter 或鼠标确认后才修改草稿。
    }
    private void UseSelectedProfile() {
        if (syncing || !Chooser.IsOpen || Profiles.SelectedItem is not LensCandidate profile) return;
        Chooser.IsOpen = false;
        Publish(value with { Manual = true, ProfileId = profile.Id });
    }
}
