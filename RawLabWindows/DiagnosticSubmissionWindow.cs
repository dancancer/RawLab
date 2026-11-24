using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;

namespace RawLab.Windows;

public sealed class DiagnosticSubmissionWindow : Window
{
    private readonly DiagnosticSessionStore store;
    private readonly CheckBox recordingToggle;
    private readonly TextBlock statusText;
    private readonly TextBox noteBox;
    private readonly StackPanel reportCodeRow;
    private readonly TextBox reportCodeBox;
    private readonly Button copyCodeButton;
    private readonly TextBlock feedbackText;
    private readonly TextBox previewBox;
    private readonly Button saveZipButton;
    private readonly Button uploadButton;
    private readonly Button previewButton;
    private readonly Button clearButton;
    private bool updatingToggle;
    private bool isUploading;
    private string? lastUploadedCode;

    public DiagnosticSubmissionWindow(DiagnosticSessionStore store)
    {
        this.store = store;
        Style = (Style)FindResource(typeof(Window));
        Title = Loc.Text("故障诊断与错误日志");
        Width = 560;
        MinWidth = 460;
        SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;
        ResizeMode = ResizeMode.NoResize;
        KeyboardNavigation.SetTabNavigation(this, KeyboardNavigationMode.Cycle);

        var root = new StackPanel { Margin = new Thickness(24) };

        var privacyNotice = new TextBlock
        {
            Text = Loc.Text("诊断包仅包含应用版本、系统环境、操作步骤摘要与错误代码，不包含照片内容、文件名或个人路径。"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 12),
        };
        privacyNotice.SetResourceReference(TextBlock.ForegroundProperty, "Muted");
        root.Children.Add(privacyNotice);

        recordingToggle = new CheckBox
        {
            Content = Loc.Text("记录详细诊断日志"),
            Margin = new Thickness(0, 0, 0, 6),
        };
        AutomationProperties.SetAutomationId(recordingToggle, "diagnostics.recording");
        recordingToggle.Checked += (_, _) => HandleRecordingChanged(true);
        recordingToggle.Unchecked += (_, _) => HandleRecordingChanged(false);
        root.Children.Add(recordingToggle);

        statusText = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 12),
        };
        statusText.SetResourceReference(TextBlock.ForegroundProperty, "Muted");
        root.Children.Add(statusText);

        root.Children.Add(new TextBlock
        {
            Text = Loc.Text("问题简述（选填，勿填个人隐私）"),
            Margin = new Thickness(0, 0, 0, 6),
        });
        noteBox = new TextBox
        {
            MaxLength = 200,
            Margin = new Thickness(0, 0, 0, 12),
        };
        AutomationProperties.SetAutomationId(noteBox, "diagnostics.note");
        root.Children.Add(noteBox);

        reportCodeRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Visibility = Visibility.Collapsed,
            Margin = new Thickness(0, 0, 0, 10),
        };
        reportCodeBox = new TextBox
        {
            IsReadOnly = true,
            FontFamily = new FontFamily("Consolas"),
            MinWidth = 260,
            VerticalContentAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 8, 0),
        };
        copyCodeButton = new Button { Content = Loc.Text("复制诊断码") };
        AutomationProperties.SetAutomationId(copyCodeButton, "diagnostics.copyCode");
        copyCodeButton.Click += (_, _) =>
        {
            if (string.IsNullOrEmpty(lastUploadedCode)) return;
            try
            {
                Clipboard.SetText(lastUploadedCode);
                copyCodeButton.Content = Loc.Text("已复制");
            }
            catch { }
        };
        reportCodeRow.Children.Add(reportCodeBox);
        reportCodeRow.Children.Add(copyCodeButton);
        root.Children.Add(reportCodeRow);

        feedbackText = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Visibility = Visibility.Collapsed,
            Margin = new Thickness(0, 0, 0, 10),
        };
        AutomationProperties.SetLiveSetting(feedbackText, AutomationLiveSetting.Polite);
        root.Children.Add(feedbackText);

        previewBox = new TextBox
        {
            IsReadOnly = true,
            AcceptsReturn = true,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            FontFamily = new FontFamily("Consolas"),
            FontSize = 11.5,
            Height = 180,
            Visibility = Visibility.Collapsed,
            Margin = new Thickness(0, 0, 0, 12),
        };
        root.Children.Add(previewBox);

        var actionRow = new WrapPanel { Margin = new Thickness(0, 4, 0, 0) };
        saveZipButton = new Button
        {
            Content = Loc.Text("保存到设备…"),
            Margin = new Thickness(0, 0, 8, 8),
        };
        AutomationProperties.SetAutomationId(saveZipButton, "diagnostics.saveZip");
        saveZipButton.Click += (_, _) => SaveToDevice();

        uploadButton = new Button
        {
            Content = Loc.Text("一键云端上传"),
            Margin = new Thickness(0, 0, 8, 8),
        };
        AutomationProperties.SetAutomationId(uploadButton, "diagnostics.upload");
        uploadButton.Click += async (_, _) => await UploadToCloudAsync();

        previewButton = new Button
        {
            Content = Loc.Text("预览日志"),
            Margin = new Thickness(0, 0, 8, 8),
        };
        AutomationProperties.SetAutomationId(previewButton, "diagnostics.preview");
        previewButton.Click += (_, _) => TogglePreview();

        clearButton = new Button
        {
            Content = Loc.Text("清除日志"),
            Margin = new Thickness(0, 0, 8, 8),
        };
        AutomationProperties.SetAutomationId(clearButton, "diagnostics.clear");
        clearButton.Click += (_, _) =>
        {
            store.ClearAll();
            lastUploadedCode = null;
            reportCodeRow.Visibility = Visibility.Collapsed;
            previewBox.Visibility = Visibility.Collapsed;
            ShowFeedback(Loc.Text("已清除本地诊断日志。"), isError: false);
            RefreshUiState();
        };

        actionRow.Children.Add(saveZipButton);
        actionRow.Children.Add(uploadButton);
        actionRow.Children.Add(previewButton);
        actionRow.Children.Add(clearButton);
        root.Children.Add(actionRow);

        var footer = new WrapPanel
        {
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 12, 0, 0),
        };
        var closeButton = new Button
        {
            Content = Loc.Text("关闭"),
            IsCancel = true,
            IsDefault = true,
        };
        closeButton.Click += (_, _) => Close();
        footer.Children.Add(closeButton);
        root.Children.Add(footer);

        Content = root;
        RefreshUiState();
    }

    private void HandleRecordingChanged(bool enabled)
    {
        if (updatingToggle) return;
        feedbackText.Visibility = Visibility.Collapsed;
        if (enabled)
        {
            lastUploadedCode = null;
            reportCodeRow.Visibility = Visibility.Collapsed;
        }
        store.SetRecordingEnabled(enabled);
        RefreshUiState();
    }

    private void SaveToDevice()
    {
        var dialog = new SaveFileDialog
        {
            Title = Loc.Text("保存到设备…"),
            Filter = "ZIP (*.zip)|*.zip",
            DefaultExt = ".zip",
            FileName = "RawLab-Diagnostics.zip",
        };
        if (dialog.ShowDialog(this) != true) return;
        try
        {
            var pkg = store.BuildReportPackage(noteBox.Text, stopActiveRecording: true);
            pkg.ExportZip(dialog.FileName);
            ShowFeedback(Loc.Text("诊断包已保存，可通过微信、小红书或 Issue 发送给开发者。"), isError: false);
            RefreshUiState();
            try
            {
                Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{dialog.FileName}\"")
                {
                    UseShellExecute = true,
                });
            }
            catch { }
        }
        catch (DiagnosticUploadException ex) when (ex.Reason == DiagnosticUploadFailure.Empty)
        {
            ShowFeedback(Loc.Text("暂无可导出的错误日志。"), isError: true);
            RefreshUiState();
        }
        catch (Exception)
        {
            ShowFeedback(Loc.Text("无法导出诊断包。"), isError: true);
            RefreshUiState();
        }
    }

    private async Task UploadToCloudAsync()
    {
        if (isUploading) return;
        isUploading = true;
        feedbackText.Visibility = Visibility.Collapsed;
        copyCodeButton.Content = Loc.Text("复制诊断码");
        RefreshUiState();
        try
        {
            var note = noteBox.Text;
            var code = await store.UploadAsync(note);
            lastUploadedCode = code;
            reportCodeBox.Text = Loc.Format("诊断码：{0}", code);
            reportCodeRow.Visibility = Visibility.Visible;
            ShowFeedback(Loc.Text("上传成功，请复制诊断码发送给开发者。"), isError: false);
        }
        catch (DiagnosticUploadException ex)
        {
            var msg = ex.Reason switch
            {
                DiagnosticUploadFailure.Empty => Loc.Text("暂无可导出的错误日志。"),
                DiagnosticUploadFailure.PayloadTooLarge => Loc.Text("日志体积超出云端单次上限，请使用「保存到设备」导出诊断包。"),
                _ => Loc.Text("云端上传暂不可用，请先将诊断包保存到设备后发送。"),
            };
            ShowFeedback(msg, isError: true);
        }
        catch (Exception)
        {
            ShowFeedback(Loc.Text("云端上传暂不可用，请先将诊断包保存到设备后发送。"), isError: true);
        }
        finally
        {
            isUploading = false;
            RefreshUiState();
        }
    }

    private void TogglePreview()
    {
        if (previewBox.Visibility == Visibility.Visible)
        {
            previewBox.Visibility = Visibility.Collapsed;
            previewButton.Content = Loc.Text("预览日志");
            return;
        }
        try
        {
            var pkg = store.BuildReportPackage(noteBox.Text, stopActiveRecording: false);
            previewBox.Text = pkg.PreviewText;
            previewBox.Visibility = Visibility.Visible;
            previewButton.Content = Loc.Text("收起预览");
        }
        catch (Exception)
        {
            ShowFeedback(Loc.Text("暂无可导出的错误日志。"), isError: true);
        }
    }

    private void ShowFeedback(string message, bool isError)
    {
        feedbackText.Text = message;
        feedbackText.Foreground = isError ? Brushes.IndianRed : (Brush)FindResource("Muted");
        feedbackText.Visibility = Visibility.Visible;
    }

    private void RefreshUiState()
    {
        var snap = store.GetSnapshot();
        updatingToggle = true;
        recordingToggle.IsChecked = snap.IsRecording;
        updatingToggle = false;

        statusText.Text = snap.IsRecording
            ? Loc.Text("正在记录详细诊断日志（30 分钟或下次重启后自动关闭）。请复现问题后导出或上传。")
            : snap.RecoveredPreviousSession && snap.HasExportableLogs
                ? Loc.Text("检测到上次录制的诊断日志，可直接保存到设备或一键上传。")
                : snap.HasExportableLogs
                    ? Loc.Text("已有可导出的本地诊断记录；详细日志录制当前处于关闭状态。")
                    : Loc.Text("默认关闭。遇到问题时可打开开关复现操作，随后将诊断包保存到设备或一键上传。");

        var canAct = (snap.HasExportableLogs || snap.IsRecording) && !isUploading;
        saveZipButton.IsEnabled = canAct;
        uploadButton.IsEnabled = canAct;
        uploadButton.Content = Loc.Text(isUploading ? "正在上传…" : "一键云端上传");
        previewButton.IsEnabled = snap.HasExportableLogs || snap.IsRecording;
        previewButton.Content = Loc.Text(previewBox.Visibility == Visibility.Visible ? "收起预览" : "预览日志");
        clearButton.Visibility = snap.HasExportableLogs ? Visibility.Visible : Visibility.Collapsed;
        clearButton.IsEnabled = !isUploading;
    }
}
