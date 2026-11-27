namespace RawLab.Windows;

internal enum CanvasProbeMode
{
    None,
    HslTarget,
    CurveTarget,
    WhiteBalance,
    PointColor
}

internal readonly record struct CanvasProbeTransition(
    CanvasProbeMode PreviousMode,
    CanvasProbeMode ActiveMode,
    bool Changed);

// 单一真源管理 MainWindow 四路互斥画布取色/目标调整模式；
// 取样监视的 Pin 模式继续由 InspectionSessionState 独占，不做双向镜像。
internal sealed class CanvasProbeCoordinator
{
    private CanvasProbeMode activeMode = CanvasProbeMode.None;

    internal CanvasProbeMode ActiveMode => activeMode;

    internal bool IsHslTarget => activeMode == CanvasProbeMode.HslTarget;
    internal bool IsCurveTarget => activeMode == CanvasProbeMode.CurveTarget;
    internal bool IsWhiteBalance => activeMode == CanvasProbeMode.WhiteBalance;
    internal bool IsPointColor => activeMode == CanvasProbeMode.PointColor;
    internal bool AnyActive => activeMode != CanvasProbeMode.None;

    // 任意画布取色或目标拖动模式激活时，均阻止按住“查看调整前”，与 macOS 客户端一致。
    internal bool BlocksBeforeHold => activeMode is
        CanvasProbeMode.HslTarget or
        CanvasProbeMode.CurveTarget or
        CanvasProbeMode.WhiteBalance or
        CanvasProbeMode.PointColor;

    // 白平衡与点颜色吸管是一次性取色模式，在窗口失活、切图、缩放或取消参数输入时直接退出；
    // HSL 与曲线目标调整是持久拖动模式，这些场景仅取消在途拖动/采样，保持模式开启。
    internal bool ExitsOnInputCancel => activeMode is
        CanvasProbeMode.WhiteBalance or
        CanvasProbeMode.PointColor;

    internal static CanvasProbeMode ModeForTool(EditorAdjustmentTool tool) => tool switch
    {
        EditorAdjustmentTool.Hsl => CanvasProbeMode.HslTarget,
        EditorAdjustmentTool.ToneCurve => CanvasProbeMode.CurveTarget,
        EditorAdjustmentTool.WhiteBalance => CanvasProbeMode.WhiteBalance,
        EditorAdjustmentTool.PointColor => CanvasProbeMode.PointColor,
        _ => CanvasProbeMode.None
    };

    internal CanvasProbeTransition Activate(CanvasProbeMode mode)
    {
        if (!Enum.IsDefined(mode)) throw new ArgumentOutOfRangeException(nameof(mode));
        var previous = activeMode;
        if (previous == mode)
            return new(previous, activeMode, Changed: false);
        activeMode = mode;
        return new(previous, activeMode, Changed: true);
    }

    internal CanvasProbeTransition Deactivate(CanvasProbeMode mode)
    {
        if (!Enum.IsDefined(mode)) throw new ArgumentOutOfRangeException(nameof(mode));
        if (mode == CanvasProbeMode.None || activeMode != mode)
            return new(activeMode, activeMode, Changed: false);
        var previous = activeMode;
        activeMode = CanvasProbeMode.None;
        return new(previous, activeMode, Changed: true);
    }

    internal CanvasProbeTransition CancelAll() => Activate(CanvasProbeMode.None);

    internal CanvasProbeTransition CancelTransient() =>
        ExitsOnInputCancel
            ? Activate(CanvasProbeMode.None)
            : new(activeMode, activeMode, Changed: false);

    internal CanvasProbeTransition DeactivateForTool(EditorAdjustmentTool tool)
    {
        var allowed = ModeForTool(tool);
        return activeMode != CanvasProbeMode.None && activeMode != allowed
            ? Activate(CanvasProbeMode.None)
            : new(activeMode, activeMode, Changed: false);
    }

    // Esc 优先退出当前激活的四路画布探测之一；未激活时返回 false，交由后续链路（含 InspectionSessionState）处理。
    internal bool TryConsumeEscape(out CanvasProbeTransition transition)
    {
        if (activeMode == CanvasProbeMode.None)
        {
            transition = new(CanvasProbeMode.None, CanvasProbeMode.None, Changed: false);
            return false;
        }
        transition = Activate(CanvasProbeMode.None);
        return true;
    }
}
