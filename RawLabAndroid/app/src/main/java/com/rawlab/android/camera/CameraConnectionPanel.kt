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
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.Alignment
import androidx.compose.ui.semantics.Role
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.rawlab.android.R

internal fun cameraBluetoothPermissions(sdk: Int): List<String> = if (sdk >= Build.VERSION_CODES.S) {
    listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
} else listOf(Manifest.permission.ACCESS_FINE_LOCATION)

internal fun cameraWifiPermissions(sdk: Int): List<String> = buildList {
    add(Manifest.permission.ACCESS_FINE_LOCATION)
    if (sdk >= Build.VERSION_CODES.TIRAMISU) add(Manifest.permission.NEARBY_WIFI_DEVICES)
}

private enum class CameraConnectionAction { DISCOVER, JOIN, CURRENT_WIFI }

@Composable
internal fun CameraConnectionPanel(state: CameraImportState, model: CameraImportViewModel, enabled: Boolean = true) {
    val context = LocalContext.current
    val sdk = Build.VERSION.SDK_INT
    var pendingAction by rememberSaveable { mutableStateOf<CameraConnectionAction?>(null) }
    var pendingCandidate by rememberSaveable { mutableStateOf<String?>(null) }
    fun required(action: CameraConnectionAction) = when (action) {
        CameraConnectionAction.DISCOVER -> cameraBluetoothPermissions(sdk)
        CameraConnectionAction.CURRENT_WIFI -> cameraWifiPermissions(sdk)
        CameraConnectionAction.JOIN -> (cameraBluetoothPermissions(sdk) + cameraWifiPermissions(sdk)).distinct()
    }
    fun perform(action: CameraConnectionAction) = when (action) {
        CameraConnectionAction.DISCOVER -> model.scan()
        CameraConnectionAction.CURRENT_WIFI -> model.useLegacyWifi()
        CameraConnectionAction.JOIN -> pendingCandidate?.let(model::connect) ?: Unit
    }
    fun missing(action: CameraConnectionAction) = required(action)
        .filter { context.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
    val permissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        pendingAction?.let { action ->
            pendingAction = null
            if (missing(action).isEmpty()) perform(action) else model.permissionDenied()
        }
    }
    fun request(action: CameraConnectionAction, candidate: String? = null) {
        if (pendingAction != null) return
        pendingCandidate = candidate
        val missing = missing(action)
        if (sdk < Build.VERSION_CODES.Q || missing.isEmpty()) perform(action)
        else {
            pendingAction = action
            // Android 12+ needs both location permissions in one request for Precise.
            val requested = if (Manifest.permission.ACCESS_FINE_LOCATION in missing)
                missing + Manifest.permission.ACCESS_COARSE_LOCATION else missing
            permissions.launch(requested.toTypedArray())
        }
    }
    val available = enabled && !state.closing && !state.preparing
    val accessAuth = state.accessAuth
    if (accessAuth != null) {
        CameraAccessAuthCard(
            prompt = accessAuth,
            available = available,
            onSubmit = model::submitAccessAuth,
            onCancel = model::cancelAccessAuth,
            onForget = model::forgetAccessAuth,
        )
        return
    }
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
        Button(onClick = { request(CameraConnectionAction.CURRENT_WIFI) }, shape = CameraControlShape,
            enabled = available && (state.mode != CameraMode.TETHER || state.cardSavingConfirmed),
            modifier = Modifier.fillMaxWidth().testTag("camera-use-wifi")) { Text(stringResource(R.string.camera_use_wifi)) }
    } else {
        state.candidates.forEach { candidate ->
            val name = SonyCameraModel.fromAdvertisement(candidate.name).takeUnless { it == SonyCameraModel.UNKNOWN }?.displayName ?: candidate.name
            ListItem(headlineContent = { Text(name) }, supportingContent = if (name != candidate.name) ({ Text(candidate.name) }) else null,
                modifier = Modifier.fillMaxWidth().clickable(enabled = available && state.stage == SonyCameraConnection.Stage.SCANNING) {
                    request(CameraConnectionAction.JOIN, candidate.id)
                }.testTag("camera-candidate-${candidate.id}"))
            HorizontalDivider()
        }
        if (state.candidates.isEmpty() && state.stage == null && !state.closing)
            Text(stringResource(R.string.camera_devices_empty), style = MaterialTheme.typography.bodyMedium)
    }
    OutlinedButton(onClick = { request(CameraConnectionAction.DISCOVER) }, shape = CameraControlShape,
        enabled = available && (state.stage == null || state.stage == SonyCameraConnection.Stage.SCANNING || state.stage == SonyCameraConnection.Stage.MANUAL_WIFI),
        modifier = Modifier.fillMaxWidth().testTag("camera-find")) { Text(stringResource(R.string.camera_find)) }
    if (state.stage == null || state.stage == SonyCameraConnection.Stage.SCANNING)
        TextButton(onClick = model::prepareLegacyWifi, enabled = available, modifier = Modifier.fillMaxWidth().testTag("camera-legacy-connect")) {
            Text(stringResource(R.string.camera_manual_wifi))
        }
}

@Composable
private fun CameraAccessAuthCard(
    prompt: CameraAccessAuthPrompt,
    available: Boolean,
    onSubmit: (user: String, password: String) -> Unit,
    onCancel: () -> Unit,
    onForget: () -> Unit,
) {
    var username by rememberSaveable(prompt.cameraId, prompt.initialUser) { mutableStateOf(prompt.initialUser) }
    var password by remember(prompt.cameraId) { mutableStateOf("") }
    var passwordVisible by remember { mutableStateOf(false) }

    OutlinedCard(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (prompt.submitting) {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                Text(
                    stringResource(R.string.camera_auth_connecting),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Text(stringResource(R.string.camera_auth_title), style = MaterialTheme.typography.titleMedium)
            if (prompt.fingerprintChanged) {
                Text(
                    stringResource(R.string.camera_auth_fingerprint_changed),
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodyMedium,
                )
            } else {
                Text(stringResource(R.string.camera_auth_guide), style = MaterialTheme.typography.bodyMedium)
            }
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    stringResource(R.string.camera_auth_fingerprint),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    text = "${prompt.fingerprint} (${prompt.keyType})",
                    style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                    modifier = Modifier.testTag("camera-auth-fingerprint"),
                )
            }
            OutlinedTextField(
                value = username,
                onValueChange = { username = it },
                singleLine = true,
                enabled = available && !prompt.submitting,
                label = { Text(stringResource(R.string.camera_auth_user)) },
                modifier = Modifier.fillMaxWidth().testTag("camera-auth-user"),
            )
            OutlinedTextField(
                value = password,
                onValueChange = { password = it },
                singleLine = true,
                enabled = available && !prompt.submitting,
                label = { Text(stringResource(R.string.camera_auth_password)) },
                visualTransformation = if (passwordVisible) VisualTransformation.None else PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                trailingIcon = {
                    TextButton(
                        onClick = { passwordVisible = !passwordVisible },
                        enabled = available && !prompt.submitting,
                    ) {
                        Text(
                            stringResource(
                                if (passwordVisible) R.string.camera_auth_hide_password else R.string.camera_auth_show_password,
                            ),
                        )
                    }
                },
                modifier = Modifier.fillMaxWidth().testTag("camera-auth-password"),
            )
            prompt.errorMessage
                ?.takeIf { !prompt.fingerprintChanged || it != R.string.camera_auth_fingerprint_changed }
                ?.let { messageId ->
                    Text(
                        stringResource(messageId),
                        color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            Button(
                onClick = { onSubmit(username, password) },
                enabled = available && !prompt.submitting && username.isNotBlank() && password.isNotEmpty(),
                shape = CameraControlShape,
                modifier = Modifier.fillMaxWidth().testTag("camera-auth-submit"),
            ) {
                Text(stringResource(R.string.camera_auth_submit))
            }
            if (prompt.hasSavedCredentials) {
                TextButton(
                    onClick = {
                        password = ""
                        username = ""
                        onForget()
                    },
                    enabled = available && !prompt.submitting,
                    modifier = Modifier.fillMaxWidth().testTag("camera-auth-forget"),
                ) {
                    Text(stringResource(R.string.camera_auth_forget))
                }
            }
            OutlinedButton(
                onClick = onCancel,
                enabled = !prompt.submitting,
                shape = CameraControlShape,
                modifier = Modifier.fillMaxWidth().testTag("camera-auth-cancel"),
            ) {
                Text(stringResource(R.string.cancel))
            }
        }
    }
}
