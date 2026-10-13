using System.ComponentModel;
using System.Diagnostics;
using System.Windows;

namespace RawLab.Windows;

public partial class AboutWindow : Window
{
    private readonly UpdateChecker updates;
    private bool languageReady;
    public AboutWindow(UpdateChecker updates)
    {
        InitializeComponent();
        this.updates = updates;
        DataContext = updates;
        LanguageBox.ItemsSource = Loc.Choices.Select(c => c.Code == "system" ? c with { NativeName = Loc.Text("跟随系统") } : c).ToList();
        LanguageBox.SelectedValue = Loc.Preference;
        languageReady = true;
        Loc.Changed += RefreshLanguage;
        Closed += (_, _) => Loc.Changed -= RefreshLanguage;
    }
    private void RefreshLanguage()
    {
        languageReady = false;
        LanguageBox.ItemsSource = Loc.Choices.Select(c => c.Code == "system" ? c with { NativeName = Loc.Text("跟随系统") } : c).ToList();
        LanguageBox.SelectedValue = Loc.Preference;
        languageReady = true;
    }
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
    private async void CheckClicked(object sender, RoutedEventArgs e) => await updates.CheckAsync(true);
    private void RepositoryClicked(object sender, RoutedEventArgs e) => OpenLink(UpdateRelease.Repository);
    private void AuthorClicked(object sender, RoutedEventArgs e) => OpenLink(UpdateRelease.Author);
    private void DownloadClicked(object sender, RoutedEventArgs e) { if (updates.Available is { } release) OpenLink(release.Url); }
    private void CloseClicked(object sender, RoutedEventArgs e) => Close();
    private void OpenLink(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Win32Exception) { MessageBox.Show(this, Loc.Text("无法打开链接，请检查默认浏览器设置。"), "RawLab"); }
    }
}
