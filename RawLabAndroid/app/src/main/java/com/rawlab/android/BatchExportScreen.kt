package com.rawlab.android

import android.net.Uri
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.border
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BatchExportScreen(
    model: BatchExportModel,
    storage: PhotoStorage,
    onBack: () -> Unit,
) {
    val context = LocalContext.current
    val state by model.state.collectAsStateWithLifecycle()
    var album by rememberSaveable { mutableStateOf(false) }
    var discard by remember { mutableStateOf(false) }
    var effectTarget by remember { mutableStateOf<BatchRow?>(null) }
    var png by rememberSaveable(state.job.id) { mutableStateOf(state.job.outputPng) }
    var exportSizeKey by rememberSaveable(state.job.id) {
        mutableStateOf(exportSizeChoice(state.job.outputLongEdge).key)
    }
    var exportCustomSize by rememberSaveable(state.job.id) {
        mutableStateOf(if (state.job.outputLongEdge != null && exportSizeChoice(state.job.outputLongEdge) == ExportSizeChoice.CUSTOM)
            state.job.outputLongEdge.toString() else "")
    }
    var destination by rememberSaveable(state.job.id) { mutableStateOf<Uri?>(state.job.destination?.let(Uri::parse)) }
    val files = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { model.addUris(it) }
    val directory = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        if (uri != null) {
            runCatching { context.contentResolver.takePersistableUriPermission(uri, android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION or android.content.Intent.FLAG_GRANT_WRITE_URI_PERMISSION) }
            destination = uri
            model.setDestination(uri)
        }
    }
    BackHandler { if (state.phase !in setOf(BatchPhase.RUNNING, BatchPhase.PREPARING)) onBack() }

    if (album) {
        var selected by rememberSaveable { mutableStateOf(state.job.rows.map { it.id }) }
        AlbumScreen(storage, onBack = { album = false }, onFile = { album = false; files.launch(arrayOf("*/*")) },
            onPhoto = { uri -> selected = if (uri.toString() in selected) selected - uri.toString() else selected + uri.toString() },
            selectedPhotos = selected.toSet(), onDone = {
                state.job.rows.filter { it.id !in selected }.forEach { model.remove(it.id) }
                model.addUris(selected.filter { id -> state.job.rows.none { it.id == id } }.map(Uri::parse))
                album = false
            })
        return
    }

    Scaffold(topBar = {
        TopAppBar(title = { Text(stringResource(R.string.batch_export)) }, navigationIcon = {
            IconButton(onClick = onBack, enabled = state.phase != BatchPhase.RUNNING && state.phase != BatchPhase.PREPARING) {
                Icon(Icons.AutoMirrored.Outlined.ArrowBack, stringResource(R.string.back))
            }
        })
    }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            when (state.phase) {
                BatchPhase.SELECTING -> BatchConfirmContent(state, storage, png, destination,
                    ExportSizeChoice.fromKey(exportSizeKey), exportCustomSize,
                    onAlbum = { album = true }, onFiles = { files.launch(arrayOf("*/*")) },
                    onDirectory = { directory.launch(null) }, onAlbumOutput = { destination = null; model.setDestination(null) }, onPng = { png = it },
                    onSize = { choice -> exportSizeKey = choice.key }, onCustomSize = { exportCustomSize = it },
                    onRemove = model::remove, onInspect = { effectTarget = it },
                    onStart = { model.start(png, destination, ExportSize.parse(ExportSizeChoice.fromKey(exportSizeKey), exportCustomSize)) })
                BatchPhase.PREPARING, BatchPhase.RUNNING -> BatchProgressContent(state, model::cancel)
                BatchPhase.COMPLETE, BatchPhase.CANCELLED, BatchPhase.FAILED -> BatchResultContent(state,
                    onRetry = model::retryFailed, onClose = onBack, onDirectory = { directory.launch(state.destination) },
                    onConfirm = model::confirmOutput, onDiscard = { discard = true })
            }
        }
    }
    if (discard) AlertDialog(onDismissRequest = { discard = false }, title = { Text("放弃批量任务？") },
        text = { Text("已保存的照片会保留。") },
        confirmButton = { TextButton(onClick = { if (model.discard()) onBack(); discard = false }) { Text("放弃任务") } },
        dismissButton = { TextButton(onClick = { discard = false }) { Text("取消") } })
    effectTarget?.let { row ->
        var preview by remember(row.id) { mutableStateOf<android.graphics.Bitmap?>(null) }
        var error by remember(row.id) { mutableStateOf<String?>(null) }
        LaunchedEffect(row.id) {
            try { preview = model.preview(row.target) }
            catch (failure: Exception) { error = failure.message }
        }
        AlertDialog(onDismissRequest = { effectTarget = null }, title = { Text(row.target.displayName) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box(Modifier.fillMaxWidth().aspectRatio(1f), contentAlignment = Alignment.Center) {
                        preview?.let { Image(it.asImageBitmap(), row.target.displayName, Modifier.fillMaxSize(), contentScale = ContentScale.Fit) }
                        if (preview == null && error == null) CircularProgressIndicator()
                        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                    }
                }
            }, confirmButton = { TextButton(onClick = { effectTarget = null }) { Text(stringResource(R.string.confirm)) } })
    }
}

@Composable
private fun BatchConfirmContent(
    state: BatchExportState,
    storage: PhotoStorage,
    png: Boolean,
    destination: Uri?,
    sizeChoice: ExportSizeChoice,
    customSize: String,
    onAlbum: () -> Unit,
    onFiles: () -> Unit,
    onDirectory: () -> Unit,
    onAlbumOutput: () -> Unit,
    onPng: (Boolean) -> Unit,
    onSize: (ExportSizeChoice) -> Unit,
    onCustomSize: (String) -> Unit,
    onRemove: (String) -> Unit,
    onInspect: (BatchRow) -> Unit,
    onStart: () -> Unit,
) {
    var showSettings by rememberSaveable { mutableStateOf(false) }
    Column(Modifier.fillMaxSize()) {
    LazyColumn(Modifier.fillMaxWidth().weight(1f), contentPadding = PaddingValues(bottom = 12.dp)) {
        item {
            Text("调整来源", style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(20.dp, 16.dp, 20.dp, 8.dp))
            Row(Modifier.padding(horizontal = 20.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(Modifier.size(80.dp)) { BatchThumbnail(storage, state.job.source.identity.value, state.job.source.sourceFile) }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(state.job.source.displayName, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    val settings = state.job.source.settings
                    Text("${Film.all.firstOrNull { it.id == settings.film }?.name ?: settings.film} · ${String.format("%.0f", settings.strength * 100f)}%",
                        color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
                    Text(String.format("曝光 %+.2f EV", settings.exposure), style = MaterialTheme.typography.bodySmall)
                }
            }
        }
        item {
            Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = onAlbum, modifier = Modifier.weight(1f)) { Icon(Icons.Outlined.PhotoLibrary, null); Spacer(Modifier.width(6.dp)); Text("相册多选") }
                OutlinedButton(onClick = onFiles, modifier = Modifier.weight(1f)) { Icon(Icons.Outlined.FolderOpen, null); Spacer(Modifier.width(6.dp)); Text("文件多选") }
            }
        }
        item {
            Text("目标照片（已选 ${state.selectedCount} 张）", style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.padding(20.dp, 20.dp, 20.dp, 8.dp))
        }
        if (state.job.rows.isEmpty()) item {
            Text("请选择要套用当前调整的 RAW 照片", color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp))
        }
        items(state.job.rows, key = { it.id }) { row ->
            Row(Modifier.fillMaxWidth().clickable { onInspect(row) }.padding(horizontal = 20.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(56.dp)) { BatchThumbnail(storage, row.target.sourceUri, row.target.sourceFile) }
                Spacer(Modifier.width(12.dp))
                Text(row.target.displayName, Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                TextButton(onClick = { onInspect(row) }) { Text("查看") }
                IconButton(onClick = { onRemove(row.id) }) { Icon(Icons.Outlined.Close, "移除") }
            }
        }
        item {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp)) {
                Text("全部调整", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                TextButton(onClick = { showSettings = !showSettings }) { Text(if (showSettings) "收起" else "展开") }
            }
            if (showSettings) SettingsSummary(state.job.source.settings)
        }
        item {
            Text("输出", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(20.dp, 16.dp, 20.dp, 4.dp))
            Row(Modifier.padding(horizontal = 20.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(selected = !png, onClick = { onPng(false) }, label = { Text(stringResource(R.string.jpeg)) })
                FilterChip(selected = png, onClick = { onPng(true) }, label = { Text(stringResource(R.string.png)) })
            }
            Row(Modifier.padding(horizontal = 20.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (Build.VERSION.SDK_INT >= 29) {
                    FilterChip(selected = destination == null, onClick = onAlbumOutput, label = { Text("照片图库") })
                }
                OutlinedButton(onClick = onDirectory) { Icon(Icons.Outlined.FolderOpen, null); Spacer(Modifier.width(4.dp)); Text("选择目录") }
            }
            ExportSizeControls(
                selected = sizeChoice,
                customText = customSize,
                onSelected = onSize,
                onCustomText = onCustomSize,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp),
            )
            Text(destination?.lastPathSegment ?: "照片图库", Modifier.padding(horizontal = 20.dp), maxLines = 2, overflow = TextOverflow.Ellipsis)
            state.error?.let { Text(it, Modifier.padding(20.dp), color = MaterialTheme.colorScheme.error) }
        }
    }
    Text("仅用于本次导出，保留各照片原有调整", Modifier.padding(horizontal = 20.dp), style = MaterialTheme.typography.bodySmall)
    val longEdge = ExportSize.parse(sizeChoice, customSize)
    val sizeValid = sizeChoice != ExportSizeChoice.CUSTOM || longEdge != null
    Button(onClick = onStart, enabled = sizeValid && state.job.rows.isNotEmpty() && (Build.VERSION.SDK_INT >= 29 || destination != null), modifier = Modifier.fillMaxWidth().padding(20.dp)) {
        Text("导出 ${state.job.rows.size} 张")
    }
    }
}

private fun exportSizeChoice(longEdge: Int?): ExportSizeChoice = when (longEdge) {
    null -> ExportSizeChoice.ORIGINAL
    2048 -> ExportSizeChoice.EDGE_2048
    3000 -> ExportSizeChoice.EDGE_3000
    4096 -> ExportSizeChoice.EDGE_4096
    else -> ExportSizeChoice.CUSTOM
}

@Composable
private fun BatchProgressContent(state: BatchExportState, onCancel: () -> Unit) {
    Column(Modifier.fillMaxSize().padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(if (state.stopping) "正在停止" else if (state.phase == BatchPhase.PREPARING) "正在准备" else "正在导出", style = MaterialTheme.typography.titleLarge)
        LinearProgressIndicator(progress = { (state.successCount + state.failedCount).toFloat() / state.job.rows.size.coerceAtLeast(1) }, modifier = Modifier.fillMaxWidth())
        Text("已完成 ${state.successCount} / ${state.job.rows.size}")
        LazyColumn(Modifier.weight(1f)) { items(state.job.rows, key = { it.id }) { row -> BatchRowLine(row) } }
        OutlinedButton(onClick = onCancel, enabled = !state.stopping, modifier = Modifier.fillMaxWidth()) { Text(if (state.stopping) "正在停止" else stringResource(R.string.cancel)) }
    }
}

@Composable
private fun BatchResultContent(state: BatchExportState, onRetry: () -> Unit, onClose: () -> Unit,
    onDirectory: () -> Unit, onConfirm: (String, Boolean) -> Unit, onDiscard: () -> Unit) {
    Column(Modifier.fillMaxSize().padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(if (state.phase == BatchPhase.COMPLETE) "导出完成" else if (state.failedCount > 0) "部分导出失败" else "导出结果", style = MaterialTheme.typography.titleLarge)
        Text("成功 ${state.successCount} 张，失败 ${state.failedCount} 张，未处理 ${state.unfinishedCount - state.failedCount} 张")
        state.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        LazyColumn(Modifier.weight(1f)) { items(state.job.rows, key = { it.id }) { row ->
            BatchRowLine(row)
            if (row.status == BatchRowStatus.NEEDS_CONFIRMATION) {
                Text("上次保存结果不确定，请先核对图库或输出目录。", style = MaterialTheme.typography.bodySmall)
                Row {
                    TextButton(onClick = { onConfirm(row.id, true) }) { Text("已找到输出") }
                    TextButton(onClick = { onConfirm(row.id, false) }) { Text("未保存，重新导出") }
                }
            }
        } }
        if (state.unfinishedCount > 0) OutlinedButton(onClick = onDirectory, modifier = Modifier.fillMaxWidth()) { Icon(Icons.Outlined.FolderOpen, null); Text("重新选择输出目录") }
        if (state.unfinishedCount > 0) Button(onClick = onRetry, modifier = Modifier.fillMaxWidth()) { Icon(Icons.Outlined.Refresh, null); Spacer(Modifier.width(6.dp)); Text(if (state.failedCount == state.unfinishedCount) "重试失败项" else "继续未完成项") }
        OutlinedButton(onClick = onClose, modifier = Modifier.fillMaxWidth()) { Text("关闭") }
        if (state.phase != BatchPhase.COMPLETE) TextButton(onClick = onDiscard, modifier = Modifier.fillMaxWidth()) { Text("放弃任务") }
    }
}

@Composable
private fun BatchRowLine(row: BatchRow) {
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        val icon = when (row.status) {
            BatchRowStatus.SUCCESS -> Icons.Outlined.CheckCircle
            BatchRowStatus.FAILED -> Icons.Outlined.Close
            else -> Icons.Outlined.Refresh
        }
        Icon(icon, row.status.name, tint = if (row.status == BatchRowStatus.FAILED) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary)
        Spacer(Modifier.width(8.dp))
        Column(Modifier.weight(1f)) {
            Text(row.target.displayName, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(when (row.status) {
                BatchRowStatus.PENDING -> "等待导出"
                BatchRowStatus.PROCESSING -> "正在处理"
                BatchRowStatus.PUBLISHING -> "正在保存"
                BatchRowStatus.NEEDS_CONFIRMATION -> "待核对"
                BatchRowStatus.SUCCESS -> "已保存"
                BatchRowStatus.FAILED -> "失败"
                BatchRowStatus.CANCELLED -> "已取消"
            }, style = MaterialTheme.typography.labelSmall)
            row.error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
        }
    }
}

@Composable
private fun SettingsSummary(settings: EditSettings) {
    Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        SettingLine("胶片", settings.film)
        SettingLine("强度", String.format("%.0f%%", settings.strength * 100))
        SettingLine("曝光", String.format("%+.2f EV", settings.exposure))
        SettingLine("高光", String.format("%+.0f%%", settings.highlights * 100))
        SettingLine("阴影", String.format("%+.0f%%", settings.shadows * 100))
        SettingLine("对比度", String.format("%+.0f%%", settings.contrast * 100))
        SettingLine("S 曲线", String.format("%+.0f%%", settings.toneCurve * 100))
        SettingLine("饱和度", String.format("%+.0f%%", settings.saturation * 100))
        SettingLine("白平衡", if (settings.customWb) "自定义" else "各照片拍摄时设置")
        if (settings.customWb) {
            SettingLine("色温", String.format("%.0f K", settings.temperature))
            SettingLine("色调", String.format("%+.0f", settings.tint))
        }
        SettingLine("锐化", String.format("%.0f%%", settings.sharpening * 100))
        SettingLine("降噪", if (settings.denoise.enabled) "开启" else "关闭")
        SettingLine("亮度降噪", String.format("%.0f", settings.denoise.luma))
        SettingLine("色彩降噪", String.format("%.0f", settings.denoise.chroma))
        SettingLine("粗颗粒降噪", String.format("%.0f", settings.denoise.coarse))
    }
}

@Composable
private fun SettingLine(title: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp)) { Text(title, Modifier.weight(1f)); Text(value, color = MaterialTheme.colorScheme.onSurfaceVariant) }
}

@Composable
private fun BatchThumbnail(storage: PhotoStorage, uri: String?, file: java.io.File) {
    val thumbnail by produceState<android.graphics.Bitmap?>(null, uri) {
        value = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            uri?.let { storage.thumbnail(Uri.parse(it)) } ?: runCatching {
                val exif = androidx.exifinterface.media.ExifInterface(file)
                val original = exif.thumbnailBitmap ?: return@runCatching null
                val matrix = android.graphics.Matrix().apply {
                    if (exif.isFlipped) postScale(-1f, 1f)
                    postRotate(exif.rotationDegrees.toFloat())
                }
                android.graphics.Bitmap.createBitmap(original, 0, 0, original.width, original.height, matrix, true)
            }.getOrNull()
        }
    }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        thumbnail?.let { Image(it.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.Fit) }
            ?: Icon(Icons.Outlined.PhotoLibrary, null)
    }
}
