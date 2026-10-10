package com.rawlab.android

import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.isSystemInDarkTheme
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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    val model: EditorViewModel by lazy { ViewModelProvider(this)[EditorViewModel::class.java] }
    val updates: UpdateViewModel by lazy { ViewModelProvider(this)[UpdateViewModel::class.java] }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { RawLabTheme { RawLabApp(model, updates) } }
    }
}

@Composable
fun RawLabTheme(content: @Composable () -> Unit) {
    val scheme = if (isSystemInDarkTheme()) darkColorScheme(
        primary = Color(0xFFE9CE55), onPrimary = Color(0xFF29250A), secondary = Color(0xFF7ED4D3),
        surface = Color(0xFF202122), surfaceContainer = Color(0xFF292A2B), background = Color(0xFF18191A),
    ) else lightColorScheme(primary = Color(0xFF6E5900), secondary = Color(0xFF00696B),
        surface = Color(0xFFF9F9F9), background = Color(0xFFF0F1F2))
    MaterialTheme(colorScheme = scheme, content = content)
}

@Composable
private fun RawLabApp(model: EditorViewModel, updates: UpdateViewModel) {
    val state by model.state.collectAsStateWithLifecycle()
    val updateState by updates.state.collectAsStateWithLifecycle()
    var about by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(updates) { updates.check(manual = false) }
    var album by rememberSaveable { mutableStateOf(false) }
    val batch by model.batch.collectAsStateWithLifecycle()
    val pendingBatch by model.pendingBatch.collectAsStateWithLifecycle()
    val owner = LocalLifecycleOwner.current
    val context = LocalContext.current
    DisposableEffect(owner, model) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP && (context as? android.app.Activity)?.isChangingConfigurations != true) model.onBackground()
        }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer) }
    }
    var exportDialog by rememberSaveable { mutableStateOf(false) }
    var png by rememberSaveable { mutableStateOf(false) }
    var exportSizeKey by rememberSaveable { mutableStateOf(ExportSizeChoice.ORIGINAL.key) }
    var exportCustomSize by rememberSaveable { mutableStateOf("") }
    var pendingExportLongEdgeText by rememberSaveable { mutableStateOf("") }
    var licenses by rememberSaveable { mutableStateOf(false) }
    val screenState = rememberSaveableStateHolder()
    val openFile = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) { album = false; model.importPhoto(uri) }
    }
    val openLook = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        model.importLooks(uris)
    }
    val saveJpeg = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("image/jpeg")) {
        if (it == null) model.cancelExport() else model.export(it, false, pendingExportLongEdgeText.toIntOrNull())
    }
    val savePng = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("image/png")) {
        if (it == null) model.cancelExport() else model.export(it, true, pendingExportLongEdgeText.toIntOrNull())
    }
    if (batch != null) {
        BatchExportScreen(model = batch!!, storage = model.storage, onBack = model::closeBatch)
    } else if (album) {
        screenState.SaveableStateProvider("album") {
            AlbumScreen(model.storage, onBack = { album = false }, onFile = { openFile.launch(arrayOf("*/*")) },
                onPhoto = { album = false; model.importPhoto(it) })
        }
    } else {
        Column(Modifier.fillMaxSize()) {
        pendingBatch.firstOrNull()?.let { job ->
            Row(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 16.dp), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                Text("有未完成的批量导出", Modifier.weight(1f))
                TextButton(onClick = { model.resumeBatch(job) }) { Text("查看任务") }
            }
        }
        Box(Modifier.weight(1f)) {
        EditorScreen(state, onAlbum = { album = true }, onFile = { openFile.launch(arrayOf("*/*")) },
            onEdit = model::edit, onReset = model::reset, onRetry = model::retry,
            onSaveRetry = model::retrySave,
            onExport = {
                exportSizeKey = ExportSizeChoice.ORIGINAL.key
                exportCustomSize = ""
                png = false
                if (model.beginExport()) exportDialog = true
            },
            onBatchExport = model::beginBatch,
            onMessageDismiss = model::dismissMessage, onLicenses = { licenses = true }, onGpuChange = model::setGpuEnabled,
            onImportLook = { openLook.launch(arrayOf("*/*")) }, onRenameLook = model::renameLook,
            onDeleteLook = model::deleteLook, onLookImportReportDismiss = model::dismissLookImportReport,
            onAbout = { about = true }, updateVersion = updateState.available?.version)
        }
        }
    }
    if (exportDialog) AlertDialog(
        onDismissRequest = { exportDialog = false; model.cancelExport() },
        title = { Text(stringResource(R.string.export)) },
        text = {
            Column {
                Row {
                    FilterChip(selected = !png, onClick = { png = false }, label = { Text(stringResource(R.string.jpeg)) })
                    Spacer(Modifier.width(8.dp))
                    FilterChip(selected = png, onClick = { png = true }, label = { Text(stringResource(R.string.png)) })
                }
                val selectedSize = ExportSizeChoice.fromKey(exportSizeKey)
                val longEdge = ExportSize.parse(selectedSize, exportCustomSize)
                val sizeValid = selectedSize != ExportSizeChoice.CUSTOM || longEdge != null
                ExportSizeControls(
                    selected = selectedSize,
                    customText = exportCustomSize,
                    onSelected = { choice -> exportSizeKey = choice.key },
                    onCustomText = { exportCustomSize = it },
                    modifier = Modifier.padding(top = 12.dp),
                )
                if (Build.VERSION.SDK_INT >= 29) TextButton(onClick = {
                    exportDialog = false; model.export(null, png, longEdge)
                }, enabled = sizeValid) { Text(stringResource(R.string.save_album)) }
                TextButton(onClick = {
                    exportDialog = false
                    pendingExportLongEdgeText = longEdge?.toString().orEmpty()
                    val name = "RawLab-${System.currentTimeMillis()}"
                    if (png) savePng.launch("$name.png") else saveJpeg.launch("$name.jpg")
                }, enabled = sizeValid) { Text(stringResource(R.string.save_file)) }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = { exportDialog = false; model.cancelExport() }) { Text(stringResource(R.string.cancel)) } },
    )
    if (licenses) LicenseDialog { licenses = false }
    if (about) AboutDialog(updateState, updates::setAutomatic, { updates.check(manual = true) }) { about = false }
}

@Composable
private fun LicenseDialog(onClose: () -> Unit) {
    val context = LocalContext.current
    val notices by produceState("") {
        value = withContext(Dispatchers.IO) {
            context.assets.list("licenses").orEmpty().joinToString("\n\n") { name ->
                name + "\n" + context.assets.open("licenses/$name").bufferedReader().use { it.readText() }
            }
        }
    }
    AlertDialog(onDismissRequest = onClose, title = { Text(stringResource(R.string.licenses)) },
        text = { Text(notices, Modifier.heightIn(max = 440.dp).verticalScroll(rememberScrollState()), style = MaterialTheme.typography.bodySmall) },
        confirmButton = { TextButton(onClick = onClose) { Text(stringResource(R.string.confirm)) } })
}
