package com.rawlab.android.editor.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
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
import com.rawlab.android.editor.controls.AdjustmentHapticGate
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
    onAutoExposure: () -> Unit = {},
    onBatchExport: () -> Unit = {},
    onImportLook: () -> Unit = {}, onRenameLook: (String, String) -> Unit = { _, _ -> },
    onDeleteLook: (String) -> Unit = {}, onLookImportReportDismiss: () -> Unit = {},
    onAbout: () -> Unit = {}, updateVersion: String? = null,
    onPreviewSizeChange: (Int) -> Unit = {},
    onBeginDraft: (AdjustmentGroup) -> Unit = {}, onDraftEdit: (EditSettings, Boolean) -> Unit = { _, _ -> },
    onApplyDraft: () -> Boolean = { false }, onDiscardDraft: () -> Unit = {},
    onGeometryRatio: (GeometryRatio, Boolean) -> Unit = { _, _ -> },
    onFilmSelected: (UsageFilmKind) -> Unit = {},
    onPrepareReset: (EditorResetScope) -> EditorResetPreparation = {
        EditorResetPreparation(EditorResetResult.Blocked("The current preview is not ready"))
    },
    onCommitReset: (PreparedEditorReset) -> Boolean = { false }) {
    var compare by rememberSaveable { mutableStateOf(false) }
    var expanded by rememberSaveable { mutableStateOf(true) }
    var menu by remember { mutableStateOf(false) }
    var tool by rememberSaveable { mutableIntStateOf(0) }
    var channel by rememberSaveable { mutableIntStateOf(0) }
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
    val retrySave = { if (state.draft != null) { applyAndLeave(); Unit } else onSaveRetry() }
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
    var infoMode by rememberSaveable(state.photo?.file?.absolutePath) { mutableIntStateOf(0) }
    val photoCanvas = rememberSaveable(state.photo?.file?.absolutePath, saver = PhotoCanvasState.Saver) { PhotoCanvasState() }
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
        LocalAdjustmentHapticGate provides hapticGate) {
    Scaffold(snackbarHost = { SnackbarHost(snackbar) }, topBar = {
        TopAppBar(modifier = Modifier.alpha(surroundingAlpha), title = {
            Column {
                Text("RawLab", style = MaterialTheme.typography.titleMedium)
                state.photo?.let { Text(it.name, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.labelSmall) }
            }
        }, navigationIcon = {
            ToolIcon(Icons.Outlined.PhotoLibrary, R.string.open_album, state.operation == Operation.NONE) { leave(onAlbum) }
        }, actions = {
            IconToggleButton(checked = compare, onCheckedChange = { compare = it }, enabled = state.preview != null && state.draft == null) {
                Icon(Icons.Outlined.Compare, stringResource(R.string.compare))
            }
            Box {
                ToolIcon(Icons.Outlined.MoreVert, R.string.more) { menu = true }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text(stringResource(R.string.open_file)) }, enabled = state.operation == Operation.NONE,
                        leadingIcon = { Icon(Icons.Outlined.FolderOpen, null) }, onClick = { menu = false; leave(onFile) })
                    DropdownMenuItem(text = { Text(stringResource(R.string.batch_export)) }, enabled = state.canExport,
                        leadingIcon = { Icon(Icons.Outlined.Layers, null) }, onClick = { menu = false; onBatchExport() })
                    DropdownMenuItem(text = { Text(stringResource(R.string.editor_settings)) },
                        leadingIcon = { Icon(Icons.Outlined.Settings, null) }, onClick = { menu = false; settings = true })
                    DropdownMenuItem(text = { Text(stringResource(R.string.licenses)) },
                        leadingIcon = { Icon(Icons.Outlined.Description, null) }, onClick = { menu = false; leave(onLicenses) })
                    DropdownMenuItem(text = { Text(stringResource(R.string.about_rawlab)) },
                        leadingIcon = { Icon(Icons.Outlined.Info, null) }, onClick = { menu = false; leave(onAbout) })
                    if (updateVersion != null) DropdownMenuItem(text = { Text(stringResource(R.string.view_update)) },
                        leadingIcon = { Icon(Icons.Outlined.SystemUpdate, null) }, onClick = { menu = false; leave(onAbout) })
                }
            }
            ToolIcon(Icons.Outlined.SaveAlt, R.string.export, state.canExport, onExport)
        })
    }) { padding ->
        BoxWithConstraints(Modifier.fillMaxSize().padding(padding)) {
            val density = LocalDensity.current
            val textMeasurer = rememberTextMeasurer()
            val groupStyle = MaterialTheme.typography.labelMedium
            val titles = EditorAdjustmentGroup.entries.map { stringResource(groupTitle(it)) }
            val slotWidth = (320.dp - 16.dp) / 6
            val labelsFit = slotWidth >= 48.dp && titles.all { title ->
                val measurement = textMeasurer.measure(AnnotatedString(title), groupStyle,
                    constraints = Constraints(maxWidth = with(density) { (slotWidth - 8.dp).roundToPx() }))
                measurement.lineCount <= 2
            }
            val wide = editorUsesSideDock(maxWidth.value, maxHeight.value, density.fontScale,
                if (labelsFit) 320f else Float.POSITIVE_INFINITY)
            // 顶部进度区与底部分隔线不属于照片/面板可分配高度。
            val dockLayout = editorDockLayout(maxHeight.value - if (wide) 4f else 5f, density.fontScale, wide, expanded)
            val dockHeight = dockLayout.height.dp
            val sideDockWidth = 320.dp
            Column(Modifier.fillMaxSize()) {
                Box(Modifier.fillMaxWidth().height(4.dp)) {
                    if (state.rendering || state.previewResizePending || state.operation == Operation.EXPORT) LinearProgressIndicator(Modifier.fillMaxWidth())
                }
                if (wide && state.photo != null) {
                    Row(Modifier.weight(1f)) {
                        Column(Modifier.weight(1f)) {
                            EditorCanvas(state, compare, photoCanvas, photoInfo, infoMode, { infoMode = (infoMode + 1) % 3 },
                                Modifier.weight(1f), onAlbum, onFile, onLicenses, onPreviewSizeChange, onDraftEdit, retrySave)
                            RenderError(state, onRetry)
                        }
                        VerticalDivider()
                        AdjustmentDock(state, Modifier.width(sideDockWidth).fillMaxHeight(), tool, selectTool, expanded,
                            { leave { expanded = !expanded } }, compare, { compare = !compare }, onEdit,
                            onImportLook, onRenameLook, onDeleteLook, onAutoExposure, onDraftEdit,
                            { applyAndLeave(); Unit }, { onDiscardDraft(); tool = 2 }, onFilmSelected, onGeometryRatio, selectGroup, channel, { channel = it }, requestReset, wide, !pendingAll, dockLayout.compactNavigation)
                    }
                } else {
                    EditorCanvas(state, compare, photoCanvas, photoInfo, infoMode, { infoMode = (infoMode + 1) % 3 },
                        Modifier.weight(1f), onAlbum, onFile, onLicenses, onPreviewSizeChange, onDraftEdit, retrySave)
                    RenderError(state, onRetry)
                    if (state.photo != null) {
                        HorizontalDivider()
                        AdjustmentDock(state, Modifier.fillMaxWidth().height(dockHeight), tool, selectTool, expanded,
                            { leave { expanded = !expanded } }, compare, { compare = !compare }, onEdit,
                            onImportLook, onRenameLook, onDeleteLook, onAutoExposure, onDraftEdit,
                            { applyAndLeave(); Unit }, { onDiscardDraft(); tool = 2 }, onFilmSelected, onGeometryRatio, selectGroup, channel, { channel = it }, requestReset, wide, !pendingAll, dockLayout.compactNavigation)
                    }
                }
            }
        }
    }
    }
}
