using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;

namespace RawLab.Windows;

public partial class MainWindow
{
    private void RefreshUnavailableToolReasons()
    {
        var hdr=settings.IsHDREditing;
        var raster=file!=null && LibraryEntry.IsRaster(file);
        foreach(var button in Tools.Children.OfType<Button>()) {
            string? reason=null;
            if(file!=null && !exporting) {
                if(hdr && !button.IsEnabled)reason="HDR 模式暂不支持此工具。";
                else if(ReferenceEquals(button,LensCategory) && PhotoInput.IsNormalX3f(file,settings))reason="此输入不支持镜头校正";
                else if(ReferenceEquals(button,LensCategory) && raster)reason="仅 RAW 照片支持镜头校正。";
                else if(ReferenceEquals(button,WhiteBalanceCategory) && !hdr && settings.AsShot==null)reason="此照片没有可用的相机白平衡校准。";
            }
            AutomationProperties.SetHelpText(button,reason==null ? "" : Loc.Text(reason));
            ToolTipService.SetShowOnDisabled(button,true);
            if(reason!=null)button.ToolTip=Loc.Text(reason);
            else if(ReferenceEquals(button,GeometryCategory))button.SetResourceReference(ToolTipProperty,"裁切、旋转、翻转和拉直");
            else if(ReferenceEquals(button,LensCategory))button.SetResourceReference(ToolTipProperty,"镜头匹配");
            else if(ReferenceEquals(button,FilmCategory))button.SetResourceReference(ToolTipProperty,"选择胶片模拟");
            else if(ReferenceEquals(button,MasterRecipeCategory))button.SetResourceReference(ToolTipProperty,"选择大师配方");
            else button.ToolTip=AutomationProperties.GetName(button);
        }
    }
    private readonly WorkspaceLayout workspaceLayout = new();
    private string workspaceWidthsPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RawLab", "workspace-widths.json");
    private sealed record WorkspaceWidths(double Library, double Inspector);
    private (EditorAdjustmentTool Tool, bool Perspective)? suspendedTransform;
    private bool histogramExpanded = true;

    private void InitializeWorkspace()
    {
        try
        {
            var widths = AtomicJson.Read<WorkspaceWidths>(workspaceWidthsPath);
            if (double.IsFinite(widths.Library)) workspaceLayout.ResizeLibrary(widths.Library);
            if (double.IsFinite(widths.Inspector)) workspaceLayout.ResizeInspector(widths.Inspector);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { }

        InitializeWorkspaceBrowser();
        EditorShell.SizeChanged += (_, e) => {
            workspaceLayout.WindowResized(e.PreviousSize.Width, e.NewSize.Width);
            RefreshWorkspace();
        };
        LibrarySplitter.DragCompleted += (_, e) => { if (!e.Canceled) SaveWorkspaceWidth(libraryPane: true); };
        AdjustmentSplitter.DragCompleted += (_, e) => { if (!e.Canceled) SaveWorkspaceWidth(libraryPane: false); };
        LibrarySplitter.KeyUp += (_, e) => { if (e.Key is Key.Left or Key.Right) SaveWorkspaceWidth(libraryPane: true); };
        AdjustmentSplitter.KeyUp += (_, e) => { if (e.Key is Key.Left or Key.Right) SaveWorkspaceWidth(libraryPane: false); };
        WorkspaceBody.SizeChanged += (_, _) => RefreshHistogramWorkspace();
        DockHeader.SizeChanged += (_, _) => RefreshHistogramWorkspace();
        HistogramPopup.Closed += (_, _) => RefreshStateToolTips();
        Loaded += (_, _) => RefreshWorkspace();
        RefreshWorkspace();
    }

    private void SaveWorkspaceWidth(bool libraryPane)
    {
        if (WorkspaceLayout.Compact(WorkspaceWidth)) return;
        if (libraryPane) workspaceLayout.ResizeLibrary(LibraryColumn.Width.Value);
        else workspaceLayout.ResizeInspector(InspectorColumn.Width.Value);
        try { AtomicJson.Write(workspaceWidthsPath, new WorkspaceWidths(workspaceLayout.LibraryWidth, workspaceLayout.InspectorWidth)); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    private double WorkspaceWidth => EditorShell.ActualWidth > 0 ? EditorShell.ActualWidth : Width;
    private bool ShowsPhotoWorkspace => workspaceLayout.Mode != WorkspaceMode.Selection;
    private bool ShowsInspector => workspaceLayout.ShowsInspector(file != null);

    private void RefreshWorkspace()
    {
        var width = WorkspaceWidth;
        var presentation = workspaceLayout.LibraryAt(width);
        var docked = presentation == LibraryPresentation.Docked;
        var drawer = presentation == LibraryPresentation.Drawer;
        var showInspector = ShowsInspector;
        if (drawer && LibraryDrawer.Child == null)
        {
            LibraryDock.Child = null;
            LibraryDrawer.Child = LibraryPanel;
        }
        else if (!drawer && LibraryDock.Child == null)
        {
            LibraryDrawer.Child = null;
            LibraryDock.Child = LibraryPanel;
        }
        LibraryPanel.Visibility = docked || drawer ? Visibility.Visible : Visibility.Collapsed;
        LibraryOverlay.Visibility = drawer ? Visibility.Visible : Visibility.Collapsed;
        LibrarySplitter.Visibility = docked ? Visibility.Visible : Visibility.Collapsed;
        LibraryColumn.MinWidth = docked ? WorkspaceLayout.MinimumLibraryWidth : 0;
        LibraryColumn.Width = new(docked ? workspaceLayout.LibraryWidth : 0);
        LibrarySplitterColumn.Width = new(docked ? 5 : 0);

        AdjustmentPanel.Visibility = showInspector ? Visibility.Visible : Visibility.Collapsed;
        var canResizeInspector = showInspector && !WorkspaceLayout.Compact(width);
        AdjustmentSplitter.Visibility = canResizeInspector ? Visibility.Visible : Visibility.Collapsed;
        InspectorColumn.MinWidth = showInspector ? WorkspaceLayout.MinimumInspectorWidth : 0;
        InspectorColumn.Width = new(showInspector ? workspaceLayout.InspectorWidthAt(width) : 0);
        InspectorSplitterColumn.Width = new(canResizeInspector ? 5 : 0);

        PhotoArea.Visibility = ShowsPhotoWorkspace ? Visibility.Visible : Visibility.Collapsed;
        SelectionWorkspace.Visibility = ShowsPhotoWorkspace ? Visibility.Collapsed : Visibility.Visible;
        EditingWorkspaceButton.Tag = workspaceLayout.Mode == WorkspaceMode.Editing ? "selected" : null;
        SelectionWorkspaceButton.Tag = workspaceLayout.Mode == WorkspaceMode.Selection ? "selected" : null;
        PreviewWorkspaceButton.Tag = workspaceLayout.Mode == WorkspaceMode.Preview ? "selected" : null;
        RefreshWorkspaceAvailability();
        RefreshHistogramWorkspace();
        RefreshWorkspaceBrowserLayout();
        RefreshHDRPresentation();
    }

    private void RefreshWorkspaceAvailability()
    {
        var canSwitch = !closing && !exporting && !UpdateInstallationActive && pendingAllReset == null;
        EditingWorkspaceButton.IsEnabled = SelectionWorkspaceButton.IsEnabled = canSwitch;
        PreviewWorkspaceButton.IsEnabled = canSwitch && result != null;
        LibraryToggleButton.IsEnabled = canSwitch && workspaceLayout.Mode != WorkspaceMode.Preview;
        AdjustToggleButton.IsEnabled = canSwitch && workspaceLayout.Mode == WorkspaceMode.Editing && file != null;
        LibraryToggleButton.Tag = LibraryPanel.Visibility == Visibility.Visible ? "selected" : null;
        AdjustToggleButton.Tag = ShowsInspector ? "selected" : null;
        RefreshSelectionCount();
        foreach (var button in new[] { EditingWorkspaceButton, SelectionWorkspaceButton, PreviewWorkspaceButton })
            AutomationProperties.SetItemStatus(button, Equals(button.Tag, "selected") ? Loc.Text("已选") : "");
        AutomationProperties.SetItemStatus(LibraryToggleButton, LibraryPanel.Visibility == Visibility.Visible ? Loc.Text("已展开") : Loc.Text("已收起"));
        AutomationProperties.SetItemStatus(AdjustToggleButton, ShowsInspector ? Loc.Text("已展开") : Loc.Text("已收起"));
    }

    private void WorkspaceModeClicked(object sender, RoutedEventArgs e)
    {
        var mode = ReferenceEquals(sender, SelectionWorkspaceButton) ? WorkspaceMode.Selection :
            ReferenceEquals(sender, PreviewWorkspaceButton) ? WorkspaceMode.Preview : WorkspaceMode.Editing;
        SwitchWorkspace(mode);
    }

    private void SwitchWorkspace(WorkspaceMode mode)
    {
        if (mode == workspaceLayout.Mode || closing || exporting || UpdateInstallationActive || pendingAllReset != null ||
            (mode == WorkspaceMode.Preview && result == null)) return;
        if (workspaceLayout.Mode == WorkspaceMode.Editing && !SuspendInspectorTool()) return;
        if (mode != WorkspaceMode.Editing && hslTargetEnabled) SetHslTargetMode(false, hslTargetAxis);
        CancelViewingInput();
        HistogramPopup.IsOpen = ProcessingPopup.IsOpen = false;
        workspaceLayout.SetMode(mode);
        RefreshWorkspace();
        RestoreInspectorTool();
        RefreshControls();
    }

    private bool SuspendInspectorTool()
    {
        var suspended = transform.Active ? (CurrentTool, GeometryEditor.ShowPerspective) : ((EditorAdjustmentTool, bool)?)null;
        CancelParameterInputs();
        if (!ResolveTransformDraft()) return false;
        CloseQuickPresets();
        suspendedTransform ??= suspended;
        return true;
    }

    private void RestoreInspectorTool()
    {
        if (!ShowsInspector || suspendedTransform is not { } suspended) return;
        suspendedTransform = null;
        SelectTool(suspended.Tool);
        if (choosingGeometry) GeometryEditor.ShowPerspective = suspended.Perspective;
    }

    private void LibraryToggle(object sender, RoutedEventArgs e)
    {
        if (exporting || closing || UpdateInstallationActive) return;
        workspaceLayout.ToggleLibrary(WorkspaceWidth);
        RefreshWorkspace();
    }

    private void DismissLibraryDrawer(object sender, RoutedEventArgs e)
    {
        if (workspaceLayout.LibraryAt(WorkspaceWidth) != LibraryPresentation.Drawer) return;
        workspaceLayout.DismissTransient();
        RefreshWorkspace();
        LibraryToggleButton.Focus();
    }

    private bool DismissWorkspaceTransient()
    {
        var wasDrawer = workspaceLayout.LibraryAt(WorkspaceWidth) == LibraryPresentation.Drawer;
        if (!workspaceLayout.DismissTransient()) return false;
        RefreshWorkspace();
        RestoreInspectorTool();
        RefreshControls();
        if (wasDrawer) LibraryToggleButton.Focus();
        else if (workspaceLayout.Mode == WorkspaceMode.Selection) SelectionWorkspaceButton.Focus();
        else EditingWorkspaceButton.Focus();
        return true;
    }

    private void DockToggle(object sender, RoutedEventArgs e)
    {
        if (file == null || pendingAllReset != null || closing || exporting || UpdateInstallationActive ||
            workspaceLayout.Mode != WorkspaceMode.Editing) return;
        if (ShowsInspector && !SuspendInspectorTool()) return;
        workspaceLayout.ToggleInspector();
        ProcessingPopup.IsOpen = false;
        RefreshWorkspace();
        RestoreInspectorTool();
        RefreshControls();
    }

    private bool ShowsInlineHistogram
    {
        get
        {
            var minimumHeight = TextElement.GetFontSize(AdjustmentPanel) >= 20 ? 700 : 400;
            return ShowsInspector && (WorkspaceBody.ActualHeight == 0 || WorkspaceBody.ActualHeight >= minimumHeight);
        }
    }

    private void RefreshHistogramWorkspace()
    {
        var inline = ShowsInlineHistogram;
        var available = result != null && ShowsPhotoWorkspace;
        if (inline && HistogramPopupContent.Child != null)
        {
            HistogramPopup.IsOpen = false;
            HistogramPopupContent.Child = null;
            HistogramHost.Children.Add(HistogramPanel);
        }
        else if (!inline && HistogramPanel.Parent == HistogramHost)
        {
            HistogramHost.Children.Remove(HistogramPanel);
            HistogramPopupContent.Child = HistogramPanel;
        }
        if (!available) HistogramPopup.IsOpen = false;
        HistogramSurface.Visibility = available && inline ? Visibility.Visible : Visibility.Collapsed;
        HistogramButton.Visibility = available && !inline ? Visibility.Visible : Visibility.Collapsed;
        HistogramPanel.Visibility = !inline || histogramExpanded ? Visibility.Visible : Visibility.Collapsed;
        HistogramTitle.Visibility = inline ? Visibility.Collapsed : Visibility.Visible;
        HistogramHeading.Text = HistogramTitle.Text;
        RefreshStateToolTips();
    }

    private void RefreshStateToolTips()
    {
        HistogramInlineButton.ToolTip = Loc.Text(histogramExpanded ? "收起直方图" : "展开直方图");
        HistogramButton.ToolTip = HistogramButton.Visibility == Visibility.Visible
            ? Loc.Text(HistogramPopup.IsOpen ? "收起直方图" : "展开直方图") : null;
        AdjustToggleButton.ToolTip = Loc.Text(ShowsInspector ? "收起调整栏" : "展开调整栏");
    }

    private void HistogramClicked(object sender, RoutedEventArgs e)
    {
        if (result == null || !ShowsPhotoWorkspace) return;
        if (ShowsInlineHistogram) histogramExpanded = sender is MenuItem || !histogramExpanded;
        else HistogramPopup.IsOpen = !HistogramPopup.IsOpen;
        RefreshHistogramWorkspace();
    }
}
