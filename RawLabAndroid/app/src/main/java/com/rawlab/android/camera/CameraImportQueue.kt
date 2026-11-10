package com.rawlab.android.camera

import java.io.FileOutputStream

/** 调用方持有存储锁；两种相机入口共用同一下载、校验和发布顺序。 */
internal fun receiveCameraJob(store: CameraImportStore, job: CameraImportJob, permit: CameraTransferPermit,
    download: (CameraPhoto, FileOutputStream) -> String, onJob: (CameraImportJob) -> Unit = {}): CameraImportJob {
    if (job.status == CameraJobStatus.COMPLETE) return job
    permit.check()
    var latest = job.copy(status = CameraJobStatus.ACTIVE)
    store.save(latest)
    for ((index, item) in latest.items.withIndex()) {
        if (item.saved != null) continue
        permit.check()
        val part = store.partial(job.id)
        try {
            val digest = FileOutputStream(part).use { output ->
                val result = download(item.photo, output)
                output.fd.sync()
                result
            }
            permit.check()
            latest = store.publish(latest, index, part, digest, permit)
            onJob(latest)
        } finally { part.delete() }
    }
    return latest
}
