package com.rawlab.android.editor.controls

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import com.rawlab.android.R
import com.rawlab.android.settings.HslSettings

@Composable
fun HslControls(settings: HslSettings, enabled: Boolean, channel: Int, onChannelChange: (Int) -> Unit,
    onReset: (Boolean) -> Unit, onEdit: (HslSettings, Boolean) -> Unit) {
    val names = listOf(R.string.hsl_red, R.string.hsl_orange, R.string.hsl_yellow, R.string.hsl_green,
        R.string.hsl_aqua, R.string.hsl_blue, R.string.hsl_purple, R.string.hsl_magenta)
    val colors = listOf(Color.Red, Color(0xffff9800), Color.Yellow, Color.Green, Color.Cyan,
        Color.Blue, Color(0xff9c27b0), Color.Magenta)
    Column(Modifier.fillMaxWidth()) {
        LazyRow(Modifier.testTag("hsl-channels")) {
            items(8) { index ->
                val name = stringResource(names[index])
                val changed = (0..2).any { settings.value(it, index) != 0f }
                val status = stringResource(if (changed) R.string.hsl_adjusted else R.string.hsl_unadjusted)
                Column(Modifier.width(48.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    IconButton(onClick = { onChannelChange(index) }, enabled = enabled,
                        modifier = Modifier.size(48.dp).testTag("hsl-channel-$index").semantics { contentDescription = name; selected = channel == index; stateDescription = status }) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Box(Modifier.size(24.dp).testTag("hsl-color-$index").background(colors[index], CircleShape)
                                .border(if (channel == index) 3.dp else 0.dp, MaterialTheme.colorScheme.onSurface, CircleShape))
                            Spacer(Modifier.height(3.dp))
                            Box(Modifier.size(3.dp).testTag("hsl-marker-$index")
                                .background(if (changed) MaterialTheme.colorScheme.primary else Color.Transparent, CircleShape))
                        }
                    }
                }
            }
        }
        val axes = listOf(R.string.hsl_hue, R.string.saturation, R.string.hsl_lightness)
        val directions = listOf(R.string.editor_hsl_hue_direction, R.string.editor_hsl_saturation_direction, R.string.editor_hsl_lightness_direction)
        val selectedName = stringResource(names[channel])
        val scope = LocalAdjustmentSession.current
        CompositionLocalProvider(LocalAdjustmentSession provides (scope to channel)) {
            axes.forEachIndexed { axis, label ->
                val pair = stringResource(R.string.editor_parameter_pair, selectedName, stringResource(label))
                val colorsForAxis = when (axis) {
                    0 -> listOf(colors[(channel + 7) % 8], colors[channel], colors[(channel + 1) % 8])
                    1 -> listOf(Color.Gray, colors[channel])
                    else -> listOf(Color.Black, colors[channel], Color.White)
                }
                NumericControl(label, settings.value(axis, channel), -100f..100f, "", enabled,
                    { value, dragging -> onEdit(settings.withValue(axis, channel, value), dragging) },
                    { onEdit(settings.withValue(axis, channel, 0f), false) },
                    trackColors = colorsForAxis, axisDescription = "$pair. ${stringResource(directions[axis])}")
            }
        }
    }
}
