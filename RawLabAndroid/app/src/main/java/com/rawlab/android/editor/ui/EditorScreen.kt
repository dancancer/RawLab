package com.rawlab.android.editor.ui

import com.rawlab.android.editor.controls.HslTargetActions
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.PointerEventPass

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.testTag
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.layout
import androidx.compose.ui.draw.alpha
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.ui.semantics.*
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import android.text.format.Formatter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import com.rawlab.android.R
import com.rawlab.android.about.LanguageMenu
import com.rawlab.android.analytics.UsageFilmKind
import com.rawlab.android.editor.AdjustmentGroup
import com.rawlab.android.editor.*
import com.rawlab.android.editor.Operation
import com.rawlab.android.editor.canvas.PhotoCanvasState
import com.rawlab.android.editor.canvas.PhotoViewOptions
import com.rawlab.android.editor.canvas.ComparisonMode
import com.rawlab.android.editor.controls.AdjustmentHapticGate
import com.rawlab.android.editor.controls.LocalAdjustmentCancellation
import com.rawlab.android.editor.controls.LocalAdjustmentSession
import com.rawlab.android.editor.controls.LocalAdjustmentFocus
import com.rawlab.android.editor.controls.LocalAdjustmentHapticGate
import com.rawlab.android.editor.controls.LocalEditorHaptics
import com.rawlab.android.editor.controls.NumericControl
import com.rawlab.android.editor.controls.editorUsesSideDock
import com.rawlab.android.editor.controls.editorDockLayout
import com.rawlab.android.geometry.GeometryRatio
import com.rawlab.android.camera.CameraOriginalsRetention
import com.rawlab.android.camera.CameraOriginalsSummary
import com.rawlab.android.photo.PhotoInfo
import com.rawlab.android.photo.PhotoInfoReader
import com.rawlab.android.photo.RetainedCopiesSummary
import com.rawlab.android.photo.SystemPhotoStore
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.HDRCameraDevelopmentSettings
import com.rawlab.android.settings.HDRRenditionSettings
import com.rawlab.android.ui.ToolIcon

// ============================================================================
//  编辑器主界面：顶栏、画布与调整面板的布局
// ============================================================================

internal fun filmSelectionChanged(edits: EditSettings, selectedId: String): Boolean =
    edits.film != selectedId || edits.recipeID != null

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EditorScreen(state: EditorState, onAlbum: () -> Unit, onFile: () -> Unit,
    onEdit: (EditSettings, Boolean) -> Unit, onRetry: () -> Unit,
    onExport: () -> Unit, onMessageDismiss: () -> Unit, onLicenses: () -> Unit, onGpuChange: (Boolean) -> Unit,
    onCancelExport: () -> Unit = {},
    onCamera: () -> Unit = {},
    onHDRChange: (Boolean) -> Unit = {},
    onRollbackProcessing: () -> Unit = {},
    onHDRCameraDevelopment: (HDRCameraDevelopmentSettings) -> Unit = {},
    onImportHDRCameraProfile: () -> Unit = {},
    onHDRCameraDraftChange: (HDRCameraDevelopmentSettings) -> Unit = {},
    onSaveRetry: () -> Unit = {},
    onCancelAdjustment: () -> Unit = {},
    canUndoAdjustment: Boolean = false, canRedoAdjustment: Boolean = false, canPasteAdjustment: Boolean = false,
    onCopyAdjustments: () -> Unit = {}, onPasteAdjustments: () -> Unit = {}, onAdjustmentHistory: () -> Unit = {},
    onPresets: () -> Unit = {}, onClosePresets: () -> Unit = {}, quickPresetsVisible: Boolean = false,
    quickPresetContent: @Composable () -> Unit = {}, presetAction: AdjustmentPresetAction? = null,
    onPresetActionConsumed: () -> Unit = {}, onPresetActionReady: (AdjustmentPresetAction) -> Unit = {},
    onUndoAdjustment: () -> Unit = {}, onRedoAdjustment: () -> Unit = {},
    hslTarget: HslTargetActions = HslTargetActions(),
    onAutoExposure: () -> Unit = {},
    onBatchExport: () -> Unit = {},
    onCollection: () -> Unit = {}, collectionEditing: Boolean = false,
    onImportLook: () -> Unit = {}, onRenameLook: (String, String) -> Unit = { _, _ -> },
    onImportHDRLook: () -> Unit = {},
    onApplyHDRSilver: (Boolean) -> Unit = {},
    onCancelHDRLookImport: () -> Unit = {},
    onDeleteLook: (String) -> Unit = {}, onLookImportReportDismiss: () -> Unit = {},
    onAbout: () -> Unit = {}, updateVersion: String? = null,
    onPreviewSizeChange: (Int) -> Unit = {},
    onBeginDraft: (AdjustmentGroup) -> Unit = {}, onDraftEdit: (EditSettings, Boolean) -> Unit = { _, _ -> },
    onUndoDraft: () -> Unit = {}, onRedoDraft: () -> Unit = {},
    onApplyDraft: ((Boolean) -> Unit) -> Unit = { it(false) }, onDiscardDraft: () -> Unit = {},
    onGeometryRatio: (GeometryRatio, Boolean) -> Unit = { _, _ -> },
    onGeometryLock: () -> Unit = {}, onGeometrySwap: () -> Unit = {}, onGeometryGrid: () -> Unit = {},
    onFilmSelected: (UsageFilmKind) -> Unit = {},
    onSelectFilm: (String) -> Boolean = { false },
    onPrepareReset: (EditorResetScope) -> EditorResetPreparation = {
        EditorResetPreparation(EditorResetResult.Blocked("The current preview is not ready"))
    },
    onCommitReset: (PreparedEditorReset) -> Boolean = { false },
    onResetUnusableRecord: () -> Unit = {},
    onDismissUnusableRecord: () -> Unit = {},
    systemPhotoRequest: SystemPhotoOpenRequest? = null,
    onSystemPhotoConsumed: (SystemPhotoOpenRequest) -> Unit = {},
    onSystemPhotoReady: (SystemPhotoOpenRequest, (Boolean) -> Unit) -> Unit = { _, finish -> finish(false) }) {
    var view by rememberSaveable(stateSaver = listSaver<PhotoViewOptions, Any>(save = {
        listOf(it.comparisonEnabled, it.preferredMode.ordinal, it.margins, it.infoMode, it.purePreview)
    }, restore = { PhotoViewOptions(it[0] as Boolean, ComparisonMode.entries[it[1] as Int], it[2] as Boolean, it[3] as Int, it[4] as Boolean) })) { mutableStateOf(PhotoViewOptions()) }
    val compare = view.comparisonEnabled && state.draft?.group != AdjustmentGroup.GEOMETRY
    var zoomMenu by remember { mutableStateOf(false) }
    var expanded by rememberSaveable { mutableStateOf(true) }
    var toolOpen by rememberSaveable(state.photo?.identity) { mutableStateOf(false) }
    var workspaceHistogram by rememberSaveable(state.photo?.identity) { mutableStateOf(false) }
    var fine by rememberSaveable(state.photo?.identity) { mutableStateOf(false) }
    var toolMenu by remember { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    var tool by rememberSaveable { mutableIntStateOf(0) }
    var channel by rememberSaveable { mutableIntStateOf(0) }
    var gradingZone by rememberSaveable(state.photo?.identity, state.photo?.file?.absolutePath) { mutableStateOf(com.rawlab.android.settings.ColorGradingZone.SHADOWS) }
    var pendingAll by remember(state.photo?.identity, state.photo?.file?.absolutePath) { mutableStateOf(false) }
    var prepareAllWhenReady by remember(state.photo?.identity, state.photo?.file?.absolutePath) { mutableStateOf(false) }
    var preparedReset by remember { mutableStateOf<PreparedEditorReset?>(null) }
    var blockedScope by remember { mutableStateOf<EditorResetScope?>(null) }
    var resetError by remember { mutableStateOf<Int?>(null) }
    var pendingLeave by remember(state.photo?.identity, state.photo?.file?.absolutePath) { mutableStateOf<(() -> Unit)?>(null) }
    var pendingSystemPhoto by remember { mutableStateOf<SystemPhotoOpenRequest?>(null) }
    var settings by rememberSaveable { mutableStateOf(false) }
    var adjusting by remember { mutableStateOf(false) }
    LaunchedEffect(tool) { if (tool == 9) tool = 8 }
    LaunchedEffect(state.edits.isHDREditing) { if (quickPresetsVisible) onClosePresets(); if (state.edits.isHDREditing) tool = 2 }
    val surroundingAlpha by animateFloatAsState(if (adjusting) .32f else 1f, tween(160), label = "adjustment-context")
    val context = LocalContext.current
    val preferences = remember(context) { context.getSharedPreferences("editor", android.content.Context.MODE_PRIVATE) }
    var haptics by rememberSaveable { mutableStateOf(preferences.getBoolean("haptics", true)) }
    fun leave(action: () -> Unit) {
        if (pendingAll) return
        onCancelAdjustment()
        if (state.draft?.changed == true) pendingLeave = action
        else { if (state.draft != null) onDiscardDraft(); toolOpen = false; action() }
    }
    fun applyAndLeave() {
        onApplyDraft { accepted ->
            if (accepted) {
                val destination = pendingLeave
                pendingLeave = null
                toolOpen = false
                if (destination != null) destination()
            }
        }
    }
    fun cancelLeave() {
        pendingSystemPhoto?.let(onSystemPhotoConsumed)
        pendingSystemPhoto = null
        pendingLeave = null
        pendingAll = false; prepareAllWhenReady = false
    }
    LaunchedEffect(systemPhotoRequest?.id, state.operation, state.committingAdjustments, state.saveState, pendingAll, pendingLeave != null) {
        val request = systemPhotoRequest
        if (request != null && state.operation == Operation.NONE && !state.committingAdjustments &&
            state.saveState != EditSaveState.FAILED && !pendingAll && pendingLeave == null) {
            pendingSystemPhoto = request
            leave {
                pendingSystemPhoto = null
                onSystemPhotoReady(request) { accepted -> if (accepted) onSystemPhotoConsumed(request) }
            }
        }
    }
    LaunchedEffect(presetAction) {
        presetAction?.let { action ->
            onPresetActionConsumed()
            leave { onPresetActionReady(action) }
        }
    }
    val retrySave = { if (state.draft != null) { applyAndLeave(); Unit } else onSaveRetry() }
    val selectTool: (Int) -> Unit = { next ->
        if (quickPresetsVisible) onClosePresets()
        if (next != tool || !toolOpen) leave { tool = next; fine = false; toolOpen = true; expanded = true }
    }
    fun openQuickPresets() { onCancelAdjustment(); expanded = true; onPresets() }
    val selectGroup: (EditorAdjustmentGroup) -> Unit = { group ->
        if (quickPresetsVisible) onClosePresets()
        leave { tool = EditorAdjustmentRules.defaultTool(group); expanded = true }
    }

    fun finishAll() { pendingAll = false; prepareAllWhenReady = false }
    fun prepareReset(scope: EditorResetScope) {
        val result = onPrepareReset(scope)
        when (val outcome = result.result) {
            EditorResetResult.NoChange -> finishAll()
            is EditorResetResult.Blocked -> {
                blockedScope = scope
                resetError = when {
                    outcome.reason.contains("Unknown recipe") -> R.string.editor_reset_unknown_recipe
                    outcome.reason.contains("Missing white balance") -> R.string.editor_reset_missing_wb
                    outcome.reason.contains("preview") -> R.string.editor_reset_not_ready
                    outcome.reason.contains("represented") -> R.string.editor_reset_unrepresentable
                    else -> R.string.editor_reset_invalid
                }
                finishAll()
            }
            is EditorResetResult.Ready -> result.prepared?.let { prepared ->
                if (outcome.requiresConfirmation) preparedReset = prepared
                else if (!onCommitReset(prepared)) resetError = R.string.editor_reset_stale
            }
        }
    }
    val requestReset: (EditorResetScope) -> Unit = { scope ->
        if (!pendingAll) {
            if (scope == EditorResetScope.All) {
                // 中性且未改动的草稿原地保持，避免离开/重进产生额外预览。
                if (state.draft?.changed == true || EditorAdjustmentRules.isModified(scope, state.edits, state.resetContext())) {
                    leave { pendingAll = true; prepareAllWhenReady = true }
                    pendingAll = true
                }
            } else prepareReset(scope)
        }
    }
    LaunchedEffect(pendingAll, prepareAllWhenReady, state.draft, state.exact, state.rendering, state.previewResizePending) {
        if (pendingAll && prepareAllWhenReady && state.draft == null && state.exact &&
            !state.rendering && !state.previewResizePending) {
            prepareAllWhenReady = false
            prepareReset(EditorResetScope.All)
        }
    }
    LaunchedEffect(tool, toolOpen, state.canExport, pendingAll) {
        if (toolOpen && !pendingAll && state.draft == null && state.canExport)
            onBeginDraft(AdjustmentGroup.forTool(tool))
    }
    LaunchedEffect(state.draft?.group) { state.draft?.let { tool = it.group.tool; toolOpen = true } }
    BackHandler(enabled = toolOpen) { leave { toolOpen = false } }
    BackHandler(enabled = state.operation == Operation.EXPORT, onBack = onCancelExport)
    BackHandler(enabled = state.importingHDRLook, onBack = onCancelHDRLookImport)
    if (pendingLeave != null) AlertDialog(onDismissRequest = { cancelLeave() },
        title = { Text(stringResource(R.string.adjustment_leave)) },
        confirmButton = { TextButton(onClick = { applyAndLeave() },
            enabled = state.canApplyDraft) { Text(stringResource(R.string.adjustment_apply)) } },
        dismissButton = {
            Column {
                TextButton(onClick = { onDiscardDraft(); toolOpen = false; pendingLeave?.invoke(); pendingLeave = null }) { Text(stringResource(R.string.adjustment_discard)) }
                TextButton(onClick = { cancelLeave() }) { Text(stringResource(R.string.adjustment_continue)) }
            }
        })
    if (state.recoverUnusableRecord) AlertDialog(
        onDismissRequest = onDismissUnusableRecord,
        title = { Text(stringResource(R.string.editor_reset_all_title)) },
        text = { Text(listOfNotNull(state.error, stringResource(R.string.editor_reset_all_message)).joinToString("\n\n")) },
        confirmButton = {
            TextButton(onClick = onResetUnusableRecord, enabled = !state.committingAdjustments) {
                Text(stringResource(R.string.editor_reset_confirm))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismissUnusableRecord) {
                Text(stringResource(R.string.cancel))
            }
        },
    )
    preparedReset?.let { prepared ->
        EditorResetConfirmation(prepared, onDismiss = { preparedReset = null; finishAll() }) {
            preparedReset = null
            if (!onCommitReset(prepared)) resetError = R.string.editor_reset_stale
            finishAll()
        }
    }
    resetError?.let { message -> AlertDialog(onDismissRequest = { resetError = null },
        title = { Text(stringResource(R.string.editor_reset_blocked_title)) }, text = { Text(stringResource(message)) },
        confirmButton = { TextButton(onClick = { resetError = null }) { Text(stringResource(R.string.confirm)) } },
        dismissButton = {
            if (blockedScope != EditorResetScope.All && message in listOf(R.string.editor_reset_unknown_recipe,
                    R.string.editor_reset_missing_wb, R.string.editor_reset_unrepresentable)) {
                TextButton(onClick = { resetError = null; requestReset(EditorResetScope.All) }) {
                    Text(stringResource(R.string.editor_reset_all))
                }
            }
        }) }
    val sourceKey = "${state.photo?.identity?.value}:${state.photo?.file?.absolutePath}"
    val liveSourceKey by rememberUpdatedState(sourceKey)
    if (settings) AlertDialog(onDismissRequest = { settings = false }, title = { Text(stringResource(R.string.editor_settings)) },
        text = { Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.gpu_auto), Modifier.weight(1f))
                Switch(state.gpuEnabled, onGpuChange, enabled = state.operation == Operation.NONE)
            }
            if (state.photo?.isHDRSource == true) Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.hdr_editing), Modifier.weight(1f))
                Switch(state.edits.isHDREditing, onHDRChange, enabled = state.controlsEnabled && state.draft == null,
                    modifier = Modifier.testTag("hdr-editing"))
            }
            state.edits.hdr?.takeIf { state.edits.isHDREditing }?.let { hdr ->
                var expanded by remember(sourceKey) { mutableStateOf(false) }
                TextButton(onClick = { expanded = !expanded }, modifier = Modifier.testTag("hdr-rendition")) {
                    Text(stringResource(R.string.hdr_rendition))
                }
                if (expanded) CompositionLocalProvider(LocalAdjustmentSession provides sourceKey,
                    LocalAdjustmentCancellation provides { _ -> if (liveSourceKey == sourceKey) onCancelAdjustment() }) {
                    HDRRenditionRows(hdr.renditionSettings, state.controlsEnabled && state.draft == null) { next, dragging ->
                        if (liveSourceKey == sourceKey) onEdit(state.edits.copy(hdr = hdr.withRendition(next)), dragging)
                    }
                }
                if (state.photo?.isCameraRawHDR == true && state.photo.hdrSource?.isProRAW != true) {
                    var cameraOpen by remember(sourceKey) { mutableStateOf(false) }
                    TextButton(onClick = { cameraOpen = !cameraOpen }, enabled = !state.importingHDRCameraProfile,
                        modifier = Modifier.testTag("hdr-camera")) { Text("HDR RAW") }
                    if (cameraOpen) HDRCameraDevelopmentRows(hdr.cameraSettings,
                        state.controlsEnabled && state.draft == null && !state.rendering && !state.importingHDRCameraProfile,
                        state.photo.hdrSource?.supportsBayerDevelopment == true, onHDRCameraDevelopment, onImportHDRCameraProfile,
                        state.hdrCameraDraftSettings ?: hdr.cameraSettings, onHDRCameraDraftChange)
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.adjustment_haptics), Modifier.weight(1f))
                Switch(haptics, { haptics = it; preferences.edit().putBoolean("haptics", it).apply() })
            }
            LanguageMenu()
            HorizontalDivider()
            SystemPhotoStorageSection(
                enabled = state.operation == Operation.NONE && systemPhotoRequest == null,
                directory = remember(context) { File(context.filesDir, "system-photos") },
            )
            CameraOriginalsStorageSection(
                enabled = state.operation == Operation.NONE && systemPhotoRequest == null,
                directory = remember(context) { File(context.filesDir, "camera-media-imports") },
            )
        } }, confirmButton = { TextButton(onClick = { settings = false }) { Text(stringResource(R.string.confirm)) } })
    val liveTarget by rememberUpdatedState(hslTarget)
    val hdrMode = state.edits.isHDREditing
    val liveHDRMode by rememberUpdatedState(hdrMode)
    val targetAxis = hslTarget.state.axis
    val hslWorkspace = toolOpen && tool == 14 && state.draft?.group == AdjustmentGroup.HSL
    val liveHslWorkspace by rememberUpdatedState(hslWorkspace)
    val targetMode = hslTarget.state.enabled && hslWorkspace
    val canvasTarget = if (targetMode) hslTarget.guarded {
        liveHslWorkspace && liveTarget.state.enabled &&
            liveSourceKey == sourceKey && liveTarget.state.axis == targetAxis && liveHDRMode == hdrMode
    } else null
    LaunchedEffect(hslWorkspace) { if (!hslWorkspace && liveTarget.state.enabled) liveTarget.enabled(false) }
    LaunchedEffect(targetMode) { if (targetMode) view = view.cancelHold() }
    BackHandler(targetMode) { hslTarget.enabled(false) }
    val cancelAdjustment = onCancelAdjustment
    val cancelRuler: (() -> Unit) -> Unit = { restore ->
        if (liveSourceKey == sourceKey) {
            if (state.draft == null) cancelAdjustment() else restore()
        }
    }
    var viewSource by rememberSaveable { mutableStateOf(sourceKey) }
    val photoCanvas = rememberSaveable(sourceKey, saver = PhotoCanvasState.Saver) { PhotoCanvasState() }
    fun togglePure() {
        if (view.purePreview) { photoCanvas.exitPure(); view = view.copy(purePreview = false, holdingBefore = false) }
        else if (state.draft?.group != AdjustmentGroup.GEOMETRY && state.controlsEnabled && state.preview != null) {
            photoCanvas.enterPure(); view = view.enterPure(true)
        }
    }
    val holdBefore: (Boolean) -> Unit = { held -> view = if (held) view.beginHold(state.draft?.group != AdjustmentGroup.GEOMETRY && state.controlsEnabled) else view.cancelHold() }
    LaunchedEffect(sourceKey) {
        if (viewSource != sourceKey) {
            view = view.forNewPhoto(); viewSource = sourceKey
        }
    }
    LaunchedEffect(state.draft != null) {
        if (state.draft != null) { photoCanvas.exitPure(); view = view.copy(purePreview = false, holdingBefore = false) }
    }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_PAUSE || event == Lifecycle.Event.ON_STOP) { onClosePresets(); view = view.cancelHold(); liveTarget.cancel() } }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer); view = view.cancelHold(); liveTarget.cancel() }
    }
    val windowFocused = LocalWindowInfo.current.isWindowFocused
    LaunchedEffect(windowFocused, menu, settings, zoomMenu, pendingLeave, preparedReset, state.recoverUnusableRecord, state.operation) {
        if (!windowFocused || menu || settings || zoomMenu || pendingLeave != null || preparedReset != null || state.recoverUnusableRecord || state.operation != Operation.NONE) { view = view.cancelHold(); liveTarget.cancel() }
    }
    BackHandler(quickPresetsVisible) { onClosePresets() }
    BackHandler(view.purePreview) { togglePure() }
    val photoInfo by produceState<PhotoInfo?>(null, state.photo?.file?.absolutePath) {
        value = null
        val photo = state.photo ?: return@produceState
        value = withContext(Dispatchers.IO) {
            runCatching { PhotoInfoReader.read(photo.file, photo.name) }.getOrElse { PhotoInfo(fileName = photo.name) }
        }
    }
    val snackbar = remember { SnackbarHostState() }
    LaunchedEffect(state.message) {
        state.message?.let { snackbar.showSnackbar(it); onMessageDismiss() }
    }
    state.lookImportReport?.takeIf { state.pendingLookImports.isEmpty() && !state.lookImportPreparing }?.let { report ->
        AlertDialog(onDismissRequest = onLookImportReportDismiss,
            title = { Text(stringResource(R.string.look_import_result)) },
            text = { Text(report, Modifier.heightIn(max = 320.dp).verticalScroll(rememberScrollState())) },
            confirmButton = { TextButton(onClick = onLookImportReportDismiss) { Text(stringResource(R.string.confirm)) } })
    }
    val hapticGate = remember { AdjustmentHapticGate() }
    CompositionLocalProvider(LocalEditorHaptics provides haptics, LocalAdjustmentFocus provides { adjusting = it },
        LocalAdjustmentHapticGate provides hapticGate, LocalAdjustmentCancellation provides cancelRuler) {
    val currentDock by rememberUpdatedState<@Composable (Modifier, Boolean, Boolean) -> Unit>({ modifier, side, compact ->
        AdjustmentDock(state, modifier, tool, selectTool, expanded, {
            if (quickPresetsVisible) onClosePresets()
            if (targetMode) expanded = !expanded else leave { expanded = !expanded }
        },
            compare, { view = view.toggleComparison() }, onEdit, onImportLook, onRenameLook, onDeleteLook,
            onAutoExposure, onDraftEdit, { applyAndLeave(); Unit }, { onDiscardDraft(); toolOpen = false },
            onFilmSelected, onGeometryRatio, selectGroup, channel, { onCancelAdjustment(); channel = it }, requestReset, side, !pendingAll, compact,
            onGeometryLock, onGeometrySwap, onGeometryGrid, onPresets = { if (quickPresetsVisible) onClosePresets() else openQuickPresets() },
            quickPresetsVisible = quickPresetsVisible, quickPresetContent = quickPresetContent, gradingZone = gradingZone,
            onGradingZoneChange = { onCancelAdjustment(); gradingZone = it }, hslTarget = hslTarget, onSelectFilm = onSelectFilm,
            onImportHDRLook = onImportHDRLook, onApplyHDRSilver = onApplyHDRSilver,
            onRollbackProcessing = onRollbackProcessing, toolOpen = toolOpen, fine = fine)
    })
    @Composable fun workspaceActions(modifier: Modifier) {
        if (state.photo != null && !view.purePreview) Row(modifier.fillMaxWidth().padding(horizontal = 8.dp),
            verticalAlignment = Alignment.CenterVertically) {
            ToolIcon(Icons.Outlined.Undo, R.string.transfer_undo, (if (toolOpen) state.draft?.canUndo == true else canUndoAdjustment) && state.controlsEnabled, if (toolOpen) onUndoDraft else onUndoAdjustment)
            ToolIcon(Icons.Outlined.Redo, R.string.transfer_redo, (if (toolOpen) state.draft?.canRedo == true else canRedoAdjustment) && state.controlsEnabled, if (toolOpen) onRedoDraft else onRedoAdjustment)
            if (toolOpen) ToolIcon(Icons.Outlined.SettingsBackupRestore, R.string.reset, state.draftReady) { requestReset(EditorResetScope.Tool(tool)) }
            Spacer(Modifier.weight(1f))
            ToolIcon(Icons.Outlined.Compare, R.string.editor_compare_enable, state.draft?.group != AdjustmentGroup.GEOMETRY) {
                view = view.toggleComparison()
            }
            if (toolOpen) Box(Modifier.testTag("workspace-more")) {
                ToolIcon(Icons.Outlined.MoreHoriz, R.string.more) { toolMenu = true }
                DropdownMenu(toolMenu, { toolMenu = false }) {
                    DropdownMenuItem(text = { Text(stringResource(R.string.editor_photo_info)) },
                        onClick = { view = view.copy(infoMode = (view.infoMode + 1) % 3); toolMenu = false })
                    DropdownMenuItem(text = { Text(stringResource(R.string.editor_rgb_histogram)) },
                        modifier = Modifier.testTag("workspace-histogram"),
                        leadingIcon = { if (workspaceHistogram) Icon(Icons.Outlined.Check, null) },
                        onClick = { workspaceHistogram = !workspaceHistogram; toolMenu = false })
                    if (hslWorkspace) DropdownMenuItem(text = { Text(stringResource(R.string.hsl_target)) },
                        onClick = { hslTarget.enabled(!hslTarget.state.enabled); toolMenu = false })
                    DropdownMenuItem(text = { Text(stringResource(R.string.adjustment_fine)) },
                        leadingIcon = { if (fine) Icon(Icons.Outlined.Check, null) },
                        modifier = Modifier.testTag("adjustment-fine").semantics { selected = fine }, onClick = { fine = !fine; toolMenu = false })
                    DropdownMenuItem(text = { Text(stringResource(R.string.editor_preview_enter)) },
                        onClick = { toolMenu = false; togglePure() })
                }
            }
        }
    }
    // 纯预览与横竖布局只移动/暂不测量同一面板，保留 fine、滚动和本地输入状态。
    val retainedDock = remember { movableContentOf<Modifier, Boolean, Boolean> { modifier, side, compact -> currentDock(modifier, side, compact) } }
    Scaffold(modifier = Modifier.pointerInput(targetMode) {
        if (targetMode) awaitPointerEventScope {
            while (true) {
                val event = awaitPointerEvent(PointerEventPass.Initial)
                if (event.changes.count { it.pressed } >= 2) liveTarget.cancel()
            }
        }
    }, snackbarHost = { SnackbarHost(snackbar) }, topBar = {
        if (!view.purePreview && !toolOpen) CenterAlignedTopAppBar(modifier = Modifier.alpha(surroundingAlpha), title = {
            Text(state.photo?.name ?: "RawLab", style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }, navigationIcon = {
            ToolIcon(if (state.photo != null) Icons.AutoMirrored.Outlined.ArrowBack else Icons.Outlined.PhotoLibrary, R.string.open_album, state.operation == Operation.NONE) { leave(onAlbum) }
        }, actions = {
            IconButton(onClick = { onCancelAdjustment(); onCamera() }, enabled = state.operation == Operation.NONE,
                modifier = Modifier.testTag("editor-camera")) {
                Icon(Icons.Outlined.CameraAlt, stringResource(R.string.camera_title))
            }
            ToolIcon(Icons.Outlined.SaveAlt, R.string.export, state.canExport, onExport)
            Box(Modifier.testTag("editor-menu")) {
                ToolIcon(Icons.Outlined.MoreVert, R.string.more) { menu = true }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text(stringResource(R.string.open_file)) }, enabled = state.operation == Operation.NONE,
                        leadingIcon = { Icon(Icons.Outlined.FolderOpen, null) }, onClick = { menu = false; leave(onFile) })
                    DropdownMenuItem(text = { Text(stringResource(R.string.camera_import)) },
                        modifier = Modifier.testTag("camera-entry"), enabled = state.operation == Operation.NONE,
                        onClick = { menu = false; onCancelAdjustment(); onCamera() })
                    HorizontalDivider()
                    DropdownMenuItem(text = { Text(stringResource(R.string.preset_library)) },
                        modifier = Modifier.testTag("preset-menu"), onClick = { menu = false; openQuickPresets() })
                    DropdownMenuItem(text = { Text(stringResource(R.string.transfer_copy)) }, enabled = state.controlsEnabled,
                        modifier = Modifier.testTag("adjustment-menu-copy"), leadingIcon = { Icon(Icons.Outlined.ContentCopy, null) },
                        onClick = { menu = false; leave(onCopyAdjustments) })
                    DropdownMenuItem(text = { Text(stringResource(R.string.transfer_paste)) }, enabled = state.controlsEnabled && canPasteAdjustment,
                        modifier = Modifier.testTag("adjustment-menu-paste"), leadingIcon = { Icon(Icons.Outlined.ContentPaste, null) },
                        onClick = { menu = false; leave(onPasteAdjustments) })
                    DropdownMenuItem(text = { Text(stringResource(R.string.transfer_undo)) }, enabled = canUndoAdjustment && state.controlsEnabled,
                        modifier = Modifier.testTag("adjustment-menu-undo"), leadingIcon = { Icon(Icons.Outlined.Undo, null) },
                        onClick = { menu = false; leave(onUndoAdjustment) })
                    DropdownMenuItem(text = { Text(stringResource(R.string.transfer_redo)) }, enabled = canRedoAdjustment && state.controlsEnabled,
                        modifier = Modifier.testTag("adjustment-menu-redo"), leadingIcon = { Icon(Icons.Outlined.Redo, null) },
                        onClick = { menu = false; leave(onRedoAdjustment) })
                    DropdownMenuItem(text = { Text(stringResource(R.string.transfer_history)) }, enabled = state.controlsEnabled,
                        modifier = Modifier.testTag("adjustment-menu-history"), leadingIcon = { Icon(Icons.Outlined.History, null) },
                        onClick = { menu = false; leave(onAdjustmentHistory) })
                    HorizontalDivider()
                    DropdownMenuItem(text = { Text(if (collectionEditing) stringResource(R.string.collection_return) else stringResource(R.string.collection_title)) },
                        enabled = state.operation == Operation.NONE, modifier = Modifier.testTag("collection-menu"),
                        leadingIcon = { Icon(Icons.Outlined.Collections, null) }, onClick = {
                            menu = false
                            if (collectionEditing) leave(onCollection) else { onCancelAdjustment(); onCollection() }
                        })
                    DropdownMenuItem(text = { Text(stringResource(R.string.batch_export)) }, enabled = state.canExport,
                        leadingIcon = { Icon(Icons.Outlined.Layers, null) }, onClick = { menu = false; onBatchExport() })
                    DropdownMenuItem(text = { Text(stringResource(R.string.editor_photo_info)) }, enabled = state.preview != null,
                        leadingIcon = { Icon(Icons.Outlined.Info, null) }, onClick = { menu = false; view = view.copy(infoMode = (view.infoMode + 1) % 3) })
                    DropdownMenuItem(text = { Text(stringResource(R.string.editor_rgb_histogram)) },
                        onClick = { workspaceHistogram = !workspaceHistogram; menu = false })
                    DropdownMenuItem(text = { Text(stringResource(R.string.editor_zoom_display)) }, enabled = state.preview != null && state.draft == null,
                        leadingIcon = { Icon(Icons.Outlined.ZoomIn, null) }, onClick = { menu = false; zoomMenu = true })
                    DropdownMenuItem(text = { Text(stringResource(R.string.editor_settings)) },
                        leadingIcon = { Icon(Icons.Outlined.Settings, null) }, onClick = { menu = false; settings = true })
                    DropdownMenuItem(text = { Text(stringResource(R.string.licenses)) },
                        leadingIcon = { Icon(Icons.Outlined.Description, null) }, onClick = { menu = false; leave(onLicenses) })
                    DropdownMenuItem(text = { Text(stringResource(R.string.about_rawlab)) },
                        leadingIcon = { Icon(Icons.Outlined.Info, null) }, onClick = { menu = false; leave(onAbout) })
                    if (updateVersion != null) DropdownMenuItem(text = { Text(stringResource(R.string.view_update)) },
                        leadingIcon = { Icon(Icons.Outlined.SystemUpdate, null) }, onClick = { menu = false; leave(onAbout) })
                }
                DropdownMenu(zoomMenu, { zoomMenu = false }) {
                    DropdownMenuItem(text = { Text(stringResource(R.string.zoom_fit)) }, onClick = { zoomMenu = false; photoCanvas.view = com.rawlab.android.editor.canvas.PhotoViewTransform() })
                    DropdownMenuItem(text = { Text("100%") }, onClick = { zoomMenu = false; photoCanvas.zoom = com.rawlab.android.editor.canvas.PhotoZoom(1f) })
                    DropdownMenuItem(text = { Text(stringResource(R.string.editor_photo_margin)) }, onClick = { view = view.copy(margins = !view.margins) },
                        trailingIcon = { Switch(view.margins, { view = view.copy(margins = it) }) })
                }
            }
        }, expandedHeight = 48.dp)
    }) { padding ->
        BoxWithConstraints(Modifier.fillMaxSize().padding(padding)) {
            val density = LocalDensity.current
            val wide = editorUsesSideDock(maxWidth.value, maxHeight.value, density.fontScale)
            // 顶部进度区与底部分隔线不属于照片/面板可分配高度。
            val dockLayout = editorDockLayout(maxHeight.value - if (wide) 4f else 5f, density.fontScale, wide, expanded)
            val dockHeight = if (!toolOpen && !quickPresetsVisible) (if (density.fontScale > 1.3f) 196 else 164).dp else dockLayout.height.dp
            val sideDockWidth = 336.dp
            Column(Modifier.fillMaxSize()) {
                if (!view.purePreview) Spacer(Modifier.fillMaxWidth().height(4.dp))
                if (wide && state.photo != null) {
                    Row(Modifier.weight(1f)) {
                        Column(Modifier.weight(1f)) {
                            Box(Modifier.weight(1f)) {
                            EditorCanvas(state, compare, photoCanvas, photoInfo, view.infoMode, { view = view.copy(infoMode = (view.infoMode + 1) % 3) },
                                Modifier.fillMaxSize(), onAlbum, onFile, onLicenses, onPreviewSizeChange, onDraftEdit, retrySave, view, ::togglePure, holdBefore,
                                { view = view.selectComparison(it) }, { view = view.copy(comparisonEnabled = false, holdingBefore = false) }, onRetry, hslTarget = canvasTarget, showTargetStatus = !expanded, onCamera = onCamera,
                                workspaceControls = true, histogramExpanded = workspaceHistogram,
                                onHistogramExpandedChange = { workspaceHistogram = it },
                                onCancelExport = onCancelExport)
                            workspaceActions(Modifier.align(Alignment.BottomCenter))
                            }
                        }
                        if (!view.purePreview) VerticalDivider()
                        retainedDock(Modifier.hideForPurePreview(view.purePreview).width(sideDockWidth).fillMaxHeight(), true, dockLayout.compactNavigation)
                    }
                } else {
                    Box(Modifier.weight(1f)) {
                    EditorCanvas(state, compare, photoCanvas, photoInfo, view.infoMode, { view = view.copy(infoMode = (view.infoMode + 1) % 3) },
                        Modifier.fillMaxSize(), onAlbum, onFile, onLicenses, onPreviewSizeChange, onDraftEdit, retrySave, view, ::togglePure, holdBefore,
                                { view = view.selectComparison(it) }, { view = view.copy(comparisonEnabled = false, holdingBefore = false) }, onRetry, hslTarget = canvasTarget, showTargetStatus = !expanded, onCamera = onCamera,
                                workspaceControls = true, histogramExpanded = workspaceHistogram,
                                onHistogramExpandedChange = { workspaceHistogram = it },
                                onCancelExport = onCancelExport)
                    workspaceActions(Modifier.align(Alignment.BottomCenter))
                    }
                    if (state.photo != null) {
                        if (!view.purePreview) HorizontalDivider()
                        retainedDock(Modifier.hideForPurePreview(view.purePreview).fillMaxWidth().heightIn(max = dockHeight), false, dockLayout.compactNavigation)
                    }
                }
            }
        }
    }
    }
}

@Composable
private fun HDRRenditionRows(settings: HDRRenditionSettings, enabled: Boolean,
    change: (HDRRenditionSettings, Boolean) -> Unit) {
    NumericControl(R.string.hdr_peak_limit, settings.peakLimitEV, 0f..6f, "EV", enabled,
        { value, dragging -> change(settings.copy(peakLimitEV = value), dragging) },
        { change(settings.copy(peakLimitEV = 0f), false) }, stepOverride = .1f)
    if (settings.peakLimitEV == 0f) Text(stringResource(R.string.hdr_peak_unlimited), style = MaterialTheme.typography.labelSmall)
    NumericControl(R.string.hdr_sdr_exposure, settings.sdrExposureEV, -4f..4f, "EV", enabled,
        { value, dragging -> change(settings.copy(sdrExposureEV = value), dragging) },
        { change(settings.copy(sdrExposureEV = 0f), false) }, stepOverride = .1f)
    NumericControl(R.string.hdr_sdr_contrast, settings.sdrContrast, -100f..100f, "%", enabled,
        { value, dragging -> change(settings.copy(sdrContrast = value), dragging) },
        { change(settings.copy(sdrContrast = 0f), false) })
    NumericControl(R.string.hdr_sdr_saturation, settings.sdrSaturation, -100f..100f, "%", enabled,
        { value, dragging -> change(settings.copy(sdrSaturation = value), dragging) },
        { change(settings.copy(sdrSaturation = 0f), false) })
    TextButton(onClick = { change(HDRRenditionSettings(), false) }, enabled = enabled && !settings.isDefault,
        modifier = Modifier.testTag("hdr-rendition-reset")) {
        Text(stringResource(R.string.editor_reset_confirm))
    }
}

@Composable
internal fun HDRCameraDevelopmentRows(settings: HDRCameraDevelopmentSettings, enabled: Boolean, supportsBayerDevelopment: Boolean,
    apply: (HDRCameraDevelopmentSettings) -> Unit, importProfile: () -> Unit,
    draft: HDRCameraDevelopmentSettings, changeDraft: (HDRCameraDevelopmentSettings) -> Unit) {
    @Composable fun switch(label: Int, value: Boolean, tag: String, update: (Boolean) -> Unit, allowed: Boolean = enabled) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(label), Modifier.weight(1f))
            Switch(value, update, enabled = allowed, modifier = Modifier.testTag(tag))
        }
    }
    switch(R.string.transfer_field_white_balance_mode, draft.customWhiteBalance, "hdr-camera-wb", {
        changeDraft(draft.copy(customWhiteBalance = it, temperature = if (it) 6500f else 0f, tint = 0f))
    })
    if (draft.customWhiteBalance) {
        NumericControl(R.string.temperature, draft.temperature, 2000f..50000f, "K", enabled,
            { value, _ -> changeDraft(draft.copy(temperature = value)) }, { changeDraft(draft.copy(temperature = 6500f)) }, defaultValue = 6500f)
        NumericControl(R.string.tint, draft.tint, -150f..150f, "", enabled,
            { value, _ -> changeDraft(draft.copy(tint = value)) }, { changeDraft(draft.copy(tint = 0f)) })
    }
    Text(stringResource(R.string.transfer_field_exposure_mode))
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        FilterChip(!draft.sensorExposure, { changeDraft(draft.copy(sensorExposure = false)) }, { Text(stringResource(R.string.adjustment_summary_exposure_scene)) },
            enabled = enabled)
        FilterChip(draft.sensorExposure, { changeDraft(draft.copy(sensorExposure = true)) }, { Text(stringResource(R.string.exposure_sensor)) },
            enabled = enabled, modifier = Modifier.testTag("hdr-camera-sensor"))
    }
    if (supportsBayerDevelopment) {
        Text(stringResource(R.string.transfer_field_raw_denoise))
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            for (level in 0..2) {
                FilterChip(draft.fbddLevel == level, { changeDraft(draft.copy(fbddLevel = level)) },
                    { Text(if (level == 0) stringResource(R.string.disabled) else "FBDD $level") },
                    enabled = enabled, modifier = Modifier.testTag("hdr-camera-fbdd-$level"))
            }
        }
    }
    switch(R.string.transfer_field_lens_distortion, draft.lensDistortion, "hdr-camera-distortion", {
        changeDraft(draft.copy(lensDistortion = it, lensProfile = draft.lensProfile.takeIf { _ -> it || draft.lensTca || draft.lensVignetting }))
    })
    switch(R.string.transfer_field_lens_tca, draft.lensTca, "hdr-camera-tca", {
        changeDraft(draft.copy(lensTca = it, lensProfile = draft.lensProfile.takeIf { _ -> it || draft.lensDistortion || draft.lensVignetting }))
    })
    switch(R.string.lens_vignetting, draft.lensVignetting, "hdr-camera-vignetting", {
        changeDraft(draft.copy(lensVignetting = it, lensProfile = draft.lensProfile.takeIf { _ -> it || draft.lensDistortion || draft.lensTca }))
    })
    switch(R.string.transfer_field_lens_auto_crop, draft.lensAutoCrop, "hdr-camera-autocrop",
        { changeDraft(draft.copy(lensAutoCrop = it)) }, allowed = enabled && draft.lensActive)
    draft.cameraProfile?.let { profile ->
        Text(stringResource(R.string.hdr_camera_profile))
        Text(profile.name, modifier = Modifier.testTag("hdr-camera-profile-name"))
    }
    Row {
        TextButton(onClick = importProfile, enabled = enabled, modifier = Modifier.testTag("hdr-camera-profile-import")) {
            Text(stringResource(R.string.hdr_camera_profile_import))
        }
        if (draft.cameraProfile != null) {
            TextButton(onClick = { changeDraft(draft.copy(cameraProfile = null)) }, enabled = enabled) {
                Text(stringResource(R.string.hdr_camera_profile_clear))
            }
        }
    }
    Row {
        // 只复位草稿；点「应用」后沿用既有预检与提交流程。
        TextButton(onClick = { changeDraft(HDRCameraDevelopmentSettings()) }, enabled = enabled && !draft.isDefault,
            modifier = Modifier.testTag("hdr-camera-reset")) {
            Text(stringResource(R.string.editor_reset_confirm))
        }
        TextButton(onClick = { apply(draft) }, enabled = enabled && draft != settings, modifier = Modifier.testTag("hdr-camera-apply")) {
            Text(stringResource(R.string.adjustment_apply))
        }
    }
}

private sealed interface StorageCleanupFeedback {
    data class Cleared(val fileCount: Int, val totalBytes: Long) : StorageCleanupFeedback
    data object Failed : StorageCleanupFeedback
}

@Composable
private fun SystemPhotoStorageSection(enabled: Boolean, directory: File) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var summary by remember(directory) { mutableStateOf<RetainedCopiesSummary?>(null) }
    var loading by remember(directory) { mutableStateOf(true) }
    var clearing by remember(directory) { mutableStateOf(false) }
    var confirmTarget by remember(directory) { mutableStateOf<RetainedCopiesSummary?>(null) }
    var feedback by remember(directory) { mutableStateOf<StorageCleanupFeedback?>(null) }
    LaunchedEffect(directory) {
        loading = true
        try {
            summary = withContext(Dispatchers.IO) { SystemPhotoStore.inspectRetainedCopies(directory) }
        } catch (_: IOException) {
            summary = null
            feedback = StorageCleanupFeedback.Failed
        } finally {
            loading = false
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.storage_section_title), style = MaterialTheme.typography.titleSmall)
        summary?.let { current ->
            Text(
                stringResource(
                    R.string.storage_system_photo_copies_summary,
                    current.fileCount,
                    Formatter.formatShortFileSize(context, current.totalBytes),
                ),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.testTag("settings-system-photos-summary"),
            )
        }
        OutlinedButton(
            onClick = {
                scope.launch {
                    loading = true
                    feedback = null
                    try {
                        val latest = withContext(Dispatchers.IO) { SystemPhotoStore.inspectRetainedCopies(directory) }
                        summary = latest
                        confirmTarget = latest
                    } catch (_: IOException) {
                        feedback = StorageCleanupFeedback.Failed
                    } finally {
                        loading = false
                    }
                }
            },
            enabled = enabled && !loading && !clearing,
            modifier = Modifier.testTag("settings-clear-system-photos"),
        ) {
            Text(stringResource(R.string.storage_clear_system_photo_copies))
        }
        when (val currentFeedback = feedback) {
            is StorageCleanupFeedback.Cleared -> Text(
                stringResource(
                    R.string.storage_clear_system_photo_copies_done,
                    currentFeedback.fileCount,
                    Formatter.formatShortFileSize(context, currentFeedback.totalBytes),
                ),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.testTag("settings-system-photos-feedback"),
            )
            StorageCleanupFeedback.Failed -> Text(
                stringResource(R.string.storage_clear_system_photo_copies_failed),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier.testTag("settings-system-photos-feedback"),
            )
            null -> Unit
        }
    }
    confirmTarget?.let { target ->
        AlertDialog(
            onDismissRequest = { if (!clearing) confirmTarget = null },
            title = { Text(stringResource(R.string.storage_clear_system_photo_copies)) },
            text = {
                Text(
                    stringResource(
                        R.string.storage_clear_system_photo_copies_confirm,
                        target.fileCount,
                        Formatter.formatShortFileSize(context, target.totalBytes),
                    )
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        scope.launch {
                            clearing = true
                            try {
                                val cleared = withContext(Dispatchers.IO) { SystemPhotoStore.clearRetainedCopies(directory) }
                                val refreshed = withContext(Dispatchers.IO) {
                                    runCatching { SystemPhotoStore.inspectRetainedCopies(directory) }
                                        .getOrDefault(RetainedCopiesSummary(0, 0L))
                                }
                                summary = refreshed
                                feedback = StorageCleanupFeedback.Cleared(cleared.fileCount, cleared.totalBytes)
                            } catch (_: IOException) {
                                val refreshed = withContext(Dispatchers.IO) {
                                    runCatching { SystemPhotoStore.inspectRetainedCopies(directory) }.getOrNull()
                                }
                                if (refreshed != null) summary = refreshed
                                feedback = StorageCleanupFeedback.Failed
                            } finally {
                                clearing = false
                                confirmTarget = null
                            }
                        }
                    },
                    enabled = !clearing,
                    modifier = Modifier.testTag("settings-clear-system-photos-confirm"),
                ) {
                    Text(stringResource(R.string.storage_clear_confirm_action))
                }
            },
            dismissButton = {
                TextButton(
                    onClick = { confirmTarget = null },
                    enabled = !clearing,
                    modifier = Modifier.testTag("settings-clear-system-photos-cancel"),
                ) {
                    Text(stringResource(R.string.cancel))
                }
            },
        )
    }
}

// Q6：相机原件不自动删，这里是设置区里的手动清理入口（列目录 + 删除已导出原件的记录）。
@Composable
private fun CameraOriginalsStorageSection(enabled: Boolean, directory: File) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var summary by remember(directory) { mutableStateOf<CameraOriginalsSummary?>(null) }
    var loading by remember(directory) { mutableStateOf(true) }
    var clearing by remember(directory) { mutableStateOf(false) }
    var confirmTarget by remember(directory) { mutableStateOf<CameraOriginalsSummary?>(null) }
    var feedback by remember(directory) { mutableStateOf<StorageCleanupFeedback?>(null) }
    LaunchedEffect(directory) {
        loading = true
        summary = withContext(Dispatchers.IO) { runCatching { CameraOriginalsRetention.inspect(directory) }.getOrNull() }
        if (summary == null) feedback = StorageCleanupFeedback.Failed
        loading = false
    }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        summary?.let { current ->
            Text(
                stringResource(
                    R.string.storage_camera_originals_summary,
                    current.fileCount,
                    Formatter.formatShortFileSize(context, current.totalBytes),
                ),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.testTag("settings-camera-originals-summary"),
            )
        }
        OutlinedButton(
            onClick = {
                scope.launch {
                    loading = true
                    feedback = null
                    val latest = withContext(Dispatchers.IO) { runCatching { CameraOriginalsRetention.inspect(directory) }.getOrNull() }
                    summary = latest
                    confirmTarget = latest
                    if (latest == null) feedback = StorageCleanupFeedback.Failed
                    loading = false
                }
            },
            enabled = enabled && !loading && !clearing,
            modifier = Modifier.testTag("settings-clear-camera-originals"),
        ) {
            Text(stringResource(R.string.storage_clear_camera_originals))
        }
        when (val currentFeedback = feedback) {
            is StorageCleanupFeedback.Cleared -> Text(
                stringResource(
                    R.string.storage_clear_camera_originals_done,
                    currentFeedback.fileCount,
                    Formatter.formatShortFileSize(context, currentFeedback.totalBytes),
                ),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.testTag("settings-camera-originals-feedback"),
            )
            StorageCleanupFeedback.Failed -> Text(
                stringResource(R.string.storage_clear_camera_originals_failed),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier.testTag("settings-camera-originals-feedback"),
            )
            null -> Unit
        }
    }
    confirmTarget?.let { target ->
        AlertDialog(
            onDismissRequest = { if (!clearing) confirmTarget = null },
            title = { Text(stringResource(R.string.storage_clear_camera_originals)) },
            text = {
                Text(
                    stringResource(
                        R.string.storage_clear_camera_originals_confirm,
                        target.fileCount,
                        Formatter.formatShortFileSize(context, target.totalBytes),
                    )
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        scope.launch {
                            clearing = true
                            val cleared = withContext(Dispatchers.IO) { runCatching { CameraOriginalsRetention.pruneExported(directory) }.getOrNull() }
                            val refreshed = withContext(Dispatchers.IO) { runCatching { CameraOriginalsRetention.inspect(directory) }.getOrNull() }
                            if (refreshed != null) summary = refreshed
                            feedback = if (cleared == null) StorageCleanupFeedback.Failed
                                else StorageCleanupFeedback.Cleared(cleared.fileCount, cleared.totalBytes)
                            clearing = false
                            confirmTarget = null
                        }
                    },
                    enabled = !clearing,
                    modifier = Modifier.testTag("settings-clear-camera-originals-confirm"),
                ) {
                    Text(stringResource(R.string.storage_clear_confirm_action))
                }
            },
            dismissButton = {
                TextButton(
                    onClick = { confirmTarget = null },
                    enabled = !clearing,
                    modifier = Modifier.testTag("settings-clear-camera-originals-cancel"),
                ) {
                    Text(stringResource(R.string.cancel))
                }
            },
        )
    }
}

private fun Modifier.hideForPurePreview(hidden: Boolean): Modifier = if (!hidden) this else
    this.clearAndSetSemantics { }.layout { _, _ -> layout(0, 0) { } }
