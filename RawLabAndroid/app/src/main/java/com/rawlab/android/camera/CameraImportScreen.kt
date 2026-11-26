package com.rawlab.android.camera

import com.rawlab.android.ui.AppIcons

import android.app.DatePickerDialog
import android.app.TimePickerDialog
import android.net.Uri
import android.text.format.Formatter
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.rawlab.android.R
import java.text.DateFormat
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
internal fun CameraImportScreen(model: CameraImportViewModel, onBack: () -> Unit, onOpen: (List<Uri>) -> Unit,
    showTask: Boolean = false, onTaskShown: () -> Unit = {}, onViewInAlbum: (List<Uri>) -> Unit = {},
    showHistory: Boolean = false, onHistoryShown: () -> Unit = {}, onConnect: (Boolean) -> Unit = {}) {
    val state by model.state.collectAsStateWithLifecycle()
    val browseGrid = rememberLazyGridState()
    val selectionGrid = rememberLazyGridState()
    val scope = rememberCoroutineScope()
    var page by rememberSaveable { mutableStateOf("browse") }
    var previewKey by rememberSaveable { mutableStateOf<String?>(null) }
    var format by rememberSaveable { mutableStateOf("all") }
    var date by rememberSaveable { mutableStateOf<String?>(null) }
    var selectedOnly by rememberSaveable { mutableStateOf(false) }
    var filterOpen by rememberSaveable { mutableStateOf(false) }
    var destinationOpen by rememberSaveable { mutableStateOf(false) }
    var jpegOpen by rememberSaveable { mutableStateOf(false) }
    var draftFormat by rememberSaveable { mutableStateOf("all") }
    var draftDate by rememberSaveable { mutableStateOf<String?>(null) }
    var menu by remember { mutableStateOf(false) }
    var unreadableOpen by rememberSaveable { mutableStateOf(false) }
    DisposableEffect(model) { onDispose { model.cancelOpening() } }
    fun back() {
        model.cancelOpening()
        when {
            previewKey != null -> previewKey = null
            page != "browse" -> page = "browse"
            else -> onBack()
        }
    }
    BackHandler(onBack = ::back)
    LaunchedEffect(showTask) { if (showTask) { previewKey = null; page = "task"; onTaskShown() } }
    LaunchedEffect(showHistory) { if (showHistory) { previewKey = null; page = "history"; onHistoryShown() } }
    val preview = state.photos.find { it.key == previewKey }
    val filtered = remember(state.photos, format, date, selectedOnly, state.selected) {
        state.photos.filter { if (selectedOnly) it.key in state.selected else matches(it, format, date) }
    }
    val selected = state.photos.filter { it.key in state.selected }
    val incremental = state.importMode == CameraImportMode.INCREMENTAL
    val resumeIncremental = state.resumableIncrementalJob
    val incrementalCount = state.incrementalScan?.assets?.size ?: 0
    val canImport = !state.transferring && !state.preparing && !state.closing && state.stage == null
    val needsOriginalJpeg = state.job?.items?.any { it.problem?.needsOriginalJpeg == true } == true
    val savedKeys = remember(state.jobs, state.cameraId, state.hardwareIdentity, state.photos, state.incrementalOwner, state.verifiedImports) {
        val observed = state.photos.associateBy { it.key }
        state.jobs.asSequence()
            .filter { it.originalListingOwner == state.incrementalOwner && it.matchesCamera(state.cameraId, state.hardwareIdentity) }
            .flatMap { it.items.asSequence() }
            .filter { it.saved != null && observed[it.photo.key]?.let(it.photo::matchesSnapshot) == true }
            .map { it.photo.key }
            .toSet() + state.verifiedImports.values.map { it.photo }
                .filter { observed[it.key]?.let(it::matchesSnapshot) == true }.map { it.key }
    }
    val title = when {
        preview != null -> R.string.camera_preview
        page == "history" -> R.string.camera_history
        page == "task" -> R.string.camera_progress
        else -> R.string.camera_import
    }
    Scaffold(modifier = Modifier.testTag("camera-import-screen"), topBar = {
        TopAppBar(expandedHeight = 56.dp, title = {
            if (page == "browse" && preview == null && state.connected) {
                Column(Modifier.clickable { onConnect(false) }.testTag("camera-select-connection")) {
                    Text(state.model.displayName, style = MaterialTheme.typography.titleMedium)
                    Text(stringResource(R.string.camera_import), style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            } else Text(stringResource(title), style = MaterialTheme.typography.titleMedium)
        }, navigationIcon = {
            IconButton(onClick = ::back, modifier = Modifier.testTag("camera-back")) {
                Icon(Icons.AutoMirrored.Outlined.ArrowBack, stringResource(R.string.back))
            }
        }, actions = {
            if (page == "browse" && preview == null && state.connected && !incremental) {
                IconButton(onClick = { draftFormat = format; draftDate = date; filterOpen = true }, modifier = Modifier.testTag("camera-filter")) {
                    Icon(AppIcons.Outlined.FilterList, stringResource(R.string.camera_filter),
                        tint = if (format != "all" || date != null) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface)
                }
            }
            Box {
                IconButton(onClick = { menu = true }, modifier = Modifier.testTag("camera-menu")) { Icon(Icons.Outlined.MoreVert, stringResource(R.string.more)) }
                DropdownMenu(menu, { menu = false }) {
                    if (state.connected && page == "browse" && !incremental) DropdownMenuItem(text = { Text(stringResource(R.string.camera_selected)) },
                        leadingIcon = { if (selectedOnly) Icon(Icons.Outlined.Check, null) }, enabled = selected.isNotEmpty(),
                        modifier = Modifier.testTag("camera-selected-only"), onClick = { selectedOnly = !selectedOnly; menu = false })
                    if (!incremental && selected.isNotEmpty()) DropdownMenuItem(text = { Text(stringResource(R.string.camera_clear)) },
                        enabled = !state.transferring, onClick = { model.clearSelection(); selectedOnly = false; menu = false })
                    if (state.connected && page == "browse" && !incremental) DropdownMenuItem(
                        text = { Text(stringResource(R.string.camera_jpeg_settings)) },
                        enabled = canImport,
                        modifier = Modifier.testTag("camera-jpeg-settings"),
                        onClick = { jpegOpen = true; menu = false },
                    )
                    if (state.job != null) DropdownMenuItem(text = { Text(stringResource(R.string.camera_view_task)) },
                        modifier = Modifier.testTag("camera-view-task"), onClick = { page = "task"; previewKey = null; menu = false })
                    DropdownMenuItem(text = { Text(stringResource(R.string.camera_history)) }, modifier = Modifier.testTag("camera-history"),
                        onClick = { model.cancelOpening(); page = "history"; previewKey = null; menu = false })
                    DropdownMenuItem(text = { Text(stringResource(R.string.camera_save_location)) }, enabled = !state.transferring && !state.preparing,
                        modifier = Modifier.testTag("camera-destination-settings"), onClick = { destinationOpen = true; menu = false })
                    DropdownMenuItem(text = { Text(stringResource(if (state.connected) R.string.camera_change else R.string.camera_connect_action)) },
                        enabled = !state.transferring && !state.preparing, onClick = { menu = false; onConnect(page == "task") })
                    if (state.connected) DropdownMenuItem(text = { Text(stringResource(R.string.camera_disconnect)) }, onClick = { menu = false; model.disconnect() })
                }
            }
        })
    }, bottomBar = {
        val hasCandidates = if (incremental) incrementalCount > 0 || resumeIncremental != null else selected.isNotEmpty()
        val showActions = preview != null || page == "task" && state.job != null || page == "browse" && state.connected && hasCandidates
        if (showActions) Surface(Modifier.fillMaxWidth(), color = MaterialTheme.colorScheme.surface) {
            Column(Modifier.navigationBarsPadding().padding(horizontal = 12.dp, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                when {
                    preview != null -> Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        val index = filtered.indexOfFirst { it.key == preview.key }
                        IconButton(onClick = { previewKey = filtered[index - 1].key }, enabled = index > 0) { Icon(AppIcons.AutoMirrored.Outlined.NavigateBefore, stringResource(R.string.camera_previous)) }
                        Button(onClick = { model.toggle(preview) }, enabled = !state.transferring, shape = CameraControlShape, modifier = Modifier.weight(1f)) {
                            Text(stringResource(if (preview.key in state.selected) R.string.camera_deselect else R.string.camera_select))
                        }
                        IconButton(onClick = { previewKey = filtered[index + 1].key }, enabled = index >= 0 && index + 1 < filtered.size) { Icon(AppIcons.AutoMirrored.Outlined.NavigateNext, stringResource(R.string.camera_next)) }
                    }
                    page == "task" -> {
                        val job = checkNotNull(state.job)
                        if (state.transferring) OutlinedButton(onClick = model::stop, shape = CameraControlShape,
                            modifier = Modifier.fillMaxWidth().testTag("camera-stop")) { Text(stringResource(R.string.camera_stop)) }
                        else {
                            if (needsOriginalJpeg) {
                                Button(onClick = { if (state.connected) model.resume(keepJpegOriginals = true) else onConnect(true) },
                                    enabled = canImport, shape = CameraControlShape,
                                    modifier = Modifier.fillMaxWidth().testTag("camera-jpeg-keep-original")) {
                                    val label = if (state.connected) R.string.camera_jpeg_keep_remaining_originals
                                        else R.string.camera_connect_action
                                    Text(stringResource(label))
                                }
                            } else {
                                val hasRetryable = job.status != CameraJobStatus.COMPLETE && job.items.any { it.saved == null && !it.skipped }
                                val hasSkippable = job.items.any { it.canSkip }
                                if (hasRetryable || hasSkippable) Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    if (hasRetryable) Button(onClick = { if (state.connected) model.resume() else onConnect(true) },
                                        enabled = !state.preparing && !state.closing, shape = CameraControlShape,
                                        modifier = Modifier.weight(1f).testTag("camera-resume")) {
                                        val label = when {
                                            !state.connected -> R.string.camera_connect_action
                                            job.items.any { it.error != null && !it.skipped } -> R.string.message_retry_failed_items
                                            job.items.any { it.problem != null && !it.skipped } -> R.string.camera_retry_originals
                                            else -> R.string.camera_resume
                                        }
                                        Text(stringResource(label))
                                    }
                                    if (hasSkippable) OutlinedButton(onClick = model::skipFailed,
                                        enabled = !state.preparing && !state.closing, shape = CameraControlShape,
                                        modifier = Modifier.weight(1f).testTag("camera-skip")) {
                                        Text(stringResource(R.string.transfer_skip))
                                    }
                                }
                            }
                            if (job.savedCount > 0) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Button(onClick = { model.openSaved(onOpen) }, enabled = !state.preparing, shape = CameraControlShape,
                                    modifier = Modifier.weight(1f).testTag("camera-open")) {
                                    Text(stringResource(if (job.items.mapNotNull { it.saved }.distinct().size == 1) R.string.camera_open else R.string.camera_collection))
                                }
                                OutlinedButton(onClick = { model.openSaved(onViewInAlbum) }, enabled = !state.preparing, shape = CameraControlShape,
                                    modifier = Modifier.weight(1f).testTag("camera-view-album")) { Text(stringResource(R.string.camera_view_album)) }
                            }
                        }
                    }
                    incremental -> Button(
                        onClick = { model.startImport(); page = "task" },
                        enabled = canImport && (resumeIncremental != null || state.incrementalOptionsValid),
                        shape = CameraControlShape, modifier = Modifier.fillMaxWidth().testTag("camera-import"),
                    ) {
                        if (resumeIncremental != null) Text(stringResource(R.string.camera_resume))
                        else Text(stringResource(R.string.camera_incremental_import_count, incrementalCount))
                    }
                    else -> Row(Modifier.fillMaxWidth().heightIn(min = 52.dp).testTag("camera-selection-bar"), verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        IconButton(onClick = { model.clearSelection(); selectedOnly = false }) { Icon(Icons.Outlined.Close, stringResource(R.string.camera_cancel_selection)) }
                        Text(stringResource(R.string.camera_selection_count, selected.size, bytes(selected.sumOf { it.size })), Modifier.weight(1f),
                            style = MaterialTheme.typography.labelMedium)
                        if (selected.size == 1) IconButton(onClick = { previewKey = selected.single().key }, modifier = Modifier.testTag("camera-preview-selected")) {
                            Icon(AppIcons.Outlined.ZoomIn, stringResource(R.string.camera_preview))
                        }
                        Button(onClick = { model.startImport(); page = "task" },
                            enabled = canImport && (!state.incrementalJpeg.adjust || state.incrementalOptionsValid || selected.all { it.raw }),
                            shape = CameraControlShape, modifier = Modifier.testTag("camera-import")) { Text(stringResource(R.string.camera_import_count, selected.size)) }
                    }
                }
            }
        }
    }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            state.message?.takeUnless {
                page == "task" && ((state.job?.status == CameraJobStatus.PAUSED && it == R.string.camera_paused) ||
                    (needsOriginalJpeg && it == R.string.camera_jpeg_gain_map_keep_original))
            }?.let { message ->
                Row(Modifier.fillMaxWidth().padding(start = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(message), Modifier.weight(1f).padding(vertical = 8.dp), style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error)
                    IconButton(onClick = model::dismissMessage) { Icon(Icons.Outlined.Close, stringResource(R.string.message_close)) }
                }
            }
            if (state.unreadableLogs.isNotEmpty()) Row(Modifier.fillMaxWidth().padding(start = 12.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.camera_unreadable_logs, state.unreadableLogs.size), Modifier.weight(1f).padding(vertical = 4.dp),
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                TextButton(onClick = { unreadableOpen = true }, modifier = Modifier.testTag("camera-unreadable-view")) {
                    Text(stringResource(R.string.message_view))
                }
                TextButton(onClick = model::discardUnreadableLogs, enabled = !state.transferring && !state.preparing && !state.closing,
                    modifier = Modifier.testTag("camera-unreadable-discard")) {
                    Text(stringResource(R.string.camera_unreadable_discard))
                }
            }
            when {
                preview != null -> {
                    val previewIndex = filtered.indexOfFirst { it.key == preview.key }
                    val indexText = if (previewIndex >= 0) " · ${previewIndex + 1} / ${filtered.size}" else ""
                    CameraImage(model, preview, true, state.connected, state.transferring, Modifier.weight(1f).fillMaxWidth())
                    Column(Modifier.padding(12.dp)) {
                        Text(preview.name, style = MaterialTheme.typography.titleSmall)
                        Text("${if (preview.raw) "RAW" else "JPEG"} · ${bytes(preview.size)}$indexText", style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                page == "history" -> if (state.jobs.isEmpty()) CameraEmpty(R.string.camera_no_history) else LazyColumn(Modifier.fillMaxSize()) {
                    items(state.jobs, key = { it.id }) { job ->
                        ListItem(headlineContent = { Text(DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(job.createdAt))) },
                            supportingContent = { Text(stringResource(R.string.camera_saved_count, job.savedCount, job.items.size)) },
                            trailingContent = { Text(stringResource(if (job.items.any { it.problem != null }) R.string.camera_original_unavailable
                                else if (job.status == CameraJobStatus.COMPLETE) R.string.camera_complete else R.string.camera_paused), style = MaterialTheme.typography.labelSmall) },
                            modifier = Modifier.clickable(enabled = !state.transferring || state.job?.id == job.id) { model.selectJob(job); page = "task" })
                        HorizontalDivider()
                    }
                }
                page == "task" -> CameraTask(state, needsOriginalJpeg)
                state.connected -> {
                    if (state.transferring) {
                        Surface(
                            onClick = { page = "task" },
                            shape = CameraControlShape,
                            color = MaterialTheme.colorScheme.surfaceContainerLow,
                            border = BorderStroke(1.dp, MaterialTheme.colorScheme.primary.copy(alpha = 0.45f)),
                            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp).testTag("camera-browse-task"),
                        ) {
                            Row(
                                Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                Text(stringResource(R.string.camera_progress), Modifier.weight(1f), style = MaterialTheme.typography.labelLarge)
                                Text(stringResource(R.string.message_view), color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.labelMedium)
                            }
                        }
                    }
                    CameraImportModeControls(state, model)
                    if (incremental) {
                        CameraIncrementalOptions(state, model) { jpegOpen = true }
                    } else {
                        val visibleKeys = remember(filtered) { filtered.map { it.key } }
                        val allSelected = allVisibleSelected(state.selected, visibleKeys)
                        val hasFilters = format != "all" || date != null || selectedOnly
                        Row(
                            Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Text("${filtered.size}", style = MaterialTheme.typography.labelLarge,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                            if (hasFilters) {
                                AssistChip(
                                    onClick = { format = "all"; date = null; selectedOnly = false },
                                    label = { Text(stringResource(R.string.camera_clear_filter)) },
                                    trailingIcon = { Icon(Icons.Outlined.Close, contentDescription = null, modifier = Modifier.size(16.dp)) },
                                    shape = CameraControlShape,
                                    modifier = Modifier.testTag("camera-clear-filter"),
                                )
                            }
                            Spacer(Modifier.weight(1f))
                            TextButton(
                                onClick = { model.toggleSelectAll(visibleKeys) },
                                enabled = filtered.isNotEmpty() && !state.transferring,
                                modifier = Modifier.testTag("camera-select-all"),
                            ) {
                                Text(stringResource(if (allSelected) R.string.collection_deselect_all else R.string.collection_select_all))
                            }
                        }
                        if (state.incrementalJpeg.adjust) {
                            Surface(
                                onClick = { jpegOpen = true },
                                enabled = canImport,
                                shape = CameraControlShape,
                                color = MaterialTheme.colorScheme.primary.copy(alpha = 0.12f),
                                border = BorderStroke(1.dp, MaterialTheme.colorScheme.primary.copy(alpha = 0.45f)),
                                modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp).testTag("camera-jpeg-adjusted"),
                            ) {
                                Row(
                                    Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                ) {
                                    Icon(AppIcons.Outlined.Tune, contentDescription = null, modifier = Modifier.size(16.dp), tint = MaterialTheme.colorScheme.primary)
                                    Text("${stringResource(R.string.camera_jpeg_settings)} · ${cameraJpegSummaryText(state.incrementalJpeg)}",
                                        Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis,
                                        style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
                                    Icon(AppIcons.AutoMirrored.Outlined.NavigateNext, contentDescription = null, modifier = Modifier.size(18.dp), tint = MaterialTheme.colorScheme.primary)
                                }
                            }
                        }
                        HorizontalDivider()
                        if (filtered.isEmpty()) CameraEmpty(if (state.photos.isEmpty()) R.string.camera_empty else R.string.camera_no_matches)
                        else BoxWithConstraints(Modifier.weight(1f).fillMaxWidth()) {
                            val columns = cameraGridColumns(maxWidth.value)
                            LazyVerticalGrid(state = if (selectedOnly) selectionGrid else browseGrid,
                                columns = GridCells.Fixed(columns),
                                modifier = Modifier.fillMaxSize().testTag("camera-grid"), contentPadding = PaddingValues(10.dp),
                                horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                                items(filtered, key = { it.key }) { photo ->
                                    val checked = photo.key in state.selected
                                    val saved = photo.key in savedKeys
                                    Column(Modifier.fillMaxWidth().combinedClickable(role = Role.Checkbox,
                                        onClick = { model.toggle(photo) }, onLongClick = { previewKey = photo.key },
                                        onLongClickLabel = stringResource(R.string.camera_preview), enabled = !state.transferring)
                                        .semantics { this.selected = checked }.testTag("camera-item-${photo.key}")) {
                                        Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(4.dp))
                                            .border(if (checked) 2.dp else 0.dp, if (checked) MaterialTheme.colorScheme.primary else Color.Transparent, RoundedCornerShape(4.dp))) {
                                            CameraImage(model, photo, false, state.connected, state.transferring, Modifier.fillMaxWidth().aspectRatio(1.5f))
                                            Box(
                                                Modifier
                                                    .align(Alignment.TopEnd)
                                                    .padding(6.dp)
                                                    .size(22.dp)
                                                    .clip(CircleShape)
                                                    .background(if (checked) MaterialTheme.colorScheme.primary else Color.Black.copy(alpha = 0.55f))
                                                    .border(1.5.dp, if (checked) MaterialTheme.colorScheme.primary else Color.White.copy(alpha = 0.78f), CircleShape),
                                                contentAlignment = Alignment.Center,
                                            ) {
                                                if (checked) {
                                                    Icon(Icons.Outlined.Check, contentDescription = null, modifier = Modifier.size(14.dp), tint = MaterialTheme.colorScheme.onPrimary)
                                                }
                                            }
                                            Text(if (photo.raw) "RAW" else "JPEG",
                                                Modifier.align(Alignment.BottomStart).padding(4.dp)
                                                    .background(Color.Black.copy(alpha = 0.72f), RoundedCornerShape(3.dp))
                                                    .padding(horizontal = 4.dp, vertical = 2.dp),
                                                color = Color.White, style = MaterialTheme.typography.labelSmall)
                                            if (saved) Icon(Icons.Outlined.CheckCircle, stringResource(R.string.camera_saved),
                                                Modifier.align(Alignment.BottomEnd).padding(4.dp).size(18.dp), tint = MaterialTheme.colorScheme.primary)
                                        }
                                        Text(photo.name, Modifier.padding(top = 4.dp), maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.labelMedium)
                                    }
                                }
                            }
                        }
                    }
                }
                else -> Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(stringResource(R.string.camera_devices_empty), style = MaterialTheme.typography.bodyMedium)
                    Spacer(Modifier.height(16.dp))
                    Button(onClick = { onConnect(false) }, enabled = !state.closing && !state.preparing, shape = CameraControlShape,
                        modifier = Modifier.testTag("camera-connect")) { Text(stringResource(R.string.camera_connect_action)) }
                }
            }
        }
    }
    if (destinationOpen) CameraImportSettings(state.destination,
        onSave = { model.setDestination(it); destinationOpen = false }, onDismiss = { destinationOpen = false })
    if (jpegOpen) ModalBottomSheet(onDismissRequest = { jpegOpen = false },
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)) {
            CameraJpegSettingsContent(state, model)
            Spacer(Modifier.height(8.dp))
        }
    }
    if (unreadableOpen) AlertDialog(onDismissRequest = { unreadableOpen = false },
        title = { Text(stringResource(R.string.camera_unreadable_title)) },
        text = { Column(Modifier.verticalScroll(rememberScrollState())) {
            state.unreadableLogs.forEach { Text(it, style = MaterialTheme.typography.bodySmall) }
        } },
        confirmButton = { TextButton(onClick = { unreadableOpen = false }) { Text(stringResource(R.string.message_close)) } })
    if (filterOpen) ModalBottomSheet(onDismissRequest = { filterOpen = false }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        val dates = state.photos.mapNotNull { dateKey(it.created) }.distinct().sortedDescending()
        val count = state.photos.count { matches(it, draftFormat, draftDate) }
        Column(Modifier.fillMaxWidth().heightIn(max = 560.dp).navigationBarsPadding().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(R.string.camera_filter), style = MaterialTheme.typography.titleLarge)
            LazyColumn(Modifier.weight(1f, fill = false)) {
                item { Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf("all", "RAW", "JPEG").forEach { option ->
                        FilterChip(selected = draftFormat == option, onClick = { draftFormat = option }, shape = CameraControlShape,
                            label = { Text(if (option == "all") stringResource(R.string.camera_all) else option) })
                    }
                } }
                item { DateOption(stringResource(R.string.camera_all_dates), draftDate == null) { draftDate = null } }
                items(dates) { value -> DateOption(value, draftDate == value) { draftDate = value } }
            }
            Button(onClick = { format = draftFormat; date = draftDate; selectedOnly = false; filterOpen = false; scope.launch { browseGrid.scrollToItem(0) } },
                shape = CameraControlShape, modifier = Modifier.fillMaxWidth().testTag("camera-filter-apply")) { Text(stringResource(R.string.camera_filter_apply, count)) }
            Spacer(Modifier.height(8.dp))
        }
    }
}

@Composable
private fun CameraTask(state: CameraImportState, needsOriginalJpeg: Boolean) {
    val job = state.job
    if (job == null) { CameraEmpty(R.string.camera_loading); return }
    Column(Modifier.fillMaxSize()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(stringResource(when {
                state.transferring -> R.string.camera_progress
                needsOriginalJpeg -> R.string.camera_paused
                job.items.any { it.problem != null } -> R.string.camera_original_unavailable
                job.status == CameraJobStatus.COMPLETE -> R.string.camera_complete
                else -> R.string.camera_paused
            }), style = MaterialTheme.typography.headlineSmall)
            if (job.items.any { it.problem == CameraMediaProblem.HDR_GAIN_MAP }) Text(stringResource(R.string.camera_jpeg_gain_map_keep_original),
                color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
            if (job.items.any { it.problem == CameraMediaProblem.JPEG_MEMORY }) Text(stringResource(R.string.memory_error),
                color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
            Text(stringResource(R.string.camera_saved_count, job.savedCount, job.items.size))
            if (job.failedCount > 0 || job.skippedCount > 0) Text(
                stringResource(
                    R.string.message_succeeded_failed_not_processed,
                    job.savedCount.toString(),
                    job.failedCount.toString(),
                    (job.pendingCount + job.skippedCount).toString(),
                ),
                color = if (job.failedCount > 0) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.testTag("camera-task-summary"),
            )
            job.incremental?.let { plan ->
                Text("${stringResource(R.string.camera_transfer_format)} · ${if (plan.format == CameraImportFormat.RAW_AND_JPEG) "RAW + JPEG" else plan.format.name}",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            val effectiveJpeg = job.effectiveJpeg
            if (effectiveJpeg != null && job.items.any { job.jpegOptions(it) != null })
                Text(stringResource(R.string.camera_jpeg_summary,
                    effectiveJpeg.longEdge?.let { "$it px" } ?: stringResource(R.string.output_original_size),
                    java.text.NumberFormat.getPercentInstance().format(effectiveJpeg.quality / 100.0)), style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (job.savedCount > 0) Text(stringResource(R.string.camera_saved_to_album),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            LinearProgressIndicator(progress = { ((job.savedBytes + state.currentBytes).toFloat() / job.totalBytes.coerceAtLeast(1)).coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth())
            Text("${bytes((job.savedBytes + state.currentBytes).coerceAtMost(job.totalBytes))} / ${bytes(job.totalBytes)}", style = MaterialTheme.typography.bodySmall)
            if (state.transferring) Text(stringResource(R.string.camera_foreground), color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
        }
        LazyColumn(Modifier.weight(1f)) {
            items(job.items, key = { it.photo.key }) { item ->
                Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(item.photo.name, style = MaterialTheme.typography.bodyMedium)
                        Text(bytes(item.outputSize ?: item.photo.size), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        if (item.saveOriginalJpeg) Text(stringResource(R.string.camera_jpeg_original),
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        else if (item.saved != null && job.jpegOptions(item) != null) Text(stringResource(R.string.camera_jpeg_output_adjusted),
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        if (item.error != null && !item.skipped) Text(item.error,
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error,
                            modifier = Modifier.testTag("camera-item-error-${item.photo.key}"))
                        (item.saved ?: item.unavailable)?.let { saved ->
                            Text(saved.relativePath + saved.displayName, style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                            if (item.captureDay == null) Text(stringResource(R.string.camera_unknown_capture_date),
                                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    Text(stringResource(when {
                        state.currentKey == item.photo.key -> R.string.camera_progress
                        item.skipped -> R.string.transfer_skipped
                        item.problem == CameraMediaProblem.MISSING || item.problem == CameraMediaProblem.REMOTE_MISSING -> R.string.camera_original_missing
                        item.problem == CameraMediaProblem.CHANGED -> R.string.camera_original_changed
                        item.problem?.needsOriginalJpeg == true -> R.string.camera_jpeg_processing_failed
                        item.error != null -> R.string.camera_original_unavailable
                        item.duplicate -> R.string.camera_duplicate
                        item.saved != null -> R.string.camera_saved
                        else -> R.string.camera_waiting
                    }), modifier = Modifier.padding(start = 8.dp).widthIn(max = 110.dp), style = MaterialTheme.typography.labelMedium)
                }
                HorizontalDivider()
            }
        }
    }
}

@Composable
private fun CameraImportModeControls(state: CameraImportState, model: CameraImportViewModel) {
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
            SegmentedButton(
                selected = state.importMode == CameraImportMode.MANUAL,
                onClick = { model.setImportMode(CameraImportMode.MANUAL) },
                shape = SegmentedButtonDefaults.itemShape(0, 2, CameraControlShape),
                modifier = Modifier.testTag("camera-import-mode-MANUAL"),
            ) {
                Text(stringResource(R.string.camera_import_mode_manual), maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            SegmentedButton(
                selected = state.importMode == CameraImportMode.INCREMENTAL,
                onClick = { model.setImportMode(CameraImportMode.INCREMENTAL) },
                shape = SegmentedButtonDefaults.itemShape(1, 2, CameraControlShape),
                modifier = Modifier.testTag("camera-import-mode-INCREMENTAL"),
            ) {
                Text(stringResource(R.string.camera_import_mode_incremental), maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        if (state.stage == SonyCameraConnection.Stage.NETWORK) {
            Text(stringResource(R.string.camera_incremental_scanning), style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("camera-incremental-scanning"))
        }
    }
}

@Composable
private fun CameraIncrementalOptions(state: CameraImportState, model: CameraImportViewModel, onOpenJpegSettings: () -> Unit) {
    val context = LocalContext.current
    val scan = state.incrementalScan
    val pickCutoff = {
        val zone = cameraTimeZone(state.legacyCameraTime)
        val current = Calendar.getInstance(zone).apply { timeInMillis = scan?.startMillis ?: System.currentTimeMillis() }
        DatePickerDialog(context, { _, year, month, day ->
            TimePickerDialog(context, { _, hour, minute ->
                model.setIncrementalCutoff(Calendar.getInstance(zone).apply {
                    set(year, month, day, hour, minute, 0); set(Calendar.MILLISECOND, 0)
                }.timeInMillis)
            }, current.get(Calendar.HOUR_OF_DAY), current.get(Calendar.MINUTE), true).show()
        }, current.get(Calendar.YEAR), current.get(Calendar.MONTH), current.get(Calendar.DAY_OF_MONTH)).show()
    }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
        Column(
            Modifier.widthIn(max = 680.dp).fillMaxWidth().verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 10.dp).testTag("camera-incremental-options"),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Surface(
                shape = RoundedCornerShape(10.dp),
                color = MaterialTheme.colorScheme.surfaceContainerLow,
                border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
            ) {
                Column(Modifier.fillMaxWidth().padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    when {
                        state.stage == SonyCameraConnection.Stage.NETWORK -> Unit
                        scan?.needsCutoffConfirmation == true -> Text(
                            stringResource(R.string.camera_incremental_boundary_unverified),
                            color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.bodySmall,
                            modifier = Modifier.testTag("camera-incremental-boundary-unverified"),
                        )
                        scan?.assets.isNullOrEmpty() -> Text(
                            stringResource(R.string.camera_incremental_no_new),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.testTag("camera-incremental-no-new"),
                        )
                        else -> Text(
                            stringResource(R.string.camera_incremental_pending_count, scan?.assets?.size ?: 0),
                            style = MaterialTheme.typography.titleSmall,
                            modifier = Modifier.testTag("camera-incremental-pending-count"),
                        )
                    }
                    Row(
                        Modifier.fillMaxWidth()
                            .clip(CameraControlShape)
                            .clickable(onClick = pickCutoff)
                            .padding(vertical = 4.dp)
                            .testTag("camera-incremental-cutoff"),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(stringResource(R.string.camera_incremental_cutoff), style = MaterialTheme.typography.labelLarge)
                            Text(
                                stringResource(
                                    R.string.camera_incremental_range,
                                    scan?.let { formatCameraTime(it.startMillis, state.legacyCameraTime) }
                                        ?: stringResource(R.string.camera_incremental_camera_time),
                                ),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        Icon(AppIcons.AutoMirrored.Outlined.NavigateNext, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    if (state.incrementalCutoffMillis != null) {
                        TextButton(
                            onClick = { model.setIncrementalCutoff(null) },
                            modifier = Modifier.testTag("camera-incremental-default-cutoff"),
                        ) {
                            Text(stringResource(R.string.camera_incremental_default_cutoff))
                        }
                    }
                    if ((scan?.undatedCount ?: 0) > 0 || state.incrementalIncludeUndated) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Checkbox(state.incrementalIncludeUndated, onCheckedChange = model::setIncrementalIncludeUndated,
                                modifier = Modifier.testTag("camera-incremental-include-undated"))
                            Text(stringResource(R.string.camera_incremental_undated_count, scan?.undatedCount ?: 0), style = MaterialTheme.typography.bodySmall)
                        }
                    }
                    OutlinedButton(
                        onClick = model::refreshIncrementalScan,
                        enabled = !state.preparing && !state.transferring && state.stage == null,
                        shape = CameraControlShape,
                        modifier = Modifier.testTag("camera-incremental-refresh"),
                    ) {
                        Text(stringResource(R.string.camera_incremental_refresh))
                    }
                }
            }
            Surface(
                shape = RoundedCornerShape(10.dp),
                color = MaterialTheme.colorScheme.surfaceContainerLow,
                border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
            ) {
                Column(Modifier.fillMaxWidth().padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(stringResource(R.string.camera_transfer_format), style = MaterialTheme.typography.labelLarge)
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        listOf(CameraImportFormat.RAW, CameraImportFormat.JPEG, CameraImportFormat.RAW_AND_JPEG).forEach { format ->
                            FilterChip(selected = state.incrementalFormat == format, onClick = { model.setIncrementalFormat(format) },
                                label = { Text(if (format == CameraImportFormat.RAW_AND_JPEG) "RAW + JPEG" else format.name) },
                                modifier = Modifier.testTag("camera-incremental-format-${format.name}"), shape = CameraControlShape)
                        }
                    }
                    if (state.incrementalFormat != CameraImportFormat.RAW) {
                        HorizontalDivider()
                        Row(
                            Modifier.fillMaxWidth()
                                .clip(CameraControlShape)
                                .clickable(enabled = !state.transferring, onClick = onOpenJpegSettings)
                                .padding(vertical = 4.dp)
                                .testTag("camera-jpeg-settings"),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Text(stringResource(R.string.camera_jpeg_settings), style = MaterialTheme.typography.bodyMedium)
                            Spacer(Modifier.weight(1f))
                            Text(
                                cameraJpegSummaryText(state.incrementalJpeg),
                                style = MaterialTheme.typography.bodySmall,
                                color = if (state.incrementalJpeg.adjust) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            Icon(AppIcons.AutoMirrored.Outlined.NavigateNext, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun cameraJpegSummaryText(options: CameraJPEGOptions): String {
    if (!options.adjust) return stringResource(R.string.camera_jpeg_original)
    val size = options.longEdge?.let { "$it px" } ?: stringResource(R.string.output_original_size)
    val quality = java.text.NumberFormat.getPercentInstance().format(options.quality / 100.0)
    return stringResource(R.string.camera_jpeg_summary, size, quality)
}

@Composable
private fun CameraJpegSettingsContent(state: CameraImportState, model: CameraImportViewModel) {
    // 无效的半截输入只存在这里，ViewModel 已记为无效；重建若退回有效值会与“不可开始”的状态脱节。
    var edgeText by rememberSaveable { mutableStateOf(state.incrementalJpeg.longEdge?.toString().orEmpty()) }
    var qualityText by rememberSaveable { mutableStateOf(state.incrementalJpeg.quality.toString()) }
    LaunchedEffect(state.incrementalJpeg.longEdge) {
        val target = state.incrementalJpeg.longEdge?.toString().orEmpty()
        if (edgeText.toIntOrNull() != state.incrementalJpeg.longEdge) edgeText = target
    }
    LaunchedEffect(state.incrementalJpeg.quality) {
        if (qualityText.toIntOrNull() != state.incrementalJpeg.quality) qualityText = state.incrementalJpeg.quality.toString()
    }
    val edge = edgeText.toIntOrNull()
    val edgeInvalid = edgeText.isNotBlank() && edge !in 1..65_535
    val quality = qualityText.toIntOrNull()
    val qualityInvalid = quality !in 1..100

    Text(stringResource(R.string.camera_jpeg_settings), style = MaterialTheme.typography.labelLarge)
    Row(verticalAlignment = Alignment.CenterVertically) {
        Switch(state.incrementalJpeg.adjust, onCheckedChange = { checked ->
            val next = if (checked && !state.incrementalJpeg.adjust && state.incrementalJpeg.longEdge == null) {
                state.incrementalJpeg.copy(adjust = true, longEdge = 2048)
            } else {
                state.incrementalJpeg.copy(adjust = checked)
            }
            val valid = !checked || (!qualityInvalid && (next.longEdge == null || !edgeInvalid))
            model.setIncrementalJpeg(next, optionsValid = valid)
        }, modifier = Modifier.testTag("camera-jpeg-adjust"))
        Text(stringResource(if (state.incrementalJpeg.adjust) R.string.camera_jpeg_adjusted else R.string.camera_jpeg_original),
            Modifier.padding(start = 8.dp), style = MaterialTheme.typography.bodySmall)
    }
    if (state.incrementalJpeg.adjust) {
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            listOf(null to "original", 2048 to "2048", 3000 to "3000", 4096 to "4096").forEach { (preset, label) ->
                FilterChip(selected = edgeText == preset?.toString().orEmpty(), onClick = {
                    edgeText = preset?.toString().orEmpty()
                    model.setIncrementalJpeg(state.incrementalJpeg.copy(longEdge = preset), optionsValid = !qualityInvalid)
                }, label = { Text(if (preset == null) stringResource(R.string.output_original_size) else label) },
                    modifier = Modifier.testTag("camera-jpeg-size-$label"), shape = CameraControlShape)
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(edgeText, { value ->
                edgeText = value
                val parsed = value.toIntOrNull()
                if (value.isBlank()) {
                    model.setIncrementalJpeg(state.incrementalJpeg.copy(longEdge = null), optionsValid = !qualityInvalid)
                } else if (parsed in 1..65_535) {
                    model.setIncrementalJpeg(state.incrementalJpeg.copy(longEdge = parsed), optionsValid = !qualityInvalid)
                } else {
                    model.setIncrementalOptionsValid(false)
                }
            }, label = { Text(stringResource(R.string.output_long_edge)) }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                isError = edgeInvalid, modifier = Modifier.weight(1f).testTag("camera-jpeg-size"))
            OutlinedTextField(qualityText, { value ->
                qualityText = value
                val parsed = value.toIntOrNull()
                if (parsed in 1..100) {
                    model.setIncrementalJpeg(state.incrementalJpeg.copy(quality = parsed!!), optionsValid = !edgeInvalid)
                } else {
                    model.setIncrementalOptionsValid(false)
                }
            }, label = { Text(stringResource(R.string.camera_jpeg_quality)) }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                isError = qualityInvalid, modifier = Modifier.weight(1f).testTag("camera-jpeg-quality"))
        }
        Text(stringResource(R.string.camera_jpeg_local_processing), style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun CameraImage(model: CameraImportViewModel, photo: CameraPhoto, large: Boolean, refresh: Boolean, busy: Boolean, modifier: Modifier) {
    val loadState by produceState<CameraPreviewLoadState>(CameraPreviewLoadState.Loading, photo.key, large, refresh, busy) {
        value = previewLoadState(model.preview(photo, large))
    }
    var zoom by remember(photo.key, large) { mutableFloatStateOf(1f) }
    var offset by remember(photo.key, large) { mutableStateOf(Offset.Zero) }
    val interactionModifier = if (large) {
        modifier
            .background(MaterialTheme.colorScheme.surfaceContainerLow)
            .clip(RoundedCornerShape(4.dp))
            .pointerInput(photo.key) {
                detectTapGestures(onDoubleTap = {
                    if (zoom > 1f) {
                        zoom = 1f
                        offset = Offset.Zero
                    } else {
                        zoom = 2f
                    }
                })
            }
            .pointerInput(photo.key) {
                detectTransformGestures { _, pan, scale, _ ->
                    val nextZoom = (zoom * scale).coerceIn(1f, 4f)
                    zoom = nextZoom
                    val maxX = size.width * (nextZoom - 1f) / 2f
                    val maxY = size.height * (nextZoom - 1f) / 2f
                    offset = if (nextZoom <= 1f) Offset.Zero else Offset(
                        (offset.x + pan.x).coerceIn(-maxX, maxX),
                        (offset.y + pan.y).coerceIn(-maxY, maxY),
                    )
                }
            }
    } else {
        modifier.background(MaterialTheme.colorScheme.surfaceContainerLow)
    }
    Box(interactionModifier, contentAlignment = Alignment.Center) {
        when (val state = loadState) {
            is CameraPreviewLoadState.Loading -> if (large) {
                CircularProgressIndicator(Modifier.size(28.dp), strokeWidth = 2.dp)
            }
            is CameraPreviewLoadState.Loaded -> Image(
                state.bitmap.asImageBitmap(),
                photo.name,
                Modifier.fillMaxSize().graphicsLayer {
                    scaleX = zoom
                    scaleY = zoom
                    translationX = offset.x
                    translationY = offset.y
                },
                contentScale = ContentScale.Fit,
            )
            CameraPreviewLoadState.Unavailable -> Text(
                stringResource(R.string.camera_preview_unavailable),
                Modifier.padding(12.dp),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun DateOption(text: String, selected: Boolean, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().selectable(selected, role = Role.RadioButton, onClick = onClick).padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        RadioButton(selected, onClick = null); Text(text, Modifier.padding(start = 8.dp))
    }
}
@Composable private fun CameraEmpty(text: Int) { Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) { Text(stringResource(text)) } }
@Composable private fun bytes(size: Long): String = Formatter.formatShortFileSize(LocalContext.current, size)
private fun cameraTimeZone(legacy: Boolean): TimeZone =
    if (legacy) TimeZone.getTimeZone("GMT") else TimeZone.getDefault()
private fun formatCameraTime(value: Long, legacy: Boolean): String = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.ROOT).apply {
    timeZone = cameraTimeZone(legacy)
}.format(Date(value))
private fun dateKey(value: Long): String? = if (value in 946684800000L..4102444800000L) SimpleDateFormat("yyyy-MM-dd", Locale.ROOT).format(Date(value)) else null
private fun matches(photo: CameraPhoto, format: String, date: String?) = (format == "all" || photo.raw == (format == "RAW")) && (date == null || dateKey(photo.created) == date)
internal fun stageText(stage: SonyCameraConnection.Stage): Int = when (stage) {
    SonyCameraConnection.Stage.SCANNING -> R.string.camera_scanning
    SonyCameraConnection.Stage.PAIRING -> R.string.camera_pairing
    SonyCameraConnection.Stage.BLUETOOTH -> R.string.camera_bluetooth
    SonyCameraConnection.Stage.WIFI_STARTING -> R.string.camera_wifi_starting
    SonyCameraConnection.Stage.WIFI_CONFIRMATION -> R.string.camera_wifi_confirmation
    SonyCameraConnection.Stage.MANUAL_WIFI -> R.string.camera_manual_wifi
    SonyCameraConnection.Stage.NETWORK -> R.string.camera_network
}
