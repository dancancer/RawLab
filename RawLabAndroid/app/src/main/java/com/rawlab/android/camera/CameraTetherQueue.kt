package com.rawlab.android.camera

import java.io.FileOutputStream
import java.io.IOException

/** 与选片队列共用 Store 和外部存储锁；每轮有界接收，已预留批次在下一次恢复时继续。 */
internal class CameraTetherQueue(private val store: CameraImportStore, private val journal: CameraTetherJournal) {
    fun receive(initial: CameraTetherRun, observed: List<CameraPhoto>, permit: CameraTransferPermit,
        download: (CameraPhoto, FileOutputStream) -> String,
        onRun: (CameraTetherRun) -> Unit = {}, onJob: (CameraImportJob) -> Unit = {}): CameraTetherRun {
        permit.check()
        // reserve 先核对全卡身份，防止缺失基线或重用对象被当作新照片。
        var run = journal.reserve(initial, observed).first
        onRun(run)
        var count = 0
        var bytes = 0L
        var batchIndex = 0
        while (true) {
            while (batchIndex < run.batches.size) {
                permit.check()
                val batch = run.batches[batchIndex++]
                val job = store.create(run.cameraId, batch.photos, run.destination, batch.id)
                onJob(receiveCameraJob(store, job, permit, { photo, output ->
                    if (count >= MAX_PENDING || bytes + photo.size > MAX_PENDING_BYTES) throw CameraTetherBacklogException()
                    count++; bytes += photo.size
                    download(photo, output)
                }, onJob))
            }
            val (updated, batch) = journal.reserve(run, observed)
            run = updated
            if (batch == null) return run
            onRun(run)
        }
    }

    companion object {
        const val MAX_PENDING = 64
        const val MAX_PENDING_BYTES = 2L * 1024 * 1024 * 1024
    }
}

internal class CameraTetherBacklogException : IOException("Camera transfer backlog exceeds budget")
