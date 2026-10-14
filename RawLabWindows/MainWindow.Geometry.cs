using System.Windows.Media.Imaging;

namespace RawLab.Windows;

public partial class MainWindow
{
    private readonly GeometryEditSession geometrySession = new();
    private long geometryGeneration;
    private bool geometryPreviewReady, savedGeometryCompare, savedGeometrySwipe, geometryRenderPending;
    private RenderedImage? savedGeometryResult;
    private (BitmapSource? Image, BitmapSource? Clipping) savedGeometryNeutralImage, savedGeometryResultImage;
    private GeometrySettings PreviewGeometry => geometrySession.IsActive ? geometrySession.PreviewGeometry : settings.Geometry;

    private void BeginGeometryDraft()
    {
        if (file == null || exporting || geometrySession.IsActive) return;
        savedGeometryResult = result;
        savedGeometryNeutralImage = NeutralCanvas.CurrentImage; savedGeometryResultImage = ResultCanvas.CurrentImage;
        geometrySession.Begin(settings.Geometry); ++geometryGeneration;
        geometryPreviewReady = false;
        savedGeometryCompare = compare; savedGeometrySwipe = swipe;
        compare = swipe = false;
        choosingRecipes = choosingHsl = choosingLens = choosingFilm = choosingDenoise = choosingPhotoEffects = false;
        choosingGeometry = true; interacting = false;
        ResultCanvas.GeometryEditing = true;
        GeometryEditor.Begin(geometrySession.Draft);
        GeometryEditor.SetCanvasSize(0, 0);
        NeutralCanvas.Visibility = System.Windows.Visibility.Collapsed; NeutralColumn.Width = new(0);
        ResultCanvas.ComparisonEnabled = false;
        viewport.Fit(); RefreshComparisonToolTip(); RefreshControls(); Schedule();
        ResultCanvas.Focus();
    }
    private void UpdateGeometryDraft(GeometrySettings value, bool dragging)
    {
        if (!ready || syncing || exporting || !geometrySession.IsActive) return;
        var previous = geometrySession.PreviewGeometry;
        geometrySession.Update(value);
        GeometryEditor.Refresh(value); RefreshCropOverlay();
        if (geometrySession.PreviewGeometry != previous) {
            ++geometryGeneration; geometryPreviewReady = false;
            GeometryEditor.SetCanvasSize(0, 0); RefreshCropOverlay();
            interacting = dragging; Schedule();
        } else if (interacting && !dragging) {
            interacting = false; Schedule();
        }
    }
    private void RefreshCropOverlay()
    {
        ResultCanvas.SetCropDraft(geometrySession.IsActive && geometryPreviewReady ? geometrySession.Draft : null,
            GeometryEditor.AspectRatio, GeometryEditor.ShowCorrectionGrid);
    }
    private void ApplyGeometryDraft()
    {
        if (!geometrySession.IsActive || !geometryPreviewReady || exporting) return;
        settings.Geometry = geometrySession.Apply();
        EndGeometryDraft(); MarkEdited(); SaveEdits();
        RefreshControls(); Schedule();
    }
    private void CancelGeometryDraft(bool render = true)
    {
        if (!geometrySession.IsActive) return;
        geometrySession.Cancel(); EndGeometryDraft();
        RefreshControls(); if (render) Schedule();
    }
    private void EndGeometryDraft()
    {
        ++geometryGeneration; geometryPreviewReady = false; geometryRenderPending = true; exactReady = false;
        result = savedGeometryResult;
        NeutralCanvas.SetImage(savedGeometryNeutralImage.Image, savedGeometryNeutralImage.Clipping);
        ResultCanvas.SetImage(savedGeometryResultImage.Image, savedGeometryResultImage.Clipping);
        ResultCanvas.SetComparison(savedGeometryNeutralImage.Image, savedGeometryNeutralImage.Clipping);
        if (result != null) {
            viewport.SetSourceSize(result.NativeWidth, result.NativeHeight);
            Histogram.Bins = result.Histogram; Histogram.InvalidateVisual(); RefreshRenderLabels();
        }
        savedGeometryResult = null; savedGeometryNeutralImage = savedGeometryResultImage = default;
        choosingGeometry = false; interacting = false;
        ResultCanvas.GeometryEditing = false; ResultCanvas.SetCropDraft(null, null, false);
        SetComparisonMode(savedGeometryCompare, savedGeometrySwipe, false);
        viewport.Fit(); RefreshComparisonToolTip();
    }
}
