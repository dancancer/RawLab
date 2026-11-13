package com.rawlab.android.camera

import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStream

/** 与选片队列共用 Store 和外部存储锁；每轮有界接收，已预留批次在下一次恢复时继续。 */
internal class CameraTetherQueue(private val store: CameraImportStore, private val journal: CameraTetherJournal) {
    fun receive(initial: CameraTetherRun, observed: List<CameraPhoto>, permit: CameraTransferPermit,
        download: (CameraPhoto, FileOutputStream) -> String,
        onRun: (CameraTetherRun) -> Unit = {}, onJob: (CameraImportJob) -> Unit = {},
        mode: CameraTetherObservationMode = CameraTetherObservationMode.Full): CameraTetherRun {
        permit.check()
        // reserve 按观测模式核对基线/尾部锚点与对象槽位身份，防止换卡或句柄重用被当作新照片。
        var run = journal.reserve(initial, observed, mode).first
        onRun(run)
        var count = 0
        var bytes = 0L
        var batchIndex = run.rebasedBatches
        while (true) {
            while (batchIndex < run.batches.size) {
                permit.check()
                val batch = run.batches[batchIndex++]
                val job = store.create(run.cameraId, batch.photos, run.destination, batch.id)
                onJob(receiveCameraJob(store, job, permit, { photo, output ->
                    if (count >= MAX_PENDING || bytes + photo.size > MAX_PENDING_BYTES) throw CameraTetherBacklogException()
                    count++; bytes += photo.size
                    download(photo, output)
                }, onJob, continueOnPhotoError = false))
            }
            val (updated, batch) = journal.reserve(run, observed, mode)
            run = updated
            if (batch == null) return run
            onRun(run)
        }
    }

    fun resume(initial: CameraTetherRun, observed: List<CameraPhoto>, hardwareIdentity: CameraHardwareIdentity?,
        jobs: List<CameraImportJob>, permit: CameraTransferPermit, download: (CameraPhoto, OutputStream) -> String,
        onJob: (CameraImportJob) -> Unit): CameraTetherRun {
        permit.check()
        if (hardwareIdentity == null || hardwareIdentity != initial.hardwareIdentity) throw CameraTetherSourceException()
        val registered = initial.recoveryJobs(jobs) ?: throw CameraTetherSourceException()
        val rebased = journal.rebase(initial, observed)
        val planned = registered.map { job ->
            val matches = resumeLocatorMap(job, observed, sessionOwner = null)
            if (job.items.any { it.photo.key !in matches }) throw CameraTetherSourceException()
            job to matches
        }
        // 已发布的文件也要核对当前卡内的源字节，不能靠本机副本或旧句柄确认。
        for ((job, matches) in planned) for (item in job.items) {
            if (item.saved == null) continue
            permit.check()
            if (download(matches.getValue(item.photo.key), discardBytes) != item.digest)
                throw CameraTetherSourceException()
        }
        for ((job, matches) in planned) {
            if (job.status == CameraJobStatus.COMPLETE) continue
            val verified = try {
                receiveCameraJob(store, job, permit, { original, output ->
                    download(matches.getValue(original.key), output)
                }, onJob, continueOnPhotoError = false)
            } catch (_: CameraImportSourceChanged) { throw CameraTetherSourceException() }
            if (verified.status != CameraJobStatus.COMPLETE) throw CameraTetherSourceException()
        }
        permit.check()
        journal.save(rebased)
        return rebased
    }

    companion object {
        const val MAX_PENDING = 64
        const val MAX_PENDING_BYTES = 2L * 1024 * 1024 * 1024
        private val discardBytes = object : OutputStream() {
            override fun write(value: Int) = Unit
            override fun write(bytes: ByteArray, offset: Int, length: Int) = Unit
        }
    }
}

/** 恢复前须有旧清单的来源凭据，机身序列号和卡槽都不能代替原件摘要。 */
internal fun CameraTetherRun.recoveryJobs(jobs: List<CameraImportJob>): List<CameraImportJob>? {
    if (status == CameraTetherStatus.ENDED || hardwareIdentity == null) return null
    // 首拍还没登记成批次就断线：没有已预留的原件可重验，续接只做 rebase 并折叠当前卡清单；
    // 卡内来源唯一性由 rebase 逐个核对兜底，基线是否完整不再阻塞续接。
    if (batches.isEmpty()) return emptyList()
    val byId = jobs.associateBy { it.id }
    val registered = batches.map { batch ->
        val job = byId[batch.id] ?: return null
        if (job.cameraId != cameraId || job.destination != destination || job.items.size != batch.photos.size ||
            batch.photos.zip(job.items).any { (photo, item) -> item.digest == null || !photo.matchesSnapshot(item.photo) })
            return null
        job
    }
    // 已保存原件的校验和待传原件共用同一预算。超出预算时改为手动补传，
    // 避免重连后从头校验同一批文件，或把上一次连接的校验当成当前卡的凭据。
    if (registered.sumOf { it.items.size } > CameraTetherQueue.MAX_PENDING ||
        registered.sumOf { it.totalBytes } > CameraTetherQueue.MAX_PENDING_BYTES) return null
    val sources = registered.flatMap { job -> job.items.map { it.photo } }.groupBy { it.resumeMetadataKey }
    // 首次连接时只观察、未接收的基线对象没有摘要。不要把重连后同名文件当成旧对象。
    if (baseline.any { photo ->
        sources[photo.resumeMetadataKey].orEmpty().count { photo.matchesResumeMetadata(it) } != 1
    }) return null
    return registered
}

internal class CameraTetherBacklogException : IOException("Camera transfer backlog exceeds budget")
internal class CameraTetherSourceException : IOException("Camera originals no longer match the session")
