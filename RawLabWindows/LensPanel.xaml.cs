using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace RawLab.Windows;

public partial class LensPanel : UserControl
{
    private LensSettings value = new();
    private LensInfo? info;
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
        Loaded += (_, _) => Loc.Changed += RefreshLanguage;
        Unloaded += (_, _) => Loc.Changed -= RefreshLanguage;
        Refresh(value, null);
    }
    private void RefreshLanguage()
    {
        if (IsLoaded) Dispatcher.BeginInvoke(new Action(() => Refresh(value, info)));
    }
    public void Refresh(LensSettings settings, LensInfo? report) {
        syncing = true;
        value = settings; info = report;
        Automatic.IsChecked = !value.Manual; Manual.IsChecked = value.Manual;
        Distortion.IsChecked = value.Distortion; Tca.IsChecked = value.Tca; AutoCrop.IsChecked = value.AutoCrop;
        var title = value.Manual ? info?.Candidates.FirstOrDefault(p => p.Id == value.ProfileId)?.Title : info?.SelectedLens;
        SelectedTitle.Text = string.IsNullOrEmpty(title) ? value.Manual ? Loc.Text("选择镜头") : Loc.Text("未匹配镜头") : title;
        ProfileButton.ToolTip = SelectedTitle.Text;
        ProfileButton.IsEnabled = value.Manual && info?.Candidates.Count > 0;
        StatusText.Text = info?.Message ?? Loc.Text("镜头信息尚未就绪");
        StatusText.ToolTip = info?.DetectedLens;
        // 按显示精度判断：四舍五入后是 0.0% 的裁边不值得报告
        var crop = info == null ? 0 : (1 - 1 / info.CropScale) * 100;
        CropText.Text = crop >= .05 ? Loc.Format("裁边 {0}%", crop.ToString("F1", CultureInfo.GetCultureInfo(Loc.Language))) : "";
        FilterProfiles();
        syncing = false;
    }
    private void Publish(LensSettings next) {
        if (syncing || !IsEnabled) return;
        Refresh(next, info); Changed?.Invoke(next);
    }
    private void ModeChanged(object sender, RoutedEventArgs e) => Publish(value with { Manual = ReferenceEquals(sender, Manual) });
    private void SwitchChanged(object sender, RoutedEventArgs e) => Publish(value with {
        Distortion = Distortion.IsChecked == true, Tca = Tca.IsChecked == true, AutoCrop = AutoCrop.IsChecked == true });
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
