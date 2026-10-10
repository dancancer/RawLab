package com.rawlab.android

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.RestartAlt
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp

@Composable
internal fun PhotoEffectsControls(
    value: PhotoEffectsSettings,
    vignette: Boolean,
    enabled: Boolean,
    onChange: (PhotoEffectsSettings, Boolean) -> Unit,
) {
    val parameters = PhotoEffectParameter.entries.filter { it.isVignette == vignette }
    val amount = if (vignette) PhotoEffectParameter.VIGNETTE_AMOUNT else PhotoEffectParameter.GRAIN_AMOUNT
    val groupTitle = if (vignette) R.string.vignette else R.string.grain
    val resetLabel = if (vignette) R.string.reset_vignette else R.string.reset_grain
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(stringResource(groupTitle), style = MaterialTheme.typography.labelLarge)
            ToolIcon(Icons.Outlined.RestartAlt, resetLabel, enabled = enabled && !value.isEffectDefault(vignette)) {
                onChange(value.resetEffects(vignette), false)
            }
        }
        parameters.forEach { parameter ->
            val active = enabled && when {
                parameter == amount -> true
                parameter == PhotoEffectParameter.VIGNETTE_HIGHLIGHTS -> value.vignetteAmount < 0f
                else -> value.value(amount) != 0f
            }
            NumericControl(
                label = parameter.label,
                value = value.value(parameter),
                range = parameter.range,
                unit = "",
                enabled = active,
                onValue = { next, dragging -> onChange(value.withEffect(parameter, next), dragging) },
                onReset = { onChange(value.withEffect(parameter, parameter.defaultValue), false) },
                clampInput = true,
            )
        }
    }
}

private val PhotoEffectParameter.label: Int
    get() = when (this) {
        PhotoEffectParameter.VIGNETTE_AMOUNT -> R.string.vignette_amount
        PhotoEffectParameter.VIGNETTE_MIDPOINT -> R.string.vignette_midpoint
        PhotoEffectParameter.VIGNETTE_ROUNDNESS -> R.string.vignette_roundness
        PhotoEffectParameter.VIGNETTE_FEATHER -> R.string.vignette_feather
        PhotoEffectParameter.VIGNETTE_HIGHLIGHTS -> R.string.vignette_highlights
        PhotoEffectParameter.GRAIN_AMOUNT -> R.string.grain_amount
        PhotoEffectParameter.GRAIN_SIZE -> R.string.grain_size
        PhotoEffectParameter.GRAIN_ROUGHNESS -> R.string.grain_roughness
    }
