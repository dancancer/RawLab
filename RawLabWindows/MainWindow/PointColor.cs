using System.Windows;

namespace RawLab.Windows;

public partial class MainWindow
{
    private bool pointColorProbeEnabled;
    private string? pointColorProbeNotice;

    private bool CanUsePointColorProbe =>
        file != null && !settings.IsHDREditing && !closing && !exporting && !transform.Active &&
        result?.Image != null &&
        settings.PointColor.Swatches.Count < AdjustmentFieldSpec.SubFields.PointColor.MaxSwatches;

    private void InitializePointColorProbe()
    {
        PointColorEditor.EyedropperToggled += SetPointColorProbeMode;
        ResultCanvas.PointColorProbeClicked += SamplePointColorAt;
        ResultCanvas.PointColorProbeCancelled += CancelPointColorProbe;
        ResultCanvas.PointColorProbeRejected += () =>
        {
            pointColorProbeNotice = Loc.Text("请在调整后的照片区域取色。");
            RefreshPointColorPanel();
        };
    }

    private void SetPointColorProbeMode(bool enabled)
    {
        if (enabled)
        {
            CancelHslTarget();
            CancelCurveTarget();
            CancelWbProbe();
        }
        pointColorProbeEnabled = enabled && CanUsePointColorProbe;
        if (!pointColorProbeEnabled)
        {
            pointColorProbeNotice = null;
        }
        else
        {
            EndHoldingBefore();
            inspection.PinModeEnabled = false;
            RefreshInspection();
            pointColorProbeNotice = Loc.Text("吸管取样");
        }
        RefreshPointColorPanel();
    }

    private void CancelPointColorProbe()
    {
        if (!pointColorProbeEnabled && pointColorProbeNotice == null && !ResultCanvas.PointColorProbeEnabled) return;
        SetPointColorProbeMode(false);
    }

    private void RefreshPointColorPanel()
    {
        ResultCanvas.PointColorProbeEnabled = ShowsInspector && pointColorProbeEnabled &&
            toolMode == EditorToolMode.PointColor && expandedGroup != null &&
            !transform.Active && CanUsePointColorProbe;
        if (toolMode == EditorToolMode.PointColor)
        {
            PointColorEditor.Refresh(
                settings.PointColor,
                (file, openRevision, settings.IsHDREditing),
                eyedropperEnabled: pointColorProbeEnabled && CanUsePointColorProbe,
                eyedropperAvailable: CanUsePointColorProbe,
                notice: pointColorProbeNotice);
        }
    }

    private void SamplePointColorAt(Point normPoint)
    {
        if (!pointColorProbeEnabled || !ResultCanvas.PointColorProbeEnabled || file == null ||
            closing || exporting || transform.Active || renderFailed ||
            result?.Image is not { } bitmap)
        {
            pointColorProbeNotice = Loc.Text("预览已变化，请重新取色。");
            RefreshPointColorPanel();
            return;
        }
        if (settings.PointColor.Swatches.Count >= AdjustmentFieldSpec.SubFields.PointColor.MaxSwatches)
        {
            pointColorProbeEnabled = false;
            pointColorProbeNotice = null;
            RefreshPointColorPanel();
            return;
        }
        var sample = InspectionOverlayRenderer.SampleBitmap(bitmap, normPoint.X, normPoint.Y);
        if (sample is not { } s)
        {
            pointColorProbeNotice = Loc.Text("此像素不可取样。");
            RefreshPointColorPanel();
            return;
        }
        var swatch = InspectionNative.SwatchFromSample(s);
        var updated = settings.PointColor.Swatches.ToList();
        updated.Add(swatch);
        pointColorProbeEnabled = false;
        pointColorProbeNotice = null;
        settings.PointColor = new PointColorSettings(updated);
        interacting = false;
        MarkEdited();
        RefreshControls();
        PointColorEditor.SelectSwatch(updated.Count - 1);
        Schedule();
    }
}
