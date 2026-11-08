using Microsoft.Win32;
using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace RawLab.Windows;

internal sealed class DcpImportOptionsDialog : Window
{
    private readonly bool requiresCurve;
    private readonly bool requiresOmitAutomaticBlack;
    private readonly TextBlock curveName;
    private readonly TextBlock error;
    private readonly CheckBox omitAutomaticBlack;
    private readonly Button import;
    private byte[]? toneCurveJson;

    internal DcpImportOptions Options { get; private set; }

    internal DcpImportOptionsDialog(Window owner, string source, DcpCompileException failure,
        DcpImportOptions? previous = null)
    {
        requiresCurve = failure.Reason == DcpErrorReason.MissingToneCurve;
        requiresOmitAutomaticBlack = failure.Reason == DcpErrorReason.AutomaticBlack;
        toneCurveJson = previous?.ToneCurveJson?.ToArray();
        Options = new(toneCurveJson, previous?.OmitAutomaticBlack == true);

        var root = AdjustmentDialogLayout.Configure(this, owner, "DCP 导入选项", "look.dcp-options");
        var heading = new StackPanel();
        heading.Children.Add(AdjustmentDialogLayout.Text(Path.GetFileName(source)));
        heading.Children.Add(AdjustmentDialogLayout.Text(failure.Message));
        root.Children.Add(heading);

        var body = new StackPanel();
        var scroll = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Grid.SetRow(scroll, 1);
        root.Children.Add(scroll);

        if (failure.Reason == DcpErrorReason.MissingToneCurve || toneCurveJson != null)
        {
            body.Children.Add(AdjustmentDialogLayout.Text(Loc.Text("色调曲线（JSON）")));
            var curveActions = new WrapPanel();
            var choose = AdjustmentDialogLayout.Button("选择曲线文件…", "look.dcp-options.curve", ChooseCurve);
            curveActions.Children.Add(choose);
            curveName = AdjustmentDialogLayout.Text("");
            curveName.VerticalAlignment = VerticalAlignment.Center;
            curveActions.Children.Add(curveName);
            body.Children.Add(curveActions);
            SetCurveName(previous?.ToneCurveJson != null ? Loc.Text("曲线") : "");
        }
        else
        {
            curveName = AdjustmentDialogLayout.Text("");
        }

        omitAutomaticBlack = new CheckBox
        {
            Content = AdjustmentDialogLayout.Text(Loc.Text("省略自动黑位")),
            IsChecked = previous?.OmitAutomaticBlack == true,
            Margin = new Thickness(0, 12, 0, 8)
        };
        AutomationProperties.SetAutomationId(omitAutomaticBlack, "look.dcp-options.omit-black");
        omitAutomaticBlack.Checked += (_, _) => UpdateImportState();
        omitAutomaticBlack.Unchecked += (_, _) => UpdateImportState();
        body.Children.Add(omitAutomaticBlack);

        error = AdjustmentDialogLayout.Text("");
        error.SetResourceReference(TextBlock.ForegroundProperty, "ErrorForeground");
        body.Children.Add(error);

        var actions = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0) };
        var cancel = AdjustmentDialogLayout.Button("取消", "look.dcp-options.cancel", Close);
        cancel.IsCancel = true;
        actions.Children.Add(cancel);
        import = AdjustmentDialogLayout.Button("导入外观", "look.dcp-options.import", Confirm);
        import.IsDefault = true;
        actions.Children.Add(import);
        Grid.SetRow(actions, 2);
        root.Children.Add(actions);
        UpdateImportState();
    }

    private void ChooseCurve()
    {
        var picker = new OpenFileDialog
        {
            Title = Loc.Text("选择曲线文件…"),
            Filter = Loc.Text("RawLab 文件") + "|*.json"
        };
        if (picker.ShowDialog(this) != true) return;
        try
        {
            toneCurveJson = DcpCompiler.ReadToneCurveJson(picker.FileName);
            SetCurveName(Path.GetFileName(picker.FileName));
            error.Text = "";
        }
        catch (Exception failure)
        {
            toneCurveJson = null;
            SetCurveName("");
            error.Text = failure.Message;
        }
        UpdateImportState();
    }

    private void SetCurveName(string value) => curveName.Text = value;

    private void UpdateImportState()
    {
        import.IsEnabled = (!requiresCurve || toneCurveJson is { Length: > 0 }) &&
            (!requiresOmitAutomaticBlack || omitAutomaticBlack.IsChecked == true);
    }

    private void Confirm()
    {
        Options = new(toneCurveJson, omitAutomaticBlack.IsChecked == true);
        DialogResult = true;
    }
}
