package com.rawlab.android.editor.geometry

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import com.rawlab.android.R
import com.rawlab.android.editor.controls.NumericControl
import com.rawlab.android.geometry.GeometryRatio
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.ui.ToolIcon

@Composable
internal fun GeometryControls(value: GeometrySettings, enabled: Boolean,
    ratio: GeometryRatio = GeometryRatio.FREE, portrait: Boolean = false, ratioEnabled: Boolean = enabled,
    onRatioChange: (GeometryRatio, Boolean) -> Unit = { _, _ -> }, onReset: (() -> Unit)? = null,
    lockedRatio: Float? = null, physicalAspect: Float? = ratio.ratio(1f, portrait), canvasAspect: Float = 1f,
    onLock: () -> Unit = {}, onSwap: () -> Unit = { onRatioChange(ratio, !portrait) },
    showsGrid: Boolean = true, onGrid: () -> Unit = {}, perspective: Boolean = false,
    onChange: (GeometrySettings, Boolean) -> Unit) {
    var ratioMenu by remember { mutableStateOf(false) }
    var dimensions by rememberSaveable { mutableStateOf(false) }
    fun ratioTitle(choice: GeometryRatio): Int? = when (choice) {
        GeometryRatio.FREE -> R.string.geometry_ratio_free
        GeometryRatio.ORIGINAL -> R.string.geometry_ratio_original
        else -> null
    }
    fun ratioNumber(choice: GeometryRatio): String = when (choice) {
        GeometryRatio.SQUARE -> "1:1"
        GeometryRatio.THREE_TWO -> if (portrait) "2:3" else "3:2"
        GeometryRatio.FOUR_THREE -> if (portrait) "3:4" else "4:3"
        GeometryRatio.SIXTEEN_NINE -> if (portrait) "9:16" else "16:9"
        else -> ""
    }
    val normalized = physicalAspect?.let { it / canvasAspect }
    val maximumWidth = minOf(1f - value.cropX, normalized?.let { (1f - value.cropY) * it } ?: 1f)
    val maximumHeight = minOf(1f - value.cropY, normalized?.let { (1f - value.cropX) / it } ?: 1f)
    fun dimension(width: Boolean, percent: Float) {
        val fraction = percent / 100f
        val next = if (width) value.copy(cropWidth = fraction, cropHeight = normalized?.let { fraction / it } ?: value.cropHeight)
            else value.copy(cropHeight = fraction, cropWidth = normalized?.let { fraction * it } ?: value.cropWidth)
        onChange(next, false)
    }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        if (perspective) {
            NumericControl(R.string.geometry_perspective_horizontal, value.perspectiveHorizontal * 100f, -100f..100f, "%", enabled,
                { next, dragging -> onChange(value.copy(perspectiveHorizontal = next / 100f), dragging) },
                { onChange(value.copy(perspectiveHorizontal = 0f), false) })
            NumericControl(R.string.geometry_perspective_vertical, value.perspectiveVertical * 100f, -100f..100f, "%", enabled,
                { next, dragging -> onChange(value.copy(perspectiveVertical = next / 100f), dragging) },
                { onChange(value.copy(perspectiveVertical = 0f), false) })
        } else {
            Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f)) {
                    TextButton(onClick = { ratioMenu = true }, enabled = ratioEnabled,
                        modifier = Modifier.heightIn(min = 48.dp).testTag("geometry.ratios")) {
                        Text(if (lockedRatio != null) stringResource(R.string.geometry_lock_current_aspect)
                            else ratioTitle(ratio)?.let { stringResource(it) } ?: ratioNumber(ratio), Modifier.weight(1f))
                        Icon(Icons.Outlined.UnfoldMore, null, Modifier.size(18.dp))
                    }
                    DropdownMenu(ratioMenu, { ratioMenu = false }) {
                        GeometryRatio.entries.forEach { choice ->
                            DropdownMenuItem(text = { Text(ratioTitle(choice)?.let { stringResource(it) } ?: ratioNumber(choice)) },
                                onClick = { ratioMenu = false; onRatioChange(choice, portrait) },
                                modifier = Modifier.testTag("geometry.ratio-${choice.name}").semantics { selected = choice == ratio && lockedRatio == null })
                        }
                    }
                }
                IconToggleButton(checked = physicalAspect != null, onCheckedChange = { onLock() }, enabled = ratioEnabled,
                    modifier = Modifier.testTag("geometry.lock-ratio")) { Icon(if (physicalAspect == null) Icons.Outlined.LockOpen else Icons.Outlined.Lock, stringResource(R.string.geometry_lock_current_aspect)) }
                IconButton(onClick = onSwap, enabled = ratioEnabled && physicalAspect != null && physicalAspect != 1f,
                    modifier = Modifier.testTag("geometry.swap-ratio")) { Icon(Icons.Outlined.ScreenRotation, stringResource(R.string.geometry_swap_ratio)) }
                IconToggleButton(checked = showsGrid, onCheckedChange = { onGrid() }, enabled = enabled,
                    modifier = Modifier.testTag("geometry.grid")) { Icon(Icons.Outlined.GridOn, stringResource(R.string.geometry_grid)) }
            }
            Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = { onChange(value.rotated(false), false) }, enabled = enabled,
                    modifier = Modifier.testTag("geometry.rotate-left")) { Icon(Icons.Outlined.RotateLeft, stringResource(R.string.geometry_rotate_left)) }
                IconButton(onClick = { onChange(value.rotated(true), false) }, enabled = enabled,
                    modifier = Modifier.testTag("geometry.rotate-right")) { Icon(Icons.Outlined.RotateRight, stringResource(R.string.geometry_rotate_right)) }
                IconToggleButton(checked = value.flipHorizontal, onCheckedChange = { onChange(value.copy(flipHorizontal = it), false) }, enabled = enabled,
                    modifier = Modifier.testTag("geometry.flip-horizontal")) { Icon(Icons.Outlined.Flip, stringResource(R.string.geometry_flip_horizontal)) }
                IconToggleButton(checked = value.flipVertical, onCheckedChange = { onChange(value.copy(flipVertical = it), false) }, enabled = enabled,
                    modifier = Modifier.testTag("geometry.flip-vertical")) { Icon(Icons.Outlined.FlipCameraAndroid, stringResource(R.string.geometry_flip_vertical)) }
                Spacer(Modifier.weight(1f))
                ToolIcon(Icons.Outlined.RestartAlt, R.string.geometry_reset, enabled) {
                    if (onReset != null) onReset() else { onRatioChange(GeometryRatio.FREE, portrait); onChange(GeometrySettings(), false) }
                }
            }
            NumericControl(R.string.geometry_straighten, value.straightenDegrees, -45f..45f, "°", enabled,
                { next, dragging -> onChange(value.copy(straightenDegrees = next), dragging) },
                { onChange(value.copy(straightenDegrees = 0f), false) })
            TextButton(onClick = { dimensions = !dimensions }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("geometry.dimensions")) {
                Text(stringResource(R.string.geometry_position_size), Modifier.weight(1f))
                Icon(if (dimensions) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, null)
            }
            if (dimensions) Column(Modifier.padding(horizontal = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    NumericControl(R.string.geometry_crop_x, value.cropX * 100f, 0f..((1f - value.cropWidth) * 100f).coerceAtLeast(0f), "%", enabled,
                        { next, _ -> onChange(value.copy(cropX = next / 100f), false) }, { onChange(value.copy(cropX = 0f), false) }, compactNumber = true, modifier = Modifier.weight(1f))
                    NumericControl(R.string.geometry_crop_y, value.cropY * 100f, 0f..((1f - value.cropHeight) * 100f).coerceAtLeast(0f), "%", enabled,
                        { next, _ -> onChange(value.copy(cropY = next / 100f), false) }, { onChange(value.copy(cropY = 0f), false) }, compactNumber = true, modifier = Modifier.weight(1f))
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    NumericControl(R.string.geometry_crop_width, value.cropWidth * 100f, minOf(.1f, maximumWidth * 100f)..maximumWidth * 100f, "%", enabled,
                        { next, _ -> dimension(true, next) }, { dimension(true, 100f) }, defaultValue = 100f, resetEnabled = maximumWidth >= 1f,
                        compactNumber = true, modifier = Modifier.weight(1f))
                    NumericControl(R.string.geometry_crop_height, value.cropHeight * 100f, minOf(.1f, maximumHeight * 100f)..maximumHeight * 100f, "%", enabled,
                        { next, _ -> dimension(false, next) }, { dimension(false, 100f) }, defaultValue = 100f, resetEnabled = maximumHeight >= 1f,
                        compactNumber = true, modifier = Modifier.weight(1f))
                }
            }
        }
    }
}
