package com.rawlab.android

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.RestartAlt
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt

@Composable
internal fun DenoiseControls(value: DenoiseSettings, enabled: Boolean,
    onChange: (DenoiseSettings, Boolean) -> Unit) {
    var menu by remember { mutableStateOf(false) }
    fun title(preset: DenoisePreset) = when (preset) {
        DenoisePreset.DETAIL -> R.string.denoise_detail
        DenoisePreset.CLEAN -> R.string.denoise_clean
        DenoisePreset.CUSTOM -> R.string.denoise_custom
    }
    Column {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.denoise), style = MaterialTheme.typography.labelLarge)
            Switch(value.enabled, { onChange(value.copy(enabled = it), false) }, enabled = enabled)
            Spacer(Modifier.weight(1f))
            Box {
                TextButton(onClick = { menu = true }, enabled = enabled) { Text(stringResource(title(value.preset))) }
                DropdownMenu(menu, { menu = false }) {
                    listOf(DenoisePreset.DETAIL, DenoisePreset.CLEAN).forEach { preset ->
                        DropdownMenuItem(text = { Text(stringResource(title(preset))) },
                            onClick = { menu = false; onChange(value.withPreset(preset), false) })
                    }
                }
            }
            ToolIcon(Icons.Outlined.RestartAlt, R.string.reset_value, enabled) { onChange(DenoiseSettings(), false) }
        }
        val active = enabled && value.enabled
        NumericControl(R.string.denoise_luma, value.luma, 0f..100f, "", active,
            { number, dragging -> onChange(value.copy(luma = number.roundToInt().toFloat()), dragging) },
            { onChange(value.copy(luma = 0f), false) })
        NumericControl(R.string.denoise_chroma, value.chroma, 0f..100f, "", active,
            { number, dragging -> onChange(value.copy(chroma = number.roundToInt().toFloat()), dragging) },
            { onChange(value.copy(chroma = 46f), false) })
        NumericControl(R.string.denoise_coarse, value.coarse, 0f..100f, "", active,
            { number, dragging -> onChange(value.copy(coarse = number.roundToInt().toFloat()), dragging) },
            { onChange(value.copy(coarse = 50f), false) })
    }
}
