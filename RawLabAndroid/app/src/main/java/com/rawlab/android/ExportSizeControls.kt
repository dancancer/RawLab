package com.rawlab.android

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowDropDown
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp

@Composable
internal fun ExportSizeControls(
    selected: ExportSizeChoice,
    customText: String,
    onSelected: (ExportSizeChoice) -> Unit,
    onCustomText: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val customValue = ExportSize.parseCustom(customText)
    var menu by remember { mutableStateOf(false) }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.output_size), style = androidx.compose.material3.MaterialTheme.typography.titleSmall)
            Spacer(Modifier.weight(1f))
            Box {
                TextButton(onClick = { menu = true }) {
                    Text(exportSizeLabel(selected))
                    Icon(Icons.Outlined.ArrowDropDown, contentDescription = null)
                }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    ExportSizeChoice.entries.forEach { choice ->
                        DropdownMenuItem(text = { Text(exportSizeLabel(choice)) }, onClick = {
                            menu = false
                            onSelected(choice)
                        })
                    }
                }
            }
        }
        if (selected == ExportSizeChoice.CUSTOM) {
            OutlinedTextField(
                value = customText,
                onValueChange = onCustomText,
                modifier = Modifier.fillMaxWidth(),
                label = { Text(stringResource(R.string.output_long_edge)) },
                supportingText = {
                    Text(if (customText.isBlank() || customValue == null) stringResource(R.string.output_size_error)
                    else stringResource(R.string.output_size_range))
                },
                isError = customText.isNotBlank() && customValue == null,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                singleLine = true,
            )
        }
    }
}

@Composable
private fun exportSizeLabel(choice: ExportSizeChoice): String = when (choice) {
    ExportSizeChoice.ORIGINAL -> stringResource(R.string.output_original_size)
    ExportSizeChoice.CUSTOM -> stringResource(R.string.output_custom_size)
    else -> "${choice.longEdge} px"
}
