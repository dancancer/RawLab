package com.rawlab.android.editor.geometry

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
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
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import kotlin.math.min
import kotlin.math.abs
import com.rawlab.android.R
import com.rawlab.android.editor.render.PreviewPair
import com.rawlab.android.geometry.GeometryCropCorner
import com.rawlab.android.geometry.GeometryCropMath
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.geometry.moveCrop

@Composable
internal fun GeometryCropCanvas(pair: PreviewPair, value: GeometrySettings, enabled: Boolean,
    physicalAspect: Float? = null, showsGrid: Boolean = true, onChange: (GeometrySettings) -> Unit) {
    val current by rememberUpdatedState(value)
    val change by rememberUpdatedState(onChange)
    val description = stringResource(R.string.geometry_drag_hint)
    val labels = listOf(R.string.geometry_move_left, R.string.geometry_move_right, R.string.geometry_move_up,
        R.string.geometry_move_down).map { stringResource(it) }
    val inset = with(LocalDensity.current) { 24.dp.toPx() }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val scale = min((constraints.maxWidth - 2 * inset).coerceAtLeast(1f) / pair.comparisonWidth,
            (constraints.maxHeight - 2 * inset).coerceAtLeast(1f) / pair.comparisonHeight)
        val width = pair.comparisonWidth * scale
        val height = pair.comparisonHeight * scale
        val image = Rect((constraints.maxWidth - width) / 2f, (constraints.maxHeight - height) / 2f,
            (constraints.maxWidth + width) / 2f, (constraints.maxHeight + height) / 2f)
        Image(pair.result.asImageBitmap(), null, Modifier.fillMaxSize().padding(24.dp), contentScale = ContentScale.Fit)
        Canvas(Modifier.fillMaxSize().testTag("geometry.canvas").semantics {
            contentDescription = description
            stateDescription = "${(value.cropX * 100).toInt()}, ${(value.cropY * 100).toInt()} / ${(value.cropWidth * 100).toInt()} × ${(value.cropHeight * 100).toInt()}%"
            if (enabled) customActions = listOf(
                CustomAccessibilityAction(labels[0]) { change(current.moveCrop(-.02f, 0f)); true },
                CustomAccessibilityAction(labels[1]) { change(current.moveCrop(.02f, 0f)); true },
                CustomAccessibilityAction(labels[2]) { change(current.moveCrop(0f, -.02f)); true },
                CustomAccessibilityAction(labels[3]) { change(current.moveCrop(0f, .02f)); true })
        }.pointerInput(image, enabled, physicalAspect) {
            if (!enabled || width <= 0f || height <= 0f) return@pointerInput
            var baseline: GeometrySettings? = null
            var corner = -1
            var delta = Offset.Zero
            detectDragGestures(onDragStart = { point ->
                val crop = current.rect(image)
                val handles = listOf(crop.topLeft, crop.topRight, crop.bottomLeft, crop.bottomRight)
                // Tiny crops use numeric controls rather than overlapping handle hit regions.
                corner = if (crop.width >= 56.dp.toPx() && crop.height >= 56.dp.toPx())
                    handles.indices.minByOrNull { (handles[it] - point).getDistance() }
                        ?.takeIf { abs(point.x - handles[it].x) <= 24.dp.toPx() && abs(point.y - handles[it].y) <= 24.dp.toPx() } ?: -1 else -1
                baseline = current.takeIf { corner >= 0 || crop.contains(point) }
                delta = Offset.Zero
            }, onDrag = { pointer, movement ->
                val start = baseline ?: return@detectDragGestures
                pointer.consume()
                delta += movement
                val dx = delta.x / width
                val dy = delta.y / height
                if (corner < 0) change(start.moveCrop(dx, dy)) else {
                    change(GeometryCropMath.resize(start, GeometryCropCorner.entries[corner], dx, dy,
                        physicalAspect, pair.comparisonWidth / pair.comparisonHeight))
                }
            }, onDragEnd = { baseline = null }, onDragCancel = { baseline = null })
        }) {
            val crop = value.rect(image)
            val shade = Color.Black.copy(alpha = .56f)
            drawRect(shade, image.topLeft, Size(image.width, (crop.top - image.top).coerceAtLeast(0f)))
            drawRect(shade, Offset(image.left, crop.bottom), Size(image.width, (image.bottom - crop.bottom).coerceAtLeast(0f)))
            drawRect(shade, Offset(image.left, crop.top), Size((crop.left - image.left).coerceAtLeast(0f), crop.height))
            drawRect(shade, Offset(crop.right, crop.top), Size((image.right - crop.right).coerceAtLeast(0f), crop.height))
            drawRect(Color.White, crop.topLeft, crop.size, style = Stroke(1.5.dp.toPx()))
            if (showsGrid) for (step in 1..2) {
                val x = crop.left + crop.width * step / 3f
                val y = crop.top + crop.height * step / 3f
                drawLine(Color.White.copy(alpha = .6f), Offset(x, crop.top), Offset(x, crop.bottom), 1.dp.toPx())
                drawLine(Color.White.copy(alpha = .6f), Offset(crop.left, y), Offset(crop.right, y), 1.dp.toPx())
            }
            if (enabled && crop.width >= 56.dp.toPx() && crop.height >= 56.dp.toPx()) {
                for ((point, direction) in listOf(crop.topLeft to Offset(1f, 1f), crop.topRight to Offset(-1f, 1f),
                    crop.bottomLeft to Offset(1f, -1f), crop.bottomRight to Offset(-1f, -1f))) {
                    drawLine(Color.White, point, point + Offset(direction.x * 16.dp.toPx(), 0f), 3.dp.toPx())
                    drawLine(Color.White, point, point + Offset(0f, direction.y * 16.dp.toPx()), 3.dp.toPx())
                }
            }
        }
    }
}

private fun GeometrySettings.rect(image: Rect) = Rect(image.left + cropX * image.width, image.top + cropY * image.height,
    image.left + (cropX + cropWidth) * image.width, image.top + (cropY + cropHeight) * image.height)
