package com.rawlab.android

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
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
import androidx.compose.ui.input.pointer.PointerInputScope
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import kotlin.math.max
import kotlin.math.roundToInt

class PhotoCanvasState {
    var viewport by mutableStateOf<PhotoViewport?>(null)
    var zoom by mutableStateOf<PhotoZoom?>(null)
    var split by mutableFloatStateOf(.5f)

    fun resize(next: PhotoViewport) {
        zoom = zoom?.resize(viewport ?: next, next) ?: PhotoZoom(next.fitScale)
        viewport = next
    }

    fun transform(factor: Float, pan: Offset, focus: Offset) {
        val area = viewport ?: return
        zoom = zoom?.transform(area, factor, pan.x, pan.y, focus.x, focus.y)
    }

    fun doubleTap(point: Offset) {
        val area = viewport ?: return
        zoom = zoom?.doubleTap(area, point.x, point.y)
    }

    companion object {
        val Saver = listSaver<PhotoCanvasState, Float>(save = {
            val area = it.viewport
            val zoom = it.zoom
            if (area == null || zoom == null) listOf(it.split)
            else listOf(it.split, area.imageWidth, area.imageHeight, area.width, area.height, zoom.scale, zoom.x, zoom.y)
        }, restore = { saved ->
            PhotoCanvasState().apply {
                split = saved[0]
                if (saved.size == 8) {
                    viewport = PhotoViewport(saved[1], saved[2], saved[3], saved[4])
                    zoom = PhotoZoom(saved[5], saved[6], saved[7])
                }
            }
        })
    }
}

@Composable
internal fun PhotoCanvas(
    pair: PreviewPair,
    compare: Boolean,
    filename: String,
    state: PhotoCanvasState,
    info: PhotoInfo? = null,
    infoMode: Int = 0,
    onInfoClick: () -> Unit = {},
) {
    val wipeDescription = stringResource(R.string.comparison_wipe)
    val fitDescription = stringResource(R.string.zoom_fit)
    BoxWithConstraints(Modifier.fillMaxSize().padding(horizontal = 8.dp).clipToBounds()) {
        if (constraints.maxWidth == 0 || constraints.maxHeight == 0) return@BoxWithConstraints
        // Keep exact-preview geometry while a smaller interactive preview is displayed.
        val viewport = PhotoViewport(max(pair.result.width.toFloat(), state.viewport?.imageWidth ?: 0f),
            max(pair.result.height.toFloat(), state.viewport?.imageHeight ?: 0f),
            constraints.maxWidth.toFloat(), constraints.maxHeight.toFloat())
        val zoom = state.zoom?.resize(state.viewport ?: viewport, viewport) ?: PhotoZoom(viewport.fitScale)
        SideEffect { if (state.viewport != viewport) state.resize(viewport) }
        val transform = Modifier.fillMaxSize().graphicsLayer {
            scaleX = zoom.scale / viewport.fitScale
            scaleY = zoom.scale / viewport.fitScale
            translationX = zoom.x
            translationY = zoom.y
        }
        val percent = "${(zoom.scale * 100).roundToInt()}%"
        Box(Modifier.fillMaxSize().testTag("photo-canvas").semantics {
            contentDescription = filename
            stateDescription = if (viewport.isFit(zoom.scale)) "$fitDescription $percent" else percent
            customActions = listOf(
                CustomAccessibilityAction("100%") { state.zoom = PhotoZoom(1f); true },
                CustomAccessibilityAction(fitDescription) { state.zoom = PhotoZoom(viewport.fitScale); true }
            )
        }.pointerInput(state) { detectTapGestures(onDoubleTap = state::doubleTap) }
            .pointerInput(state, compare) { photoGestures(state, compare) }) {
            Image(pair.result.asImageBitmap(), null, transform, contentScale = ContentScale.Fit)
            if (compare) {
                Box(Modifier.fillMaxSize().testTag("comparison-wipe").semantics {
                    contentDescription = wipeDescription
                    stateDescription = "${(state.split * 100).roundToInt()}%"
                    progressBarRangeInfo = ProgressBarRangeInfo(state.split, 0f..1f)
                    setProgress { state.split = it.coerceIn(0f, 1f); true }
                }.drawWithContent {
                    clipRect(right = size.width * state.split) { this@drawWithContent.drawContent() }
                    drawLine(Color.White, Offset(size.width * state.split, 0f), Offset(size.width * state.split, size.height), 1.dp.toPx())
                }) {
                    Image(pair.neutral.asImageBitmap(), null, transform, contentScale = ContentScale.Fit)
                }
                Icon(Icons.Outlined.SwapHoriz, null, Modifier.align(Alignment.CenterStart)
                    .offset { IntOffset((viewport.width * state.split - 16.dp.toPx()).roundToInt(), 0) }
                    .size(32.dp).background(Color.White, CircleShape).padding(5.dp), tint = Color.Black)
                Row(Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(8.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                    for (label in listOf(R.string.neutral, R.string.result)) Text(stringResource(label),
                        Modifier.background(Color.Black.copy(alpha = .65f)).padding(6.dp),
                        color = Color.White, style = MaterialTheme.typography.labelSmall)
                }
            }
            PhotoInfoOverlay(info, infoMode, onInfoClick)
        }
    }
}

@Composable
private fun PhotoInfoOverlay(info: PhotoInfo?, mode: Int, onInfoClick: () -> Unit) {
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
        Icon(Icons.Outlined.Info, modeDescription, tint = Color.White)
    }
    if (mode != 0 && info != null) {
        Column(
            Modifier.padding(start = 60.dp, top = 12.dp).widthIn(max = 360.dp)
                .background(Color.Black.copy(alpha = .72f))
                .padding(horizontal = 10.dp, vertical = 8.dp)
                .testTag("photo-info-panel"),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            if (mode == 1) {
                InfoLine(stringResource(R.string.info_filename), info.fileName)
                info.captureTime?.let { InfoLine(stringResource(R.string.info_capture_time), it) }
                info.orientationCorrection?.let { InfoLine(stringResource(R.string.info_orientation), it) }
                if (info.originalWidth != null && info.originalHeight != null) {
                    InfoLine(stringResource(R.string.info_original_dimensions), "${info.originalWidth} × ${info.originalHeight}")
                }
            } else {
                InfoLine(stringResource(R.string.info_filename), info.fileName)
                val hasCaptureParameters = info.camera != null || info.lens != null || info.shutter != null ||
                    info.aperture != null || info.iso != null || info.focalLength != null
                if (!hasCaptureParameters) {
                    Text(stringResource(R.string.info_capture_missing), color = Color.White, style = MaterialTheme.typography.labelSmall)
                }
                info.camera?.let { InfoLine(stringResource(R.string.info_camera), it) }
                info.lens?.let { InfoLine(stringResource(R.string.info_lens), it) }
                info.shutter?.let { InfoLine(stringResource(R.string.info_shutter), it) }
                info.aperture?.let { InfoLine(stringResource(R.string.info_aperture), "f/$it") }
                info.iso?.let { InfoLine(stringResource(R.string.info_iso), it) }
                info.focalLength?.let { InfoLine(stringResource(R.string.info_focal_length), it) }
            }
        }
    }
}

@Composable
private fun InfoLine(title: String, value: String) {
    Text(
        "$title  $value",
        color = Color.White,
        style = MaterialTheme.typography.labelSmall,
        modifier = Modifier.fillMaxWidth(),
    )
}

private suspend fun PointerInputScope.photoGestures(state: PhotoCanvasState, compare: Boolean) {
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false)
        var transformed = false
        var dragging = false
        do {
            val event = awaitPointerEvent()
            val fingers = event.changes.count { it.pressed }
            if (fingers >= 2) {
                transformed = true
                state.transform(event.calculateZoom(), event.calculatePan(), event.calculateCentroid(useCurrent = false))
                event.changes.forEach { if (it.positionChanged()) it.consume() }
            } else if (!transformed && fingers == 1) {
                val change = event.changes.first { it.pressed }
                dragging = dragging || (change.position - down.position).getDistance() > viewConfiguration.touchSlop
                if (dragging) {
                    if (compare) state.split = (change.position.x / size.width).coerceIn(0f, 1f)
                    else state.transform(1f, event.calculatePan(), change.previousPosition)
                    change.consume()
                }
            } else if (transformed) {
                // Do not turn a pinch into a wipe when the first finger is lifted.
                event.changes.forEach { it.consume() }
            }
        } while (event.changes.any { it.pressed })
    }
}
