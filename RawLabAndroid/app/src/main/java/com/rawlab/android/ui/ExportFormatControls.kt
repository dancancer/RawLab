package com.rawlab.android.ui

import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.rawlab.android.R
import com.rawlab.android.format.ExportFormat

@Composable
internal fun ExportFormatControls(selected: ExportFormat, onSelect: (ExportFormat) -> Unit,
    modifier: Modifier = Modifier, enabled: (ExportFormat) -> Boolean = { true }) {
    Column(modifier.fillMaxWidth().selectableGroup(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        ExportFormat.entries.forEach { format ->
            val title = when (format) { ExportFormat.JPEG -> R.string.jpeg; ExportFormat.PNG -> R.string.png; ExportFormat.DNG -> R.string.dng }
            val description = when (format) {
                ExportFormat.JPEG -> R.string.jpeg_description
                ExportFormat.PNG -> R.string.png_description
                ExportFormat.DNG -> R.string.dng_description
            }
            val allowed = enabled(format)
            Row(Modifier.fillMaxWidth().heightIn(min = 80.dp)
                .border(1.dp, if (format == selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline,
                    RoundedCornerShape(6.dp))
                .selectable(format == selected, enabled = allowed, role = Role.RadioButton, onClick = { onSelect(format) })
                .alpha(if (allowed) 1f else .5f)
                .testTag("export-format-${format.name}").padding(12.dp), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                RadioButton(selected == format, onClick = null, enabled = allowed)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(stringResource(title), style = MaterialTheme.typography.titleSmall)
                    Text(stringResource(description), style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}
