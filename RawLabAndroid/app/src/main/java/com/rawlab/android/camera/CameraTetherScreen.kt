package com.rawlab.android.camera

import com.rawlab.android.ui.AppIcons

import android.graphics.Bitmap
import android.net.Uri
import android.text.format.Formatter
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.rawlab.android.R
import com.rawlab.android.camera.protocol.SonyTetherSession
import com.rawlab.android.photo.PhotoStorage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

@Composable
internal fun CameraTetherScreen(model: CameraImportViewModel, storage: PhotoStorage, onBack: () -> Unit,
    onOpen: (List<Uri>) -> Unit, onConnect: (Boolean) -> Unit = {}, onImport: () -> Unit = {}, onHistory: () -> Unit = {}) {
    val connection by model.state.collectAsStateWithLifecycle()
    val tether by model.tether.state.collectAsStateWithLifecycle()
    var settings by rememberSaveable { mutableStateOf(false) }
    val view = LocalView.current
    DisposableEffect(view, tether.active) {
        val previous = view.keepScreenOn; view.keepScreenOn = tether.active
        onDispose { view.keepScreenOn = previous }
    }
    fun back() { model.disconnect(); onBack() }
    BackHandler(onBack = ::back)
    CameraTetherWorkspace(tether, { uri, size -> storage.thumbnail(uri, size) }, model.tether::capture,
        { onConnect(tether.canResume) }, { model.openTetherSaved(it, onOpen) }, onSetParameter = model.tether::setParameter,
        onFocusPoint = model.tether::setFocusPoint, onCancelTouchFocus = model.tether::cancelTouchFocus,
        cameraName = (SonyCameraModel.entries.find { it.profileId == tether.run?.profileId } ?: connection.model).displayName,
        onBack = ::back, onChangeCamera = { onConnect(false) }, onDisconnect = model::disconnect,
        onDestination = { settings = true }, destinationEnabled = !tether.active && !connection.closing,
        onHistory = onHistory, onImport = onImport, onConfirmContinue = { model.tether.confirmPausedRun(); onConnect(false) })
    if (settings) CameraImportSettings(connection.destination,
        onSave = { model.setDestination(it); settings = false }, onDismiss = { settings = false })
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CameraTetherWorkspace(state: CameraTetherState,
    thumbnail: suspend (Uri, Int) -> Bitmap?, onCapture: () -> Unit, onReconnect: () -> Unit,
    onEdit: (CameraTetherSaved) -> Unit, onSetParameter: (Int, Long) -> Unit = { _, _ -> },
    onFocusPoint: (Int, Int) -> Unit = { _, _ -> }, onCancelTouchFocus: () -> Unit = {},
    cameraName: String = "Sony", onBack: () -> Unit = {}, onChangeCamera: () -> Unit = {},
    onDisconnect: () -> Unit = {}, onDestination: () -> Unit = {}, destinationEnabled: Boolean = true,
    onHistory: () -> Unit = {}, onImport: () -> Unit = {}, onConfirmContinue: () -> Unit = {}) {
    var grid by rememberSaveable { mutableStateOf(false) }
    var autoReview by rememberSaveable { mutableStateOf(false) }
    var reviewUri by rememberSaveable { mutableStateOf<String?>(null) }
    var shootingParameters by rememberSaveable { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    var observedUri by remember { mutableStateOf(state.saved.firstOrNull()?.uri) }
    val saved = state.saved
    LaunchedEffect(saved.firstOrNull()?.uri) {
        val latest = saved.firstOrNull()?.uri
        if (latest != observedUri && latest != null && autoReview && reviewUri == null) reviewUri = latest
        observedUri = latest
    }
    Scaffold(topBar = {
        CenterAlignedTopAppBar(title = {
            Text(stringResource(R.string.camera_tether_header, cameraName), style = MaterialTheme.typography.titleMedium,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
        }, expandedHeight = 56.dp, navigationIcon = {
            IconButton(onClick = onBack, modifier = Modifier.testTag("tether-back")) {
                Icon(Icons.AutoMirrored.Outlined.ArrowBack, stringResource(R.string.back))
            }
        }, actions = {
            Box {
                IconButton(onClick = { menu = true }, modifier = Modifier.testTag("tether-menu")) { Icon(Icons.Outlined.MoreVert, stringResource(R.string.more)) }
                DropdownMenu(menu, { menu = false }) {
                    DropdownMenuItem(text = { Text(stringResource(R.string.camera_change)) }, onClick = { menu = false; onChangeCamera() })
                    DropdownMenuItem(text = { Text(stringResource(R.string.camera_save_location)) }, enabled = destinationEnabled,
                        modifier = Modifier.testTag("camera-destination-settings"), onClick = { menu = false; onDestination() })
                    DropdownMenuItem(text = { Text(stringResource(R.string.camera_history)) }, onClick = { menu = false; onHistory() })
                    DropdownMenuItem(text = { Text(stringResource(R.string.camera_import)) }, modifier = Modifier.testTag("tether-switch-import"),
                        onClick = { menu = false; onImport() })
                    DropdownMenuItem(text = { Text(stringResource(R.string.camera_disconnect)) }, enabled = state.active,
                        modifier = Modifier.testTag("tether-pause"), onClick = { menu = false; onDisconnect() })
                    HorizontalDivider()
                    DropdownMenuItem(text = { Text(stringResource(R.string.tether_grid)) },
                        trailingIcon = { if (grid) Icon(Icons.Outlined.Check, null) }, modifier = Modifier.testTag("tether-grid-toggle"),
                        onClick = { grid = !grid; menu = false })
                    DropdownMenuItem(text = { Text(stringResource(R.string.tether_review_auto)) },
                        trailingIcon = { if (autoReview) Icon(Icons.Outlined.Check, null) }, modifier = Modifier.testTag("tether-auto-review"),
                        onClick = { autoReview = !autoReview; menu = false })
                }
            }
        })
    }) { insets ->
        BoxWithConstraints(Modifier.fillMaxSize().padding(insets).testTag("tether-workspace")) {
            val landscape = maxWidth > maxHeight
            @Composable fun parameterButton() {
                IconButton(onClick = { shootingParameters = true }, modifier = Modifier.size(48.dp).testTag("tether-shooting-parameters")) {
                    Icon(AppIcons.Outlined.Tune, stringResource(R.string.camera_shooting_parameters))
                }
            }
            @Composable fun viewfinder(modifier: Modifier) {
                Box(modifier) {
                    TetherViewfinder(state, grid, Modifier.fillMaxSize(), onFocusPoint = onFocusPoint, onCancelTouchFocus = onCancelTouchFocus)
                    if (!state.active) Surface(
                        modifier = Modifier.align(Alignment.Center).padding(horizontal = 24.dp),
                        shape = RoundedCornerShape(12.dp),
                        color = Color(0xD8141416),
                        border = BorderStroke(1.dp, Color.White.copy(alpha = 0.14f)),
                    ) {
                        Column(
                            Modifier.padding(horizontal = 24.dp, vertical = 20.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Text(stringResource(R.string.tether_paused), color = Color.White, style = MaterialTheme.typography.titleSmall)
                            Text(stringResource(R.string.tether_saved, saved.size), color = Color.LightGray, style = MaterialTheme.typography.bodySmall)
                            if (state.canResume || state.run == null && state.failure != CameraTetherFailure.SOURCE) {
                                Button(onClick = onReconnect, shape = CameraControlShape, modifier = Modifier.testTag("tether-reconnect")) {
                                    Text(stringResource(R.string.tether_reconnect))
                                }
                            } else {
                                if (state.canConfirmAndContinue) Button(onClick = onConfirmContinue, shape = CameraControlShape,
                                    modifier = Modifier.testTag("tether-confirm-continue")) { Text(stringResource(R.string.tether_confirm_continue)) }
                                OutlinedButton(onClick = onImport, shape = CameraControlShape,
                                    modifier = Modifier.testTag("tether-import-instead")) { Text(stringResource(R.string.camera_import)) }
                            }
                        }
                    }
                }
            }
            if (landscape) Row(Modifier.fillMaxSize()) {
                Column(Modifier.weight(1f).fillMaxHeight()) {
                    viewfinder(Modifier.weight(1f).fillMaxWidth())
                    TetherParameterBar(state, onSetParameter)
                    TetherStatus(state)
                }
                Column(Modifier.width(96.dp).fillMaxHeight().verticalScroll(rememberScrollState()).padding(vertical = 8.dp),
                    horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.SpaceEvenly) {
                    RecentButton(saved.firstOrNull(), saved.size, thumbnail) { reviewUri = saved.firstOrNull()?.uri }
                    Shutter(state, onCapture)
                    parameterButton()
                }
            } else Column(Modifier.fillMaxSize()) {
                viewfinder(Modifier.weight(1f).fillMaxWidth())
                TetherParameterBar(state, onSetParameter)
                Row(Modifier.fillMaxWidth().height(108.dp).padding(horizontal = 32.dp),
                    horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                    RecentButton(saved.firstOrNull(), saved.size, thumbnail) { reviewUri = saved.firstOrNull()?.uri }
                    Shutter(state, onCapture)
                    parameterButton()
                }
                TetherStatus(state)
            }
        }
    }
    val review = saved.find { it.uri == reviewUri }
    if (review != null) TetherReview(review, saved, thumbnail, onSelect = { reviewUri = it.uri },
        onDismiss = { reviewUri = null }, onEdit = { reviewUri = null; onEdit(review) })
    if (shootingParameters) TetherParameterSheet(state, onSetParameter, onDismiss = { shootingParameters = false })
}

private enum class TetherParameterKind(val code: Int, val title: Int, val tag: String) {
    SHUTTER(CameraShootingParameter.SHUTTER.code, R.string.camera_param_shutter, "shutter"),
    APERTURE(0x5007, R.string.camera_param_aperture, "aperture"),
    ISO(CameraShootingParameter.ISO.code, R.string.camera_param_iso, "iso"),
    EV(0x5010, R.string.camera_param_ev, "ev"),
    WB(CameraShootingParameter.WHITE_BALANCE.code, R.string.camera_param_wb, "wb"),
    FOCUS(CameraShootingParameter.FOCUS.code, R.string.camera_param_focus, "focus"),
    FOCUS_AREA(CameraShootingParameter.FOCUS_AREA.code, R.string.camera_param_focus_area, "focus-area"),
    TEMPERATURE(0xd20f, R.string.camera_param_temperature, "temperature");

    companion object {
        val common = listOf(SHUTTER, APERTURE, ISO, EV)
        val panel = listOf(WB, FOCUS, FOCUS_AREA, TEMPERATURE)
    }
}

private fun CameraTetherParameter.valueText(): String = formatCameraParameter(code, current)

@Composable
private fun TetherParameterBar(state: CameraTetherState, onSetParameter: (Int, Long) -> Unit) {
    val values = state.parameters.values.associateBy { it.code }
    Surface(color = MaterialTheme.colorScheme.surface) {
        Column(Modifier.fillMaxWidth().testTag("tether-parameter-strip")) {
            HorizontalDivider()
            Row(Modifier.fillMaxWidth()) {
                TetherParameterKind.common.forEach { kind ->
                    TetherParameterControl(kind, values[kind.code] ?: if (kind == TetherParameterKind.ISO) values[0xd226] else null,
                        state.parameters, onSetParameter, Modifier.weight(1f),
                        available = state.phase == CameraTetherPhase.READY && !state.focusBusy, focusBusy = state.focusBusy)
                }
            }
            if (state.parameters.busy) {
                val busyLabel = stringResource(R.string.camera_param_busy)
                LinearProgressIndicator(
                    Modifier.fillMaxWidth().height(2.dp).semantics { contentDescription = busyLabel },
                )
            }
            state.parameters.failure?.let { failure ->
                val message = when (failure) {
                    CameraParameterFailure.UNAVAILABLE -> R.string.camera_param_unavailable
                    CameraParameterFailure.UNCONFIRMED -> R.string.camera_param_unknown
                    CameraParameterFailure.REJECTED, CameraParameterFailure.CONNECTION -> R.string.camera_param_failed
                }
                Text(stringResource(message), Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                    style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.error)
            }
            HorizontalDivider()
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TetherParameterControl(kind: TetherParameterKind, parameter: CameraTetherParameter?,
    parameters: CameraTetherParameterState, onSetParameter: (Int, Long) -> Unit, modifier: Modifier = Modifier,
    available: Boolean = true, focusBusy: Boolean = false, inline: Boolean = false) {
    var menu by remember(kind, parameter?.current, parameter?.options) { mutableStateOf(false) }
    var reason by remember { mutableStateOf(false) }
    val canSet = available && parameter != null && parameter.enabled && parameter.writable && parameters.writable &&
        !parameters.busy && !focusBusy && parameter.options.isNotEmpty()
    val readoutColor = if (canSet) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.55f)
    Box(modifier) {
        val cell = Modifier.fillMaxWidth().heightIn(min = 64.dp).clickable(enabled = !parameters.busy && !focusBusy, role = Role.Button) {
            if (canSet) menu = true else reason = true
        }.padding(horizontal = 4.dp, vertical = 8.dp).testTag("tether-parameter-${kind.tag}")
        val value = parameter?.valueText() ?: "—"
        if (inline) Row(cell, verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(kind.title), Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
            Text(value, style = MaterialTheme.typography.bodyMedium, color = readoutColor)
            if (!canSet) Text(stringResource(R.string.camera_param_readonly_short), Modifier.padding(start = 8.dp), style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        } else Box(cell, contentAlignment = Alignment.Center) {
            val readout = when {
                parameter == null -> "—"
                kind == TetherParameterKind.ISO -> "ISO $value"
                kind == TetherParameterKind.SHUTTER -> value.removeSuffix(" s")
                else -> value
            }
            Text(readout, fontSize = 16.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, color = readoutColor,
                modifier = Modifier.semantics { contentDescription = readout })
        }
    }
    if (menu && parameter != null) {
        val sheetOptions = parameter.options
        val currentIndex = sheetOptions.indexOf(parameter.current).coerceAtLeast(0)
        val listState = rememberLazyListState(initialFirstVisibleItemIndex = currentIndex)
        ModalBottomSheet(
            onDismissRequest = { menu = false },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        ) {
            Column(
                Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(stringResource(kind.title), style = MaterialTheme.typography.titleLarge)
                LazyColumn(state = listState, modifier = Modifier.fillMaxWidth().heightIn(max = 360.dp)) {
                    items(sheetOptions) { option ->
                        val isCurrent = option == parameter.current
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .heightIn(min = 48.dp)
                                .clip(CameraControlShape)
                                .clickable {
                                    menu = false
                                    onSetParameter(parameter.code, option)
                                }
                                .padding(horizontal = 12.dp, vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                formatCameraParameter(parameter.code, option),
                                Modifier.weight(1f),
                                style = MaterialTheme.typography.bodyLarge,
                                color = if (isCurrent) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                            )
                            if (isCurrent) {
                                Icon(Icons.Outlined.Check, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                            }
                        }
                        HorizontalDivider()
                    }
                }
            }
        }
    }
    if (reason) AlertDialog(onDismissRequest = { reason = false }, title = { Text(stringResource(kind.title)) },
        text = { Text(stringResource(if (parameter == null) R.string.camera_param_unavailable else R.string.camera_param_readonly)) },
        confirmButton = { TextButton(onClick = { reason = false }) { Text(stringResource(R.string.confirm)) } })
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TetherParameterSheet(state: CameraTetherState, onSetParameter: (Int, Long) -> Unit, onDismiss: () -> Unit) {
    val values = state.parameters.values.associateBy { it.code }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp).navigationBarsPadding()
            .verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(stringResource(R.string.camera_shooting_parameters), style = MaterialTheme.typography.headlineSmall)
            TetherParameterKind.panel.filter { (it != TetherParameterKind.TEMPERATURE && it != TetherParameterKind.FOCUS_AREA) || values.containsKey(it.code) }.forEach { kind ->
                TetherParameterControl(kind, values[kind.code], state.parameters, onSetParameter, Modifier.fillMaxWidth(),
                    available = state.phase == CameraTetherPhase.READY && !state.focusBusy, focusBusy = state.focusBusy, inline = true)
                HorizontalDivider()
            }
            if (state.parameters.failure != null) Text(stringResource(R.string.camera_param_failed), color = MaterialTheme.colorScheme.error)
            TextButton(onClick = onDismiss, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.cancel)) }
        }
    }
}

@Composable
private fun TetherViewfinder(
    state: CameraTetherState,
    grid: Boolean,
    modifier: Modifier,
    onFocusPoint: (Int, Int) -> Unit = { _, _ -> },
    onCancelTouchFocus: () -> Unit = {},
) {
    val live = state.active && state.live && state.liveAvailable && state.frame != null
    val label = stringResource(when {
        live -> R.string.tether_live
        state.frame != null || state.liveAvailable -> R.string.tether_stale
        else -> R.string.camera_live_unavailable
    })
    var containerSize by remember { mutableStateOf(IntSize.Zero) }
    var tapReticle by remember { mutableStateOf<Pair<Long, CameraFocusTap>?>(null) }
    var lastFocusSquareRatio by remember { mutableStateOf<Float?>(null) }
    LaunchedEffect(tapReticle?.first, state.focusBusy) {
        if (state.focusBusy) return@LaunchedEffect
        val activeTap = tapReticle ?: return@LaunchedEffect
        delay(1_800)
        if (tapReticle?.first == activeTap.first) tapReticle = null
    }
    LaunchedEffect(state.focusFailure, state.focusBusy, state.focusFrames, live) {
        if (!live || state.focusFailure != null || (!state.focusBusy && state.focusFrames.isNotEmpty())) {
            tapReticle = null
        }
    }
    LaunchedEffect(state.focusFrames, state.frame, state.active) {
        if (!state.active) {
            lastFocusSquareRatio = null
            return@LaunchedEffect
        }
        val bitmap = state.frame ?: return@LaunchedEffect
        val nonFace = state.focusFrames.filter { it.kind != SonyTetherSession.LiveViewFrameKind.FACE }
        if (nonFace.size == 1) {
            normalizedFocusSquareRatio(nonFace[0], bitmap.width, bitmap.height)?.let { lastFocusSquareRatio = it }
        }
    }
    val canTap = live && state.phase == CameraTetherPhase.READY && !state.focusBusy && !state.parameters.busy
    val latestFrame by rememberUpdatedState(state.frame)
    val latestContainerSize by rememberUpdatedState(containerSize)
    val latestOnFocusPoint by rememberUpdatedState(onFocusPoint)
    Box(
        modifier
            .background(Color.Black)
            .onSizeChanged { containerSize = it }
            .pointerInput(canTap) {
                if (!canTap) return@pointerInput
                detectTapGestures { offset ->
                    val bitmap = latestFrame ?: return@detectTapGestures
                    val bounds = latestContainerSize
                    val tap = mapViewfinderTapToCameraGrid(
                        tapX = offset.x,
                        tapY = offset.y,
                        containerWidth = bounds.width.toFloat(),
                        containerHeight = bounds.height.toFloat(),
                        imageWidth = bitmap.width,
                        imageHeight = bitmap.height,
                    ) ?: return@detectTapGestures
                    tapReticle = System.nanoTime() to tap
                    latestOnFocusPoint(tap.x, tap.y)
                }
            }
            .testTag("tether-viewfinder"),
        contentAlignment = Alignment.Center,
    ) {
        state.frame?.let { bitmap ->
            Image(bitmap.asImageBitmap(), label, Modifier.fillMaxSize().graphicsLayer { alpha = if (live) 1f else .45f }, contentScale = ContentScale.Fit)
            if (grid) Canvas(Modifier.fillMaxSize().testTag("tether-grid")) {
                val ratio = bitmap.width.toFloat() / bitmap.height
                val width = minOf(size.width, size.height * ratio); val height = width / ratio
                val left = (size.width - width) / 2; val top = (size.height - height) / 2
                for (i in 1..2) {
                    drawLine(Color.White.copy(alpha = .5f), Offset(left + width * i / 3, top), Offset(left + width * i / 3, top + height), 1.dp.toPx())
                    drawLine(Color.White.copy(alpha = .5f), Offset(left, top + height * i / 3), Offset(left + width, top + height * i / 3), 1.dp.toPx())
                }
            }
            if (live) {
                val focusLocked = state.isFocusLocked
                Canvas(Modifier.fillMaxSize().testTag("tether-focus-overlay")) {
                    val ratio = bitmap.width.toFloat() / bitmap.height
                    val width = minOf(size.width, size.height * ratio); val height = width / ratio
                    val left = (size.width - width) / 2; val top = (size.height - height) / 2
                    val green = Color(0xFF34D759)
                    val white = Color.White.copy(alpha = 0.92f)
                    val backing = Color.Black.copy(alpha = 0.45f)
                    clipRect(left = left, top = top, right = left + width, bottom = top + height) {
                        if (!state.focusBusy && state.focusFrames.isNotEmpty()) {
                            for (frame in state.focusFrames) {
                                val box = computeFocusOverlayBox(frame, left, top, width, height)
                                val focused = frame.focused || (focusLocked && frame.kind != SonyTetherSession.LiveViewFrameKind.FACE)
                                val strokeWidth = if (focused) 2.dp.toPx() else 1.5.dp.toPx()
                                drawRect(backing, Offset(box.x, box.y), Size(box.width, box.height), style = Stroke(width = strokeWidth + 1.5.dp.toPx()))
                                drawRect(if (focused) green else white, Offset(box.x, box.y), Size(box.width, box.height), style = Stroke(width = strokeWidth))
                            }
                        } else {
                            tapReticle?.second?.let { tap ->
                                val boxSize = computeTapFocusSide(
                                    width,
                                    height,
                                    minDefaultPx = 34.dp.toPx(),
                                    maxDefaultPx = 52.dp.toPx(),
                                    minLearnedPx = 20.dp.toPx(),
                                    lastSquareRatio = lastFocusSquareRatio,
                                )
                                val x = left + tap.u * width - boxSize / 2f
                                val y = top + tap.v * height - boxSize / 2f
                                val strokeWidth = if (focusLocked) 2.dp.toPx() else 1.75.dp.toPx()
                                drawRect(backing, Offset(x, y), Size(boxSize, boxSize), style = Stroke(width = strokeWidth + 1.5.dp.toPx()))
                                drawRect(if (focusLocked) green else white, Offset(x, y), Size(boxSize, boxSize), style = Stroke(width = strokeWidth))
                            }
                        }
                    }
                }
            }
        }
        if (state.frame == null && state.active && state.liveAvailable) CircularProgressIndicator(Modifier.size(32.dp))
        if (state.frame != null) Row(
            Modifier.align(Alignment.TopStart).padding(12.dp)
                .background(Color.Black.copy(alpha = 0.68f), MaterialTheme.shapes.small)
                .padding(horizontal = 8.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Box(Modifier.size(6.dp).clip(CircleShape).background(if (live) Color(0xFF34D759) else Color.Gray))
            Text(if (live) "LIVE" else label, color = Color.White, style = MaterialTheme.typography.labelSmall)
        }
        else if (state.active) Text(label,
            Modifier.background(Color.Black.copy(alpha = .7f), MaterialTheme.shapes.small).padding(12.dp), color = Color.White)
        if (live && state.parameters.canCancelTouchFocus) {
            val cancelEnabled = !state.focusBusy && state.phase == CameraTetherPhase.READY
            Row(
                Modifier
                    .align(Alignment.TopEnd)
                    .padding(8.dp)
                    .defaultMinSize(minWidth = 48.dp, minHeight = 48.dp)
                    .clip(RoundedCornerShape(24.dp))
                    .background(Color.Black.copy(alpha = 0.68f))
                    .clickable(enabled = cancelEnabled, role = Role.Button) {
                        tapReticle = null
                        onCancelTouchFocus()
                    }
                    .padding(horizontal = 12.dp, vertical = 10.dp)
                    .testTag("tether-cancel-focus"),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Icon(Icons.Outlined.Close, contentDescription = null, modifier = Modifier.size(16.dp), tint = Color.White)
                Text(stringResource(R.string.tether_cancel_focus), color = Color.White, style = MaterialTheme.typography.labelMedium)
            }
        }
    }
}

@Composable
private fun TetherStatus(state: CameraTetherState) {
    val phase = when (state.phase) {
        CameraTetherPhase.READY -> R.string.tether_ready
        CameraTetherPhase.CAPTURING -> R.string.tether_capturing
        CameraTetherPhase.WAITING -> R.string.tether_waiting
        CameraTetherPhase.RECEIVING -> R.string.tether_receiving
        CameraTetherPhase.PAUSED, CameraTetherPhase.IDLE -> R.string.tether_paused
        CameraTetherPhase.PREPARING -> R.string.tether_preparing
    }
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        if (state.resumedRegisteredOnly) Text(stringResource(R.string.camera_resume_registered), style = MaterialTheme.typography.bodySmall)
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(if (state.phase == CameraTetherPhase.READY) R.string.camera_connected_receiving else phase), Modifier.weight(1f), style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(stringResource(R.string.tether_saved, state.saved.size), style = MaterialTheme.typography.labelSmall)
            if (state.pendingCount > 0) Text(" · " + stringResource(R.string.tether_pending, state.pendingCount), style = MaterialTheme.typography.labelSmall)
        }
        state.focusFailure?.let { focusFailure ->
            val focusMessage = when (focusFailure) {
                CameraFocusFailure.MANUAL_FOCUS -> R.string.tether_focus_manual
                CameraFocusFailure.FOCUS_AREA_FIXED -> R.string.tether_focus_area_fixed
                CameraFocusFailure.UNSUPPORTED -> R.string.tether_focus_unsupported
                CameraFocusFailure.REJECTED -> R.string.tether_focus_rejected
            }
            Text(stringResource(focusMessage), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error,
                modifier = Modifier.testTag("tether-focus-error"))
        }
        state.current?.let { photo ->
            Text(photo.name, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
            LinearProgressIndicator(progress = { (state.currentBytes.toFloat() / photo.size.coerceAtLeast(1)).coerceIn(0f, 1f) },
                modifier = Modifier.fillMaxWidth().testTag("tether-transfer-progress"))
            Text("${Formatter.formatShortFileSize(LocalContext.current, state.currentBytes)} / ${Formatter.formatShortFileSize(LocalContext.current, photo.size)}",
                style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        state.failure?.let { failure ->
            val message = when (failure) {
                CameraTetherFailure.UNKNOWN_SHOT -> R.string.tether_unknown
                CameraTetherFailure.SETTINGS -> R.string.tether_settings_error
                CameraTetherFailure.SOURCE -> R.string.tether_source_error
                CameraTetherFailure.STORAGE -> R.string.camera_storage_failed
                CameraTetherFailure.BACKLOG -> if (state.canResume) R.string.tether_backlog_error else R.string.tether_source_error
                CameraTetherFailure.LIVE -> R.string.tether_live_error
                CameraTetherFailure.UNSUPPORTED -> R.string.tether_unsupported
                CameraTetherFailure.PHOTO_LIMIT -> R.string.tether_photo_limit
                CameraTetherFailure.CONNECTION -> R.string.camera_connection_failed
            }
            Text(stringResource(message), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
        }
    }
}

@Composable
private fun Shutter(state: CameraTetherState, onCapture: () -> Unit) {
    val enabled = state.phase == CameraTetherPhase.READY && (state.live || !state.liveAvailable) && state.parameters.captureReady && !state.parameters.busy && !state.focusBusy
    val label = stringResource(R.string.tether_shutter)
    Box(Modifier.size(68.dp).border(3.dp, if (enabled) Color.White else MaterialTheme.colorScheme.outline, CircleShape)
        .padding(5.dp).clip(CircleShape).background(if (enabled) Color.White else MaterialTheme.colorScheme.surfaceContainerHigh)
        .clickable(enabled = enabled, role = Role.Button, onClick = onCapture).semantics { contentDescription = label }.testTag("tether-shutter"),
        contentAlignment = Alignment.Center) {
        if (state.phase == CameraTetherPhase.CAPTURING || state.phase == CameraTetherPhase.WAITING)
            CircularProgressIndicator(Modifier.size(30.dp), strokeWidth = 2.dp)
    }
}

@Composable
private fun RecentButton(photo: CameraTetherSaved?, count: Int, thumbnail: suspend (Uri, Int) -> Bitmap?, onReview: () -> Unit) {
    val label = stringResource(R.string.tether_recent)
    Box(Modifier.size(48.dp).clickable(enabled = photo != null, role = Role.Button, onClick = onReview)
        .semantics { contentDescription = label }.testTag("tether-recent"), contentAlignment = Alignment.Center) {
        if (photo != null) SavedThumbnail(photo, thumbnail, Modifier.size(48.dp).clip(MaterialTheme.shapes.small))
        else Icon(AppIcons.Outlined.PhotoLibrary, null, Modifier.size(48.dp).padding(10.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun SavedThumbnail(photo: CameraTetherSaved, loader: suspend (Uri, Int) -> Bitmap?, modifier: Modifier, large: Boolean = false) {
    val preview by produceState<Pair<Bitmap?, Boolean>>(null to false, photo.uri, large) {
        value = withContext(Dispatchers.IO) { loader(Uri.parse(photo.uri), if (large) 1024 else 256) } to true
    }
    val bitmap = preview.first
    Box(modifier.background(Color.Black), contentAlignment = Alignment.Center) {
        if (bitmap != null) Image(bitmap!!.asImageBitmap(), photo.photo.name, Modifier.fillMaxSize(), contentScale = if (large) ContentScale.Fit else ContentScale.Crop)
        else if (large && !preview.second) CircularProgressIndicator(Modifier.size(28.dp))
        else if (large) Text(stringResource(R.string.tether_preview_missing), Modifier.padding(16.dp), style = MaterialTheme.typography.bodySmall)
        else Icon(AppIcons.Outlined.PhotoLibrary, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun TetherReview(photo: CameraTetherSaved, saved: List<CameraTetherSaved>, thumbnail: suspend (Uri, Int) -> Bitmap?,
    onSelect: (CameraTetherSaved) -> Unit, onDismiss: () -> Unit, onEdit: () -> Unit) {
    var zoom by remember(photo.uri) { mutableFloatStateOf(1f) }
    var offset by remember(photo.uri) { mutableStateOf(Offset.Zero) }
    val index = saved.indexOfFirst { it.uri == photo.uri }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Surface(Modifier.fillMaxSize().testTag("tether-review"), color = Color.Black, contentColor = Color.White) {
            Column(Modifier.fillMaxSize().systemBarsPadding()) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = onDismiss, modifier = Modifier.testTag("tether-review-close")) { Icon(Icons.Outlined.Close, stringResource(R.string.back)) }
                    Text(stringResource(R.string.tether_review_index, index + 1, saved.size), Modifier.weight(1f), style = MaterialTheme.typography.labelLarge)
                    TextButton(onClick = { zoom = 1f; offset = Offset.Zero }) { Text("${(zoom * 100).toInt()}%") }
                }
                Box(Modifier.weight(1f).fillMaxWidth().clip(MaterialTheme.shapes.extraSmall).pointerInput(photo.uri) {
                    detectTransformGestures { _, pan, scale, _ ->
                        zoom = (zoom * scale).coerceIn(1f, 4f)
                        val x = size.width * (zoom - 1f) / 2; val y = size.height * (zoom - 1f) / 2
                        offset = Offset((offset.x + pan.x).coerceIn(-x, x), (offset.y + pan.y).coerceIn(-y, y))
                    }
                }) {
                    SavedThumbnail(photo, thumbnail, Modifier.fillMaxSize().graphicsLayer {
                        scaleX = zoom; scaleY = zoom; translationX = offset.x; translationY = offset.y
                    }, large = true)
                }
                Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(photo.photo.name, style = MaterialTheme.typography.titleSmall)
                    Text("${if (photo.photo.raw) "RAW" else "JPEG"} · ${Formatter.formatShortFileSize(LocalContext.current, photo.photo.size)}", style = MaterialTheme.typography.labelMedium)
                    Text(stringResource(R.string.tether_preview_note), color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
                }
                Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = { onSelect(saved[index - 1]) }, enabled = index > 0, modifier = Modifier.testTag("tether-review-previous")) {
                        Icon(AppIcons.AutoMirrored.Outlined.NavigateBefore, stringResource(R.string.camera_previous))
                    }
                    Button(onClick = onEdit, modifier = Modifier.weight(1f).testTag("tether-review-edit")) { Text(stringResource(R.string.camera_open)) }
                    IconButton(onClick = { onSelect(saved[index + 1]) }, enabled = index + 1 < saved.size, modifier = Modifier.testTag("tether-review-next")) {
                        Icon(AppIcons.AutoMirrored.Outlined.NavigateNext, stringResource(R.string.camera_next))
                    }
                }
            }
        }
    }
}
