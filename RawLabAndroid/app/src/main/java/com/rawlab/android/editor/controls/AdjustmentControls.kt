package com.rawlab.android.editor.controls

import android.os.SystemClock
import android.view.HapticFeedbackConstants
import android.view.accessibility.AccessibilityManager
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Brush
import java.math.BigDecimal
import java.text.DecimalFormatSymbols
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.awaitHorizontalTouchSlopOrCancellation
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Exposure
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
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
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt
import com.rawlab.android.R
import com.rawlab.android.ui.ToolIcon

internal val LocalEditorHaptics = staticCompositionLocalOf { true }
internal val LocalAdjustmentCancellation = staticCompositionLocalOf<(() -> Unit) -> Unit> { { restore -> restore() } }
internal val LocalAdjustmentFocus = staticCompositionLocalOf<(Boolean) -> Unit> { {} }
internal val LocalAdjustmentHapticGate = staticCompositionLocalOf { AdjustmentHapticGate() }

internal val LocalAdjustmentSession = staticCompositionLocalOf<Any?> { null }
internal val LocalAdjustmentFine = staticCompositionLocalOf { false }

@Composable
internal fun NumericControl(label: Int, value: Float, range: ClosedFloatingPointRange<Float>, unit: String,
    enabled: Boolean, onValue: (Float, Boolean) -> Unit, onReset: () -> Unit, reciprocal: Boolean = false,
    defaultValue: Float = 0f, resetEnabled: Boolean = enabled, showReset: Boolean = true,
    trackColors: List<Color>? = null, axisDescription: String? = null,
    compactNumber: Boolean = false, modifier: Modifier = Modifier) {
    val step = when (label) {
        R.string.exposure -> .05f
        R.string.temperature -> 10f
        R.string.geometry_straighten -> .1f
        R.string.geometry_crop_x, R.string.geometry_crop_y,
        R.string.geometry_crop_width, R.string.geometry_crop_height -> .01f
        else -> 1f
    }
    val baseline = when (label) {
        R.string.strength -> 100f
        R.string.denoise_chroma -> 46f
        R.string.denoise_coarse, R.string.vignette_midpoint, R.string.vignette_feather, R.string.grain_roughness -> 50f
        R.string.grain_size -> 25f
        else -> defaultValue
    }.coerceIn(range)
    val scale = AdjustmentScale(range, step, baseline, reciprocal, compactPercent = compactNumber)
    val scope = LocalAdjustmentSession.current
    // 未提交文本只属于打开时的照片、工具、轴、色域和原值；重绑定必须先销毁它。
    val session = remember(scope, label, value, enabled) { Any() }
    val liveSession by rememberUpdatedState(session)
    val update by rememberUpdatedState(onValue)
    var editing by remember(session) { mutableStateOf(false) }
    var input by remember(session) { mutableStateOf("") }
    val locale = LocalConfiguration.current.locales[0]
    val formatted = if (compactNumber) formatCropPercent(value, locale) else formatAdjustment(value, step, locale)
    val title = stringResource(label)
    val parsed = scale.parse(input, locale, value)
    val raw = parseAdjustmentNumber(input, locale)
    val modified = value != baseline
    val status = stringResource(if (modified) R.string.hsl_adjusted else R.string.hsl_unadjusted)
    val help = stringResource(R.string.editor_numeric_help, formatAdjustment(baseline, step, locale),
        formatAdjustment(range.start, step, locale), formatAdjustment(range.endInclusive, step, locale), formatAdjustment(step, step, locale))
    val resetLabel = stringResource(R.string.reset_value)
    val resetHint = stringResource(R.string.editor_numeric_reset_hint)
    val requester = remember { FocusRequester() }
    val context = LocalContext.current
    val accessibility = remember(context) { context.getSystemService(AccessibilityManager::class.java) }
    var touchExploration by remember(accessibility) { mutableStateOf(accessibility?.isTouchExplorationEnabled == true) }
    DisposableEffect(accessibility) {
        val listener = AccessibilityManager.TouchExplorationStateChangeListener { touchExploration = it }
        accessibility?.addTouchExplorationStateChangeListener(listener)
        onDispose { accessibility?.removeTouchExplorationStateChangeListener(listener) }
    }
    val reset by rememberUpdatedState(onReset)
    val canReset = enabled && resetEnabled && modified
    val resetModifier = Modifier.semantics {
        stateDescription = status
        customActions = if (canReset) listOf(CustomAccessibilityAction(resetLabel) { reset(); true }) else emptyList()
    }.then(if (!touchExploration && canReset) Modifier.pointerInput(session) {
        detectTapGestures(onDoubleTap = { reset() })
    } else Modifier)
    val color = if (modified) Color(0xffffc107) else MaterialTheme.colorScheme.onSurface
    val large = LocalDensity.current.fontScale > 1.3f
    @Composable fun name(modifier: Modifier) {
        Text(title, modifier.testTag("adjustment-name-$label").then(resetModifier).heightIn(min = 48.dp).wrapContentHeight(),
            style = MaterialTheme.typography.labelMedium)
    }
    @Composable fun number() {
        TextButton(onClick = { input = formatted; editing = true }, enabled = enabled,
            contentPadding = PaddingValues(horizontal = 4.dp),
            modifier = Modifier.heightIn(min = 48.dp).focusRequester(requester).testTag("adjustment-value-$label")
                .semantics {
                    stateDescription = status
                    if (compactNumber) {
                        contentDescription = "$title, $formatted $unit"
                        progressBarRangeInfo = ProgressBarRangeInfo(value, range)
                        customActions = if (canReset) listOf(CustomAccessibilityAction(resetLabel) { reset(); true }) else emptyList()
                        if (enabled) setProgress { next ->
                            if (!next.isFinite()) false else {
                                if (next != value) update(scale.quantize(next), false)
                                true
                            }
                        }
                    }
                }) {
            Box(Modifier.widthIn(max = 104.dp).horizontalScroll(rememberScrollState())) {
                Text(formatted, color = color, fontFamily = FontFamily.Monospace)
            }
            if (modified) Text(" ·", color = color)
        }
        Text(unit, Modifier.widthIn(min = 24.dp).testTag("adjustment-unit-$label"), style = MaterialTheme.typography.labelSmall)
    }
    @Composable fun track(modifier: Modifier) {
        Box(modifier) {
            AdjustmentRuler(axisDescription ?: title, value, scale, unit, LocalAdjustmentFine.current,
                enabled, onValue, resetModifier, trackColors)
        }
    }
    Column(modifier.fillMaxWidth().padding(horizontal = if (compactNumber) 4.dp else 12.dp).testTag("adjustment-row-$label")) {
        if (compactNumber) {
            if (large) {
                name(Modifier.fillMaxWidth())
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically) { number() }
            } else Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) { name(Modifier.weight(1f)); number() }
        } else if (large) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) { name(Modifier.weight(1f)); number() }
            track(Modifier.fillMaxWidth())
        } else Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            name(Modifier.weight(.8f)); track(Modifier.weight(1f)); number()
        }
    }
    fun close() { editing = false; requester.requestFocus() }
    if (editing) AlertDialog(onDismissRequest = { close() }, title = { Text(title) },
        text = {
            Column(Modifier.imePadding().verticalScroll(rememberScrollState())) {
                Text(help, style = MaterialTheme.typography.bodySmall)
                if (!touchExploration) Text(resetHint, style = MaterialTheme.typography.bodySmall)
                OutlinedTextField(input, { input = it }, singleLine = true, modifier = Modifier.fillMaxWidth().testTag("adjustment-input"),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal), isError = parsed == null,
                    leadingIcon = if (range.start < 0f) ({
                        ToolIcon(Icons.Outlined.Exposure, R.string.adjustment_toggle_sign) {
                            val draft = input.trim()
                            input = if (draft.startsWith("-")) draft.removePrefix("-") else "-" + draft.removePrefix("+")
                        }
                    }) else null,
                    supportingText = { if (parsed == null) Text(if (raw != null && raw.isFinite() && raw in range)
                        stringResource(R.string.editor_numeric_step_error, formatAdjustment(step, step, locale))
                        else stringResource(R.string.invalid_value)) })
            }
        }, confirmButton = { TextButton(onClick = {
            if (liveSession === session && parsed != null) {
                if (parsed != value) update(parsed, false)
                close()
            }
        }, enabled = parsed != null, modifier = Modifier.testTag("adjustment-input-apply")) { Text(stringResource(R.string.adjustment_apply)) } },
        dismissButton = { TextButton(onClick = { close() }) { Text(stringResource(R.string.cancel)) } })
}

internal fun formatAdjustment(value: Float, step: Float, locale: Locale = Locale.ROOT): String =
    (if (value == 0f) "0" else BigDecimal(value.toString()).stripTrailingZeros().toPlainString())
        .replace('.', DecimalFormatSymbols.getInstance(locale).decimalSeparator)

@Composable
private fun AdjustmentRuler(title: String, value: Float, scale: AdjustmentScale, unit: String, fine: Boolean,
    enabled: Boolean, onValue: (Float, Boolean) -> Unit, resetModifier: Modifier, trackColors: List<Color>?) {
    val density = LocalDensity.current
    val current by rememberUpdatedState(value)
    val scope = LocalAdjustmentSession.current
    val liveScope by rememberUpdatedState(scope)
    val cancel = LocalAdjustmentCancellation.current
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
    Canvas(Modifier.fillMaxWidth().height(48.dp).then(resetModifier).testTag("adjustment-slider").semantics {
        contentDescription = title
        stateDescription = "${formatAdjustment(value, scale.step)} $unit"
        progressBarRangeInfo = ProgressBarRangeInfo(value, scale.range)
        if (enabled) setProgress {
            if (!it.isFinite()) false else {
                // 读屏可能把刚读出的旧非网格原值原样交回；先判断相等，不能先量化。
                if (it != current) { val next = scale.quantize(it); if (next != current) update(next, false) }
                true
            }
        } else disabled()
    }.focusable(enabled).pointerInput(scope, scale, fine, enabled, haptics) {
        if (!enabled) return@pointerInput
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false)
            // Leave the system's edge-back region alone and only capture horizontal intent.
            if (down.position.x < 24.dp.toPx() || down.position.x > size.width - 24.dp.toPx()) return@awaitEachGesture
            val start = current
            var latest = start
            var changedDuringGesture = false
            var released = false
            val updateAtStart = update
            val cancelAtStart = cancel
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
                        changedDuringGesture = true
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
                released = !change.pressed && !change.isConsumed
            } finally {
                active = false
                focus(false)
                if (changedDuringGesture) {
                    if (released && liveScope == scope) updateAtStart(latest, false)
                    else cancelAtStart { if (liveScope == scope) updateAtStart(start, false) }
                }
            }
        }
    }) {
        val left = 4.dp.toPx()
        val width = (size.width - left * 2f).coerceAtLeast(0f)
        val y = size.height / 2f
        val start = left + scale.fraction(scale.default) * width
        val end = left + scale.fraction(value) * width
        if (trackColors != null) drawLine(Brush.horizontalGradient(trackColors), Offset(left, y), Offset(left + width, y), 4.dp.toPx())
        else drawLine(foreground.copy(alpha = .3f), Offset(left, y), Offset(left + width, y), 2.dp.toPx())
        drawLine(primary, Offset(start, y), Offset(end, y), 4.dp.toPx())
        for (i in 0..20) {
            val x = left + width * i / 20f
            val height = if (i % 5 == 0) 12.dp.toPx() else 6.dp.toPx()
            val growth = if (reduceMotion) 0f else (1f - abs(x - finger) / 24.dp.toPx()).coerceAtLeast(0f) * pulse * 4.dp.toPx()
            drawLine(foreground, Offset(x, y - height - growth), Offset(x, y - 5.dp.toPx()), 1.dp.toPx())
        }
        drawCircle(primary, 3.dp.toPx(), Offset(start, y + 8.dp.toPx()))
        drawLine(primary, Offset(end, y - 17.dp.toPx()), Offset(end, y + 5.dp.toPx()), 2.dp.toPx())
    }
}
