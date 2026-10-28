package com.rawlab.android.editor.panels

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.RestartAlt
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.rawlab.android.R
import com.rawlab.android.editor.controls.NumericControl
import com.rawlab.android.settings.PhotoEffectParameter
import com.rawlab.android.settings.PhotoEffectsSettings
import com.rawlab.android.ui.ToolIcon

@Composable
internal fun PhotoEffectsControls(
    value: PhotoEffectsSettings,
    vignette: Boolean,
    enabled: Boolean, onReset: (() -> Unit)? = null,
    onChange: (PhotoEffectsSettings, Boolean) -> Unit,
) {
    val amount = if (vignette) PhotoEffectParameter.VIGNETTE_AMOUNT else PhotoEffectParameter.GRAIN_AMOUNT
    var advanced by rememberSaveable(vignette) { mutableStateOf(!vignette) }
    val parameters = PhotoEffectParameter.entries.filter {
        it.isVignette == vignette && (!vignette || advanced || it == amount)
    }
    val groupTitle = if (vignette) R.string.vignette else R.string.grain
    val resetLabel = stringResource(R.string.reset_effect, stringResource(groupTitle))
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(stringResource(groupTitle), Modifier.weight(1f), style = MaterialTheme.typography.labelLarge)
            if (vignette) TextButton(
                onClick = { advanced = !advanced },
                modifier = Modifier.testTag("effects.vignette.advanced"),
            ) {
                Text(stringResource(if (advanced) R.string.collapse_vignette else R.string.expand_vignette))
            }
            if (!vignette || advanced) ToolIcon(Icons.Outlined.RestartAlt, resetLabel,
                enabled = enabled && !value.isEffectDefault(vignette)) {
                    onReset?.invoke() ?: onChange(value.resetEffects(vignette), false)
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
                showReset = !vignette || advanced,
            )
            if (parameter == PhotoEffectParameter.VIGNETTE_HIGHLIGHTS && value.vignetteAmount >= 0f)
                Text(stringResource(R.string.vignette_highlights_unavailable), Modifier.padding(horizontal = 16.dp),
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
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
