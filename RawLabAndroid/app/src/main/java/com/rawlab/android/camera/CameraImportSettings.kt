package com.rawlab.android.camera

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.rawlab.android.R

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CameraImportSettings(destination: CameraImportDestination, onSave: (CameraImportDestination) -> Unit,
    onDismiss: () -> Unit) {
    var directory by rememberSaveable { mutableStateOf(destination.directory) }
    var grouping by rememberSaveable { mutableStateOf(destination.grouping.name) }
    val candidate = runCatching { CameraImportDestination(directory, CameraDirectoryGrouping.valueOf(grouping)) }.getOrNull()
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxHeight(.9f).imePadding().padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(stringResource(R.string.camera_save_location_title), style = MaterialTheme.typography.headlineSmall)
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(value = directory, onValueChange = { directory = it }, singleLine = true,
                    label = { Text(stringResource(R.string.camera_directory)) }, isError = candidate == null,
                    supportingText = { Text(stringResource(if (candidate == null) R.string.camera_directory_invalid else R.string.camera_directory_hint)) },
                    modifier = Modifier.fillMaxWidth().testTag("camera-directory-input"))
                Text(stringResource(R.string.camera_directory_grouping), style = MaterialTheme.typography.titleSmall)
                for (option in CameraDirectoryGrouping.entries) {
                    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).selectable(grouping == option.name,
                        role = Role.RadioButton, onClick = { grouping = option.name }).testTag("camera-group-${option.name}"),
                        verticalAlignment = Alignment.CenterVertically) {
                        RadioButton(grouping == option.name, onClick = null)
                        Text(stringResource(groupingLabel(option)))
                    }
                }
                if (candidate != null) {
                    Text(stringResource(R.string.camera_path_example), style = MaterialTheme.typography.titleSmall)
                    Text(candidate.relativePath(CameraCaptureDate.parse("2026:10:22 12:00:00", null)),
                        style = MaterialTheme.typography.bodyMedium)
                }
                if (grouping != CameraDirectoryGrouping.NONE.name) Text(stringResource(R.string.camera_unknown_date_hint),
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(stringResource(R.string.camera_settings_future), style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Button(onClick = { candidate?.let(onSave) }, enabled = candidate != null,
                modifier = Modifier.fillMaxWidth().testTag("camera-destination-save")) { Text(stringResource(R.string.camera_save_settings)) }
            TextButton(onClick = onDismiss, modifier = Modifier.fillMaxWidth().testTag("camera-destination-cancel")) { Text(stringResource(R.string.cancel)) }
        }
    }
}

internal fun groupingLabel(grouping: CameraDirectoryGrouping): Int = when (grouping) {
    CameraDirectoryGrouping.NONE -> R.string.camera_group_none
    CameraDirectoryGrouping.CAPTURE_DAY -> R.string.camera_group_day
    CameraDirectoryGrouping.CAPTURE_MONTH -> R.string.camera_group_month
}

@Composable
internal fun destinationDescription(destination: CameraImportDestination): String {
    val suffix = if (destination.grouping == CameraDirectoryGrouping.NONE) ""
        else "${stringResource(groupingLabel(destination.grouping))}/"
    return "Pictures/${destination.directory}/$suffix"
}
