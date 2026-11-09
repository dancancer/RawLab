package com.rawlab.android.camera

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.text.format.Formatter
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.NavigateBefore
import androidx.compose.material.icons.automirrored.outlined.NavigateNext
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.PhotoCamera
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.rawlab.android.R
import java.text.DateFormat
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CameraImportScreen(model: CameraImportViewModel, onBack: () -> Unit, onOpen: (List<Uri>) -> Unit,
    showTask: Boolean = false, onTaskShown: () -> Unit = {}, onViewInAlbum: (List<Uri>) -> Unit = {}) {
    val state by model.state.collectAsStateWithLifecycle()
    val browseGrid = rememberLazyGridState()
    val selectionGrid = rememberLazyGridState()
    val scope = rememberCoroutineScope()
    var page by rememberSaveable { mutableStateOf("browse") }
    var previewKey by rememberSaveable { mutableStateOf<String?>(null) }
    var format by rememberSaveable { mutableStateOf("RAW") }
    var date by rememberSaveable { mutableStateOf<String?>(null) }
    var selectedOnly by rememberSaveable { mutableStateOf(false) }
    var filterOpen by rememberSaveable { mutableStateOf(false) }
    var destinationOpen by rememberSaveable { mutableStateOf(false) }
    var draftFormat by rememberSaveable { mutableStateOf("RAW") }
    var draftDate by rememberSaveable { mutableStateOf<String?>(null) }
    var menu by remember { mutableStateOf(false) }
    var reconnectingJob by rememberSaveable { mutableStateOf<String?>(null) }
    val context = LocalContext.current
    val permissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        if (result.values.all { it }) model.scan() else model.permissionDenied()
    }
    fun findCamera() {
        if (Build.VERSION.SDK_INT < 29) { model.scan(); return }
        val required = buildList {
            add(Manifest.permission.ACCESS_FINE_LOCATION)
            add(Manifest.permission.ACCESS_COARSE_LOCATION)
            if (Build.VERSION.SDK_INT >= 31) { add(Manifest.permission.BLUETOOTH_SCAN); add(Manifest.permission.BLUETOOTH_CONNECT) }
            if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.NEARBY_WIFI_DEVICES)
        }.filter { context.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (required.isEmpty()) model.scan() else permissions.launch(required.toTypedArray())
    }
    DisposableEffect(model) { onDispose { model.cancelOpening() } }
    fun back() {
        reconnectingJob = null
        model.cancelOpening()
        when {
            previewKey != null -> previewKey = null
            page != "browse" -> page = "browse"
            else -> onBack()
        }
    }
    BackHandler(onBack = ::back)
    LaunchedEffect(state.connected, reconnectingJob) {
        if (state.connected && reconnectingJob != null && state.job?.id == reconnectingJob) {
            reconnectingJob = null
            page = "task"
        }
    }
    LaunchedEffect(showTask) {
        if (showTask) { previewKey = null; page = "task"; onTaskShown() }
    }
    val preview = state.photos.find { it.key == previewKey }
    val filtered = remember(state.photos, format, date, selectedOnly, state.selected) {
        state.photos.filter { photo -> if (selectedOnly) photo.key in state.selected
            else matches(photo, format, date) }
    }
    val selected = state.photos.filter { it.key in state.selected }
    val title = when {
        preview != null -> R.string.camera_preview
        page == "history" -> R.string.camera_history
        page == "task" -> R.string.camera_progress
        else -> R.string.camera_import
    }
    Scaffold(topBar = {
        TopAppBar(title = { Text(stringResource(title), style = MaterialTheme.typography.titleMedium) }, navigationIcon = {
            IconButton(onClick = ::back, modifier = Modifier.testTag("camera-back")) {
                Icon(Icons.AutoMirrored.Outlined.ArrowBack, stringResource(R.string.back))
            }
        }, actions = {
            if (preview == null) IconButton(onClick = { destinationOpen = true }, enabled = !state.transferring && !state.preparing,
                modifier = Modifier.testTag("camera-destination-settings")) {
                Icon(Icons.Outlined.FolderOpen, stringResource(R.string.camera_save_location))
            }
            if (preview == null) IconButton(onClick = { model.cancelOpening(); page = "history" }, modifier = Modifier.testTag("camera-history")) {
                Icon(Icons.Outlined.History, stringResource(R.string.camera_history))
            }
            if (state.connected || state.stage != null) Box {
                IconButton(onClick = { menu = true }) { Icon(Icons.Outlined.MoreVert, stringResource(R.string.more)) }
                DropdownMenu(menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text(stringResource(R.string.camera_disconnect)) }, onClick = {
                        menu = false; model.disconnect()
                    })
                }
            }
        })
    }, bottomBar = {
        if (preview != null || (page == "task" && state.job != null) || (page == "browse" && state.connected))
        Surface(modifier = Modifier.fillMaxWidth(), tonalElevation = 2.dp) {
            Column(Modifier.navigationBarsPadding().padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                when {
                    preview != null -> {
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            val index = filtered.indexOfFirst { it.key == preview.key }
                            IconButton(onClick = { previewKey = filtered[index - 1].key }, enabled = index > 0) {
                                Icon(Icons.AutoMirrored.Outlined.NavigateBefore, stringResource(R.string.camera_previous))
                            }
                            Button(onClick = { model.toggle(preview) }, enabled = !state.transferring, modifier = Modifier.weight(1f)) {
                                Text(stringResource(if (preview.key in state.selected) R.string.camera_deselect else R.string.camera_select))
                            }
                            IconButton(onClick = { previewKey = filtered[index + 1].key }, enabled = index >= 0 && index + 1 < filtered.size) {
                                Icon(Icons.AutoMirrored.Outlined.NavigateNext, stringResource(R.string.camera_next))
                            }
                        }
                    }
                    page == "task" && state.job != null -> {
                        val job = state.job!!
                        if (state.transferring) OutlinedButton(onClick = model::stop, modifier = Modifier.fillMaxWidth().testTag("camera-stop")) {
                            Text(stringResource(R.string.camera_stop))
                        } else if (job.status != CameraJobStatus.COMPLETE) {
                            Button(onClick = { if (state.connected) model.resume() else { reconnectingJob = job.id; page = "browse"; findCamera() } },
                                enabled = !state.preparing, modifier = Modifier.fillMaxWidth().testTag("camera-resume")) {
                                Text(stringResource(if (job.items.any { it.problem != null }) R.string.camera_retry_originals
                                    else if (state.connected) R.string.camera_resume else R.string.camera_find))
                            }
                        }
                        if (job.savedCount > 0 && !state.transferring) Button(onClick = { model.openSaved(onOpen) },
                            enabled = !state.preparing, modifier = Modifier.fillMaxWidth().testTag("camera-open")) {
                            Text(stringResource(if (job.items.mapNotNull { it.saved }.distinct().size == 1) R.string.camera_open else R.string.camera_collection))
                        }
                        if (job.savedCount > 0 && !state.transferring) OutlinedButton(onClick = { model.openSaved(onViewInAlbum) },
                            enabled = !state.preparing, modifier = Modifier.fillMaxWidth().testTag("camera-view-album")) {
                            Text(stringResource(R.string.camera_view_album))
                        }
                        if (!state.transferring) TextButton(onClick = { page = "browse" }, modifier = Modifier.fillMaxWidth()) {
                            Text(stringResource(R.string.camera_back_photos))
                        }
                    }
                    page == "browse" && state.connected -> {
                        TextButton(onClick = { destinationOpen = true }, enabled = !state.transferring && !state.preparing,
                            modifier = Modifier.fillMaxWidth()) {
                            Text(stringResource(R.string.camera_destination_summary, destinationDescription(state.destination)),
                                style = MaterialTheme.typography.bodySmall)
                        }
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Text(stringResource(R.string.camera_selection_count, selected.size, bytes(selected.sumOf { it.size })),
                                Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                            TextButton(onClick = model::clearSelection, enabled = selected.isNotEmpty() && !state.transferring) {
                                Text(stringResource(R.string.camera_clear))
                            }
                        }
                        if (!selectedOnly && selected.any { !matches(it, format, date) }) Text(stringResource(R.string.camera_hidden_selected),
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Button(onClick = { model.startImport(); page = "task" }, enabled = selected.isNotEmpty() && !state.transferring && !state.preparing,
                            modifier = Modifier.fillMaxWidth().testTag("camera-import")) { Text(stringResource(R.string.camera_import_count, selected.size)) }
                    }
                }
            }
        }
    }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            state.message?.takeUnless { page == "task" && state.job?.status == CameraJobStatus.PAUSED && it == R.string.camera_paused }?.let { message ->
                Surface(color = MaterialTheme.colorScheme.surfaceContainerHigh) {
                    Row(Modifier.fillMaxWidth().padding(start = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(stringResource(message), Modifier.weight(1f).padding(vertical = 12.dp), style = MaterialTheme.typography.bodyMedium)
                        IconButton(onClick = model::dismissMessage) { Icon(Icons.Outlined.Close, stringResource(R.string.message_close)) }
                    }
                }
            }
            when {
                preview != null -> {
                    CameraImage(model, preview, large = true, refresh = state.connected, busy = state.transferring, modifier = Modifier.weight(1f).fillMaxWidth())
                    Column(Modifier.padding(16.dp)) {
                        Text(preview.name, style = MaterialTheme.typography.titleMedium)
                        Text("${if (preview.raw) "RAW" else "JPEG"} · ${bytes(preview.size)}", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                page == "history" -> {
                    if (state.jobs.isEmpty()) CameraEmpty(R.string.camera_no_history)
                    else LazyColumn(Modifier.fillMaxSize()) {
                        items(state.jobs, key = { it.id }) { job ->
                            Column(Modifier.fillMaxWidth().clickable(enabled = !state.transferring || state.job?.id == job.id) {
                                model.selectJob(job); page = "task"
                            }.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text(DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(job.createdAt)), style = MaterialTheme.typography.titleSmall)
                                Text(stringResource(R.string.camera_saved_count, job.savedCount, job.items.size))
                                Text(stringResource(if (job.items.any { it.problem != null }) R.string.camera_original_unavailable
                                    else if (job.status == CameraJobStatus.COMPLETE) R.string.camera_complete else R.string.camera_paused),
                                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            HorizontalDivider()
                        }
                    }
                }
                page == "task" -> CameraTask(state)
                state.connected -> {
                    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                            Text("α7C II", style = MaterialTheme.typography.titleSmall)
                            Text(stringResource(R.string.camera_connected), color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.labelLarge)
                        }
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedButton(onClick = { draftFormat = format; draftDate = date; filterOpen = true }, modifier = Modifier.testTag("camera-filter")) {
                                Text(if (format == "all") stringResource(R.string.camera_all) else format)
                            }
                            FilterChip(selected = selectedOnly, onClick = { selectedOnly = !selectedOnly }, label = { Text(stringResource(R.string.camera_selected)) })
                        }
                        if (state.job != null) TextButton(onClick = { page = "task" }, modifier = Modifier.testTag("camera-view-task")) {
                            Text(stringResource(R.string.camera_view_task))
                        }
                    }
                    if (filtered.isEmpty()) CameraEmpty(if (state.photos.isEmpty()) R.string.camera_empty else R.string.camera_no_matches)
                    else {
                        val fontScale = LocalDensity.current.fontScale
                        LazyVerticalGrid(state = if (selectedOnly) selectionGrid else browseGrid, columns = GridCells.Adaptive(if (fontScale >= 1.4f) 280.dp else 156.dp),
                            modifier = Modifier.weight(1f).testTag("camera-grid"), contentPadding = PaddingValues(12.dp),
                            horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                            items(filtered, key = { it.key }) { photo ->
                                val checked = photo.key in state.selected
                                val saved = state.jobs.any { job -> job.cameraId == state.cameraId && job.items.any { it.photo.key == photo.key && it.saved != null } }
                                Column(Modifier.fillMaxWidth().border(if (checked) 2.dp else 1.dp,
                                    if (checked) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant, MaterialTheme.shapes.small)
                                    .selectable(checked, enabled = !state.transferring, role = Role.Checkbox, onClick = { model.toggle(photo) })
                                    .testTag("camera-item-${photo.key}")) {
                                    Box {
                                        CameraImage(model, photo, false, state.connected, state.transferring, Modifier.fillMaxWidth().aspectRatio(1.4f))
                                        Checkbox(checked, onCheckedChange = null, modifier = Modifier.align(Alignment.TopEnd).background(MaterialTheme.colorScheme.surface.copy(alpha = .85f)))
                                    }
                                    Column(Modifier.padding(horizontal = 8.dp, vertical = 4.dp)) {
                                        Text(photo.name, style = MaterialTheme.typography.labelLarge)
                                        Text("${if (photo.raw) "RAW" else "JPEG"} · ${bytes(photo.size)}", style = MaterialTheme.typography.bodySmall,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                                        if (saved) Row(verticalAlignment = Alignment.CenterVertically) {
                                            Icon(Icons.Outlined.CheckCircle, null, Modifier.size(16.dp)); Spacer(Modifier.width(4.dp))
                                            Text(stringResource(R.string.camera_saved), style = MaterialTheme.typography.labelSmall)
                                        }
                                    }
                                    TextButton(onClick = { previewKey = photo.key }, modifier = Modifier.fillMaxWidth().testTag("camera-preview-${photo.key}")) {
                                        Text(stringResource(R.string.camera_preview))
                                    }
                                }
                            }
                        }
                    }
                }
                else -> {
                    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
                        Icon(Icons.Outlined.PhotoCamera, null, Modifier.size(40.dp), tint = MaterialTheme.colorScheme.primary)
                        Text(stringResource(R.string.camera_intro), style = MaterialTheme.typography.bodyLarge)
                        Text(stringResource(R.string.camera_supported), color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
                        TextButton(onClick = { destinationOpen = true }, enabled = !state.transferring && !state.preparing) {
                            Text(stringResource(R.string.camera_destination_summary, destinationDescription(state.destination)),
                                style = MaterialTheme.typography.bodySmall)
                        }
                        state.stage?.let { stage ->
                            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                                LinearProgressIndicator(Modifier.fillMaxWidth())
                                Text(stringResource(stageText(stage)), style = MaterialTheme.typography.titleSmall)
                            }
                        }
                        state.candidates.forEach { candidate ->
                            OutlinedButton(onClick = { model.connect(candidate.id) }, enabled = state.stage == SonyCameraConnection.Stage.SCANNING,
                                modifier = Modifier.fillMaxWidth().testTag("camera-candidate-${candidate.id}")) { Text(candidate.name) }
                        }
                        Button(onClick = ::findCamera, enabled = state.stage == null && !state.transferring && !state.preparing,
                            modifier = Modifier.fillMaxWidth().testTag("camera-find")) { Text(stringResource(R.string.camera_find)) }
                        if (state.stage != null) TextButton(onClick = model::disconnect, modifier = Modifier.fillMaxWidth()) {
                            Text(stringResource(R.string.camera_cancel_connection))
                        }
                        if (state.job != null) TextButton(onClick = { page = "task" }, modifier = Modifier.fillMaxWidth()) {
                            Text(stringResource(R.string.camera_view_task))
                        }
                        Text(stringResource(R.string.camera_no_original_deleted), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
    if (destinationOpen) CameraImportSettings(state.destination,
        onSave = { model.setDestination(it); destinationOpen = false }, onDismiss = { destinationOpen = false })
    if (filterOpen) ModalBottomSheet(onDismissRequest = { filterOpen = false },
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        val dates = state.photos.mapNotNull { dateKey(it.created) }.distinct().sortedDescending()
        val count = state.photos.count { matches(it, draftFormat, draftDate) }
        Column(Modifier.fillMaxWidth().fillMaxHeight(.9f).navigationBarsPadding().padding(horizontal = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(stringResource(R.string.camera_filter), style = MaterialTheme.typography.titleLarge)
            LazyColumn(Modifier.weight(1f)) {
                item {
                    Text(stringResource(R.string.camera_format), style = MaterialTheme.typography.labelLarge)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        listOf("RAW", "JPEG", "all").forEach { option ->
                            FilterChip(selected = draftFormat == option, onClick = { draftFormat = option },
                                label = { Text(if (option == "all") stringResource(R.string.camera_all) else option) })
                        }
                    }
                }
                item { DateOption(stringResource(R.string.camera_all_dates), draftDate == null) { draftDate = null } }
                items(dates) { value -> DateOption(value, draftDate == value) { draftDate = value } }
            }
            Button(onClick = { format = draftFormat; date = draftDate; selectedOnly = false; filterOpen = false
                scope.launch { browseGrid.scrollToItem(0) } }, modifier = Modifier.fillMaxWidth().testTag("camera-filter-apply")) {
                Text(stringResource(R.string.camera_filter_apply, count))
            }
            TextButton(onClick = { filterOpen = false }, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.cancel)) }
        }
    }

}

@Composable
private fun CameraTask(state: CameraImportState) {
    val job = state.job
    if (job == null) { CameraEmpty(R.string.camera_loading); return }
    Column(Modifier.fillMaxSize()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(stringResource(if (state.transferring) R.string.camera_progress else if (job.items.any { it.problem != null })
                R.string.camera_original_unavailable else if (job.status == CameraJobStatus.COMPLETE)
                R.string.camera_complete else R.string.camera_paused), style = MaterialTheme.typography.headlineSmall)
            Text(stringResource(R.string.camera_saved_count, job.savedCount, job.items.size))
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
                        (item.saved ?: item.unavailable)?.let { saved ->
                            Text(saved.relativePath + saved.displayName, style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                            if (item.captureDay == null) Text(stringResource(R.string.camera_unknown_capture_date),
                                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    Text(stringResource(when {
                        state.currentKey == item.photo.key -> R.string.camera_progress
                        item.problem == CameraMediaProblem.MISSING -> R.string.camera_original_missing
                        item.problem == CameraMediaProblem.CHANGED -> R.string.camera_original_changed
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
private fun dateKey(value: Long): String? = if (value in 946684800000L..4102444800000L) SimpleDateFormat("yyyy-MM-dd", Locale.ROOT).format(Date(value)) else null
private fun matches(photo: CameraPhoto, format: String, date: String?) = (format == "all" || photo.raw == (format == "RAW")) && (date == null || dateKey(photo.created) == date)
private fun stageText(stage: SonyCameraConnection.Stage): Int = when (stage) {
    SonyCameraConnection.Stage.SCANNING -> R.string.camera_scanning
    SonyCameraConnection.Stage.PAIRING -> R.string.camera_pairing
    SonyCameraConnection.Stage.BLUETOOTH -> R.string.camera_bluetooth
    SonyCameraConnection.Stage.WIFI_STARTING -> R.string.camera_wifi_starting
    SonyCameraConnection.Stage.WIFI_CONFIRMATION -> R.string.camera_wifi_confirmation
    SonyCameraConnection.Stage.NETWORK -> R.string.camera_network
}
