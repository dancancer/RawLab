package com.rawlab.android.camera

import android.app.DatePickerDialog
import android.app.TimePickerDialog
import android.graphics.Bitmap
import android.net.Uri
import android.text.format.Formatter
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.NavigateBefore
import androidx.compose.material.icons.automirrored.outlined.NavigateNext
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
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
    var draftFormat by rememberSaveable { mutableStateOf("all") }
    var draftDate by rememberSaveable { mutableStateOf<String?>(null) }
    var menu by remember { mutableStateOf(false) }
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
    val needsOriginalJpeg = state.job?.items?.any { it.problem == CameraMediaProblem.HDR_GAIN_MAP } == true
    val savedKeys = remember(state.jobs, state.cameraId, state.hardwareIdentity, state.photos) {
        val observed = state.photos.associateBy { it.key }
        state.jobs.asSequence()
            .filter { it.matchesCamera(state.cameraId, state.hardwareIdentity) }
            .flatMap { it.items.asSequence() }
            .filter { it.saved != null && observed[it.photo.key]?.let(it.photo::matchesSnapshot) == true }
            .map { it.photo.key }
            .toSet()
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
                    Icon(Icons.Outlined.FilterList, stringResource(R.string.camera_filter),
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
                        IconButton(onClick = { previewKey = filtered[index - 1].key }, enabled = index > 0) { Icon(Icons.AutoMirrored.Outlined.NavigateBefore, stringResource(R.string.camera_previous)) }
                        Button(onClick = { model.toggle(preview) }, enabled = !state.transferring, shape = CameraControlShape, modifier = Modifier.weight(1f)) {
                            Text(stringResource(if (preview.key in state.selected) R.string.camera_deselect else R.string.camera_select))
                        }
                        IconButton(onClick = { previewKey = filtered[index + 1].key }, enabled = index >= 0 && index + 1 < filtered.size) { Icon(Icons.AutoMirrored.Outlined.NavigateNext, stringResource(R.string.camera_next)) }
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
                            } else if (job.status != CameraJobStatus.COMPLETE) Button(onClick = { if (state.connected) model.resume() else onConnect(true) },
                                enabled = !state.preparing && !state.closing, shape = CameraControlShape, modifier = Modifier.fillMaxWidth().testTag("camera-resume")) {
                                Text(stringResource(if (job.items.any { it.problem != null }) R.string.camera_retry_originals else if (state.connected) R.string.camera_resume else R.string.camera_connect_action))
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
                            Icon(Icons.Outlined.ZoomIn, stringResource(R.string.camera_preview))
                        }
                        Button(onClick = { model.startImport(); page = "task" }, enabled = canImport,
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
            when {
                preview != null -> {
                    CameraImage(model, preview, true, state.connected, state.transferring, Modifier.weight(1f).fillMaxWidth())
                    Column(Modifier.padding(12.dp)) {
                        Text(preview.name, style = MaterialTheme.typography.titleSmall)
                        Text("${if (preview.raw) "RAW" else "JPEG"} · ${bytes(preview.size)}", style = MaterialTheme.typography.bodySmall,
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
                    CameraImportModeControls(state, model)
                    if (incremental) {
                        CameraIncrementalOptions(state, model)
                    } else if (filtered.isEmpty()) CameraEmpty(if (state.photos.isEmpty()) R.string.camera_empty else R.string.camera_no_matches)
                    else LazyVerticalGrid(state = if (selectedOnly) selectionGrid else browseGrid,
                        columns = GridCells.Fixed(if (LocalDensity.current.fontScale >= 1.4f) 2 else 3),
                        modifier = Modifier.fillMaxSize().testTag("camera-grid"), contentPadding = PaddingValues(8.dp),
                        horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
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
                                    Checkbox(checked, onCheckedChange = null, modifier = Modifier.align(Alignment.TopEnd))
                                    Text(if (photo.raw) "RAW" else "JPEG", Modifier.align(Alignment.BottomStart).background(Color.Black.copy(alpha = .65f)).padding(horizontal = 4.dp, vertical = 2.dp),
                                        color = Color.White, style = MaterialTheme.typography.labelSmall)
                                    if (saved) Icon(Icons.Outlined.CheckCircle, stringResource(R.string.camera_saved),
                                        Modifier.align(Alignment.BottomEnd).padding(4.dp).size(18.dp), tint = MaterialTheme.colorScheme.primary)
                                }
                                Text(photo.name, Modifier.padding(top = 4.dp), maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.labelMedium)
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
            if (needsOriginalJpeg) Text(stringResource(R.string.camera_jpeg_gain_map_keep_original),
                color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
            Text(stringResource(R.string.camera_saved_count, job.savedCount, job.items.size))
            job.incremental?.let { plan ->
                Text("${stringResource(R.string.camera_transfer_format)} · ${if (plan.format == CameraImportFormat.RAW_AND_JPEG) "RAW + JPEG" else plan.format.name}",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (job.items.any { job.jpegOptions(it) != null })
                    Text(stringResource(R.string.camera_jpeg_summary,
                        plan.jpeg.longEdge?.let { "$it px" } ?: stringResource(R.string.output_original_size),
                        java.text.NumberFormat.getPercentInstance().format(plan.jpeg.quality / 100.0)), style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
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
                        Text(bytes(item.photo.size), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        if (item.saveOriginalJpeg) Text(stringResource(R.string.camera_jpeg_original),
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        (item.saved ?: item.unavailable)?.let { saved ->
                            Text(saved.relativePath + saved.displayName, style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                            if (item.captureDay == null) Text(stringResource(R.string.camera_unknown_capture_date),
                                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    Text(stringResource(when {
                        state.currentKey == item.photo.key -> R.string.camera_progress
                        item.problem == CameraMediaProblem.MISSING || item.problem == CameraMediaProblem.REMOTE_MISSING -> R.string.camera_original_missing
                        item.problem == CameraMediaProblem.CHANGED -> R.string.camera_original_changed
                        item.problem == CameraMediaProblem.HDR_GAIN_MAP -> R.string.camera_jpeg_processing_failed
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
    Column(Modifier.fillMaxWidth()
        .padding(horizontal = 12.dp, vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.camera_import_mode), style = MaterialTheme.typography.titleSmall)
        if (state.stage == SonyCameraConnection.Stage.NETWORK)
            Text(stringResource(R.string.camera_incremental_scanning), style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("camera-incremental-scanning"))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilterChip(selected = state.importMode == CameraImportMode.MANUAL,
                onClick = { model.setImportMode(CameraImportMode.MANUAL) },
                label = { Text(stringResource(R.string.camera_import_mode_manual)) },
                modifier = Modifier.testTag("camera-import-mode-MANUAL"), shape = CameraControlShape)
            FilterChip(selected = state.importMode == CameraImportMode.INCREMENTAL,
                onClick = { model.setImportMode(CameraImportMode.INCREMENTAL) },
                label = { Text(stringResource(R.string.camera_import_mode_incremental)) },
                modifier = Modifier.testTag("camera-import-mode-INCREMENTAL"), shape = CameraControlShape)
        }
    }
}

@Composable
private fun CameraIncrementalOptions(state: CameraImportState, model: CameraImportViewModel) {
    val context = LocalContext.current
    val scan = state.incrementalScan
    var edgeText by remember(state.incrementalJpeg.longEdge) { mutableStateOf(state.incrementalJpeg.longEdge?.toString().orEmpty()) }
    var qualityText by remember(state.incrementalJpeg.quality) { mutableStateOf(state.incrementalJpeg.quality.toString()) }
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 6.dp)
        .testTag("camera-incremental-options"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.camera_transfer_format), style = MaterialTheme.typography.labelLarge)
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            listOf(CameraImportFormat.RAW, CameraImportFormat.JPEG, CameraImportFormat.RAW_AND_JPEG).forEach { format ->
                FilterChip(selected = state.incrementalFormat == format, onClick = { model.setIncrementalFormat(format) },
                    label = { Text(if (format == CameraImportFormat.RAW_AND_JPEG) "RAW + JPEG" else format.name) },
                    modifier = Modifier.testTag("camera-incremental-format-${format.name}"), shape = CameraControlShape)
            }
        }
        Text(stringResource(R.string.camera_incremental_cutoff), style = MaterialTheme.typography.labelLarge)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(R.string.camera_incremental_range,
                scan?.let { formatCameraTime(it.startMillis, state.legacyCameraTime) }
                    ?: stringResource(R.string.camera_incremental_camera_time)),
                Modifier.weight(1f), style = MaterialTheme.typography.bodySmall)
            TextButton(onClick = {
                val zone = cameraTimeZone(state.legacyCameraTime)
                val current = Calendar.getInstance(zone).apply { timeInMillis = scan?.startMillis ?: System.currentTimeMillis() }
                DatePickerDialog(context, { _, year, month, day ->
                    TimePickerDialog(context, { _, hour, minute ->
                        model.setIncrementalCutoff(Calendar.getInstance(zone).apply {
                            set(year, month, day, hour, minute, 0); set(Calendar.MILLISECOND, 0)
                        }.timeInMillis)
                    }, current.get(Calendar.HOUR_OF_DAY), current.get(Calendar.MINUTE), true).show()
                }, current.get(Calendar.YEAR), current.get(Calendar.MONTH), current.get(Calendar.DAY_OF_MONTH)).show()
            }, modifier = Modifier.testTag("camera-incremental-cutoff")) { Text(stringResource(R.string.camera_incremental_cutoff)) }
            if (state.incrementalCutoffMillis != null) TextButton(onClick = { model.setIncrementalCutoff(null) },
                modifier = Modifier.testTag("camera-incremental-default-cutoff")) { Text(stringResource(R.string.camera_incremental_default_cutoff)) }
        }
        if ((scan?.undatedCount ?: 0) > 0 || state.incrementalIncludeUndated) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Checkbox(state.incrementalIncludeUndated, onCheckedChange = model::setIncrementalIncludeUndated,
                    modifier = Modifier.testTag("camera-incremental-include-undated"))
                Text(stringResource(R.string.camera_incremental_undated_count, scan?.undatedCount ?: 0), style = MaterialTheme.typography.bodySmall)
            }
        }
        if (state.stage == SonyCameraConnection.Stage.NETWORK) {
            Spacer(Modifier.height(4.dp))
        } else if (scan?.needsCutoffConfirmation == true) {
            Text(stringResource(R.string.camera_incremental_boundary_unverified), color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodySmall, modifier = Modifier.testTag("camera-incremental-boundary-unverified"))
        } else if (scan?.assets.isNullOrEmpty()) {
            Text(stringResource(R.string.camera_incremental_no_new), style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.testTag("camera-incremental-no-new"))
        } else {
            Text(stringResource(R.string.camera_incremental_pending_count, scan?.assets?.size ?: 0),
                style = MaterialTheme.typography.bodySmall, modifier = Modifier.testTag("camera-incremental-pending-count"))
        }
        TextButton(onClick = model::refreshIncrementalScan, enabled = !state.preparing && !state.transferring && state.stage == null,
            modifier = Modifier.testTag("camera-incremental-refresh")) { Text(stringResource(R.string.camera_incremental_refresh)) }
        if (state.incrementalFormat != CameraImportFormat.RAW) {
            Text(stringResource(R.string.camera_jpeg_settings), style = MaterialTheme.typography.labelLarge)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Switch(state.incrementalJpeg.adjust, onCheckedChange = {
                    model.setIncrementalJpeg(state.incrementalJpeg.copy(adjust = it))
                }, modifier = Modifier.testTag("camera-jpeg-adjust"))
                Text(stringResource(if (state.incrementalJpeg.adjust) R.string.camera_jpeg_adjusted else R.string.camera_jpeg_original),
                    Modifier.padding(start = 8.dp), style = MaterialTheme.typography.bodySmall)
            }
            if (state.incrementalJpeg.adjust) {
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    listOf(null to "original", 2048 to "2048", 3000 to "3000", 4096 to "4096").forEach { (edge, label) ->
                        FilterChip(selected = edgeText == edge?.toString().orEmpty(), onClick = {
                            edgeText = edge?.toString().orEmpty()
                            model.setIncrementalJpeg(state.incrementalJpeg.copy(longEdge = edge))
                            }, label = { Text(if (edge == null) stringResource(R.string.output_original_size) else label) },
                            modifier = Modifier.testTag("camera-jpeg-size-$label"), shape = CameraControlShape)
                    }
                }
                val edge = edgeText.toIntOrNull()
                val edgeInvalid = (edgeText.isBlank() && state.incrementalJpeg.longEdge != null) ||
                    (edgeText.isNotBlank() && edge !in 1..65_535)
                val quality = qualityText.toIntOrNull()
                val qualityInvalid = quality !in 1..100
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(edgeText, { value ->
                        edgeText = value
                        val parsed = value.toIntOrNull()
                        if (parsed in 1..65_535) model.setIncrementalJpeg(state.incrementalJpeg.copy(longEdge = parsed))
                        model.setIncrementalOptionsValid(parsed in 1..65_535 && !qualityInvalid)
                    }, label = { Text(stringResource(R.string.output_long_edge)) }, singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        isError = edgeInvalid, modifier = Modifier.weight(1f).testTag("camera-jpeg-size"))
                    OutlinedTextField(qualityText, { value ->
                        qualityText = value
                        val parsed = value.toIntOrNull()
                        parsed?.takeIf { it in 1..100 }?.let { model.setIncrementalJpeg(state.incrementalJpeg.copy(quality = it)) }
                        model.setIncrementalOptionsValid(parsed in 1..100 && !edgeInvalid)
                    }, label = { Text(stringResource(R.string.camera_jpeg_quality)) }, singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        isError = qualityInvalid, modifier = Modifier.weight(1f).testTag("camera-jpeg-quality"))
                }
                Text(stringResource(R.string.camera_jpeg_local_processing), style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun CameraImage(model: CameraImportViewModel, photo: CameraPhoto, large: Boolean, refresh: Boolean, busy: Boolean, modifier: Modifier) {
    val bitmap by produceState<Bitmap?>(null, photo.key, large, refresh, busy) { value = model.preview(photo, large) }
    Box(modifier.background(MaterialTheme.colorScheme.surfaceContainerLow), contentAlignment = Alignment.Center) {
        val image = bitmap
        if (image != null) Image(image.asImageBitmap(), photo.name, Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
        else Text(stringResource(R.string.camera_preview_unavailable), Modifier.padding(12.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
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
