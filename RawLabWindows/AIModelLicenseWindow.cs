using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;

namespace RawLab.Windows;

internal sealed class AIModelLicenseWindow : Window
{
    private const string DualDnFallbackLicense =
        "Creative Commons Attribution-NonCommercial 4.0 International (CC BY-NC 4.0)\n" +
        "Copyright (c) 2024 OpenImagingLab\n" +
        "NonCommercial — You may not use the model weights or converted artifacts for commercial purposes.\n" +
        "Full license: https://creativecommons.org/licenses/by-nc/4.0/";

    private const string RestormerFallbackLicense =
        "Restormer Academic Public License\n" +
        "Free for non-commercial, research, academic, and personal use only. Commercial use is not permitted without upstream authorization.\n" +
        "Source: https://github.com/swz30/Restormer";

    internal AIModelLicenseWindow(string? installedDirectory)
    {
        Style = (Style)FindResource(typeof(Window));
        Title = Loc.Text("AI 降噪模型许可");
        Width = 580;
        Height = 480;
        MinWidth = 440;
        MinHeight = 360;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;

        var root = new DockPanel { Margin = new Thickness(20) };

        var header = new StackPanel { Margin = new Thickness(0, 0, 0, 12) };
        header.Children.Add(new TextBlock
        {
            Text = Loc.Text("AI 降噪模型许可"),
            FontSize = 16,
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });
        var intro = new TextBlock
        {
            Text = Loc.Text("以下模型仅限非商业用途，各自沿用原作者的许可，不适用 RawLab 的 GPL 许可。"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 6, 0, 0),
        };
        intro.SetResourceReference(TextBlock.ForegroundProperty, "Muted");
        header.Children.Add(intro);
        DockPanel.SetDock(header, Dock.Top);
        root.Children.Add(header);

        var footer = new DockPanel { Margin = new Thickness(0, 14, 0, 0) };
        var closeButton = new Button { Content = Loc.Text("关闭"), IsCancel = true, MinWidth = 84 };
        closeButton.Click += (_, _) => Close();
        DockPanel.SetDock(closeButton, Dock.Right);
        footer.Children.Add(closeButton);

        if (ResolveLicenseDirectory(installedDirectory) is { } folder)
        {
            var openFolder = new Button { Content = Loc.Text("打开许可文件夹"), HorizontalAlignment = HorizontalAlignment.Left };
            openFolder.Click += (_, _) => OpenTarget(folder);
            DockPanel.SetDock(openFolder, Dock.Left);
            footer.Children.Add(openFolder);
        }

        DockPanel.SetDock(footer, Dock.Bottom);
        root.Children.Add(footer);

        var content = new StackPanel();
        content.Children.Add(BuildLicenseBlock(
            "DualDn (CC BY-NC 4.0)",
            ReadDualDnLicense(installedDirectory),
            "https://creativecommons.org/licenses/by-nc/4.0/"));
        content.Children.Add(BuildLicenseBlock(
            "Restormer (Academic Public License)",
            ReadRestormerLicense(installedDirectory),
            "https://github.com/swz30/Restormer"));

        root.Children.Add(new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = content,
        });

        Content = root;
    }

    private UIElement BuildLicenseBlock(string title, string text, string url)
    {
        var block = new StackPanel { Margin = new Thickness(0, 0, 0, 12) };
        var bar = new DockPanel { Margin = new Thickness(0, 0, 0, 6) };
        var linkText = new TextBlock { VerticalAlignment = VerticalAlignment.Center };
        var hyperlink = new Hyperlink(new Run(url)) { NavigateUri = new Uri(url) };
        hyperlink.Click += (_, _) => OpenTarget(url);
        linkText.Inlines.Add(hyperlink);
        DockPanel.SetDock(linkText, Dock.Right);
        bar.Children.Add(linkText);
        bar.Children.Add(new TextBlock
        {
            Text = title,
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 8, 0),
        });
        block.Children.Add(bar);

        var box = new TextBox
        {
            Text = text,
            IsReadOnly = true,
            TextWrapping = TextWrapping.Wrap,
            FontFamily = new FontFamily("Consolas"),
            FontSize = 11.5,
            Padding = new Thickness(8),
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            MaxHeight = 160,
        };
        block.Children.Add(box);
        return block;
    }

    private void OpenTarget(string target)
    {
        try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); }
        catch (Win32Exception) { MessageBox.Show(this, Loc.Text("无法打开链接，请检查默认浏览器设置。"), Title); }
    }

    internal static string? ResolveLicenseDirectory(string? installedDirectory, string? baseDirectory = null)
    {
        // 去内置模型发布包中 Licenses/DualDn 只含运行时许可；优先打开已安装模型目录，再回退到应用内目录。
        if (!string.IsNullOrWhiteSpace(installedDirectory) && Directory.Exists(installedDirectory)) return installedDirectory;
        var appBase = baseDirectory ?? AppContext.BaseDirectory;
        var bundledDualDnLicenses = Path.Combine(appBase, "Licenses", "DualDn");
        if (Directory.Exists(bundledDualDnLicenses)) return bundledDualDnLicenses;
        var bundledLicenses = Path.Combine(appBase, "Licenses");
        if (Directory.Exists(bundledLicenses)) return bundledLicenses;
        return null;
    }

    internal static string ReadDualDnLicense(string? installedDirectory, string? baseDirectory = null) =>
        ReadFirstNonEmpty(
            DualDnFallbackLicense,
            installedDirectory == null ? null : Path.Combine(installedDirectory, "DualDn-LICENSE.txt"),
            Path.Combine(baseDirectory ?? AppContext.BaseDirectory, "Licenses", "DualDn", "LICENSE"),
            Path.Combine(baseDirectory ?? AppContext.BaseDirectory, "AI", "DualDn", "DualDn-LICENSE.txt"));

    internal static string ReadRestormerLicense(string? installedDirectory, string? baseDirectory = null) =>
        ReadFirstNonEmpty(
            RestormerFallbackLicense,
            installedDirectory == null ? null : Path.Combine(installedDirectory, "Restormer-LICENSE.txt"),
            Path.Combine(baseDirectory ?? AppContext.BaseDirectory, "Licenses", "DualDn", "Restormer-LICENSE.txt"),
            Path.Combine(baseDirectory ?? AppContext.BaseDirectory, "AI", "DualDn", "Restormer-LICENSE.txt"));

    private static string ReadFirstNonEmpty(string fallback, params string?[] candidates)
    {
        foreach (var path in candidates)
        {
            if (string.IsNullOrWhiteSpace(path) || !File.Exists(path)) continue;
            try
            {
                var text = File.ReadAllText(path);
                if (!string.IsNullOrWhiteSpace(text)) return text;
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        return fallback;
    }
}
