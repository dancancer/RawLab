package com.rawlab.android.editor.controls

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.rawlab.android.R
import com.rawlab.android.settings.BwMixerSettings
import com.rawlab.android.settings.BwMixerWeights

private data class BwChannelDescriptor(
    val titleRes: Int,
    val getWeight: (BwMixerWeights) -> Float,
    val setWeight: (BwMixerWeights, Float) -> BwMixerWeights,
)

private val bwChannels = listOf(
    BwChannelDescriptor(R.string.hsl_red, { it.red }, { w, v -> w.copy(red = v) }),
    BwChannelDescriptor(R.string.hsl_orange, { it.orange }, { w, v -> w.copy(orange = v) }),
    BwChannelDescriptor(R.string.hsl_yellow, { it.yellow }, { w, v -> w.copy(yellow = v) }),
    BwChannelDescriptor(R.string.hsl_green, { it.green }, { w, v -> w.copy(green = v) }),
    BwChannelDescriptor(R.string.hsl_aqua, { it.aqua }, { w, v -> w.copy(aqua = v) }),
    BwChannelDescriptor(R.string.hsl_blue, { it.blue }, { w, v -> w.copy(blue = v) }),
    BwChannelDescriptor(R.string.hsl_purple, { it.purple }, { w, v -> w.copy(purple = v) }),
    BwChannelDescriptor(R.string.hsl_magenta, { it.magenta }, { w, v -> w.copy(magenta = v) }),
)

@Composable
internal fun BwMixerControls(
    settings: BwMixerSettings,
    enabled: Boolean,
    onEdit: (BwMixerSettings, Boolean) -> Unit,
) {
    val sliderEnabled = enabled && settings.enabled
    Column(Modifier.fillMaxWidth()) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(stringResource(R.string.bw_enable_toggle), Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
            Switch(
                checked = settings.enabled,
                onCheckedChange = { checked -> onEdit(settings.copy(enabled = checked), false) },
                enabled = enabled,
                modifier = Modifier.testTag("bw-mixer-enabled"),
            )
        }
        Text(
            text = stringResource(R.string.bw_mixer),
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
        )
        bwChannels.forEach { channel ->
            NumericControl(
                channel.titleRes,
                channel.getWeight(settings.mixer),
                -100f..100f,
                "",
                sliderEnabled,
                { v, d -> onEdit(settings.copy(mixer = channel.setWeight(settings.mixer, v.coerceIn(-100f, 100f))), d) },
                { onEdit(settings.copy(mixer = channel.setWeight(settings.mixer, 0f)), false) },
            )
        }
    }
}
