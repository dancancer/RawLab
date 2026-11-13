package com.rawlab.android.camera

import android.graphics.Bitmap
import android.net.Network
import com.rawlab.android.camera.protocol.CameraMediaSession
import com.rawlab.android.camera.protocol.SonyTetherSession
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.IOException
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.URL
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.SocketFactory

internal enum class CameraTetherPhase { IDLE, PREPARING, READY, CAPTURING, WAITING, RECEIVING, PAUSED }
internal enum class CameraTetherFailure { CONNECTION, LIVE, SETTINGS, SOURCE, STORAGE, BACKLOG, UNKNOWN_SHOT, UNSUPPORTED, PHOTO_LIMIT }
internal enum class CameraParameterFailure { UNAVAILABLE, REJECTED, UNCONFIRMED, CONNECTION }
internal data class CameraTetherSaved(val photo: CameraPhoto, val uri: String, val jobId: String)
internal data class CameraTetherParameterState(
    val values: List<CameraTetherParameter> = emptyList(),
    val writable: Boolean = false,
    val read: Boolean = false,
    val busy: Boolean = false,
    val failure: CameraParameterFailure? = null,
    val reason: String? = null,
    val captureReady: Boolean = false,
)
internal data class CameraTetherState(
    val phase: CameraTetherPhase = CameraTetherPhase.IDLE,
    val run: CameraTetherRun? = null,
    val runs: List<CameraTetherRun> = emptyList(),
    val jobs: List<CameraImportJob> = emptyList(),
    val frame: Bitmap? = null,
    val frameTime: Long = 0,
    val live: Boolean = false,
    val liveAvailable: Boolean = true,
    val resumedRegisteredOnly: Boolean = false,
    val current: CameraPhoto? = null,
    val currentBytes: Long = 0,
    val failure: CameraTetherFailure? = null,
    val parameters: CameraTetherParameterState = CameraTetherParameterState(),
) {
    val receiving: Boolean get() = phase == CameraTetherPhase.RECEIVING
    val active: Boolean get() = phase !in setOf(CameraTetherPhase.IDLE, CameraTetherPhase.PAUSED)
    val canResume: Boolean get() = failure != CameraTetherFailure.SOURCE && run?.recoveryJobs(jobs) != null
    val saved: List<CameraTetherSaved> get() {
        val byId = jobs.associateBy { it.id }
        return run?.batches.orEmpty().flatMap { batch -> byId[batch.id]?.items.orEmpty().mapNotNull { item ->
            item.saved?.let { CameraTetherSaved(item.photo, it.uri, batch.id) }
        } }.distinctBy { it.uri }.reversed()
    }
    val pendingCount: Int get() {
        val byId = jobs.associateBy { it.id }
        return run?.batches?.sumOf { batch -> batch.photos.size - (byId[batch.id]?.savedCount ?: 0) } ?: 0
    }
}

/** Activity 的相机 owner 创建并持有本控制器，存储实例和锁与选片导入完全共用。 */
internal class CameraTetherController(private val scope: CoroutineScope, private val store: CameraImportStore,
    private val journal: CameraTetherJournal, private val storeLock: Mutex,
    private val onJob: (CameraImportJob) -> Unit,
    private val clock: () -> Long = ::monotonicMillis,
    private val loopPause: suspend () -> Unit = { delay(250) }) {
    private val mutable = MutableStateFlow(CameraTetherState())
    val state = mutable.asStateFlow()
    private val queue = CameraTetherQueue(store, journal)
    private var work: Job? = null
    fun refreshJobs(jobs: List<CameraImportJob>) { jobs.forEach(::updateJob) }

    @Volatile private var active: Active? = null

    private class Active(val transport: CameraTetherTransport, val openLiveConnection: (URL) -> HttpURLConnection) {
        val permit = CameraTransferPermit()
        val shutter = Channel<Unit>(1)
        val parameterRequests = Channel<ParameterRequest>(Channel.UNLIMITED)
        val shutterPending = AtomicBoolean(false)
        @Volatile var stopped = false
        @Volatile var liveGeneration = 0
        @Volatile var connection: HttpURLConnection? = null
        @Volatile var liveFailure = false
        var liveJob: Job? = null
        var run: CameraTetherRun? = null
        var ended = false
        var initialObservation = true
        var requestBatchIds: Set<String>? = null
        var requestAcknowledged = false
    }

    private data class ParameterRequest(val code: Int? = null, val requested: Long? = null)

    fun restore(runs: List<CameraTetherRun>, jobs: List<CameraImportJob>) {
        check(active == null)
        val previous = runs.firstOrNull { it.status == CameraTetherStatus.PAUSED }
        mutable.value = CameraTetherState(run = previous, runs = runs, jobs = jobs,
            phase = if (previous == null) CameraTetherPhase.IDLE else CameraTetherPhase.PAUSED,
            failure = CameraTetherFailure.UNKNOWN_SHOT.takeIf { previous?.shutterRequestedAt != null })
    }

    fun start(network: Network, address: InetAddress, clientId: UUID, model: SonyCameraModel, cameraId: String,
        destination: CameraImportDestination, resume: Boolean, cardSavingConfirmed: Boolean) =
        start(network.socketFactory, address, clientId, model, cameraId, destination, resume, cardSavingConfirmed) {
            network.openConnection(it) as HttpURLConnection
        }

    internal fun start(socketFactory: SocketFactory, address: InetAddress, clientId: UUID, model: SonyCameraModel, cameraId: String,
        destination: CameraImportDestination, resume: Boolean, cardSavingConfirmed: Boolean,
        openLiveConnection: (URL) -> HttpURLConnection = { throw IOException("Live view network unavailable") }) {
        check(work?.isActive != true && active == null)
        val paused = mutable.value
        val previous = paused.run.takeIf { resume }
        val current = Active(CameraTetherTransport(socketFactory, address, clientId, model, cardSavingConfirmed), openLiveConnection)
        active = current
        mutable.update { it.copy(phase = CameraTetherPhase.PREPARING, failure = null, live = false, frame = null, frameTime = 0,
            parameters = CameraTetherParameterState(), liveAvailable = true, resumedRegisteredOnly = previous != null) }
        work = scope.launch(Dispatchers.IO) {
            var failure: CameraTetherFailure? = null
            try {
                coroutineScope {
                    if (resume && (!paused.canResume || previous?.cameraId != cameraId))
                        throw CameraTetherSourceException()
                    current.run = previous?.copy(status = CameraTetherStatus.ACTIVE)
                    observe(current, cameraId, model, destination)
                    val liveUrl = current.transport.activateRemote()
                    runCatching { current.transport.readParameters() }
                        .onSuccess { publishParameters(current, it) }
                        .onFailure { publishParameterFailure(current, CameraParameterFailure.UNAVAILABLE, it.message) }
                    openLive(current, liveUrl, this)
                    // 基线之前的临时手机队列不属于这次新拍范围。
                    if (current.transport.usesLegacyContents) current.transport.drainHostImages()
                    var lastCheck = clock()
                    var requestedAt = 0L
                    var busy = 0
                    var lastParameterRead = clock()
                    ready(current)
                    while (isActive && !current.stopped) {
                        loopPause()
                        if (current.liveFailure) throw CameraTetherLiveException()
                        current.parameterRequests.tryReceive().getOrNull()?.let { processParameter(current, it) }
                        if (mutable.value.phase == CameraTetherPhase.READY && clock() - lastParameterRead >= 3_000) {
                            processParameter(current, ParameterRequest())
                            lastParameterRead = clock()
                        }
                        if (current.shutter.tryReceive().isSuccess) {
                            mutable.update { it.copy(phase = CameraTetherPhase.CAPTURING, failure = null) }
                            storeLock.withLock {
                                current.permit.check()
                                current.requestBatchIds = checkNotNull(current.run).batches.map { it.id }.toSet()
                                current.requestAcknowledged = false
                                current.run = checkNotNull(current.run).copy(shutterRequestedAt = System.currentTimeMillis()).also(journal::save)
                                updateRun(checkNotNull(current.run))
                            }
                            requestedAt = clock()
                            try { current.transport.capture() }
                            catch (notSent: SonyTetherSession.CaptureNotSentException) {
                                storeLock.withLock {
                                    current.run = checkNotNull(current.run).copy(shutterRequestedAt = null).also(journal::save)
                                    updateRun(checkNotNull(current.run))
                                }
                                current.shutterPending.set(false)
                                requestedAt = 0L
                                mutable.update { it.copy(phase = CameraTetherPhase.READY, failure = CameraTetherFailure.SETTINGS) }
                                continue
                            }
                            current.requestAcknowledged = true
                            mutable.update { it.copy(phase = CameraTetherPhase.WAITING) }
                        }
                        val now = clock()
                        val pending = current.transport.usesLegacyContents && current.transport.hasPendingHostImage()
                        if (needsCardReconciliation(model, pending, now, lastCheck, requestedAt, current.transport.usesLegacyContents)) {
                            val host = if (pending) current.transport.drainHostImages() else emptyList()
                            if (current.transport.usesLegacyContents) stopLive(current)
                            if (current.transport.usesLegacyContents) mutable.update { it.copy(phase = CameraTetherPhase.RECEIVING) }
                            try {
                                observe(current, cameraId, model, destination, host)
                                busy = 0
                            } catch (error: SonyTetherSession.RemoteResponseException) {
                                if (current.transport.usesLegacyContents || error.code !in setOf(0x2005, 0x2019) || ++busy > 10) throw error
                            }
                            current.permit.check()
                            if (current.transport.usesLegacyContents) openLive(current, current.transport.activateRemote(), this)
                            lastCheck = clock()
                            ready(current)
                        }
                        if (requestedAt != 0L && current.run?.shutterRequestedAt == null) requestedAt = 0L
                        if (requestedAt != 0L && clock() - requestedAt > 35_000) throw CameraTetherUnknownShotException()
                    }
                }
            } catch (_: CancellationException) {
                // 停止只使旧代次失效，已经发生的曝光和已准入的发布不会回滚。
            } catch (error: Exception) {
                if (com.rawlab.android.BuildConfig.DEBUG && !current.stopped) {
                    val response = if (error is SonyTetherSession.RemoteResponseException) " op=${error.operation} code=${error.code}" else ""
                    android.util.Log.w("RawLabCamera", "Tether ${error.javaClass.simpleName}$response at ${error.stackTrace.firstOrNull()}")
                }
                if (!current.stopped) failure = when {
                    error is CameraTetherSourceException -> CameraTetherFailure.SOURCE
                    error is CameraMediaSession.PhotoLimitExceededException -> CameraTetherFailure.PHOTO_LIMIT
                    current.run?.shutterRequestedAt != null -> CameraTetherFailure.UNKNOWN_SHOT
                    error is CameraTetherLiveException || current.liveFailure -> CameraTetherFailure.LIVE
                    error is CameraTetherSettingsException -> CameraTetherFailure.SETTINGS
                    error is CameraTetherBacklogException -> CameraTetherFailure.BACKLOG
                    error is CameraMediaSession.UnsupportedCameraException -> CameraTetherFailure.UNSUPPORTED
                    else -> CameraTetherFailure.CONNECTION
                }
            } finally {
                withContext(NonCancellable + Dispatchers.IO) {
                    stopLive(current)
                    current.transport.close()
                    current.shutter.close()
                    storeLock.withLock {
                        runCatching { store.load() }.onSuccess { jobs -> jobs.forEach(::updateJob) }
                            .onFailure { failure = CameraTetherFailure.STORAGE }
                        current.run?.let { run ->
                            val paused = run.copy(status = if (current.ended) CameraTetherStatus.ENDED else CameraTetherStatus.PAUSED)
                            if (failure == null && !current.ended && paused.shutterRequestedAt != null)
                                failure = CameraTetherFailure.UNKNOWN_SHOT
                            runCatching { journal.save(paused) }.onSuccess { updateRun(paused) }
                                .onFailure { failure = CameraTetherFailure.STORAGE }
                        }
                    }
                    if (active === current) {
                        active = null
                        mutable.update { it.copy(phase = CameraTetherPhase.PAUSED, live = false, current = null, currentBytes = 0, failure = failure) }
                    }
                }
            }
        }
    }

    fun capture() {
        val current = active ?: return
        if (mutable.value.phase != CameraTetherPhase.READY || !mutable.value.parameters.captureReady || mutable.value.parameters.busy || current.stopped || !current.shutterPending.compareAndSet(false, true)) return
        mutable.update { it.copy(phase = CameraTetherPhase.CAPTURING, failure = null) }
        if (current.shutter.trySend(Unit).isFailure) { current.shutterPending.set(false); ready(current) }
    }

    fun stop(ended: Boolean = false) {
        val current = active ?: return
        current.ended = ended
        current.stopped = true
        current.permit.cancel()
        current.liveGeneration++
        current.connection?.disconnect()
        current.transport.stop()
        work?.cancel()
        mutable.update { it.copy(live = false, phase = CameraTetherPhase.PAUSED) }
    }
    fun refreshParameters() {
        active?.parameterRequests?.trySend(ParameterRequest())
    }
    fun setParameter(code: Int, requested: Long) {
        val current = active ?: return
        if (mutable.value.phase != CameraTetherPhase.READY || mutable.value.parameters.busy) return
        mutable.update { it.copy(parameters = it.parameters.copy(busy = true, failure = null, reason = null)) }
        current.parameterRequests.trySend(ParameterRequest(code, requested))
    }
    suspend fun join() { work?.join() }

    private suspend fun observe(current: Active, cameraId: String, model: SonyCameraModel,
        destination: CameraImportDestination, host: List<CameraHostOriginal> = emptyList()) {
        val snapshot = current.transport.readCard(incremental = !current.initialObservation)
        storeLock.withLock {
            current.permit.check()
            // 恢复先核实原件；活动接收不反复散列历史媒体，打开编辑前会再次核实目标文件。
            if (current.initialObservation) {
                val jobs = store.load()
                jobs.forEach(::updateJob)
                current.run?.let { previous ->
                    val hadUnconfirmedShutter = previous.shutterRequestedAt != null
                    val resumed = queue.resume(previous, snapshot.photos, snapshot.hardwareIdentity, jobs, current.permit, { photo, output ->
                        mutable.update { it.copy(phase = CameraTetherPhase.RECEIVING, current = photo, currentBytes = 0) }
                        snapshot.download(photo, output) { bytes ->
                            current.permit.check(); mutable.update { it.copy(currentBytes = bytes) }
                        }
                    }, ::updateJob)
                    current.run = resumed
                    updateRun(resumed)
                    if (hadUnconfirmedShutter) mutable.update { it.copy(failure = CameraTetherFailure.UNKNOWN_SHOT) }
                }
            }
            if (current.run == null) {
                current.run = journal.create(cameraId, model.profileId, snapshot.photos, destination, snapshot.hardwareIdentity)
                snapshot.commit()
                current.initialObservation = false
                updateRun(checkNotNull(current.run))
                return@withLock
            }
            if (current.run?.hardwareIdentity?.let { it != snapshot.hardwareIdentity } == true) throw CameraTetherSourceException()
            val run = checkNotNull(current.run)
            val allCardPhotos = (run.observedPhotos + snapshot.photos).distinctBy { it.key }
            val expected = hostDigestsForCard(host, allCardPhotos)
            val activeBatchIds = run.batches.drop(run.rebasedBatches).map { it.id }.toSet()
            for (job in mutable.value.jobs.filter { it.id in activeBatchIds }) for (item in job.items) {
                if (item.saved != null && expected[item.photo.key]?.let { it != item.digest } == true)
                    throw CameraTetherSourceException()
            }
            var receivedAfterRequest = false
            try {
                current.run = queue.receive(checkNotNull(current.run), snapshot.photos, current.permit, { photo, output ->
                    mutable.update { it.copy(phase = CameraTetherPhase.RECEIVING, current = photo, currentBytes = 0) }
                    val digest = snapshot.download(photo, output) { bytes ->
                        current.permit.check(); mutable.update { it.copy(currentBytes = bytes) }
                    }
                    if (expected[photo.key]?.let { it != digest } == true) throw CameraTetherSourceException()
                    digest
                }, { run -> current.run = run; updateRun(run) }, { job ->
                    val before = mutable.value.jobs.find { it.id == job.id }?.savedCount ?: 0
                    if (job.savedCount > before && canFinishShutterWait(current.requestAcknowledged, current.requestBatchIds, job))
                        receivedAfterRequest = true
                    updateJob(job)
                }, mode = snapshot.observationMode)
                snapshot.commit()
                current.initialObservation = false
            } catch (error: IOException) {
                if (error.message?.contains("metadata changed") == true || error.message?.contains("baseline changed") == true)
                    throw CameraTetherSourceException()
                throw error
            }
            if (receivedAfterRequest && current.run?.shutterRequestedAt != null) {
                current.run = checkNotNull(current.run).copy(shutterRequestedAt = null).also(journal::save)
                current.shutterPending.set(false)
                current.requestBatchIds = null
                current.requestAcknowledged = false
                updateRun(checkNotNull(current.run))
            }
            mutable.update { it.copy(current = null, currentBytes = 0) }
        }
    }

    private fun ready(current: Active) {
        if (!current.stopped) mutable.update { it.copy(phase = if (!current.shutterPending.get() && current.run?.shutterRequestedAt == null)
            CameraTetherPhase.READY else CameraTetherPhase.WAITING) }
    }
    private fun processParameter(current: Active, request: ParameterRequest) {
        if (active !== current || current.stopped) return
        if (request.code == null) {
            runCatching { current.transport.readParameters() }
                .onSuccess { publishParameters(current, it) }
                .onFailure { publishParameterFailure(current, CameraParameterFailure.UNAVAILABLE, it.message) }
            return
        }
        val code = request.code
        val requested = request.requested ?: return
        runCatching { current.transport.setParameter(code, requested) }
            .onSuccess { result ->
                if (result.confirmed) publishParameters(current, result.readback)
                else if (active === current && !current.stopped) {
                    mutable.update { it.copy(parameters = it.parameters.copy(values = result.readback.values,
                        writable = result.readback.writable, captureReady = result.readback.captureReady, read = true, busy = false,
                        failure = CameraParameterFailure.UNCONFIRMED, reason = "Camera did not confirm the selected value")) }
                }
            }
            .onFailure { error ->
                val failure = if (error is SonyTetherSession.ParameterUnavailableException)
                    CameraParameterFailure.UNAVAILABLE else CameraParameterFailure.REJECTED
                publishParameterFailure(current, failure, error.message)
            }
    }
    private fun publishParameters(current: Active, readback: CameraTetherParameterReadback) {
        if (active !== current) return
        mutable.update { it.copy(parameters = CameraTetherParameterState(readback.values, readback.writable,
            read = true, busy = false, failure = null, reason = null, captureReady = readback.captureReady)) }
    }
    private fun publishParameterFailure(current: Active, failure: CameraParameterFailure, reason: String?) {
        if (active !== current) return
        mutable.update { it.copy(parameters = it.parameters.copy(busy = false, captureReady = false, failure = failure, reason = reason)) }
    }
    private fun updateRun(run: CameraTetherRun) { mutable.update { it.copy(run = run,
        runs = (it.runs.filterNot { old -> old.id == run.id } + run).sortedByDescending { item -> item.createdAt }) } }
    private fun updateJob(job: CameraImportJob) {
        mutable.update { it.copy(jobs = (it.jobs.filterNot { old -> old.id == job.id } + job).sortedByDescending { item -> item.createdAt }) }
        onJob(job)
    }

    private suspend fun openLive(current: Active, url: URL?, childScope: CoroutineScope) {
        mutable.update { it.copy(liveAvailable = url != null) }
        if (url == null) return
        val token = ++current.liveGeneration
        current.liveFailure = false
        mutable.update { it.copy(live = false) }
        current.liveJob = childScope.launch(Dispatchers.IO) {
            var connection: HttpURLConnection? = null
            try {
                connection = current.openLiveConnection(url)
                connection.instanceFollowRedirects = false
                connection.connectTimeout = 5_000; connection.readTimeout = 5_000
                current.connection = connection
                if (current.stopped || token != current.liveGeneration) return@launch
                if (connection.responseCode != 200) throw CameraTetherLiveException()
                var shown = 0L
                connection.inputStream.use { input ->
                    while (isActive && !current.stopped && token == current.liveGeneration) {
                        val bytes = SonyTetherSession.readFrame(input)
                        val now = clock()
                        if (shown != 0L && now - shown > 5_000) throw CameraTetherLiveException()
                        if (now - shown < 100) continue
                        val bitmap = decodeCameraPreview(bytes, large = true, pixelBudget = 16_000_000) ?: continue
                        shown = now
                        if (active === current && token == current.liveGeneration) mutable.update { it.copy(frame = bitmap, frameTime = now, live = true) }
                    }
                }
            } catch (_: Exception) {
                // HTTP 异常可能携带带令牌的 URL；只向 UI 发布固定错误类型。
                if (!current.stopped && token == current.liveGeneration) {
                    current.liveFailure = true
                    mutable.update { it.copy(live = false) }
                }
            } finally { connection?.disconnect(); if (current.connection === connection) current.connection = null }
        }
        val deadline = clock() + 8_000
        while (!mutable.value.live) {
            current.permit.check()
            if (current.liveFailure || clock() > deadline) throw CameraTetherLiveException()
            delay(50)
        }
    }

    private suspend fun stopLive(current: Active) {
        current.liveGeneration++
        current.connection?.disconnect()
        current.liveJob?.cancelAndJoin(); current.liveJob = null
        mutable.update { it.copy(live = false) }
    }
}

internal fun monotonicMillis() = System.nanoTime() / 1_000_000
/** 只结束本连接中已确认请求的收片等待；恢复旧任务不能代替未知快门结果的人工确认。 */
internal fun canFinishShutterWait(acknowledged: Boolean, priorBatches: Set<String>?, job: CameraImportJob): Boolean =
    acknowledged && priorBatches != null && job.id !in priorBatches && job.status == CameraJobStatus.COMPLETE
/** 快门请求本身也是核对线索，不能因 host 通知缺失而一直等到空闲周期。 */
internal fun needsCardReconciliation(model: SonyCameraModel, hostPending: Boolean, now: Long, lastCheck: Long, requestedAt: Long, legacyContents: Boolean = model == SonyCameraModel.ZVE10): Boolean {
    val requestedSinceCheck = requestedAt > lastCheck && now - requestedAt >= 3_000
    // ZV 逐对象核对会暂停取景；有拍摄线索时立即处理，空闲时降低完整核对频率。
    return hostPending || requestedSinceCheck || now - lastCheck >= if (legacyContents) 120_000L else 1_500L
}
private class CameraTetherLiveException : IOException("Camera live view unavailable")
private class CameraTetherUnknownShotException : IOException("Capture result needs confirmation")
