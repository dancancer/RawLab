package com.rawlab.android

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.Locale
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ToolIcon(icon: ImageVector, label: Int, enabled: Boolean = true, onClick: () -> Unit) {
    val text = stringResource(label)
    TooltipBox(positionProvider = TooltipDefaults.rememberPlainTooltipPositionProvider(),
        tooltip = { PlainTooltip { Text(text) } }, state = rememberTooltipState()) {
        IconButton(onClick = onClick, enabled = enabled) { Icon(icon, text) }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EditorScreen(state: EditorState, onAlbum: () -> Unit, onFile: () -> Unit,
    onEdit: (EditSettings, Boolean) -> Unit, onReset: () -> Unit, onRetry: () -> Unit,
    onExport: () -> Unit, onMessageDismiss: () -> Unit, onLicenses: () -> Unit, onGpuChange: (Boolean) -> Unit,
    onSaveRetry: () -> Unit = {},
    onBatchExport: () -> Unit = {},
    onImportLook: () -> Unit = {}, onRenameLook: (String, String) -> Unit = { _, _ -> },
    onDeleteLook: (String) -> Unit = {}, onLookImportReportDismiss: () -> Unit = {},
    onAbout: () -> Unit = {}, updateVersion: String? = null) {
    var compare by rememberSaveable { mutableStateOf(false) }
    var expanded by rememberSaveable { mutableStateOf(true) }
    var menu by remember { mutableStateOf(false) }
    var tool by rememberSaveable { mutableIntStateOf(0) }
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
    Scaffold(snackbarHost = { SnackbarHost(snackbar) }, topBar = {
        TopAppBar(title = {
            Column {
                Text("RawLab", style = MaterialTheme.typography.titleMedium)
                state.photo?.let { Text(it.name, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.labelSmall) }
            }
        }, actions = {
            if (updateVersion != null) ToolIcon(Icons.Outlined.SystemUpdate, R.string.view_update, onClick = onAbout)
            ToolIcon(Icons.Outlined.PhotoLibrary, R.string.open_album, state.operation == Operation.NONE, onAlbum)
            ToolIcon(Icons.Outlined.SaveAlt, R.string.export, state.canExport, onExport)
            ToolIcon(Icons.Outlined.Layers, R.string.batch_export, state.canExport, onBatchExport)
            Box {
                ToolIcon(Icons.Outlined.MoreVert, R.string.more) { menu = true }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text(stringResource(R.string.open_file)) }, enabled = state.operation == Operation.NONE,
                        leadingIcon = { Icon(Icons.Outlined.FolderOpen, null) }, onClick = { menu = false; onFile() })
                    DropdownMenuItem(text = { Text(stringResource(R.string.gpu_auto)) }, enabled = state.operation == Operation.NONE,
                        trailingIcon = { Checkbox(state.gpuEnabled, null) }, onClick = { menu = false; onGpuChange(!state.gpuEnabled) })
                    DropdownMenuItem(text = { Text(stringResource(R.string.licenses)) }, onClick = { menu = false; onLicenses() })
                    DropdownMenuItem(text = { Text(stringResource(R.string.about_rawlab)) },
                        leadingIcon = { Icon(Icons.Outlined.Info, null) }, onClick = { menu = false; onAbout() })
                }
            }
        })
    }) { padding ->
        BoxWithConstraints(Modifier.fillMaxSize().padding(padding)) {
            val dockHeight = if (expanded) (maxHeight * .33f).coerceIn(200.dp, 280.dp) else 48.dp
            val wide = maxWidth >= 600.dp && maxWidth > maxHeight
            Column(Modifier.fillMaxSize()) {
                Box(Modifier.fillMaxWidth().height(4.dp)) {
                    if (state.rendering || state.operation == Operation.EXPORT) LinearProgressIndicator(Modifier.fillMaxWidth())
                }
                if (wide && state.photo != null) {
                    Row(Modifier.weight(1f)) {
                        Column(Modifier.weight(1f)) {
                            EditorCanvas(state, compare, photoCanvas, photoInfo, infoMode, { infoMode = (infoMode + 1) % 3 },
                                Modifier.weight(1f), onAlbum, onFile, onLicenses)
                            RenderError(state, onRetry)
                        }
                        VerticalDivider()
                        AdjustmentDock(state, Modifier.width(320.dp).fillMaxHeight(), tool, { tool = it }, expanded,
                            { expanded = !expanded }, compare, { compare = !compare }, onEdit, onReset, onSaveRetry,
                            onImportLook, onRenameLook, onDeleteLook)
                    }
                } else {
                    EditorCanvas(state, compare, photoCanvas, photoInfo, infoMode, { infoMode = (infoMode + 1) % 3 },
                        Modifier.weight(1f), onAlbum, onFile, onLicenses)
                    RenderError(state, onRetry)
                    if (state.photo != null) {
                        HorizontalDivider()
                        AdjustmentDock(state, Modifier.fillMaxWidth().height(dockHeight), tool, { tool = it }, expanded,
                            { expanded = !expanded }, compare, { compare = !compare }, onEdit, onReset, onSaveRetry,
                            onImportLook, onRenameLook, onDeleteLook)
                    }
                }
            }
        }
    }
}

@Composable
private fun EditorCanvas(state: EditorState, compare: Boolean, photoCanvas: PhotoCanvasState, photoInfo: PhotoInfo?, infoMode: Int,
    onInfoClick: () -> Unit, modifier: Modifier,
    onAlbum: () -> Unit, onFile: () -> Unit, onLicenses: () -> Unit) {
    Box(modifier.fillMaxWidth().background(Color(0xFF18191A)), contentAlignment = Alignment.Center) {
        state.preview?.let { PhotoCanvas(it, compare, state.photo?.name.orEmpty(), photoCanvas, photoInfo, infoMode, onInfoClick) }
            ?: if (!state.rendering) EmptyEditor(onAlbum, onFile, onLicenses) else Unit
        val status = when {
            state.operation == Operation.EXPORT -> stringResource(R.string.exporting)
            state.operation == Operation.IMPORT -> stringResource(R.string.importing)
            state.operation == Operation.IMPORT_LOOK -> stringResource(R.string.look_importing)
            state.rendering -> stringResource(R.string.rendering)
            else -> null
        }
        status?.let { Text(it, Modifier.align(Alignment.TopStart).padding(12.dp).background(Color.Black.copy(alpha = .6f)).padding(6.dp),
            color = Color.White, style = MaterialTheme.typography.labelSmall) }
    }
}

@Composable
private fun RenderError(state: EditorState, onRetry: () -> Unit) {
    state.error?.let { error ->
        Row(Modifier.fillMaxWidth().heightIn(max = 96.dp).background(MaterialTheme.colorScheme.errorContainer)
            .padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(error, Modifier.weight(1f).verticalScroll(rememberScrollState()), style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onErrorContainer)
            if (state.photo != null) TextButton(onClick = onRetry, enabled = state.operation == Operation.NONE) { Text(stringResource(R.string.retry)) }
        }
    }
}

@Composable
private fun EmptyEditor(onAlbum: () -> Unit, onFile: () -> Unit, onLicenses: () -> Unit) {
    val icon = assetBitmap("AppIcon.png")
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        icon?.let { Image(it.asImageBitmap(), null, Modifier.size(80.dp)) }
        Text(stringResource(R.string.empty_title), color = Color.White, style = MaterialTheme.typography.titleLarge)
        Button(onClick = onAlbum) { Icon(Icons.Outlined.PhotoLibrary, null); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.open_album)) }
        TextButton(onClick = onFile) { Text(stringResource(R.string.open_file), color = Color(0xFFE9CE55)) }
        TextButton(onClick = onLicenses) { Text(stringResource(R.string.licenses), color = Color(0xFFB8BABC)) }
    }
}

@Composable
private fun AdjustmentDock(state: EditorState, modifier: Modifier, tool: Int, selectTool: (Int) -> Unit,
    expanded: Boolean, toggleExpanded: () -> Unit, compare: Boolean, toggleCompare: () -> Unit,
    onEdit: (EditSettings, Boolean) -> Unit, onReset: () -> Unit,
    onSaveRetry: () -> Unit,
    onImportLook: () -> Unit, onRenameLook: (String, String) -> Unit, onDeleteLook: (String) -> Unit) {
    val titles = listOf(R.string.film, R.string.strength, R.string.exposure, R.string.highlights, R.string.shadows,
        R.string.contrast, R.string.tone_curve, R.string.saturation, R.string.temperature, R.string.tint, R.string.sharpening, R.string.denoise)
    val icons = listOf(Icons.Outlined.PhotoFilter, Icons.Outlined.Tune, Icons.Outlined.Exposure, Icons.Outlined.WbSunny,
        Icons.Outlined.DarkMode, Icons.Outlined.Contrast, Icons.Outlined.ShowChart, Icons.Outlined.WaterDrop,
        Icons.Outlined.Thermostat, Icons.Outlined.Palette, Icons.Outlined.Deblur, Icons.Outlined.Grain)
    val edits = state.edits
    val calibrated = state.preview?.temperature?.isFinite() == true
    var menuLookId by remember { mutableStateOf<String?>(null) }
    var renameLookId by remember { mutableStateOf<String?>(null) }
    var deleteLookId by remember { mutableStateOf<String?>(null) }
    var renameText by remember { mutableStateOf("") }
    Column(modifier) {
        Row(Modifier.fillMaxWidth().height(48.dp), verticalAlignment = Alignment.CenterVertically) {
            IconToggleButton(checked = compare, onCheckedChange = { toggleCompare() }, enabled = state.preview != null) {
                Icon(Icons.Outlined.Compare, stringResource(R.string.compare))
            }
            if (expanded && (tool == 8 || tool == 9)) {
                TextButton(onClick = { onEdit(edits.copy(customWb = false), false) }, enabled = state.controlsEnabled && calibrated,
                    modifier = Modifier.weight(1f)) { Text(stringResource(R.string.as_shot), maxLines = 1) }
            } else {
                Text(state.looks.firstOrNull { it.id == edits.film }?.name ?: edits.film, Modifier.weight(1f),
                    maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.labelLarge)
            }
            ToolIcon(Icons.Outlined.RestartAlt, R.string.reset, state.controlsEnabled, onReset)
            ToolIcon(if (expanded) Icons.Outlined.ExpandMore else Icons.Outlined.ExpandLess,
                if (expanded) R.string.collapse_adjustments else R.string.expand_adjustments, onClick = toggleExpanded)
        }
        when (state.saveState) {
            EditSaveState.RESTORED -> Text(stringResource(R.string.edit_restored), Modifier.padding(horizontal = 16.dp),
                style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            EditSaveState.SAVED -> Text(stringResource(R.string.edit_saved), Modifier.padding(horizontal = 16.dp),
                style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            EditSaveState.FAILED -> TextButton(onClick = onSaveRetry, modifier = Modifier.padding(horizontal = 8.dp)) {
                Text(stringResource(R.string.edit_unsaved), color = MaterialTheme.colorScheme.error)
            }
            EditSaveState.NONE -> Unit
        }
        if (!expanded) return@Column
        Box(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState())) {
        when (tool) {
            0 -> LazyRow(contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                item(key = "import-look") {
                    Column(Modifier.width(76.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                        ToolIcon(Icons.Outlined.Add, R.string.import_look, state.operation == Operation.NONE, onImportLook)
                        Text(stringResource(R.string.import_look), Modifier.heightIn(min = 42.dp).padding(top = 4.dp),
                            maxLines = 3, style = MaterialTheme.typography.labelSmall)
                    }
                }
                items(state.looks, key = { it.id }) { look ->
                    val builtIn = Film.all.firstOrNull { it.id == look.id }
                    val artwork = if (builtIn?.file != null) assetBitmap("artwork/${look.id}.png") else null
                    Box(Modifier.width(76.dp)) {
                        Column(Modifier.fillMaxWidth().selectable(selected = edits.film == look.id, enabled = state.controlsEnabled,
                            role = Role.RadioButton, onClick = { onEdit(edits.copy(film = look.id), false) }),
                            horizontalAlignment = Alignment.CenterHorizontally) {
                            Box(Modifier.size(64.dp).border(if (edits.film == look.id) 2.dp else 0.dp,
                                if (edits.film == look.id) MaterialTheme.colorScheme.primary else Color.Transparent).padding(3.dp), contentAlignment = Alignment.Center) {
                                if (artwork != null) Image(artwork.asImageBitmap(), null, Modifier.fillMaxSize())
                                else Icon(Icons.Outlined.Image, null, Modifier.size(32.dp))
                            }
                            Text(look.name, Modifier.heightIn(min = 42.dp).padding(top = 4.dp), maxLines = 3,
                                overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.labelSmall)
                        }
                        if (look.managed) {
                            Box(Modifier.align(Alignment.TopEnd)) {
                                ToolIcon(Icons.Outlined.MoreVert, R.string.more, state.operation == Operation.NONE) { menuLookId = look.id }
                                DropdownMenu(expanded = menuLookId == look.id, onDismissRequest = { menuLookId = null }) {
                                    DropdownMenuItem(text = { Text(stringResource(R.string.rename_look)) },
                                        leadingIcon = { Icon(Icons.Outlined.Edit, null) }, onClick = {
                                            menuLookId = null; renameLookId = look.id; renameText = look.name
                                        })
                                    DropdownMenuItem(text = { Text(stringResource(R.string.delete_look)) },
                                        leadingIcon = { Icon(Icons.Outlined.Delete, null) }, onClick = {
                                            menuLookId = null; deleteLookId = look.id
                                        })
                                }
                            }
                        }
                    }
                }
            }
            1 -> NumericControl(R.string.strength, edits.strength * 100, 0f..200f, "%", state.controlsEnabled,
                { value, dragging -> onEdit(edits.copy(strength = value / 100), dragging) }, { onEdit(edits.copy(strength = 1f), false) })
            2 -> NumericControl(R.string.exposure, edits.exposure, -4f..4f, "EV", state.controlsEnabled,
                { value, dragging -> onEdit(edits.copy(exposure = value), dragging) }, { onEdit(edits.copy(exposure = 0f), false) })
            3 -> NumericControl(R.string.highlights, edits.highlights * 100, -100f..100f, "%", state.controlsEnabled,
                { value, dragging -> onEdit(edits.copy(highlights = value / 100), dragging) }, { onEdit(edits.copy(highlights = 0f), false) })
            4 -> NumericControl(R.string.shadows, edits.shadows * 100, -100f..100f, "%", state.controlsEnabled,
                { value, dragging -> onEdit(edits.copy(shadows = value / 100), dragging) }, { onEdit(edits.copy(shadows = 0f), false) })
            5 -> NumericControl(R.string.contrast, edits.contrast * 100, -100f..100f, "%", state.controlsEnabled,
                { value, dragging -> onEdit(edits.copy(contrast = value / 100), dragging) }, { onEdit(edits.copy(contrast = 0f), false) })
            6 -> NumericControl(R.string.tone_curve, edits.toneCurve * 100, -100f..100f, "%", state.controlsEnabled,
                { value, dragging -> onEdit(edits.copy(toneCurve = value / 100), dragging) }, { onEdit(edits.copy(toneCurve = 0f), false) })
            7 -> NumericControl(R.string.saturation, edits.saturation * 100, -100f..100f, "%", state.controlsEnabled,
                { value, dragging -> onEdit(edits.copy(saturation = value / 100), dragging) }, { onEdit(edits.copy(saturation = 0f), false) })
            8, 9 -> {
                if (!calibrated) Text(stringResource(R.string.wb_unavailable), Modifier.padding(12.dp), style = MaterialTheme.typography.bodySmall)
                else {
                    if (tool == 8) NumericControl(R.string.temperature, edits.temperature, 2000f..50000f, "K", state.controlsEnabled,
                        { value, dragging -> onEdit(edits.copy(customWb = true, temperature = value), dragging) },
                        { onEdit(edits.copy(customWb = false), false) }, reciprocal = true)
                    else NumericControl(R.string.tint, edits.tint, -150f..150f, "", state.controlsEnabled,
                        { value, dragging -> onEdit(edits.copy(customWb = true, tint = value), dragging) },
                        { onEdit(edits.copy(customWb = false), false) })
                }
            }
            11 -> DenoiseControls(edits.denoise, state.controlsEnabled) { value, dragging ->
                onEdit(edits.copy(denoise = value), dragging)
            }
            10 -> NumericControl(R.string.sharpening, edits.sharpening * 100, 0f..200f, "%", state.controlsEnabled,
                { value, dragging -> onEdit(edits.copy(sharpening = value / 100), dragging) }, { onEdit(edits.copy(sharpening = 0f), false) })
        }
        }
        LazyRow(Modifier.fillMaxWidth().height(64.dp), contentPadding = PaddingValues(horizontal = 4.dp)) {
            items(titles.size) { index ->
                val title = titles[index]
                val color = if (tool == index) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
                Column(Modifier.width(76.dp).fillMaxHeight().selectable(tool == index, enabled = state.controlsEnabled, role = Role.Tab,
                    onClick = { selectTool(index) }), horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center) {
                    Icon(icons[index], null, Modifier.size(24.dp), tint = color)
                    Text(stringResource(title), color = color, style = MaterialTheme.typography.labelSmall, maxLines = 1)
                }
            }
        }
    }
    renameLookId?.let { id ->
        AlertDialog(onDismissRequest = { renameLookId = null }, title = { Text(stringResource(R.string.rename_look)) },
            text = { OutlinedTextField(value = renameText, onValueChange = { renameText = it }, singleLine = true,
                label = { Text(stringResource(R.string.look_name)) }) },
            confirmButton = { TextButton(onClick = { onRenameLook(id, renameText); renameLookId = null },
                enabled = renameText.trim().isNotEmpty()) { Text(stringResource(R.string.confirm)) } },
            dismissButton = { TextButton(onClick = { renameLookId = null }) { Text(stringResource(R.string.cancel)) } })
    }
    deleteLookId?.let { id ->
        val look = state.looks.firstOrNull { it.id == id }
        AlertDialog(onDismissRequest = { deleteLookId = null }, title = { Text(stringResource(R.string.delete_look)) },
            text = { Text(look?.name.orEmpty()) },
            confirmButton = { TextButton(onClick = { onDeleteLook(id); deleteLookId = null }) { Text(stringResource(R.string.confirm)) } },
            dismissButton = { TextButton(onClick = { deleteLookId = null }) { Text(stringResource(R.string.cancel)) } })
    }
}

@Composable
internal fun NumericControl(label: Int, value: Float, range: ClosedFloatingPointRange<Float>, unit: String,
    enabled: Boolean, onValue: (Float, Boolean) -> Unit, onReset: () -> Unit, reciprocal: Boolean = false) {
    var editing by remember { mutableStateOf(false) }
    var latestValue by remember(value) { mutableStateOf(value) }
    val formatted = if (unit == "EV") String.format(Locale.ROOT, "%.2f", value) else value.roundToInt().toString()
    var input by remember { mutableStateOf("") }
    val parsed = input.toFloatOrNull()?.takeIf { it.isFinite() && it in range }
    Column(Modifier.padding(horizontal = 16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(label), Modifier.weight(1f), style = MaterialTheme.typography.labelLarge)
            TextButton(onClick = { input = formatted; editing = true }, enabled = enabled) { Text("$formatted $unit") }
            ToolIcon(Icons.Outlined.RestartAlt, R.string.reset_value, enabled, onReset)
        }
        val sliderRange = if (reciprocal) (-1f / range.start)..(-1f / range.endInclusive) else range
        Slider(modifier = Modifier.testTag("adjustment-slider").semantics { stateDescription = "$formatted $unit" },
            value = if (reciprocal) -1f / value else value, onValueChange = {
            latestValue = if (reciprocal) (-1f / it).coerceIn(range) else it
            onValue(latestValue, true)
        }, onValueChangeFinished = { onValue(latestValue, false) }, valueRange = sliderRange, enabled = enabled)
    }
    if (editing) AlertDialog(onDismissRequest = { editing = false }, title = { Text(stringResource(label)) },
        text = {
            OutlinedTextField(value = input, onValueChange = { input = it }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = if (range.start < 0) KeyboardType.Text else KeyboardType.Decimal), isError = parsed == null,
                label = { Text("${range.start} … ${range.endInclusive} $unit") },
                supportingText = { if (parsed == null) Text(stringResource(R.string.invalid_value)) })
        }, confirmButton = { TextButton(onClick = { parsed?.let { onValue(it, false) }; editing = false }, enabled = parsed != null) { Text(stringResource(R.string.confirm)) } },
        dismissButton = { TextButton(onClick = { editing = false }) { Text(stringResource(R.string.cancel)) } })
}

@Composable
private fun assetBitmap(path: String): Bitmap? {
    val context = LocalContext.current
    val bitmap by produceState<Bitmap?>(null, path) {
        value = withContext(Dispatchers.IO) {
            context.assets.open(path).use { BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = 4 }) }
        }
    }
    return bitmap
}
