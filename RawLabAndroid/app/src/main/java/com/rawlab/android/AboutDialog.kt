package com.rawlab.android

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.OpenInNew
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

@Composable
fun AboutDialog(state: UpdateState, onAutomatic: (Boolean) -> Unit, onCheck: () -> Unit, onClose: () -> Unit) {
    val context = LocalContext.current
    val automaticLabel = stringResource(R.string.auto_update_check)
    var linkFailed by remember { mutableStateOf(false) }
    fun open(url: String) {
        try { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
        catch (_: ActivityNotFoundException) { linkFailed = true }
    }
    AlertDialog(onDismissRequest = onClose, title = { Text(stringResource(R.string.about_rawlab)) },
        text = {
            Column(Modifier.heightIn(max = 440.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(stringResource(R.string.app_version, state.version))
                HorizontalDivider()
                Text(stringResource(R.string.project_author), style = MaterialTheme.typography.titleSmall)
                TextButton(onClick = { open(UpdateRelease.REPOSITORY) }) {
                    Icon(Icons.AutoMirrored.Outlined.OpenInNew, null); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.github_repository))
                }
                TextButton(onClick = { open(UpdateRelease.AUTHOR) }) {
                    Icon(Icons.AutoMirrored.Outlined.OpenInNew, null); Spacer(Modifier.width(8.dp)); Text(stringResource(R.string.author_xiaohongshu))
                }
                if (linkFailed) Text(stringResource(R.string.browser_unavailable), color = MaterialTheme.colorScheme.error)
                HorizontalDivider()
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(automaticLabel, Modifier.weight(1f))
                    Switch(checked = state.automatic, onCheckedChange = onAutomatic,
                        modifier = Modifier.semantics { contentDescription = automaticLabel })
                }
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
