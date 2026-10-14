package com.rawlab.android

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import java.util.Locale
import kotlin.math.min

/** The only gestures while editing geometry are crop handles and moving the crop. */
@Composable
internal fun GeometryCropCanvas(pair: PreviewPair, value: GeometrySettings, physicalAspect: Float?,
    grid: Boolean, enabled: Boolean, onChange: (GeometrySettings, Boolean) -> Unit) {
    val current by rememberUpdatedState(value)
    val change by rememberUpdatedState(onChange)
    val description = stringResource(R.string.geometry_drag_hint)
    val moveLabels = listOf(R.string.geometry_move_left, R.string.geometry_move_right,
        R.string.geometry_move_up, R.string.geometry_move_down).map { stringResource(it) }
    val bounds = String.format(Locale.ROOT, "%.1f%%, %.1f%% · %.1f%% × %.1f%%",
        value.cropX * 100f, value.cropY * 100f, value.cropWidth * 100f, value.cropHeight * 100f)
    BoxWithConstraints(Modifier.fillMaxSize().clipToBounds()) {
        if (constraints.maxWidth <= 0 || constraints.maxHeight <= 0) return@BoxWithConstraints
        val canvasAspect = pair.canvasWidth.toFloat() / pair.canvasHeight
        val inset = with(LocalDensity.current) { 24.dp.toPx() }
        val availableWidth = (constraints.maxWidth - 2f * inset).coerceAtLeast(1f)
        val availableHeight = (constraints.maxHeight - 2f * inset).coerceAtLeast(1f)
        val scale = min(availableWidth / pair.canvasWidth, availableHeight / pair.canvasHeight)
        val width = pair.canvasWidth * scale
        val height = pair.canvasHeight * scale
        val image = Rect((constraints.maxWidth - width) / 2f, (constraints.maxHeight - height) / 2f,
            (constraints.maxWidth + width) / 2f, (constraints.maxHeight + height) / 2f)
        Image(pair.result.asImageBitmap(), null, Modifier.fillMaxSize().padding(24.dp), contentScale = ContentScale.Fit)
        Canvas(Modifier.fillMaxSize().testTag("geometry.canvas").semantics {
            contentDescription = description
            stateDescription = bounds
            if (enabled) customActions = listOf(
                CustomAccessibilityAction(moveLabels[0]) { change(GeometryCropMath.move(current, -.02f, 0f), false); true },
                CustomAccessibilityAction(moveLabels[1]) { change(GeometryCropMath.move(current, .02f, 0f), false); true },
                CustomAccessibilityAction(moveLabels[2]) { change(GeometryCropMath.move(current, 0f, -.02f), false); true },
                CustomAccessibilityAction(moveLabels[3]) { change(GeometryCropMath.move(current, 0f, .02f), false); true })
        }.pointerInput(image, physicalAspect, enabled) {
            if (!enabled) return@pointerInput
            var baseline: GeometrySettings? = null
            var corner: GeometryCropCorner? = null
            var delta = Offset.Zero
            detectDragGestures(onDragStart = { point ->
                val crop = current.cropRect(image)
                val handles = listOf(GeometryCropCorner.TOP_LEFT to crop.topLeft,
                    GeometryCropCorner.TOP_RIGHT to crop.topRight, GeometryCropCorner.BOTTOM_LEFT to crop.bottomLeft,
                    GeometryCropCorner.BOTTOM_RIGHT to crop.bottomRight)
                corner = handles.minByOrNull { (it.second - point).getDistance() }
                    ?.takeIf { (it.second - point).getDistance() <= 24.dp.toPx() }?.first
                baseline = current.takeIf { corner != null || crop.contains(point) }
                delta = Offset.Zero
            }, onDrag = { pointer, amount ->
                val start = baseline ?: return@detectDragGestures
                pointer.consume()
                delta += amount
                val next = corner?.let { GeometryCropMath.resize(start, it, delta.x / image.width,
                    delta.y / image.height, physicalAspect, canvasAspect) }
                    ?: GeometryCropMath.move(start, delta.x / image.width, delta.y / image.height)
                change(next, true)
            }, onDragEnd = {
                baseline = null
                corner = null
                delta = Offset.Zero
            }, onDragCancel = {
                baseline = null
                corner = null
                delta = Offset.Zero
            })
        }) {
            val crop = value.cropRect(image)
            val shade = Color.Black.copy(alpha = .56f)
            drawRect(shade, image.topLeft, Size(image.width, crop.top - image.top))
            drawRect(shade, Offset(image.left, crop.bottom), Size(image.width, image.bottom - crop.bottom))
            drawRect(shade, Offset(image.left, crop.top), Size(crop.left - image.left, crop.height))
            drawRect(shade, Offset(crop.right, crop.top), Size(image.right - crop.right, crop.height))
            drawRect(Color.White, crop.topLeft, crop.size, style = Stroke(1.5.dp.toPx()))
            if (grid) for (step in 1..2) {
                val x = crop.left + crop.width * step / 3f
                val y = crop.top + crop.height * step / 3f
                drawLine(Color.White.copy(alpha = .65f), Offset(x, crop.top), Offset(x, crop.bottom), 1.dp.toPx())
                drawLine(Color.White.copy(alpha = .65f), Offset(crop.left, y), Offset(crop.right, y), 1.dp.toPx())
            }
            if (enabled) for ((point, direction) in listOf(crop.topLeft to Offset(1f, 1f), crop.topRight to Offset(-1f, 1f),
                crop.bottomLeft to Offset(1f, -1f), crop.bottomRight to Offset(-1f, -1f))) {
                val length = min(18.dp.toPx(), min(crop.width, crop.height) / 3f)
                drawLine(Color.White, point, point + Offset(direction.x * length, 0f), 3.dp.toPx())
                drawLine(Color.White, point, point + Offset(0f, direction.y * length), 3.dp.toPx())
            }
        }
    }
}

private fun GeometrySettings.cropRect(image: Rect) = Rect(image.left + cropX * image.width,
    image.top + cropY * image.height, image.left + (cropX + cropWidth) * image.width,
    image.top + (cropY + cropHeight) * image.height)
