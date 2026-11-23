package com.rawlab.android.camera

import com.rawlab.android.ui.AppIcons

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.rawlab.android.R
import com.rawlab.android.photo.PhotoStorage

internal val CameraControlShape = RoundedCornerShape(6.dp)
private enum class CameraRoute { HOME, CONNECT, HELP, IMPORT, TETHER }

/** 页面导航独立于相机协议；一次新的编辑器入口始终从 HOME 开始。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CameraScreen(model: CameraImportViewModel, storage: PhotoStorage, onBack: () -> Unit,
    onOpen: (List<Uri>) -> Unit, onViewInAlbum: (List<Uri>) -> Unit,
    showTask: Boolean = false, onTaskShown: () -> Unit = {}) {
    val connection by model.state.collectAsStateWithLifecycle()
    val tether by model.tether.state.collectAsStateWithLifecycle()
    var route by rememberSaveable { mutableStateOf(if (showTask) CameraRoute.IMPORT else CameraRoute.HOME) }
    var connectReturn by rememberSaveable { mutableStateOf(CameraRoute.HOME) }
    var returnToTask by rememberSaveable { mutableStateOf(false) }
    var history by rememberSaveable { mutableStateOf(false) }
    var settings by rememberSaveable { mutableStateOf(false) }
    fun home() { model.disconnect(); route = CameraRoute.HOME }
    fun connect(mode: CameraMode, resume: Boolean = false, task: Boolean = false) {
        connectReturn = route
        returnToTask = task
        if (connection.mode != mode) model.setMode(mode) else model.disconnect()
        model.setTetherResume(resume)
        route = CameraRoute.CONNECT
    }
    LaunchedEffect(showTask) { if (showTask) { model.setMode(CameraMode.IMPORT); route = CameraRoute.IMPORT } }
    LaunchedEffect(connection.connected, route) {
        if (route == CameraRoute.CONNECT && connection.connected)
            route = if (connection.mode == CameraMode.IMPORT) CameraRoute.IMPORT else CameraRoute.TETHER
    }
    when (route) {
        CameraRoute.HOME -> {
            BackHandler { model.disconnect(); onBack() }
            Scaffold(topBar = {
                TopAppBar(title = { Text(stringResource(R.string.camera_title)) }, expandedHeight = 56.dp,
                    navigationIcon = { IconButton(onClick = { model.disconnect(); onBack() }, modifier = Modifier.testTag("camera-back")) {
                        Icon(Icons.AutoMirrored.Outlined.ArrowBack, stringResource(R.string.back))
                    } })
            }) { insets ->
                Box(Modifier.fillMaxSize().padding(insets), contentAlignment = Alignment.TopCenter) {
                    Column(Modifier.widthIn(max = 680.dp).fillMaxWidth().verticalScroll(rememberScrollState())
                        .padding(horizontal = 16.dp, vertical = 12.dp).testTag("camera-home"),
                        verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        val previousCamera = tether.run?.profileId?.let { id -> SonyCameraModel.entries.firstOrNull { it.profileId == id } }
                        Column(Modifier.padding(horizontal = 4.dp, vertical = 12.dp).testTag("camera-identity"), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(if (connection.connected) connection.model.displayName else previousCamera?.displayName ?: stringResource(R.string.camera_title), style = MaterialTheme.typography.headlineSmall)
                            Text(stringResource(if (previousCamera == null) R.string.camera_choose_connection else R.string.camera_previous_disconnected),
                                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        Surface(shape = RoundedCornerShape(10.dp), color = MaterialTheme.colorScheme.surfaceContainerLow) {
                            CameraTaskEntry(R.string.camera_import, R.string.camera_import_hint, AppIcons.Outlined.PhotoLibrary,
                                "camera-mode-IMPORT", !connection.closing && !connection.preparing) {
                                if (connection.connected && connection.mode == CameraMode.IMPORT) route = CameraRoute.IMPORT else connect(CameraMode.IMPORT)
                            }
                        }
                        Surface(shape = RoundedCornerShape(10.dp), color = MaterialTheme.colorScheme.surfaceContainerLow) {
                            CameraTaskEntry(R.string.tether_title, R.string.camera_tether_hint, AppIcons.Outlined.PhotoCamera,
                                "camera-mode-TETHER", !connection.closing && !connection.preparing) { connect(CameraMode.TETHER) }
                        }
                        val previous = tether.run
                        if (previous != null && tether.canResume) {
                            val name = SonyCameraModel.entries.find { it.profileId == previous.profileId }?.displayName.orEmpty()
                            Surface(
                                shape = RoundedCornerShape(10.dp),
                                color = MaterialTheme.colorScheme.surfaceContainerLow,
                                border = BorderStroke(1.dp, MaterialTheme.colorScheme.primary.copy(alpha = 0.45f)),
                                modifier = Modifier.fillMaxWidth().clickable(enabled = !connection.closing && !connection.preparing) {
                                    connect(CameraMode.TETHER, resume = true)
                                }.testTag("camera-resume-tether"),
                            ) {
                                ListItem(
                                    headlineContent = { Text(stringResource(R.string.camera_resume_previous, name), style = MaterialTheme.typography.titleSmall) },
                                    leadingContent = { Icon(AppIcons.Outlined.PhotoCamera, null, tint = MaterialTheme.colorScheme.primary) },
                                    trailingContent = { Icon(AppIcons.AutoMirrored.Outlined.NavigateNext, null) },
                                    colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
                                )
                            }
                        } else if (previous?.status == CameraTetherStatus.PAUSED) {
                            Text(stringResource(R.string.tether_source_error), modifier = Modifier.padding(horizontal = 4.dp, vertical = 4.dp),
                                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        Surface(shape = RoundedCornerShape(10.dp), color = MaterialTheme.colorScheme.surfaceContainerLow) {
                            Column {
                                ListItem(
                                    headlineContent = { Text(stringResource(R.string.camera_history)) },
                                    leadingContent = { Icon(AppIcons.Outlined.History, null) },
                                    trailingContent = { Icon(AppIcons.AutoMirrored.Outlined.NavigateNext, null) },
                                    colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
                                    modifier = Modifier.fillMaxWidth().clickable {
                                        model.setMode(CameraMode.IMPORT); history = true; route = CameraRoute.IMPORT
                                    }.testTag("camera-history"),
                                )
                                HorizontalDivider()
                                ListItem(
                                    headlineContent = { Text(stringResource(R.string.camera_save_location)) },
                                    leadingContent = { Icon(Icons.Outlined.Settings, null) },
                                    trailingContent = { Icon(AppIcons.AutoMirrored.Outlined.NavigateNext, null) },
                                    colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
                                    modifier = Modifier.fillMaxWidth().clickable { settings = true }.testTag("camera-destination-settings"),
                                )
                            }
                        }
                        if (connection.closing) LinearProgressIndicator(Modifier.fillMaxWidth().padding(vertical = 8.dp))
                    }
                }
            }
        }
        CameraRoute.CONNECT -> CameraConnectionScreen(model, onBack = {
            model.disconnect(); route = connectReturn
        }, onHelp = { route = CameraRoute.HELP })
        CameraRoute.HELP -> CameraConnectionHelpScreen(onBack = { route = CameraRoute.CONNECT })
        CameraRoute.IMPORT -> CameraImportScreen(model, onBack = ::home, onOpen = onOpen, onViewInAlbum = onViewInAlbum,
            showTask = showTask || returnToTask, onTaskShown = { returnToTask = false; onTaskShown() },
            showHistory = history, onHistoryShown = { history = false }, onConnect = { task -> connect(CameraMode.IMPORT, task = task) })
        CameraRoute.TETHER -> CameraTetherScreen(model, storage, onBack = ::home, onOpen = onOpen,
            onConnect = { resume -> connect(CameraMode.TETHER, resume = resume) }, onImport = { connect(CameraMode.IMPORT) },
            onHistory = { model.setMode(CameraMode.IMPORT); history = true; route = CameraRoute.IMPORT })
    }
    if (settings) CameraImportSettings(connection.destination,
        onSave = { model.setDestination(it); settings = false }, onDismiss = { settings = false })
}

@Composable
private fun CameraTaskEntry(title: Int, detail: Int, icon: ImageVector, tag: String, enabled: Boolean, onClick: () -> Unit) {
    ListItem(headlineContent = { Text(stringResource(title), style = MaterialTheme.typography.titleMedium) },
        supportingContent = { Text(stringResource(detail), style = MaterialTheme.typography.bodyMedium) },
        leadingContent = { Icon(icon, null, tint = MaterialTheme.colorScheme.primary) },
        trailingContent = { Icon(AppIcons.AutoMirrored.Outlined.NavigateNext, null) },
        colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
        modifier = Modifier.fillMaxWidth().clickable(enabled = enabled, onClick = onClick).padding(vertical = 4.dp).testTag(tag))
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CameraConnectionScreen(model: CameraImportViewModel, onBack: () -> Unit, onHelp: () -> Unit) {
    val state by model.state.collectAsStateWithLifecycle()
    val context = androidx.compose.ui.platform.LocalContext.current
    BackHandler(onBack = onBack)
    Scaffold(topBar = {
        TopAppBar(title = { Text(stringResource(if (state.mode == CameraMode.IMPORT) R.string.camera_connect_import else R.string.camera_connect_tether)) }, expandedHeight = 56.dp,
            navigationIcon = { IconButton(onClick = onBack, modifier = Modifier.testTag("camera-back")) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, stringResource(R.string.back)) } })
    }) { insets ->
        Box(Modifier.fillMaxSize().padding(insets), contentAlignment = Alignment.TopCenter) {
            Column(Modifier.widthIn(max = 680.dp).fillMaxWidth().verticalScroll(rememberScrollState()).padding(16.dp)
                .testTag("camera-connect-screen"), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.camera_choose),
                        Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
                    TextButton(onClick = onHelp, modifier = Modifier.testTag("camera-connection-help")) {
                        Text(stringResource(R.string.camera_connection_help))
                    }
                }
                state.message?.let { message ->
                    Surface(
                        shape = RoundedCornerShape(8.dp),
                        color = MaterialTheme.colorScheme.errorContainer.copy(alpha = 0.25f),
                        border = BorderStroke(1.dp, MaterialTheme.colorScheme.error.copy(alpha = 0.45f)),
                    ) {
                        Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(stringResource(message), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
                            if (message == R.string.camera_permissions) {
                                TextButton(
                                    onClick = {
                                        context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                            Uri.fromParts("package", context.packageName, null)))
                                    },
                                    modifier = Modifier.testTag("camera-open-settings"),
                                ) {
                                    Text(stringResource(R.string.camera_open_settings))
                                }
                            }
                        }
                    }
                }
                if (state.closing) Text(stringResource(R.string.camera_connect_wait))
                CameraConnectionPanel(state, model)
                Text(stringResource(R.string.camera_supported), style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CameraConnectionHelpScreen(onBack: () -> Unit) {
    BackHandler(onBack = onBack)
    Scaffold(topBar = {
        TopAppBar(title = { Text(stringResource(R.string.camera_connection_help)) }, navigationIcon = {
            IconButton(onClick = onBack, modifier = Modifier.testTag("camera-back")) {
                Icon(Icons.AutoMirrored.Outlined.ArrowBack, stringResource(R.string.back))
            }
        })
    }) { insets ->
        Box(Modifier.fillMaxSize().padding(insets), contentAlignment = Alignment.TopCenter) {
            Column(Modifier.widthIn(max = 680.dp).fillMaxWidth().verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 12.dp).testTag("camera-connect-help"),
                verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text(stringResource(R.string.camera_guide_intro), style = MaterialTheme.typography.bodyMedium)
            listOf(
                R.string.camera_guide_prepare_title to R.string.camera_guide_prepare,
                R.string.camera_guide_bluetooth_title to R.string.camera_guide_bluetooth,
                R.string.camera_guide_manual_title to R.string.camera_guide_manual,
                R.string.camera_guide_tether_title to R.string.camera_guide_tether,
                R.string.camera_guide_troubleshoot_title to R.string.camera_guide_troubleshoot,
            ).forEach { (title, text) ->
                Text(stringResource(title), style = MaterialTheme.typography.titleMedium)
                Text(stringResource(text), style = MaterialTheme.typography.bodyMedium)
            }
            Text(stringResource(R.string.camera_guide_unverified_title), style = MaterialTheme.typography.titleMedium)
            Text(stringResource(R.string.camera_guide_compatibility), style = MaterialTheme.typography.bodyMedium)
            Text(stringResource(R.string.tether_foreground), style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}
