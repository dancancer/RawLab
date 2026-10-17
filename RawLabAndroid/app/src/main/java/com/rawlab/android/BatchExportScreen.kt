package com.rawlab.android

import android.net.Uri
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.border
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BatchExportScreen(
    model: BatchExportModel,
    storage: PhotoStorage,
    onBack: () -> Unit,
) {
    val context = LocalContext.current
    val state by model.state.collectAsStateWithLifecycle()
    var album by rememberSaveable { mutableStateOf(false) }
    var discard by remember { mutableStateOf(false) }
    var effectTarget by remember { mutableStateOf<BatchRow?>(null) }
    var format by rememberSaveable(state.job.id) { mutableStateOf(state.job.outputFormat) }
    var exportSizeKey by rememberSaveable(state.job.id) {
        mutableStateOf(exportSizeChoice(state.job.outputLongEdge).key)
    }
    var exportCustomSize by rememberSaveable(state.job.id) {
        mutableStateOf(if (state.job.outputLongEdge != null && exportSizeChoice(state.job.outputLongEdge) == ExportSizeChoice.CUSTOM)
            state.job.outputLongEdge.toString() else "")
    }
    var destination by rememberSaveable(state.job.id) { mutableStateOf<Uri?>(state.job.destination?.let(Uri::parse)) }
    val files = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { model.addUris(it) }
    val directory = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        if (uri != null) {
            runCatching { context.contentResolver.takePersistableUriPermission(uri, android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION or android.content.Intent.FLAG_GRANT_WRITE_URI_PERMISSION) }
            destination = uri
            model.setDestination(uri)
        }
    }
    BackHandler { if (state.phase !in setOf(BatchPhase.RUNNING, BatchPhase.PREPARING)) onBack() }

    if (album) {
        var selected by rememberSaveable { mutableStateOf(state.job.rows.map { it.id }) }
        AlbumScreen(storage, onBack = { album = false }, onFile = { album = false; files.launch(arrayOf("*/*")) },
            onPhoto = { uri -> selected = if (uri.toString() in selected) selected - uri.toString() else selected + uri.toString() },
            selectedPhotos = selected.toSet(), onDone = {
                state.job.rows.filter { it.id !in selected }.forEach { model.remove(it.id) }
                model.addUris(selected.filter { id -> state.job.rows.none { it.id == id } }.map(Uri::parse))
                album = false
            })
        return
    }

    Scaffold(topBar = {
        TopAppBar(title = { Text(stringResource(R.string.batch_export)) }, navigationIcon = {
            IconButton(onClick = onBack, enabled = state.phase != BatchPhase.RUNNING && state.phase != BatchPhase.PREPARING) {
                Icon(Icons.AutoMirrored.Outlined.ArrowBack, stringResource(R.string.back))
            }
        })
    }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            when (state.phase) {
                BatchPhase.SELECTING -> BatchConfirmContent(state, storage, format, destination,
                    ExportSizeChoice.fromKey(exportSizeKey), exportCustomSize,
                    onAlbum = { album = true }, onFiles = { files.launch(arrayOf("*/*")) },
                    onDirectory = { directory.launch(null) }, onAlbumOutput = { destination = null; model.setDestination(null) }, onFormat = { format = it },
                    onSize = { choice -> exportSizeKey = choice.key }, onCustomSize = { exportCustomSize = it },
                    onRemove = model::remove, onInspect = { effectTarget = it },
                    onStart = { model.start(format, destination, ExportSize.parse(ExportSizeChoice.fromKey(exportSizeKey), exportCustomSize)) })
                BatchPhase.PREPARING, BatchPhase.RUNNING -> BatchProgressContent(state, model::cancel)
                BatchPhase.COMPLETE, BatchPhase.CANCELLED, BatchPhase.FAILED -> BatchResultContent(state,
                    onRetry = model::retryFailed, onClose = onBack, onDirectory = { directory.launch(state.destination) },
                    onConfirm = model::confirmOutput, onDiscard = { discard = true })
            }
        }
    }
    if (discard) AlertDialog(onDismissRequest = { discard = false }, title = { Text(AppStrings.text(R.string.message_discard_batch_task)) },
        text = { Text(AppStrings.text(R.string.message_saved_photos_will_be_kept)) },
        confirmButton = { TextButton(onClick = { if (model.discard()) onBack(); discard = false }) { Text(AppStrings.text(R.string.message_discard_task)) } },
        dismissButton = { TextButton(onClick = { discard = false }) { Text(AppStrings.text(R.string.message_cancel)) } })
    effectTarget?.let { row ->
        var preview by remember(row.id) { mutableStateOf<android.graphics.Bitmap?>(null) }
        var error by remember(row.id) { mutableStateOf<String?>(null) }
        LaunchedEffect(row.id) {
            try { preview = model.preview(row.target) }
            catch (failure: Exception) { error = failure.message }
        }
        AlertDialog(onDismissRequest = { effectTarget = null }, title = { Text(row.target.displayName) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box(Modifier.fillMaxWidth().aspectRatio(1f), contentAlignment = Alignment.Center) {
                        preview?.let { Image(it.asImageBitmap(), row.target.displayName, Modifier.fillMaxSize(), contentScale = ContentScale.Fit) }
                        if (preview == null && error == null) CircularProgressIndicator()
                        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                    }
                }
            }, confirmButton = { TextButton(onClick = { effectTarget = null }) { Text(stringResource(R.string.confirm)) } })
    }
}

@Composable
private fun BatchConfirmContent(
    state: BatchExportState,
    storage: PhotoStorage,
    format: ExportFormat,
    destination: Uri?,
    sizeChoice: ExportSizeChoice,
    customSize: String,
    onAlbum: () -> Unit,
    onFiles: () -> Unit,
    onDirectory: () -> Unit,
    onAlbumOutput: () -> Unit,
    onFormat: (ExportFormat) -> Unit,
    onSize: (ExportSizeChoice) -> Unit,
    onCustomSize: (String) -> Unit,
    onRemove: (String) -> Unit,
    onInspect: (BatchRow) -> Unit,
    onStart: () -> Unit,
) {
    var showSettings by rememberSaveable { mutableStateOf(false) }
    val context = LocalContext.current
    val recipes = remember(context) { MasterRecipe.load(context) }
    val bundledFilms = remember(context) { Film.all + BundledLooks.load(context) }
    val sourceSettings = state.job.source.settings
    val sourceLookName = recipes.firstOrNull { it.id == sourceSettings.recipeID }?.let(AppStrings::recipeName)
        ?: if (sourceSettings.film == "neutral") stringResource(R.string.neutral_look)
        else bundledFilms.firstOrNull { it.id == sourceSettings.film }?.name ?: sourceSettings.film
    Column(Modifier.fillMaxSize()) {
    LazyColumn(Modifier.fillMaxWidth().weight(1f), contentPadding = PaddingValues(bottom = 12.dp)) {
        item {
            Text(AppStrings.text(R.string.message_adjustment_source), style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(20.dp, 16.dp, 20.dp, 8.dp))
            Row(Modifier.padding(horizontal = 20.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(Modifier.size(80.dp)) { BatchThumbnail(storage, state.job.source.identity.value, state.job.source.sourceFile) }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(state.job.source.displayName, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    val settings = state.job.source.settings
                    Text("$sourceLookName · ${String.format(java.util.Locale.ROOT, "%.0f", settings.strength * 100f)}%",
                        color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
                    Text(AppStrings.format(R.string.message_exposure_ev, settings.exposure), style = MaterialTheme.typography.bodySmall)
                }
            }
        }
        item {
            Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = onAlbum, modifier = Modifier.weight(1f)) { Icon(Icons.Outlined.PhotoLibrary, null); Spacer(Modifier.width(6.dp)); Text(AppStrings.text(R.string.message_select_multiple_from_album)) }
                OutlinedButton(onClick = onFiles, modifier = Modifier.weight(1f)) { Icon(Icons.Outlined.FolderOpen, null); Spacer(Modifier.width(6.dp)); Text(AppStrings.text(R.string.message_select_multiple_files)) }
            }
        }
        item {
            Text(AppStrings.format(R.string.message_target_photos_selected, state.selectedCount.toString()), style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.padding(20.dp, 20.dp, 20.dp, 8.dp))
        }
        if (state.job.rows.isEmpty()) item {
            Text(AppStrings.text(R.string.message_select_raw_photos_to_apply_the_current), color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp))
        }
        items(state.job.rows, key = { it.id }) { row ->
            Row(Modifier.fillMaxWidth().clickable { onInspect(row) }.padding(horizontal = 20.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(56.dp)) { BatchThumbnail(storage, row.target.sourceUri, row.target.sourceFile) }
                Spacer(Modifier.width(12.dp))
                Text(row.target.displayName, Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                TextButton(onClick = { onInspect(row) }) { Text(AppStrings.text(R.string.message_view)) }
                IconButton(onClick = { onRemove(row.id) }) { Icon(Icons.Outlined.Close, AppStrings.text(R.string.message_remove)) }
            }
        }
        item {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp)) {
                Text(AppStrings.text(R.string.message_all_adjustments), style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                TextButton(onClick = { showSettings = !showSettings }) { Text(if (showSettings) AppStrings.text(R.string.message_collapse) else AppStrings.text(R.string.message_expand)) }
            }
            if (showSettings) SettingsSummary(state.job.source.settings, sourceLookName)
        }
        item {
            Text(AppStrings.text(R.string.message_output), style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(20.dp, 16.dp, 20.dp, 4.dp))
            ExportFormatControls(format, onFormat, Modifier.padding(horizontal = 20.dp))
            Column(Modifier.padding(horizontal = 20.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (Build.VERSION.SDK_INT >= 29 && format.allowsGallery) {
                    FilterChip(selected = destination == null, onClick = onAlbumOutput, label = { Text(AppStrings.text(R.string.message_photo_gallery)) })
                }
                OutlinedButton(onClick = onDirectory) { Icon(Icons.Outlined.FolderOpen, null); Spacer(Modifier.width(4.dp)); Text(AppStrings.text(R.string.message_choose_directory)) }
            }
            ExportSizeControls(
                selected = sizeChoice,
                customText = customSize,
                onSelected = onSize,
                onCustomText = onCustomSize,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
            )
            Text(destination?.lastPathSegment ?: if (format.allowsGallery) AppStrings.text(R.string.message_photo_gallery)
                else AppStrings.text(R.string.message_choose_directory),
                Modifier.padding(horizontal = 20.dp), maxLines = 2, overflow = TextOverflow.Ellipsis)
            state.error?.let { Text(it, Modifier.padding(20.dp), color = MaterialTheme.colorScheme.error) }
        }
    }
    Text(AppStrings.text(R.string.message_for_this_export_only_each_photo_s), Modifier.padding(horizontal = 20.dp), style = MaterialTheme.typography.bodySmall)
    val longEdge = ExportSize.parse(sizeChoice, customSize)
    val sizeValid = sizeChoice != ExportSizeChoice.CUSTOM || longEdge != null
    Button(onClick = onStart, enabled = sizeValid && state.job.rows.isNotEmpty() && (destination != null || (Build.VERSION.SDK_INT >= 29 && format.allowsGallery)), modifier = Modifier.fillMaxWidth().padding(20.dp)) {
        Text(AppStrings.format(R.string.message_export_photos, state.job.rows.size.toString()))
    }
    }
}

private fun exportSizeChoice(longEdge: Int?): ExportSizeChoice = when (longEdge) {
    null -> ExportSizeChoice.ORIGINAL
    2048 -> ExportSizeChoice.EDGE_2048
    3000 -> ExportSizeChoice.EDGE_3000
    4096 -> ExportSizeChoice.EDGE_4096
    else -> ExportSizeChoice.CUSTOM
}

@Composable
private fun BatchProgressContent(state: BatchExportState, onCancel: () -> Unit) {
    Column(Modifier.fillMaxSize().padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(if (state.stopping) AppStrings.text(R.string.message_stopping) else if (state.phase == BatchPhase.PREPARING) AppStrings.text(R.string.message_preparing) else AppStrings.text(R.string.message_exporting), style = MaterialTheme.typography.titleLarge)
        LinearProgressIndicator(progress = { state.completionFraction }, modifier = Modifier.fillMaxWidth())
        Text(AppStrings.format(R.string.message_completed, state.successCount.toString(), state.job.rows.size.toString()))
        LazyColumn(Modifier.weight(1f)) { items(state.job.rows, key = { it.id }) { row -> BatchRowLine(row) } }
        OutlinedButton(onClick = onCancel, enabled = !state.stopping, modifier = Modifier.fillMaxWidth()) { Text(if (state.stopping) AppStrings.text(R.string.message_stopping) else stringResource(R.string.cancel)) }
    }
}

@Composable
private fun BatchResultContent(state: BatchExportState, onRetry: () -> Unit, onClose: () -> Unit,
    onDirectory: () -> Unit, onConfirm: (String, Boolean) -> Unit, onDiscard: () -> Unit) {
    Column(Modifier.fillMaxSize().padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(if (state.phase == BatchPhase.COMPLETE) AppStrings.text(R.string.message_export_complete) else if (state.failedCount > 0) AppStrings.text(R.string.message_some_exports_failed) else AppStrings.text(R.string.message_export_result), style = MaterialTheme.typography.titleLarge)
        Text(AppStrings.format(R.string.message_succeeded_failed_not_processed, state.successCount.toString(), state.failedCount.toString(), (state.unfinishedCount - state.failedCount).toString()))
        if (state.confirmationCount > 0) Text(stringResource(R.string.batch_confirmation_count, state.confirmationCount))
        state.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        LazyColumn(Modifier.weight(1f)) { items(state.job.rows, key = { it.id }) { row ->
            BatchRowLine(row)
            if (row.status == BatchRowStatus.NEEDS_CONFIRMATION) {
                Text(AppStrings.text(R.string.message_the_previous_save_result_is_uncertain_check), style = MaterialTheme.typography.bodySmall)
                Row {
                    TextButton(onClick = { onConfirm(row.id, true) }) { Text(AppStrings.text(R.string.message_output_found)) }
                    TextButton(onClick = { onConfirm(row.id, false) }) { Text(AppStrings.text(R.string.message_not_saved_export_again)) }
                }
            }
        } }
        if (state.unfinishedCount > 0) OutlinedButton(onClick = onDirectory, modifier = Modifier.fillMaxWidth()) { Icon(Icons.Outlined.FolderOpen, null); Text(AppStrings.text(R.string.message_choose_output_directory_again)) }
        if (state.unfinishedCount > 0) Button(onClick = onRetry, modifier = Modifier.fillMaxWidth()) { Icon(Icons.Outlined.Refresh, null); Spacer(Modifier.width(6.dp)); Text(if (state.failedCount == state.unfinishedCount) AppStrings.text(R.string.message_retry_failed_items) else AppStrings.text(R.string.message_continue_unfinished_items)) }
        OutlinedButton(onClick = onClose, modifier = Modifier.fillMaxWidth()) { Text(AppStrings.text(R.string.message_close)) }
        if (state.phase != BatchPhase.COMPLETE) TextButton(onClick = onDiscard, modifier = Modifier.fillMaxWidth()) { Text(AppStrings.text(R.string.message_discard_task)) }
    }
}

@Composable
private fun BatchRowLine(row: BatchRow) {
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        val icon = when (row.status) {
            BatchRowStatus.SUCCESS -> Icons.Outlined.CheckCircle
            BatchRowStatus.FAILED -> Icons.Outlined.Close
            else -> Icons.Outlined.Refresh
        }
        Icon(icon, null, tint = if (row.status == BatchRowStatus.FAILED) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary)
        Spacer(Modifier.width(8.dp))
        Column(Modifier.weight(1f)) {
            Text(row.target.displayName, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(when (row.status) {
                BatchRowStatus.PENDING -> AppStrings.text(R.string.message_waiting_to_export)
                BatchRowStatus.PROCESSING -> AppStrings.text(R.string.message_processing)
                BatchRowStatus.PUBLISHING -> AppStrings.text(R.string.message_saving)
                BatchRowStatus.NEEDS_CONFIRMATION -> AppStrings.text(R.string.message_awaiting_confirmation)
                BatchRowStatus.SUCCESS -> AppStrings.text(R.string.message_saved)
                BatchRowStatus.FAILED -> AppStrings.text(R.string.message_failed)
                BatchRowStatus.CANCELLED -> AppStrings.text(R.string.message_cancelled)
            }, style = MaterialTheme.typography.labelSmall)
            row.error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
        }
    }
}

@Composable
private fun SettingsSummary(settings: EditSettings, lookName: String) {
    Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        SettingLine(AppStrings.text(R.string.message_film), lookName)
        SettingLine(AppStrings.text(R.string.grain_amount), String.format(java.util.Locale.ROOT, "%.0f%%", settings.strength * 100))
        SettingLine(AppStrings.text(R.string.message_exposure), String.format(java.util.Locale.ROOT, "%+.2f EV", settings.exposure))
        SettingLine(AppStrings.text(R.string.exposure_basis), listOf(AppStrings.text(R.string.exposure_scene), AppStrings.text(R.string.exposure_preview), AppStrings.text(R.string.exposure_sensor))[settings.exposureMode])
        SettingLine("HSL", if (settings.hsl.isIdentity) AppStrings.text(R.string.hsl_unadjusted) else AppStrings.text(R.string.hsl_adjusted))
        SettingLine(AppStrings.text(R.string.message_highlights), String.format(java.util.Locale.ROOT, "%+.0f%%", settings.highlights * 100))
        SettingLine(AppStrings.text(R.string.message_shadows), String.format(java.util.Locale.ROOT, "%+.0f%%", settings.shadows * 100))
        SettingLine(AppStrings.text(R.string.message_contrast), String.format(java.util.Locale.ROOT, "%+.0f%%", settings.contrast * 100))
        SettingLine(AppStrings.text(R.string.message_s_curve), String.format(java.util.Locale.ROOT, "%+.0f%%", settings.toneCurve * 100))
        SettingLine(AppStrings.text(R.string.message_saturation), String.format(java.util.Locale.ROOT, "%+.0f%%", settings.saturation * 100))
        SettingLine(AppStrings.text(R.string.message_white_balance), if (settings.customWb) AppStrings.text(R.string.message_custom) else AppStrings.text(R.string.message_as_shot_for_each_photo))
        if (settings.customWb) {
            SettingLine(AppStrings.text(R.string.message_temperature), String.format(java.util.Locale.ROOT, "%.0f K", settings.temperature))
            SettingLine(AppStrings.text(R.string.message_tint), String.format(java.util.Locale.ROOT, "%+.0f", settings.tint))
        }
        SettingLine(AppStrings.text(R.string.message_sharpening), String.format(java.util.Locale.ROOT, "%.0f%%", settings.sharpening * 100))
        SettingLine(AppStrings.text(R.string.message_denoise), if (settings.denoise.enabled) AppStrings.text(R.string.message_on) else AppStrings.text(R.string.disabled))
        SettingLine(AppStrings.text(R.string.message_luma_denoise), String.format(java.util.Locale.ROOT, "%.0f", settings.denoise.luma))
        SettingLine(AppStrings.text(R.string.message_chroma_denoise), String.format(java.util.Locale.ROOT, "%.0f", settings.denoise.chroma))
        SettingLine(AppStrings.text(R.string.message_coarse_grain_denoise), String.format(java.util.Locale.ROOT, "%.0f", settings.denoise.coarse))
        SettingLine(AppStrings.text(R.string.lens_matching), if (settings.lens.manual) AppStrings.text(R.string.lens_manual) else AppStrings.text(R.string.lens_automatic))
        SettingLine(AppStrings.text(R.string.lens_distortion_short), if (settings.lens.distortion) AppStrings.text(R.string.message_on) else AppStrings.text(R.string.disabled))
        SettingLine(AppStrings.text(R.string.lens_tca), if (settings.lens.tca) AppStrings.text(R.string.message_on) else AppStrings.text(R.string.disabled))
        SettingLine(AppStrings.text(R.string.lens_auto_crop), if (settings.lens.autoCrop) AppStrings.text(R.string.message_on) else AppStrings.text(R.string.disabled))
        Text(AppStrings.text(R.string.geometry), style = MaterialTheme.typography.labelLarge)
        Text(AppStrings.format(R.string.geometry_summary,
            settings.geometry.cropX * 100f, settings.geometry.cropY * 100f,
            settings.geometry.cropWidth * 100f, settings.geometry.cropHeight * 100f,
            settings.geometry.quarterTurns * 90, settings.geometry.straightenDegrees),
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        SettingLine(AppStrings.text(R.string.geometry_flip_horizontal), if (settings.geometry.flipHorizontal) AppStrings.text(R.string.message_on) else AppStrings.text(R.string.disabled))
        SettingLine(AppStrings.text(R.string.geometry_flip_vertical), if (settings.geometry.flipVertical) AppStrings.text(R.string.message_on) else AppStrings.text(R.string.disabled))
        SettingLine(AppStrings.text(R.string.geometry_perspective_horizontal), String.format(java.util.Locale.ROOT, "%+.0f%%", settings.geometry.perspectiveHorizontal * 100f))
        SettingLine(AppStrings.text(R.string.geometry_perspective_vertical), String.format(java.util.Locale.ROOT, "%+.0f%%", settings.geometry.perspectiveVertical * 100f))
        SettingLine(AppStrings.text(R.string.display_chroma_denoise), AppStrings.text(when (settings.displayChromaDenoise) {
            1 -> R.string.denoise_detail
            2 -> R.string.denoise_clean
            else -> R.string.disabled
        }))
        SettingLine(AppStrings.text(R.string.vignette), AppStrings.format(R.string.vignette_summary,
            settings.effects.vignetteAmount, settings.effects.vignetteMidpoint, settings.effects.vignetteRoundness,
            settings.effects.vignetteFeather, settings.effects.vignetteHighlights))
        SettingLine(AppStrings.text(R.string.grain), AppStrings.format(R.string.grain_summary,
            settings.effects.grainAmount, settings.effects.grainSize, settings.effects.grainRoughness))
    }
}

@Composable
private fun SettingLine(title: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp)) { Text(title, Modifier.weight(1f)); Text(value, color = MaterialTheme.colorScheme.onSurfaceVariant) }
}

@Composable
private fun BatchThumbnail(storage: PhotoStorage, uri: String?, file: java.io.File) {
    val thumbnail by produceState<android.graphics.Bitmap?>(null, uri) {
        value = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            uri?.let { storage.thumbnail(Uri.parse(it)) } ?: runCatching {
                val exif = androidx.exifinterface.media.ExifInterface(file)
                val original = exif.thumbnailBitmap ?: return@runCatching null
                val matrix = android.graphics.Matrix().apply {
                    if (exif.isFlipped) postScale(-1f, 1f)
                    postRotate(exif.rotationDegrees.toFloat())
                }
                android.graphics.Bitmap.createBitmap(original, 0, 0, original.width, original.height, matrix, true)
            }.getOrNull()
        }
    }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        thumbnail?.let { Image(it.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Fit) }
            ?: Icon(Icons.Outlined.PhotoLibrary, null)
    }
}
