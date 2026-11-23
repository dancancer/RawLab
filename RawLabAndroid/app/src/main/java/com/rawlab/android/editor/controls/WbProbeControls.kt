package com.rawlab.android.editor.controls

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.rawlab.android.R
import com.rawlab.android.settings.WbProbeNotice
import com.rawlab.android.settings.WbProbeState

data class WbProbeActions(
    val state: WbProbeState = WbProbeState(),
    val enabled: (Boolean) -> Unit = {},
    val sample: (Float, Float) -> Unit = { _, _ -> },
    val cancel: () -> Unit = {},
    val reject: () -> Unit = {},
) {
    fun guarded(current: () -> Boolean) = copy(
        sample = { x, y -> if (current()) sample(x, y) },
        cancel = { if (current()) cancel() },
        reject = { if (current()) reject() },
    )
}

@Composable
internal fun WbProbeControls(probe: WbProbeActions, enabled: Boolean) {
    val state = probe.state
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        FilterChip(
            selected = state.enabled,
            onClick = { probe.enabled(!state.enabled) },
            enabled = enabled,
            label = { Text(stringResource(R.string.wb_eyedropper)) },
            modifier = Modifier.heightIn(min = 48.dp).testTag("wb-eyedropper"),
        )
        if (state.enabled) {
            val message = when {
                state.waiting -> stringResource(R.string.hsl_target_waiting)
                state.notice == WbProbeNotice.OUTSIDE -> stringResource(R.string.hsl_target_outside)
                state.notice == WbProbeNotice.STALE -> stringResource(R.string.hsl_target_stale)
                state.notice == WbProbeNotice.OVEREXPOSED || state.notice == WbProbeNotice.UNAVAILABLE ->
                    stringResource(R.string.hsl_target_unavailable)
                else -> stringResource(R.string.wb_eyedropper)
            }
            Text(
                text = message,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.testTag("wb-eyedropper-status"),
            )
        }
    }
}

@Composable
internal fun WbProbeCanvasControls(probe: WbProbeActions, modifier: Modifier = Modifier) {
    Surface(
        modifier.widthIn(max = 560.dp).testTag("wb-eyedropper-canvas"),
        shape = MaterialTheme.shapes.medium,
        color = MaterialTheme.colorScheme.surface.copy(alpha = .95f),
    ) {
        Column(Modifier.padding(10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(stringResource(R.string.wb_eyedropper), style = MaterialTheme.typography.titleSmall)
            TextButton(
                onClick = { probe.enabled(false) },
                modifier = Modifier.heightIn(min = 48.dp).testTag("wb-eyedropper-exit"),
            ) {
                Text(stringResource(R.string.hsl_target_exit))
            }
        }
    }
}
