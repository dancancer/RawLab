package com.rawlab.android.editor.panels

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.RestartAlt
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.rawlab.android.R
import com.rawlab.android.engine.LensCandidate
import com.rawlab.android.engine.LensInfo
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.settings.LensSettings

@Composable
fun LensControls(value: LensSettings, info: LensInfo?, enabled: Boolean, loading: Boolean = false, change: (LensSettings) -> Unit) {
    var choosing by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SingleChoiceSegmentedButtonRow(Modifier.weight(1f)) {
                listOf(R.string.lens_automatic, R.string.lens_manual).forEachIndexed { index, title ->
                    val titleText = stringResource(title)
                    SegmentedButton(selected = value.manual == (index == 1),
                        onClick = { change(value.copy(manual = index == 1)) }, enabled = enabled,
                        shape = SegmentedButtonDefaults.itemShape(index, 2),
                        modifier = Modifier.semantics {
                            role = Role.RadioButton
                            contentDescription = titleText
                        }) { Text(titleText) }
                }
            }
            IconButton(onClick = { change(LensSettings()) }, enabled = enabled && value != LensSettings(),
                modifier = Modifier.testTag("lens.reset")) { Icon(Icons.Outlined.RestartAlt, stringResource(R.string.lens_reset)) }
        }
        val candidate = if (value.manual) info?.candidates?.firstOrNull { it.id == value.profileId }
            else info?.candidates?.firstOrNull { it.title == info.selectedLens }
                ?: info?.candidates?.singleOrNull { it.isMatch }
        LensToggle(R.string.lens_distortion, value.distortion, enabled && candidate?.hasDistortion == true, "lens.distortion") { change(value.copy(distortion = it)) }
        LensToggle(R.string.lens_tca, value.tca, enabled && candidate?.hasTca == true, "lens.tca") { change(value.copy(tca = it)) }
        LensToggle(R.string.lens_auto_crop, value.autoCrop, enabled, "lens.crop") { change(value.copy(autoCrop = it)) }
        val selected = if (value.manual) info?.candidates?.firstOrNull { it.id == value.profileId }?.title
            else info?.selectedLens?.takeIf { it.isNotEmpty() }
        TextButton(onClick = { choosing = true }, modifier = Modifier.fillMaxWidth().testTag("lens.profile"),
            enabled = enabled && value.manual && info?.candidates?.isNotEmpty() == true) {
            Text(selected ?: stringResource(if (value.manual) R.string.lens_choose else R.string.lens_unmatched))
        }
        Text(if (loading) stringResource(R.string.rendering) else info?.message ?: stringResource(R.string.lens_info_not_ready), style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.testTag("lens.status"))
        if (candidate == null || !candidate.hasDistortion || !candidate.hasTca) Text(stringResource(R.string.lens_no_calibration),
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        info?.detectedLens?.takeIf { it.isNotEmpty() }?.let {
            Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        info?.cropPercent?.let { Text(AppStrings.format(R.string.lens_crop_percent, it), style = MaterialTheme.typography.bodySmall) }
    }
    if (choosing) LensChooser(info?.candidates.orEmpty(), value.profileId, { choosing = false }) {
        change(value.copy(manual = true, profileId = it.id)); choosing = false
    }
}

@Composable
private fun LensToggle(title: Int, checked: Boolean, enabled: Boolean, tag: String, change: (Boolean) -> Unit) {
    val label = stringResource(title)
    val stateLabel = stringResource(if (checked) R.string.message_on else R.string.disabled)
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
        Switch(checked = checked, onCheckedChange = change, enabled = enabled,
            modifier = Modifier.testTag(tag).semantics {
                contentDescription = label
                stateDescription = stateLabel
            })
    }
}

@Composable
private fun LensChooser(candidates: List<LensCandidate>, selected: String?, dismiss: () -> Unit, select: (LensCandidate) -> Unit) {
    var search by remember { mutableStateOf("") }
    val filtered = remember(candidates, search) {
        candidates.filter { it.title.contains(search, ignoreCase = true) }
            .sortedWith(compareByDescending<LensCandidate> { it.isMatch }.thenBy { it.title })
    }
    AlertDialog(onDismissRequest = dismiss, title = { Text(stringResource(R.string.lens_choose_profile)) }, confirmButton = {
        TextButton(onClick = dismiss) { Text(stringResource(R.string.cancel)) }
    }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(search, { search = it }, singleLine = true, label = { Text(stringResource(R.string.lens_search)) },
                modifier = Modifier.fillMaxWidth().testTag("lens.search"))
            if (filtered.isEmpty()) Text(stringResource(R.string.lens_none_found))
            LazyColumn(Modifier.fillMaxWidth().heightIn(max = 320.dp)) {
                items(filtered, key = { it.id }) { candidate ->
                    ListItem(modifier = Modifier.clickable { select(candidate) }.testTag("lens.candidate"),
                        headlineContent = { Text(candidate.title) }, supportingContent = {
                            Text(listOfNotNull(
                                stringResource(R.string.lens_distortion_short).takeIf { candidate.hasDistortion },
                                stringResource(R.string.lens_tca).takeIf { candidate.hasTca },
                                stringResource(R.string.lens_metadata_match).takeIf { candidate.isMatch },
                            ).joinToString(" / "))
                        }, trailingContent = { RadioButton(selected == candidate.id, onClick = { select(candidate) }) })
                }
            }
        }
    })
}
