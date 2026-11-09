package com.rawlab.android.album

import android.content.Intent
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import java.io.File
import com.rawlab.android.photo.EditedPhotoPreviews
import com.rawlab.android.photo.PhotoEditFilter
import com.rawlab.android.settings.EditStore
import androidx.compose.ui.semantics.stateDescription
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
import androidx.compose.ui.platform.testTag
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
import com.rawlab.android.R
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.photo.AlbumPhoto
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.ui.ToolIcon

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AlbumScreen(storage: PhotoStorage, onBack: () -> Unit, onFile: (() -> Unit)?, onPhoto: (Uri) -> Unit,
    selectedPhotos: Set<String>? = null, onDone: (() -> Unit)? = null,
    doneLabel: String? = null, doneEnabled: Boolean = true, initialPhotos: Set<String>? = null) {
    BackHandler(onBack = onBack)
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    var refresh by remember { mutableIntStateOf(0) }
    var editRevision by remember { mutableIntStateOf(0) }
    val previews = remember(context) { EditedPhotoPreviews(context) }
    val foregroundBusy by EditedPhotoPreviews.foregroundBusy.collectAsState()
    var editFilter by rememberSaveable { mutableStateOf(PhotoEditFilter.ALL) }
    var editedFlags by remember { mutableStateOf<Map<String, Boolean>>(emptyMap()) }
    var editStatusFailed by remember { mutableStateOf(false) }
    var access by remember { mutableStateOf(AlbumAccess.Level.NONE) }
    var photos by remember { mutableStateOf<List<AlbumPhoto>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var failed by remember { mutableStateOf(false) }
    var bucket by rememberSaveable(initialPhotos) { mutableStateOf<String?>(null) }
    var focused by rememberSaveable(initialPhotos) { mutableStateOf(!initialPhotos.isNullOrEmpty()) }
    val preferences = remember { context.getSharedPreferences("album_layout", android.content.Context.MODE_PRIVATE) }
    var columns by rememberSaveable { mutableIntStateOf(preferences.getInt("columns", 3).coerceIn(1, 6)) }
    var squareThumbnails by rememberSaveable { mutableStateOf(preferences.getBoolean("square", false)) }
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
    DisposableEffect(previews) { onDispose { previews.close() } }
    DisposableEffect(context) {
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) { refresh++ }
        }
        context.contentResolver.registerContentObserver(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true, observer)
        onDispose { context.contentResolver.unregisterContentObserver(observer) }
    }
    LaunchedEffect(previews) {
        val directory = File(context.filesDir, "edits").canonicalPath
        EditStore.changes.collect { if (it.directory == directory) editRevision++ }
    }
    LaunchedEffect(previews, "ready") { EditedPhotoPreviews.ready.collect { editRevision++ } }
    LaunchedEffect(photos, editRevision) {
        try { editedFlags = previews.states(photos); editStatusFailed = false }
        catch (error: Exception) {
            if (error is kotlinx.coroutines.CancellationException) throw error
            editStatusFailed = true
        }
    }
    LaunchedEffect(refresh) {
        loading = true
        failed = false
        val granted = AlbumAccess.permissions(Build.VERSION.SDK_INT).filter {
            context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
        }.toSet()
        access = AlbumAccess.level(Build.VERSION.SDK_INT, granted)
        try {
            photos = withContext(Dispatchers.IO) { storage.album(ownOnly = access == AlbumAccess.Level.NONE) }
            if (bucket != null && photos.none { it.albumId == bucket }) bucket = null
        } catch (error: Exception) {
            if (error is kotlinx.coroutines.CancellationException) throw error
            failed = true
        } finally { loading = false }
    }
    Scaffold(topBar = {
        TopAppBar(title = { Text(stringResource(R.string.open_album)) }, navigationIcon = {
            ToolIcon(Icons.AutoMirrored.Outlined.ArrowBack, R.string.back, onClick = onBack)
        }, actions = {
            if (onDone != null) TextButton(onClick = onDone, enabled = doneEnabled) {
                Text(doneLabel ?: AppStrings.format(R.string.message_confirm_photos, (selectedPhotos?.size ?: 0).toString()))
            }
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
                                preferences.edit().putBoolean("square", square).apply()
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
                                preferences.edit().putInt("columns", count).apply()
                                viewMenu = false
                            },
                        )
                    }
                }
            }
            if (onFile != null) ToolIcon(Icons.Outlined.FolderOpen, R.string.open_file, onClick = onFile)
            ToolIcon(Icons.Outlined.Refresh, R.string.refresh, onClick = { refresh++ })
        })
    }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).testTag("album-root")) {
            if (access == AlbumAccess.Level.NONE && photos.isEmpty() && !loading && !failed && !focused) {
                Column(Modifier.fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(stringResource(R.string.permission_title), style = MaterialTheme.typography.titleLarge)
                    Text(stringResource(R.string.permission_body), style = MaterialTheme.typography.bodyMedium)
                    Button(onClick = { permission.launch(AlbumAccess.permissions(Build.VERSION.SDK_INT).toTypedArray()) }) {
                        Text(stringResource(R.string.grant_access))
                    }
                    TextButton(onClick = { context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))) }) {
                        Text(stringResource(R.string.settings))
                    }
                    if (onFile != null) OutlinedButton(onClick = onFile) { Text(stringResource(R.string.open_file)) }
                }
            } else {
                if (access == AlbumAccess.Level.NONE || access == AlbumAccess.Level.PARTIAL) {
                    Column(Modifier.padding(horizontal = 16.dp)) {
                        Text(stringResource(if (access == AlbumAccess.Level.NONE) R.string.album_own_photos else R.string.partial_access),
                            style = MaterialTheme.typography.bodyMedium)
                        TextButton(onClick = { permission.launch(AlbumAccess.permissions(Build.VERSION.SDK_INT).toTypedArray()) }) {
                            Text(stringResource(if (access == AlbumAccess.Level.NONE) R.string.grant_access else R.string.select_more))
                        }
                    }
                }
                if (focused) Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.camera_this_import), Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
                    TextButton(onClick = { focused = false; bucket = null }) { Text(stringResource(R.string.camera_view_all_photos)) }
                }
                val shownPhotos = if (focused) photos.filter { it.uri.toString() in initialPhotos.orEmpty() } else photos
                val groups = shownPhotos.distinctBy { it.albumId }
                val repeatedNames = groups.groupingBy { it.album }.eachCount().filterValues { it > 1 }.keys
                LazyRow(modifier = Modifier.testTag("album-groups"), contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    item { FilterChip(selected = bucket == null, onClick = { bucket = null }, label = { Text(stringResource(R.string.all_albums)) }) }
                    items(groups, key = { it.albumId }) { group ->
                        val name = if (group.album in repeatedNames) group.relativePath?.trimEnd('/')?.removePrefix("Pictures/") ?: group.album else group.album
                        FilterChip(selected = bucket == group.albumId, onClick = { bucket = group.albumId }, label = { Text(name) },
                            modifier = Modifier.testTag("album-group-${group.albumId}"))
                    }
                }
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp).testTag("album-edit-filter")) {
                    PhotoEditFilter.entries.forEachIndexed { index, filter ->
                        SegmentedButton(selected = editFilter == filter, onClick = {
                            editFilter = filter
                            gridState.requestScrollToItem(0); staggeredState.requestScrollToItem(0)
                        }, shape = SegmentedButtonDefaults.itemShape(index, PhotoEditFilter.entries.size),
                            modifier = Modifier.testTag("album-edit-filter-${filter.name.lowercase()}")) {
                            Text(stringResource(when (filter) {
                                PhotoEditFilter.ALL -> R.string.album_edit_filter_all
                                PhotoEditFilter.EDITED -> R.string.album_edit_filter_edited
                                PhotoEditFilter.UNEDITED -> R.string.album_edit_filter_unedited
                            }))
                        }
                    }
                }
                if (editStatusFailed) Text(stringResource(R.string.album_edit_status_unavailable),
                    Modifier.padding(horizontal = 16.dp), style = MaterialTheme.typography.bodySmall)
                if (loading) LinearProgressIndicator(Modifier.fillMaxWidth())
                if (failed || (!loading && shownPhotos.isEmpty())) {
                    Column(Modifier.padding(24.dp)) {
                        Text(stringResource(if (failed) R.string.album_error else R.string.album_empty))
                        if (onFile != null) TextButton(onClick = onFile) { Text(stringResource(R.string.open_file)) }
                    }
                }
                // 查询期间不让空网格重测，将保存的位置保留到照片列表恢复。
                val spacing = if (columns >= 5) 4.dp else 8.dp
                if (shownPhotos.isNotEmpty()) {
                    val visiblePhotos = shownPhotos.filter { (bucket == null || it.albumId == bucket) && editFilter.includes(editedFlags[it.uri.toString()]) }
                    if (visiblePhotos.isEmpty() && !loading) Text(stringResource(R.string.album_no_edit_matches), Modifier.padding(24.dp))
                    if (squareThumbnails) {
                        LazyVerticalGrid(state = gridState, columns = GridCells.Fixed(columns), contentPadding = PaddingValues(spacing),
                            horizontalArrangement = Arrangement.spacedBy(spacing), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            items(visiblePhotos, key = { it.uri.toString() }) { photo ->
                                AlbumPhotoItem(storage, photo, true, refresh, onPhoto, selectedPhotos?.contains(photo.uri.toString()),
                                    previews, editedFlags[photo.uri.toString()], editRevision, foregroundBusy)
                            }
                        }
                    } else {
                        LazyVerticalStaggeredGrid(state = staggeredState,
                            columns = StaggeredGridCells.Fixed(columns), contentPadding = PaddingValues(spacing),
                            horizontalArrangement = Arrangement.spacedBy(spacing), verticalItemSpacing = 12.dp) {
                            items(visiblePhotos, key = { it.uri.toString() }) { photo ->
                                AlbumPhotoItem(storage, photo, false, refresh, onPhoto, selectedPhotos?.contains(photo.uri.toString()),
                                    previews, editedFlags[photo.uri.toString()], editRevision, foregroundBusy)
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun AlbumPhotoItem(storage: PhotoStorage, photo: AlbumPhoto, square: Boolean, refresh: Int, onPhoto: (Uri) -> Unit,
    checked: Boolean? = null, previews: EditedPhotoPreviews, edited: Boolean?, editRevision: Int, foregroundBusy: Boolean) {
    val editDescription = if (edited == true) stringResource(R.string.album_edit_filter_edited)
        else if (edited == false) stringResource(R.string.album_edit_filter_unedited) else ""
    Column(Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable { onPhoto(photo.uri) }
        .semantics { stateDescription = editDescription }.testTag("album-photo-${photo.uri}")) {
        Box {
            AlbumThumbnail(storage, photo, square, refresh, previews, edited, editRevision, foregroundBusy)
            if (checked != null) Checkbox(checked, onCheckedChange = { onPhoto(photo.uri) }, modifier = Modifier.align(Alignment.TopEnd))
        }
        Text(photo.name, minLines = 2, maxLines = 2, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.labelMedium,
            modifier = Modifier.padding(top = 4.dp))
    }
}

private data class AlbumPreviewImage(val bitmap: android.graphics.Bitmap? = null, val adjusted: Boolean = false,
    val notice: Int? = null, val sourceVersion: String = "")

@Composable
internal fun AlbumThumbnail(storage: PhotoStorage, photo: AlbumPhoto, square: Boolean, refresh: Int,
    previews: EditedPhotoPreviews? = null, edited: Boolean? = null, editRevision: Int = 0, foregroundBusy: Boolean = false) {
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val widthPixels = with(LocalDensity.current) { maxWidth.toPx() }
        val sourceRatio = photo.aspectRatio
        val size = (widthPixels * max(1f, 1f / (sourceRatio ?: 1f))).roundToInt().coerceIn(128, 1024)
        val thumbnail by produceState(AlbumPreviewImage(), photo.uri, photo.sourceVersion, refresh, editRevision, edited, size, foregroundBusy) {
            if (value.sourceVersion != photo.sourceVersion) value = AlbumPreviewImage(sourceVersion = photo.sourceVersion)
            value = value.copy(notice = if (edited == true) {
                if (value.adjusted) R.string.album_preview_updating else R.string.album_original_preview
            } else null)
            if (value.bitmap == null || edited != true && value.adjusted) {
                val original = withContext(Dispatchers.IO) { storage.thumbnail(photo.uri, size, photo.orientation) }
                value = value.copy(bitmap = original, adjusted = false)
            }
            if (edited == true && previews != null && !foregroundBusy) {
                try { value = AlbumPreviewImage(previews.image(photo), true, sourceVersion = photo.sourceVersion) }
                catch (error: Exception) {
                    if (error is kotlinx.coroutines.CancellationException) throw error
                    value = value.copy(notice = R.string.album_preview_unavailable)
                }
            }
        }
        val bitmap = thumbnail.bitmap
        val ratio = if (square) 1f else if (thumbnail.adjusted && bitmap != null) bitmap.width.toFloat() / bitmap.height
            else sourceRatio ?: bitmap?.let { it.width.toFloat() / it.height } ?: 1f
        Box(Modifier.fillMaxWidth().aspectRatio(ratio), contentAlignment = Alignment.Center) {
            if (bitmap != null) Image(bitmap.asImageBitmap(), photo.name, Modifier.fillMaxSize(),
                contentScale = if (square) ContentScale.Crop else ContentScale.Fit)
            else Icon(Icons.Outlined.Image, photo.name, Modifier.size(40.dp))
            if (edited == true) Surface(color = androidx.compose.ui.graphics.Color.Black.copy(alpha = .72f),
                shape = androidx.compose.foundation.shape.RoundedCornerShape(4.dp), modifier = Modifier.align(Alignment.BottomEnd).padding(5.dp)
                    .testTag("album-edited-${photo.uri}")) {
                Icon(Icons.Outlined.Edit, null, tint = androidx.compose.ui.graphics.Color.White, modifier = Modifier.padding(4.dp).size(13.dp))
            }
            thumbnail.notice?.let { notice ->
                Surface(color = androidx.compose.ui.graphics.Color.Black.copy(alpha = .72f),
                    shape = androidx.compose.foundation.shape.RoundedCornerShape(3.dp), modifier = Modifier.align(Alignment.TopStart).padding(4.dp)) {
                    Text(stringResource(notice), color = androidx.compose.ui.graphics.Color.White, maxLines = 2,
                        style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(3.dp))
                }
            }
        }
    }
}
