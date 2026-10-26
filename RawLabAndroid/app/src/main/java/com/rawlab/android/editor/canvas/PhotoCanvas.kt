package com.rawlab.android.editor.canvas

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.border
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.graphics.drawscope.Stroke
import com.rawlab.android.editor.controls.HslTargetActions
import androidx.compose.foundation.focusable
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.SwapHoriz
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.key.*
import androidx.compose.ui.input.pointer.PointerInputScope
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.max
import kotlin.math.abs
import kotlin.math.roundToInt
import com.rawlab.android.R
import com.rawlab.android.editor.render.PreviewPair
import com.rawlab.android.photo.PhotoInfo

class PhotoCanvasState {
    var viewport by mutableStateOf<PhotoViewport?>(null)
    var view by mutableStateOf(PhotoViewTransform())
    var pureOrigin by mutableStateOf<PhotoViewTransform?>(null)
    var split by mutableFloatStateOf(.5f)
    var zoom: PhotoZoom?
        get() = viewport?.let(view::project)
        set(value) { viewport?.let { if (value != null) view = PhotoViewTransform.from(value, it) } }

    fun resize(next: PhotoViewport) { viewport = next }
    fun transform(factor: Float, pan: Offset, focus: Offset, pane: PhotoViewport? = viewport) {
        val area = pane ?: return
        view = PhotoViewTransform.from(view.project(area).transform(area, factor, pan.x, pan.y, focus.x, focus.y), area)
    }
    fun doubleTap(point: Offset, pane: PhotoViewport? = viewport) {
        val area = pane ?: return
        view = PhotoViewTransform.from(view.project(area).doubleTap(area, point.x, point.y), area)
    }
    fun enterPure() { if (pureOrigin == null) pureOrigin = view }
    fun exitPure() { pureOrigin?.let { view = it }; pureOrigin = null }

    companion object {
        private const val FORMAT = -3f
        val Saver = listSaver<PhotoCanvasState, Float>(save = {
            val origin = it.pureOrigin
            listOf(FORMAT, it.split, it.view.magnification, it.view.focusX, it.view.focusY,
                if (origin == null) 0f else 1f, origin?.magnification ?: 1f, origin?.focusX ?: .5f, origin?.focusY ?: .5f)
        }, restore = { saved ->
            PhotoCanvasState().apply {
                when {
                    saved.size == 1 -> if (saved[0].isFinite()) split = saved[0].coerceIn(0f, 1f)
                    saved.size == 8 && saved.all { it.isFinite() } && (1..5).all { saved[it] > 0f } -> {
                        // 已发布版本存的是照片/窗口尺寸与像素缩放，不是 canonical 的倍率和焦点。
                        split = saved[0].coerceIn(0f, 1f)
                        val area = PhotoViewport(saved[1], saved[2], saved[3], saved[4])
                        viewport = area
                        view = PhotoViewTransform.from(PhotoZoom(saved[5], saved[6], saved[7]).constrained(area), area)
                    }
                    saved.size == 9 && saved[0] == FORMAT && saved.all { it.isFinite() } &&
                        saved[2] > 0f && saved[3] in 0f..1f && saved[4] in 0f..1f &&
                        saved[5] in listOf(0f, 1f) && saved[6] > 0f && saved[7] in 0f..1f && saved[8] in 0f..1f -> {
                        split = saved[1].coerceIn(0f, 1f)
                        view = PhotoViewTransform(saved[2], saved[3], saved[4])
                        if (saved[5] == 1f) pureOrigin = PhotoViewTransform(saved[6], saved[7], saved[8])
                    }
                }
            }
        })
    }
}

@Composable
internal fun PhotoCanvas(
    pair: PreviewPair, compare: Boolean, filename: String, state: PhotoCanvasState,
    info: PhotoInfo? = null, infoMode: Int = 0, onInfoClick: () -> Unit = {},
    onPreviewSizeChange: (Int) -> Unit = {}, bottomOverlayInset: Dp = 0.dp,
    bottomOverlay: @Composable () -> Unit = {},
    mode: ComparisonMode = ComparisonMode.SIDE_BY_SIDE, holdingBefore: Boolean = false,
    showOverlays: Boolean = true, margins: Boolean = true,
    onCanvasTap: () -> Unit = {}, onHoldBefore: (Boolean) -> Unit = {},
    onModeChange: (ComparisonMode) -> Unit = {}, onCompareClose: () -> Unit = {}, viewingEnabled: Boolean = true,
    hslTarget: HslTargetActions? = null,
) {
    val wipeDescription = stringResource(R.string.editor_compare_split)
    val fitDescription = stringResource(R.string.zoom_fit)
    val beforeLabel = stringResource(R.string.editor_compare_before)
    val afterLabel = stringResource(R.string.result)
    val pureAction = stringResource(if (showOverlays) R.string.editor_preview_enter else R.string.editor_preview_exit)
    val holdAction = stringResource(if (holdingBefore) R.string.editor_compare_show_after else R.string.editor_compare_hold_before)
    val resetSplit = stringResource(R.string.editor_compare_reset_split)
    val tap by rememberUpdatedState(onCanvasTap)
    val hold by rememberUpdatedState(onHoldBefore)
    val target by rememberUpdatedState(hslTarget)
    val focusRequester = remember { FocusRequester() }
    var canvasOrigin by remember { mutableStateOf(Offset.Zero) }
    val labelBounds = remember { mutableStateMapOf<String, Rect>() }
    var targetTouch by remember { mutableStateOf<Offset?>(null) }
    var targetAnchor by remember { mutableStateOf<Offset?>(null) }
    var targetImage by remember { mutableStateOf<android.graphics.Bitmap?>(null) }
    DisposableEffect(Unit) { onDispose { hold(false); target?.cancel() } }
    BoxWithConstraints(Modifier.fillMaxSize().padding(if (margins) 8.dp else 0.dp).clipToBounds()) {
        if (constraints.maxWidth == 0 || constraints.maxHeight == 0) return@BoxWithConstraints
        val canvasWidth = constraints.maxWidth.toFloat(); val canvasHeight = constraints.maxHeight.toFloat()
        val horizontal = constraints.maxWidth >= constraints.maxHeight
        val sideBySide = compare && mode == ComparisonMode.SIDE_BY_SIDE
        val gap = 1.dp
        val gapPx = with(androidx.compose.ui.platform.LocalDensity.current) { gap.roundToPx() }
        val primary = PhotoViewport(pair.comparisonWidth, pair.comparisonHeight,
            if (sideBySide && horizontal) ((constraints.maxWidth - gapPx) / 2).toFloat() else constraints.maxWidth.toFloat(),
            if (sideBySide && !horizontal) ((constraints.maxHeight - gapPx) / 2).toFloat() else constraints.maxHeight.toFloat())
        SideEffect { if (state.viewport != primary) state.resize(primary) }
        val previewEdge = primary.previewLongEdge(state.view.project(primary).scale)
        LaunchedEffect(previewEdge) { onPreviewSizeChange(previewEdge) }
        val percent = "${(state.view.project(primary).scale * 100).roundToInt()}%"
        val before = holdingBefore && !compare && hslTarget == null
        val resultOrigin = Offset(if (sideBySide && horizontal) primary.width + gapPx else 0f,
            if (sideBySide && !horizontal) primary.height + gapPx else 0f)
        val touchImage by rememberUpdatedState(pair.result)
        val targetDividerRadius = with(androidx.compose.ui.platform.LocalDensity.current) { 24.dp.toPx() }
        val targetHit: (Offset) -> Offset? = { point ->
            if (labelBounds.values.any { it.contains(point + canvasOrigin) }) null else {
                val local = point-resultOrigin
                hslTargetCoordinates(primary, state.view.project(primary), local.x, local.y,
                    if (compare && mode == ComparisonMode.WIPE) state.split else null, targetDividerRadius)
                    ?.let { Offset(it.first,it.second) }
            }
        }
        @Composable fun pane(modifier: Modifier, neutralOnly: Boolean = false, paneLabel: String? = null) {
            BoxWithConstraints(modifier.clipToBounds()) {
                val area = PhotoViewport(pair.comparisonWidth, pair.comparisonHeight, constraints.maxWidth.toFloat(), constraints.maxHeight.toFloat())
                val zoom = state.view.project(area)
                val image = photoImageRect(area, zoom)
                val transform = Modifier.fillMaxSize().graphicsLayer {
                    scaleX = zoom.scale / area.fitScale; scaleY = zoom.scale / area.fitScale
                    translationX = zoom.x; translationY = zoom.y
                }
                val wipe = compare && mode == ComparisonMode.WIPE
                Box(Modifier.fillMaxSize()
                    .pointerInput(state, area, compare, mode, viewingEnabled, hslTarget != null) {
                        if (hslTarget == null) detectTapGestures(onDoubleTap = { hold(false); state.doubleTap(it, area) },
                            onLongPress = { if (!compare && viewingEnabled) hold(true) },
                            onPress = { try { tryAwaitRelease() } finally { hold(false) } }, onTap = { if (viewingEnabled || !showOverlays) tap() })
                    }) {
                    Image((if (neutralOnly || before) pair.neutral else pair.result).asImageBitmap(), null,
                        transform.testTag(if (neutralOnly || before) "comparison-before" else "comparison-after"), contentScale = ContentScale.Fit)
                    if (wipe) {
                        Box(Modifier.fillMaxSize().drawWithContent {
                            val x = image.splitX(state.split)
                            clipRect(image.left, image.top, x, image.bottom) { this@drawWithContent.drawContent() }
                            drawLine(Color.White, Offset(x, image.top), Offset(x, image.bottom), 1.dp.toPx())
                        }) { Image(pair.neutral.asImageBitmap(), null, transform, contentScale = ContentScale.Fit) }
                        Box(Modifier.offset { IntOffset(image.left.roundToInt(), image.top.roundToInt()) }
                            .size(with(androidx.compose.ui.platform.LocalDensity.current) { image.width.toDp() }, with(androidx.compose.ui.platform.LocalDensity.current) { image.height.toDp() })
                            .testTag("comparison-wipe").semantics {
                            contentDescription = wipeDescription
                            stateDescription = "${(state.split * 100).roundToInt()}%"
                            progressBarRangeInfo = ProgressBarRangeInfo(state.split, 0f..1f)
                            setProgress { if (!it.isFinite()) false else { state.split = it.coerceIn(0f, 1f); true } }
                            customActions = listOf(CustomAccessibilityAction(resetSplit) { state.split = .5f; true })
                        }.onKeyEvent {
                            if (it.type != KeyEventType.KeyDown) false else when (it.key) {
                                Key.DirectionLeft, Key.DirectionDown -> { state.split = (state.split - .02f).coerceAtLeast(0f); true }
                                Key.DirectionRight, Key.DirectionUp -> { state.split = (state.split + .02f).coerceAtMost(1f); true }
                                Key.MoveHome -> { state.split = .5f; true }
                                else -> false
                            }
                        }.focusable())
                        Box(Modifier.offset { IntOffset((image.splitX(state.split).coerceIn(image.left + minOf(24.dp.toPx(), image.width / 2), image.right - minOf(24.dp.toPx(), image.width / 2)) - 16.dp.toPx()).roundToInt(), ((image.top + image.bottom) / 2 - 16.dp.toPx()).roundToInt()) }
                            .size(32.dp).testTag("comparison-handle").background(Color.White, CircleShape).padding(4.dp)) {
                            Icon(Icons.Outlined.SwapHoriz, null, Modifier.fillMaxSize().testTag("comparison-handle-glyph"), tint = Color.Black)
                        }
                    }
                    if (showOverlays && (paneLabel != null || wipe)) {
                        Box(Modifier.offset { IntOffset(image.left.roundToInt(), image.top.roundToInt()) }
                            .size(with(androidx.compose.ui.platform.LocalDensity.current) { image.width.toDp() }, with(androidx.compose.ui.platform.LocalDensity.current) { image.height.toDp() })) {
                            val labels = if (paneLabel != null) listOf(paneLabel) else listOf(beforeLabel, afterLabel)
                            val labelStyle = MaterialTheme.typography.labelSmall
                            val measurer = rememberTextMeasurer()
                            // 短照片放不下两条完整文案时分居两行；通常仍留在底部避开信息入口。
                            val separateRows = paneLabel == null && labels.sumOf { measurer.measure(it, labelStyle).size.width } +
                                with(androidx.compose.ui.platform.LocalDensity.current) { 32.dp.toPx() } > image.width
                            val labelPadding = if (separateRows) 0.dp else 4.dp
                            for ((index, label) in labels.withIndex()) {
                                val labelKey = "$neutralOnly-$index"
                                DisposableEffect(labelKey) { onDispose { labelBounds.remove(labelKey) } }
                                Text(label,
                                Modifier.align(if (paneLabel != null || index == 0 && !separateRows) Alignment.BottomStart
                                    else if (index == 0) Alignment.TopStart else Alignment.BottomEnd)
                                    .padding(labelPadding).testTag(if (neutralOnly || paneLabel == null && index == 0) "comparison-label-before" else "comparison-label-after")
                                    .background(Color.Black.copy(alpha = .65f)).padding(labelPadding)
                                    .onGloballyPositioned { labelBounds[labelKey] = it.boundsInWindow() }, color = Color.White,
                                style = labelStyle, maxLines = 1)
                            }
                        }
                    }
                }
            }
        }
        Box(Modifier.fillMaxSize().testTag("photo-canvas")
            .onGloballyPositioned { canvasOrigin = it.positionInWindow() }
            .focusRequester(focusRequester).onKeyEvent { event ->
                val action = target
                if (action == null || event.type != KeyEventType.KeyDown) false else when (event.key) {
                    Key.Escape -> { action.cancel(); true }
                    Key.DirectionUp, Key.DirectionRight -> { action.key(if (event.isShiftPressed) .1f else 1f); true }
                    Key.DirectionDown, Key.DirectionLeft -> { action.key(if (event.isShiftPressed) -.1f else -1f); true }
                    else -> false
                }
            }.focusable(hslTarget != null).semantics {
            contentDescription = filename
            stateDescription = if (before) beforeLabel else if (primary.isFit(state.view.project(primary).scale)) "$fitDescription $percent" else percent
            customActions = buildList {
                add(CustomAccessibilityAction("100%") { state.zoom = PhotoZoom(1f); true })
                add(CustomAccessibilityAction(fitDescription) { state.view = PhotoViewTransform(); true })
                if (hslTarget == null && (viewingEnabled || !showOverlays)) add(CustomAccessibilityAction(pureAction) { tap(); true })
                if (hslTarget == null && viewingEnabled && !compare) add(CustomAccessibilityAction(holdAction) { hold(!holdingBefore); true })
            }
        }) {
            // 手势接收层只包住照片，保证跨 pane 的两指仍在同一命中链；控件叠层保持优先。
            Box(Modifier.fillMaxSize().pointerInput(state, primary, compare, mode, horizontal, hslTarget != null, hslTarget?.state?.axis) {
                photoGestures(state, primary, compare && mode == ComparisonMode.WIPE, { hold(false) },
                    target = { target }, targetHit = targetHit, targetFocus = { focusRequester.requestFocus() },
                    targetPointer = { position, anchor ->
                        targetTouch = position
                        if (anchor != null) { targetAnchor = anchor; targetImage = touchImage }
                        if (position == null) targetImage = null
                    }) { point ->
                    Offset(if (sideBySide && horizontal && point.x > primary.width) primary.width + gapPx else 0f,
                        if (sideBySide && !horizontal && point.y > primary.height) primary.height + gapPx else 0f)
                }
            }) {
            if (sideBySide) {
                if (horizontal) Row(Modifier.fillMaxSize()) {
                    pane(Modifier.weight(1f).fillMaxHeight(), true, beforeLabel); Spacer(Modifier.width(gap)); pane(Modifier.weight(1f).fillMaxHeight(), paneLabel = afterLabel)
                } else Column(Modifier.fillMaxSize()) {
                    pane(Modifier.weight(1f).fillMaxWidth(), true, beforeLabel); Spacer(Modifier.height(gap)); pane(Modifier.weight(1f).fillMaxWidth(), paneLabel = afterLabel)
                }
            } else pane(Modifier.fillMaxSize())
            }
            if (showOverlays) {
                if (hslTarget == null) {
                    BoxWithConstraints(Modifier.fillMaxSize()) { PhotoInfoOverlay(info, infoMode, onInfoClick, maxHeight, if (compare) 112.dp else 64.dp) }
                }
                DisposableEffect(Unit) { onDispose { labelBounds.remove("bottom-overlay") } }
                Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(bottom = bottomOverlayInset)
                    .onGloballyPositioned { labelBounds["bottom-overlay"] = it.boundsInWindow() }) { bottomOverlay() }
                if (compare) {
                    var menu by remember { mutableStateOf(false) }
                    Box(Modifier.align(Alignment.TopEnd).padding(end = 56.dp)) {
                        IconButton(onClick = { menu = true }, Modifier.size(48.dp).testTag("comparison-mode")) {
                            Icon(Icons.Outlined.SwapHoriz, stringResource(R.string.editor_compare_mode))
                        }
                        DropdownMenu(menu, { menu = false }) {
                            DropdownMenuItem(text = { Text(stringResource(R.string.editor_compare_side_by_side)) }, onClick = { menu = false; onModeChange(ComparisonMode.SIDE_BY_SIDE) })
                            DropdownMenuItem(text = { Text(stringResource(R.string.editor_compare_wipe)) }, onClick = { menu = false; onModeChange(ComparisonMode.WIPE) })
                            DropdownMenuItem(text = { Text(stringResource(R.string.editor_compare_disable)) }, onClick = { menu = false; onCompareClose() })
                        }
                    }
                }
            }
            if (hslTarget != null && hslTarget.state.x != null && hslTarget.state.y != null) {
                val projected = state.view.project(primary)
                val photoWidth = primary.imageWidth*projected.scale; val photoHeight = primary.imageHeight*projected.scale
                val photoLeft = resultOrigin.x+(primary.width-photoWidth)/2+projected.x
                val photoTop = resultOrigin.y+(primary.height-photoHeight)/2+projected.y
                Canvas(Modifier.fillMaxSize()) {
                    val point = Offset(photoLeft+hslTarget.state.x*photoWidth, photoTop+hslTarget.state.y*photoHeight)
                    drawCircle(Color.Black, 9.dp.toPx(), point, style = Stroke(4.dp.toPx()))
                    drawCircle(Color.White, 9.dp.toPx(), point, style = Stroke(2.dp.toPx()))
                }
                val finger = targetTouch; val anchor = targetAnchor; val magnified = targetImage
                if (finger != null && anchor != null && magnified != null) {
                    val radius = with(androidx.compose.ui.platform.LocalDensity.current) { 44.dp.toPx() }
                    val centerX = finger.x.coerceIn(radius, maxOf(radius, canvasWidth-radius))
                    val centerY = (if (finger.y > radius*2.5f) finger.y-radius*1.65f else finger.y+radius*1.65f)
                        .coerceIn(radius, maxOf(radius, canvasHeight-radius))
                    Canvas(Modifier.offset { IntOffset((centerX-radius).roundToInt(), (centerY-radius).roundToInt()) }
                        .size(88.dp).clip(CircleShape).background(Color.Black).border(2.dp, Color.White, CircleShape)
                        .testTag("hsl-target-loupe")) {
                        drawImage(magnified.asImageBitmap(), srcSize = IntSize(magnified.width, magnified.height),
                            dstOffset = IntOffset((size.width/2-anchor.x*photoWidth*3).roundToInt(), (size.height/2-anchor.y*photoHeight*3).roundToInt()),
                            dstSize = IntSize((photoWidth*3).roundToInt().coerceAtLeast(1), (photoHeight*3).roundToInt().coerceAtLeast(1)))
                        drawCircle(Color.Black, 6.dp.toPx(), style = Stroke(4.dp.toPx()))
                        drawCircle(Color.White, 6.dp.toPx(), style = Stroke(2.dp.toPx()))
                    }
                }
            }
            RgbHistogramOverlay(if (before) pair.neutralHistogram else pair.resultHistogram, before, showOverlays && hslTarget == null,
                Modifier.align(Alignment.TopEnd).padding(8.dp))
        }
    }
}

@Composable
private fun PhotoInfoOverlay(info: PhotoInfo?, mode: Int, onInfoClick: () -> Unit, availableHeight: Dp, endInset: Dp) {
    val modeDescription = when (mode) {
        1 -> stringResource(R.string.info_file)
        2 -> stringResource(R.string.info_capture)
        else -> stringResource(R.string.info_hidden)
    }
    IconButton(
        onClick = onInfoClick,
        modifier = Modifier.padding(8.dp).size(48.dp)
            .background(Color.Black.copy(alpha = .65f), CircleShape)
            .testTag("photo-info-button")
            .semantics { contentDescription = modeDescription },
    ) {
        Icon(Icons.Outlined.Info, modeDescription, Modifier.size(24.dp), tint = Color.White)
    }
    if (mode != 0 && info != null) {
        Column(
            Modifier.heightIn(max = availableHeight).padding(start = 60.dp, top = 12.dp, end = endInset).widthIn(max = 360.dp)
                .background(Color.Black.copy(alpha = .72f))
                .padding(horizontal = 10.dp, vertical = 8.dp)
                .testTag("photo-info-panel"),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            if (mode == 1) {
                InfoLine(stringResource(R.string.info_filename), info.fileName)
                InfoLine(stringResource(R.string.info_capture_time), info.captureTime)
                InfoLine(stringResource(R.string.info_orientation), info.orientationCorrection)
                InfoLine(stringResource(R.string.info_original_dimensions),
                    if (info.originalWidth != null && info.originalHeight != null) "${info.originalWidth} × ${info.originalHeight}" else null)
            } else {
                InfoLine(stringResource(R.string.info_filename), info.fileName)
                val hasCaptureParameters = info.camera != null || info.lens != null || info.shutter != null ||
                    info.aperture != null || info.iso != null || info.focalLength != null
                if (!hasCaptureParameters) {
                    Text(stringResource(R.string.info_capture_missing), color = Color.White, style = MaterialTheme.typography.labelSmall)
                }
                InfoLine(stringResource(R.string.info_camera), info.camera)
                InfoLine(stringResource(R.string.info_lens), info.lens)
                InfoLine(stringResource(R.string.info_shutter), info.shutter)
                InfoLine(stringResource(R.string.info_aperture), info.aperture?.let { "f/$it" })
                InfoLine(stringResource(R.string.info_iso), info.iso)
                InfoLine(stringResource(R.string.info_focal_length), info.focalLength)
            }
        }
    }
}

@Composable
private fun InfoLine(title: String, value: String?) {
    Text(
        "${title}  ${value ?: stringResource(R.string.info_unavailable)}",
        color = Color.White,
        style = MaterialTheme.typography.labelSmall,
        modifier = Modifier.fillMaxWidth(),
    )
}

private suspend fun PointerInputScope.photoGestures(state: PhotoCanvasState, area: PhotoViewport, wipe: Boolean,
    cancelHold: () -> Unit, target: () -> HslTargetActions? = { null }, targetHit: (Offset) -> Offset? = { null },
    targetPointer: (Offset?, Offset?) -> Unit = { _, _ -> }, targetFocus: () -> Unit = {}, paneOrigin: (Offset) -> Offset) {
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false)
        val origin = paneOrigin(down.position)
        // 同一次手势跨界时仍保留首次落下的 pane，不能中途更换坐标原点。
        val origins = mutableMapOf(down.id to origin)
        val downPosition = down.position - origin
        val image = photoImageRect(area, state.view.project(area))
        val initialSplit = state.split
        val handleX = image.splitX(initialSplit).coerceIn(image.left + minOf(24.dp.toPx(), image.width / 2), image.right - minOf(24.dp.toPx(), image.width / 2))
        val wipeHit = wipe && abs(downPosition.x - handleX) <= 24.dp.toPx() && downPosition.x in image.left..image.right && downPosition.y in image.top..image.bottom
        var targeting = target()
        if (wipeHit) { targeting?.cancel(); targeting = null }
        var targetStarted = false; var targetEnded = false
        if (targeting != null) {
            val point = targetHit(down.position)
            if (point != null) {
                targetStarted = true; targeting.begin(point.x, point.y); targetPointer(down.position, point)
                targetFocus(); down.consume()
            } else targeting.reject()
        }
        val targetScale = .5f / 1.dp.toPx()
        var transformed = false
        var dragging = false
        try {
            do {
                val event = awaitPointerEvent()
                val fingers = event.changes.count { it.pressed }
                event.changes.filter { it.pressed }.forEach { origins.getOrPut(it.id) { paneOrigin(it.position) } }
                if (fingers >= 2) {
                    if (targetStarted) { targeting?.cancel(); targetStarted = false; targetPointer(null, null) }
                    cancelHold(); transformed = true
                    val zoom = state.view.project(area)
                    val pointers = event.changes.filter { it.pressed && it.previousPressed }
                    val photoFocus = pointers.map { pointer ->
                        val point = pointer.previousPosition - origins.getValue(pointer.id)
                        Offset(.5f + (point.x - area.width / 2 - zoom.x) / (area.imageWidth * zoom.scale),
                            .5f + (point.y - area.height / 2 - zoom.y) / (area.imageHeight * zoom.scale))
                    }.fold(Offset.Zero) { total, point -> total + point } / pointers.size.coerceAtLeast(1).toFloat()
                    val focus = Offset(area.width / 2 + zoom.x + (photoFocus.x - .5f) * area.imageWidth * zoom.scale,
                        area.height / 2 + zoom.y + (photoFocus.y - .5f) * area.imageHeight * zoom.scale)
                    state.transform(event.calculateZoom(), event.calculatePan(), focus, area)
                    event.changes.forEach { if (it.positionChanged()) it.consume() }
                } else if (!transformed && fingers == 1) {
                    val change = event.changes.first { it.pressed }
                    dragging = dragging || (change.position - down.position).getDistance() > viewConfiguration.touchSlop
                    if (targeting != null) {
                        if (targetStarted) { targeting.move((down.position.y-change.position.y)*targetScale); targetPointer(change.position, null) }
                        change.consume()
                    } else if (dragging) {
                        cancelHold()
                        if (wipeHit) state.split = (initialSplit + (change.position.x - down.position.x) / image.width).coerceIn(0f, 1f)
                        else state.transform(1f, event.calculatePan(), change.previousPosition - origin, area)
                        change.consume()
                    }
                } else if (transformed) event.changes.forEach { it.consume() }
                if (fingers == 0 && targetStarted) {
                    event.changes.firstOrNull { it.id == down.id }?.let { targeting?.move((down.position.y-it.position.y)*targetScale) }
                    targeting?.end(); targetEnded = true
                }
            } while (event.changes.any { it.pressed })
        } finally {
            if (targetStarted && !targetEnded) targeting?.cancel()
            targetPointer(null, null); cancelHold()
        }
    }
}
