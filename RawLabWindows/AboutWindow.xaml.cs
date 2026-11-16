using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Data;
using System.Windows.Documents;

namespace RawLab.Windows;

public partial class AboutWindow : Window
{
    private readonly string currentVersion;
    private bool languageReady;
    private readonly UsageAnalytics analytics;
    private bool refreshingUsage;
    public AboutWindow(string currentVersion, UsageAnalytics? analytics = null)
    {
        InitializeComponent();
        this.currentVersion = currentVersion;
        this.analytics = analytics ?? new UsageAnalytics();
        RefreshVersion();
        LanguageBox.ItemsSource = Loc.Choices.Select(c => c.Code == "system" ? c with { NativeName = Loc.Text("跟随系统") } : c).ToList();
        LanguageBox.SelectedValue = Loc.Preference;
        languageReady = true;
        Loc.Changed += RefreshLanguage;
        Closed += (_, _) => Loc.Changed -= RefreshLanguage;
        this.analytics.PropertyChanged += UsageChanged;
        Closed += (_, _) => this.analytics.PropertyChanged -= UsageChanged;
        RefreshUsage();
    }
    private void RefreshLanguage()
    {
        RefreshVersion();
        languageReady = false;
        LanguageBox.ItemsSource = Loc.Choices.Select(c => c.Code == "system" ? c with { NativeName = Loc.Text("跟随系统") } : c).ToList();
        LanguageBox.SelectedValue = Loc.Preference;
        languageReady = true;
        RefreshUsage();
    }
    private void RefreshVersion() => VersionRun.Text = Loc.Format("版本 {0}", currentVersion);
    private void LanguageChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (!languageReady || LanguageBox.SelectedValue is not string preference || preference == Loc.Preference) return;
        try { Loc.SetPreference(preference); }
        catch (Exception error) when (error is System.IO.IOException or UnauthorizedAccessException)
        {
            MessageBox.Show(this, Loc.Text("无法保存语言设置。") + "\n" + error.Message, "RawLab");
            LanguageBox.SelectedValue = Loc.Preference;
        }
    }
    private async void UsageConsentChanged(object sender, RoutedEventArgs e)
    {
        if (refreshingUsage) return;
        var requested = UsageConsent.IsChecked == true;
        if (requested == analytics.ConsentGiven) { RefreshUsage(); return; }
        await analytics.SetConsentAsync(requested);
        RefreshUsage();
    }
    private void RepositoryClicked(object sender, RoutedEventArgs e) => OpenLink("https://github.com/dancancer/RawLab");
    private void AuthorClicked(object sender, RoutedEventArgs e) => OpenLink("https://www.xiaohongshu.com/user/profile/6474b1560000000010037c8e");
    private void PrivacyClicked(object sender, RoutedEventArgs e) => OpenLink("https://terms.alicdn.com/legal-agreement/terms/privacy_policy_full/20240308104330389/20240308104330389.html");
    private void CloseClicked(object sender, RoutedEventArgs e) => Close();
    private void RefreshUsage()
    {
        refreshingUsage = true;
        UsageConsent.IsEnabled = analytics.CanEnable || analytics.ConsentGiven;
        UsageConsent.IsChecked = analytics.ConsentGiven;
        // 统计模型只给翻译键，这里按当前语言显示
        UsageStatus.Text = Loc.Text(string.IsNullOrEmpty(analytics.StorageWarning) ? analytics.Status : analytics.StorageWarning);
        refreshingUsage = false;
    }
    private void UsageChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e) => Dispatcher.BeginInvoke(RefreshUsage);
    private void OpenLink(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Win32Exception) { MessageBox.Show(this, Loc.Text("无法打开链接，请检查默认浏览器设置。"), "RawLab"); }
    }
}
