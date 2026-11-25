package com.rawlab.android.editor.controls

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
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
import com.rawlab.android.adjustments.AdjustmentFieldSpec
import com.rawlab.android.engine.ToneCurveSampling
import com.rawlab.android.settings.*
import kotlin.math.abs
import kotlin.math.hypot

private const val CURVE_DRAG_OUT_DELETE_MARGIN = 0.12
private const val CURVE_DOUBLE_TAP_DELETE_MS = 350L
private const val CURVE_SIGNIFICANT_MOVE_THRESHOLD = 0.02

private data class ArmedCurvePointDelete(val index: Int, val point: ToneCurvePoint, val uptimeMillis: Long)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ToneCurveControls(settings: ToneCurveSettings, legacy: Float, enabled: Boolean,
    onEdit: (ToneCurveSettings, Boolean) -> Unit, onLegacyEdit: (Float, Boolean) -> Unit,
    usesExposureStops: Boolean = false, hslTarget: HslTargetActions = HslTargetActions()) {
    val scope = LocalAdjustmentSession.current
    val scopeKey = scope?.toString().orEmpty()
    val pointCurveModified = !settings.shape(ToneCurveChannel.RGB).isIdentity ||
        (settings.mode == ToneCurveMode.LEGACY && abs(legacy) > 1e-6f)
    val parametricModified = !settings.parametric.isDefault
    var channelName by rememberSaveable(scopeKey) { mutableStateOf(ToneCurveChannel.RGB.name) }
    val channel = ToneCurveChannel.entries.firstOrNull { it.name == channelName } ?: ToneCurveChannel.RGB
    var parametricMode by rememberSaveable(scopeKey) {
        mutableStateOf(parametricModified && !pointCurveModified)
    }
    var selected by rememberSaveable(scopeKey, channelName) { mutableIntStateOf(0) }
    var editing by remember(scope, channel) { mutableStateOf(false) }
    var switching by remember(scope, channel) { mutableStateOf(false) }
    var legacyEditing by remember(scope, channel) { mutableStateOf(false) }
    val root by rememberUpdatedState(settings)
    val shape = settings.shape(channel)
    val curve = ToneCurveSettings(
        mode = if (shape.mode == ToneCurveMode.LEGACY) ToneCurveMode.CUSTOM else shape.mode,
        points = if (shape.mode == ToneCurveMode.LEGACY) ToneCurveShape.identity.points else shape.points,
        applyToLuminosity = settings.applyToLuminosity,
        parametric = if (channel == ToneCurveChannel.RGB) settings.parametric else ToneCurveParametric(),
    )
    val current by rememberUpdatedState(curve)
    val index = selected.coerceIn(0, curve.points.lastIndex)
    val owner = channel
    val update: (ToneCurveSettings, Boolean) -> Unit = { next, dragging ->
        if (channel == owner) {
            val updatedRoot = root.replacing(owner, next.master)
            onEdit(
                ToneCurveSettings(
                    updatedRoot.mode,
                    updatedRoot.points,
                    updatedRoot.channels,
                    applyToLuminosity = next.applyToLuminosity,
                    parametric = if (owner == ToneCurveChannel.RGB) next.parametric else root.parametric,
                ),
                dragging,
            )
        }
    }
    val targetEnabled = hslTarget.state.enabled && hslTarget.state.curveMode
    LaunchedEffect(targetEnabled, channel) {
        if (targetEnabled && channel == ToneCurveChannel.RGB && parametricMode) {
            parametricMode = false
        }
    }
    val legacyActive = channel == ToneCurveChannel.RGB && shape.mode == ToneCurveMode.LEGACY && legacy != 0f
    val showParametric = channel == ToneCurveChannel.RGB && parametricMode
    val labels = listOf("RGB", stringResource(R.string.hsl_red), stringResource(R.string.hsl_green), stringResource(R.string.hsl_blue))
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        Row(Modifier.fillMaxWidth()) {
            ToneCurveChannel.entries.forEachIndexed { position, item ->
                val itemModified = if (item == ToneCurveChannel.RGB) {
                    pointCurveModified || parametricModified
                } else {
                    !settings.shape(item).isIdentity
                }
                val itemStatus = stringResource(if (itemModified) R.string.hsl_adjusted else R.string.hsl_unadjusted)
                TextButton(onClick = {
                    if (channel != item) {
                        channelName = item.name
                        hslTarget.curveChannel(item)
                    }
                }, modifier = Modifier.weight(1f).heightIn(min = 48.dp)
                    .testTag("curve-channel-${item.name.lowercase()}")
                    .semantics { this.selected = item == channel; stateDescription = itemStatus }) {
                    Text(labels[position], color = if (item == channel) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                    if (itemModified) {
                        Spacer(Modifier.width(4.dp))
                        Box(Modifier.size(4.dp).background(MaterialTheme.colorScheme.primary, CircleShape))
                    }
                }
            }
        }
        if (channel == ToneCurveChannel.RGB) {
            val pointTitle = stringResource(R.string.curve_point_mode)
            val paramTitle = stringResource(R.string.curve_parametric_mode)
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(!parametricMode, { parametricMode = false }, enabled = enabled,
                    label = { Text(if (pointCurveModified) "$pointTitle •" else pointTitle) },
                    modifier = Modifier.weight(1f).heightIn(min = 44.dp).testTag("curve-mode-point"))
                FilterChip(parametricMode, {
                    parametricMode = true
                    if (targetEnabled) hslTarget.enabled(false)
                }, enabled = enabled,
                    label = { Text(if (parametricModified) "$paramTitle •" else paramTitle) },
                    modifier = Modifier.weight(1f).heightIn(min = 44.dp).testTag("curve-mode-parametric"))
            }
        }
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween) {
            Text(stringResource(R.string.curve_luminosity_only), style = MaterialTheme.typography.bodySmall)
            Switch(settings.applyToLuminosity, { checked ->
                onEdit(ToneCurveSettings(root.mode, root.points, root.channels, checked, root.parametric), false)
            }, enabled = enabled, modifier = Modifier.testTag("curve-luminosity-only"))
        }
        if (!showParametric) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(targetEnabled, { hslTarget.enabled(!hslTarget.state.enabled) }, enabled = enabled,
                    label = { Text(stringResource(R.string.hsl_target)) },
                    modifier = Modifier.heightIn(min = 44.dp).testTag("curve-target"))
                if (targetEnabled) {
                    val targetMsg = when {
                        hslTarget.state.waiting -> stringResource(R.string.hsl_target_waiting)
                        hslTarget.state.notice == HslTargetAvailability.OUTSIDE -> stringResource(R.string.hsl_target_outside)
                        hslTarget.state.notice == HslTargetAvailability.STALE -> stringResource(R.string.hsl_target_stale)
                        hslTarget.state.notice == HslTargetAvailability.NONFINITE -> stringResource(R.string.hsl_target_unavailable)
                        hslTarget.state.notice == HslTargetAvailability.FAILED -> stringResource(R.string.hsl_target_failed)
                        else -> stringResource(R.string.hsl_target_instructions)
                    }
                    Text(targetMsg, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.weight(1f).testTag("curve-target-status"))
                }
            }
        }
        CompositionLocalProvider(LocalAdjustmentSession provides (scope to channel)) {
            if (legacyActive && !showParametric) {
                Column(Modifier.height(194.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(stringResource(R.string.tone_curve))
                    Text(formatAdjustmentNumber(legacy * 100.0, LocalConfiguration.current.locales[0]) + "%")
                    TextButton(onClick = { switching = true }, enabled = enabled, modifier = Modifier.testTag("curve-switch")) {
                        Text(stringResource(R.string.curve_custom))
                    }
                }
            } else {
                CurveCanvas(
                    curve, index, { selected = it }, enabled, Modifier.size(194.dp),
                    channel = channel,
                    showSplitMarkers = showParametric,
                    allowsPointEditing = !showParametric,
                    onEdit = update,
                )
                if (usesExposureStops) Row(Modifier.width(170.dp).testTag("curve-hdr-ev-axis"), horizontalArrangement = Arrangement.SpaceBetween) {
                    for (value in listOf("−8 EV", "0 EV", "+8 EV")) Text(value, style = MaterialTheme.typography.labelSmall)
                }
            }
        }
        if (showParametric) {
            val sub = AdjustmentFieldSpec.SubFields.LightCurveParametric
            val gap = sub.splitMinGap.toFloat()
            val p = settings.parametric
            fun updateParametric(nextParam: ToneCurveParametric, dragging: Boolean) {
                onEdit(ToneCurveSettings(root.mode, root.points, root.channels, root.applyToLuminosity, nextParam), dragging)
            }
            NumericControl(R.string.highlights, p.highlights.toFloat(), sub.bandMin.toFloat()..sub.bandMax.toFloat(), "%", enabled,
                { v, dragging -> updateParametric(root.parametric.copy(highlights = v.toDouble()), dragging) },
                { updateParametric(root.parametric.copy(highlights = sub.bandDefault), false) })
            NumericControl(R.string.curve_lights, p.lights.toFloat(), sub.bandMin.toFloat()..sub.bandMax.toFloat(), "%", enabled,
                { v, dragging -> updateParametric(root.parametric.copy(lights = v.toDouble()), dragging) },
                { updateParametric(root.parametric.copy(lights = sub.bandDefault), false) })
            NumericControl(R.string.curve_darks, p.darks.toFloat(), sub.bandMin.toFloat()..sub.bandMax.toFloat(), "%", enabled,
                { v, dragging -> updateParametric(root.parametric.copy(darks = v.toDouble()), dragging) },
                { updateParametric(root.parametric.copy(darks = sub.bandDefault), false) })
            NumericControl(R.string.shadows, p.shadows.toFloat(), sub.bandMin.toFloat()..sub.bandMax.toFloat(), "%", enabled,
                { v, dragging -> updateParametric(root.parametric.copy(shadows = v.toDouble()), dragging) },
                { updateParametric(root.parametric.copy(shadows = sub.bandDefault), false) })
            Text(stringResource(R.string.curve_split_points), style = MaterialTheme.typography.labelMedium,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp))
            val shadowMax = minOf(sub.splitShadowMax.toFloat(), p.splitMidtone.toFloat() - gap)
            NumericControl(R.string.shadows, p.splitShadow.toFloat(), sub.splitShadowMin.toFloat()..shadowMax.coerceAtLeast(sub.splitShadowMin.toFloat()), "", enabled,
                { v, dragging ->
                    val clamped = v.toDouble().coerceIn(sub.splitShadowMin, minOf(sub.splitShadowMax, root.parametric.splitMidtone - sub.splitMinGap))
                    updateParametric(root.parametric.copy(splitShadow = clamped), dragging)
                },
                {
                    val resetVal = sub.splitShadowDefault.coerceAtMost(root.parametric.splitMidtone - sub.splitMinGap)
                    updateParametric(root.parametric.copy(splitShadow = resetVal), false)
                }, defaultValue = sub.splitShadowDefault.toFloat(), stepOverride = 0.01f)
            val midMin = maxOf(sub.splitMidtoneMin.toFloat(), p.splitShadow.toFloat() + gap)
            val midMax = minOf(sub.splitMidtoneMax.toFloat(), p.splitHighlight.toFloat() - gap)
            NumericControl(R.string.grading_midtones, p.splitMidtone.toFloat(), midMin..midMax.coerceAtLeast(midMin), "", enabled,
                { v, dragging ->
                    val clamped = v.toDouble().coerceIn(maxOf(sub.splitMidtoneMin, root.parametric.splitShadow + sub.splitMinGap), minOf(sub.splitMidtoneMax, root.parametric.splitHighlight - sub.splitMinGap))
                    updateParametric(root.parametric.copy(splitMidtone = clamped), dragging)
                },
                {
                    val resetVal = sub.splitMidtoneDefault.coerceIn(root.parametric.splitShadow + sub.splitMinGap, root.parametric.splitHighlight - sub.splitMinGap)
                    updateParametric(root.parametric.copy(splitMidtone = resetVal), false)
                }, defaultValue = sub.splitMidtoneDefault.toFloat(), stepOverride = 0.01f)
            val highMin = maxOf(sub.splitHighlightMin.toFloat(), p.splitMidtone.toFloat() + gap)
            NumericControl(R.string.highlights, p.splitHighlight.toFloat(), highMin..sub.splitHighlightMax.toFloat().coerceAtLeast(highMin), "", enabled,
                { v, dragging ->
                    val clamped = v.toDouble().coerceIn(maxOf(sub.splitHighlightMin, root.parametric.splitMidtone + sub.splitMinGap), sub.splitHighlightMax)
                    updateParametric(root.parametric.copy(splitHighlight = clamped), dragging)
                },
                {
                    val resetVal = sub.splitHighlightDefault.coerceAtLeast(root.parametric.splitMidtone + sub.splitMinGap)
                    updateParametric(root.parametric.copy(splitHighlight = resetVal), false)
                }, defaultValue = sub.splitHighlightDefault.toFloat(), stepOverride = 0.01f)
            TextButton(onClick = { updateParametric(ToneCurveParametric(), false) }, enabled = enabled && !p.isDefault,
                modifier = Modifier.testTag("curve-parametric-reset")) { Text(stringResource(R.string.curve_reset)) }
        } else {
            Row(Modifier.fillMaxWidth().padding(horizontal = 18.dp), verticalAlignment = Alignment.CenterVertically) {
                fun coordinate(value: Double) = if (usesExposureStops) formatAdjustmentNumber(value * 16 - 8, java.util.Locale.getDefault())
                    else (value * 255).toInt().toString()
                val point = curve.points[index]
                Text("${stringResource(R.string.curve_input)} ${coordinate(point.x)} · ${stringResource(R.string.curve_output)} ${coordinate(point.y)}",
                    Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                IconButton(
                    onClick = {
                        val next = current.removing(index)
                        selected = minOf(index, (next.points.size - 1).coerceAtLeast(0))
                        update(next, false)
                    },
                    enabled = enabled && curve.isInterior(index),
                    modifier = Modifier.testTag("curve-quick-remove"),
                ) {
                    Icon(
                        Icons.Outlined.Delete,
                        contentDescription = stringResource(R.string.curve_remove_point),
                        tint = if (enabled && curve.isInterior(index)) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.35f),
                    )
                }
                TextButton(onClick = { editing = true }, modifier = Modifier.testTag("curve-edit-point")) { Text(stringResource(R.string.curve_edit_point)) }
            }
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
                CurveCoordinate(R.string.curve_input, point.x, enabled && curve.canMoveX(index), "curve-x", usesExposureStops) { x ->
                    update(current.moving(index, x, current.points[index].y), false)
                }
                CurveCoordinate(R.string.curve_output, point.y, enabled && curve.canMoveY(index), "curve-y", usesExposureStops) { y ->
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
    modifier: Modifier, channel: ToneCurveChannel = ToneCurveChannel.RGB, showSplitMarkers: Boolean = false,
    allowsPointEditing: Boolean = true, onEdit: (ToneCurveSettings, Boolean) -> Unit) {
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
    var armedDelete by remember(scope, channel, showSplitMarkers) { mutableStateOf<ArmedCurvePointDelete?>(null) }
    val isParametricView = showSplitMarkers && channel == ToneCurveChannel.RGB
    val interactive = enabled && allowsPointEditing && !isParametricView
    val samples = remember(value, channel, isParametricView) {
        if (isParametricView) {
            ToneCurveSampling.samples(
                ToneCurveSettings(ToneCurveMode.CUSTOM, ToneCurveShape.identity.points, parametric = value.parametric),
                ToneCurveChannel.RGB,
            )
        } else {
            ToneCurveSampling.samples(ToneCurveSettings(value.mode, value.points), ToneCurveChannel.RGB)
        }
    }
    val title = stringResource(if (isParametricView) R.string.curve_parametric_mode else R.string.curve_title)
    val description = if (isParametricView) {
        stringResource(if (value.parametric.isDefault) R.string.hsl_unadjusted else R.string.hsl_adjusted)
    } else {
        stringResource(R.string.curve_summary, value.points.size)
    }
    val foreground = MaterialTheme.colorScheme.onSurface
    val primary = MaterialTheme.colorScheme.primary
    val curveTint = when (channel) {
        ToneCurveChannel.RGB -> foreground
        ToneCurveChannel.RED -> Color(0xFFE53935)
        ToneCurveChannel.GREEN -> Color(0xFF43A047)
        ToneCurveChannel.BLUE -> Color(0xFF1E88E5)
    }
    Canvas(modifier.testTag("curve-canvas").semantics {
        contentDescription = title; stateDescription = description
        if (!enabled) disabled()
    }.focusRequester(requester).onKeyEvent { event ->
        if (!interactive || event.type != KeyEventType.KeyDown) false
        else if (active && event.key == Key.Escape) { armedDelete = null; cancellation++; true }
        else if (active || !current.canMoveY(selected)) false
        else {
            armedDelete = null
            val point = current.points[selected]; val step = if (event.isShiftPressed || fine) .001 else .01
            val next = when (event.key) {
                Key.DirectionLeft -> if (current.canMoveX(selected)) current.moving(selected, point.x - step, point.y) else null
                Key.DirectionRight -> if (current.canMoveX(selected)) current.moving(selected, point.x + step, point.y) else null
                Key.DirectionUp -> current.moving(selected, point.x, point.y + step)
                Key.DirectionDown -> current.moving(selected, point.x, point.y - step)
                Key.Backspace, Key.Delete -> if (current.isInterior(selected)) current.removing(selected) else null
                else -> null
            }
            if (next == null) false else { if (next != current) update(next, false); true }
        }
    }.focusable(interactive).pointerInput(scope, fine, interactive, windowFocused, cancellation) {
        if (!interactive || !windowFocused) return@pointerInput
        awaitEachGesture {
            val down = awaitFirstDown()
            val padding = 12.dp.toPx(); val width = (size.width - 2 * padding).coerceAtLeast(1f); val height = (size.height - 2 * padding).coerceAtLeast(1f)
            val hitRadiusSq = 20.dp.toPx() * 20.dp.toPx()
            fun point(position: Offset) = ToneCurvePoint(((position.x - padding) / width).toDouble(), (1 - (position.y - padding) / height).toDouble())
            fun distance(p: ToneCurvePoint): Double {
                val dx = (p.x * width + padding - down.position.x); val dy = ((1 - p.y) * height + padding - down.position.y)
                return dx * dx + dy * dy
            }
            val start = current; val origin = point(down.position)
            val armed = armedDelete
            armedDelete = null
            if (armed != null &&
                down.uptimeMillis >= armed.uptimeMillis &&
                down.uptimeMillis - armed.uptimeMillis <= CURVE_DOUBLE_TAP_DELETE_MS &&
                armed.index in start.points.indices &&
                start.isInterior(armed.index) &&
                start.points[armed.index] == armed.point &&
                distance(armed.point) <= hitRadiusSq
            ) {
                val removed = start.removing(armed.index)
                if (removed != start) {
                    select(minOf(armed.index, (removed.points.size - 1).coerceAtLeast(0)))
                    requester.requestFocus()
                    down.consume()
                    update(removed, false)
                    return@awaitEachGesture
                }
            }
            val nearest = start.points.indices.minBy { distance(start.points[it]) }
            val hit = distance(start.points[nearest]) <= hitRadiusSq
            val hitExistingInterior = hit && start.isInterior(nearest)
            val initial = if (hit) start else start.inserting(origin.x, origin.y)
            if (!hit && initial == start) return@awaitEachGesture
            val index = if (hit) nearest else initial.points.indexOfFirst { it.x == origin.x }
            select(index); requester.requestFocus()
            val updateAtStart = update; val cancelAtStart = cancel
            val handle = initial.points[index]; val scale = if (fine) .25 else 1.0
            fun isOutsideBounds(p: ToneCurvePoint): Boolean =
                p.x < -CURVE_DRAG_OUT_DELETE_MARGIN || p.x > 1.0 + CURVE_DRAG_OUT_DELETE_MARGIN ||
                    p.y < -CURVE_DRAG_OUT_DELETE_MARGIN || p.y > 1.0 + CURVE_DRAG_OUT_DELETE_MARGIN
            fun moved(position: Offset): ToneCurveSettings {
                val p = point(position)
                return initial.moving(index, handle.x + (p.x - origin.x) * scale, handle.y + (p.y - origin.y) * scale)
            }
            var latest = initial; var changed = initial != start; var released = false
            var movedSignificantly = false; var removedByDragOut = false
            fun stepPosition(position: Offset): ToneCurveSettings {
                val raw = point(position)
                if (hypot(raw.x - origin.x, raw.y - origin.y) > CURVE_SIGNIFICANT_MOVE_THRESHOLD) {
                    movedSignificantly = true
                }
                if (initial.isInterior(index) && isOutsideBounds(raw)) {
                    val removed = initial.removing(index)
                    removedByDragOut = true
                    select(minOf(index, (removed.points.size - 1).coerceAtLeast(0)))
                    return removed
                }
                if (removedByDragOut) {
                    removedByDragOut = false
                    select(index)
                }
                return moved(position)
            }
            active = true; focus(true)
            try {
                if (changed) updateAtStart(initial, true)
                var change = down
                do {
                    val next = stepPosition(change.position)
                    if (next != latest) { changed = true; latest = next; updateAtStart(next, true) }
                    change.consume()
                    change = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: break
                    if (!change.pressed && !change.isConsumed) {
                        val final = stepPosition(change.position)
                        if (final != latest) { changed = true; latest = final; updateAtStart(final, true) }
                        released = true; change.consume(); break
                    }
                } while (change.pressed && !change.isConsumed)
            } finally {
                active = false; focus(false)
                if (released && liveScope == scope && hitExistingInterior && !movedSignificantly && !removedByDragOut && index in latest.points.indices) {
                    armedDelete = ArmedCurvePointDelete(index, latest.points[index], down.uptimeMillis)
                }
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
        if (isParametricView) {
            val markerEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 3.dp.toPx()))
            for (splitX in listOf(value.parametric.splitShadow, value.parametric.splitMidtone, value.parametric.splitHighlight)) {
                drawLine(foreground.copy(alpha = .35f), point(ToneCurvePoint(splitX, 0.0)), point(ToneCurvePoint(splitX, 1.0)),
                    pathEffect = markerEffect)
            }
        }
        val path = Path(); samples.forEachIndexed { index, sample -> val p = point(sample); if (index == 0) path.moveTo(p.x, p.y) else path.lineTo(p.x, p.y) }
        drawPath(path, curveTint, style = Stroke(2.dp.toPx()))
        if (!isParametricView) {
            value.points.forEachIndexed { index, p -> drawCircle(if (index == selected) primary else curveTint,
                (if (index == selected) 6.dp else 4.dp).toPx(), point(p)) }
        }
    }
}
