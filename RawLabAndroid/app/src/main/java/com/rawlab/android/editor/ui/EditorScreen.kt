package com.rawlab.android.editor.ui

import com.rawlab.android.editor.controls.HslTargetActions
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.PointerEventPass

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
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
import com.rawlab.android.editor.controls.LocalAdjustmentFocus
import com.rawlab.android.editor.controls.LocalAdjustmentHapticGate
import com.rawlab.android.editor.controls.LocalEditorHaptics
import com.rawlab.android.editor.controls.editorUsesSideDock
import com.rawlab.android.editor.controls.editorDockLayout
import com.rawlab.android.geometry.GeometryRatio
import com.rawlab.android.photo.PhotoInfo
import com.rawlab.android.photo.PhotoInfoReader
import com.rawlab.android.settings.EditSettings
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
    onSaveRetry: () -> Unit = {},
    adjustmentReloadRequired: Boolean = false, onReloadAdjustments: () -> Boolean = { false },
    onCancelAdjustment: () -> Unit = {},
    canUndoAdjustment: Boolean = false, canRedoAdjustment: Boolean = false, canPasteAdjustment: Boolean = false,
    onCopyAdjustments: () -> Unit = {}, onPasteAdjustments: () -> Unit = {}, onAdjustmentHistory: () -> Unit = {},
    onPresets: () -> Unit = {}, presetAction: AdjustmentPresetAction? = null,
    onPresetActionConsumed: () -> Unit = {}, onPresetActionReady: (AdjustmentPresetAction) -> Unit = {},
    onUndoAdjustment: () -> Unit = {}, onRedoAdjustment: () -> Unit = {},
    hslTarget: HslTargetActions = HslTargetActions(),
    onAutoExposure: () -> Unit = {},
    onBatchExport: () -> Unit = {},
    onCollection: () -> Unit = {}, collectionEditing: Boolean = false,
    onImportLook: () -> Unit = {}, onRenameLook: (String, String) -> Unit = { _, _ -> },
    onDeleteLook: (String) -> Unit = {}, onLookImportReportDismiss: () -> Unit = {},
    onAbout: () -> Unit = {}, updateVersion: String? = null,
    onPreviewSizeChange: (Int) -> Unit = {},
    onBeginDraft: (AdjustmentGroup) -> Unit = {}, onDraftEdit: (EditSettings, Boolean) -> Unit = { _, _ -> },
    onApplyDraft: () -> Boolean = { false }, onDiscardDraft: () -> Unit = {},
    onGeometryRatio: (GeometryRatio, Boolean) -> Unit = { _, _ -> },
    onGeometryLock: () -> Unit = {}, onGeometrySwap: () -> Unit = {}, onGeometryGrid: () -> Unit = {},
    onFilmSelected: (UsageFilmKind) -> Unit = {},
    onPrepareReset: (EditorResetScope) -> EditorResetPreparation = {
        EditorResetPreparation(EditorResetResult.Blocked("The current preview is not ready"))
    },
    onCommitReset: (PreparedEditorReset) -> Boolean = { false }) {
    var view by rememberSaveable(stateSaver = listSaver<PhotoViewOptions, Any>(save = {
        listOf(it.comparisonEnabled, it.preferredMode.ordinal, it.margins, it.infoMode, it.purePreview)
    }, restore = { PhotoViewOptions(it[0] as Boolean, ComparisonMode.entries[it[1] as Int], it[2] as Boolean, it[3] as Int, it[4] as Boolean) })) { mutableStateOf(PhotoViewOptions()) }
    val compare = view.comparisonEnabled && state.draft == null
    var zoomMenu by remember { mutableStateOf(false) }
    var expanded by rememberSaveable { mutableStateOf(true) }
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
    var settings by rememberSaveable { mutableStateOf(false) }
    var adjusting by remember { mutableStateOf(false) }
    LaunchedEffect(tool) { if (tool == 9) tool = 8 }
    val surroundingAlpha by animateFloatAsState(if (adjusting) .32f else 1f, tween(160), label = "adjustment-context")
    val context = LocalContext.current
    val preferences = remember(context) { context.getSharedPreferences("editor", android.content.Context.MODE_PRIVATE) }
    var haptics by rememberSaveable { mutableStateOf(preferences.getBoolean("haptics", true)) }
    fun leave(action: () -> Unit) {
        if (pendingAll) return
        onCancelAdjustment()
        if (state.draft?.changed == true) pendingLeave = action
        else { if (state.draft != null) onDiscardDraft(); action() }
    }
    fun applyAndLeave(): Boolean {
        if (!onApplyDraft()) return false
        val destination = pendingLeave
        pendingLeave = null
        if (destination != null) destination() else tool = 2
        return true
    }
    LaunchedEffect(presetAction) {
        presetAction?.let { action ->
            onPresetActionConsumed()
            leave { onPresetActionReady(action) }
        }
    }
    var confirmReload by remember { mutableStateOf(false) }
    val retrySave = { if (adjustmentReloadRequired) confirmReload = true else if (state.draft != null) { applyAndLeave(); Unit } else onSaveRetry() }
    if (confirmReload) AlertDialog(onDismissRequest = { confirmReload = false },
        title = { Text(stringResource(R.string.transfer_reload)) }, text = { Text(stringResource(R.string.transfer_reload_body)) },
        confirmButton = { TextButton(onClick = {
            confirmReload = false
            if (onReloadAdjustments()) { pendingLeave = null; pendingAll = false; prepareAllWhenReady = false; tool = 2 }
        }, modifier = Modifier.testTag("adjustment-reload-confirm")) { Text(stringResource(R.string.transfer_reload)) } },
        dismissButton = { TextButton(onClick = { confirmReload = false }) { Text(stringResource(R.string.cancel)) } })
    val selectTool: (Int) -> Unit = { next -> if (next != tool) leave { tool = next; expanded = true } }
    val selectGroup: (EditorAdjustmentGroup) -> Unit = { group ->
        leave {
            if (expanded && EditorAdjustmentRules.groupFor(tool) == group) expanded = false
            else { tool = EditorAdjustmentRules.defaultTool(group); expanded = true }
        }
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
    LaunchedEffect(tool, expanded, state.canExport, pendingAll) {
        if (expanded && !pendingAll && state.draft == null && state.canExport) when (tool) {
            17 -> onBeginDraft(AdjustmentGroup.GEOMETRY)
            16 -> onBeginDraft(AdjustmentGroup.LENS)
        }
    }
    BackHandler(enabled = state.draft != null) { leave { tool = 2 } }
    if (pendingLeave != null) AlertDialog(onDismissRequest = { pendingLeave = null; finishAll() },
        title = { Text(stringResource(R.string.adjustment_leave)) },
        confirmButton = { TextButton(onClick = { applyAndLeave() },
            enabled = state.canApplyDraft) { Text(stringResource(R.string.adjustment_apply)) } },
        dismissButton = {
            Column {
                TextButton(onClick = { onDiscardDraft(); pendingLeave?.invoke(); pendingLeave = null }) { Text(stringResource(R.string.adjustment_discard)) }
                TextButton(onClick = { pendingLeave = null; finishAll() }) { Text(stringResource(R.string.adjustment_continue)) }
            }
        })
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
    if (settings) AlertDialog(onDismissRequest = { settings = false }, title = { Text(stringResource(R.string.editor_settings)) },
        text = { Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.gpu_auto), Modifier.weight(1f))
                Switch(state.gpuEnabled, onGpuChange, enabled = state.operation == Operation.NONE)
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.adjustment_haptics), Modifier.weight(1f))
                Switch(haptics, { haptics = it; preferences.edit().putBoolean("haptics", it).apply() })
            }
            LanguageMenu()
        } }, confirmButton = { TextButton(onClick = { settings = false }) { Text(stringResource(R.string.confirm)) } })
    val sourceKey = "${state.photo?.identity?.value}:${state.photo?.file?.absolutePath}"
    val liveSourceKey by rememberUpdatedState(sourceKey)
    val liveTarget by rememberUpdatedState(hslTarget)
    val targetAxis = hslTarget.state.axis
    val targetMode = hslTarget.state.enabled && tool == 14 && expanded && state.draft == null
    val canvasTarget = if (targetMode) hslTarget.guarded { liveSourceKey == sourceKey && liveTarget.state.axis == targetAxis } else null
    LaunchedEffect(tool, expanded) { if (tool != 14 || !expanded) liveTarget.enabled(false) }
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
        else if (state.draft == null && state.controlsEnabled && state.preview != null) {
            photoCanvas.enterPure(); view = view.enterPure(true)
        }
    }
    val holdBefore: (Boolean) -> Unit = { held -> view = if (held) view.beginHold(state.draft == null && state.controlsEnabled) else view.cancelHold() }
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
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_PAUSE || event == Lifecycle.Event.ON_STOP) { view = view.cancelHold(); liveTarget.cancel() } }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer); view = view.cancelHold(); liveTarget.cancel() }
    }
    val windowFocused = LocalWindowInfo.current.isWindowFocused
    LaunchedEffect(windowFocused, menu, settings, zoomMenu, pendingLeave, preparedReset, state.operation) {
        if (!windowFocused || menu || settings || zoomMenu || pendingLeave != null || preparedReset != null || state.operation != Operation.NONE) { view = view.cancelHold(); liveTarget.cancel() }
    }
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
    state.lookImportReport?.let { report ->
        AlertDialog(onDismissRequest = onLookImportReportDismiss,
            title = { Text(stringResource(R.string.look_import_result)) },
            text = { Text(report, Modifier.heightIn(max = 320.dp).verticalScroll(rememberScrollState())) },
            confirmButton = { TextButton(onClick = onLookImportReportDismiss) { Text(stringResource(R.string.confirm)) } })
    }
    val hapticGate = remember { AdjustmentHapticGate() }
    CompositionLocalProvider(LocalEditorHaptics provides haptics, LocalAdjustmentFocus provides { adjusting = it },
        LocalAdjustmentHapticGate provides hapticGate, LocalAdjustmentCancellation provides cancelRuler) {
    val currentDock by rememberUpdatedState<@Composable (Modifier, Boolean, Boolean) -> Unit>({ modifier, side, compact ->
        AdjustmentDock(state, modifier, tool, selectTool, expanded, { leave { expanded = !expanded } },
            compare, { view = view.toggleComparison() }, onEdit, onImportLook, onRenameLook, onDeleteLook,
            onAutoExposure, onDraftEdit, { applyAndLeave(); Unit }, { onDiscardDraft(); tool = 2 },
            onFilmSelected, onGeometryRatio, selectGroup, channel, { onCancelAdjustment(); channel = it }, requestReset, side, !pendingAll, compact,
            onGeometryLock, onGeometrySwap, onGeometryGrid, onPresets = { onCancelAdjustment(); onPresets() }, gradingZone = gradingZone,
            onGradingZoneChange = { onCancelAdjustment(); gradingZone = it }, hslTarget = hslTarget)
    })
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
        if (!view.purePreview) TopAppBar(modifier = Modifier.alpha(surroundingAlpha), title = {
            Column {
                Text("RawLab", style = MaterialTheme.typography.titleMedium)
                state.photo?.let { Text(it.name, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.labelSmall) }
            }
        }, navigationIcon = {
            ToolIcon(Icons.Outlined.PhotoLibrary, R.string.open_album, state.operation == Operation.NONE) { leave(onAlbum) }
        }, actions = {
            IconToggleButton(checked = compare, onCheckedChange = { view = view.toggleComparison() }, enabled = state.preview != null && state.draft == null) {
                Icon(Icons.Outlined.Compare, stringResource(if (compare) R.string.editor_compare_disable else R.string.editor_compare_enable))
            }
            Box {
                ToolIcon(Icons.Outlined.MoreVert, R.string.more) { menu = true }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text(stringResource(R.string.open_file)) }, enabled = state.operation == Operation.NONE,
                        leadingIcon = { Icon(Icons.Outlined.FolderOpen, null) }, onClick = { menu = false; leave(onFile) })
                    HorizontalDivider()
                    DropdownMenuItem(text = { Text(stringResource(R.string.preset_library)) },
                        modifier = Modifier.testTag("preset-menu"), onClick = { menu = false; onCancelAdjustment(); onPresets() })
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
                    DropdownMenuItem(text = { Text(stringResource(R.string.transfer_history)) }, enabled = state.controlsEnabled && !adjustmentReloadRequired,
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
            ToolIcon(Icons.Outlined.SaveAlt, R.string.export, state.canExport, onExport)
        })
    }) { padding ->
        BoxWithConstraints(Modifier.fillMaxSize().padding(padding)) {
            val density = LocalDensity.current
            val wide = editorUsesSideDock(maxWidth.value, maxHeight.value, density.fontScale)
            // 顶部进度区与底部分隔线不属于照片/面板可分配高度。
            val dockLayout = editorDockLayout(maxHeight.value - if (wide) 4f else 5f, density.fontScale, wide, expanded)
            val dockHeight = dockLayout.height.dp
            val sideDockWidth = 336.dp
            Column(Modifier.fillMaxSize()) {
                if (!view.purePreview) Spacer(Modifier.fillMaxWidth().height(4.dp))
                if (wide && state.photo != null) {
                    Row(Modifier.weight(1f)) {
                        Column(Modifier.weight(1f)) {
                            EditorCanvas(state, compare, photoCanvas, photoInfo, view.infoMode, { view = view.copy(infoMode = (view.infoMode + 1) % 3) },
                                Modifier.weight(1f), onAlbum, onFile, onLicenses, onPreviewSizeChange, onDraftEdit, retrySave, view, ::togglePure, holdBefore,
                                { view = view.selectComparison(it) }, { view = view.copy(comparisonEnabled = false, holdingBefore = false) }, onRetry, hslTarget = canvasTarget)
                        }
                        if (!view.purePreview) VerticalDivider()
                        retainedDock(Modifier.hideForPurePreview(view.purePreview).width(sideDockWidth).fillMaxHeight(), true, dockLayout.compactNavigation)
                    }
                } else {
                    EditorCanvas(state, compare, photoCanvas, photoInfo, view.infoMode, { view = view.copy(infoMode = (view.infoMode + 1) % 3) },
                        Modifier.weight(1f), onAlbum, onFile, onLicenses, onPreviewSizeChange, onDraftEdit, retrySave, view, ::togglePure, holdBefore,
                                { view = view.selectComparison(it) }, { view = view.copy(comparisonEnabled = false, holdingBefore = false) }, onRetry, hslTarget = canvasTarget)
                    if (state.photo != null) {
                        if (!view.purePreview) HorizontalDivider()
                        retainedDock(Modifier.hideForPurePreview(view.purePreview).fillMaxWidth().height(dockHeight), false, dockLayout.compactNavigation)
                    }
                }
            }
        }
    }
    }
}

private fun Modifier.hideForPurePreview(hidden: Boolean): Modifier = if (!hidden) this else
    this.clearAndSetSemantics { }.layout { _, _ -> layout(0, 0) { } }
