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
import com.rawlab.android.camera.protocol.SonyTetherSession
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
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
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.UUID
import javax.net.SocketFactory

internal enum class CameraImportFailure {
    PHOTO_LIMIT_EXCEEDED,
}

internal data class CameraAccessAuthPrompt(
    val cameraId: String,
    val fingerprint: String,
    val keyType: String,
    val initialUser: String = "",
    val hasSavedCredentials: Boolean = false,
    val fingerprintChanged: Boolean = false,
    val submitting: Boolean = false,
    val errorMessage: Int? = null,
)

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
    val accessAuth: CameraAccessAuthPrompt? = null,
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

    fun withQueueListing(current: Map<String, SonyMobileSession.Asset>, limitExceeded: Boolean): CameraImportState {
        val next = copy(
            photos = sortedCameraPhotos(current.values),
            selected = selected.intersect(current.keys),
            failure = CameraImportFailure.PHOTO_LIMIT_EXCEEDED.takeIf { limitExceeded } ?: failure,
            message = R.string.camera_incremental_oversized.takeIf { limitExceeded } ?: message,
        )
        return if (next.connected && next.importMode == CameraImportMode.INCREMENTAL && next.cameraId != null)
            next.copy(incrementalScan = computeCameraIncrementalScan(next, next.cameraId)) else next
    }

    fun withQueueResult(result: CameraSessionQueueResult, owner: String): CameraImportState {
        val sameConnection = connected && incrementalOwner == owner
        val latest = result.job
        var next = copy(
            job = latest,
            jobs = (jobs.filterNot { it.id == latest.id } + latest).sortedByDescending { it.createdAt },
            verifiedImports = if (sameConnection) verifiedImports + result.verifiedImports else verifiedImports,
        )
        if (!result.shouldDisconnect && sameConnection) {
            if (result.failure == null && latest.incremental != null && latest.status == CameraJobStatus.COMPLETE) {
                next = next.copy(incrementalCutoffMillis = null, incrementalIncludeUndated = false)
            }
            if (next.importMode == CameraImportMode.INCREMENTAL && next.cameraId != null) {
                next = next.copy(incrementalScan = computeCameraIncrementalScan(next, next.cameraId))
            }
        }
        return next
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
    private val importsDirectory = File(application.filesDir, "camera-media-imports")
    private val tetherRunsDirectory = File(application.filesDir, "camera-tether-runs")
    private val store = CameraImportStore(importsDirectory,
        File(application.cacheDir, "camera-media-partials"), MediaPhotoLibrary(application), CameraCaptureDateReader::read,
        processJpeg = { source, destination, options -> CameraJPEGProcessing.process(application, source, destination, options) },
        verifyJpeg = CameraJPEGProcessing::ensureAdjustmentSupported)
    private val authStore = CameraAccessAuthStore(application)
    private val connection = SonyCameraConnection(application, this)
    private val sessionLock = Mutex()
    private val storeLock = Mutex()
    private val tetherJournal = CameraTetherJournal(tetherRunsDirectory)
    val tether = CameraTetherController(viewModelScope, store, tetherJournal, storeLock, ::updateJob)
    @Volatile private var session: CameraMediaSession? = null
    @Volatile private var sshTunnel: SonySshTunnel? = null
    private var device: SonyMobileSession.Device? = null
    @Volatile private var assets: Map<String, SonyMobileSession.Asset> = emptyMap()
    private var cameraId = ""
    @Volatile private var generation = 0
    private var permit: CameraTransferPermit? = null
    private var transfer: Job? = null
    private var importPreparation: Job? = null
    private var connectionWork: Job? = null
    private var heartbeat: Job? = null
    private var closingWork: Job? = null
    private var pendingConnected: PendingConnection? = null
    private var pendingAuthTarget: PendingConnection? = null
    private var resumeTether = false
    private var foreground = false
    private var opening: String? = null

    private data class PendingConnection(
        val network: Network,
        val address: InetAddress,
        val cameraId: String,
    )
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
    fun setIncrementalJpeg(options: CameraJPEGOptions, optionsValid: Boolean = options.isValid) {
        if (!options.isValid || mutable.value.transferring || mutable.value.preparing) return
        preferences.edit().putBoolean(preferenceKey("incremental-jpeg-adjust"), options.adjust)
            .putString(preferenceKey("incremental-jpeg-edge"), options.longEdge?.toString())
            .putInt(preferenceKey("incremental-jpeg-quality"), options.quality).apply()
        mutable.update { it.copy(incrementalJpeg = options, incrementalOptionsValid = optionsValid) }
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
    fun toggleSelectAll(visibleKeys: Collection<String>) {
        if (mutable.value.transferring) return
        mutable.update { it.copy(selected = toggleVisibleSelection(it.selected, visibleKeys)) }
    }
    fun selectJob(job: CameraImportJob) { if (!mutable.value.transferring && !mutable.value.preparing) mutable.update { it.copy(job = job) } }

    private fun debugCameraLog(message: String) {
        if (com.rawlab.android.BuildConfig.DEBUG) {
            runCatching { android.util.Log.d("RawLabCamera", message) }
        }
    }

    override fun onCandidates(items: List<CameraCandidate>) { mutable.update { it.copy(candidates = items) } }
    override fun onStage(stage: SonyCameraConnection.Stage) { mutable.update { it.copy(stage = stage, failure = null, message = null) } }
    override fun onConnected(network: Network, address: InetAddress, cameraId: String) {
        debugCameraLog("onConnected mode=${mutable.value.mode} closing=${mutable.value.closing} foreground=$foreground")
        if (mutable.value.closing) return
        if (!foreground) {
            pendingConnected = PendingConnection(network, address, cameraId)
            return
        }
        pendingConnected = null
        startConnectedSession(network, address, cameraId)
    }

    private fun startConnectedSession(network: Network, address: InetAddress, cameraId: String) {
        if (mutable.value.closing || !foreground) return
        val current = generation
        val targetMode = mutable.value.mode
        mutable.update { it.copy(stage = SonyCameraConnection.Stage.NETWORK, accessAuth = null, message = null) }
        connectionWork = viewModelScope.launch {
            var pendingDirectTether: SonyTetherSession? = null
            val resolution = withContext(Dispatchers.IO) {
                resolveCameraAccessAuth(
                    cameraId = cameraId,
                    loadSaved = authStore::load,
                    probeSsh = { probeSshHostKey(address, rawSocketFactory = network.socketFactory) },
                    connectSsh = { user, pass, fingerprint ->
                        SonySshTunnel.connect(
                            address = address,
                            username = user,
                            password = pass,
                            expectedFingerprint = fingerprint,
                            rawSocketFactory = network.socketFactory,
                        )
                    },
                    tryDirect = {
                        if (targetMode == CameraMode.IMPORT) {
                            openCameraImportSession(
                                createMobile = { SonyMobileSession(network.socketFactory, address, clientId) { debugCameraLog("mobile: $it") } },
                                createLegacy = { SonyLegacyImportSession(network.socketFactory, address, clientId) { debugCameraLog("legacy: $it") } },
                                initializeRemote = false,
                            ) { opened ->
                                withContext(Dispatchers.Main.immediate) {
                                    if (current != generation || !foreground) throw IOException("Stale camera connection")
                                    session = opened
                                }
                            }
                        } else {
                            val remote = SonyTetherSession(network.socketFactory, address, clientId) { debugCameraLog("remote: $it") }
                            try {
                                remote.inspectDevice()
                            } catch (error: Throwable) {
                                remote.close()
                                throw error
                            }
                            pendingDirectTether = remote
                            null
                        }
                    },
                    onDiagnostic = { debugCameraLog(SonySshTunnel.redactIps(it)) },
                )
            }

            if (current != generation || !foreground || mutable.value.closing) {
                (resolution as? CameraAuthResolution.Direct)?.importSession?.session?.close()
                (resolution as? CameraAuthResolution.SshConnected)?.tunnel?.close()
                pendingDirectTether?.close()
                return@launch
            }

            when (resolution) {
                is CameraAuthResolution.Direct -> {
                    if (targetMode == CameraMode.IMPORT) {
                        val connected = resolution.importSession
                            ?: return@launch onFailure(SonyCameraConnection.Failure.DISCONNECTED)
                        finishImportConnect(connected, cameraId)
                    } else {
                        val initialRemote = pendingDirectTether
                        pendingDirectTether = null
                        this@CameraImportViewModel.cameraId = cameraId
                        mutable.update { it.copy(stage = null, connected = true, cameraId = cameraId, accessAuth = null) }
                        tether.start(
                            socketFactory = network.socketFactory,
                            address = address,
                            clientId = clientId,
                            model = mutable.value.model,
                            cameraId = cameraId,
                            destination = mutable.value.destination,
                            resume = resumeTether,
                            cardSavingConfirmed = mutable.value.cardSavingConfirmed,
                            openLiveConnection = { url -> network.openConnection(url) as java.net.HttpURLConnection },
                            initialRemote = initialRemote,
                        )
                    }
                }
                is CameraAuthResolution.SshConnected -> {
                    val tunnel = resolution.tunnel
                    sshTunnel?.close()
                    sshTunnel = tunnel
                    if (targetMode == CameraMode.IMPORT) {
                        openImportAndPublish(
                            current = current,
                            factory = tunnel.socketFactory(),
                            address = address,
                            cameraId = cameraId,
                            initializeRemote = true,
                        )
                    } else {
                        this@CameraImportViewModel.cameraId = cameraId
                        mutable.update { it.copy(stage = null, connected = true, cameraId = cameraId, accessAuth = null) }
                        tether.start(
                            socketFactory = tunnel.socketFactory(),
                            address = address,
                            clientId = clientId,
                            model = mutable.value.model,
                            cameraId = cameraId,
                            destination = mutable.value.destination,
                            resume = resumeTether,
                            cardSavingConfirmed = mutable.value.cardSavingConfirmed,
                            openLiveStream = { url -> tunnel.openLiveViewStream(url) },
                        )
                    }
                }
                is CameraAuthResolution.PromptAuth -> {
                    pendingAuthTarget = PendingConnection(network, address, cameraId)
                    mutable.update { it.copy(stage = null, accessAuth = resolution.prompt, message = null) }
                }
                is CameraAuthResolution.Failed -> {
                    pendingDirectTether?.close()
                    onFailure(resolution.failure)
                }
            }
        }
    }

    fun submitAccessAuth(user: String, password: String) {
        val snapshot = mutable.value
        val prompt = snapshot.accessAuth ?: return
        val target = pendingAuthTarget ?: return
        if (snapshot.closing || !foreground || prompt.submitting) return
        val trimmedUser = user.trim()
        if (trimmedUser.isEmpty() || password.isEmpty()) {
            mutable.update {
                it.copy(accessAuth = prompt.copy(submitting = false, errorMessage = R.string.camera_auth_failed))
            }
            return
        }
        val current = generation
        val targetMode = snapshot.mode
        mutable.update {
            it.copy(stage = null, message = null, accessAuth = prompt.copy(submitting = true, errorMessage = null))
        }
        connectionWork = viewModelScope.launch {
            val connectResult = withContext(Dispatchers.IO) {
                runCatching {
                    SonySshTunnel.connect(
                        address = target.address,
                        username = trimmedUser,
                        password = password,
                        expectedFingerprint = prompt.fingerprint,
                        rawSocketFactory = target.network.socketFactory,
                    )
                }
            }
            if (current != generation || !foreground || mutable.value.closing) {
                connectResult.getOrNull()?.close()
                return@launch
            }
            connectResult.onSuccess { tunnel ->
                withContext(Dispatchers.IO) {
                    authStore.save(
                        target.cameraId,
                        CameraAccessAuthRecord(
                            user = trimmedUser,
                            password = password,
                            fingerprint = tunnel.hostProbe.fingerprint,
                        ),
                    )
                }
                if (current != generation || !foreground || mutable.value.closing) {
                    tunnel.close()
                    return@launch
                }
                sshTunnel?.close()
                sshTunnel = tunnel
                pendingAuthTarget = null
                mutable.update { it.copy(accessAuth = null) }
                if (targetMode == CameraMode.IMPORT) {
                    mutable.update { it.copy(stage = SonyCameraConnection.Stage.NETWORK) }
                    openImportAndPublish(
                        current = current,
                        factory = tunnel.socketFactory(),
                        address = target.address,
                        cameraId = target.cameraId,
                        initializeRemote = true,
                    )
                } else {
                    this@CameraImportViewModel.cameraId = target.cameraId
                    mutable.update { it.copy(stage = null, connected = true, cameraId = target.cameraId, accessAuth = null) }
                    tether.start(
                        socketFactory = tunnel.socketFactory(),
                        address = target.address,
                        clientId = clientId,
                        model = mutable.value.model,
                        cameraId = target.cameraId,
                        destination = mutable.value.destination,
                        resume = resumeTether,
                        cardSavingConfirmed = mutable.value.cardSavingConfirmed,
                        openLiveStream = { url -> tunnel.openLiveViewStream(url) },
                    )
                }
            }.onFailure { error ->
                when (error) {
                    is SshFingerprintMismatchException -> {
                        mutable.update { state ->
                            val activePrompt = state.accessAuth ?: prompt
                            state.copy(
                                accessAuth = activePrompt.copy(
                                    fingerprint = error.actualFingerprint.ifBlank { activePrompt.fingerprint },
                                    keyType = error.keyType.takeIf { it != "unknown" } ?: activePrompt.keyType,
                                    fingerprintChanged = true,
                                    submitting = false,
                                    errorMessage = R.string.camera_auth_fingerprint_changed,
                                ),
                            )
                        }
                    }
                    is SshAuthenticationException -> {
                        mutable.update { state ->
                            val activePrompt = state.accessAuth ?: prompt
                            state.copy(
                                accessAuth = activePrompt.copy(
                                    initialUser = trimmedUser,
                                    submitting = false,
                                    errorMessage = R.string.camera_auth_failed,
                                ),
                            )
                        }
                    }
                    else -> {
                        debugCameraLog("submitAccessAuth failed: ${error.javaClass.simpleName}: ${SonySshTunnel.redactIps(error.message)}")
                        onFailure(SonyCameraConnection.Failure.DISCONNECTED)
                    }
                }
            }
        }
    }

    fun forgetAccessAuth() {
        val activePrompt = mutable.value.accessAuth ?: return
        if (activePrompt.submitting) return
        val targetId = pendingAuthTarget?.cameraId ?: activePrompt.cameraId
        mutable.update { state ->
            state.copy(
                accessAuth = state.accessAuth?.copy(
                    initialUser = "",
                    hasSavedCredentials = false,
                    errorMessage = null,
                ),
            )
        }
        viewModelScope.launch(Dispatchers.IO) {
            authStore.delete(targetId)
        }
    }

    fun cancelAccessAuth() {
        if (mutable.value.accessAuth?.submitting == true) return
        disconnect()
        mutable.update { it.copy(accessAuth = null, message = null) }
    }

    fun connectImport(
        factory: SocketFactory,
        address: InetAddress,
        cameraId: String,
        initializeRemote: Boolean = false,
    ) {
        if (mutable.value.closing || !foreground) return
        debugCameraLog("connectImport start")
        val current = generation
        mutable.update { it.copy(stage = SonyCameraConnection.Stage.NETWORK) }
        connectionWork = viewModelScope.launch {
            openImportAndPublish(current, factory, address, cameraId, initializeRemote)
        }
    }

    private suspend fun openImportAndPublish(
        current: Int,
        factory: SocketFactory,
        address: InetAddress,
        cameraId: String,
        initializeRemote: Boolean,
    ) {
        val result = withContext(Dispatchers.IO) {
            runCatching {
                openCameraImportSession(
                    createMobile = { SonyMobileSession(factory, address, clientId) { debugCameraLog("mobile: $it") } },
                    createLegacy = { SonyLegacyImportSession(factory, address, clientId) { debugCameraLog("legacy: $it") } },
                    initializeRemote = initializeRemote,
                ) { opened ->
                    withContext(Dispatchers.Main.immediate) {
                        if (current != generation || !foreground) throw IOException("Stale camera connection")
                        session = opened
                    }
                }
            }
        }
        if (current != generation || !foreground || mutable.value.closing) {
            result.getOrNull()?.session?.close()
            return
        }
        result.onSuccess { connected ->
            finishImportConnect(connected, cameraId)
        }.onFailure { error ->
            val redactedMessage = error.message?.replace(Regex("""\b\d{1,3}(?:\.\d{1,3}){3}\b"""), "<ip>")
            debugCameraLog("connectImport failed ${error.javaClass.simpleName} at ${error.stackTrace.firstOrNull()} msg=$redactedMessage")
            onFailure(
                if (error is CameraMediaSession.UnsupportedCameraException) {
                    SonyCameraConnection.Failure.UNSUPPORTED
                } else {
                    SonyCameraConnection.Failure.DISCONNECTED
                },
            )
        }
    }

    private fun finishImportConnect(connected: ConnectedCameraImport, cameraId: String) {
        debugCameraLog("connectImport success assets=${connected.listing.assets.size} model=${connected.device.model} fw=${connected.device.firmware}")
        device = connected.device
        this@CameraImportViewModel.cameraId = cameraId
        assets = connected.listing.assets.associateBy { it.key() }
        val owner = UUID.randomUUID().toString()
        val settings = readIncrementalSettings(cameraId)
        mutable.update {
            it.copy(accessAuth = null).withConnectedListing(
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
        startImportHeartbeat(generation)
    }

    /**
     * 空闲导入会话没有任何 PTP 流量时，相机会在一段时间后自行断开（用户停下来挑片、锁屏片刻就得重连 BLE + Wi-Fi）。
     * 定期发一次只读 GetDeviceInfo 维持会话；传输或预览占用会话时跳过，失败时立即把断开同步到界面。
     */
    private fun startImportHeartbeat(current: Int) {
        heartbeat?.cancel()
        heartbeat = viewModelScope.launch {
            while (true) {
                delay(CAMERA_IMPORT_HEARTBEAT_MS)
                if (current != generation || !mutable.value.connected || mutable.value.mode != CameraMode.IMPORT) return@launch
                val alive = withContext(Dispatchers.IO) {
                    if (!sessionLock.tryLock()) return@withContext true
                    try { current != generation || pingCameraSession(session) } finally { sessionLock.unlock() }
                }
                if (!alive && current == generation) {
                    debugCameraLog("import heartbeat failed")
                    onFailure(SonyCameraConnection.Failure.DISCONNECTED)
                    return@launch
                }
            }
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
        heartbeat?.cancel(); heartbeat = null
        pendingConnected = null
        pendingAuthTarget = null
        permit?.cancel()
        tether.stop()
        session?.close(); session = null
        device = null; assets = emptyMap()
        previews.evictAll()
        val oldTunnel = sshTunnel
        sshTunnel = null
        val prior = closingWork
        val oldTransfer = transfer
        val oldPreparation = importPreparation
        val oldConnection = connectionWork
        mutable.update { it.copy(stage = null, connected = false, closing = true, hardwareIdentity = null, failure = null, accessAuth = null) }
        closingWork = viewModelScope.launch {
            prior?.join()
            oldTransfer?.join()
            oldPreparation?.join()
            oldConnection?.join()
            tether.join()
            withContext(Dispatchers.IO) { runCatching { oldTunnel?.close() } }
            connection.close()
            mutable.update { it.copy(closing = false) }
        }
    }
    fun onForeground() {
        foreground = true
        debugCameraLog("onForeground stage=${mutable.value.stage} hasPending=${pendingConnected != null}")
        val deferred = pendingConnected
        val snapshot = mutable.value
        if (deferred != null && !snapshot.closing && !snapshot.connected && snapshot.accessAuth == null) {
            pendingConnected = null
            startConnectedSession(deferred.network, deferred.address, deferred.cameraId)
        }
    }
    fun onBackground() {
        debugCameraLog("onBackground stage=${mutable.value.stage} connected=${mutable.value.connected}")
        foreground = false
        if (shouldStopCameraOnBackground(
                state = mutable.value,
                hasActiveImportPreparation = importPreparation?.isActive == true,
                hasActiveConnectionWork = connectionWork?.isActive == true,
                tetherActive = tether.state.value.active,
            )
        ) {
            stop()
        }
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
        if (snapshot.importMode == CameraImportMode.MANUAL && snapshot.incrementalJpeg.adjust &&
            !snapshot.incrementalOptionsValid && photos.any { !it.raw }) return
        val incremental = scan?.let {
            CameraIncrementalPlan(snapshot.incrementalFormat, snapshot.incrementalJpeg,
                customCutoffMillis = snapshot.incrementalCutoffMillis,
                includeUndated = snapshot.incrementalIncludeUndated,
                sessionOwner = snapshot.incrementalOwner,
                checkpoints = it.nextCheckpoints)
        }
        val manualJpeg = if (incremental == null) snapshot.incrementalJpeg.takeIf { it.adjust } else null
        val selectedCamera = cameraId
        val hardwareIdentity = device?.let(CameraHardwareIdentity::read)
        val current = generation
        mutable.update { it.copy(preparing = true, message = null) }
        importPreparation = viewModelScope.launch {
            try {
                val result = withContext(Dispatchers.IO) { storeLock.withLock { runCatching {
                    store.create(selectedCamera, photos, snapshot.destination, incremental = incremental,
                        hardwareIdentity = hardwareIdentity, listingOwner = snapshot.incrementalOwner, jpeg = manualJpeg)
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
                                    mutable.update { it.withQueueListing(current, limitExceeded) }
                                }
                            },
                            onProgress = { key, bytes -> mutable.update { it.copy(currentKey = key, currentBytes = bytes) } },
                            onJob = ::updateJob,
                        )
                    }
                }
            }
            mutable.update { it.withQueueResult(result, snapshot.incrementalOwner) }
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
        val asset = assets[photo.key] ?: return null
        val current = generation
        return withContext(Dispatchers.IO) { sessionLock.withLock {
            if (current != generation || mutable.value.transferring) return@withLock null
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
            executeOpenSaved(
                jobId = job.id,
                request = request,
                currentOpening = { opening },
                currentJobId = { mutable.value.job?.id },
                clearOpening = { opening = null },
                resetPreparing = { mutable.update { it.copy(preparing = false) } },
                loadUris = {
                    withContext(Dispatchers.IO) { storeLock.withLock {
                        runCatching { store.savedUris(job).map(Uri::parse) }.onFailure {
                            refreshed = runCatching { store.load().firstOrNull { it.id == job.id } }.getOrNull()
                        }
                    } } to refreshed
                },
                onRefreshed = ::updateJob,
                onReady = onReady,
                onError = { error ->
                    mutable.update { it.copy(message = if (error is CameraLocalSourceChanged)
                        R.string.camera_local_source_changed else R.string.camera_source_missing) }
                },
            )
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
            executeOpenTetherSaved(
                resetPreparing = { mutable.update { it.copy(preparing = false) } },
                loadUris = {
                    closing?.join()
                    withContext(Dispatchers.IO) { storeLock.withLock { runCatching {
                        val jobs = store.load(); tether.refreshJobs(jobs)
                        val job = jobs.find { it.id == photo.jobId } ?: throw IOException("Saved camera job missing")
                        if (photo.uri !in store.savedUris(job)) throw IOException("Saved camera photo missing")
                        listOf(Uri.parse(photo.uri))
                    } } }
                },
                canDeliver = { current == generation && foreground },
                onReady = onReady,
                onError = { mutable.update { it.copy(message = R.string.camera_source_missing) } },
            )
        }
    }
    // Q6 相机原件手动清理：与传输/恢复共用 storeLock；清理后重新加载 jobs 刷新 state，
    // 否则相机页继续显示已删除的任务（内存与磁盘失同步）。
    suspend fun inspectOriginals(): CameraOriginalsSummary? = withContext(Dispatchers.IO) {
        storeLock.withLock { runCatching { CameraOriginalsRetention.inspect(importsDirectory) }.getOrNull() }
    }

    suspend fun pendingOriginalsCleanup(): CameraOriginalsSummary? = withContext(Dispatchers.IO) {
        storeLock.withLock {
            runCatching { CameraOriginalsRetention.pendingExported(importsDirectory, tetherRunsDirectory) }.getOrNull()
        }
    }

    suspend fun pruneOriginals(): CameraOriginalsSummary? = withContext(Dispatchers.IO) {
        storeLock.withLock {
            runCatching {
                val freed = CameraOriginalsRetention.pruneExported(importsDirectory, tetherRunsDirectory)
                val jobs = store.load()
                tether.refreshJobs(jobs)
                mutable.update { current ->
                    val pending = jobs.firstOrNull { it.status != CameraJobStatus.COMPLETE }
                    val job = jobs.firstOrNull { it.id == current.job?.id } ?: pending ?: jobs.firstOrNull()
                    current.copy(jobs = jobs, job = job, unreadableLogs = store.unreadableJobIds.sorted())
                }
                freed
            }.getOrNull()
        }
    }
    override fun onCleared() {
        generation++; pendingConnected = null; pendingAuthTarget = null
        permit?.cancel(); tether.stop(); session?.close()
        val lingeringTunnel = sshTunnel
        sshTunnel = null
        // 给已按下的快门释放留出与协议层一致的有界窗口。
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            runCatching { lingeringTunnel?.close() }
            connection.close()
        }, 2_100)
        super.onCleared()
    }
}

internal const val CAMERA_IMPORT_HEARTBEAT_MS = 10_000L

/** 相机能完整应答（含错误响应码）即视为会话仍在；只有已关闭或传输层异常才算断开。 */
internal fun pingCameraSession(opened: CameraMediaSession?): Boolean {
    if (opened == null) return true
    if (!opened.isOpen) return false
    return try {
        opened.deviceInfo()
        true
    } catch (error: CameraMediaSession.PhotoTransferException) {
        !error.isSessionFailure
    } catch (_: java.io.IOException) {
        false
    }
}

internal fun shouldStopCameraOnBackground(
    state: CameraImportState,
    hasActiveImportPreparation: Boolean,
    hasActiveConnectionWork: Boolean,
    tetherActive: Boolean,
): Boolean {
    if (state.transferring || hasActiveImportPreparation || hasActiveConnectionWork || tetherActive) {
        return true
    }
    state.accessAuth?.let { prompt ->
        return prompt.submitting
    }
    return when (state.stage) {
        null,
        SonyCameraConnection.Stage.MANUAL_WIFI,
        SonyCameraConnection.Stage.PAIRING,
        SonyCameraConnection.Stage.WIFI_CONFIRMATION -> false
        SonyCameraConnection.Stage.SCANNING,
        SonyCameraConnection.Stage.BLUETOOTH,
        SonyCameraConnection.Stage.WIFI_STARTING,
        SonyCameraConnection.Stage.NETWORK -> true
    }
}

internal sealed interface CameraAuthResolution {
    data class Direct(val importSession: ConnectedCameraImport? = null) : CameraAuthResolution
    data class SshConnected(val tunnel: SonySshTunnel) : CameraAuthResolution
    data class PromptAuth(val prompt: CameraAccessAuthPrompt) : CameraAuthResolution
    data class Failed(val failure: SonyCameraConnection.Failure) : CameraAuthResolution
}

internal suspend fun resolveCameraAccessAuth(
    cameraId: String,
    loadSaved: (String) -> CameraAccessAuthRecord?,
    probeSsh: () -> SshHostProbe,
    connectSsh: (user: String, password: String, expectedFingerprint: String) -> SonySshTunnel,
    tryDirect: suspend () -> ConnectedCameraImport?,
    onDiagnostic: (String) -> Unit = {},
): CameraAuthResolution {
    val saved = cameraId.takeIf { it.isNotBlank() }?.let(loadSaved)
    if (saved != null) {
        val probe = try {
            probeSsh()
        } catch (error: Throwable) {
            onDiagnostic("probeSsh failed: ${error.javaClass.simpleName}: ${error.message}")
            null
        }
        if (probe != null) {
            val savedFingerprint = normalizeSha256Fingerprint(saved.fingerprint)
            if (savedFingerprint == null || !MessageDigest.isEqual(
                    savedFingerprint.toByteArray(StandardCharsets.UTF_8),
                    probe.fingerprint.toByteArray(StandardCharsets.UTF_8),
                )
            ) {
                return CameraAuthResolution.PromptAuth(
                    CameraAccessAuthPrompt(
                        cameraId = cameraId,
                        fingerprint = probe.fingerprint,
                        keyType = probe.keyType,
                        initialUser = saved.user,
                        hasSavedCredentials = true,
                        fingerprintChanged = true,
                        errorMessage = R.string.camera_auth_fingerprint_changed,
                    ),
                )
            }
            return try {
                CameraAuthResolution.SshConnected(
                    connectSsh(saved.user, saved.password, probe.fingerprint),
                )
            } catch (_: SshFingerprintMismatchException) {
                CameraAuthResolution.PromptAuth(
                    CameraAccessAuthPrompt(
                        cameraId = cameraId,
                        fingerprint = probe.fingerprint,
                        keyType = probe.keyType,
                        initialUser = saved.user,
                        hasSavedCredentials = true,
                        fingerprintChanged = true,
                        errorMessage = R.string.camera_auth_fingerprint_changed,
                    ),
                )
            } catch (_: SshAuthenticationException) {
                CameraAuthResolution.PromptAuth(
                    CameraAccessAuthPrompt(
                        cameraId = cameraId,
                        fingerprint = probe.fingerprint,
                        keyType = probe.keyType,
                        initialUser = saved.user,
                        hasSavedCredentials = true,
                        errorMessage = R.string.camera_auth_failed,
                    ),
                )
            } catch (error: Throwable) {
                onDiagnostic("connectSsh failed: ${error.javaClass.simpleName}: ${error.message}")
                CameraAuthResolution.Failed(SonyCameraConnection.Failure.DISCONNECTED)
            }
        }
    }

    return try {
        CameraAuthResolution.Direct(tryDirect())
    } catch (_: CameraMediaSession.UnsupportedCameraException) {
        CameraAuthResolution.Failed(SonyCameraConnection.Failure.UNSUPPORTED)
    } catch (error: IOException) {
        onDiagnostic("tryDirect failed: ${error.javaClass.simpleName}")
        val probe = try {
            probeSsh()
        } catch (probeError: Throwable) {
            onDiagnostic("probeSsh failed: ${probeError.javaClass.simpleName}: ${probeError.message}")
            null
        }
        if (probe != null) {
            CameraAuthResolution.PromptAuth(
                CameraAccessAuthPrompt(
                    cameraId = cameraId,
                    fingerprint = probe.fingerprint,
                    keyType = probe.keyType,
                    initialUser = saved?.user.orEmpty(),
                    hasSavedCredentials = saved != null,
                ),
            )
        } else {
            CameraAuthResolution.Failed(SonyCameraConnection.Failure.DISCONNECTED)
        }
    } catch (error: Throwable) {
        onDiagnostic("tryDirect failed: ${error.javaClass.simpleName}: ${error.message}")
        CameraAuthResolution.Failed(SonyCameraConnection.Failure.DISCONNECTED)
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
            val plannedJpeg = job.effectiveJpeg
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

internal suspend fun executeOpenSaved(
    jobId: String,
    request: String,
    currentOpening: () -> String?,
    currentJobId: () -> String?,
    clearOpening: () -> Unit,
    resetPreparing: () -> Unit,
    loadUris: suspend () -> Pair<Result<List<Uri>>, CameraImportJob?>,
    onRefreshed: (CameraImportJob) -> Unit,
    onReady: (List<Uri>) -> Unit,
    onError: (Throwable) -> Unit,
) {
    try {
        val (result, refreshed) = loadUris()
        if (currentOpening() != request || currentJobId() != jobId) return
        clearOpening()
        refreshed?.let(onRefreshed)
        resetPreparing()
        result.onSuccess { if (it.isNotEmpty()) onReady(it) }
            .onFailure(onError)
    } finally {
        if (currentOpening() == request) {
            clearOpening()
            resetPreparing()
        }
    }
}

internal suspend fun executeOpenTetherSaved(
    resetPreparing: () -> Unit,
    loadUris: suspend () -> Result<List<Uri>>,
    canDeliver: () -> Boolean,
    onReady: (List<Uri>) -> Unit,
    onError: (Throwable) -> Unit,
) {
    try {
        val result = loadUris()
        resetPreparing()
        if (canDeliver()) result.onSuccess(onReady).onFailure(onError)
    } finally {
        resetPreparing()
    }
}

internal sealed interface CameraPreviewLoadState {
    data object Loading : CameraPreviewLoadState
    data class Loaded(val bitmap: Bitmap) : CameraPreviewLoadState
    data object Unavailable : CameraPreviewLoadState
}

internal fun previewLoadState(bitmap: Bitmap?): CameraPreviewLoadState =
    if (bitmap != null) CameraPreviewLoadState.Loaded(bitmap) else CameraPreviewLoadState.Unavailable

internal fun cameraGridColumns(maxWidthDp: Float): Int = when {
    maxWidthDp >= 900f -> 5
    maxWidthDp >= 600f -> 4
    else -> 3
}

internal fun allVisibleSelected(selected: Set<String>, visibleKeys: Collection<String>): Boolean =
    visibleKeys.isNotEmpty() && visibleKeys.all { it in selected }

internal fun toggleVisibleSelection(selected: Set<String>, visibleKeys: Collection<String>): Set<String> {
    if (visibleKeys.isEmpty()) return selected
    return if (allVisibleSelected(selected, visibleKeys)) selected - visibleKeys.toSet() else selected + visibleKeys
}
