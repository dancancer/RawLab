package com.rawlab.android.camera

import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.NavigateNext
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.PhotoCamera
import androidx.compose.material.icons.outlined.PhotoLibrary
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
    var menu by remember { mutableStateOf(false) }
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
                    } }, actions = {
                        Box {
                            IconButton(onClick = { menu = true }, modifier = Modifier.testTag("camera-menu")) { Icon(Icons.Outlined.MoreVert, stringResource(R.string.more)) }
                            DropdownMenu(menu, { menu = false }) {
                                DropdownMenuItem(text = { Text(stringResource(R.string.camera_history)) }, leadingIcon = { Icon(Icons.Outlined.History, null) },
                                    modifier = Modifier.testTag("camera-history"), onClick = { menu = false; model.setMode(CameraMode.IMPORT); history = true; route = CameraRoute.IMPORT })
                                DropdownMenuItem(text = { Text(stringResource(R.string.camera_save_location)) }, leadingIcon = { Icon(Icons.Outlined.Settings, null) },
                                    modifier = Modifier.testTag("camera-destination-settings"), onClick = { menu = false; settings = true })
                            }
                        }
                    })
            }) { insets ->
                Column(Modifier.fillMaxSize().padding(insets).verticalScroll(rememberScrollState()).testTag("camera-home")) {
                    val previousCamera = tether.run?.profileId?.let { id -> SonyCameraModel.entries.firstOrNull { it.profileId == id } }
                    Column(Modifier.padding(horizontal = 20.dp, vertical = 24.dp).testTag("camera-identity"), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(if (connection.connected) connection.model.displayName else previousCamera?.displayName ?: stringResource(R.string.camera_title), style = MaterialTheme.typography.headlineSmall)
                        Text(stringResource(if (previousCamera == null) R.string.camera_choose_connection else R.string.camera_previous_disconnected),
                            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    CameraTaskEntry(R.string.camera_import, R.string.camera_import_hint, Icons.Outlined.PhotoLibrary,
                        "camera-mode-IMPORT", !connection.closing && !connection.preparing) {
                        if (connection.connected && connection.mode == CameraMode.IMPORT) route = CameraRoute.IMPORT else connect(CameraMode.IMPORT)
                    }
                    HorizontalDivider(Modifier.padding(horizontal = 16.dp))
                    CameraTaskEntry(R.string.tether_title, R.string.camera_tether_hint, Icons.Outlined.PhotoCamera,
                        "camera-mode-TETHER", !connection.closing && !connection.preparing) { connect(CameraMode.TETHER) }
                    val previous = tether.run
                    if (previous != null && tether.canResume) {
                        val name = SonyCameraModel.entries.find { it.profileId == previous.profileId }?.displayName.orEmpty()
                        TextButton(onClick = { connect(CameraMode.TETHER, resume = true) }, enabled = !connection.closing && !connection.preparing,
                            modifier = Modifier.padding(horizontal = 56.dp).testTag("camera-resume-tether")) {
                            Text(stringResource(R.string.camera_resume_previous, name))
                        }
                    } else if (previous?.status == CameraTetherStatus.PAUSED) {
                        Text(stringResource(R.string.tether_source_error), modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    if (connection.closing) LinearProgressIndicator(Modifier.fillMaxWidth().padding(16.dp))
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
        trailingContent = { Icon(Icons.AutoMirrored.Outlined.NavigateNext, null) },
        modifier = Modifier.fillMaxWidth().clickable(enabled = enabled, onClick = onClick).padding(vertical = 8.dp).testTag(tag))
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CameraConnectionScreen(model: CameraImportViewModel, onBack: () -> Unit, onHelp: () -> Unit) {
    val state by model.state.collectAsStateWithLifecycle()
    BackHandler(onBack = onBack)
    Scaffold(topBar = {
        TopAppBar(title = { Text(stringResource(if (state.mode == CameraMode.IMPORT) R.string.camera_connect_import else R.string.camera_connect_tether)) }, expandedHeight = 56.dp,
            navigationIcon = { IconButton(onClick = onBack, modifier = Modifier.testTag("camera-back")) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, stringResource(R.string.back)) } })
    }) { insets ->
        Column(Modifier.fillMaxSize().padding(insets).verticalScroll(rememberScrollState()).padding(16.dp)
            .testTag("camera-connect-screen"), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.camera_choose),
                    Modifier.weight(1f), style = MaterialTheme.typography.titleMedium)
                TextButton(onClick = onHelp, modifier = Modifier.testTag("camera-connection-help")) {
                    Text(stringResource(R.string.camera_connection_help))
                }
            }
            state.message?.let { Text(stringResource(it), color = MaterialTheme.colorScheme.error) }
            if (state.closing) Text(stringResource(R.string.camera_connect_wait))
            CameraConnectionPanel(state, model)
            Text(stringResource(R.string.camera_supported), style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
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
        Column(Modifier.fillMaxSize().padding(insets).verticalScroll(rememberScrollState())
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
