package com.rawlab.android.editor.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.text.input.ImeAction
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.rawlab.android.R
import com.rawlab.android.adjustments.AdjustmentPayload
import com.rawlab.android.adjustments.AdjustmentTransferException
import com.rawlab.android.editor.EditorViewModel
import com.rawlab.android.editor.adjustmentErrorMessage
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.presets.*
import com.rawlab.android.settings.EditPersistenceConflict
import com.rawlab.android.ui.EditorSheetSystemBars

sealed interface AdjustmentPresetAction {
    data object Save : AdjustmentPresetAction
    data class Apply(val preset: AdjustmentPreset) : AdjustmentPresetAction
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun AdjustmentPresetSheet(model: EditorViewModel, saving: Boolean = false, onClose: () -> Unit,
    onRequest: (AdjustmentPresetAction) -> Unit) {
    val editor by model.state.collectAsStateWithLifecycle()
    val focus = LocalFocusManager.current
    var presets by remember { mutableStateOf(emptyList<AdjustmentPreset>()) }
    var loaded by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var creating by remember { mutableStateOf(saving) }
    var captureGeneration by remember { mutableIntStateOf(0) }
    fun close() { captureGeneration++; onClose() }
    DisposableEffect(model) { onDispose { captureGeneration++ } }
    var rename by remember { mutableStateOf<AdjustmentPreset?>(null) }
    var deleting by remember { mutableStateOf<AdjustmentPreset?>(null) }
    var overwrite by remember { mutableStateOf<Pair<AdjustmentPreset, AdjustmentPayload>?>(null) }
    var name by remember { mutableStateOf(if (saving) AppStrings.text(R.string.preset_new_name) else "") }
    fun reload() {
        try { presets = model.presetStore.list(); loaded = true; error = null }
        catch (failure: Exception) { loaded = false; error = presetErrorMessage(failure) }
    }
    fun finish() { creating = false; rename = null; name = ""; reload() }
    fun operation(action: () -> Unit) {
        try { action(); finish() } catch (failure: Exception) { error = presetErrorMessage(failure) }
    }
    LaunchedEffect(model) { reload() }
    ModalBottomSheet(onDismissRequest = ::close,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        EditorSheetSystemBars()
        Column(Modifier.fillMaxWidth().fillMaxHeight(.94f).imePadding().padding(horizontal = 20.dp).testTag("preset-root")) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(if (creating) R.string.preset_save else if (rename != null) R.string.preset_rename else R.string.preset_library),
                    Modifier.weight(1f), style = MaterialTheme.typography.titleLarge)
                TextButton(onClick = ::close, modifier = Modifier.testTag("preset-close")) { Text(stringResource(R.string.message_close)) }
            }
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(bottom = 24.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                error?.let {
                    Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.testTag("preset-error"))
                    TextButton(onClick = ::reload, modifier = Modifier.testTag("preset-reload")) { Text(stringResource(R.string.preset_reload)) }
                }
                if (creating || rename != null) {
                    OutlinedTextField(name, { name = it; error = null }, label = { Text(stringResource(R.string.preset_name)) },
                        modifier = Modifier.fillMaxWidth().testTag("preset-name"), singleLine = true,
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                        keyboardActions = KeyboardActions(onDone = { focus.clearFocus() }))
                    val validName = AdjustmentPreset.normalizedName(name).isNotEmpty()
                    if (creating) AdjustmentScopeEditor(stringResource(R.string.preset_save), "preset-save", validName && editor.controlsEnabled,
                        allowed = if (editor.edits.isHDREditing) com.rawlab.android.adjustments.AdjustmentField.HDR_SUPPORTED
                            else com.rawlab.android.adjustments.AdjustmentField.entries.filterNot { it.isHDRRelative }.toSet()) { scope ->
                        val savedName = name
                        val generation = ++captureGeneration
                        model.capturePresetAdjustments(scope) capture@ { captured ->
                            if (captureGeneration != generation) return@capture
                            try {
                                val payload = captured.getOrThrow()
                                try { model.presetStore.create(savedName, payload); finish() }
                                catch (duplicate: AdjustmentPresetException) {
                                    if (duplicate.reason == PresetFailure.DUPLICATE_NAME && duplicate.existing != null)
                                        overwrite = duplicate.existing to payload
                                    else throw duplicate
                                }
                            } catch (failure: Exception) { error = presetErrorMessage(failure) }
                        }
                    } else Button(onClick = { rename?.let { expected -> operation { model.presetStore.rename(expected, name) } } },
                        enabled = validName, modifier = Modifier.testTag("preset-rename-save")) { Text(stringResource(R.string.preset_rename_action)) }
                    TextButton(onClick = { captureGeneration++; creating = false; rename = null; error = null; name = "" }, modifier = Modifier.testTag("preset-cancel")) {
                        Text(stringResource(R.string.cancel))
                    }
                } else {
                    Button(onClick = { onRequest(AdjustmentPresetAction.Save) }, enabled = loaded && editor.controlsEnabled,
                        modifier = Modifier.testTag("preset-create")) { Text(stringResource(R.string.preset_create)) }
                    if (loaded && presets.isEmpty()) {
                        Text(stringResource(R.string.preset_empty), style = MaterialTheme.typography.titleMedium)
                        Text(stringResource(R.string.preset_empty_hint))
                    }
                    for (preset in presets) key(preset.id) {
                        var menu by remember { mutableStateOf(false) }
                        OutlinedCard(Modifier.fillMaxWidth().testTag("preset-row-${preset.id}")) {
                            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                                    Text(preset.name, Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
                                    Box {
                                        IconButton(onClick = { menu = true }, modifier = Modifier.testTag("preset-manage-${preset.id}")) {
                                            Icon(Icons.Outlined.MoreVert, stringResource(R.string.preset_manage, preset.name))
                                        }
                                        DropdownMenu(menu, { menu = false }) {
                                            DropdownMenuItem(text = { Text(stringResource(R.string.preset_rename_action)) },
                                                onClick = { menu = false; rename = preset; name = preset.name; error = null }, modifier = Modifier.testTag("preset-rename"))
                                            DropdownMenuItem(text = { Text(stringResource(R.string.preset_delete)) },
                                                onClick = { menu = false; deleting = preset }, modifier = Modifier.testTag("preset-delete"))
                                        }
                                    }
                                }
                                Text(stringResource(R.string.transfer_selected, preset.payload.fields.size.toString()), style = MaterialTheme.typography.bodySmall)
                                TextButton(onClick = { onRequest(AdjustmentPresetAction.Apply(preset)) }, enabled = editor.controlsEnabled,
                                    modifier = Modifier.heightIn(min = 48.dp).testTag("preset-apply-${preset.id}")) { Text(stringResource(R.string.preset_apply)) }
                            }
                        }
                    }
                }
            }
        }
    }
    overwrite?.let { (expected, payload) ->
        AlertDialog(onDismissRequest = { overwrite = null }, title = { Text(stringResource(R.string.preset_overwrite_confirm)) },
            text = { Text(expected.name) }, confirmButton = {
                TextButton(onClick = { overwrite = null; operation { model.presetStore.overwrite(expected, payload) } },
                    modifier = Modifier.testTag("preset-overwrite-confirm")) { Text(stringResource(R.string.preset_overwrite)) }
            }, dismissButton = { Column {
                TextButton(onClick = { overwrite = null; name = ""; error = AppStrings.text(R.string.preset_another_name) },
                    modifier = Modifier.testTag("preset-save-as")) { Text(stringResource(R.string.preset_save_as)) }
                TextButton(onClick = { overwrite = null }) { Text(stringResource(R.string.cancel)) }
            } })
    }
    deleting?.let { expected ->
        AlertDialog(onDismissRequest = { deleting = null }, title = { Text(stringResource(R.string.preset_delete_confirm)) },
            text = { Text(expected.name) }, confirmButton = {
                TextButton(onClick = { deleting = null; operation { model.presetStore.delete(expected) } },
                    modifier = Modifier.testTag("preset-delete-confirm")) { Text(stringResource(R.string.preset_delete)) }
            }, dismissButton = { TextButton(onClick = { deleting = null }, modifier = Modifier.testTag("preset-delete-cancel")) { Text(stringResource(R.string.cancel)) } })
    }
}

private fun presetErrorMessage(error: Throwable): String {
    if (error is AdjustmentTransferException || error is EditPersistenceConflict) return adjustmentErrorMessage(error)
    return if (error is AdjustmentPresetException) AppStrings.text(when (error.reason) {
        PresetFailure.EMPTY_NAME -> R.string.preset_enter_name
        PresetFailure.DUPLICATE_NAME -> R.string.preset_duplicate_name
        PresetFailure.CHANGED -> R.string.preset_changed
        PresetFailure.CORRUPT_LIBRARY -> R.string.preset_corrupt
        PresetFailure.UNSUPPORTED_VERSION -> R.string.preset_future
        PresetFailure.IDENTITY_COLLISION -> R.string.preset_identity_error
    }) else String.format(AppStrings.text(R.string.preset_error), error.localizedMessage.orEmpty())
}
