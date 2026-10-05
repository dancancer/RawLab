package com.rawlab.android

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.staggeredgrid.StaggeredGridCells
import androidx.compose.foundation.lazy.staggeredgrid.LazyVerticalStaggeredGrid
import androidx.compose.foundation.lazy.staggeredgrid.items
import androidx.compose.foundation.lazy.staggeredgrid.rememberLazyStaggeredGridState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.max
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AlbumScreen(storage: PhotoStorage, onBack: () -> Unit, onFile: () -> Unit, onPhoto: (Uri) -> Unit) {
    BackHandler(onBack = onBack)
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    var refresh by remember { mutableIntStateOf(0) }
    var access by remember { mutableStateOf(AlbumAccess.Level.NONE) }
    var photos by remember { mutableStateOf<List<AlbumPhoto>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var failed by remember { mutableStateOf(false) }
    var bucket by rememberSaveable { mutableStateOf<String?>(null) }
    var columns by rememberSaveable { mutableIntStateOf(3) }
    var squareThumbnails by rememberSaveable { mutableStateOf(false) }
    var viewMenu by remember { mutableStateOf(false) }
    val gridState = rememberLazyGridState()
    val staggeredState = rememberLazyStaggeredGridState()
    // 密度改变时保留首张可见照片，旧像素偏移可能已超过缩小后的整张缩略图。
    fun anchorVisiblePhoto(square: Boolean) {
        val index = if (squareThumbnails) gridState.firstVisibleItemIndex else staggeredState.firstVisibleItemIndex
        if (square) gridState.requestScrollToItem(index) else staggeredState.requestScrollToItem(index)
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { refresh++ }
    DisposableEffect(owner) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_RESUME) refresh++ }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(refresh) {
        photos = emptyList()
        loading = true
        failed = false
        val granted = AlbumAccess.permissions(Build.VERSION.SDK_INT).filter {
            context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
        }.toSet()
        access = AlbumAccess.level(Build.VERSION.SDK_INT, granted)
        try {
            photos = if (access == AlbumAccess.Level.NONE) emptyList() else withContext(Dispatchers.IO) { storage.album() }
            if (bucket != null && photos.none { it.album == bucket }) bucket = null
        } catch (error: Exception) {
            if (error is kotlinx.coroutines.CancellationException) throw error
            failed = true
        } finally { loading = false }
    }
    Scaffold(topBar = {
        TopAppBar(title = { Text(stringResource(R.string.open_album)) }, navigationIcon = {
            ToolIcon(Icons.AutoMirrored.Outlined.ArrowBack, R.string.back, onClick = onBack)
        }, actions = {
            Box {
                ToolIcon(Icons.Outlined.GridView, R.string.album_view_options) { viewMenu = true }
                DropdownMenu(expanded = viewMenu, onDismissRequest = { viewMenu = false }) {
                    for (square in listOf(true, false)) {
                        DropdownMenuItem(
                            text = { Text(stringResource(if (square) R.string.album_square else R.string.album_original_ratio)) },
                            modifier = Modifier.semantics { selected = squareThumbnails == square },
                            leadingIcon = { Icon(if (square) Icons.Outlined.CropSquare else Icons.Outlined.AspectRatio, null) },
                            trailingIcon = { if (squareThumbnails == square) Icon(Icons.Outlined.Check, null) },
                            onClick = {
                                if (squareThumbnails != square) anchorVisiblePhoto(square)
                                squareThumbnails = square
                                viewMenu = false
                            },
                        )
                    }
                    HorizontalDivider()
                    for (count in 1..6) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.album_columns, count)) },
                            modifier = Modifier.semantics { selected = columns == count },
                            trailingIcon = { if (columns == count) Icon(Icons.Outlined.Check, null) },
                            onClick = {
                                if (columns != count) anchorVisiblePhoto(squareThumbnails)
                                columns = count
                                viewMenu = false
                            },
                        )
                    }
                }
            }
            ToolIcon(Icons.Outlined.FolderOpen, R.string.open_file, onClick = onFile)
            ToolIcon(Icons.Outlined.Refresh, R.string.refresh, onClick = { refresh++ })
        })
    }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            if (access == AlbumAccess.Level.NONE) {
                Column(Modifier.fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(stringResource(R.string.permission_title), style = MaterialTheme.typography.titleLarge)
                    Text(stringResource(R.string.permission_body), style = MaterialTheme.typography.bodyMedium)
                    Button(onClick = { permission.launch(AlbumAccess.permissions(Build.VERSION.SDK_INT).toTypedArray()) }) {
                        Text(stringResource(R.string.grant_access))
                    }
                    TextButton(onClick = { context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))) }) {
                        Text(stringResource(R.string.settings))
                    }
                    OutlinedButton(onClick = onFile) { Text(stringResource(R.string.open_file)) }
                }
            } else {
                if (access == AlbumAccess.Level.PARTIAL) {
                    Column(Modifier.padding(horizontal = 16.dp)) {
                        Text(stringResource(R.string.partial_access), style = MaterialTheme.typography.bodyMedium)
                        TextButton(onClick = { permission.launch(AlbumAccess.permissions(Build.VERSION.SDK_INT).toTypedArray()) }) {
                            Text(stringResource(R.string.select_more))
                        }
                    }
                }
                LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    item { FilterChip(selected = bucket == null, onClick = { bucket = null }, label = { Text(stringResource(R.string.all_albums)) }) }
                    items(photos.map { it.album }.distinct()) { name ->
                        FilterChip(selected = bucket == name, onClick = { bucket = name }, label = { Text(name) })
                    }
                }
                if (loading) LinearProgressIndicator(Modifier.fillMaxWidth())
                if (failed || (!loading && photos.isEmpty())) {
                    Column(Modifier.padding(24.dp)) {
                        Text(stringResource(if (failed) R.string.album_error else R.string.album_empty))
                        TextButton(onClick = onFile) { Text(stringResource(R.string.open_file)) }
                    }
                }
                // 查询期间不让空网格重测，将保存的位置保留到照片列表恢复。
                val spacing = if (columns >= 5) 4.dp else 8.dp
                if (photos.isNotEmpty()) {
                    val visiblePhotos = photos.filter { bucket == null || it.album == bucket }
                    if (squareThumbnails) {
                        LazyVerticalGrid(state = gridState, columns = GridCells.Fixed(columns), contentPadding = PaddingValues(spacing),
                            horizontalArrangement = Arrangement.spacedBy(spacing), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            items(visiblePhotos, key = { it.uri.toString() }) { photo ->
                                AlbumPhotoItem(storage, photo, true, refresh, onPhoto)
                            }
                        }
                    } else {
                        LazyVerticalStaggeredGrid(state = staggeredState,
                            columns = StaggeredGridCells.Fixed(columns), contentPadding = PaddingValues(spacing),
                            horizontalArrangement = Arrangement.spacedBy(spacing), verticalItemSpacing = 12.dp) {
                            items(visiblePhotos, key = { it.uri.toString() }) { photo ->
                                AlbumPhotoItem(storage, photo, false, refresh, onPhoto)
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun AlbumPhotoItem(storage: PhotoStorage, photo: AlbumPhoto, square: Boolean, refresh: Int, onPhoto: (Uri) -> Unit) {
    Column(Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable { onPhoto(photo.uri) }) {
        AlbumThumbnail(storage, photo, square, refresh)
        Text(photo.name, minLines = 2, maxLines = 2, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.labelMedium,
            modifier = Modifier.padding(top = 4.dp))
    }
}

@Composable
internal fun AlbumThumbnail(storage: PhotoStorage, photo: AlbumPhoto, square: Boolean, refresh: Int) {
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val widthPixels = with(LocalDensity.current) { maxWidth.toPx() }
        val sourceRatio = photo.aspectRatio
        val size = (widthPixels * max(1f, 1f / (sourceRatio ?: 1f))).roundToInt().coerceIn(128, 1024)
        val thumbnail by produceState<android.graphics.Bitmap?>(null, photo.uri, refresh, size) {
            value = withContext(Dispatchers.IO) { storage.thumbnail(photo.uri, size, photo.orientation) }
        }
        val bitmap = thumbnail
        val ratio = if (square) 1f else sourceRatio ?: bitmap?.let { it.width.toFloat() / it.height } ?: 1f
        Box(Modifier.fillMaxWidth().aspectRatio(ratio), contentAlignment = Alignment.Center) {
            if (bitmap != null) Image(bitmap.asImageBitmap(), photo.name, Modifier.fillMaxSize(),
                contentScale = if (square) ContentScale.Crop else ContentScale.Fit)
            else Icon(Icons.Outlined.Image, photo.name, Modifier.size(40.dp))
        }
    }
}
