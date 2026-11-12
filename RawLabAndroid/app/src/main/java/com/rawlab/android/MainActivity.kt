package com.rawlab.android

import com.rawlab.android.camera.CameraImportScreen
import com.rawlab.android.camera.CameraImportViewModel
import com.rawlab.android.editor.controls.HslTargetActions

import android.os.Build
import android.os.Bundle
import android.content.Intent
import android.net.Uri
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.SystemBarStyle
import androidx.compose.foundation.background
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import com.rawlab.android.about.AboutDialog
import com.rawlab.android.about.UpdateViewModel
import com.rawlab.android.album.AlbumScreen
import com.rawlab.android.analytics.UsageAnalytics
import com.rawlab.android.analytics.UsageEvent
import com.rawlab.android.analytics.setup.UsageAnalyticsRegistry
import com.rawlab.android.batch.ui.BatchSelectionScreen
import com.rawlab.android.batch.ui.BatchExportScreen
import com.rawlab.android.editor.EditorViewModel
import com.rawlab.android.photo.SystemPhotoIntent
import com.rawlab.android.editor.PendingDcpImport
import com.rawlab.android.editor.PendingLookCompatibility
import com.rawlab.android.editor.ui.DcpImportDialog
import com.rawlab.android.editor.ui.EditorScreen
import com.rawlab.android.editor.ui.LUTCompatibilityDialog
import com.rawlab.android.editor.ui.AdjustmentSheet
import com.rawlab.android.editor.ui.AdjustmentTransferSheet
import com.rawlab.android.editor.ui.AdjustmentPresetSheet
import com.rawlab.android.editor.ui.AdjustmentPresetAction
import com.rawlab.android.editor.ui.QuickPresetContent
import com.rawlab.android.presets.AdjustmentPreset
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.ExportSize
import com.rawlab.android.format.ExportSizeChoice
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.ui.EditorSheetSystemBars
import com.rawlab.android.ui.ExportFormatControls
import com.rawlab.android.ui.ExportSizeControls

class MainActivity : ComponentActivity() {
    override fun attachBaseContext(newBase: android.content.Context) {
        super.attachBaseContext(AppStrings.localizedContext(newBase))
    }
    val model: EditorViewModel by lazy { ViewModelProvider(this)[EditorViewModel::class.java] }
    internal val camera: CameraImportViewModel by lazy { ViewModelProvider(this)[CameraImportViewModel::class.java] }
    val updates: UpdateViewModel by lazy { ViewModelProvider(this)[UpdateViewModel::class.java] }
    val usage: UsageAnalytics by lazy { UsageAnalyticsRegistry.get(applicationContext) }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT))
        usage.beginSession()
        setContent { RawLabTheme { RawLabApp(model, updates, usage, camera) } }
        if (savedInstanceState == null) receivePhotoIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        receivePhotoIntent(intent)
    }

    @Suppress("DEPRECATION")
    private fun receivePhotoIntent(intent: Intent) {
        val streams = runCatching {
            if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
                if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
                else intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
            } else listOfNotNull(if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                                else intent.getParcelableExtra<android.os.Parcelable>(Intent.EXTRA_STREAM) as? Uri)
        }.getOrDefault(emptyList())
        val clip = intent.clipData?.let { data -> (0 until data.itemCount).mapNotNull { data.getItemAt(it).uri?.toString() } }.orEmpty()
        val uris = SystemPhotoIntent.uris(intent.action, intent.dataString, streams.map { it.toString() }, clip)
        val requestID = intent.getStringExtra(SystemPhotoForwarding.EXTRA_REQUEST_ID)
        model.receiveSystemPhotos(uris.map(Uri::parse), requestID ?: java.util.UUID.randomUUID().toString())
    }
}

@Composable
fun RawLabTheme(content: @Composable () -> Unit) {
    val scheme = darkColorScheme(
        primary = Color(0xFFF2CE48), onPrimary = Color(0xFF252110), secondary = Color(0xFF63CDD6),
        primaryContainer = Color(0xFF3D351C), onPrimaryContainer = Color(0xFFF2CE48),
        secondaryContainer = Color(0xFF3D351C), onSecondaryContainer = Color(0xFFF2CE48),
        surface = Color(0xFF272729), surfaceContainer = Color(0xFF272729),
        surfaceContainerHigh = Color(0xFF303033), surfaceContainerLow = Color(0xFF212124),
        surfaceContainerHighest = Color(0xFF303033), background = Color(0xFF1C1C1E),
        onSurface = Color(0xFFEEEEF2), onSurfaceVariant = Color(0xFFB9B9C3),
        outline = Color(0xFF85858E), outlineVariant = Color(0xFF444449), error = Color(0xFFFFB09B),
    )
    MaterialTheme(colorScheme = scheme, content = content)
}

@Composable
@OptIn(ExperimentalMaterial3Api::class)
private fun RawLabApp(model: EditorViewModel, updates: UpdateViewModel, usage: UsageAnalytics, camera: CameraImportViewModel) {
    val state by model.state.collectAsStateWithLifecycle()
    val quickPreset by model.quickPreset.collectAsStateWithLifecycle()
    var presetLibraryRevision by remember { mutableIntStateOf(0) }
    val hslTarget by model.hslTarget.collectAsStateWithLifecycle()
    val updateState by updates.state.collectAsStateWithLifecycle()
    val usageState by usage.state.collectAsStateWithLifecycle()
    var about by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(updates) { updates.check(manual = false) }
    var adjustmentSheet by remember { mutableStateOf<AdjustmentSheet?>(null) }
    var presetLibrary by remember { mutableStateOf(false) }
    var savingPreset by remember { mutableStateOf(false) }
    var selectedPreset by remember { mutableStateOf<AdjustmentPreset?>(null) }
    var presetAction by remember { mutableStateOf<AdjustmentPresetAction?>(null) }
    fun history(undo: Boolean) {
        model.performAdjustmentHistory(undo, completed = { results ->
            if (results.any { it.status in setOf(com.rawlab.android.adjustments.AdjustmentStatus.BLOCKED,
                    com.rawlab.android.adjustments.AdjustmentStatus.CONFLICT, com.rawlab.android.adjustments.AdjustmentStatus.FAILED) })
                adjustmentSheet = AdjustmentSheet.HISTORY
        })
    }
    var cameraOpen by rememberSaveable { mutableStateOf(false) }
    var cameraTaskRequested by remember { mutableStateOf(false) }
    val cameraState by camera.state.collectAsStateWithLifecycle()
    var album by rememberSaveable { mutableStateOf(false) }
    var albumFromCamera by rememberSaveable { mutableStateOf(false) }
    var albumPhotoFocus by rememberSaveable { mutableStateOf(emptyList<String>()) }
    var fileFromCameraAlbum by rememberSaveable { mutableStateOf(false) }
    var collectionOpen by rememberSaveable { mutableStateOf(false) }
    val collection by model.collection.collectAsStateWithLifecycle()
    val systemPhotoRequests by model.systemPhotoRequests.collectAsStateWithLifecycle()
    val batch by model.batch.collectAsStateWithLifecycle()
    val pendingBatch by model.pendingBatch.collectAsStateWithLifecycle()
    LaunchedEffect(systemPhotoRequests.firstOrNull()?.id, batch, collection.busy) {
        if (systemPhotoRequests.isNotEmpty() && batch == null && !collection.busy) { album = false; collectionOpen = false; cameraOpen = false }
    }
    val owner = LocalLifecycleOwner.current
    val context = LocalContext.current
    DisposableEffect(owner, model, camera) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_START) camera.onForeground()
            if (event == Lifecycle.Event.ON_STOP && (context as? android.app.Activity)?.isChangingConfigurations != true) {
                model.onBackground()
                camera.onBackground()
            }
        }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer) }
    }
    val editorVisible = !cameraOpen && batch == null && !collectionOpen && !album
    DisposableEffect(owner, model, editorVisible) {
        fun updateEditorActivity() {
            model.setEditorActive(editorVisible && owner.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))
        }
        val observer = LifecycleEventObserver { _, _ -> updateEditorActivity() }
        owner.lifecycle.addObserver(observer)
        updateEditorActivity()
        onDispose { owner.lifecycle.removeObserver(observer) }
    }
    DisposableEffect(cameraState.transferring) {
        val window = (context as? android.app.Activity)?.window
        if (cameraState.transferring) window?.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        onDispose { window?.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
    }
    var exportDialog by rememberSaveable { mutableStateOf(false) }
    var format by rememberSaveable { mutableStateOf(ExportFormat.JPEG) }
    var exportToAlbum by rememberSaveable { mutableStateOf(Build.VERSION.SDK_INT >= 29) }
    var exportSizeKey by rememberSaveable { mutableStateOf(ExportSizeChoice.ORIGINAL.key) }
    var exportCustomSize by rememberSaveable { mutableStateOf("") }
    var pendingExportLongEdgeText by rememberSaveable { mutableStateOf("") }
    var licenses by rememberSaveable { mutableStateOf(false) }
    val screenState = rememberSaveableStateHolder()
    val openFile = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (fileFromCameraAlbum && uri != null) {
            album = false
            model.receiveSystemPhotos(listOf(uri))
        } else model.importPhoto(uri) { accepted -> if (accepted) album = false }
        fileFromCameraAlbum = false
    }
    val openLook = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        model.importLooks(uris)
    }
    val openHDRLook = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument(), model::finishHDRLookImport)
    val openHDRCameraProfile = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument(), model::finishHDRCameraProfileImport)
    val saveJpeg = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("image/jpeg")) {
        if (it == null) exportDialog = true else model.export(it, format, pendingExportLongEdgeText.toIntOrNull())
    }
    val savePng = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("image/png")) {
        if (it == null) exportDialog = true else model.export(it, ExportFormat.PNG, pendingExportLongEdgeText.toIntOrNull())
    }
    val saveDng = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("image/x-adobe-dng")) {
        if (it == null) exportDialog = true else model.export(it, ExportFormat.DNG, pendingExportLongEdgeText.toIntOrNull())
    }
    if (cameraOpen) {
        com.rawlab.android.camera.CameraScreen(camera, model.storage, onBack = { cameraOpen = false; albumFromCamera = false },
            showTask = cameraTaskRequested, onTaskShown = { cameraTaskRequested = false }, onOpen = { uris ->
            // 原件交接仍走系统导入队列，由编辑器现有草稿门禁决定何时替换画布。
            model.receiveSystemPhotos(uris)
            cameraOpen = false
            albumFromCamera = false
        }, onViewInAlbum = { uris ->
            albumPhotoFocus = uris.map(Uri::toString)
            albumFromCamera = true
            collectionOpen = false
            cameraOpen = false
            cameraTaskRequested = true
            album = true
        })
    } else if (batch != null) {
        BatchExportScreen(model = batch!!, storage = model.storage, onBack = model::closeBatch)
    } else if (collectionOpen) {
        BatchSelectionScreen(model, onBack = { collectionOpen = false }, onEdit = { collectionOpen = false })
    } else if (album) {
        screenState.SaveableStateProvider("album") {
            AlbumScreen(model.storage, onBack = { album = false; if (albumFromCamera) cameraOpen = true },
                onFile = { fileFromCameraAlbum = albumFromCamera; openFile.launch(arrayOf("*/*")) }, initialPhotos = albumPhotoFocus.takeIf { it.isNotEmpty() }?.toSet(),
                onPhoto = { uri ->
                    if (albumFromCamera) {
                        // 相机页往返保留草稿；选定本地照片后才进入既有的离开确认。
                        albumFromCamera = false
                        album = false
                        model.receiveSystemPhotos(listOf(uri))
                    } else model.importPhoto(uri) { accepted -> if (accepted) album = false }
                })
        }
    } else {
        screenState.SaveableStateProvider("editor") {
        Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        if (cameraState.transferring || cameraState.job?.status == com.rawlab.android.camera.CameraJobStatus.PAUSED) {
            TextButton(onClick = { model.setEditorActive(false); cameraTaskRequested = true; cameraOpen = true },
                modifier = Modifier.fillMaxWidth().statusBarsPadding().testTag("camera-open-task")) {
                Text(stringResource(R.string.camera_view_task))
            }
        }
        pendingBatch.firstOrNull()?.let { job ->
            Row(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 16.dp), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                Text(AppStrings.text(R.string.message_unfinished_batch_export), Modifier.weight(1f))
                TextButton(onClick = { model.resumeBatch(job) }, enabled = state.draft == null) { Text(AppStrings.text(R.string.message_view_task)) }
            }
        }
        Box(Modifier.weight(1f)) {
        EditorScreen(state, onAlbum = { model.setEditorActive(false); albumFromCamera = false; albumPhotoFocus = emptyList(); album = true }, onFile = { openFile.launch(arrayOf("*/*")) },
            onRollbackProcessing = model::rollbackProcessingMigration,
            onCamera = { model.setEditorActive(false); cameraTaskRequested = false; cameraOpen = true },
            systemPhotoRequest = systemPhotoRequests.firstOrNull()?.takeUnless { collection.busy },
            onSystemPhotoConsumed = model::consumeSystemPhotoRequest,
            onSystemPhotoReady = { request, completed ->
                if (!request.openAsCollection) model.importPhoto(request.uris.first(), completed)
                else model.returnToCollection { accepted ->
                    if (accepted) { model.addCollectionPhotos(request.uris); collectionOpen = true }
                    completed(accepted)
                }
            },
            hslTarget = HslTargetActions(hslTarget, model::setHslTargetEnabled, model::setHslTargetAxis,
                { x, y -> model.beginHslTarget(x, y) }, model::moveHslTarget, model::endHslTarget,
                model::cancelHslTarget, model::keyHslTarget, model::rejectHslTarget),
            onEdit = model::edit, onRetry = model::retry, onSelectFilm = model::selectFilm,
            onPrepareReset = model::prepareReset, onCommitReset = model::commitReset,
            onResetUnusableRecord = model::resetUnusableImportRecord,
            onDismissUnusableRecord = model::dismissUnusableImportRecovery,
            onSaveRetry = { model.retrySave() },
            onCancelAdjustment = model::cancelAdjustmentInteraction,
            canUndoAdjustment = model.canUndoAdjustment, canRedoAdjustment = model.canRedoAdjustment,
            canPasteAdjustment = model.adjustmentClipboard != null,
            onCopyAdjustments = { model.closeAdjustmentOperation(); adjustmentSheet = AdjustmentSheet.COPY },
            onPasteAdjustments = { model.closeAdjustmentOperation(); adjustmentSheet = AdjustmentSheet.PASTE },
            onAdjustmentHistory = { model.closeAdjustmentOperation(); adjustmentSheet = AdjustmentSheet.HISTORY },
            onPresets = model::showQuickPresets, onClosePresets = model::closeQuickPresets,
            quickPresetsVisible = quickPreset.visible,
            quickPresetContent = { QuickPresetContent(model, presetLibraryRevision,
                onManage = { savingPreset = false; presetLibrary = true }, onRequest = { presetAction = it }) },
            presetAction = presetAction,
            onPresetActionConsumed = { presetAction = null }, onPresetActionReady = { action ->
                when (action) {
                    AdjustmentPresetAction.Save -> { savingPreset = true; presetLibrary = true }
                    is AdjustmentPresetAction.Apply -> { model.showQuickPresets(); model.applyPresetToCurrentPhoto(action.preset) }
                    is AdjustmentPresetAction.ApplyMultiple -> {
                        model.closeAdjustmentOperation(); selectedPreset = action.preset; adjustmentSheet = AdjustmentSheet.PASTE
                    }
                }
            },
            onUndoAdjustment = { history(true) }, onRedoAdjustment = { history(false) },
            onAutoExposure = model::autoExposure,
            onFilmSelected = { usage.record(UsageEvent.FilmSelected(it)) },
            onExport = {
                exportSizeKey = ExportSizeChoice.ORIGINAL.key
                exportCustomSize = ""
                format = if (state.edits.isHDREditing) ExportFormat.HDR_JPEG else ExportFormat.JPEG
                model.beginExport { if (it) exportDialog = true }
            },
            onBatchExport = model::beginBatch,
            collectionEditing = collection.currentID != null && collection.currentID == state.photo?.identity?.value,
            onCollection = {
                if (collection.currentID != null) {
                    model.returnToCollection { if (it) collectionOpen = true }
                } else { model.retainCurrentInCollection(); collectionOpen = true }
            },
            onMessageDismiss = model::dismissMessage, onLicenses = { licenses = true }, onGpuChange = model::setGpuEnabled,
            onHDRChange = model::setHDRMode,
            onHDRCameraDevelopment = model::applyHDRCameraDevelopment,
            onHDRCameraDraftChange = model::changeHDRCameraDraft,
            onImportHDRCameraProfile = { if (model.beginHDRCameraProfileImport()) openHDRCameraProfile.launch(arrayOf("*/*")) },
            onImportLook = { openLook.launch(arrayOf("*/*")) }, onRenameLook = model::renameLook,
            onImportHDRLook = { if (model.beginHDRLookImport()) openHDRLook.launch(arrayOf("*/*")) },
            onApplyHDRSilver = model::applyHDRSilver,
            onDeleteLook = model::deleteLook, onLookImportReportDismiss = model::dismissLookImportReport,
            onAbout = { about = true }, updateVersion = updateState.available?.version,
            onPreviewSizeChange = model::updatePreviewSize,
            onUndoDraft = model::undoDraft, onRedoDraft = model::redoDraft,
            onBeginDraft = model::beginDraft, onDraftEdit = model::changeDraft,
            onApplyDraft = model::applyDraft, onDiscardDraft = model::discardDraft,
            onGeometryRatio = model::chooseGeometryRatio, onGeometryLock = model::toggleGeometryLock,
            onGeometrySwap = model::swapGeometryRatio, onGeometryGrid = model::toggleGeometryGrid)
        if (!state.lookImportPreparing) {
            when (val pending = state.pendingLookImports.firstOrNull()) {
                is PendingLookCompatibility ->
                    LUTCompatibilityDialog(pending, state.photo, model.storage, model::resolveLookCompatibility)
                is PendingDcpImport -> DcpImportDialog(pending, model::resolveDcpImport)
                null -> Unit
            }
        }
        }
        }
    }
    }
    adjustmentSheet?.let { kind ->
        AdjustmentTransferSheet(model, kind, selectedPreset) { adjustmentSheet = null; selectedPreset = null }
    }
    if (presetLibrary) AdjustmentPresetSheet(model, savingPreset,
        onClose = { presetLibrary = false; savingPreset = false; presetLibraryRevision++ },
        onRequest = { action -> presetLibrary = false; savingPreset = false; presetLibraryRevision++; presetAction = action })
    if (exportDialog) ModalBottomSheet(
        onDismissRequest = { exportDialog = false; model.cancelExport() },
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
    ) {
        EditorSheetSystemBars()
        Column(Modifier.fillMaxWidth().fillMaxHeight(.94f).imePadding().padding(horizontal = 24.dp)) {
            Text(stringResource(R.string.export), style = MaterialTheme.typography.headlineSmall, modifier = Modifier.padding(bottom = 16.dp))
            val selectedSize = ExportSizeChoice.fromKey(exportSizeKey)
            val longEdge = ExportSize.parse(selectedSize, exportCustomSize)
            val sizeValid = selectedSize != ExportSizeChoice.CUSTOM || longEdge != null
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                ExportFormatControls(format, { format = it }, hdrEditing = state.edits.isHDREditing)
                ExportSizeControls(
                    selected = selectedSize,
                    customText = exportCustomSize,
                    onSelected = { choice -> exportSizeKey = choice.key },
                    onCustomText = { exportCustomSize = it },
                    modifier = Modifier.padding(top = 12.dp),
                )
                Text(stringResource(R.string.output_destination), style = MaterialTheme.typography.titleSmall)
                if (Build.VERSION.SDK_INT >= 29 && format.allowsGallery) {
                    OutlinedButton(onClick = { exportToAlbum = true }, modifier = Modifier.fillMaxWidth()) {
                        RadioButton(exportToAlbum, null); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.save_album))
                    }
                }
                OutlinedButton(onClick = { exportToAlbum = false }, modifier = Modifier.fillMaxWidth()) {
                    RadioButton(!exportToAlbum || !format.allowsGallery, null); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.save_file))
                }
            }
            Button(onClick = {
                    exportDialog = false
                    if (exportToAlbum && format.allowsGallery && Build.VERSION.SDK_INT >= 29) {
                        model.export(null, format, longEdge)
                        return@Button
                    }
                    pendingExportLongEdgeText = longEdge?.toString().orEmpty()
                    val name = "RawLab-${System.currentTimeMillis()}"
                    when (format) {
                        ExportFormat.JPEG, ExportFormat.HDR_JPEG -> saveJpeg.launch("$name.jpg")
                        ExportFormat.PNG -> savePng.launch("$name.png")
                        ExportFormat.DNG -> saveDng.launch("$name.dng")
                    }
                }, enabled = sizeValid, modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) { Text(stringResource(R.string.export)) }
            TextButton(onClick = { exportDialog = false; model.cancelExport() }, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.cancel)) }
        }
    }
    if (licenses) LicenseDialog { licenses = false }
    if (about) AboutDialog(updateState, updates::setAutomatic, { updates.check(manual = true) }, { about = false },
        usageState = usageState, onUsage = usage::setEnabled)
}

@Composable
private fun LicenseDialog(onClose: () -> Unit) {
    val context = LocalContext.current
    val notices by produceState("") {
        value = withContext(Dispatchers.IO) {
            fun files(path: String): List<String> {
                val children = context.assets.list(path).orEmpty()
                return if (children.isEmpty()) listOf(path) else children.sorted().flatMap { files("$path/$it") }
            }
            files("licenses").joinToString("\n\n") { path ->
                path.removePrefix("licenses/") + "\n" + context.assets.open(path).bufferedReader().use { it.readText() }
            }
        }
    }
    AlertDialog(onDismissRequest = onClose, title = { Text(stringResource(R.string.licenses)) },
        text = { Text(notices, Modifier.heightIn(max = 440.dp).verticalScroll(rememberScrollState()), style = MaterialTheme.typography.bodySmall) },
        confirmButton = { TextButton(onClick = onClose) { Text(stringResource(R.string.confirm)) } })
}
