package com.rawlab.android

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.RestartAlt
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp

@Composable
fun HslControls(settings: HslSettings, enabled: Boolean, onEdit: (HslSettings, Boolean) -> Unit) {
    var channel by rememberSaveable { mutableIntStateOf(0) }
    val names = listOf(R.string.hsl_red, R.string.hsl_orange, R.string.hsl_yellow, R.string.hsl_green,
        R.string.hsl_aqua, R.string.hsl_blue, R.string.hsl_purple, R.string.hsl_magenta)
    val colors = listOf(Color.Red, Color(0xffff9800), Color.Yellow, Color.Green, Color.Cyan,
        Color.Blue, Color(0xff9c27b0), Color.Magenta)
    Column(Modifier.fillMaxWidth()) {
        LazyRow {
            items(8) { index ->
                val name = stringResource(names[index])
                Column(Modifier.width(72.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    IconButton(onClick = { channel = index }, enabled = enabled,
                        modifier = Modifier.semantics { contentDescription = name; selected = channel == index }) {
                        Box(Modifier.size(24.dp).background(colors[index], CircleShape)
                            .border(if (channel == index) 3.dp else 0.dp, MaterialTheme.colorScheme.onSurface, CircleShape))
                    }
                    Text(name, style = MaterialTheme.typography.labelSmall)
                }
            }
        }
        val axes = listOf(R.string.hsl_hue, R.string.saturation, R.string.hsl_lightness)
        axes.forEachIndexed { axis, label ->
            NumericControl(label, settings.value(axis, channel), -100f..100f, "", enabled,
                { value, dragging -> onEdit(settings.withValue(axis, channel, value), dragging) },
                { onEdit(settings.withValue(axis, channel, 0f), false) })
        }
        Row {
            IconButton(onClick = {
                var reset = settings
                for (axis in 0..2) reset = reset.withValue(axis, channel, 0f)
                onEdit(reset, false)
            }, enabled = enabled && (0..2).any { settings.value(it, channel) != 0f }) {
                Icon(Icons.Outlined.Refresh, stringResource(R.string.hsl_reset_channel))
            }
            IconButton(onClick = { onEdit(HslSettings(), false) }, enabled = enabled && !settings.isIdentity) {
                Icon(Icons.Outlined.RestartAlt, stringResource(R.string.hsl_reset))
            }
        }
    }
}
