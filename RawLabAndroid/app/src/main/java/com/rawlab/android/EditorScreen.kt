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
    onExport: () -> Unit, onMessageDismiss: () -> Unit, onLicenses: () -> Unit, onGpuChange: (Boolean) -> Unit) {
    var compare by rememberSaveable { mutableStateOf(false) }
    var expanded by rememberSaveable { mutableStateOf(true) }
    var menu by remember { mutableStateOf(false) }
    var tool by rememberSaveable { mutableIntStateOf(0) }
    val photoCanvas = rememberSaveable(state.photo?.file?.absolutePath, saver = PhotoCanvasState.Saver) { PhotoCanvasState() }
    val snackbar = remember { SnackbarHostState() }
    LaunchedEffect(state.message) {
        state.message?.let { snackbar.showSnackbar(it); onMessageDismiss() }
    }
    Scaffold(snackbarHost = { SnackbarHost(snackbar) }, topBar = {
        TopAppBar(title = {
            Column {
                Text("RawLab", style = MaterialTheme.typography.titleMedium)
                state.photo?.let { Text(it.name, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.labelSmall) }
            }
        }, actions = {
            ToolIcon(Icons.Outlined.PhotoLibrary, R.string.open_album, state.operation == Operation.NONE, onAlbum)
            ToolIcon(Icons.Outlined.SaveAlt, R.string.export, state.canExport, onExport)
            Box {
                ToolIcon(Icons.Outlined.MoreVert, R.string.more) { menu = true }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text(stringResource(R.string.open_file)) }, enabled = state.operation == Operation.NONE,
                        leadingIcon = { Icon(Icons.Outlined.FolderOpen, null) }, onClick = { menu = false; onFile() })
                    DropdownMenuItem(text = { Text(stringResource(R.string.gpu_auto)) }, enabled = state.operation == Operation.NONE,
                        trailingIcon = { Checkbox(state.gpuEnabled, null) }, onClick = { menu = false; onGpuChange(!state.gpuEnabled) })
                    DropdownMenuItem(text = { Text(stringResource(R.string.licenses)) }, onClick = { menu = false; onLicenses() })
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
                            EditorCanvas(state, compare, photoCanvas, Modifier.weight(1f), onAlbum, onFile, onLicenses)
                            RenderError(state, onRetry)
                        }
                        VerticalDivider()
                        AdjustmentDock(state, Modifier.width(320.dp).fillMaxHeight(), tool, { tool = it }, expanded,
                            { expanded = !expanded }, compare, { compare = !compare }, onEdit, onReset)
                    }
                } else {
                    EditorCanvas(state, compare, photoCanvas, Modifier.weight(1f), onAlbum, onFile, onLicenses)
                    RenderError(state, onRetry)
                    if (state.photo != null) {
                        HorizontalDivider()
                        AdjustmentDock(state, Modifier.fillMaxWidth().height(dockHeight), tool, { tool = it }, expanded,
                            { expanded = !expanded }, compare, { compare = !compare }, onEdit, onReset)
                    }
                }
            }
        }
    }
}

@Composable
private fun EditorCanvas(state: EditorState, compare: Boolean, photoCanvas: PhotoCanvasState, modifier: Modifier,
    onAlbum: () -> Unit, onFile: () -> Unit, onLicenses: () -> Unit) {
    Box(modifier.fillMaxWidth().background(Color(0xFF18191A)), contentAlignment = Alignment.Center) {
        state.preview?.let { PhotoCanvas(it, compare, state.photo?.name.orEmpty(), photoCanvas) }
            ?: if (!state.rendering) EmptyEditor(onAlbum, onFile, onLicenses) else Unit
        val status = when {
            state.operation == Operation.EXPORT -> stringResource(R.string.exporting)
            state.operation == Operation.IMPORT -> stringResource(R.string.importing)
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
    onEdit: (EditSettings, Boolean) -> Unit, onReset: () -> Unit) {
    val titles = listOf(R.string.film, R.string.strength, R.string.exposure, R.string.temperature, R.string.tint)
    val icons = listOf(Icons.Outlined.PhotoFilter, Icons.Outlined.Tune, Icons.Outlined.Exposure, Icons.Outlined.Thermostat, Icons.Outlined.Palette)
    val edits = state.edits
    val calibrated = state.preview?.temperature?.isFinite() == true
    Column(modifier) {
        Row(Modifier.fillMaxWidth().height(48.dp), verticalAlignment = Alignment.CenterVertically) {
            IconToggleButton(checked = compare, onCheckedChange = { toggleCompare() }, enabled = state.preview != null) {
                Icon(Icons.Outlined.Compare, stringResource(R.string.compare))
            }
            if (expanded && tool >= 3) {
                TextButton(onClick = { onEdit(edits.copy(customWb = false), false) }, enabled = state.controlsEnabled && calibrated,
                    modifier = Modifier.weight(1f)) { Text(stringResource(R.string.as_shot), maxLines = 1) }
            } else {
                Text(Film.all.first { it.id == edits.film }.name, Modifier.weight(1f),
                    maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.labelLarge)
            }
            ToolIcon(Icons.Outlined.RestartAlt, R.string.reset, state.controlsEnabled, onReset)
            ToolIcon(if (expanded) Icons.Outlined.ExpandMore else Icons.Outlined.ExpandLess,
                if (expanded) R.string.collapse_adjustments else R.string.expand_adjustments, onClick = toggleExpanded)
        }
        if (!expanded) return@Column
        Box(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState())) {
        when (tool) {
            0 -> LazyRow(contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                items(Film.all, key = { it.id }) { film ->
                    val artwork = if (film.file != null) assetBitmap("artwork/${film.id}.png") else null
                    Column(Modifier.width(76.dp).selectable(selected = edits.film == film.id, enabled = state.controlsEnabled,
                        role = Role.RadioButton, onClick = { onEdit(edits.copy(film = film.id), false) }),
                        horizontalAlignment = Alignment.CenterHorizontally) {
                        Box(Modifier.size(64.dp).border(if (edits.film == film.id) 2.dp else 0.dp,
                            if (edits.film == film.id) MaterialTheme.colorScheme.primary else Color.Transparent).padding(3.dp), contentAlignment = Alignment.Center) {
                            if (artwork != null) Image(artwork.asImageBitmap(), null, Modifier.fillMaxSize())
                            else Icon(Icons.Outlined.Image, null, Modifier.size(32.dp))
                        }
                        Text(film.name, Modifier.heightIn(min = 42.dp).padding(top = 4.dp), maxLines = 3, style = MaterialTheme.typography.labelSmall)
                    }
                }
            }
            1 -> NumericControl(R.string.strength, edits.strength * 100, 0f..200f, "%", state.controlsEnabled,
                { value, dragging -> onEdit(edits.copy(strength = value / 100), dragging) }, { onEdit(edits.copy(strength = 1f), false) })
            2 -> NumericControl(R.string.exposure, edits.exposure, -5f..5f, "EV", state.controlsEnabled,
                { value, dragging -> onEdit(edits.copy(exposure = value), dragging) }, { onEdit(edits.copy(exposure = 0f), false) })
            3, 4 -> {
                if (!calibrated) Text(stringResource(R.string.wb_unavailable), Modifier.padding(12.dp), style = MaterialTheme.typography.bodySmall)
                else {
                    if (tool == 3) NumericControl(R.string.temperature, edits.temperature, 2000f..50000f, "K", state.controlsEnabled,
                        { value, dragging -> onEdit(edits.copy(customWb = true, temperature = value), dragging) },
                        { onEdit(edits.copy(customWb = false), false) }, reciprocal = true)
                    else NumericControl(R.string.tint, edits.tint, -150f..150f, "", state.controlsEnabled,
                        { value, dragging -> onEdit(edits.copy(customWb = true, tint = value), dragging) },
                        { onEdit(edits.copy(customWb = false), false) })
                }
            }
        }
        }
        Row(Modifier.fillMaxWidth().height(64.dp)) {
            titles.forEachIndexed { index, title ->
                val color = if (tool == index) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
                Column(Modifier.weight(1f).fillMaxHeight().selectable(tool == index, enabled = state.controlsEnabled, role = Role.Tab,
                    onClick = { selectTool(index) }), horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center) {
                    Icon(icons[index], null, Modifier.size(24.dp), tint = color)
                    Text(stringResource(title), color = color, style = MaterialTheme.typography.labelSmall, maxLines = 1)
                }
            }
        }
    }
}

@Composable
private fun NumericControl(label: Int, value: Float, range: ClosedFloatingPointRange<Float>, unit: String,
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
