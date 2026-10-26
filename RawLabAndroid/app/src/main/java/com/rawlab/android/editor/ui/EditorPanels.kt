package com.rawlab.android.editor.ui

import com.rawlab.android.editor.controls.HslTargetActions
import com.rawlab.android.editor.controls.HslTargetCanvasControls

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
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
import androidx.compose.ui.unit.dp
import com.rawlab.android.R
import com.rawlab.android.editor.AdjustmentGroup
import com.rawlab.android.editor.EditSaveState
import com.rawlab.android.editor.EditorState
import com.rawlab.android.editor.Operation
import com.rawlab.android.editor.canvas.PhotoCanvas
import com.rawlab.android.editor.canvas.PhotoCanvasState
import com.rawlab.android.editor.geometry.GeometryCropCanvas
import com.rawlab.android.photo.PhotoInfo
import com.rawlab.android.settings.EditSettings

// ============================================================================
//  编辑器画布区的状态块：画布、保存提示、渲染错误与空白引导
// ============================================================================

@Composable
internal fun EditorCanvas(state: EditorState, compare: Boolean, photoCanvas: PhotoCanvasState, photoInfo: PhotoInfo?, infoMode: Int,
    onInfoClick: () -> Unit, modifier: Modifier,
    onAlbum: () -> Unit, onFile: () -> Unit, onLicenses: () -> Unit, onPreviewSizeChange: (Int) -> Unit,
    onDraftEdit: (EditSettings, Boolean) -> Unit, onSaveRetry: () -> Unit,
    view: PhotoViewOptions = PhotoViewOptions(), onCanvasTap: () -> Unit = {}, onHoldBefore: (Boolean) -> Unit = {},
    onModeChange: (ComparisonMode) -> Unit = {}, onCompareClose: () -> Unit = {}, onRetry: () -> Unit = {}, hslTarget: HslTargetActions? = null, showTargetStatus: Boolean = false) {
    val comparisonInset = if (compare) with(LocalDensity.current) {
        MaterialTheme.typography.labelSmall.lineHeight.toDp() + 36.dp
    } else 12.dp
    Box(modifier.fillMaxWidth().background(MaterialTheme.colorScheme.background).testTag("editor-canvas"), contentAlignment = Alignment.Center) {
        state.preview?.let {
            if (state.draft?.group == AdjustmentGroup.GEOMETRY) GeometryCropCanvas(it, state.visibleEdits.geometry,
                enabled = state.draftReady, physicalAspect = state.draft.geometryAspect, showsGrid = state.draft.geometryGrid) { value ->
                onDraftEdit(state.visibleEdits.copy(geometry = value), false)
            }
            else PhotoCanvas(it, compare && state.draft == null, state.photo?.name.orEmpty(), photoCanvas, photoInfo, infoMode, onInfoClick, onPreviewSizeChange,
                mode = view.preferredMode, holdingBefore = view.holdingBefore && state.draft == null && hslTarget == null, hslTarget = hslTarget,
                showOverlays = !view.purePreview, margins = view.margins,
                onCanvasTap = { if (state.draft == null) onCanvasTap() }, onHoldBefore = { onHoldBefore(it && state.draft == null) },
                onModeChange = onModeChange, onCompareClose = onCompareClose, viewingEnabled = state.draft == null && state.controlsEnabled,
                bottomOverlayInset = comparisonInset, bottomOverlay = {
                    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                        if (showTargetStatus && hslTarget != null) HslTargetCanvasControls(hslTarget, Modifier.padding(8.dp))
                        EditorSaveNotice(state, onSaveRetry, Modifier.padding(start = 4.dp, end = 4.dp, top = 8.dp))
                    }
                })
        } ?: EmptyEditor(onAlbum, onFile, state.operation == Operation.NONE)
        val busy = state.rendering || state.previewResizePending
        val previewStatus = stringResource(when {
            busy -> R.string.rendering
            state.error != null -> R.string.editor_preview_outdated
            else -> R.string.editor_preview_updated
        })
        val context = LocalContext.current
        val reduceMotion = android.provider.Settings.Global.getFloat(context.contentResolver,
            android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
        if (state.preview != null) Box(Modifier.align(Alignment.TopCenter).fillMaxWidth().height(2.dp)
            .testTag("preview-progress").semantics { stateDescription = previewStatus; liveRegion = LiveRegionMode.Polite }) {
            if (busy) {
                if (reduceMotion) Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.primary))
                else LinearProgressIndicator(Modifier.fillMaxSize())
            }
        }
        if (!view.purePreview) {
            val operation = when (state.operation) {
                Operation.EXPORT -> R.string.exporting
                Operation.IMPORT -> R.string.importing
                Operation.IMPORT_LOOK -> R.string.look_importing
                else -> null
            }
            operation?.let { Text(stringResource(it), Modifier.align(Alignment.TopStart).padding(12.dp)
                .background(Color.Black.copy(alpha = .6f)).padding(6.dp), color = Color.White, style = MaterialTheme.typography.labelSmall) }
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
            if (state.photo != null) TextButton(onClick = onRetry, enabled = state.operation == Operation.NONE) { Text(stringResource(R.string.retry)) }
        }
    }
}

@Composable
internal fun EmptyEditor(onAlbum: () -> Unit, onFile: () -> Unit, enabled: Boolean) {
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Button(onClick = onAlbum, enabled = enabled) { Icon(Icons.Outlined.PhotoLibrary, null); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.select_photo)) }
        TextButton(onClick = onFile, enabled = enabled) { Text(stringResource(R.string.open_file)) }
        Text(stringResource(R.string.empty_hint), color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
    }
}
