package com.rawlab.android.editor.controls

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.rawlab.android.R
import com.rawlab.android.settings.*

data class HslTargetActions(val state: HslTargetState = HslTargetState(),
    val enabled: (Boolean) -> Unit = {}, val axis: (Int) -> Unit = {},
    val begin: (Float, Float) -> Unit = { _, _ -> }, val move: (Float) -> Unit = {},
    val end: () -> Unit = {}, val cancel: () -> Unit = {}, val key: (Float) -> Unit = {}, val reject: () -> Unit = {}) {
    fun guarded(current: () -> Boolean) = copy(
        begin = { x, y -> if (current()) begin(x, y) }, move = { if (current()) move(it) },
        end = { if (current()) end() }, cancel = { if (current()) cancel() },
        key = { if (current()) key(it) }, reject = { if (current()) reject() })
}

@Composable
internal fun HslTargetControls(target: HslTargetActions, enabled: Boolean) {
    val state = target.state
    val axes = listOf(R.string.hsl_hue, R.string.saturation, R.string.hsl_lightness)
    val names = listOf(R.string.hsl_red, R.string.hsl_orange, R.string.hsl_yellow, R.string.hsl_green,
        R.string.hsl_aqua, R.string.hsl_blue, R.string.hsl_purple, R.string.hsl_magenta)
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        FilterChip(state.enabled, { target.enabled(!state.enabled) }, enabled = enabled,
            label = { Text(stringResource(R.string.hsl_target)) },
            modifier = Modifier.heightIn(min = 48.dp).testTag("hsl-target"))
        if (state.enabled) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                axes.forEachIndexed { index, label ->
                    FilterChip(state.axis == index, { target.axis(index) }, enabled = enabled,
                        label = { Text(stringResource(label)) },
                        modifier = Modifier.weight(1f).heightIn(min = 48.dp).testTag("hsl-target-axis-$index"))
                }
            }
            val message = when {
                state.waiting -> stringResource(R.string.hsl_target_waiting)
                state.notice == HslTargetAvailability.NEAR_GRAY -> stringResource(R.string.hsl_target_gray)
                state.notice == HslTargetAvailability.OUTSIDE -> stringResource(R.string.hsl_target_outside)
                state.notice == HslTargetAvailability.STALE -> stringResource(R.string.hsl_target_stale)
                state.notice == HslTargetAvailability.NONFINITE -> stringResource(R.string.hsl_target_unavailable)
                state.notice == HslTargetAvailability.FAILED -> stringResource(R.string.hsl_target_failed)
                state.sample?.usable == true -> stringResource(R.string.hsl_target_ranges,
                    state.sample.channels.map { stringResource(names[it]) }.joinToString(" · "))
                else -> stringResource(R.string.hsl_target_instructions)
            }
            Text(message, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.testTag("hsl-target-status"))
        }
    }
}
