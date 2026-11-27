namespace RawLab.Windows;

public partial class MainWindow
{
    private readonly CanvasProbeCoordinator canvasProbes = new();

    private void ActivateCanvasProbe(CanvasProbeMode mode)
    {
        var transition = canvasProbes.Activate(mode);
        if (transition.Changed && transition.PreviousMode != CanvasProbeMode.None)
            CleanupDeactivatedProbe(transition.PreviousMode);
        EndHoldingBefore();
        inspection.PinModeEnabled = false;
        RefreshInspection();
    }

    private void CancelAllCanvasProbes(bool includeInspectionPin = false)
    {
        var transition = canvasProbes.CancelAll();
        if (transition.Changed)
            CleanupDeactivatedProbe(transition.PreviousMode);
        if (includeInspectionPin && inspection.PinModeEnabled)
        {
            inspection.PinModeEnabled = false;
            RefreshInspection();
        }
    }

    private void CancelCanvasProbeInputs()
    {
        var transition = canvasProbes.CancelTransient();
        if (transition.Changed)
        {
            CleanupDeactivatedProbe(transition.PreviousMode);
            return;
        }
        switch (canvasProbes.ActiveMode)
        {
            case CanvasProbeMode.HslTarget:
                CancelHslTarget();
                break;
            case CanvasProbeMode.CurveTarget:
                CancelCurveTarget();
                break;
        }
    }

    private void DeactivateCanvasProbeForTool(EditorAdjustmentTool tool)
    {
        var transition = canvasProbes.DeactivateForTool(tool);
        if (transition.Changed)
            CleanupDeactivatedProbe(transition.PreviousMode);
    }

    private bool TryHandleCanvasProbeEscape()
    {
        if (!canvasProbes.TryConsumeEscape(out var transition)) return false;
        CleanupDeactivatedProbe(transition.PreviousMode);
        return true;
    }

    private void CleanupDeactivatedProbe(CanvasProbeMode mode)
    {
        switch (mode)
        {
            case CanvasProbeMode.HslTarget:
                CancelHslTarget();
                break;
            case CanvasProbeMode.CurveTarget:
                CancelCurveTarget();
                break;
            case CanvasProbeMode.WhiteBalance:
                ResetWbProbeState();
                RefreshWbProbe();
                break;
            case CanvasProbeMode.PointColor:
                pointColorProbeNotice = null;
                RefreshPointColorPanel();
                break;
        }
    }
}
