package com.rawlab.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun GeometryControls(value: GeometrySettings, enabled: Boolean,
    ratio: GeometryRatio, portrait: Boolean, correct: Boolean, grid: Boolean,
    onRatio: (GeometryRatio) -> Unit, onPortrait: () -> Unit, onCorrect: (Boolean) -> Unit,
    onGrid: () -> Unit, onApply: () -> Unit, onCancel: () -> Unit, onReset: () -> Unit,
    onChange: (GeometrySettings, Boolean) -> Unit, modifier: Modifier = Modifier,
    cropEnabled: Boolean = enabled, applyEnabled: Boolean = enabled) {
    var precise by remember { mutableStateOf(false) }
    Column(modifier) {
        Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(horizontal = 8.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TextButton(onClick = onCancel, modifier = Modifier.testTag("geometry.cancel")) { Text(stringResource(R.string.cancel)) }
            Text(stringResource(R.string.geometry), Modifier.weight(1f), style = MaterialTheme.typography.titleSmall,
                maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
            Button(onClick = onApply, enabled = applyEnabled, modifier = Modifier.testTag("geometry.apply")) {
                Text(stringResource(R.string.geometry_apply))
            }
        }
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp).heightIn(min = 48.dp)) {
                listOf(R.string.geometry_crop_mode, R.string.geometry_correct_mode).forEachIndexed { index, label ->
                    SegmentedButton(selected = correct == (index == 1), onClick = { onCorrect(index == 1) },
                        shape = SegmentedButtonDefaults.itemShape(index, 2),
                        modifier = Modifier.testTag(if (index == 0) "geometry.crop-mode" else "geometry.correct-mode")) {
                        Text(stringResource(label))
                    }
                }
            }
            if (correct) {
                NumericControl(R.string.geometry_straighten, value.straightenDegrees, -45f..45f, "°", enabled,
                    { next, dragging -> onChange(value.copy(straightenDegrees = next), dragging) },
                    { onChange(value.copy(straightenDegrees = 0f), false) })
                NumericControl(R.string.geometry_perspective_horizontal, value.perspectiveHorizontal * 100f, -100f..100f, "%", enabled,
                    { next, dragging -> onChange(value.copy(perspectiveHorizontal = next / 100f), dragging) },
                    { onChange(value.copy(perspectiveHorizontal = 0f), false) })
                NumericControl(R.string.geometry_perspective_vertical, value.perspectiveVertical * 100f, -100f..100f, "%", enabled,
                    { next, dragging -> onChange(value.copy(perspectiveVertical = next / 100f), dragging) },
                    { onChange(value.copy(perspectiveVertical = 0f), false) })
            } else {
                LazyRow(Modifier.fillMaxWidth(), contentPadding = PaddingValues(horizontal = 16.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(GeometryRatio.entries) { choice ->
                        FilterChip(selected = ratio == choice, enabled = cropEnabled, onClick = { onRatio(choice) },
                            label = { Text(geometryRatioLabel(choice, portrait)) },
                            modifier = Modifier.heightIn(min = 48.dp).testTag("geometry.ratio-${choice.name}"))
                    }
                }
                Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceEvenly) {
                    GeometryAction(Icons.Outlined.RotateLeft, R.string.geometry_rotate_left, "geometry.rotate-left", enabled) { onChange(value.rotated(false), false) }
                    GeometryAction(Icons.Outlined.RotateRight, R.string.geometry_rotate_right, "geometry.rotate-right", enabled) { onChange(value.rotated(true), false) }
                    GeometryAction(Icons.Outlined.Flip, R.string.geometry_flip_horizontal, "geometry.flip-horizontal", enabled, value.flipHorizontal, toggle = true) { onChange(value.copy(flipHorizontal = !value.flipHorizontal), false) }
                    GeometryAction(Icons.Outlined.Flip, R.string.geometry_flip_vertical, "geometry.flip-vertical", enabled, value.flipVertical, toggle = true, vertical = true) { onChange(value.copy(flipVertical = !value.flipVertical), false) }
                    GeometryAction(Icons.Outlined.SwapHoriz, R.string.geometry_swap_ratio, "geometry.swap-ratio", cropEnabled && ratio != GeometryRatio.FREE && ratio != GeometryRatio.SQUARE) { onPortrait() }
                }
                Text(stringResource(R.string.geometry_drag_hint), Modifier.padding(horizontal = 16.dp),
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                TextButton(onClick = { precise = !precise }, modifier = Modifier.padding(horizontal = 8.dp).testTag("geometry.precise")) {
                    Icon(if (precise) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, null)
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.geometry_precise_crop))
                }
                if (precise) PreciseCrop(value, cropEnabled) { next, dragging -> onRatio(GeometryRatio.FREE); onChange(next, dragging) }
            }
            Spacer(Modifier.height(8.dp))
        }
        Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically) {
            FilterChip(selected = grid, onClick = onGrid, label = { Text(stringResource(R.string.geometry_grid)) },
                    modifier = Modifier.heightIn(min = 48.dp).testTag("geometry.grid"))
            Spacer(Modifier.weight(1f))
            TextButton(onClick = onReset, enabled = enabled, modifier = Modifier.testTag("geometry.reset")) {
                Text(stringResource(R.string.geometry_reset))
            }
        }
    }
}

@Composable
private fun GeometryAction(icon: androidx.compose.ui.graphics.vector.ImageVector, label: Int, tag: String,
    enabled: Boolean, selected: Boolean = false, toggle: Boolean = false, vertical: Boolean = false, onClick: () -> Unit) {
    val description = stringResource(label)
    val modifier = Modifier.size(48.dp).testTag(tag).semantics { contentDescription = description }
    val content: @Composable () -> Unit = {
        Icon(icon, null, modifier = if (vertical) Modifier.rotate(90f) else Modifier)
    }
    if (toggle) IconToggleButton(checked = selected, onCheckedChange = { onClick() }, enabled = enabled,
        modifier = modifier, content = content)
    else IconButton(onClick = onClick, enabled = enabled, modifier = modifier, content = content)
}

@Composable
internal fun geometryRatioLabel(value: GeometryRatio, portrait: Boolean): String = when (value) {
    GeometryRatio.FREE -> stringResource(R.string.geometry_ratio_free)
    GeometryRatio.ORIGINAL -> stringResource(R.string.geometry_ratio_original)
    GeometryRatio.SQUARE -> "1:1"
    GeometryRatio.THREE_TWO -> if (portrait) "2:3" else "3:2"
    GeometryRatio.FOUR_THREE -> if (portrait) "3:4" else "4:3"
    GeometryRatio.SIXTEEN_NINE -> if (portrait) "9:16" else "16:9"
}

@Composable
private fun PreciseCrop(value: GeometrySettings, enabled: Boolean, onChange: (GeometrySettings, Boolean) -> Unit) {
    var fields by remember(value.cropX, value.cropY, value.cropWidth, value.cropHeight) {
        mutableStateOf(listOf(value.cropX, value.cropY, value.cropWidth, value.cropHeight)
            .map { String.format(Locale.ROOT, "%.2f", it * 100f) })
    }
    val valid = runCatching {
        val crop = fields.map { it.toFloat() / 100f }
        value.copy(cropX = crop[0], cropY = crop[1], cropWidth = crop[2], cropHeight = crop[3])
    }.getOrNull()
    val labels = listOf(R.string.geometry_crop_x, R.string.geometry_crop_y, R.string.geometry_crop_width, R.string.geometry_crop_height)
    for (row in 0..1) Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        for (index in row * 2..row * 2 + 1) OutlinedTextField(fields[index], { input ->
            fields = fields.toMutableList().also { it[index] = input }
        }, Modifier.weight(1f).testTag("geometry.crop-$index"), enabled = enabled, singleLine = true,
            label = { Text(stringResource(labels[index])) }, suffix = { Text("%") }, isError = valid == null,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal))
    }
    if (valid == null) Text(stringResource(R.string.geometry_crop_error), Modifier.padding(horizontal = 16.dp),
        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
    TextButton(onClick = { valid?.let { onChange(it, false) } }, enabled = enabled && valid != null,
        modifier = Modifier.padding(horizontal = 8.dp).testTag("geometry.apply-crop")) { Text(stringResource(R.string.geometry_update_crop)) }
}
