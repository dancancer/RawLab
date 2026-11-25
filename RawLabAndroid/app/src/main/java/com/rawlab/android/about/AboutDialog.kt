package com.rawlab.android.about

import com.rawlab.android.ui.AppIcons

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogProperties
import com.rawlab.android.R
import com.rawlab.android.analytics.UsageAnalyticsState
import com.rawlab.android.diagnostics.DiagnosticUiState
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.i18n.LanguageChoice

@Composable
fun AboutDialog(
    state: UpdateState,
    onAutomatic: (Boolean) -> Unit,
    onCheck: () -> Unit,
    onClose: () -> Unit,
    usageState: UsageAnalyticsState = UsageAnalyticsState(available = false, enabled = false),
    onUsage: (Boolean) -> Unit = {},
    diagnosticState: DiagnosticUiState = DiagnosticUiState(),
    onDiagnosticRecording: (Boolean) -> Unit = {},
    onDiagnosticNote: (String) -> Unit = {},
    onDiagnosticSaveToUri: (Uri) -> Unit = {},
    onDiagnosticShare: () -> Unit = {},
    onDiagnosticUpload: () -> Unit = {},
    onDiagnosticTogglePreview: () -> Unit = {},
    onDiagnosticClear: () -> Unit = {},
    onDiagnosticCodeCopied: () -> Unit = {},
) {
    val context = LocalContext.current
    val automaticLabel = stringResource(R.string.auto_update_check)
    var linkFailed by remember { mutableStateOf(false) }
    val saveZipLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/zip")
    ) { uri ->
        if (uri != null) onDiagnosticSaveToUri(uri)
    }
    fun open(url: String) {
        try { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
        catch (_: ActivityNotFoundException) { linkFailed = true }
    }
    AlertDialog(
        onDismissRequest = onClose,
        properties = DialogProperties(usePlatformDefaultWidth = false),
        modifier = Modifier.padding(horizontal = 24.dp, vertical = 16.dp).widthIn(max = 560.dp),
        title = { Text(stringResource(R.string.about_rawlab)) },
        text = {
            Column(Modifier.heightIn(max = 460.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(stringResource(R.string.app_version, state.version))
                LanguageMenu()
                HorizontalDivider()
                Text(stringResource(R.string.project_author), style = MaterialTheme.typography.titleSmall)
                TextButton(onClick = { open(UpdateRelease.REPOSITORY) }) {
                    Icon(AppIcons.AutoMirrored.Outlined.OpenInNew, null); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.github_repository))
                }
                TextButton(onClick = { open(UpdateRelease.AUTHOR) }) {
                    Icon(AppIcons.AutoMirrored.Outlined.OpenInNew, null); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.author_xiaohongshu))
                }
                if (linkFailed) Text(stringResource(R.string.browser_unavailable), color = MaterialTheme.colorScheme.error)
                HorizontalDivider()
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(automaticLabel, Modifier.weight(1f))
                    Switch(checked = state.automatic, onCheckedChange = onAutomatic,
                        modifier = Modifier.semantics { contentDescription = automaticLabel })
                }
                HorizontalDivider()
                Text(stringResource(R.string.usage_privacy), style = MaterialTheme.typography.bodySmall)
                Text(stringResource(R.string.usage_install_id), style = MaterialTheme.typography.bodySmall)
                val usageLabel = stringResource(R.string.usage_analytics)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(usageLabel, Modifier.weight(1f))
                    Switch(
                        checked = usageState.enabled,
                        onCheckedChange = onUsage,
                        enabled = usageState.available || usageState.enabled,
                        modifier = Modifier.semantics { contentDescription = usageLabel },
                    )
                }
                Text(stringResource(usageState.statusMessage()), style = MaterialTheme.typography.bodySmall)
                TextButton(onClick = { open("https://terms.alicdn.com/legal-agreement/terms/privacy_policy_full/20240308104330389/20240308104330389.html") }) {
                    Icon(AppIcons.AutoMirrored.Outlined.OpenInNew, null)
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.usage_privacy_policy))
                }
                HorizontalDivider()
                Text(stringResource(R.string.diagnostics_title), style = MaterialTheme.typography.titleSmall)
                val recordingLabel = stringResource(R.string.diagnostics_recording)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(recordingLabel, Modifier.weight(1f))
                    Switch(
                        checked = diagnosticState.isRecording,
                        onCheckedChange = onDiagnosticRecording,
                        modifier = Modifier.testTag("diagnostics.recording").semantics { contentDescription = recordingLabel },
                    )
                }
                Text(stringResource(diagnosticState.statusRes), style = MaterialTheme.typography.bodySmall)
                Text(stringResource(R.string.diagnostics_privacy_notice), style = MaterialTheme.typography.bodySmall)
                OutlinedTextField(
                    value = diagnosticState.userNote,
                    onValueChange = onDiagnosticNote,
                    label = { Text(stringResource(R.string.diagnostics_note_label)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth().testTag("diagnostics.note"),
                )
                diagnosticState.lastUploadedReportID?.let { code ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text(
                            stringResource(R.string.diagnostics_code_format, code),
                            fontFamily = FontFamily.Monospace,
                            modifier = Modifier.weight(1f),
                        )
                        OutlinedButton(
                            onClick = {
                                val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                                clipboard?.setPrimaryClip(ClipData.newPlainText("RawLab Diagnostic Code", code))
                                onDiagnosticCodeCopied()
                            },
                            modifier = Modifier.testTag("diagnostics.copyCode"),
                        ) {
                            Text(stringResource(if (diagnosticState.copiedCode) R.string.diagnostics_copied else R.string.diagnostics_copy_code))
                        }
                    }
                }
                diagnosticState.feedbackRes?.let { resId ->
                    Text(
                        stringResource(resId),
                        style = MaterialTheme.typography.bodySmall,
                        color = if (diagnosticState.feedbackIsError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                val canAct = (diagnosticState.hasExportableLogs || diagnosticState.isRecording) && !diagnosticState.isUploading
                Row(
                    modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    OutlinedButton(
                        onClick = { saveZipLauncher.launch("RawLab-Diagnostics.zip") },
                        enabled = canAct,
                        modifier = Modifier.testTag("diagnostics.saveZip"),
                    ) {
                        Text(stringResource(R.string.diagnostics_save_device))
                    }
                    OutlinedButton(
                        onClick = onDiagnosticShare,
                        enabled = canAct,
                        modifier = Modifier.testTag("diagnostics.shareZip"),
                    ) {
                        Text(stringResource(R.string.diagnostics_share_zip))
                    }
                    Button(
                        onClick = onDiagnosticUpload,
                        enabled = canAct,
                        modifier = Modifier.testTag("diagnostics.upload"),
                    ) {
                        Text(stringResource(if (diagnosticState.isUploading) R.string.diagnostics_uploading else R.string.diagnostics_upload))
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(
                        onClick = onDiagnosticTogglePreview,
                        enabled = diagnosticState.hasExportableLogs || diagnosticState.isRecording,
                        modifier = Modifier.testTag("diagnostics.preview"),
                    ) {
                        Text(stringResource(R.string.diagnostics_preview))
                    }
                    if (diagnosticState.hasExportableLogs) {
                        TextButton(
                            onClick = onDiagnosticClear,
                            enabled = !diagnosticState.isUploading,
                            modifier = Modifier.testTag("diagnostics.clear"),
                        ) {
                            Text(stringResource(R.string.diagnostics_clear), color = MaterialTheme.colorScheme.error)
                        }
                    }
                }
                diagnosticState.previewText?.let { preview ->
                    Surface(
                        color = MaterialTheme.colorScheme.surfaceContainerLow,
                        shape = MaterialTheme.shapes.small,
                        modifier = Modifier.fillMaxWidth().heightIn(max = 180.dp),
                    ) {
                        Text(
                            preview,
                            fontFamily = FontFamily.Monospace,
                            style = MaterialTheme.typography.bodySmall,
                            modifier = Modifier.padding(8.dp).verticalScroll(rememberScrollState()),
                        )
                    }
                }
                HorizontalDivider()
                Text(when (state.status) {
                    UpdateStatus.UNCHECKED -> stringResource(R.string.update_unchecked)
                    UpdateStatus.CHECKING -> stringResource(R.string.update_checking)
                    UpdateStatus.CURRENT -> stringResource(R.string.update_current)
                    UpdateStatus.AVAILABLE -> stringResource(R.string.update_available, state.available?.version.orEmpty())
                    UpdateStatus.FAILED -> stringResource(R.string.update_failed)
                })
                TextButton(onClick = onCheck, enabled = state.status != UpdateStatus.CHECKING) {
                    Icon(Icons.Outlined.Refresh, null); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.check_updates))
                }
                state.available?.let { release ->
                    Button(onClick = { open(release.url) }) { Text(stringResource(R.string.update_download, release.version)) }
                    if (release.notes.isNotBlank()) Text(release.notes, style = MaterialTheme.typography.bodySmall)
                }
            }
        }, confirmButton = { TextButton(onClick = onClose) { Text(stringResource(R.string.confirm)) } })
}

/** 状态行：有故障先说明故障；否则说明本构建能否统计，以及用户当前的选择 */
private fun UsageAnalyticsState.statusMessage(): Int = issue?.message ?: when {
    !available -> R.string.usage_unavailable
    enabled -> R.string.usage_enabled
    else -> R.string.usage_disabled
}

@Composable
internal fun LanguageMenu() {
    val context = LocalContext.current
    var expanded by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    val preference = AppStrings.preference(context)
    val index = LanguageChoice.codes.indexOf(preference).coerceAtLeast(0)
    val systemName = stringResource(R.string.follow_system)
    val label = if (index == 0) systemName else LanguageChoice.nativeNames[index]
    Column {
        Text(stringResource(R.string.language), style = MaterialTheme.typography.labelLarge)
        Box {
            OutlinedButton(onClick = { expanded = true }) { Text(label) }
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                LanguageChoice.codes.forEachIndexed { i, code ->
                    DropdownMenuItem(text = { Text(if (i == 0) systemName else LanguageChoice.nativeNames[i]) }, onClick = {
                        expanded = false
                        if (code != preference) {
                            try {
                                AppStrings.setPreference(context, code)
                                if (android.os.Build.VERSION.SDK_INT < 33) (context as? android.app.Activity)?.recreate()
                            } catch (_: IllegalStateException) { failed = true }
                        }
                    })
                }
            }
        }
        if (failed) Text(stringResource(R.string.language_save_error), color = MaterialTheme.colorScheme.error)
    }
}
