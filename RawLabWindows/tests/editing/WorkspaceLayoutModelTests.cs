using RawLab.Windows;
using Xunit;

namespace RawLab.Windows.Tests;

public sealed class WorkspaceLayoutModelTests
{
    [Fact]
    [Trait("Category", "Model")]
    public void BreakpointsLibraryDrawerAndInspectorPoliciesWork()
    {
        var layout = new WorkspaceLayout();
        Assert.False(WorkspaceLayout.Compact(WorkspaceLayout.CompactWidth));
        Assert.True(WorkspaceLayout.Compact(WorkspaceLayout.CompactWidth - 1));
        Assert.Equal(LibraryPresentation.Docked, layout.LibraryAt(WorkspaceLayout.CompactWidth));
        Assert.Equal(LibraryPresentation.Hidden, layout.LibraryAt(WorkspaceLayout.CompactWidth - 1));

        layout.ResizeLibrary(10);
        Assert.Equal(WorkspaceLayout.MinimumLibraryWidth, layout.LibraryWidth);
        layout.ResizeLibrary(999);
        Assert.Equal(WorkspaceLayout.MaximumLibraryWidth, layout.LibraryWidth);

        layout.ResizeInspector(10);
        Assert.Equal(WorkspaceLayout.MinimumInspectorWidth, layout.InspectorWidth);
        layout.ResizeInspector(999);
        Assert.Equal(WorkspaceLayout.MaximumInspectorWidth, layout.InspectorWidth);
        Assert.Equal(WorkspaceLayout.MinimumInspectorWidth, layout.InspectorWidthAt(1000));
        Assert.Equal(WorkspaceLayout.MaximumInspectorWidth, layout.InspectorWidthAt(1440));

        Assert.False(layout.ShowsInspector(false));
        Assert.True(layout.ShowsInspector(true));

        layout.ToggleLibrary(1000);
        Assert.Equal(LibraryPresentation.Drawer, layout.LibraryAt(1000));
        layout.SetMode(WorkspaceMode.Preview);
        Assert.Equal(LibraryPresentation.Hidden, layout.LibraryAt(1440));
        Assert.False(layout.ShowsInspector(true));
        Assert.True(layout.DismissTransient());
        Assert.Equal(WorkspaceMode.Editing, layout.Mode);
        Assert.Equal(LibraryPresentation.Drawer, layout.LibraryAt(1000));
        Assert.True(layout.DismissTransient());
        Assert.Equal(LibraryPresentation.Hidden, layout.LibraryAt(1000));

        layout.ToggleLibrary(1440);
        Assert.Equal(LibraryPresentation.Hidden, layout.LibraryAt(1440));
        layout.SetMode(WorkspaceMode.Selection);
        layout.PhotoOpened();
        Assert.Equal(WorkspaceMode.Editing, layout.Mode);

        layout.ToggleLibrary(1000);
        layout.WindowResized(1000, 1300);
        Assert.Equal(LibraryPresentation.Hidden, layout.LibraryAt(1000));
    }

    [Fact]
    [Trait("Category", "Model")]
    public void ComparisonPlacementAndMarginPoliciesWork()
    {
        var off = WorkspaceLayout.ComparisonLayout(true, false, false, 1200, 800);
        Assert.False(off.SideBySide);
        Assert.False(off.ShowsNeutralCanvas);
        Assert.False(off.ShowWipeOverlay);
        Assert.Equal(0, off.NeutralColumn);

        var horizontal = WorkspaceLayout.ComparisonLayout(true, true, false, 1000, 700);
        Assert.True(horizontal.SideBySide);
        Assert.False(horizontal.StackedVertically);
        Assert.Equal(1, horizontal.NeutralRow);
        Assert.Equal(0, horizontal.NeutralColumn);
        Assert.Equal(1, horizontal.ResultRow);

        var vertical = WorkspaceLayout.ComparisonLayout(true, true, false, 700, 1000);
        Assert.True(vertical.SideBySide);
        Assert.True(vertical.StackedVertically);
        Assert.Equal(0, vertical.NeutralRow);
        Assert.Equal(1, vertical.NeutralColumn);
        Assert.Equal(1, vertical.ResultRow);

        var wipe = WorkspaceLayout.ComparisonLayout(true, true, true, 700, 1000);
        Assert.False(wipe.SideBySide);
        Assert.True(wipe.ShowWipeOverlay);

        var noFile = WorkspaceLayout.ComparisonLayout(false, true, true, 700, 1000);
        Assert.False(noFile.ShowsNeutralCanvas);
        Assert.False(noFile.ShowWipeOverlay);

        Assert.Equal(WorkspaceLayout.PhotoMarginInset, WorkspaceLayout.ContentCanvasMargin(true));
        Assert.Equal(0, WorkspaceLayout.ContentCanvasMargin(false));
        Assert.Equal(160, WorkspaceLayout.MinimumCanvasHeight);
    }

    [Fact]
    [Trait("Category", "Model")]
    public void CropHitTestAndNormalizedViewportProjectionWork()
    {
        var empty = PhotoViewProjection.Project(0, 100, 200, 100, 1, 0.5, 0.5);
        Assert.Equal(default, empty);

        var fitted = PhotoViewProjection.Project(200, 100, 400, 200, 1, 0.5, 0.5, WorkspaceLayout.ContentCanvasMargin(true));
        Assert.Equal(new ViewRectangle(32, 16, 136, 68), fitted);

        Assert.Null(CropInteraction.HitTest(10, 20, 0, 50, 10, 20));
        Assert.Equal(CropHandle.TopLeft, CropInteraction.HitTest(100, 50, 200, 100, 108, 56));
        Assert.Equal(CropHandle.BottomRight, CropInteraction.HitTest(100, 50, 200, 100, 295, 148));
        Assert.Equal(CropHandle.Right, CropInteraction.HitTest(100, 50, 200, 100, 300, 100));
        Assert.Equal(CropHandle.Move, CropInteraction.HitTest(100, 50, 200, 100, 200, 100));
        Assert.Null(CropInteraction.HitTest(100, 50, 200, 100, 80, 100));

        var ratio = CropInteraction.Ratio(CropAspectPreset.ThreeTwo, 6000, 4000, swapped: true);
        Assert.Equal(2.0 / 3.0, ratio!.Value, 6);
        var moved = CropInteraction.Dragging(new CropRect(0.2, 0.2, 0.5, 0.5), CropHandle.Move, 0.8, 0.8, 1000, 800, null);
        Assert.Equal(new CropRect(0.5, 0.5, 0.5, 0.5), moved);
    }
}
