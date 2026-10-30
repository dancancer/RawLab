package com.rawlab.android.editor.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.rawlab.android.R
import com.rawlab.android.editor.EditorViewModel
import com.rawlab.android.editor.QuickPresetPhase
import com.rawlab.android.presets.AdjustmentPreset
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun QuickPresetContent(model: EditorViewModel, libraryRevision: Int, onManage: () -> Unit,
    onRequest: (AdjustmentPresetAction) -> Unit) {
    val quick by model.quickPreset.collectAsStateWithLifecycle()
    val editor by model.state.collectAsStateWithLifecycle()
    var presets by remember { mutableStateOf(emptyList<AdjustmentPreset>()) }
    var error by remember { mutableStateOf<String?>(null) }
    var reload by remember { mutableIntStateOf(0) }
    var loaded by remember { mutableStateOf(false) }
    LaunchedEffect(libraryRevision, reload) {
        val result = withContext(Dispatchers.IO) { runCatching { model.presetStore.list() } }
        result.fold({ presets = it; error = null }, { presets = emptyList(); error = presetErrorMessage(it) })
        loaded = true
    }
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).testTag("preset.quick.root"),
        verticalArrangement = Arrangement.spacedBy(8.dp)) {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TextButton(onClick = onManage, enabled = !quick.busy, modifier = Modifier.testTag("preset.quick.manage")) {
                Text(stringResource(R.string.preset_quick_manage))
            }
            TextButton(onClick = { onRequest(AdjustmentPresetAction.Save) }, enabled = loaded && error == null && !quick.busy && editor.controlsEnabled,
                modifier = Modifier.testTag("preset.quick.create")) { Text(stringResource(R.string.preset_create)) }
        }
        quick.preset?.let { preset ->
            val status = when (quick.phase) {
                QuickPresetPhase.PREPARING -> stringResource(R.string.preset_quick_checking)
                QuickPresetPhase.COMMITTING -> stringResource(R.string.message_saving)
                QuickPresetPhase.SAVED -> stringResource(R.string.transfer_applied)
                QuickPresetPhase.UNCHANGED -> stringResource(R.string.transfer_unchanged)
                QuickPresetPhase.UNDONE -> stringResource(R.string.transfer_undone)
                else -> quick.message
            }
            status?.let { Text(preset.name + " · " + it, Modifier.testTag("preset.quick.status")) }
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                when (quick.phase) {
                    QuickPresetPhase.PREPARING -> TextButton(onClick = model::cancelQuickPreset,
                        modifier = Modifier.testTag("preset.quick.cancel")) { Text(stringResource(R.string.cancel)) }
                    QuickPresetPhase.SAVED -> TextButton(onClick = model::undoQuickPreset, enabled = editor.controlsEnabled,
                        modifier = Modifier.testTag("preset.quick.undo")) { Text(stringResource(R.string.transfer_undo)) }
                    QuickPresetPhase.FAILED, QuickPresetPhase.UNDO_FAILED -> {
                        TextButton(onClick = { if (quick.phase == QuickPresetPhase.UNDO_FAILED) model.undoQuickPreset()
                            else onRequest(AdjustmentPresetAction.Apply(preset)) }, enabled = editor.controlsEnabled,
                            modifier = Modifier.testTag("preset.quick.retry")) { Text(stringResource(R.string.retry)) }
                        TextButton(onClick = model::cancelQuickPreset, modifier = Modifier.testTag("preset.quick.cancel")) { Text(stringResource(R.string.cancel)) }
                    }
                    else -> Unit
                }
            }
        }
        if (error != null) {
            Text(error!!, Modifier.testTag("preset.quick.libraryError"))
            TextButton(onClick = { reload++ }, modifier = Modifier.testTag("preset.quick.reload")) { Text(stringResource(R.string.preset_reload)) }
        } else if (loaded && presets.isEmpty()) {
            Text(stringResource(R.string.preset_empty), Modifier.testTag("preset.quick.empty"), style = MaterialTheme.typography.titleMedium)
            Text(stringResource(R.string.preset_empty_hint), style = MaterialTheme.typography.bodySmall)
        }
        presets.forEach { preset -> key(preset.id) {
            var menu by remember { mutableStateOf(false) }
            Text(preset.name, Modifier.testTag("preset.quick.name.${preset.id}"), style = MaterialTheme.typography.titleMedium)
            Text(adjustmentSummary(preset.payload).groups.joinToString(" / ") { summaryGroupTitle(it.id) + " · " + it.fields.size },
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = { onRequest(AdjustmentPresetAction.Apply(preset)) }, enabled = !quick.busy && editor.controlsEnabled,
                    modifier = Modifier.weight(1f).heightIn(min = 48.dp).testTag("preset.quick.apply.${preset.id}")) {
                    Text(stringResource(R.string.preset_quick_apply_current))
                }
                Box {
                    IconButton(onClick = { menu = true }, enabled = !quick.busy, modifier = Modifier.testTag("preset.quick.more.${preset.id}")) {
                        Icon(Icons.Outlined.MoreVert, stringResource(R.string.preset_manage, preset.name))
                    }
                    DropdownMenu(menu, { menu = false }) {
                        DropdownMenuItem(text = { Text(stringResource(R.string.preset_quick_apply_multiple)) }, onClick = {
                            menu = false; onRequest(AdjustmentPresetAction.ApplyMultiple(preset))
                        }, modifier = Modifier.testTag("preset.quick.multiple.${preset.id}"))
                    }
                }
            }
            TransferDisclosure(stringResource(R.string.transfer_range), "preset.quick.details.${preset.id}") {
                AdjustmentSummaryContent(preset.payload, model::adjustmentSummaryLookName, "preset.quick.summary.${preset.id}")
            }
            HorizontalDivider()
        } }
    }
}
