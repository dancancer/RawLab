package com.rawlab.android.batch.ui

import android.net.Uri
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.rawlab.android.R
import com.rawlab.android.album.AlbumScreen
import com.rawlab.android.batch.CollectionExportReview
import com.rawlab.android.editor.collectionMessage
import com.rawlab.android.editor.CollectionSynchronization
import com.rawlab.android.editor.EditorViewModel
import com.rawlab.android.editor.ui.AdjustmentScopeEditor
import com.rawlab.android.editor.ui.AdjustmentSheet
import com.rawlab.android.editor.ui.AdjustmentTransferSheet
import com.rawlab.android.format.*
import com.rawlab.android.ui.ExportFormatControls
import com.rawlab.android.ui.ExportSizeControls

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun BatchSelectionScreen(model: EditorViewModel, onBack: () -> Unit, onEdit: () -> Unit) {
    val collection by model.collection.collectAsStateWithLifecycle()
    val editor by model.state.collectAsStateWithLifecycle()
    var album by remember { mutableStateOf(false) }
    var scope by remember { mutableStateOf(false) }
    var captureGeneration by remember { mutableIntStateOf(0) }
    fun closeScope() { captureGeneration++; scope = false }
    DisposableEffect(model) { onDispose { captureGeneration++ } }
    var synchronization by remember { mutableStateOf<CollectionSynchronization?>(null) }
    var history by remember { mutableStateOf(false) }
    var export by remember { mutableStateOf(false) }
    var pendingEdit by remember { mutableStateOf<String?>(null) }
    val list = rememberLazyListState(initialFirstVisibleItemIndex = collection.returnPosition.coerceAtMost((collection.photos.size - 1).coerceAtLeast(0)))
    val files = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { model.addCollectionPhotos(it) }
    LaunchedEffect(Unit) { model.refreshCollection() }
    BackHandler(enabled = !collection.busy) { onBack() }
    if (album) {
        var selected by remember { mutableStateOf(emptySet<String>()) }
        AlbumScreen(model.storage, onBack = { album = false }, onFile = { album = false; files.launch(arrayOf("*/*")) },
            onPhoto = { uri -> selected = if (uri.toString() in selected) selected - uri.toString() else selected + uri.toString() },
            selectedPhotos = selected, onDone = { model.addCollectionPhotos(selected.map(Uri::parse)); album = false })
        return
    }
    Scaffold(topBar = { TopAppBar(title = { Text(stringResource(R.string.collection_title)) }, navigationIcon = {
        TextButton(onClick = onBack, enabled = !collection.busy) { Text(stringResource(R.string.back)) }
    }) }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp).testTag("batch-selection-root"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row {
                TextButton(onClick = { album = true }, enabled = !collection.busy) { Text(stringResource(R.string.open_album)) }
                TextButton(onClick = { files.launch(arrayOf("*/*")) }, enabled = !collection.busy) { Text(stringResource(R.string.collection_add)) }
                TextButton(onClick = { model.selectCollectionAll(collection.selected.size != collection.photos.size) }, enabled = !collection.busy) {
                    Text(if (collection.selected.size == collection.photos.size) stringResource(R.string.collection_deselect_all) else stringResource(R.string.collection_select_all))
                }
            }
            Text(stringResource(R.string.collection_selected_count, collection.selected.size))
            if (collection.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            collection.error?.let { Text(collectionMessage(it), color = MaterialTheme.colorScheme.error) }
            if (collection.photos.isEmpty()) Text(stringResource(R.string.collection_empty))
            LazyColumn(Modifier.weight(1f), state = list, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(collection.photos, key = { it.id }) { photo ->
                    OutlinedCard(Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(8.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Checkbox(photo.id in collection.selected, { model.selectCollectionPhoto(photo.id, it) }, enabled = !collection.busy)
                                Box(Modifier.size(48.dp)) { BatchThumbnail(model.storage, photo.sourceUri, photo.sourceFile) }
                                Text(photo.displayName, Modifier.weight(1f).padding(horizontal = 8.dp))
                                TextButton(onClick = {
                                    if (editor.photo != null && model.collectionDraftFailure(editor.photo!!.identity.value) != null) pendingEdit = photo.id
                                    else model.editCollectionPhoto(photo.id) { if (it) onEdit() }
                                }, enabled = !collection.busy && photo.id !in collection.failures, modifier = Modifier.testTag("collection-edit-${photo.id}")) { Text(stringResource(R.string.collection_edit)) }
                            }
                            collection.failures[photo.id]?.let {
                                Text(collectionMessage(it), color = MaterialTheme.colorScheme.error)
                                TextButton(onClick = { model.addCollectionPhotos(listOf(Uri.parse(photo.sourceUri))) }, enabled = !collection.busy) { Text(stringResource(R.string.transfer_retry)) }
                            }
                            TextButton(onClick = { model.removeCollectionPhoto(photo.id) }, enabled = !collection.busy) { Text(stringResource(R.string.message_remove)) }
                        }
                    }
                }
            }
            val targets = editor.photo?.let { collection.synchronizationTargets(it.identity.value) }.orEmpty()
            Text(editor.photo?.let { stringResource(R.string.collection_source_targets, it.name, targets.size) } ?: stringResource(R.string.collection_choose_source))
            if (editor.photo != null && targets.isEmpty()) Text(stringResource(R.string.collection_no_sync_targets))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = { scope = true }, enabled = !collection.busy && targets.isNotEmpty(), modifier = Modifier.weight(1f).testTag("collection-sync")) { Text(stringResource(R.string.collection_sync)) }
                Button(onClick = { export = true }, enabled = !collection.busy && collection.selected.isNotEmpty(), modifier = Modifier.weight(1f).testTag("collection-export")) { Text(stringResource(R.string.collection_export)) }
            }
            if (collection.lastSynchronization != null) TextButton(onClick = { model.closeAdjustmentOperation(); history = true }, enabled = !collection.busy) { Text(stringResource(R.string.collection_sync_history)) }
        }
    }
    pendingEdit?.let { id ->
        AlertDialog(onDismissRequest = { pendingEdit = null }, title = { Text(stringResource(R.string.collection_resolve_draft)) },
            text = { Text(collectionMessage(model.collectionDraftFailure(editor.photo?.identity?.value.orEmpty()).orEmpty())) },
            confirmButton = { TextButton(onClick = {
                model.resolveCollectionDraft(true) { accepted -> if (accepted) model.editCollectionPhoto(id) { if (it) { pendingEdit = null; onEdit() } } }
            }) { Text(stringResource(R.string.collection_apply_draft)) } },
            dismissButton = { Row {
                TextButton(onClick = { model.resolveCollectionDraft(false) { accepted -> if (accepted) model.editCollectionPhoto(id) { if (it) { pendingEdit = null; onEdit() } } } }) { Text(stringResource(R.string.collection_discard_draft)) }
                TextButton(onClick = { pendingEdit = null }) { Text(stringResource(R.string.cancel)) }
            } })
    }
    if (scope) ModalBottomSheet(onDismissRequest = ::closeScope, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxHeight(.9f).verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(R.string.collection_sync), style = MaterialTheme.typography.titleLarge)
            Text(stringResource(R.string.collection_source_targets, editor.photo?.name.orEmpty(), editor.photo?.let { collection.synchronizationTargets(it.identity.value).size } ?: 0))
            val draft = editor.photo?.let { model.collectionDraftFailure(it.identity.value) }
            if (draft != null) {
                Text(collectionMessage(draft), color = MaterialTheme.colorScheme.error)
                TextButton(onClick = { model.resolveCollectionDraft(true) }) { Text(stringResource(R.string.collection_apply_draft)) }
                TextButton(onClick = { model.resolveCollectionDraft(false) }) { Text(stringResource(R.string.collection_discard_draft)) }
            }
            AdjustmentScopeEditor(stringResource(R.string.collection_check_targets), "collection-sync-preflight", enabled = draft == null && !editor.committingAdjustments,
                allowed = if (editor.edits.isHDREditing) com.rawlab.android.adjustments.AdjustmentField.HDR_SUPPORTED
                    else com.rawlab.android.adjustments.AdjustmentField.entries.filterNot { it.isHDRRelative }.toSet(),
                previewCapture = model::previewAdjustmentPayload, lookName = model::adjustmentSummaryLookName) { selected ->
                val generation = ++captureGeneration
                model.captureCollectionSynchronization(selected) { captured ->
                    if (scope && generation == captureGeneration) captured?.let { closeScope(); synchronization = it }
                }
            }
            TextButton(onClick = ::closeScope) { Text(stringResource(R.string.cancel)) }
        }
    }
    synchronization?.let { operation ->
        AdjustmentTransferSheet(model, AdjustmentSheet.PASTE, synchronization = operation) { synchronization = null }
    }
    if (history) AdjustmentTransferSheet(model, AdjustmentSheet.HISTORY, focusedHistory = collection.lastSynchronization) { history = false }
    if (export) CollectionExportSheet(model) { export = false }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CollectionExportSheet(model: EditorViewModel, onClose: () -> Unit) {
    val collection by model.collection.collectAsStateWithLifecycle()
    val editor by model.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    var skipped by remember { mutableStateOf(emptySet<String>()) }
    var format by remember { mutableStateOf(ExportFormat.JPEG) }
    var size by remember { mutableStateOf(ExportSizeChoice.ORIGINAL) }
    var custom by remember { mutableStateOf("") }
    var destination by remember { mutableStateOf<Uri?>(null) }
    var review by remember { mutableStateOf<CollectionExportReview?>(null) }
    val directory = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        if (uri != null) {
            runCatching { context.contentResolver.takePersistableUriPermission(uri,
                android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION or android.content.Intent.FLAG_GRANT_WRITE_URI_PERMISSION) }
            destination = uri; review = null
        }
    }
    LaunchedEffect(collection.selected, editor.adjustmentRevision) { review = null }
    ModalBottomSheet(onDismissRequest = { if (!collection.busy) onClose() },
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxHeight(.94f).padding(horizontal = 20.dp).testTag("collection-export-review"), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(R.string.collection_export), style = MaterialTheme.typography.titleLarge)
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (!collection.busy) {
                    ExportFormatControls(format, { format = it; review = null },
                        hdrEditing = collection.selectedPhotos.isNotEmpty() && collection.selectedPhotos.all { it.sourceIsHDR })
                    ExportSizeControls(size, custom, { size = it; review = null }, { custom = it; review = null })
                    TextButton(onClick = { directory.launch(destination) }) { Text(destination?.toString() ?: stringResource(R.string.collection_output_directory)) }
                    if (Build.VERSION.SDK_INT >= 29 && format.allowsGallery) TextButton(onClick = { destination = null; review = null }) { Text(stringResource(R.string.save_album)) }
                }
                Text(stringResource(R.string.collection_draft_hint))
                for (photo in collection.selectedPhotos) {
                    OutlinedCard(Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(photo.displayName, style = MaterialTheme.typography.titleMedium)
                            val draft = model.collectionDraftFailure(photo.id)
                            val row = review?.rows?.firstOrNull { it.target.id == photo.id }
                            (row?.error ?: collection.failures[photo.id] ?: draft)?.let { Text(collectionMessage(it), color = MaterialTheme.colorScheme.error) }
                            if (draft != null && editor.photo?.identity?.value == photo.id) Row {
                                TextButton(onClick = { model.resolveCollectionDraft(true); review = null }, enabled = !collection.busy && photo.id !in skipped) { Text(stringResource(R.string.collection_apply_draft)) }
                                TextButton(onClick = { model.resolveCollectionDraft(false); review = null }, enabled = !collection.busy && photo.id !in skipped) { Text(stringResource(R.string.collection_discard_draft)) }
                            }
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Checkbox(photo.id in skipped, { checked -> skipped = if (checked) skipped + photo.id else skipped - photo.id; review = null }, enabled = !collection.busy)
                                Text(stringResource(R.string.collection_skip))
                            }
                            row?.settings?.let { settings ->
                                var expanded by remember { mutableStateOf(false) }
                                TextButton(onClick = { expanded = !expanded }) { Text(stringResource(R.string.collection_saved_settings)) }
                                if (expanded) SettingsSummary(settings, settings.film)
                            }
                        }
                    }
                }
                collection.error?.let { Text(collectionMessage(it), color = MaterialTheme.colorScheme.error) }
                review?.let { Text(stringResource(R.string.collection_export_count, it.rows.size), Modifier.testTag("collection-export-count")) }
            }
            val edge = ExportSize.parse(size, custom)
            val valid = (size != ExportSizeChoice.CUSTOM || edge != null) && (destination != null || (format.allowsGallery && Build.VERSION.SDK_INT >= 29))
            val count = collection.selectedPhotos.count { it.id !in skipped }
            if (count == 0) Text(stringResource(R.string.collection_no_export_targets))
            if (collection.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            if (review?.ready == true) Button(onClick = { model.freezeCollectionExport(review!!) { success -> review = null; if (success) onClose() } },
                enabled = !collection.busy, modifier = Modifier.fillMaxWidth().testTag("collection-export-freeze")) { Text(stringResource(R.string.collection_freeze)) }
            else Button(onClick = { model.prepareCollectionExport(skipped, format, edge, destination) { review = it } },
                enabled = !collection.busy && valid && count > 0, modifier = Modifier.fillMaxWidth().testTag("collection-export-preflight")) { Text(stringResource(R.string.collection_review)) }
            TextButton(onClick = onClose, enabled = !collection.busy, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.cancel)) }
        }
    }
}
