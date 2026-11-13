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
import com.rawlab.android.camera.protocol.CameraMediaSession
import com.rawlab.android.camera.protocol.SonyLegacyImportSession
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.util.UUID
import javax.net.SocketFactory

internal enum class CameraImportFailure {
    PHOTO_LIMIT_EXCEEDED,
}

internal data class CameraImportState(
    val stage: SonyCameraConnection.Stage? = null,
    val candidates: List<CameraCandidate> = emptyList(),
    val photos: List<CameraPhoto> = emptyList(),
    val selected: Set<String> = emptySet(),
    val connected: Boolean = false,
    val cameraId: String? = null,
    val hardwareIdentity: CameraHardwareIdentity? = null,
    val failure: CameraImportFailure? = null,
    val message: Int? = null,
    val jobs: List<CameraImportJob> = emptyList(),
    val job: CameraImportJob? = null,
    val transferring: Boolean = false,
    val preparing: Boolean = false,
    val currentKey: String? = null,
    val currentBytes: Long = 0,
    val destination: CameraImportDestination = CameraImportDestination(),
    val model: SonyCameraModel = SonyCameraModel.UNKNOWN,
    val mode: CameraMode = CameraMode.IMPORT,
    val importMode: CameraImportMode = CameraImportMode.MANUAL,
    val incrementalFormat: CameraImportFormat = CameraImportFormat.RAW_AND_JPEG,
    val incrementalJpeg: CameraJPEGOptions = CameraJPEGOptions(),
    val incrementalOptionsValid: Boolean = true,
    val incrementalCutoffMillis: Long? = null,
    val incrementalIncludeUndated: Boolean = false,
    val incrementalScan: CameraIncrementalScan? = null,
    val incrementalOwner: String = "",
    val verifiedImports: Map<String, CameraVerifiedImport> = emptyMap(),
    val legacyCameraTime: Boolean = false,
    val closing: Boolean = false,
    val cardSavingConfirmed: Boolean = false,
    // 读不出的导入记录（隔离日志的 id）：界面可查看详情或确认放弃。
    val unreadableLogs: List<String> = emptyList(),
) {
    val resumableIncrementalJob: CameraImportJob?
        get() {
            if (!connected || importMode != CameraImportMode.INCREMENTAL) return null
            return jobs.firstOrNull { job ->
                job.matchesCamera(cameraId, hardwareIdentity) && job.incremental != null && !job.committed &&
                    job.items.any { it.saved == null && !it.skipped } &&
                    job.items.none { it.problem?.needsOriginalJpeg == true } &&
                    (incrementalCutoffMillis == null || incrementalCutoffMillis == job.incremental.customCutoffMillis) &&
                    resumeLocatorMap(job, photos, incrementalOwner).let { matches ->
                        job.items.all { it.saved != null || it.skipped || it.photo.key in matches }
                    }
            }
        }

    fun withConnectedListing(
        cameraId: String,
        opened: CameraMediaSession,
        info: SonyMobileSession.Device,
        listing: CameraPhotoListing,
        owner: String,
        mode: CameraImportMode = importMode,
        format: CameraImportFormat = incrementalFormat,
        jpeg: CameraJPEGOptions = incrementalJpeg,
    ): CameraImportState {
        val photos = sortedCameraPhotos(listing.assets)
        val hardwareIdentity = CameraHardwareIdentity.read(info)
        val next = copy(
            stage = null,
            connected = true,
            cameraId = cameraId,
            photos = photos,
            hardwareIdentity = hardwareIdentity,
            model = SonyCameraModel.fromIdentity(info.model, info.firmware),
            importMode = mode,
            incrementalFormat = format,
            incrementalJpeg = jpeg,
            incrementalOptionsValid = true,
            legacyCameraTime = opened is SonyLegacyImportSession,
            incrementalCutoffMillis = null,
            incrementalIncludeUndated = false,
            incrementalScan = null,
            incrementalOwner = owner,
            verifiedImports = emptyMap(),
            selected = emptySet(),
            failure = CameraImportFailure.PHOTO_LIMIT_EXCEEDED.takeIf { listing.limitExceeded },
            message = R.string.camera_incremental_oversized.takeIf { listing.limitExceeded },
        )
        return if (mode == CameraImportMode.INCREMENTAL) next.copy(incrementalScan = computeCameraIncrementalScan(next, cameraId)) else next
    }
}

internal enum class CameraMode { IMPORT, TETHER }
internal enum class CameraImportMode { MANUAL, INCREMENTAL }
internal data class CameraVerifiedImport(val photo: CameraPhoto, val digest: String, val jobId: String)

internal fun SonyMobileSession.Asset.photo() = CameraPhoto(key(), name, size, created,
    resumeIdentity = resumeIdentity(), storageToken = storageToken, captureTimestamp = captureTimestamp)

internal class CameraImportViewModel(application: Application) : AndroidViewModel(application), SonyCameraConnection.Listener {
    private val mutable = MutableStateFlow(CameraImportState(preparing = true))
    val state = mutable.asStateFlow()
    private val store = CameraImportStore(File(application.filesDir, "camera-media-imports"),
        File(application.cacheDir, "camera-media-partials"), MediaPhotoLibrary(application), CameraCaptureDateReader::read)
    private val connection = SonyCameraConnection(application, this)
    private val sessionLock = Mutex()
    private val storeLock = Mutex()
    private val tetherJournal = CameraTetherJournal(File(application.filesDir, "camera-tether-runs"))
    val tether = CameraTetherController(viewModelScope, store, tetherJournal, storeLock, ::updateJob)
    @Volatile private var session: CameraMediaSession? = null
    private var device: SonyMobileSession.Device? = null
    private var assets: Map<String, SonyMobileSession.Asset> = emptyMap()
    private var cameraId = ""
    @Volatile private var generation = 0
    private var permit: CameraTransferPermit? = null
    private var transfer: Job? = null
    private var importPreparation: Job? = null
    private var connectionWork: Job? = null
    private var closingWork: Job? = null
    private var resumeTether = false
    private var foreground = false
    private var opening: String? = null
    private val previews = object : android.util.LruCache<String, Bitmap>(12 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap) = value.allocationByteCount
    }
    private val preferences = application.getSharedPreferences("camera-import", 0)
    private val clientId = preferences.getString("client-id", null)?.let(UUID::fromString)
        ?: UUID.randomUUID().also { preferences.edit().putString("client-id", it.toString()).apply() }

    private fun preferenceKey(name: String, forCamera: String? = cameraId.takeIf { it.isNotBlank() }): String =
        forCamera?.let { "camera:$it:$name" } ?: name

    private data class IncrementalSettings(val mode: CameraImportMode, val format: CameraImportFormat,
        val jpeg: CameraJPEGOptions)

    private fun readIncrementalSettings(camera: String): IncrementalSettings {
        val mode = runCatching { CameraImportMode.valueOf(preferences.getString(preferenceKey("import-mode", camera), CameraImportMode.MANUAL.name)!!) }
            .getOrDefault(CameraImportMode.MANUAL)
        val format = runCatching { CameraImportFormat.valueOf(preferences.getString(preferenceKey("incremental-format", camera), CameraImportFormat.RAW_AND_JPEG.name)!!) }
            .getOrDefault(CameraImportFormat.RAW_AND_JPEG)
        val jpeg = CameraJPEGOptions(preferences.getBoolean(preferenceKey("incremental-jpeg-adjust", camera), false),
            preferences.getString(preferenceKey("incremental-jpeg-edge", camera), null)?.toIntOrNull(),
            preferences.getInt(preferenceKey("incremental-jpeg-quality", camera), 90)).takeIf { it.isValid }
            ?: CameraJPEGOptions()
        return IncrementalSettings(mode, format, jpeg)
    }

    init {
        val destination = runCatching { CameraImportDestination(
            preferences.getString("destination-directory", "RawLab/Camera")!!,
            CameraDirectoryGrouping.valueOf(preferences.getString("destination-grouping", CameraDirectoryGrouping.CAPTURE_DAY.name)!!))
        }.getOrDefault(CameraImportDestination())
        mutable.update { it.copy(destination = destination) }
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { storeLock.withLock { runCatching { store.load() to tetherJournal.load() } } }
            result.onSuccess { (jobs, runs) ->
                tether.restore(runs, jobs)
                val pending = jobs.firstOrNull { it.status != CameraJobStatus.COMPLETE }
                mutable.update { it.copy(preparing = false, jobs = jobs, job = pending ?: jobs.firstOrNull(), cameraId = pending?.cameraId,
                    selected = pending?.items?.map { item -> item.photo.key }?.toSet().orEmpty(),
                    unreadableLogs = store.unreadableJobIds.sorted()) }
            }
                .onFailure { mutable.update { it.copy(preparing = false, message = R.string.camera_storage_failed) } }
        }
        viewModelScope.launch {
            tether.state.collect { value ->
                if (value.phase == CameraTetherPhase.PAUSED && mutable.value.mode == CameraMode.TETHER && mutable.value.connected) disconnect()
            }
        }
    }

    fun scan() {
        if (mutable.value.transferring || mutable.value.preparing || mutable.value.closing) return
        mutable.update { it.copy(failure = null, message = null, candidates = emptyList()) }
        connectAfterStop { connection.scan() }
    }
    fun connect(id: String) {
        if (mutable.value.transferring || mutable.value.preparing || mutable.value.closing) return
        val model = mutable.value.candidates.find { it.id == id }?.name?.let(SonyCameraModel::fromAdvertisement) ?: return
        mutable.update { it.copy(model = model) }
        connectAfterStop { connection.connect(id) }
    }
    fun prepareLegacyWifi() {
        if (mutable.value.transferring || mutable.value.preparing || mutable.value.closing) return
        mutable.update { it.copy(model = SonyCameraModel.UNKNOWN, failure = null, message = null) }
        connectAfterStop { connection.prepareLegacyWifi() }
    }
    fun useLegacyWifi() {
        if (mutable.value.transferring || mutable.value.preparing || mutable.value.closing) return
        mutable.update { it.copy(model = SonyCameraModel.UNKNOWN, failure = null, message = null) }
        connectAfterStop { connection.useLegacyWifi() }
    }
    private fun connectAfterStop(connect: () -> Unit) {
        disconnect()
        val current = generation
        val closing = closingWork
        viewModelScope.launch {
            closing?.join()
            if (current == generation && foreground) connect()
        }
    }
    fun setMode(mode: CameraMode) {
        if (mutable.value.preparing || mutable.value.closing || mutable.value.mode == mode) return
        disconnect()
        resumeTether = false
        mutable.update { it.copy(mode = mode, failure = null, message = null) }
    }
    fun setImportMode(mode: CameraImportMode) {
        if (mutable.value.preparing || mutable.value.closing || mutable.value.transferring || mutable.value.importMode == mode) return
        preferences.edit().putString(preferenceKey("import-mode"), mode.name).apply()
        mutable.update {
            it.copy(
                importMode = mode,
                message = if (it.failure == CameraImportFailure.PHOTO_LIMIT_EXCEEDED) it.message else null,
            )
        }
        if (mode == CameraImportMode.INCREMENTAL && mutable.value.connected) recomputeIncrementalScan()
    }
    fun setIncrementalFormat(format: CameraImportFormat) {
        if (mutable.value.transferring || mutable.value.preparing) return
        preferences.edit().putString(preferenceKey("incremental-format"), format.name).apply()
        mutable.update { it.copy(incrementalFormat = format,
            incrementalOptionsValid = if (format == CameraImportFormat.RAW) true else it.incrementalOptionsValid) }
        if (mutable.value.importMode == CameraImportMode.INCREMENTAL && mutable.value.connected) recomputeIncrementalScan()
    }
    fun setIncrementalJpeg(options: CameraJPEGOptions) {
        if (!options.isValid || mutable.value.transferring || mutable.value.preparing) return
        preferences.edit().putBoolean(preferenceKey("incremental-jpeg-adjust"), options.adjust)
            .putString(preferenceKey("incremental-jpeg-edge"), options.longEdge?.toString())
            .putInt(preferenceKey("incremental-jpeg-quality"), options.quality).apply()
        mutable.update { it.copy(incrementalJpeg = options, incrementalOptionsValid = true) }
        recomputeIncrementalScan()
    }
    fun setIncrementalOptionsValid(valid: Boolean) { if (!mutable.value.transferring && !mutable.value.preparing)
        mutable.update { it.copy(incrementalOptionsValid = valid) } }
    fun setIncrementalCutoff(cutoffMillis: Long?) {
        if (mutable.value.transferring || mutable.value.preparing) return
        mutable.update { it.copy(incrementalCutoffMillis = cutoffMillis) }
        if (mutable.value.importMode == CameraImportMode.INCREMENTAL && mutable.value.connected) recomputeIncrementalScan()
    }
    fun setIncrementalIncludeUndated(include: Boolean) {
        if (mutable.value.transferring || mutable.value.preparing) return
        mutable.update { it.copy(incrementalIncludeUndated = include) }
        if (mutable.value.importMode == CameraImportMode.INCREMENTAL && mutable.value.connected) recomputeIncrementalScan()
    }
    private fun recomputeIncrementalScan() {
        val snapshot = mutable.value
        if (snapshot.importMode != CameraImportMode.INCREMENTAL || !snapshot.connected || snapshot.cameraId == null) return
        val scan = computeCameraIncrementalScan(snapshot, snapshot.cameraId)
        mutable.update { it.copy(incrementalScan = scan) }
    }
    fun refreshIncrementalScan() {
        val snapshot = mutable.value
        if (snapshot.stage != null || snapshot.transferring || snapshot.preparing) return
        val opened = session
        val info = device
        if (snapshot.importMode != CameraImportMode.INCREMENTAL || !snapshot.connected || opened == null || info == null) {
            recomputeIncrementalScan()
            return
        }
        val current = generation
        mutable.update { it.copy(stage = SonyCameraConnection.Stage.NETWORK, failure = null, message = null) }
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) { sessionLock.withLock { runCatching { listCameraPhotosBounded(opened, info) } } }
            if (current != generation || !foreground) return@launch
            result.onSuccess { listing ->
                assets = listing.assets.associateBy { it.key() }
                val photos = sortedCameraPhotos(listing.assets)
                mutable.update {
                    it.copy(
                        stage = null,
                        photos = photos,
                        failure = CameraImportFailure.PHOTO_LIMIT_EXCEEDED.takeIf { listing.limitExceeded },
                        message = R.string.camera_incremental_oversized.takeIf { listing.limitExceeded },
                    )
                }
                recomputeIncrementalScan()
            }.onFailure { onFailure(SonyCameraConnection.Failure.DISCONNECTED) }
        }
    }
    fun setTetherResume(resume: Boolean) { if (!tether.state.value.active) resumeTether = resume }
    fun confirmCardSaving(confirmed: Boolean) { if (!tether.state.value.active) mutable.update { it.copy(cardSavingConfirmed = confirmed) } }
    fun permissionDenied() { mutable.update { it.copy(message = R.string.camera_permissions) } }
    fun dismissMessage() { mutable.update { it.copy(failure = null, message = null) } }
    /** 放弃全部读不出的导入记录：删除隔离日志，其待发布媒体由随后的孤儿清理回收。 */
    fun discardUnreadableLogs() {
        // 与 setDestination/selectJob 同门禁：store.load() 会改写活动任务并清理 .part，只能在停下的队列上跑。
        if (mutable.value.transferring || mutable.value.preparing || mutable.value.closing || tether.state.value.active) return
        viewModelScope.launch {
            val refreshed = withContext(Dispatchers.IO) { storeLock.withLock {
                store.unreadableJobIds.sorted().forEach { store.discardUnreadableJob(it) }
                runCatching { store.load() }.getOrNull()
            } }
            mutable.update { state -> refreshed?.let { jobs ->
                val pending = jobs.firstOrNull { it.status != CameraJobStatus.COMPLETE }
                val current = state.job?.takeIf { job -> jobs.any { it.id == job.id } } ?: pending ?: jobs.firstOrNull()
                state.copy(jobs = jobs, job = current, unreadableLogs = store.unreadableJobIds.sorted())
            } ?: state.copy(unreadableLogs = store.unreadableJobIds.sorted(), message = R.string.camera_storage_failed) }
            refreshed?.let { tether.refreshJobs(it) }
        }
    }
    fun setDestination(destination: CameraImportDestination) {
        if (mutable.value.transferring || mutable.value.preparing || tether.state.value.active) return
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
    override fun onStage(stage: SonyCameraConnection.Stage) { mutable.update { it.copy(stage = stage, failure = null, message = null) } }
    override fun onConnected(network: Network, address: InetAddress, cameraId: String) {
        if (mutable.value.closing || !foreground) return
        if (mutable.value.mode == CameraMode.TETHER) {
            this.cameraId = cameraId
            mutable.update { it.copy(stage = null, connected = true, cameraId = cameraId) }
            tether.start(network, address, clientId, mutable.value.model, cameraId, mutable.value.destination, resumeTether, mutable.value.cardSavingConfirmed)
            return
        }
        connectImport(network.socketFactory, address, cameraId)
    }

    fun connectImport(factory: SocketFactory, address: InetAddress, cameraId: String) {
        if (mutable.value.closing || !foreground) return
        val current = generation
        mutable.update { it.copy(stage = SonyCameraConnection.Stage.NETWORK) }
        connectionWork = viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    openCameraImportSession(
                        createMobile = { SonyMobileSession(factory, address, clientId) { } },
                        createLegacy = { SonyLegacyImportSession(factory, address, clientId) { } },
                    ) { opened ->
                        withContext(Dispatchers.Main.immediate) {
                            if (current != generation || !foreground) throw IOException("Stale camera connection")
                            session = opened
                        }
                    }
                }
            }
            if (current != generation || !foreground) { result.getOrNull()?.session?.close(); return@launch }
            result.onSuccess { connected ->
                device = connected.device
                this@CameraImportViewModel.cameraId = cameraId
                assets = connected.listing.assets.associateBy { it.key() }
                val owner = UUID.randomUUID().toString()
                val settings = readIncrementalSettings(cameraId)
                mutable.update {
                    it.withConnectedListing(
                        cameraId = cameraId,
                        opened = connected.session,
                        info = connected.device,
                        listing = connected.listing,
                        owner = owner,
                        mode = settings.mode,
                        format = settings.format,
                        jpeg = settings.jpeg,
                    )
                }
            }.onFailure { onFailure(if (it is CameraMediaSession.UnsupportedCameraException)
                SonyCameraConnection.Failure.UNSUPPORTED else SonyCameraConnection.Failure.DISCONNECTED) }
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
        tether.stop()
        session?.close(); session = null
        device = null; assets = emptyMap()
        previews.evictAll()
        val prior = closingWork
        val oldTransfer = transfer
        val oldPreparation = importPreparation
        val oldConnection = connectionWork
        mutable.update { it.copy(stage = null, connected = false, closing = true, hardwareIdentity = null, failure = null) }
        closingWork = viewModelScope.launch {
            prior?.join()
            oldTransfer?.join()
            oldPreparation?.join()
            oldConnection?.join()
            tether.join()
            connection.close()
            mutable.update { it.copy(closing = false) }
        }
    }
    fun onForeground() { foreground = true }
    fun onBackground() {
        foreground = false
        if (mutable.value.transferring || importPreparation?.isActive == true || connectionWork?.isActive == true || tether.state.value.active ||
            mutable.value.stage != null && mutable.value.stage != SonyCameraConnection.Stage.MANUAL_WIFI) stop()
    }
    fun stop() { disconnect(); mutable.update { it.copy(message = R.string.camera_paused) } }

    fun startImport() {
        val snapshot = mutable.value
        if (snapshot.mode != CameraMode.IMPORT || snapshot.closing || !foreground || !snapshot.connected || snapshot.transferring ||
            snapshot.preparing || snapshot.stage != null) return
        snapshot.resumableIncrementalJob?.let { runQueue(it, resuming = true); return }
        val scan = snapshot.incrementalScan.takeIf { snapshot.importMode == CameraImportMode.INCREMENTAL }
        if (snapshot.importMode == CameraImportMode.INCREMENTAL &&
            (scan == null || scan.needsCutoffConfirmation || !snapshot.incrementalOptionsValid)) return
        val photos = scan?.assets ?: snapshot.photos.filter { it.key in snapshot.selected }
        if (photos.isEmpty()) return
        val incremental = scan?.let {
            CameraIncrementalPlan(snapshot.incrementalFormat, snapshot.incrementalJpeg,
                customCutoffMillis = snapshot.incrementalCutoffMillis,
                includeUndated = snapshot.incrementalIncludeUndated,
                sessionOwner = snapshot.incrementalOwner,
                checkpoints = it.nextCheckpoints)
        }
        val selectedCamera = cameraId
        val hardwareIdentity = device?.let(CameraHardwareIdentity::read)
        val current = generation
        mutable.update { it.copy(preparing = true, message = null) }
        importPreparation = viewModelScope.launch {
            try {
                val result = withContext(Dispatchers.IO) { storeLock.withLock { runCatching {
                    store.create(selectedCamera, photos, snapshot.destination, incremental = incremental,
                        hardwareIdentity = hardwareIdentity, listingOwner = snapshot.incrementalOwner)
                } } }
                result.onSuccess { job ->
                    if (!foreground || current != generation) {
                        // 后台事件使这次准入失效；即使已经返回前台，也只保留可继续的任务。
                        val paused = job.copy(status = CameraJobStatus.PAUSED)
                        val saved = withContext(Dispatchers.IO) { storeLock.withLock { runCatching { store.save(paused) } } }
                        updateJob(paused)
                        mutable.update { it.copy(message = if (saved.isFailure) R.string.camera_storage_failed else it.message ?: R.string.camera_paused) }
                    } else { updateJob(job); runQueue(job) }
                }.onFailure { mutable.update { it.copy(message = R.string.camera_storage_failed) } }
            } finally {
                importPreparation = null
                mutable.update { it.copy(preparing = false) }
            }
        }
    }
    fun resume(keepJpegOriginals: Boolean = false) {
        val snapshot = mutable.value
        if (!snapshot.preparing) snapshot.job?.let { runQueue(it, resuming = true, keepJpegOriginals = keepJpegOriginals) }
    }

    fun skipFailed() {
        val snapshot = mutable.value
        val job = snapshot.job ?: return
        if (snapshot.preparing || snapshot.transferring || snapshot.closing || job.items.none { it.canSkip }) return
        mutable.update { it.copy(preparing = true, message = null) }
        viewModelScope.launch {
            try {
                val result = withContext(Dispatchers.IO) {
                    storeLock.withLock { runCatching { skipFailedCameraItems(store, job) } }
                }
                result.onSuccess { updated ->
                    updateJob(updated)
                    if (updated.committed && updated.incremental != null &&
                        mutable.value.connected && mutable.value.incrementalOwner == snapshot.incrementalOwner) {
                        recomputeIncrementalScan()
                    }
                }.onFailure { mutable.update { it.copy(message = R.string.camera_storage_failed) } }
            } finally {
                mutable.update { it.copy(preparing = false) }
            }
        }
    }

    private fun runQueue(job: CameraImportJob, resuming: Boolean = false, keepJpegOriginals: Boolean = false) {
        val snapshot = mutable.value
        if (snapshot.mode != CameraMode.IMPORT || snapshot.closing || !foreground || snapshot.transferring ||
            snapshot.stage != null || job.status == CameraJobStatus.COMPLETE) return
        val opened = session
        val info = device
        if (opened == null || info == null) {
            updateJob(job.copy(status = CameraJobStatus.PAUSED))
            mutable.update { it.copy(message = R.string.camera_disconnected) }
            return
        }
        if (!job.matchesCamera(cameraId, CameraHardwareIdentity.read(info))) {
            mutable.update { it.copy(message = R.string.camera_source_changed) }; return
        }
        val listed = assets
        val allowed = CameraTransferPermit(); permit = allowed
        mutable.update { it.copy(transferring = true, job = job, message = null, currentBytes = 0) }
        transfer = viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                storeLock.withLock {
                    sessionLock.withLock {
                        executeCameraSessionQueue(
                            store = store,
                            opened = opened,
                            info = info,
                            initialJob = job,
                            listedAssets = listed,
                            incrementalOwner = snapshot.incrementalOwner,
                            allowed = allowed,
                            resuming = resuming,
                            keepJpegOriginals = keepJpegOriginals,
                            onListed = { current, limitExceeded ->
                                withContext(Dispatchers.Main.immediate) {
                                    allowed.check()
                                    assets = current
                                    previews.evictAll()
                                    mutable.update {
                                        it.copy(
                                            photos = sortedCameraPhotos(current.values),
                                            selected = it.selected.intersect(current.keys),
                                            failure = CameraImportFailure.PHOTO_LIMIT_EXCEEDED.takeIf { limitExceeded } ?: it.failure,
                                            message = R.string.camera_incremental_oversized.takeIf { limitExceeded } ?: it.message,
                                        )
                                    }
                                }
                            },
                            onProgress = { key, bytes -> mutable.update { it.copy(currentKey = key, currentBytes = bytes) } },
                            onJob = ::updateJob,
                        )
                    }
                }
            }
            if (result.verifiedImports.isNotEmpty()) {
                mutable.update { state ->
                    if (state.connected && state.incrementalOwner == snapshot.incrementalOwner)
                        state.copy(verifiedImports = state.verifiedImports + result.verifiedImports)
                    else state
                }
            }
            val latest = result.job
            updateJob(latest)
            if (result.failure == null && latest.incremental != null &&
                mutable.value.connected && mutable.value.incrementalOwner == snapshot.incrementalOwner) {
                if (latest.status == CameraJobStatus.COMPLETE) {
                    mutable.update { it.copy(incrementalCutoffMillis = null, incrementalIncludeUndated = false) }
                }
                recomputeIncrementalScan()
            }
            permit = null
            mutable.update {
                it.copy(
                    transferring = false,
                    currentKey = null,
                    currentBytes = 0,
                    message = if (result.sourceChanged) R.string.camera_source_changed
                    else if (result.failure != null) it.message ?: R.string.camera_transfer_failed
                    else it.message,
                )
            }
            if (result.shouldDisconnect) disconnect()
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
            val bytes = try { session?.preview(asset, large) ?: return@withLock null }
            catch (_: SonyMobileSession.ResponseException) { return@withLock null }
            catch (_: IOException) {
                // 缩略图离屏会取消调用方，但致命错误后的连接状态仍必须同步到主线程。
                withContext(NonCancellable + Dispatchers.Main.immediate) {
                    if (current == generation) onFailure(SonyCameraConnection.Failure.DISCONNECTED)
                }
                return@withLock null
            }
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
    fun openTetherSaved(photo: CameraTetherSaved, onReady: (List<Uri>) -> Unit) {
        if (mutable.value.preparing) return
        disconnect()
        val current = generation
        val closing = closingWork
        mutable.update { it.copy(preparing = true) }
        viewModelScope.launch {
            closing?.join()
            val result = withContext(Dispatchers.IO) { storeLock.withLock { runCatching {
                val jobs = store.load(); tether.refreshJobs(jobs)
                val job = jobs.find { it.id == photo.jobId } ?: throw IOException("Saved camera job missing")
                if (photo.uri !in store.savedUris(job)) throw IOException("Saved camera photo missing")
                listOf(Uri.parse(photo.uri))
            } } }
            mutable.update { it.copy(preparing = false) }
            if (current == generation && foreground) result.onSuccess(onReady)
                .onFailure { mutable.update { it.copy(message = R.string.camera_source_missing) } }
        }
    }
    override fun onCleared() {
        generation++; permit?.cancel(); tether.stop(); session?.close()
        // 给已按下的快门释放留出与协议层一致的有界窗口。
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({ connection.close() }, 2_100)
        super.onCleared()
    }
}

internal fun computeCameraIncrementalScan(snapshot: CameraImportState, cameraId: String): CameraIncrementalScan {
    val jobs = snapshot.jobs.filter { it.matchesCamera(cameraId, snapshot.hardwareIdentity) && it.incremental != null }
    val checkpoints = committedIncrementalCheckpoints(jobs)
    val jpeg = snapshot.incrementalJpeg.takeIf { it.adjust }
    val verifiedJobs = snapshot.verifiedImports.values.map { it.jobId }.toSet()
    val savedKeys = if (snapshot.incrementalCutoffMillis != null) emptySet() else jobs.asSequence()
        .filter { it.originalListingOwner == snapshot.incrementalOwner || it.id in verifiedJobs }
        .flatMap { job ->
            val plannedJpeg = job.incremental?.jpeg?.takeIf { it.adjust }
            val saved = job.items.asSequence().filter {
                it.saved != null && (it.photo.raw || jpeg == plannedJpeg || jpeg == job.jpegOptions(it))
            }
            val matches = resumeLocatorMap(job, snapshot.photos, snapshot.incrementalOwner)
            saved.mapNotNull { item ->
                val photo = matches[item.photo.key] ?: return@mapNotNull null
                if (job.originalListingOwner == snapshot.incrementalOwner) photo.key
                else photo.key.takeIf {
                    snapshot.verifiedImports[it]?.let { evidence ->
                        evidence.digest == item.digest && evidence.photo.matchesSnapshot(photo)
                    } == true
                }
            }
        }.toSet()
    val zone = java.time.ZoneId.systemDefault()
    val wallClockZone = if (snapshot.legacyCameraTime) java.time.ZoneOffset.UTC else zone
    return CameraIncrementalScan(snapshot.photos, checkpoints,
        CameraIncrementalScan.defaultCutoffMillis(zone = zone, wallClockZone = wallClockZone), snapshot.incrementalCutoffMillis,
        snapshot.incrementalFormat, snapshot.incrementalIncludeUndated, savedKeys, snapshot.incrementalOwner)
}

/** 相机预览按容器方向解码；不下载或显影原件来生成浏览图。 */
internal fun decodeCameraPreview(bytes: ByteArray, large: Boolean, pixelBudget: Long = 100_000_000): Bitmap? {
    if (Build.VERSION.SDK_INT < 28) return null
    return runCatching {
        ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(bytes))) { decoder, info, _ ->
            val width = info.size.width
            val height = info.size.height
            if (width <= 0 || height <= 0 || width.toLong() * height > pixelBudget) throw java.io.IOException("Camera preview exceeds pixel budget")
            val scale = minOf(1f, (if (large) 1600f else 400f) / maxOf(width, height))
            decoder.setTargetSize((width * scale).roundToInt().coerceAtLeast(1), (height * scale).roundToInt().coerceAtLeast(1))
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            decoder.setTargetColorSpace(ColorSpace.get(ColorSpace.Named.SRGB))
            decoder.setOnPartialImageListener { false }
        }
    }.getOrNull()
}
