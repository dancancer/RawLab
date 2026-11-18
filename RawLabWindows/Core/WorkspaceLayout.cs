namespace RawLab.Windows;

internal enum WorkspaceMode { Editing, Selection, Preview }
internal enum LibraryPresentation { Hidden, Docked, Drawer }

internal sealed class WorkspaceLayout
{
    internal const double CompactWidth = 1180;
    internal const double MinimumLibraryWidth = 200;
    internal const double MaximumLibraryWidth = 288;
    internal const double MinimumInspectorWidth = 280;
    internal const double MaximumInspectorWidth = 360;
    internal const double DrawerWidth = 264;

    private WorkspaceMode beforePreview;
    private bool libraryDocked = true;
    private bool inspectorVisible = true;
    private bool drawerOpen;
    private bool drawerBeforePreview;

    internal WorkspaceMode Mode { get; private set; }
    internal double LibraryWidth { get; private set; } = 232;
    internal double InspectorWidth { get; private set; } = 304;
    internal static bool Compact(double width) => width < CompactWidth;
    internal double InspectorWidthAt(double width) => Compact(width) ? MinimumInspectorWidth : InspectorWidth;
    internal bool ShowsInspector(bool hasPhoto) => Mode == WorkspaceMode.Editing && inspectorVisible && hasPhoto;

    internal LibraryPresentation LibraryAt(double width)
    {
        if (Mode == WorkspaceMode.Preview) return LibraryPresentation.Hidden;
        if (Compact(width)) return drawerOpen ? LibraryPresentation.Drawer : LibraryPresentation.Hidden;
        return libraryDocked ? LibraryPresentation.Docked : LibraryPresentation.Hidden;
    }

    internal void ResizeLibrary(double width) =>
        LibraryWidth = Math.Clamp(width, MinimumLibraryWidth, MaximumLibraryWidth);

    internal void ResizeInspector(double width) =>
        InspectorWidth = Math.Clamp(width, MinimumInspectorWidth, MaximumInspectorWidth);

    internal void ToggleLibrary(double width)
    {
        if (Mode == WorkspaceMode.Preview) return;
        if (Compact(width)) drawerOpen = !drawerOpen;
        else libraryDocked = !libraryDocked;
    }

    internal void ToggleInspector() => inspectorVisible = !inspectorVisible;
    internal void ShowInspector() => inspectorVisible = true;

    internal void SetMode(WorkspaceMode mode)
    {
        if (mode == Mode) return;
        if (mode == WorkspaceMode.Preview)
        {
            beforePreview = Mode;
            drawerBeforePreview = drawerOpen;
        }
        drawerOpen = Mode == WorkspaceMode.Preview && mode == beforePreview && drawerBeforePreview;
        Mode = mode;
    }

    internal void WindowResized(double before, double after)
    {
        if (Compact(before) == Compact(after)) return;
        drawerOpen = drawerBeforePreview = false;
    }

    internal void PhotoOpened()
    {
        if (Mode == WorkspaceMode.Selection) SetMode(WorkspaceMode.Editing);
        drawerOpen = drawerBeforePreview = false;
    }

    internal bool DismissTransient()
    {
        if (drawerOpen)
        {
            drawerOpen = false;
            return true;
        }
        if (Mode != WorkspaceMode.Preview) return false;
        SetMode(beforePreview);
        return true;
    }
}
