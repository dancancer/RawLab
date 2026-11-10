package com.rawlab.android.camera

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.ui.Alignment
import androidx.compose.ui.semantics.Role
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.rawlab.android.R

@Composable
internal fun rememberCameraFinder(model: CameraImportViewModel): (Boolean) -> Unit {
    val context = LocalContext.current
    var manual by remember { mutableStateOf(false) }
    val permissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        if (result.values.all { it }) { if (manual) model.useLegacyWifi() else model.scan() } else model.permissionDenied()
    }
    return { wifi ->
        manual = wifi
        val required = buildList {
            add(Manifest.permission.ACCESS_FINE_LOCATION)
            add(Manifest.permission.ACCESS_COARSE_LOCATION)
            if (Build.VERSION.SDK_INT >= 31) { add(Manifest.permission.BLUETOOTH_SCAN); add(Manifest.permission.BLUETOOTH_CONNECT) }
            if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.NEARBY_WIFI_DEVICES)
        }.filter { context.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (Build.VERSION.SDK_INT < 29 || required.isEmpty()) { if (wifi) model.useLegacyWifi() else model.scan() }
        else permissions.launch(required.toTypedArray())
    }
}

@Composable
internal fun CameraConnectionPanel(state: CameraImportState, model: CameraImportViewModel, findCamera: (Boolean) -> Unit,
    enabled: Boolean = true) {
    val context = LocalContext.current
    val available = enabled && !state.closing && !state.preparing
    state.stage?.let { stage ->
        if (stage != SonyCameraConnection.Stage.MANUAL_WIFI) LinearProgressIndicator(Modifier.fillMaxWidth())
        Text(stringResource(stageText(stage)), style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    if (state.stage == SonyCameraConnection.Stage.MANUAL_WIFI) {
        Text(stringResource(R.string.camera_manual_guide), style = MaterialTheme.typography.bodyMedium)
        if (state.mode == CameraMode.TETHER) {
            Row(Modifier.fillMaxWidth().toggleable(state.cardSavingConfirmed, role = Role.Checkbox,
                onValueChange = model::confirmCardSaving).testTag("tether-card-confirm"), verticalAlignment = Alignment.CenterVertically) {
                Checkbox(state.cardSavingConfirmed, onCheckedChange = null)
                Text(stringResource(R.string.tether_card_confirm), Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
            }
        }
        OutlinedButton(onClick = { context.startActivity(Intent(Settings.ACTION_WIFI_SETTINGS)) }, shape = CameraControlShape,
            modifier = Modifier.fillMaxWidth().testTag("camera-wifi-settings")) { Text(stringResource(R.string.camera_wifi_settings)) }
        Button(onClick = { findCamera(true) }, shape = CameraControlShape,
            enabled = available && (state.mode != CameraMode.TETHER || state.cardSavingConfirmed),
            modifier = Modifier.fillMaxWidth().testTag("camera-use-wifi")) { Text(stringResource(R.string.camera_use_wifi)) }
    } else {
        state.candidates.forEach { candidate ->
            val name = SonyCameraModel.fromAdvertisement(candidate.name)?.displayName ?: candidate.name
            ListItem(headlineContent = { Text(name) }, supportingContent = if (name != candidate.name) ({ Text(candidate.name) }) else null,
                modifier = Modifier.fillMaxWidth().clickable(enabled = available && state.stage == SonyCameraConnection.Stage.SCANNING) {
                    model.connect(candidate.id)
                }.testTag("camera-candidate-${candidate.id}"))
            HorizontalDivider()
        }
        if (state.candidates.isEmpty() && state.stage == null && !state.closing)
            Text(stringResource(R.string.camera_devices_empty), style = MaterialTheme.typography.bodyMedium)
    }
    OutlinedButton(onClick = { findCamera(false) }, shape = CameraControlShape,
        enabled = available && (state.stage == null || state.stage == SonyCameraConnection.Stage.SCANNING || state.stage == SonyCameraConnection.Stage.MANUAL_WIFI),
        modifier = Modifier.fillMaxWidth().testTag("camera-find")) { Text(stringResource(R.string.camera_find)) }
    if (state.stage == null || state.stage == SonyCameraConnection.Stage.SCANNING)
        TextButton(onClick = model::prepareLegacyWifi, enabled = available, modifier = Modifier.fillMaxWidth().testTag("camera-legacy-connect")) {
            Text(stringResource(R.string.camera_manual_wifi))
        }
}
