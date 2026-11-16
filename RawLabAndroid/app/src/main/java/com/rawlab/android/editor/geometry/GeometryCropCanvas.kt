package com.rawlab.android.editor.geometry

import android.graphics.Bitmap
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.ClipOp
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.min
import kotlin.math.abs
import com.rawlab.android.R
import com.rawlab.android.editor.render.PreviewPair
import com.rawlab.android.editor.render.uncroppedGeometrySize
import com.rawlab.android.geometry.GeometryCropCorner
import com.rawlab.android.geometry.GeometryCropMath
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.geometry.moveCrop
import com.rawlab.android.geometry.uncropped

@Composable
internal fun GeometryCropCanvas(pair: PreviewPair, value: GeometrySettings, editing: Boolean, enabled: Boolean,
    photoMargin: Dp, bitmap: Bitmap, physicalAspect: Float? = null, showsGrid: Boolean = true,
    onChange: (GeometrySettings) -> Unit) {
    val current by rememberUpdatedState(value)
    val change by rememberUpdatedState(onChange)
    val description = stringResource(R.string.geometry_drag_hint)
    val labels = listOf(R.string.geometry_move_left, R.string.geometry_move_right, R.string.geometry_move_up,
        R.string.geometry_move_down).map { stringResource(it) }
    val inset = with(LocalDensity.current) { 24.dp.toPx() }
    val paint = remember { Paint(Paint.FILTER_BITMAP_FLAG) }
    val geometry = value.uncropped()
    val projection = remember(pair.nativeWidth, pair.nativeHeight, geometry) { GeometryProjection(pair, geometry) }
    BoxWithConstraints(Modifier.fillMaxSize().padding(if (editing) 0.dp else photoMargin).clipToBounds()) {
        val viewport = Size(constraints.maxWidth.toFloat(), constraints.maxHeight.toFloat())
        val layout = projection.fit(viewport, if (editing) inset else 0f, value, editing)
        val image = layout.safeBounds
        val width = image.width
        val height = image.height
        val cropInput = if (editing) Modifier.testTag("geometry.canvas").semantics {
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
                        physicalAspect, width / height))
                }
            }, onDragEnd = { baseline = null }, onDragCancel = { baseline = null })
        } else Modifier
        Canvas(Modifier.fillMaxSize().then(cropInput)) {
            val crop = value.rect(image)
            if (!editing) {
                clipRect(crop.left, crop.top, crop.right, crop.bottom) {
                    drawProjectedPhoto(bitmap, layout, paint)
                }
                return@Canvas
            }
            drawProjectedPhoto(bitmap, layout, paint)
            clipRect(crop.left, crop.top, crop.right, crop.bottom, ClipOp.Difference) {
                drawPath(layout.outline, Color.Black.copy(alpha = .56f))
            }
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

private class GeometryProjection(pair: PreviewPair, geometry: GeometrySettings) {
    private val source = RectF(0f, 0f, pair.nativeWidth.toFloat(), pair.nativeHeight.toFloat())
    private val centered = Matrix().apply {
        val swapAxes = geometry.quarterTurns % 2 != 0
        val width = if (swapAxes) source.height() else source.width()
        val height = if (swapAxes) source.width() else source.height()
        setTranslate(-source.centerX(), -source.centerY())
        postRotate(geometry.quarterTurns * 90f)
        postScale(if (geometry.flipHorizontal) -1f else 1f, if (geometry.flipVertical) -1f else 1f)
        // 正向投影与共享核心的逆采样对应，透视轴取旋转、翻转后的画布。
        postConcat(Matrix().apply {
            setValues(floatArrayOf(1f, 0f, 0f, 0f, 1f, 0f,
                -.5f * geometry.perspectiveHorizontal / width, -.5f * geometry.perspectiveVertical / height, 1f))
        })
        postRotate(geometry.straightenDegrees)
    }
    private val bounds = RectF(source).also { centered.mapRect(it) }
    private val safe = pair.uncroppedGeometrySize(geometry).let { (width, height) ->
        Rect(-width / 2f, -height / 2f, width / 2f, height / 2f)
    }

    fun fit(viewport: Size, margin: Float, value: GeometrySettings, editing: Boolean): GeometryLayout {
        val fitted = if (editing) Rect(bounds.left, bounds.top, bounds.right, bounds.bottom) else value.rect(safe)
        val scale = min((viewport.width - 2 * margin).coerceAtLeast(1f) / fitted.width,
            (viewport.height - 2 * margin).coerceAtLeast(1f) / fitted.height)
        val x = viewport.width / 2f - fitted.center.x * scale
        val y = viewport.height / 2f - fitted.center.y * scale
        val matrix = Matrix(centered).apply { postScale(scale, scale); postTranslate(x, y) }
        val corners = floatArrayOf(0f, 0f, source.right, 0f, source.right, source.bottom, 0f, source.bottom)
        matrix.mapPoints(corners)
        val outline = Path().apply {
            moveTo(corners[0], corners[1])
            for (i in 2..6 step 2) lineTo(corners[i], corners[i + 1])
            close()
        }
        return GeometryLayout(source, matrix, outline,
            Rect(safe.left * scale + x, safe.top * scale + y, safe.right * scale + x, safe.bottom * scale + y))
    }
}

private data class GeometryLayout(val source: RectF, val matrix: Matrix, val outline: Path, val safeBounds: Rect)

private fun DrawScope.drawProjectedPhoto(bitmap: Bitmap, layout: GeometryLayout, paint: Paint) = drawIntoCanvas { canvas ->
    val native = canvas.nativeCanvas
    val saved = native.save()
    native.concat(layout.matrix)
    native.drawBitmap(bitmap, null, layout.source, paint)
    native.restoreToCount(saved)
}

private fun GeometrySettings.rect(image: Rect) = Rect(image.left + cropX * image.width, image.top + cropY * image.height,
    image.left + (cropX + cropWidth) * image.width, image.top + (cropY + cropHeight) * image.height)
