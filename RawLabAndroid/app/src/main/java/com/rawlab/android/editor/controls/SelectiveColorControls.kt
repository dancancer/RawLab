package com.rawlab.android.editor.controls

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.rawlab.android.R
import com.rawlab.android.settings.SelectiveColorBand
import com.rawlab.android.settings.SelectiveColorBands
import com.rawlab.android.settings.SelectiveColorMethod
import com.rawlab.android.settings.SelectiveColorSettings

private data class SelectiveBandDescriptor(
    val id: String,
    val titleRes: Int,
    val color: Color,
    val getBand: (SelectiveColorBands) -> SelectiveColorBand,
    val setBand: (SelectiveColorBands, SelectiveColorBand) -> SelectiveColorBands,
)

private val selectiveBands = listOf(
    SelectiveBandDescriptor("reds", R.string.selective_band_reds, Color.Red, { it.reds }, { b, v -> b.copy(reds = v) }),
    SelectiveBandDescriptor("yellows", R.string.selective_band_yellows, Color.Yellow, { it.yellows }, { b, v -> b.copy(yellows = v) }),
    SelectiveBandDescriptor("greens", R.string.selective_band_greens, Color.Green, { it.greens }, { b, v -> b.copy(greens = v) }),
    SelectiveBandDescriptor("cyans", R.string.selective_band_cyans, Color.Cyan, { it.cyans }, { b, v -> b.copy(cyans = v) }),
    SelectiveBandDescriptor("blues", R.string.selective_band_blues, Color.Blue, { it.blues }, { b, v -> b.copy(blues = v) }),
    SelectiveBandDescriptor("magentas", R.string.selective_band_magentas, Color(0xFFE633B3), { it.magentas }, { b, v -> b.copy(magentas = v) }),
    SelectiveBandDescriptor("whites", R.string.selective_band_whites, Color.White, { it.whites }, { b, v -> b.copy(whites = v) }),
    SelectiveBandDescriptor("neutrals", R.string.selective_band_neutrals, Color.Gray, { it.neutrals }, { b, v -> b.copy(neutrals = v) }),
    SelectiveBandDescriptor("blacks", R.string.selective_band_blacks, Color(0xFF262626), { it.blacks }, { b, v -> b.copy(blacks = v) }),
)

@Composable
internal fun SelectiveColorControls(
    settings: SelectiveColorSettings,
    enabled: Boolean,
    selectedBandIndex: Int,
    onSelectBand: (Int) -> Unit,
    onEdit: (SelectiveColorSettings, Boolean) -> Unit,
) {
    val safeIndex = selectedBandIndex.coerceIn(0, selectiveBands.lastIndex)
    val descriptor = selectiveBands[safeIndex]
    val band = descriptor.getBand(settings.bands)

    fun updateBand(updated: SelectiveColorBand, dragging: Boolean) {
        onEdit(settings.copy(bands = descriptor.setBand(settings.bands, updated)), dragging)
    }

    Column(Modifier.fillMaxWidth()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 2.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            FilterChip(
                selected = settings.method == SelectiveColorMethod.RELATIVE,
                onClick = { onEdit(settings.copy(method = SelectiveColorMethod.RELATIVE), false) },
                enabled = enabled,
                label = { Text(stringResource(R.string.selective_color_relative)) },
                modifier = Modifier.heightIn(min = 48.dp).testTag("selective-color-relative"),
            )
            FilterChip(
                selected = settings.method == SelectiveColorMethod.ABSOLUTE,
                onClick = { onEdit(settings.copy(method = SelectiveColorMethod.ABSOLUTE), false) },
                enabled = enabled,
                label = { Text(stringResource(R.string.selective_color_absolute)) },
                modifier = Modifier.heightIn(min = 48.dp).testTag("selective-color-absolute"),
            )
        }
        LazyRow(
            Modifier.fillMaxWidth(),
            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 2.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            itemsIndexed(selectiveBands) { index, item ->
                val value = item.getBand(settings.bands)
                val selected = index == safeIndex
                TextButton(
                    onClick = { onSelectBand(index) },
                    enabled = enabled,
                    modifier = Modifier.heightIn(min = 48.dp).testTag("selective-band-${item.id}"),
                ) {
                    Box(
                        Modifier
                            .size(10.dp)
                            .clip(CircleShape)
                            .background(item.color)
                            .border(0.8.dp, Color.White.copy(alpha = 0.35f), CircleShape),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        stringResource(item.titleRes),
                        color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    if (!value.isDefault) {
                        Spacer(Modifier.width(4.dp))
                        Box(Modifier.size(4.dp).background(MaterialTheme.colorScheme.primary, CircleShape))
                    }
                }
            }
        }
        NumericControl(R.string.selective_cyan, band.cyan, -100f..100f, "", enabled,
            { v, d -> updateBand(band.copy(cyan = v.coerceIn(-100f, 100f)), d) },
            { updateBand(band.copy(cyan = 0f), false) })
        NumericControl(R.string.selective_magenta, band.magenta, -100f..100f, "", enabled,
            { v, d -> updateBand(band.copy(magenta = v.coerceIn(-100f, 100f)), d) },
            { updateBand(band.copy(magenta = 0f), false) })
        NumericControl(R.string.selective_yellow, band.yellow, -100f..100f, "", enabled,
            { v, d -> updateBand(band.copy(yellow = v.coerceIn(-100f, 100f)), d) },
            { updateBand(band.copy(yellow = 0f), false) })
        NumericControl(R.string.selective_black, band.black, -100f..100f, "", enabled,
            { v, d -> updateBand(band.copy(black = v.coerceIn(-100f, 100f)), d) },
            { updateBand(band.copy(black = 0f), false) })
    }
}
