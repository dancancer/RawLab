package com.rawlab.android

import android.graphics.Paint
import android.graphics.Typeface
import android.os.SystemClock
import android.view.HapticFeedbackConstants
import android.view.accessibility.AccessibilityManager
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.awaitHorizontalTouchSlopOrCancellation
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.RestartAlt
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

internal val LocalEditorHaptics = staticCompositionLocalOf { true }
internal val LocalAdjustmentFocus = staticCompositionLocalOf<(Boolean) -> Unit> { {} }
internal val LocalAdjustmentHapticGate = staticCompositionLocalOf { AdjustmentHapticGate() }

@Composable
internal fun NumericControl(label: Int, value: Float, range: ClosedFloatingPointRange<Float>, unit: String,
    enabled: Boolean, onValue: (Float, Boolean) -> Unit, onReset: () -> Unit, reciprocal: Boolean = false,
    defaultValue: Float = 0f, resetEnabled: Boolean = enabled) {
    val step = when (label) {
        R.string.exposure -> .05f
        R.string.temperature -> 10f
        R.string.geometry_straighten, R.string.geometry_crop_x, R.string.geometry_crop_y,
        R.string.geometry_crop_width, R.string.geometry_crop_height -> .1f
        else -> 1f
    }
    val baseline = when (label) {
        R.string.strength -> 100f
        R.string.denoise_chroma -> 46f
        R.string.denoise_coarse, R.string.vignette_midpoint, R.string.vignette_feather, R.string.grain_roughness -> 50f
        R.string.grain_size -> 25f
        else -> defaultValue
    }.coerceIn(range)
    val scale = AdjustmentScale(range, step, baseline, reciprocal)
    var editing by rememberSaveable(label) { mutableStateOf(false) }
    var fine by rememberSaveable(label) { mutableStateOf(false) }
    var input by rememberSaveable(label) { mutableStateOf("") }
    val formatted = formatAdjustment(value, step)
    val title = stringResource(label)
    val parsed = scale.parse(input, LocalConfiguration.current.locales[0], value)
    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(title, Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
            if (LocalDensity.current.fontScale <= 1.3f) TextButton(onClick = { input = formatted; editing = true }, enabled = enabled,
                modifier = Modifier.testTag("adjustment-value-$label")) {
                Text(listOf(formatted, unit).filter { it.isNotBlank() }.joinToString(" "), fontFamily = FontFamily.Monospace)
            }
            ToolIcon(Icons.Outlined.RestartAlt, R.string.reset_value, enabled && resetEnabled, onReset)
        }
        if (LocalDensity.current.fontScale > 1.3f) TextButton(onClick = { input = formatted; editing = true }, enabled = enabled,
            modifier = Modifier.testTag("adjustment-value-$label")) {
            Text(listOf(formatted, unit).filter { it.isNotBlank() }.joinToString(" "),
                fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.titleMedium)
        }
        AdjustmentRuler(title, value, scale, unit, fine, enabled, onValue)
        SingleChoiceSegmentedButtonRow {
            listOf(R.string.adjustment_normal, R.string.adjustment_fine).forEachIndexed { index, text ->
                SegmentedButton(selected = fine == (index == 1), onClick = { fine = index == 1 },
                    shape = SegmentedButtonDefaults.itemShape(index, 2), enabled = enabled) { Text(stringResource(text)) }
            }
        }
    }
    if (editing) AlertDialog(onDismissRequest = { editing = false }, title = { Text(title) },
        text = {
            Column(Modifier.imePadding().verticalScroll(rememberScrollState())) {
                OutlinedTextField(input, { input = it }, singleLine = true, modifier = Modifier.fillMaxWidth().testTag("adjustment-input"),
                    keyboardOptions = KeyboardOptions(keyboardType = if (range.start < 0f) KeyboardType.Text else KeyboardType.Decimal), isError = parsed == null,
                    label = { Text("${formatAdjustment(range.start, step)} ... ${formatAdjustment(range.endInclusive, step)} $unit") },
                    supportingText = { if (parsed == null) Text(stringResource(R.string.invalid_value)) })
            }
        }, confirmButton = { TextButton(onClick = { parsed?.let { onValue(it, false) }; editing = false },
            enabled = parsed != null, modifier = Modifier.testTag("adjustment-input-apply")) { Text(stringResource(R.string.adjustment_apply)) } },
        dismissButton = { TextButton(onClick = { editing = false }) { Text(stringResource(R.string.cancel)) } })
}

internal fun formatAdjustment(value: Float, step: Float): String = when {
    step < .1f -> String.format(Locale.ROOT, "%+.2f", if (abs(value) < .0001f) 0f else value)
    step < 1f -> String.format(Locale.ROOT, "%.1f", value)
    else -> value.roundToInt().toString()
}

@Composable
private fun AdjustmentRuler(title: String, value: Float, scale: AdjustmentScale, unit: String, fine: Boolean,
    enabled: Boolean, onValue: (Float, Boolean) -> Unit) {
    val density = LocalDensity.current
    val current by rememberUpdatedState(value)
    val update by rememberUpdatedState(onValue)
    val view = LocalView.current
    val context = LocalContext.current
    val accessibility = remember(context) { context.getSystemService(AccessibilityManager::class.java) }
    val haptics = LocalEditorHaptics.current
    val focus = LocalAdjustmentFocus.current
    val gate = LocalAdjustmentHapticGate.current
    val reduceMotion = android.provider.Settings.Global.getFloat(context.contentResolver,
        android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    val primary = MaterialTheme.colorScheme.primary
    val foreground = MaterialTheme.colorScheme.onSurfaceVariant
    var active by remember { mutableStateOf(false) }
    var finger by remember { mutableFloatStateOf(-100f) }
    val pulse by animateFloatAsState(if (active) 1f else 0f, tween(180), label = "ruler-focus")
    val paint = remember { Paint(Paint.ANTI_ALIAS_FLAG).apply { typeface = Typeface.create("sans-serif", Typeface.NORMAL); textAlign = Paint.Align.CENTER } }
    Canvas(Modifier.fillMaxWidth().height(80.dp).testTag("adjustment-slider").semantics {
        contentDescription = title
        stateDescription = "${formatAdjustment(value, scale.step)} $unit"
        progressBarRangeInfo = ProgressBarRangeInfo(value, scale.range)
        if (enabled) setProgress { update(scale.quantize(it), false); true } else disabled()
    }.focusable(enabled).pointerInput(scale, fine, enabled, haptics) {
        if (!enabled) return@pointerInput
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false)
            // Leave the system's edge-back region alone and only capture horizontal intent.
            if (down.position.x < 24.dp.toPx() || down.position.x > size.width - 24.dp.toPx()) return@awaitEachGesture
            val start = current
            var latest = start
            var boundary = false
            val captured = awaitHorizontalTouchSlopOrCancellation(down.id) { change, _ -> change.consume() }
                ?: return@awaitEachGesture
            active = true
            focus(true)
            try {
                var change = captured
                do {
                    val dx = (change.position.x - down.position.x) / density.density
                    finger = change.position.x
                    val next = scale.drag(start, dx, fine)
                    if (next != latest) {
                        val now = SystemClock.uptimeMillis()
                        val isDefault = abs(next - scale.default) < scale.step / 2f
                        val isBoundary = next == scale.range.start || next == scale.range.endInclusive
                        val major = (next / (scale.step * 10)).roundToInt() != (latest / (scale.step * 10)).roundToInt()
                        if (haptics && accessibility?.isTouchExplorationEnabled != true &&
                            (isDefault || (isBoundary && !boundary) || major) && gate.accept(now)) {
                            view.performHapticFeedback(if (isDefault) HapticFeedbackConstants.CLOCK_TICK else HapticFeedbackConstants.KEYBOARD_TAP)
                        }
                        boundary = isBoundary
                        latest = next
                        update(next, true)
                    }
                    change.consume()
                    val event = awaitPointerEvent()
                    change = event.changes.firstOrNull { it.id == down.id } ?: break
                } while (change.pressed && !change.isConsumed)
            } finally {
                active = false
                focus(false)
                update(latest, false)
            }
        }
    }) {
        val spacing = 8.dp.toPx()
        val center = size.width / 2f
        val position = scale.position(value) / scale.rulerStep
        val base = position.toInt()
        val radius = (size.width / spacing / 2).toInt() + 2
        val bottom = 43.dp.toPx()
        paint.textSize = 11.sp.toPx()
        paint.color = foreground.toArgb()
        for (tick in (base - radius)..(base + radius)) {
            val raw = tick * scale.rulerStep
            if (raw < scale.position(scale.range.start) || raw > scale.position(scale.range.endInclusive)) continue
            val x = center + (tick - position) * spacing
            if (x !in 0f..size.width) continue
            val major = tick % 10 == 0
            val growth = if (reduceMotion) 0f else (1f - abs(x - finger) / 24.dp.toPx()).coerceAtLeast(0f) * pulse
            val height = (if (major) 22.dp.toPx() else 13.dp.toPx()) + growth * 6.dp.toPx()
            drawLine(foreground, Offset(x, bottom), Offset(x, bottom - height), 1.dp.toPx())
            if (major) {
                val label = formatAdjustment(scale.fromPosition(raw), scale.step)
                val half = paint.measureText(label) / 2f
                if (x - half >= 2.dp.toPx() && x + half <= size.width - 2.dp.toPx())
                    drawContext.canvas.nativeCanvas.drawText(label, x, bottom + 20.dp.toPx(), paint)
            }
        }
        val defaultX = center + (scale.position(scale.default) / scale.rulerStep - position) * spacing
        if (defaultX in 0f..size.width) drawCircle(primary, 2.5.dp.toPx(), Offset(defaultX, bottom + 3.dp.toPx()))
        drawLine(primary, Offset(center, 5.dp.toPx()), Offset(center, bottom), 2.dp.toPx())
    }
}
