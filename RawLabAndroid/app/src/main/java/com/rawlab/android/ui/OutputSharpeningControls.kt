package com.rawlab.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowDropDown
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.rawlab.android.R
import com.rawlab.android.format.OutputSharpening

@Composable
internal fun OutputSharpeningControls(
    selected: OutputSharpening,
    onSelected: (OutputSharpening) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    val display = if (enabled) selected else OutputSharpening.OFF
    var menu by remember { mutableStateOf(false) }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Column(Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.export_output_sharpening), style = MaterialTheme.typography.titleSmall)
            Box {
                OutlinedButton(
                    onClick = { menu = true },
                    enabled = enabled,
                    modifier = Modifier.fillMaxWidth().testTag("export-sharpening"),
                ) {
                    Text(outputSharpeningLabel(display), Modifier.weight(1f))
                    Icon(Icons.Outlined.ArrowDropDown, contentDescription = null)
                }
                DropdownMenu(expanded = menu && enabled, onDismissRequest = { menu = false }) {
                    OutputSharpening.entries.forEach { level ->
                        DropdownMenuItem(
                            modifier = Modifier.testTag("export-sharpening-${level.wireValue}"),
                            text = { Text(outputSharpeningLabel(level)) },
                            onClick = {
                                menu = false
                                onSelected(level)
                            },
                        )
                    }
                }
            }
        }
    }
}

@Composable
internal fun outputSharpeningLabel(level: OutputSharpening): String = when (level) {
    OutputSharpening.OFF -> stringResource(R.string.output_sharpening_off)
    OutputSharpening.LOW -> stringResource(R.string.output_sharpening_low)
    OutputSharpening.STANDARD -> stringResource(R.string.output_sharpening_standard)
    OutputSharpening.HIGH -> stringResource(R.string.output_sharpening_high)
}
