package com.rawlab.android.camera

import android.app.Application
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.graphics.ColorSpace
import android.os.Build
import java.nio.ByteBuffer
import kotlin.math.roundToInt
import android.net.Network
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.rawlab.android.R
import com.rawlab.android.photo.MediaPhotoLibrary
import com.rawlab.android.camera.protocol.SonyMobileSession
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.net.InetAddress
import java.util.UUID

internal data class CameraImportState(
    val stage: SonyCameraConnection.Stage? = null,
    val candidates: List<CameraCandidate> = emptyList(),
    val photos: List<CameraPhoto> = emptyList(),
    val selected: Set<String> = emptySet(),
    val connected: Boolean = false,
    val cameraId: String? = null,
    val message: Int? = null,
    val jobs: List<CameraImportJob> = emptyList(),
    val job: CameraImportJob? = null,
    val transferring: Boolean = false,
    val preparing: Boolean = false,
    val currentKey: String? = null,
    val currentBytes: Long = 0,
    val destination: CameraImportDestination = CameraImportDestination(),
)

internal class CameraImportViewModel(application: Application) : AndroidViewModel(application), SonyCameraConnection.Listener {
    private val mutable = MutableStateFlow(CameraImportState(preparing = true))
    val state = mutable.asStateFlow()
    private val store = CameraImportStore(File(application.filesDir, "camera-media-imports"),
        File(application.cacheDir, "camera-media-partials"), MediaPhotoLibrary(application), CameraCaptureDateReader::read)
    private val connection = SonyCameraConnection(application, this)
    private val sessionLock = Mutex()
    private val storeLock = Mutex()
    @Volatile private var session: SonyMobileSession? = null
    private var device: SonyMobileSession.Device? = null
    private var assets: Map<String, SonyMobileSession.Asset> = emptyMap()
    private var cameraId = ""
    @Volatile private var generation = 0
    private var permit: CameraTransferPermit? = null
    private var transfer: Job? = null
    private var opening: String? = null
    private val previews = object : android.util.LruCache<String, Bitmap>(12 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap) = value.allocationByteCount
    }
    private val preferences = application.getSharedPreferences("camera-import", 0)
    private val clientId = preferences.getString("client-id", null)?.let(UUID::fromString)
        ?: UUID.randomUUID().also { preferences.edit().putString("client-id", it.toString()).apply() }

    init {
        val destination = runCatching { CameraImportDestination(
            preferences.getString("destination-directory", "RawLab/Camera")!!,
            CameraDirectoryGrouping.valueOf(preferences.getString("destination-grouping", CameraDirectoryGrouping.CAPTURE_DAY.name)!!))
        }.getOrDefault(CameraImportDestination())
        mutable.update { it.copy(destination = destination) }
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { storeLock.withLock { runCatching { store.load() } } }
            result.onSuccess { jobs ->
                val pending = jobs.firstOrNull { it.status != CameraJobStatus.COMPLETE }
                mutable.update { it.copy(preparing = false, jobs = jobs, job = pending ?: jobs.firstOrNull(), cameraId = pending?.cameraId,
                    selected = pending?.items?.map { item -> item.photo.key }?.toSet().orEmpty()) }
            }
                .onFailure { mutable.update { it.copy(preparing = false, message = R.string.camera_storage_failed) } }
        }
    }

    fun scan() {
        if (mutable.value.transferring || mutable.value.preparing) return
        disconnect()
        mutable.update { it.copy(message = null, candidates = emptyList()) }
        connection.scan()
    }
    fun connect(id: String) { if (!mutable.value.transferring) connection.connect(id) }
    fun permissionDenied() { mutable.update { it.copy(message = R.string.camera_permissions) } }
    fun dismissMessage() { mutable.update { it.copy(message = null) } }
    fun setDestination(destination: CameraImportDestination) {
        if (mutable.value.transferring || mutable.value.preparing) return
        preferences.edit().putString("destination-directory", destination.directory)
            .putString("destination-grouping", destination.grouping.name).apply()
        mutable.update { it.copy(destination = destination) }
    }
    fun toggle(photo: CameraPhoto) {
        if (mutable.value.transferring) return
        mutable.update { it.copy(selected = if (photo.key in it.selected) it.selected - photo.key else it.selected + photo.key) }
    }
    fun clearSelection() { if (!mutable.value.transferring) mutable.update { it.copy(selected = emptySet()) } }
    fun selectJob(job: CameraImportJob) { if (!mutable.value.transferring && !mutable.value.preparing) mutable.update { it.copy(job = job) } }

    override fun onCandidates(items: List<CameraCandidate>) { mutable.update { it.copy(candidates = items) } }
    override fun onStage(stage: SonyCameraConnection.Stage) { mutable.update { it.copy(stage = stage, message = null) } }
    override fun onConnected(network: Network, address: InetAddress, cameraId: String) {
        val current = generation
        mutable.update { it.copy(stage = SonyCameraConnection.Stage.NETWORK) }
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { runCatching {
                val opened = SonyMobileSession(network.socketFactory, address, clientId) { }
                try {
                    if (current != generation) throw java.io.IOException("Stale camera connection")
                    session = opened
                    val info = opened.deviceInfo()
                    opened.openSession()
                    val found = opened.listPhotos(info)
                    Triple(opened, info, found)
                } catch (error: Exception) { opened.close(); throw error }
            } }
            if (current != generation) { result.getOrNull()?.first?.close(); return@launch }
            result.onSuccess { (_, info, found) ->
                device = info
                this@CameraImportViewModel.cameraId = cameraId
                assets = found.associateBy { it.key() }
                val photos = found.map { CameraPhoto(it.key(), it.name, it.size, it.created) }
                    .sortedWith(compareByDescending<CameraPhoto> { it.created }.thenByDescending { it.name })
                mutable.update { it.copy(stage = null, connected = true, cameraId = cameraId, photos = photos,
                    selected = if (it.cameraId == cameraId) it.selected.intersect(assets.keys) else emptySet(), message = null) }
            }.onFailure { onFailure(SonyCameraConnection.Failure.DISCONNECTED) }
        }
    }
    override fun onFailure(reason: SonyCameraConnection.Failure) {
        val message = when (reason) {
            SonyCameraConnection.Failure.UNSUPPORTED -> R.string.camera_supported
            SonyCameraConnection.Failure.PERMISSION -> R.string.camera_permissions
            SonyCameraConnection.Failure.BLUETOOTH_OFF -> R.string.camera_bluetooth_off
            SonyCameraConnection.Failure.LOCATION_OFF -> R.string.camera_location_off
            SonyCameraConnection.Failure.NOT_FOUND -> R.string.camera_not_found
            SonyCameraConnection.Failure.DISCONNECTED -> R.string.camera_disconnected
            else -> R.string.camera_connection_failed
        }
        disconnect()
        mutable.update { it.copy(message = message) }
    }
    fun disconnect() {
        generation++
        permit?.cancel()
        session?.close(); session = null
        device = null; assets = emptyMap()
        connection.close()
        previews.evictAll()
        mutable.update { it.copy(stage = null, connected = false) }
    }
    fun onBackground() { if (mutable.value.transferring) stop() }
    fun stop() { disconnect(); mutable.update { it.copy(message = R.string.camera_paused) } }

    fun startImport() {
        val snapshot = mutable.value
        if (!snapshot.connected || snapshot.transferring || snapshot.preparing || snapshot.selected.isEmpty()) return
        val selectedCamera = cameraId
        mutable.update { it.copy(preparing = true, message = null) }
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { storeLock.withLock { runCatching {
                store.create(selectedCamera, snapshot.photos.filter { it.key in snapshot.selected }, snapshot.destination)
            } } }
            mutable.update { it.copy(preparing = false) }
            result.onSuccess { job -> updateJob(job); runQueue(job) }
                .onFailure { mutable.update { it.copy(message = R.string.camera_storage_failed) } }
        }
    }
    fun resume() { mutable.value.job?.let(::runQueue) }

    private fun runQueue(job: CameraImportJob) {
        val opened = session
        val info = device
        if (opened == null || info == null) {
            updateJob(job.copy(status = CameraJobStatus.PAUSED))
            mutable.update { it.copy(message = R.string.camera_disconnected) }
            return
        }
        if (mutable.value.transferring || job.status == CameraJobStatus.COMPLETE) return
        val fresh = assets
        if (job.cameraId != cameraId || job.items.any { it.saved == null && it.photo.key !in fresh }) {
            mutable.update { it.copy(message = R.string.camera_source_changed) }; return
        }
        val allowed = CameraTransferPermit(); permit = allowed
        mutable.update { it.copy(transferring = true, job = job, message = null, currentBytes = 0) }
        transfer = viewModelScope.launch {
            var latest = job.copy(status = CameraJobStatus.ACTIVE)
            val result = withContext(Dispatchers.IO) { storeLock.withLock {
                runCatching { sessionLock.withLock {
                    store.save(latest)
                    for ((index, item) in latest.items.withIndex()) {
                        if (item.saved != null) continue
                        allowed.check()
                        val asset = fresh.getValue(item.photo.key)
                        mutable.update { it.copy(currentKey = item.photo.key, currentBytes = 0) }
                        val part = store.partial(job.id)
                        try {
                            val digest = FileOutputStream(part).use { output ->
                                val hash = opened.download(info, asset, output) { bytes, _ ->
                                    allowed.check(); mutable.update { it.copy(currentBytes = bytes) }
                                }
                                output.fd.sync(); hash
                            }
                            allowed.check()
                            latest = store.publish(latest, index, part, digest, allowed)
                            updateJob(latest)
                        } finally { part.delete() }
                    }
                } }.also { outcome ->
                    if (outcome.isFailure) {
                        latest = latest.copy(status = CameraJobStatus.PAUSED)
                        // 发布中失败可能已经写入 prepared；从持久清单恢复，不能用旧快照覆盖它。
                        runCatching { store.load().firstOrNull { it.id == job.id } }.getOrNull()?.let { latest = it }
                    }
                }
            } }
            updateJob(latest)
            permit = null
            mutable.update { it.copy(transferring = false, currentKey = null, currentBytes = 0,
                message = if (result.isFailure) it.message ?: R.string.camera_transfer_failed else null) }
            if (result.isFailure) disconnect()
        }
    }

    suspend fun preview(photo: CameraPhoto, large: Boolean): Bitmap? {
        val cacheKey = "$cameraId:${photo.key}:$large"
        previews.get(cacheKey)?.let { return it }
        if (mutable.value.transferring) return null
        val current = generation
        return withContext(Dispatchers.IO) { sessionLock.withLock {
            if (current != generation || mutable.value.transferring) return@withLock null
            val asset = assets[photo.key] ?: return@withLock null
            val bytes = runCatching { session?.preview(asset, large) }.getOrNull() ?: return@withLock null
            val bitmap = decodeCameraPreview(bytes, large)
            if (current == generation && bitmap != null) { previews.put(cacheKey, bitmap); bitmap } else null
        } }
    }

    fun cancelOpening() {
        if (opening != null) { opening = null; mutable.update { it.copy(preparing = false) } }
    }
    fun openSaved(onReady: (List<Uri>) -> Unit) {
        val job = mutable.value.job ?: return
        if (mutable.value.preparing || mutable.value.transferring) return
        val request = UUID.randomUUID().toString()
        opening = request
        mutable.update { it.copy(preparing = true, message = null) }
        viewModelScope.launch {
            var refreshed: CameraImportJob? = null
            val result = withContext(Dispatchers.IO) { storeLock.withLock {
                runCatching { store.savedUris(job).map(Uri::parse) }.onFailure {
                    refreshed = runCatching { store.load().firstOrNull { it.id == job.id } }.getOrNull()
                }
            } }
            if (opening != request || mutable.value.job?.id != job.id) return@launch
            opening = null
            refreshed?.let(::updateJob)
            mutable.update { it.copy(preparing = false) }
            result.onSuccess { if (it.isNotEmpty()) onReady(it) }
                .onFailure { error ->
                    mutable.update { it.copy(message = if (error is CameraLocalSourceChanged)
                        R.string.camera_local_source_changed else R.string.camera_source_missing) }
                }
        }
    }
    private fun updateJob(job: CameraImportJob) { mutable.update { it.copy(job = job,
        jobs = (it.jobs.filterNot { previous -> previous.id == job.id } + job).sortedByDescending { item -> item.createdAt }) } }
    override fun onCleared() { disconnect(); super.onCleared() }
}

/** 相机预览按容器方向解码；不下载或显影原件来生成浏览图。 */
internal fun decodeCameraPreview(bytes: ByteArray, large: Boolean): Bitmap? {
    if (Build.VERSION.SDK_INT < 28) return null
    return runCatching {
        ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(bytes))) { decoder, info, _ ->
            val width = info.size.width
            val height = info.size.height
            if (width <= 0 || height <= 0 || width.toLong() * height > 100_000_000) throw java.io.IOException("Camera preview exceeds pixel budget")
            val scale = minOf(1f, (if (large) 1600f else 400f) / maxOf(width, height))
            decoder.setTargetSize((width * scale).roundToInt().coerceAtLeast(1), (height * scale).roundToInt().coerceAtLeast(1))
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            decoder.setTargetColorSpace(ColorSpace.get(ColorSpace.Named.SRGB))
            decoder.setOnPartialImageListener { false }
        }
    }.getOrNull()
}
