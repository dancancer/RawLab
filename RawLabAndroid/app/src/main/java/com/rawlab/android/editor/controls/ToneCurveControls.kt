package com.rawlab.android.editor.controls

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.key.*
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.rawlab.android.R
import com.rawlab.android.engine.ToneCurveSampling
import com.rawlab.android.settings.*

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun ToneCurveControls(settings: ToneCurveSettings, legacy: Float, enabled: Boolean,
    onEdit: (ToneCurveSettings, Boolean) -> Unit, onLegacyEdit: (Float, Boolean) -> Unit) {
    val scope = LocalAdjustmentSession.current
    var selected by remember(scope) { mutableIntStateOf(0) }
    var switching by remember(scope, settings.mode) { mutableStateOf(false) }
    val current by rememberUpdatedState(settings)
    val update by rememberUpdatedState(onEdit)
    val selectedIndex = selected.coerceIn(0, (settings.points.size - 1).coerceAtLeast(0))
    Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(stringResource(if (settings.isDefault) R.string.tone_curve else R.string.curve_custom),
                Modifier.heightIn(min = 48.dp).wrapContentHeight().testTag("curve-mode"), style = MaterialTheme.typography.titleSmall)
            TextButton(onClick = { switching = true }, enabled = enabled, modifier = Modifier.testTag("curve-switch")) {
                Text(stringResource(if (settings.isDefault) R.string.curve_custom else R.string.tone_curve))
            }
        }
        if (settings.isDefault) {
            NumericControl(R.string.tone_curve, legacy * 100, -100f..100f, "%", enabled,
                { value, dragging -> onLegacyEdit(value / 100, dragging) }, { onLegacyEdit(0f, false) })
        } else {
            @Composable fun rows(modifier: Modifier) {
                Column(modifier) {
                    LazyRow {
                        items(settings.points.size) { index ->
                            val label = stringResource(R.string.curve_point_number, index + 1)
                            TextButton(onClick = { selected = index }, enabled = enabled,
                                modifier = Modifier.testTag("curve-point-$index").semantics {
                                    contentDescription = label; this.selected = index == selectedIndex
                                }) { Text((index + 1).toString()) }
                        }
                    }
                    CompositionLocalProvider(LocalAdjustmentSession provides (scope to selectedIndex)) {
                        val point = settings.points[selectedIndex]
                        CurveCoordinate(R.string.curve_input, point.x, enabled && settings.isInterior(selectedIndex), "curve-x") { x ->
                            update(current.moving(selectedIndex, x, current.points[selectedIndex].y), false)
                        }
                        CurveCoordinate(R.string.curve_output, point.y, enabled && settings.isInterior(selectedIndex), "curve-y") { y ->
                            update(current.moving(selectedIndex, current.points[selectedIndex].x, y), false)
                        }
                    }
                    if (!settings.isInterior(selectedIndex)) Text(stringResource(R.string.curve_fixed_endpoint), style = MaterialTheme.typography.bodySmall)
                }
            }
            BoxWithConstraints(Modifier.fillMaxWidth()) {
                if (maxWidth >= 460.dp && LocalDensity.current.fontScale <= 1.3f) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        CurveCanvas(settings, selectedIndex, { selected = it }, enabled, Modifier.size(232.dp, 164.dp), onEdit)
                        rows(Modifier.weight(1f))
                    }
                } else Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    CurveCanvas(settings, selectedIndex, { selected = it }, enabled, Modifier.widthIn(max = 320.dp).fillMaxWidth().height(164.dp), onEdit)
                    rows(Modifier.fillMaxWidth())
                }
            }
            Text(stringResource(R.string.curve_hint), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            FlowRow(Modifier.fillMaxWidth()) {
                TextButton(onClick = {
                    val next = (1 until current.points.size).maxBy { current.points[it].x - current.points[it - 1].x }
                    val a = current.points[next - 1]; val b = current.points[next]
                    val value = current.inserting(a.x + (b.x - a.x) / 2, a.y + (b.y - a.y) / 2)
                    if (value != current) { selected = next; update(value, false) }
                }, enabled = enabled && settings.points.size < 33, modifier = Modifier.testTag("curve-add")) { Text(stringResource(R.string.curve_add_point)) }
                TextButton(onClick = { update(current.removing(selectedIndex), false) }, enabled = enabled && settings.isInterior(selectedIndex),
                    modifier = Modifier.testTag("curve-remove")) { Text(stringResource(R.string.curve_remove_point)) }
                TextButton(onClick = { selected = 0; update(ToneCurveSettings.identity, false) }, enabled = enabled && settings != ToneCurveSettings.identity,
                    modifier = Modifier.testTag("curve-reset")) { Text(stringResource(R.string.curve_reset_identity)) }
            }
        }
    }
    if (switching) AlertDialog(onDismissRequest = { switching = false }, title = { Text(stringResource(R.string.curve_switch_title)) },
        text = { Text(stringResource(if (settings.isDefault) R.string.curve_switch_custom else R.string.curve_switch_legacy)) },
        confirmButton = { TextButton(onClick = {
            switching = false; selected = 0
            update(if (current.isDefault) ToneCurveSettings.identity else ToneCurveSettings(), false)
        }, enabled = enabled, modifier = Modifier.testTag("curve-switch-confirm")) { Text(stringResource(R.string.curve_switch)) } },
        dismissButton = { TextButton(onClick = { switching = false }) { Text(stringResource(R.string.cancel)) } })
}

@Composable
private fun CurveCoordinate(label: Int, value: Double, enabled: Boolean, tag: String, onValue: (Double) -> Unit) {
    val scope = LocalAdjustmentSession.current
    val session = remember(scope, value, enabled) { Any() }
    val liveSession by rememberUpdatedState(session)
    val update by rememberUpdatedState(onValue)
    var editing by remember(session) { mutableStateOf(false) }
    var input by remember(session) { mutableStateOf("") }
    val locale = LocalConfiguration.current.locales[0]
    val formatted = formatAdjustmentNumber(value, locale)
    val parsed = parseAdjustmentNumber(input, locale)?.takeIf { it in 0.0..1.0 }?.let {
        if (it == parseAdjustmentNumber(formatted, locale)) value else it
    }
    val title = stringResource(label)
    FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(title, Modifier.heightIn(min = 48.dp).wrapContentHeight(), style = MaterialTheme.typography.labelMedium)
        TextButton(onClick = { input = formatted; editing = true }, enabled = enabled,
            modifier = Modifier.testTag(tag).semantics { contentDescription = title; stateDescription = formatted }) { Text(formatted) }
    }
    if (editing) AlertDialog(onDismissRequest = { editing = false }, title = { Text(title) },
        text = { OutlinedTextField(input, { input = it }, singleLine = true, isError = parsed == null,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal), modifier = Modifier.testTag("curve-coordinate-input"),
            supportingText = { if (parsed == null) Text(stringResource(R.string.invalid_value)) }) },
        confirmButton = { TextButton(onClick = {
            if (liveSession === session && parsed != null) { editing = false; if (parsed != value) update(parsed) }
        }, enabled = parsed != null, modifier = Modifier.testTag("curve-coordinate-apply")) { Text(stringResource(R.string.adjustment_apply)) } },
        dismissButton = { TextButton(onClick = { editing = false }) { Text(stringResource(R.string.cancel)) } })
}

@Composable
private fun CurveCanvas(value: ToneCurveSettings, selected: Int, onSelect: (Int) -> Unit, enabled: Boolean,
    modifier: Modifier, onEdit: (ToneCurveSettings, Boolean) -> Unit) {
    val scope = LocalAdjustmentSession.current
    val liveScope by rememberUpdatedState(scope)
    val current by rememberUpdatedState(value)
    val update by rememberUpdatedState(onEdit)
    val select by rememberUpdatedState(onSelect)
    val cancel = LocalAdjustmentCancellation.current
    val focus = LocalAdjustmentFocus.current
    val fine = LocalAdjustmentFine.current
    val windowFocused = LocalWindowInfo.current.isWindowFocused
    val requester = remember { FocusRequester() }
    var active by remember { mutableStateOf(false) }
    var cancellation by remember { mutableIntStateOf(0) }
    val samples = remember(value) { ToneCurveSampling.samples(value) }
    val title = stringResource(R.string.curve_title)
    val description = stringResource(R.string.curve_summary, value.points.size)
    val foreground = MaterialTheme.colorScheme.onSurface
    val primary = MaterialTheme.colorScheme.primary
    Canvas(modifier.testTag("curve-canvas").semantics {
        contentDescription = title; stateDescription = description
        if (!enabled) disabled()
    }.focusRequester(requester).onKeyEvent { event ->
        if (!enabled || event.type != KeyEventType.KeyDown) false
        else if (active && event.key == Key.Escape) { cancellation++; true }
        else if (active || !current.isInterior(selected)) false
        else {
            val point = current.points[selected]; val step = if (event.isShiftPressed || fine) .001 else .01
            val next = when (event.key) {
                Key.DirectionLeft -> current.moving(selected, point.x - step, point.y)
                Key.DirectionRight -> current.moving(selected, point.x + step, point.y)
                Key.DirectionUp -> current.moving(selected, point.x, point.y + step)
                Key.DirectionDown -> current.moving(selected, point.x, point.y - step)
                Key.Backspace, Key.Delete -> current.removing(selected)
                else -> null
            }
            if (next == null) false else { if (next != current) update(next, false); true }
        }
    }.focusable(enabled).pointerInput(scope, fine, enabled, windowFocused, cancellation) {
        if (!enabled || !windowFocused) return@pointerInput
        awaitEachGesture {
            val down = awaitFirstDown()
            val padding = 12.dp.toPx(); val width = (size.width - 2 * padding).coerceAtLeast(1f); val height = (size.height - 2 * padding).coerceAtLeast(1f)
            fun point(position: Offset) = ToneCurvePoint(((position.x - padding) / width).toDouble(), (1 - (position.y - padding) / height).toDouble())
            fun distance(p: ToneCurvePoint): Double {
                val dx = (p.x * width + padding - down.position.x); val dy = ((1 - p.y) * height + padding - down.position.y)
                return dx * dx + dy * dy
            }
            val start = current; val origin = point(down.position)
            val nearest = start.points.indices.minBy { distance(start.points[it]) }
            val hit = distance(start.points[nearest]) <= 20.dp.toPx() * 20.dp.toPx()
            val initial = if (hit) start else start.inserting(origin.x, origin.y)
            if (!hit && initial == start) return@awaitEachGesture
            val index = if (hit) nearest else initial.points.indexOfFirst { it.x == origin.x }
            select(index); requester.requestFocus()
            val updateAtStart = update; val cancelAtStart = cancel
            val handle = initial.points[index]; val scale = if (fine) .25 else 1.0
            fun moved(position: Offset): ToneCurveSettings {
                val p = point(position)
                return initial.moving(index, handle.x + (p.x - origin.x) * scale, handle.y + (p.y - origin.y) * scale)
            }
            var latest = initial; var changed = initial != start; var released = false
            active = true; focus(true)
            try {
                if (changed) updateAtStart(initial, true)
                var change = down
                do {
                    val next = moved(change.position)
                    if (next != latest) { changed = true; latest = next; updateAtStart(next, true) }
                    change.consume()
                    change = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: break
                    if (!change.pressed && !change.isConsumed) {
                        val final = moved(change.position)
                        if (final != latest) { changed = true; latest = final; updateAtStart(final, true) }
                        released = true; change.consume(); break
                    }
                } while (change.pressed && !change.isConsumed)
            } finally {
                active = false; focus(false)
                if (changed) {
                    if (released && liveScope == scope) updateAtStart(latest, false)
                    else cancelAtStart { if (liveScope == scope) updateAtStart(start, false) }
                }
            }
        }
    }) {
        val inset = 12.dp.toPx(); val width = size.width - 2 * inset; val height = size.height - 2 * inset
        fun point(p: ToneCurvePoint) = Offset(inset + p.x.toFloat() * width, inset + (1 - p.y.toFloat()) * height)
        for (i in 0..4) {
            val t = i / 4.0
            drawLine(foreground.copy(alpha = .15f), point(ToneCurvePoint(t, 0.0)), point(ToneCurvePoint(t, 1.0)))
            drawLine(foreground.copy(alpha = .15f), point(ToneCurvePoint(0.0, t)), point(ToneCurvePoint(1.0, t)))
        }
        drawLine(foreground.copy(alpha = .5f), point(ToneCurvePoint(0.0, 0.0)), point(ToneCurvePoint(1.0, 1.0)),
            pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 4.dp.toPx())))
        val path = Path(); samples.forEachIndexed { index, sample -> val p = point(sample); if (index == 0) path.moveTo(p.x, p.y) else path.lineTo(p.x, p.y) }
        drawPath(path, foreground, style = Stroke(2.dp.toPx()))
        value.points.forEachIndexed { index, p -> drawCircle(if (index == selected) primary else foreground,
            (if (index == selected) 6.dp else 4.dp).toPx(), point(p)) }
    }
}
