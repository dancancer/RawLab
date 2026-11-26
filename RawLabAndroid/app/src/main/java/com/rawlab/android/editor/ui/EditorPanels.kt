package com.rawlab.android.editor.ui

import com.rawlab.android.ui.AppIcons

import com.rawlab.android.editor.controls.HslTargetActions
import com.rawlab.android.editor.controls.WbProbeActions
import com.rawlab.android.editor.controls.WbProbeCanvasControls
import com.rawlab.android.editor.controls.HslTargetCanvasControls

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalContext
import com.rawlab.android.editor.canvas.PhotoViewOptions
import com.rawlab.android.editor.canvas.ComparisonMode
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.rawlab.android.R
import com.rawlab.android.editor.AdjustmentGroup
import com.rawlab.android.editor.EditSaveState
import com.rawlab.android.editor.EditorState
import com.rawlab.android.editor.Operation
import com.rawlab.android.editor.canvas.PhotoCanvas
import com.rawlab.android.editor.canvas.PhotoCanvasState
import com.rawlab.android.editor.canvas.photoViewMargin
import com.rawlab.android.editor.canvas.rememberPhotoHDRPreview
import com.rawlab.android.editor.geometry.GeometryCropCanvas
import com.rawlab.android.editor.inspection.InspectionSessionState
import com.rawlab.android.photo.PhotoInfo
import com.rawlab.android.settings.EditSettings
import kotlinx.coroutines.delay

// ============================================================================
//  编辑器画布区的状态块：画布、保存提示、渲染错误与空白引导
// ============================================================================

internal data class EditorLoadingPresentation(
    val showsTopProgressLine: Boolean,
    val showsEmptyCanvasLoading: Boolean,
    val immediateBannerRes: Int?,
    val delayedBannerRes: Int?,
)

internal fun resolveEditorLoadingPresentation(
    state: EditorState,
    isAdjustingSlider: Boolean = false,
): EditorLoadingPresentation {
    val activeOperation = state.operation != Operation.NONE && state.operation != Operation.PICK_EXPORT
    val isRendering = state.rendering || state.previewResizePending
    val showsTopProgressLine = isRendering || activeOperation || state.matchingProcessing ||
        state.importingHDRCameraProfile || state.lookImportPreparing || state.committingAdjustments
    val showsEmptyCanvasLoading = state.preview == null &&
        (state.operation == Operation.IMPORT || (state.rendering && state.photo != null))

    val immediateBannerRes = when {
        state.operation == Operation.EXPORT -> null
        state.operation == Operation.IMPORT -> if (showsEmptyCanvasLoading) null else R.string.importing
        state.operation == Operation.IMPORT_LOOK || state.lookImportPreparing || state.importingHDRCameraProfile ->
            R.string.look_importing
        state.operation == Operation.PREPARE_EXPORT -> R.string.exporting
        state.matchingProcessing -> R.string.processing_migration_matching
        else -> null
    }
    val delayedBannerRes = if (
        immediateBannerRes == null &&
        state.operation != Operation.EXPORT &&
        !showsEmptyCanvasLoading &&
        isRendering &&
        !isAdjustingSlider
    ) {
        R.string.rendering
    } else {
        null
    }

    return EditorLoadingPresentation(
        showsTopProgressLine = showsTopProgressLine,
        showsEmptyCanvasLoading = showsEmptyCanvasLoading,
        immediateBannerRes = immediateBannerRes,
        delayedBannerRes = delayedBannerRes,
    )
}

@Composable
internal fun EditorCanvas(state: EditorState, compare: Boolean, photoCanvas: PhotoCanvasState, photoInfo: PhotoInfo?, infoMode: Int,
    onInfoClick: () -> Unit, modifier: Modifier,
    onAlbum: () -> Unit, onFile: () -> Unit, onLicenses: () -> Unit, onPreviewSizeChange: (Int) -> Unit,
    onDraftEdit: (EditSettings, Boolean) -> Unit, onSaveRetry: () -> Unit,
    view: PhotoViewOptions = PhotoViewOptions(), onCanvasTap: () -> Unit = {}, onHoldBefore: (Boolean) -> Unit = {},
    onModeChange: (ComparisonMode) -> Unit = {}, onCompareClose: () -> Unit = {}, onRetry: () -> Unit = {}, hslTarget: HslTargetActions? = null, showTargetStatus: Boolean = false, onCamera: () -> Unit = {},
    workspaceControls: Boolean = false, histogramExpanded: Boolean? = null, onHistogramExpandedChange: (Boolean) -> Unit = {},
    onCancelExport: () -> Unit = {},
    onDetailRequest: (com.rawlab.android.editor.canvas.ViewportRoiRequest?) -> Unit = {},
    inspection: InspectionSessionState = InspectionSessionState(),
    onInspectionMove: (Float, Float) -> Unit = { _, _ -> },
    onInspectionAnchorSelect: (Long) -> Unit = {},
    wbProbe: WbProbeActions? = null,
    isAdjustingSlider: Boolean = false,
    bottomControlsInset: Dp = 64.dp,
    sharpenMaskOverlay: android.graphics.Bitmap? = null) {
    val controlsBaseInset = if (workspaceControls) maxOf(64.dp, bottomControlsInset) else 12.dp
    val comparisonInset = if (compare) with(LocalDensity.current) {
        MaterialTheme.typography.labelSmall.lineHeight.toDp() + controlsBaseInset + if (workspaceControls) 20.dp else 24.dp
    } else controlsBaseInset
    val loading = resolveEditorLoadingPresentation(state, isAdjustingSlider)
    var delayedBannerVisible by remember { mutableStateOf(false) }
    LaunchedEffect(loading.delayedBannerRes) {
        delayedBannerVisible = false
        if (loading.delayedBannerRes != null) {
            delay(350)
            delayedBannerVisible = true
        }
    }
    val context = LocalContext.current
    val reduceMotion = android.provider.Settings.Global.getFloat(context.contentResolver,
        android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    Box(modifier.fillMaxWidth().background(MaterialTheme.colorScheme.background).testTag("editor-canvas"), contentAlignment = Alignment.Center) {
        state.preview?.let {
            val hdrPreview = rememberPhotoHDRPreview(it.hdr?.result)
            val geometryDraft = state.draft?.takeIf { draft -> draft.group == AdjustmentGroup.GEOMETRY }
            if (it.renderedGeometry.isIdentity && (geometryDraft != null || !state.edits.geometry.isIdentity))
                GeometryCropCanvas(it, state.visibleEdits.geometry, editing = geometryDraft != null,
                    enabled = state.draftReady, photoMargin = if (view.margins) photoViewMargin else 0.dp,
                    bitmap = hdrPreview.bitmap ?: it.result, physicalAspect = geometryDraft?.geometryAspect,
                    showsGrid = geometryDraft?.geometryGrid ?: true) { value ->
                onDraftEdit(state.visibleEdits.copy(geometry = value), false)
            }
            else PhotoCanvas(it, compare && state.draft?.group != AdjustmentGroup.GEOMETRY, state.photo?.name.orEmpty(), photoCanvas, photoInfo, infoMode, onInfoClick, onPreviewSizeChange,
                mode = view.preferredMode, holdingBefore = view.holdingBefore && state.draft?.group != AdjustmentGroup.GEOMETRY && hslTarget == null && wbProbe == null, hslTarget = hslTarget, wbProbe = wbProbe,
                showOverlays = !view.purePreview, margins = view.margins, workspaceControls = workspaceControls,
                histogramExpanded = histogramExpanded, onHistogramExpandedChange = onHistogramExpandedChange, hdrPreview = hdrPreview,
                detail = state.detail.takeIf { state.draft?.group != AdjustmentGroup.GEOMETRY },
                detailTiles = state.detailTiles.takeIf { state.draft?.group != AdjustmentGroup.GEOMETRY }.orEmpty(),
                onDetailRequest = if (state.draft?.group == AdjustmentGroup.GEOMETRY) ({}) else onDetailRequest,
                inspection = if (state.draft?.group == AdjustmentGroup.GEOMETRY) InspectionSessionState() else inspection,
                onInspectionMove = onInspectionMove,
                onInspectionAnchorSelect = onInspectionAnchorSelect,
                onCanvasTap = { if (state.draft?.group != AdjustmentGroup.GEOMETRY) onCanvasTap() }, onHoldBefore = { onHoldBefore(it && state.draft?.group != AdjustmentGroup.GEOMETRY) },
                onModeChange = onModeChange, onCompareClose = onCompareClose, viewingEnabled = state.draft?.group != AdjustmentGroup.GEOMETRY && state.controlsEnabled,
                bottomOverlayInset = comparisonInset, bottomOverlay = {
                    Column(Modifier.wrapContentWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                        if (showTargetStatus && hslTarget != null) HslTargetCanvasControls(hslTarget, Modifier.padding(8.dp))
                        if (showTargetStatus && wbProbe != null) WbProbeCanvasControls(wbProbe, Modifier.padding(8.dp))
                        EditorSaveNotice(state, onSaveRetry, Modifier.padding(start = 4.dp, end = 4.dp, top = 8.dp))
                    }
                },
                sharpenMaskBitmap = sharpenMaskOverlay.takeIf { state.draft?.group != AdjustmentGroup.GEOMETRY })
        } ?: if (loading.showsEmptyCanvasLoading) {
            EmptyCanvasLoading(reduceMotion = reduceMotion)
        } else {
            EmptyEditor(onAlbum, onFile, state.operation == Operation.NONE, onCamera)
        }
        val previewStatus = stringResource(when {
            state.operation == Operation.IMPORT -> R.string.importing
            state.operation == Operation.IMPORT_LOOK || state.lookImportPreparing || state.importingHDRCameraProfile ->
                R.string.look_importing
            state.operation == Operation.PREPARE_EXPORT || state.operation == Operation.EXPORT -> R.string.exporting
            state.matchingProcessing -> R.string.processing_migration_matching
            loading.showsTopProgressLine -> R.string.rendering
            state.error != null -> R.string.editor_preview_outdated
            else -> R.string.editor_preview_updated
        })
        if (state.preview != null || loading.showsTopProgressLine) {
            Box(Modifier.align(Alignment.TopCenter).fillMaxWidth().height(3.dp)
                .testTag("preview-progress").semantics { stateDescription = previewStatus; liveRegion = LiveRegionMode.Polite }) {
                if (loading.showsTopProgressLine) {
                    if (reduceMotion) Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.primary))
                    else LinearProgressIndicator(
                        modifier = Modifier.fillMaxSize(),
                        color = MaterialTheme.colorScheme.primary,
                        trackColor = Color.White.copy(alpha = 0.16f),
                    )
                }
            }
        }
        if (!view.purePreview) {
            if (state.operation == Operation.EXPORT) {
                val progress = state.exportProgress?.coerceIn(0f, 1f)
                val animatedProgress by animateFloatAsState(targetValue = progress ?: 0f, label = "exportProgress")
                Column(
                    Modifier.align(Alignment.TopStart).padding(12.dp)
                        .background(Color.Black.copy(alpha = .72f), RoundedCornerShape(10.dp))
                        .padding(start = 10.dp, end = 4.dp, top = 4.dp, bottom = 6.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        if (!reduceMotion) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(14.dp).testTag("export-loading"),
                                strokeWidth = 2.dp,
                                color = Color.White,
                            )
                            Spacer(Modifier.width(6.dp))
                        }
                        Text(stringResource(R.string.exporting), color = Color.White, style = MaterialTheme.typography.labelSmall)
                        if (progress != null) {
                            Text(
                                " ${(progress * 100).toInt().coerceIn(0, 100)}%",
                                color = Color.White,
                                style = MaterialTheme.typography.labelSmall,
                            )
                        }
                        TextButton(
                            onClick = onCancelExport,
                            contentPadding = PaddingValues(horizontal = 8.dp, vertical = 2.dp),
                            modifier = Modifier.testTag("export-cancel"),
                        ) {
                            Text(stringResource(R.string.cancel), color = Color.White, style = MaterialTheme.typography.labelSmall)
                        }
                    }
                    if (progress != null && (progress > 0f || reduceMotion)) {
                        LinearProgressIndicator(
                            progress = { if (reduceMotion) progress else animatedProgress },
                            modifier = Modifier.width(140.dp).height(3.dp).padding(end = 6.dp).testTag("export-progress"),
                        )
                    } else if (!reduceMotion) {
                        LinearProgressIndicator(
                            modifier = Modifier.width(140.dp).height(3.dp).padding(end = 6.dp).testTag("export-progress"),
                        )
                    }
                }
            } else {
                val bannerRes = loading.immediateBannerRes ?: loading.delayedBannerRes?.takeIf { delayedBannerVisible }
                bannerRes?.let {
                    Row(
                        Modifier.align(Alignment.TopStart).padding(12.dp)
                            .background(Color.Black.copy(alpha = .72f), RoundedCornerShape(10.dp))
                            .padding(horizontal = 10.dp, vertical = 6.dp)
                            .testTag("editor-activity-banner"),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        if (!reduceMotion) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(12.dp),
                                strokeWidth = 1.5.dp,
                                color = Color.White,
                            )
                            Spacer(Modifier.width(6.dp))
                        }
                        Text(stringResource(it), color = Color.White, style = MaterialTheme.typography.labelSmall)
                    }
                }
            }
            if (state.error != null) RenderError(state, onRetry, Modifier.align(Alignment.TopCenter).padding(top = 4.dp))
        }
        if (state.preview == null || (state.draft?.group == AdjustmentGroup.GEOMETRY && state.saveState == EditSaveState.FAILED)) EditorSaveNotice(state, onSaveRetry, Modifier.align(Alignment.BottomCenter)
            .padding(start = 12.dp, end = 12.dp, bottom = comparisonInset))
    }
}

@Composable
internal fun EditorSaveNotice(state: EditorState, onRetry: () -> Unit, modifier: Modifier) {
    if (state.saveState == EditSaveState.NONE || (state.draft != null && state.saveState != EditSaveState.FAILED)) return
    val failed = state.saveState == EditSaveState.FAILED
    val text = stringResource(when (state.saveState) {
        EditSaveState.SAVED -> R.string.edit_saved
        EditSaveState.RESTORED -> R.string.edit_restored
        else -> R.string.edit_unsaved
    })
    // 瞬时状态只叠加在照片上，不参与工具栏和调节区域的测量。
    Surface(modifier.widthIn(max = 400.dp).testTag("edit-save-notice"),
        shape = MaterialTheme.shapes.small,
        color = if (failed) MaterialTheme.colorScheme.errorContainer else MaterialTheme.colorScheme.surfaceContainerHigh,
        contentColor = if (failed) MaterialTheme.colorScheme.onErrorContainer else MaterialTheme.colorScheme.onSurfaceVariant) {
        if (failed) TextButton(onClick = onRetry, modifier = Modifier.testTag("edit-save-retry").semantics { liveRegion = LiveRegionMode.Polite }) {
            Text(state.saveError ?: text, Modifier.heightIn(max = 72.dp).verticalScroll(rememberScrollState()), color = MaterialTheme.colorScheme.onErrorContainer,
                style = MaterialTheme.typography.labelSmall)
        } else Text(text, Modifier.padding(horizontal = 12.dp, vertical = 8.dp).semantics { liveRegion = LiveRegionMode.Polite }, maxLines = 3,
            overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.labelSmall)
    }
}

@Composable
internal fun RenderError(state: EditorState, onRetry: () -> Unit, modifier: Modifier = Modifier) {
    state.error?.let { error ->
        Row(modifier.fillMaxWidth().heightIn(max = 96.dp).background(MaterialTheme.colorScheme.errorContainer)
            .padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("${stringResource(R.string.editor_preview_outdated)}\n$error", Modifier.weight(1f).verticalScroll(rememberScrollState()), style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onErrorContainer)
            if (state.photo != null || state.retryLegacyX3f) TextButton(onClick = onRetry, enabled = state.operation == Operation.NONE,
                modifier = Modifier.testTag(if (state.retryLegacyX3f) "x3f.retryLegacy" else "preview.retry")) {
                Text(stringResource(if (state.retryLegacyX3f) R.string.x3f_retry_legacy else R.string.retry))
            }
        }
    }
}

@Composable
internal fun EmptyCanvasLoading(reduceMotion: Boolean) {
    Surface(
        modifier = Modifier.testTag("empty-canvas-loading"),
        shape = RoundedCornerShape(12.dp),
        color = Color.Black.copy(alpha = 0.45f),
        border = BorderStroke(1.dp, Color.White.copy(alpha = 0.12f)),
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 24.dp, vertical = 20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (!reduceMotion) {
                CircularProgressIndicator(
                    modifier = Modifier.size(24.dp),
                    strokeWidth = 2.5.dp,
                    color = MaterialTheme.colorScheme.primary,
                )
            }
            Text(
                stringResource(R.string.importing),
                color = Color.White,
                style = MaterialTheme.typography.bodyMedium,
            )
        }
    }
}

@Composable
internal fun EmptyEditor(onAlbum: () -> Unit, onFile: () -> Unit, enabled: Boolean, onCamera: () -> Unit = {}) {
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Button(onClick = onAlbum, enabled = enabled) { Icon(AppIcons.Outlined.PhotoLibrary, null); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.select_photo)) }
        TextButton(onClick = onFile, enabled = enabled) { Text(stringResource(R.string.open_file)) }
        TextButton(onClick = onCamera, enabled = enabled, modifier = Modifier.testTag("camera-entry")) { Text(stringResource(R.string.camera_import)) }
        Text(stringResource(R.string.empty_hint), color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
    }
}
