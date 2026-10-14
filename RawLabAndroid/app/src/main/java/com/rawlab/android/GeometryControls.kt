package com.rawlab.android

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.RestartAlt
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import java.util.Locale

@Composable
internal fun GeometryControls(value: GeometrySettings, enabled: Boolean,
    onChange: (GeometrySettings, Boolean) -> Unit) {
    var cropDraft by remember(value.cropX, value.cropY, value.cropWidth, value.cropHeight) {
        mutableStateOf(listOf(value.cropX, value.cropY, value.cropWidth, value.cropHeight)
            .map { String.format(Locale.ROOT, "%.2f", it * 100f) })
    }
    val crop = runCatching {
        val fields = cropDraft.map { it.toFloat() / 100f }
        value.copy(cropX = fields[0], cropY = fields[1], cropWidth = fields[2], cropHeight = fields[3])
    }.getOrNull()
    val labels = listOf(R.string.geometry_crop_x, R.string.geometry_crop_y,
        R.string.geometry_crop_width, R.string.geometry_crop_height)
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.geometry), Modifier.weight(1f), style = MaterialTheme.typography.labelLarge)
            ToolIcon(Icons.Outlined.RestartAlt, R.string.geometry_reset, enabled) {
                cropDraft = listOf("0.00", "0.00", "100.00", "100.00")
                onChange(GeometrySettings(), false)
            }
        }
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TextButton(onClick = { onChange(value.rotated(false), false) }, enabled = enabled,
                modifier = Modifier.weight(1f).testTag("geometry.rotate-left")) { Text(stringResource(R.string.geometry_rotate_left)) }
            TextButton(onClick = { onChange(value.rotated(true), false) }, enabled = enabled,
                modifier = Modifier.weight(1f).testTag("geometry.rotate-right")) { Text(stringResource(R.string.geometry_rotate_right)) }
        }
        GeometryFlip(R.string.geometry_flip_horizontal, "geometry.flip-horizontal", value.flipHorizontal, enabled) {
            onChange(value.copy(flipHorizontal = it), false)
        }
        GeometryFlip(R.string.geometry_flip_vertical, "geometry.flip-vertical", value.flipVertical, enabled) {
            onChange(value.copy(flipVertical = it), false)
        }
        NumericControl(R.string.geometry_straighten, value.straightenDegrees, -45f..45f, "°", enabled,
            { next, dragging -> onChange(value.copy(straightenDegrees = next), dragging) },
            { onChange(value.copy(straightenDegrees = 0f), false) })
        Text(stringResource(R.string.geometry_crop_hint), Modifier.padding(horizontal = 16.dp),
            style = MaterialTheme.typography.bodySmall)
        for (row in 0..1) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (index in (row * 2)..(row * 2 + 1)) {
                    OutlinedTextField(cropDraft[index], { draft ->
                        cropDraft = cropDraft.toMutableList().also { it[index] = draft }
                    }, Modifier.weight(1f).testTag("geometry.crop-$index"), enabled = enabled, singleLine = true,
                        label = { Text(stringResource(labels[index])) }, suffix = { Text("%") },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal), isError = crop == null)
                }
            }
        }
        if (crop == null) Text(stringResource(R.string.geometry_crop_error),
            Modifier.padding(horizontal = 16.dp), color = MaterialTheme.colorScheme.error,
            style = MaterialTheme.typography.bodySmall)
        Button(onClick = { crop?.let { onChange(it, false) } }, enabled = enabled && crop != null,
            modifier = Modifier.padding(horizontal = 16.dp).testTag("geometry.apply-crop")) {
            Text(stringResource(R.string.geometry_apply_crop))
        }
    }
}

@Composable
private fun GeometryFlip(label: Int, tag: String, checked: Boolean, enabled: Boolean, onChange: (Boolean) -> Unit) {
    val description = stringResource(label)
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(description, Modifier.weight(1f), style = MaterialTheme.typography.labelLarge)
        Switch(checked, onChange, enabled = enabled,
            modifier = Modifier.testTag(tag).semantics { contentDescription = description })
    }
}
