package com.rawlab.android.editor.controls

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.rawlab.android.R
import com.rawlab.android.adjustments.AdjustmentFieldSpec
import com.rawlab.android.editor.inspection.InspectionBitmap
import com.rawlab.android.settings.PointColorSettings
import com.rawlab.android.settings.PointColorSwatch

data class PointColorProbeActions(
    val enabled: Boolean = false,
    val setEnabled: (Boolean) -> Unit = {},
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
internal fun PointColorCanvasControls(probe: PointColorProbeActions, modifier: Modifier = Modifier) {
    Surface(
        modifier.widthIn(max = 560.dp).testTag("point-color-eyedropper-canvas"),
        shape = MaterialTheme.shapes.medium,
        color = MaterialTheme.colorScheme.surface.copy(alpha = .95f),
    ) {
        Column(Modifier.padding(10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(stringResource(R.string.point_color_eyedropper), style = MaterialTheme.typography.titleSmall)
            TextButton(
                onClick = { probe.setEnabled(false) },
                modifier = Modifier.heightIn(min = 48.dp).testTag("point-color-eyedropper-exit"),
            ) {
                Text(stringResource(R.string.cancel))
            }
        }
    }
}

@Composable
internal fun PointColorControls(
    settings: PointColorSettings,
    enabled: Boolean,
    selectedIndex: Int,
    onSelectSwatch: (Int) -> Unit,
    probe: PointColorProbeActions,
    onEdit: (PointColorSettings, Boolean) -> Unit,
) {
    val maxSwatches = AdjustmentFieldSpec.SubFields.PointColor.maxSwatches
    val activeIndex = if (settings.swatches.isEmpty()) null else selectedIndex.coerceIn(0, settings.swatches.lastIndex)

    fun updateSwatch(index: Int, updated: PointColorSwatch, dragging: Boolean) {
        if (index !in settings.swatches.indices) return
        val next = settings.swatches.toMutableList()
        next[index] = updated
        onEdit(PointColorSettings(next), dragging)
    }

    Column(Modifier.fillMaxWidth()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            FilterChip(
                selected = probe.enabled,
                onClick = { probe.setEnabled(!probe.enabled) },
                enabled = enabled,
                label = { Text(stringResource(R.string.point_color_eyedropper)) },
                modifier = Modifier.heightIn(min = 48.dp).testTag("point-color-eyedropper"),
            )
            OutlinedButton(
                onClick = {
                    probe.setEnabled(false)
                    if (settings.swatches.size < maxSwatches) {
                        val next = settings.swatches + PointColorSwatch(srcHue = 25f, srcSaturation = 0.5f, srcLuminance = 0.5f)
                        onEdit(PointColorSettings(next), false)
                        onSelectSwatch(next.lastIndex)
                    }
                },
                enabled = enabled && settings.swatches.size < maxSwatches,
                modifier = Modifier.heightIn(min = 48.dp).testTag("point-color-add"),
            ) {
                Icon(Icons.Outlined.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(4.dp))
                Text(stringResource(R.string.point_color_add_swatch))
            }
            Spacer(Modifier.weight(1f))
            Text("${settings.swatches.size}/$maxSwatches", style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (activeIndex != null) {
                IconButton(
                    onClick = {
                        probe.setEnabled(false)
                        val next = settings.swatches.toMutableList().apply { removeAt(activeIndex) }
                        onEdit(PointColorSettings(next), false)
                        onSelectSwatch(if (next.isEmpty()) 0 else activeIndex.coerceAtMost(next.lastIndex))
                    },
                    enabled = enabled,
                    modifier = Modifier.size(48.dp).testTag("point-color-delete"),
                ) {
                    Icon(Icons.Outlined.Delete, contentDescription = stringResource(R.string.preset_delete))
                }
            }
        }
        if (settings.swatches.isNotEmpty()) {
            val swatchLabel = stringResource(R.string.point_color_swatch)
            LazyRow(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                itemsIndexed(settings.swatches) { index, swatch ->
                    val preview = InspectionBitmap.pointColorPreviewSwatch(swatch)
                    val chipColor = preview?.shiftedColor ?: Color.Gray
                    val selected = index == activeIndex
                    Box(
                        Modifier
                            .size(48.dp)
                            .clickable(enabled = enabled) { onSelectSwatch(index) }
                            .semantics { contentDescription = "$swatchLabel ${index + 1}" }
                            .testTag("point-color-swatch-$index"),
                        contentAlignment = Alignment.Center,
                    ) {
                        Box(
                            Modifier
                                .size(30.dp)
                                .alpha(if (swatch.enabled) 1f else 0.35f)
                                .clip(CircleShape)
                                .background(chipColor)
                                .border(if (selected) 2.dp else 1.dp,
                                    if (selected) MaterialTheme.colorScheme.primary else Color.White.copy(alpha = 0.4f),
                                    CircleShape),
                        )
                    }
                }
            }
        }
        if (activeIndex != null) {
            val swatch = settings.swatches[activeIndex]
            val preview = InspectionBitmap.pointColorPreviewSwatch(swatch)
            val beforeColor = preview?.srcColor ?: Color.Gray
            val afterColor = preview?.shiftedColor ?: Color.Gray
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Surface(
                    shape = RoundedCornerShape(6.dp),
                    border = BorderStroke(1.dp, Color.White.copy(alpha = 0.25f)),
                    modifier = Modifier.testTag("point-color-preview"),
                ) {
                    Row {
                        Box(Modifier.width(34.dp).height(22.dp).background(beforeColor))
                        Box(Modifier.width(34.dp).height(22.dp).background(afterColor))
                    }
                }
                Spacer(Modifier.weight(1f))
                Switch(
                    checked = swatch.enabled,
                    onCheckedChange = { checked -> updateSwatch(activeIndex, swatch.copy(enabled = checked), false) },
                    enabled = enabled,
                    modifier = Modifier.testTag("point-color-swatch-enabled"),
                )
            }
            val sliderEnabled = enabled && swatch.enabled
            NumericControl(R.string.point_color_hue_shift, swatch.hueShift, -100f..100f, "", sliderEnabled,
                { v, d -> updateSwatch(activeIndex, swatch.copy(hueShift = v.coerceIn(-100f, 100f)), d) },
                { updateSwatch(activeIndex, swatch.copy(hueShift = 0f), false) })
            NumericControl(R.string.point_color_saturation_shift, swatch.saturationShift, -100f..100f, "", sliderEnabled,
                { v, d -> updateSwatch(activeIndex, swatch.copy(saturationShift = v.coerceIn(-100f, 100f)), d) },
                { updateSwatch(activeIndex, swatch.copy(saturationShift = 0f), false) })
            NumericControl(R.string.point_color_luminance_shift, swatch.luminanceShift, -100f..100f, "", sliderEnabled,
                { v, d -> updateSwatch(activeIndex, swatch.copy(luminanceShift = v.coerceIn(-100f, 100f)), d) },
                { updateSwatch(activeIndex, swatch.copy(luminanceShift = 0f), false) })
            NumericControl(R.string.point_color_variance, swatch.variance, -100f..100f, "", sliderEnabled,
                { v, d -> updateSwatch(activeIndex, swatch.copy(variance = v.coerceIn(-100f, 100f)), d) },
                { updateSwatch(activeIndex, swatch.copy(variance = 0f), false) })
            NumericControl(R.string.point_color_range, swatch.range, 0f..100f, "", sliderEnabled,
                { v, d -> updateSwatch(activeIndex, swatch.copy(range = v.coerceIn(0f, 100f)), d) },
                { updateSwatch(activeIndex, swatch.copy(range = 50f), false) }, defaultValue = 50f)
            NumericControl(R.string.point_color_hue_range, swatch.hueRange, 0f..100f, "", sliderEnabled,
                { v, d -> updateSwatch(activeIndex, swatch.copy(hueRange = v.coerceIn(0f, 100f)), d) },
                { updateSwatch(activeIndex, swatch.copy(hueRange = 50f), false) }, defaultValue = 50f)
            NumericControl(R.string.point_color_sat_range, swatch.satRange, 0f..100f, "", sliderEnabled,
                { v, d -> updateSwatch(activeIndex, swatch.copy(satRange = v.coerceIn(0f, 100f)), d) },
                { updateSwatch(activeIndex, swatch.copy(satRange = 50f), false) }, defaultValue = 50f)
            NumericControl(R.string.point_color_lum_range, swatch.lumRange, 0f..100f, "", sliderEnabled,
                { v, d -> updateSwatch(activeIndex, swatch.copy(lumRange = v.coerceIn(0f, 100f)), d) },
                { updateSwatch(activeIndex, swatch.copy(lumRange = 50f), false) }, defaultValue = 50f)
        }
    }
}
