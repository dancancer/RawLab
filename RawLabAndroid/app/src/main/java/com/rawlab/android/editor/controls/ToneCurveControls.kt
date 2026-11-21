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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ToneCurveControls(settings: ToneCurveSettings, legacy: Float, enabled: Boolean,
    onEdit: (ToneCurveSettings, Boolean) -> Unit, onLegacyEdit: (Float, Boolean) -> Unit,
    usesExposureStops: Boolean = false) {
    val scope = LocalAdjustmentSession.current
    var channel by remember(scope) { mutableStateOf(ToneCurveChannel.RGB) }
    var selected by remember(scope, channel) { mutableIntStateOf(0) }
    var editing by remember(scope, channel) { mutableStateOf(false) }
    var switching by remember(scope, channel) { mutableStateOf(false) }
    var legacyEditing by remember(scope, channel) { mutableStateOf(false) }
    val root by rememberUpdatedState(settings)
    val shape = settings.shape(channel)
    val curve = if (shape.mode == ToneCurveMode.LEGACY) ToneCurveSettings.identity else ToneCurveSettings(shape.mode, shape.points)
    val current by rememberUpdatedState(curve)
    val index = selected.coerceIn(0, curve.points.lastIndex)
    val owner = channel
    val update: (ToneCurveSettings, Boolean) -> Unit = { next, dragging ->
        if (channel == owner) onEdit(root.replacing(owner, next.master), dragging)
    }
    val legacyActive = channel == ToneCurveChannel.RGB && shape.mode == ToneCurveMode.LEGACY && legacy != 0f
    val labels = listOf("RGB", stringResource(R.string.hsl_red), stringResource(R.string.hsl_green), stringResource(R.string.hsl_blue))
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        Row(Modifier.fillMaxWidth()) {
            ToneCurveChannel.entries.forEachIndexed { position, item ->
                TextButton(onClick = { channel = item }, modifier = Modifier.weight(1f).heightIn(min = 48.dp)
                    .testTag("curve-channel-${item.name.lowercase()}").semantics { this.selected = item == channel }) {
                    Text(labels[position], color = if (item == channel) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        CompositionLocalProvider(LocalAdjustmentSession provides (scope to channel)) {
            if (legacyActive) {
                Column(Modifier.height(194.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(stringResource(R.string.tone_curve))
                    Text(formatAdjustmentNumber(legacy * 100.0, LocalConfiguration.current.locales[0]) + "%")
                    TextButton(onClick = { switching = true }, enabled = enabled, modifier = Modifier.testTag("curve-switch")) {
                        Text(stringResource(R.string.curve_custom))
                    }
                }
            } else {
                CurveCanvas(curve, index, { selected = it }, enabled, Modifier.size(194.dp), update)
                if (usesExposureStops) Row(Modifier.width(170.dp).testTag("curve-hdr-ev-axis"), horizontalArrangement = Arrangement.SpaceBetween) {
                    for (value in listOf("−8 EV", "0 EV", "+8 EV")) Text(value, style = MaterialTheme.typography.labelSmall)
                }
            }
        }
        Row(Modifier.fillMaxWidth().padding(horizontal = 18.dp), verticalAlignment = Alignment.CenterVertically) {
            fun coordinate(value: Double) = if (usesExposureStops) formatAdjustmentNumber(value * 16 - 8, java.util.Locale.getDefault())
                else (value * 255).toInt().toString()
            val point = curve.points[index]
            Text("${stringResource(R.string.curve_input)} ${coordinate(point.x)} · ${stringResource(R.string.curve_output)} ${coordinate(point.y)}",
                Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            TextButton(onClick = { editing = true }, modifier = Modifier.testTag("curve-edit-point")) { Text(stringResource(R.string.curve_edit_point)) }
        }
    }
    if (editing) ModalBottomSheet(onDismissRequest = { editing = false }) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(R.string.curve_edit_point), style = MaterialTheme.typography.titleMedium)
            LazyRow {
                items(curve.points.size) { position ->
                    TextButton(onClick = { selected = position }, enabled = enabled,
                        modifier = Modifier.testTag("curve-point-$position").semantics { this.selected = position == index }) {
                        Text((position + 1).toString())
                    }
                }
            }
            CompositionLocalProvider(LocalAdjustmentSession provides Triple(scope, channel, index)) {
                val point = curve.points[index]
                CurveCoordinate(R.string.curve_input, point.x, enabled && curve.isInterior(index), "curve-x", usesExposureStops) { x ->
                    update(current.moving(index, x, current.points[index].y), false)
                }
                CurveCoordinate(R.string.curve_output, point.y, enabled && curve.isInterior(index), "curve-y", usesExposureStops) { y ->
                    update(current.moving(index, current.points[index].x, y), false)
                }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                TextButton(onClick = {
                    val position = (1 until current.points.size).maxBy { current.points[it].x - current.points[it - 1].x }
                    val a = current.points[position - 1]; val b = current.points[position]
                    selected = position; update(current.inserting((a.x + b.x) / 2, (a.y + b.y) / 2), false)
                }, enabled = enabled && curve.points.size < 33, modifier = Modifier.testTag("curve-add")) { Text(stringResource(R.string.curve_add_point)) }
                TextButton(onClick = { update(current.removing(index), false) }, enabled = enabled && curve.isInterior(index),
                    modifier = Modifier.testTag("curve-remove")) { Text(stringResource(R.string.curve_remove_point)) }
            }
            TextButton(onClick = { selected = 0; update(ToneCurveSettings.identity, false) }, enabled = enabled,
                modifier = Modifier.testTag("curve-reset")) { Text(stringResource(R.string.curve_reset_identity)) }
            if (channel == ToneCurveChannel.RGB) {
                TextButton(onClick = { switching = true }, enabled = enabled, modifier = Modifier.testTag("curve-switch")) {
                    Text(stringResource(if (shape.mode == ToneCurveMode.LEGACY) R.string.curve_custom else R.string.tone_curve))
                }
                if (shape.mode == ToneCurveMode.LEGACY) TextButton(onClick = { legacyEditing = !legacyEditing },
                    modifier = Modifier.testTag("curve-legacy-editor")) { Text(stringResource(R.string.tone_curve)) }
                if (legacyEditing && shape.mode == ToneCurveMode.LEGACY) NumericControl(R.string.tone_curve, legacy * 100, -100f..100f, "%", enabled,
                    { value, dragging -> onLegacyEdit(value / 100, dragging) }, { onLegacyEdit(0f, false) })
            }
        }
    }
    if (switching) AlertDialog(onDismissRequest = { switching = false }, title = { Text(stringResource(R.string.curve_switch_title)) },
        text = { Text(stringResource(if (shape.mode == ToneCurveMode.LEGACY) R.string.curve_switch_custom else R.string.curve_switch_legacy)) },
        confirmButton = { TextButton(onClick = {
            switching = false; selected = 0
            legacyEditing = shape.mode != ToneCurveMode.LEGACY
            update(if (shape.mode == ToneCurveMode.LEGACY) ToneCurveSettings.identity else ToneCurveSettings(), false)
        }, enabled = enabled, modifier = Modifier.testTag("curve-switch-confirm")) { Text(stringResource(R.string.curve_switch)) } },
        dismissButton = { TextButton(onClick = { switching = false }) { Text(stringResource(R.string.cancel)) } })
}

@Composable
private fun CurveCoordinate(label: Int, value: Double, enabled: Boolean, tag: String, usesExposureStops: Boolean, onValue: (Double) -> Unit) {
    val scope = LocalAdjustmentSession.current
    val session = remember(scope, value, enabled) { Any() }
    val liveSession by rememberUpdatedState(session)
    val update by rememberUpdatedState(onValue)
    var editing by remember(session) { mutableStateOf(false) }
    var input by remember(session) { mutableStateOf("") }
    val locale = LocalConfiguration.current.locales[0]
    val formatted = formatAdjustmentNumber(if (usesExposureStops) value * 16 - 8 else value, locale)
    val range = if (usesExposureStops) -8.0..8.0 else 0.0..1.0
    val parsed = parseAdjustmentNumber(input, locale)?.takeIf { it in range }?.let {
        if (it == parseAdjustmentNumber(formatted, locale)) value else if (usesExposureStops) (it + 8) / 16 else it
    }
    val title = stringResource(label)
    val displayed = if (usesExposureStops) "$formatted EV" else formatted
    FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(title, Modifier.heightIn(min = 48.dp).wrapContentHeight(), style = MaterialTheme.typography.labelMedium)
        TextButton(onClick = { input = formatted; editing = true }, enabled = enabled,
            modifier = Modifier.testTag(tag).semantics { contentDescription = title; stateDescription = displayed }) { Text(displayed) }
    }
    if (editing) AlertDialog(onDismissRequest = { editing = false }, title = { Text(title) },
        text = { OutlinedTextField(input, { input = it }, singleLine = true, isError = parsed == null,
            keyboardOptions = KeyboardOptions(keyboardType = if (usesExposureStops) KeyboardType.Text else KeyboardType.Decimal),
            modifier = Modifier.testTag("curve-coordinate-input"),
            suffix = if (usesExposureStops) ({ Text("EV") }) else null,
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
