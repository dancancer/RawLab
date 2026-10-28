package com.rawlab.android.editor.ui

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.ui.semantics.Role
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ExpandLess
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.rawlab.android.R
import com.rawlab.android.adjustments.*
import com.rawlab.android.presets.AdjustmentPreset
import com.rawlab.android.editor.CollectionSynchronization
import com.rawlab.android.editor.EditorViewModel
import com.rawlab.android.editor.adjustmentErrorMessage
import com.rawlab.android.ui.EditorSheetSystemBars

internal enum class AdjustmentSheet { COPY, PASTE, HISTORY }
private val unfinished = setOf(AdjustmentStatus.BLOCKED, AdjustmentStatus.FAILED, AdjustmentStatus.CONFLICT)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun AdjustmentTransferSheet(model: EditorViewModel, kind: AdjustmentSheet, preset: AdjustmentPreset? = null, synchronization: CollectionSynchronization? = null,
    focusedHistory: java.util.UUID? = null, onClose: () -> Unit) {
    val editor by model.state.collectAsStateWithLifecycle()
    val transfer by model.adjustmentTransfer.collectAsStateWithLifecycle()
    // 打开时冻结剪贴板和目标；异步 picker / 预检不能重新读取后来复制的内容。
    val payload = remember { synchronization?.payload ?: preset?.payload ?: model.adjustmentClipboard }
    val sourceName = remember { synchronization?.sourceName ?: preset?.name ?: model.adjustmentClipboardSourceName.orEmpty() }
    var targets by remember { mutableStateOf(synchronization?.targets ?: listOfNotNull(editor.photo?.uri)) }
    var skipped by remember { mutableStateOf(emptySet<String>()) }
    fun changeTargets(next: List<Uri>) {
        model.closeAdjustmentOperation(); skipped = emptySet(); targets = next.distinct()
    }
    val files = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isNotEmpty()) changeTargets(targets + uris)
    }
    val prepared = transfer.prepared
    val busy = transfer.preparing
    val ready = !busy && prepared?.targets?.any { it.id !in skipped } == true &&
        prepared.targets.all { it.error == null || it.id in skipped }
    DisposableEffect(model) { onDispose { model.closeAdjustmentOperation() } }
    ModalBottomSheet(onDismissRequest = onClose,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        EditorSheetSystemBars()
        Column(Modifier.fillMaxWidth().fillMaxHeight(.94f).padding(horizontal = 20.dp).testTag("adjustment-transfer-root")) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(if (synchronization != null) stringResource(R.string.collection_sync) else stringResource(when (kind) {
                    AdjustmentSheet.COPY -> R.string.transfer_copy
                    AdjustmentSheet.PASTE -> if (preset == null) R.string.transfer_paste else R.string.preset_apply
                    AdjustmentSheet.HISTORY -> R.string.transfer_history
                }), Modifier.weight(1f), style = MaterialTheme.typography.titleLarge)
                TextButton(onClick = onClose, modifier = Modifier.testTag("adjustment-transfer-close")) {
                    Text(stringResource(R.string.message_close))
                }
            }
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(bottom = 24.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                when (kind) {
                    AdjustmentSheet.COPY -> CopyAdjustmentContent(editor.photo?.name.orEmpty()) { scope ->
                        if (model.copyAdjustments(scope) != null) onClose()
                    }
                    AdjustmentSheet.PASTE -> if (payload == null) Text(stringResource(R.string.transfer_no_clipboard)) else {
                        Text(stringResource(R.string.transfer_source, sourceName, payload.fields.size.toString()),
                            style = MaterialTheme.typography.titleMedium)
                        TransferDisclosure(stringResource(R.string.transfer_range), "adjustment-paste-range") {
                            Text(payload.fields.sortedBy { it.id }.joinToString(" · ") { it.title })
                        }
                        Text(stringResource(R.string.transfer_targets, targets.size.toString()))
                        if (synchronization == null) TextButton(onClick = { files.launch(arrayOf("*/*")) }, enabled = !busy,
                            modifier = Modifier.testTag("adjustment-paste-files")) { Text(stringResource(R.string.transfer_choose_files)) }
                        Button(onClick = { skipped = emptySet(); model.prepareAdjustmentPaste(payload, targets, if (synchronization != null) AdjustmentHistoryTransaction.Action.SYNCHRONIZE else if (preset == null) AdjustmentHistoryTransaction.Action.PASTE else AdjustmentHistoryTransaction.Action.PRESET) },
                            enabled = !busy && targets.isNotEmpty(), modifier = Modifier.testTag("adjustment-paste-preflight")) {
                            Text(stringResource(R.string.transfer_preflight))
                        }
                        if (busy) { LinearProgressIndicator(Modifier.fillMaxWidth()); Text(stringResource(R.string.transfer_preparing)) }
                        for (uri in targets) {
                            val id = uri.toString()
                            val target = prepared?.targets?.firstOrNull { it.id == id }
                            val result = transfer.results.firstOrNull { it.targetID == id }
                            val part = model.adjustmentTransactions.firstOrNull { it.id == prepared?.id }?.parts?.firstOrNull { it.identity.value == id }
                            OutlinedCard(Modifier.fillMaxWidth()) {
                                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                    Text(target?.displayName ?: editor.photo?.takeIf { it.uri == uri }?.name ?: uri.lastPathSegment.orEmpty())
                                    if (result != null) Text(if (part?.state == AdjustmentHistoryTransaction.State.UNDONE)
                                        stringResource(R.string.transfer_undone) else result.status.title)
                                    (result?.error ?: target?.error)?.let { Text(adjustmentErrorMessage(it), color = MaterialTheme.colorScheme.error) }
                                    TransferCheck(stringResource(R.string.transfer_skip), id in skipped, !busy &&
                                        (result == null || result.status in unfinished), "adjustment-target-skip-$id") {
                                        skipped = if (it) skipped + id else skipped - id
                                    }
                                    if (editor.photo?.identity?.value == id && model.collectionDraftFailure(id) != null) {
                                        TextButton(onClick = { model.resolveCollectionDraft(true) { if (it) model.closeAdjustmentOperation() } }, enabled = !busy && id !in skipped) { Text(stringResource(R.string.collection_apply_draft)) }
                                        TextButton(onClick = { model.resolveCollectionDraft(false) { if (it) model.closeAdjustmentOperation() } }, enabled = !busy && id !in skipped) { Text(stringResource(R.string.collection_discard_draft)) }
                                    }
                                    if (prepared == null && synchronization == null) TextButton(onClick = { changeTargets(targets - uri) }, enabled = !busy) {
                                        Text(stringResource(R.string.message_remove))
                                    }
                                }
                            }
                        }
                        if (targets.isEmpty() || (prepared != null && prepared.targets.all { it.id in skipped }))
                            Text(stringResource(R.string.transfer_empty_targets))
                        if (transfer.results.isNotEmpty()) {
                            val undone = model.adjustmentTransactions.firstOrNull { it.id == prepared?.id }?.parts
                                ?.filter { it.state == AdjustmentHistoryTransaction.State.UNDONE }?.map { it.identity.value }.orEmpty().toSet()
                            Text(stringResource(R.string.transfer_summary,
                                transfer.results.count { it.status == AdjustmentStatus.APPLIED && it.targetID !in undone }.toString(),
                                transfer.results.count { it.status == AdjustmentStatus.UNCHANGED }.toString(),
                                transfer.results.count { it.status == AdjustmentStatus.SKIPPED }.toString(), undone.size.toString(),
                                transfer.results.count { it.status in unfinished }.toString()), Modifier.testTag("adjustment-paste-summary"))
                        }
                        if (transfer.results.isEmpty() || transfer.results.any { it.status in unfinished })
                            Button(onClick = { prepared?.let { model.applyAdjustmentPaste(it, skipped) } }, enabled = ready && !editor.committingAdjustments,
                                modifier = Modifier.testTag("adjustment-paste-apply")) {
                                Text(stringResource(if (transfer.results.isEmpty()) R.string.transfer_apply else R.string.transfer_retry))
                            }
                        model.adjustmentTransactions.firstOrNull { it.id == prepared?.id }?.let { TransactionButtons(model, it, busy || editor.committingAdjustments) }
                        HistoryRecovery(model)
                    }
                    AdjustmentSheet.HISTORY -> Column(Modifier.testTag("adjustment-history-list"), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text(stringResource(R.string.transfer_history_hint), style = MaterialTheme.typography.bodySmall)
                        HistoryRecovery(model)
                        if (model.adjustmentTransactions.isEmpty()) Text(stringResource(R.string.transfer_no_history))
                        for (transaction in model.adjustmentTransactions.asReversed().filter { focusedHistory == null || it.id == focusedHistory }) {
                            OutlinedCard(Modifier.fillMaxWidth()) {
                                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                    Text(when (transaction.action) {
                                        AdjustmentHistoryTransaction.Action.PASTE -> stringResource(R.string.transfer_paste)
                                        AdjustmentHistoryTransaction.Action.PRESET -> stringResource(R.string.preset_apply)
                                        AdjustmentHistoryTransaction.Action.EDIT -> stringResource(R.string.transfer_edit)
                                        AdjustmentHistoryTransaction.Action.SYNCHRONIZE -> stringResource(R.string.collection_sync)
                                    }, style = MaterialTheme.typography.titleMedium)
                                    Text(transaction.parts.joinToString(" · ") { it.displayName })
                                    TransactionButtons(model, transaction, busy || editor.committingAdjustments)
                                }
                            }
                        }
                    }
                }
                transfer.error?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.testTag("adjustment-transfer-error")) }
            }
        }
    }
}

@Composable
private fun CopyAdjustmentContent(source: String, onCopy: (AdjustmentScope) -> Unit) {
    Text(source, style = MaterialTheme.typography.titleMedium)
    AdjustmentScopeEditor(stringResource(R.string.transfer_copy), "adjustment-copy-confirm", onConfirm = onCopy)
}

@Composable
internal fun AdjustmentScopeEditor(confirmTitle: String, confirmTag: String, enabled: Boolean = true,
    onConfirm: (AdjustmentScope) -> Unit) {
    var scope by remember { mutableIntStateOf(2) }
    var fields by remember { mutableStateOf<Set<AdjustmentField>>(AdjustmentField.COMMON) }
    Text(stringResource(R.string.transfer_scope))
    listOf(R.string.transfer_all, R.string.transfer_modified, R.string.transfer_custom).forEachIndexed { index, title ->
        Row(Modifier.fillMaxWidth().clickable { scope = index }.testTag("adjustment-copy-scope-$index"),
            verticalAlignment = Alignment.CenterVertically) {
            RadioButton(scope == index, { scope = index }); Text(stringResource(title))
        }
    }
    Text(stringResource(R.string.transfer_geometry_hint), style = MaterialTheme.typography.bodySmall)
    if (scope == 2) {
        Text(stringResource(R.string.transfer_selected, fields.size.toString()))
        TextButton(onClick = { fields = emptySet() }, modifier = Modifier.testTag("adjustment-copy-clear")) { Text(stringResource(R.string.transfer_clear)) }
        val groups = listOf("looks" to R.string.transfer_group_looks, "light" to R.string.transfer_group_light,
            "color" to R.string.transfer_group_color, "effects" to R.string.transfer_group_effects,
            "detail" to R.string.transfer_group_detail, "geometry" to R.string.transfer_group_geometry)
        fun select(members: Set<AdjustmentField>, checked: Boolean) { fields = if (checked) fields + members else fields - members }
        for ((group, title) in groups) TransferDisclosure(stringResource(title), "adjustment-group-$group") {
            val members = AdjustmentField.entries.filter { it.group == group }.toSet()
            TransferCheck(stringResource(R.string.transfer_select_group), fields.containsAll(members), true, "adjustment-select-group-$group") { select(members, it) }
            for (field in members.filter { it.hslLocation == null })
                TransferCheck(field.title, field in fields, true, "adjustment-field-${field.id}") { select(setOf(field), it) }
            if (group == "color") for ((axis, axisTitle) in listOf(R.string.transfer_axis_0, R.string.transfer_axis_1, R.string.transfer_axis_2).withIndex()) {
                TransferDisclosure("HSL · ${stringResource(axisTitle)}", "adjustment-axis-$axis") {
                    val channels = members.filter { it.hslLocation?.first == axis }.toSet()
                    TransferCheck(stringResource(R.string.transfer_select_group), fields.containsAll(channels), true, "adjustment-select-axis-$axis") { select(channels, it) }
                    for (field in channels) TransferCheck(field.title, field in fields, true, "adjustment-field-${field.id}") { select(setOf(field), it) }
                }
            }
        }
    }
    Button(onClick = { onConfirm(when (scope) { 0 -> AdjustmentScope.All; 1 -> AdjustmentScope.Modified; else -> AdjustmentScope.Custom(fields) }) },
        enabled = enabled && (scope != 2 || fields.isNotEmpty()), modifier = Modifier.heightIn(min = 48.dp).testTag(confirmTag)) { Text(confirmTitle) }
}

@Composable
private fun TransactionButtons(model: EditorViewModel, transaction: AdjustmentHistoryTransaction, busy: Boolean) {
    val applied = transaction.parts.count { it.state == AdjustmentHistoryTransaction.State.APPLIED }
    val undone = transaction.parts.count { it.state == AdjustmentHistoryTransaction.State.UNDONE }
    TextButton(onClick = { model.performAdjustmentHistory(true, transaction.id, true) }, enabled = !busy && applied > 0,
        modifier = Modifier.testTag("adjustment-transaction-undo-${transaction.id}")) { Text(stringResource(R.string.transfer_undo_count, applied.toString())) }
    TextButton(onClick = { model.performAdjustmentHistory(false, transaction.id, true) }, enabled = !busy && undone > 0,
        modifier = Modifier.testTag("adjustment-transaction-redo-${transaction.id}")) { Text(stringResource(R.string.transfer_redo_count, undone.toString())) }
}

@Composable
private fun HistoryRecovery(model: EditorViewModel) {
    val transfer by model.adjustmentTransfer.collectAsStateWithLifecycle()
    val request = transfer.historyRequest ?: return
    val failures = transfer.historyResults.filter { it.status in unfinished }
    if (failures.isEmpty()) return
    Text(stringResource(R.string.transfer_history_failed), color = MaterialTheme.colorScheme.error)
    for (result in failures) {
        val name = model.adjustmentTransactions.firstOrNull { it.id == request.transactionID }?.parts?.firstOrNull { it.identity.value == result.targetID }?.displayName.orEmpty()
        Text("$name · ${adjustmentErrorMessage(result.error)}")
    }
    TextButton(onClick = { model.executeAdjustmentHistory(request) }, modifier = Modifier.testTag("adjustment-history-retry")) { Text(stringResource(R.string.transfer_retry)) }
    if (request.photo == null && failures.any { it.requiresHistoryDecision }) TextButton(onClick = {
        model.executeAdjustmentHistory(request, failures.filter { it.requiresHistoryDecision }.map { it.targetID }.toSet())
    }, modifier = Modifier.testTag("adjustment-history-skip")) { Text(stringResource(R.string.transfer_history_skip)) }
}

@Composable
private fun TransferDisclosure(title: String, tag: String, content: @Composable ColumnScope.() -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Column {
        TextButton(onClick = { expanded = !expanded }, modifier = Modifier.fillMaxWidth().testTag(tag)) {
            Text(title, Modifier.weight(1f)); Icon(if (expanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, null)
        }
        if (expanded) Column(Modifier.padding(start = 8.dp), content = content)
    }
}

@Composable
private fun TransferCheck(title: String, checked: Boolean, enabled: Boolean, tag: String, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(value = checked, enabled = enabled, role = Role.Checkbox, onValueChange = onChange).testTag(tag),
        verticalAlignment = Alignment.CenterVertically) {
        Checkbox(checked, null, enabled = enabled); Text(title, Modifier.weight(1f))
    }
}
