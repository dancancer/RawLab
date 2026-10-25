package com.rawlab.android.editor.controls

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.key.*
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import com.rawlab.android.R
import com.rawlab.android.editor.ui.gradingZoneTitle
import com.rawlab.android.settings.*

@Composable
internal fun ColorGradingControls(settings: ColorGradingSettings, enabled: Boolean, zone: ColorGradingZone,
    onZoneChange: (ColorGradingZone) -> Unit, onEdit: (ColorGradingSettings, Boolean) -> Unit) {
    val scope = LocalAdjustmentSession.current
    Column(Modifier.fillMaxWidth()) {
        LazyRow(Modifier.padding(horizontal = 8.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            items(ColorGradingZone.entries.size) { index ->
                val target = ColorGradingZone.entries[index]
                val status = stringResource(if (settings[target].isDefault) R.string.hsl_unadjusted else R.string.hsl_adjusted)
                TextButton(onClick = { onZoneChange(target) }, enabled = enabled,
                    modifier = Modifier.heightIn(min = 48.dp).testTag("grading-zone-${target.id}")
                        .semantics { selected = target == zone; stateDescription = status }) {
                    Text(stringResource(gradingZoneTitle(target)))
                    Spacer(Modifier.width(5.dp))
                    Box(Modifier.size(3.dp).background(if (settings[target].isDefault) Color.Transparent else MaterialTheme.colorScheme.primary, CircleShape))
                }
            }
        }
        CompositionLocalProvider(LocalAdjustmentSession provides (scope to zone)) {
            val value = settings[zone]
            val title = stringResource(R.string.color_grading) + " · " + stringResource(gradingZoneTitle(zone))
            @Composable fun rows(modifier: Modifier) {
                Column(modifier) {
                    NumericControl(R.string.hsl_hue, value.hue, 0f..360f, "°", enabled,
                        { hue, dragging -> ColorGradingWheel.inputHue(hue)?.let { onEdit(settings.with(zone, value.copy(hue = it)), dragging) } },
                        { onEdit(settings.with(zone, value.copy(hue = 0f)), false) }, compactNumber = true, stepOverride = .1f)
                    NumericControl(R.string.saturation, value.saturation, 0f..100f, "%", enabled,
                        { saturation, dragging -> onEdit(settings.with(zone, value.copy(saturation = saturation)), dragging) },
                        { onEdit(settings.with(zone, value.copy(saturation = 0f)), false) }, compactNumber = true, stepOverride = .1f)
                }
            }
            BoxWithConstraints(Modifier.fillMaxWidth().padding(horizontal = 12.dp)) {
                if (maxWidth >= 310.dp && LocalDensity.current.fontScale <= 1.3f) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        GradingWheel(value, enabled, title, Modifier.size(144.dp)) { next, dragging -> onEdit(settings.with(zone, next), dragging) }
                        rows(Modifier.weight(1f))
                    }
                } else Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    GradingWheel(value, enabled, title, Modifier.size(156.dp)) { next, dragging -> onEdit(settings.with(zone, next), dragging) }
                    rows(Modifier.fillMaxWidth())
                }
            }
        }
    }
}

@Composable
private fun GradingWheel(value: ColorGradingWheel, enabled: Boolean, title: String, modifier: Modifier,
    onEdit: (ColorGradingWheel, Boolean) -> Unit) {
    val scope = LocalAdjustmentSession.current
    val liveScope by rememberUpdatedState(scope)
    val current by rememberUpdatedState(value)
    val update by rememberUpdatedState(onEdit)
    val cancel = LocalAdjustmentCancellation.current
    val focus = LocalAdjustmentFocus.current
    val fine = LocalAdjustmentFine.current
    val windowFocused = LocalWindowInfo.current.isWindowFocused
    var pointerActive by remember { mutableStateOf(false) }
    var keyboardCancellation by remember { mutableIntStateOf(0) }
    val hueLabel = stringResource(R.string.hsl_hue)
    val saturationLabel = stringResource(R.string.saturation)
    val colors = remember { (0..12).map { Color.hsv(it * 30f, 1f, .9f) } }
    Canvas(modifier.testTag("grading-wheel").semantics {
        contentDescription = title
        stateDescription = "$hueLabel ${formatAdjustment(value.hue, .1f)}°, $saturationLabel ${formatAdjustment(value.saturation, .1f)}%"
        progressBarRangeInfo = ProgressBarRangeInfo(value.saturation, 0f..100f)
        if (enabled) setProgress { next ->
            if (!next.isFinite()) false else {
                val bounded = next.coerceIn(0f, 100f)
                if (bounded != current.saturation) update(current.copy(saturation = bounded), false)
                true
            }
        } else disabled()
    }.onKeyEvent { event ->
        if (!enabled || event.type != KeyEventType.KeyDown) false
        else if (pointerActive && event.key == Key.Escape) { keyboardCancellation++; true }
        else if (pointerActive) event.key in listOf(Key.DirectionLeft, Key.DirectionRight, Key.DirectionUp, Key.DirectionDown)
        else {
            val step = if (event.isShiftPressed || fine) .1f else 1f
            val next = when (event.key) {
                Key.DirectionLeft -> current.copy(hue = ColorGradingWheel.inputHue((current.hue - step + 360f) % 360f)!!)
                Key.DirectionRight -> current.copy(hue = (current.hue + step) % 360f)
                Key.DirectionUp -> current.copy(saturation = (current.saturation + step).coerceAtMost(100f))
                Key.DirectionDown -> current.copy(saturation = (current.saturation - step).coerceAtLeast(0f))
                else -> null
            }
            if (next == null) false else { if (next != current) update(next, false); true }
        }
    }.focusable(enabled).pointerInput(scope, fine, enabled, windowFocused, keyboardCancellation) {
        if (!enabled || !windowFocused) return@pointerInput
        awaitEachGesture {
            val down = awaitFirstDown()
            val radius = ((minOf(size.width, size.height) - 20.dp.toPx()) / 2).coerceAtLeast(1f)
            fun point(position: Offset) = (position.x - size.width / 2f) / radius to (position.y - size.height / 2f) / radius
            val origin = point(down.position)
            val start = current
            val drag = ColorGradingDrag(start, origin.first, origin.second, fine)
            val updateAtStart = update
            val cancelAtStart = cancel
            var latest = start
            var changed = false
            var released = false
            pointerActive = true
            focus(true)
            try {
                var change = down
                do {
                    val p = point(change.position)
                    val next = drag.value(p.first, p.second)
                    if (next != latest) { changed = true; latest = next; updateAtStart(next, true) }
                    change.consume()
                    val event = awaitPointerEvent()
                    change = event.changes.firstOrNull { it.id == down.id } ?: break
                    if (!change.pressed && !change.isConsumed) {
                        val end = point(change.position)
                        val final = drag.value(end.first, end.second)
                        if (final != latest) { changed = true; latest = final; updateAtStart(final, true) }
                        released = true; change.consume(); break
                    }
                } while (change.pressed && !change.isConsumed)
            } finally {
                pointerActive = false
                focus(false)
                if (changed) {
                    if (released && liveScope == scope) updateAtStart(latest, false)
                    else cancelAtStart { if (liveScope == scope) updateAtStart(start, false) }
                }
            }
        }
    }) {
        val radius = (size.minDimension - 20.dp.toPx()) / 2
        val alpha = if (enabled) 1f else .4f
        drawCircle(Brush.sweepGradient(colors, center), radius, alpha = alpha)
        drawCircle(Brush.radialGradient(listOf(Color.Gray, Color.Transparent), center, radius), radius, alpha = alpha)
        drawCircle(Color.Black.copy(alpha = .25f), radius, style = Stroke(1.dp.toPx()))
        val point = value.point
        val handle = center + Offset(point.first, point.second) * radius
        drawCircle(Color.Black, 8.dp.toPx(), handle, alpha = alpha, style = Stroke(4.dp.toPx()))
        drawCircle(Color.White, 8.dp.toPx(), handle, alpha = alpha, style = Stroke(2.dp.toPx()))
    }
}
