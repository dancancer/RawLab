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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    val model: EditorViewModel by lazy { ViewModelProvider(this)[EditorViewModel::class.java] }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { RawLabTheme { RawLabApp(model) } }
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
private fun RawLabApp(model: EditorViewModel) {
    val state by model.state.collectAsStateWithLifecycle()
    var album by rememberSaveable { mutableStateOf(false) }
    var exportDialog by rememberSaveable { mutableStateOf(false) }
    var png by rememberSaveable { mutableStateOf(false) }
    var licenses by rememberSaveable { mutableStateOf(false) }
    val screenState = rememberSaveableStateHolder()
    val openFile = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) { album = false; model.importPhoto(uri) }
    }
    val saveJpeg = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("image/jpeg")) {
        if (it == null) model.cancelExport() else model.export(it, false)
    }
    val savePng = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("image/png")) {
        if (it == null) model.cancelExport() else model.export(it, true)
    }
    if (album) {
        screenState.SaveableStateProvider("album") {
            AlbumScreen(model.storage, onBack = { album = false }, onFile = { openFile.launch(arrayOf("*/*")) },
                onPhoto = { album = false; model.importPhoto(it) })
        }
    } else {
        EditorScreen(state, onAlbum = { album = true }, onFile = { openFile.launch(arrayOf("*/*")) },
            onEdit = model::edit, onReset = model::reset, onRetry = model::retry,
            onExport = { if (model.beginExport()) exportDialog = true },
            onMessageDismiss = model::dismissMessage, onLicenses = { licenses = true }, onGpuChange = model::setGpuEnabled)
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
                if (Build.VERSION.SDK_INT >= 29) TextButton(onClick = {
                    exportDialog = false; model.export(null, png)
                }) { Text(stringResource(R.string.save_album)) }
                TextButton(onClick = {
                    exportDialog = false
                    val name = "RawLab-${System.currentTimeMillis()}"
                    if (png) savePng.launch("$name.png") else saveJpeg.launch("$name.jpg")
                }) { Text(stringResource(R.string.save_file)) }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = { exportDialog = false; model.cancelExport() }) { Text(stringResource(R.string.cancel)) } },
    )
    if (licenses) LicenseDialog { licenses = false }
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
