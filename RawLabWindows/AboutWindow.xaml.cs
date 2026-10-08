using System.ComponentModel;
using System.Diagnostics;
using System.Windows;

namespace RawLab.Windows;

public partial class AboutWindow : Window
{
    private readonly UpdateChecker updates;
    public AboutWindow(UpdateChecker updates)
    {
        InitializeComponent();
        this.updates = updates;
        DataContext = updates;
    }
    private async void CheckClicked(object sender, RoutedEventArgs e) => await updates.CheckAsync(true);
    private void RepositoryClicked(object sender, RoutedEventArgs e) => OpenLink(UpdateRelease.Repository);
    private void AuthorClicked(object sender, RoutedEventArgs e) => OpenLink(UpdateRelease.Author);
    private void DownloadClicked(object sender, RoutedEventArgs e) { if (updates.Available is { } release) OpenLink(release.Url); }
    private void CloseClicked(object sender, RoutedEventArgs e) => Close();
    private void OpenLink(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Win32Exception) { MessageBox.Show(this, "无法打开链接，请检查默认浏览器设置。", "RawLab"); }
    }
}
