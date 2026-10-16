package com.rawlab.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp

@Composable
internal fun GeometryControls(value: GeometrySettings, enabled: Boolean, canvasAspect: Float = 1f,
    onChange: (GeometrySettings, Boolean) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.geometry), Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
            ToolIcon(Icons.Outlined.RestartAlt, R.string.geometry_reset, enabled) { onChange(GeometrySettings(), false) }
        }
        Row(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            IconButton(onClick = { onChange(value.rotated(false), false) }, enabled = enabled,
                modifier = Modifier.testTag("geometry.rotate-left")) { Icon(Icons.Outlined.RotateLeft, stringResource(R.string.geometry_rotate_left)) }
            IconButton(onClick = { onChange(value.rotated(true), false) }, enabled = enabled,
                modifier = Modifier.testTag("geometry.rotate-right")) { Icon(Icons.Outlined.RotateRight, stringResource(R.string.geometry_rotate_right)) }
            IconToggleButton(checked = value.flipHorizontal, onCheckedChange = { onChange(value.copy(flipHorizontal = it), false) }, enabled = enabled,
                modifier = Modifier.testTag("geometry.flip-horizontal")) { Icon(Icons.Outlined.Flip, stringResource(R.string.geometry_flip_horizontal)) }
            IconToggleButton(checked = value.flipVertical, onCheckedChange = { onChange(value.copy(flipVertical = it), false) }, enabled = enabled,
                modifier = Modifier.testTag("geometry.flip-vertical")) { Icon(Icons.Outlined.FlipCameraAndroid, stringResource(R.string.geometry_flip_vertical)) }
        }
        NumericControl(R.string.geometry_straighten, value.straightenDegrees, -45f..45f, "°", enabled,
            { next, dragging -> onChange(value.copy(straightenDegrees = next), dragging) },
            { onChange(value.copy(straightenDegrees = 0f), false) })
        LazyRow(Modifier.fillMaxWidth(), contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            item { OutlinedButton(onClick = { onChange(value.uncropped(), false) }, enabled = enabled) { Text(stringResource(R.string.geometry_full)) } }
            listOf(1f to "1:1", 1.5f to "3:2", (2f / 3f) to "2:3").forEach { (ratio, title) ->
                item { OutlinedButton(onClick = { onChange(value.withAspect(ratio, canvasAspect), false) }, enabled = enabled) { Text(title) } }
            }
        }
        Text(stringResource(R.string.geometry_crop_hint), Modifier.padding(horizontal = 16.dp), style = MaterialTheme.typography.bodySmall)
        NumericControl(R.string.geometry_crop_x, value.cropX * 100f, 0f..((1f - value.cropWidth) * 100f).coerceAtLeast(0f), "%", enabled,
            { next, dragging -> onChange(value.copy(cropX = next / 100f), dragging) }, { onChange(value.copy(cropX = 0f), false) })
        NumericControl(R.string.geometry_crop_y, value.cropY * 100f, 0f..((1f - value.cropHeight) * 100f).coerceAtLeast(0f), "%", enabled,
            { next, dragging -> onChange(value.copy(cropY = next / 100f), dragging) }, { onChange(value.copy(cropY = 0f), false) })
        NumericControl(R.string.geometry_crop_width, value.cropWidth * 100f, .1f..((1f - value.cropX) * 100f).coerceAtLeast(.1f), "%", enabled,
            { next, dragging -> onChange(value.copy(cropWidth = next / 100f), dragging) }, { onChange(value.copy(cropWidth = 1f), false) },
            defaultValue = 100f, resetEnabled = value.cropX == 0f)
        NumericControl(R.string.geometry_crop_height, value.cropHeight * 100f, .1f..((1f - value.cropY) * 100f).coerceAtLeast(.1f), "%", enabled,
            { next, dragging -> onChange(value.copy(cropHeight = next / 100f), dragging) }, { onChange(value.copy(cropHeight = 1f), false) },
            defaultValue = 100f, resetEnabled = value.cropY == 0f)
    }
}
