using RawLab.Windows;
using Xunit;

namespace RawLab.Windows.Tests;

public sealed class CanvasProbeCoordinatorTests
{
    private static readonly CanvasProbeMode[] AllColorProbes =
    [
        CanvasProbeMode.HslTarget,
        CanvasProbeMode.CurveTarget,
        CanvasProbeMode.WhiteBalance,
        CanvasProbeMode.PointColor
    ];

    private static void AssertExactlyActive(CanvasProbeCoordinator coordinator, CanvasProbeMode expected)
    {
        Assert.Equal(expected, coordinator.ActiveMode);
        Assert.Equal(expected != CanvasProbeMode.None, coordinator.AnyActive);
        Assert.Equal(expected == CanvasProbeMode.HslTarget, coordinator.IsHslTarget);
        Assert.Equal(expected == CanvasProbeMode.CurveTarget, coordinator.IsCurveTarget);
        Assert.Equal(expected == CanvasProbeMode.WhiteBalance, coordinator.IsWhiteBalance);
        Assert.Equal(expected == CanvasProbeMode.PointColor, coordinator.IsPointColor);
    }

    [Fact]
    [Trait("Category", "Model")]
    public void InitialStateIsNoneAndDoesNotBlockBeforeHold()
    {
        var coordinator = new CanvasProbeCoordinator();
        AssertExactlyActive(coordinator, CanvasProbeMode.None);
        Assert.False(coordinator.BlocksBeforeHold);
        Assert.False(coordinator.ExitsOnInputCancel);
    }

    [Fact]
    [Trait("Category", "Model")]
    public void ActivatingAnyModeExclusivelyDeactivatesPreviousMode()
    {
        var coordinator = new CanvasProbeCoordinator();

        foreach (var first in AllColorProbes)
        {
            foreach (var second in AllColorProbes)
            {
                if (first == second) continue;

                coordinator.CancelAll();

                var enterFirst = coordinator.Activate(first);
                Assert.True(enterFirst.Changed);
                Assert.Equal(CanvasProbeMode.None, enterFirst.PreviousMode);
                Assert.Equal(first, enterFirst.ActiveMode);
                AssertExactlyActive(coordinator, first);

                var repeatFirst = coordinator.Activate(first);
                Assert.False(repeatFirst.Changed);
                Assert.Equal(first, repeatFirst.PreviousMode);
                Assert.Equal(first, repeatFirst.ActiveMode);

                var switchToSecond = coordinator.Activate(second);
                Assert.True(switchToSecond.Changed);
                Assert.Equal(first, switchToSecond.PreviousMode);
                Assert.Equal(second, switchToSecond.ActiveMode);
                AssertExactlyActive(coordinator, second);
            }
        }

        Assert.Throws<ArgumentOutOfRangeException>(() => coordinator.Activate((CanvasProbeMode)99));
    }

    [Fact]
    [Trait("Category", "Model")]
    public void DeactivateOnlyClearsMatchingMode()
    {
        var coordinator = new CanvasProbeCoordinator();
        coordinator.Activate(CanvasProbeMode.CurveTarget);

        var mismatch = coordinator.Deactivate(CanvasProbeMode.HslTarget);
        Assert.False(mismatch.Changed);
        Assert.Equal(CanvasProbeMode.CurveTarget, mismatch.PreviousMode);
        Assert.Equal(CanvasProbeMode.CurveTarget, mismatch.ActiveMode);
        AssertExactlyActive(coordinator, CanvasProbeMode.CurveTarget);

        var none = coordinator.Deactivate(CanvasProbeMode.None);
        Assert.False(none.Changed);

        var matched = coordinator.Deactivate(CanvasProbeMode.CurveTarget);
        Assert.True(matched.Changed);
        Assert.Equal(CanvasProbeMode.CurveTarget, matched.PreviousMode);
        Assert.Equal(CanvasProbeMode.None, matched.ActiveMode);
        AssertExactlyActive(coordinator, CanvasProbeMode.None);

        Assert.Throws<ArgumentOutOfRangeException>(() => coordinator.Deactivate((CanvasProbeMode)99));
    }

    [Fact]
    [Trait("Category", "Model")]
    public void BlocksBeforeHoldCoversAllFourColorProbes()
    {
        var coordinator = new CanvasProbeCoordinator();
        Assert.False(coordinator.BlocksBeforeHold);

        foreach (var mode in AllColorProbes)
        {
            coordinator.Activate(mode);
            Assert.True(coordinator.BlocksBeforeHold);
        }

        coordinator.CancelAll();
        Assert.False(coordinator.BlocksBeforeHold);
    }

    [Fact]
    [Trait("Category", "Model")]
    public void CancelTransientDeactivatesWhiteBalanceAndPointColorButKeepsTargetModes()
    {
        var coordinator = new CanvasProbeCoordinator();

        var idle = coordinator.CancelTransient();
        Assert.False(idle.Changed);
        Assert.Equal(CanvasProbeMode.None, idle.ActiveMode);

        // 窗口失活等瞬时取消必须退出白平衡与点颜色吸管。
        foreach (var eyedropper in new[] { CanvasProbeMode.WhiteBalance, CanvasProbeMode.PointColor })
        {
            coordinator.Activate(eyedropper);
            Assert.True(coordinator.ExitsOnInputCancel);

            var transition = coordinator.CancelTransient();
            Assert.True(transition.Changed);
            Assert.Equal(eyedropper, transition.PreviousMode);
            Assert.Equal(CanvasProbeMode.None, transition.ActiveMode);
            AssertExactlyActive(coordinator, CanvasProbeMode.None);
        }

        // HSL 与曲线目标调整保持模式开启，仅由宿主取消在途拖动/采样。
        foreach (var target in new[] { CanvasProbeMode.HslTarget, CanvasProbeMode.CurveTarget })
        {
            coordinator.Activate(target);
            Assert.False(coordinator.ExitsOnInputCancel);

            var transition = coordinator.CancelTransient();
            Assert.False(transition.Changed);
            Assert.Equal(target, transition.PreviousMode);
            Assert.Equal(target, transition.ActiveMode);
            AssertExactlyActive(coordinator, target);
        }
    }

    [Fact]
    [Trait("Category", "Model")]
    public void CancelAllDeactivatesEveryColorProbe()
    {
        var coordinator = new CanvasProbeCoordinator();

        foreach (var mode in AllColorProbes)
        {
            coordinator.Activate(mode);

            var transition = coordinator.CancelAll();
            Assert.True(transition.Changed);
            Assert.Equal(mode, transition.PreviousMode);
            Assert.Equal(CanvasProbeMode.None, transition.ActiveMode);
            AssertExactlyActive(coordinator, CanvasProbeMode.None);

            var repeat = coordinator.CancelAll();
            Assert.False(repeat.Changed);
        }
    }

    [Fact]
    [Trait("Category", "Model")]
    public void DeactivateForToolPreservesMatchingProbeAndCancelsOthers()
    {
        var coordinator = new CanvasProbeCoordinator();
        var pairs = new[]
        {
            (CanvasProbeMode.HslTarget, EditorAdjustmentTool.Hsl),
            (CanvasProbeMode.CurveTarget, EditorAdjustmentTool.ToneCurve),
            (CanvasProbeMode.WhiteBalance, EditorAdjustmentTool.WhiteBalance),
            (CanvasProbeMode.PointColor, EditorAdjustmentTool.PointColor),
        };

        foreach (var (mode, matchingTool) in pairs)
        {
            Assert.Equal(mode, CanvasProbeCoordinator.ModeForTool(matchingTool));

            coordinator.Activate(mode);

            var kept = coordinator.DeactivateForTool(matchingTool);
            Assert.False(kept.Changed);
            Assert.Equal(mode, kept.ActiveMode);

            var cleared = coordinator.DeactivateForTool(EditorAdjustmentTool.Exposure);
            Assert.True(cleared.Changed);
            Assert.Equal(mode, cleared.PreviousMode);
            Assert.Equal(CanvasProbeMode.None, cleared.ActiveMode);
        }

        Assert.Equal(CanvasProbeMode.None, CanvasProbeCoordinator.ModeForTool(EditorAdjustmentTool.Exposure));
    }

    [Fact]
    [Trait("Category", "Model")]
    public void TryConsumeEscapeConsumesActiveColorProbeAndFallsThroughWhenNone()
    {
        var coordinator = new CanvasProbeCoordinator();

        Assert.False(coordinator.TryConsumeEscape(out var idle));
        Assert.False(idle.Changed);
        Assert.Equal(CanvasProbeMode.None, idle.ActiveMode);

        foreach (var mode in AllColorProbes)
        {
            coordinator.Activate(mode);

            Assert.True(coordinator.TryConsumeEscape(out var transition));
            Assert.True(transition.Changed);
            Assert.Equal(mode, transition.PreviousMode);
            Assert.Equal(CanvasProbeMode.None, transition.ActiveMode);
            AssertExactlyActive(coordinator, CanvasProbeMode.None);

            Assert.False(coordinator.TryConsumeEscape(out var after));
            Assert.False(after.Changed);
        }
    }
}
