package com.rawlab.android.editor

import android.app.Application
import com.rawlab.android.batch.BatchJob
import com.rawlab.android.batch.BatchSourceSnapshot
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

internal class EditorBatchStateHolder(
    application: Application,
    private val session: EditorDocumentSession,
) {
    private val mutable get() = session.mutable
    private val scope get() = session.scope

    private val batches = EditorBatches(
        application,
        session.storage,
        session.scope,
        session.dependencies.batchProcessorFactory,
        session.dependencies.usageFactory,
        session.strings,
    ) { error -> mutable.value = mutable.value.copy(error = error) }

    val active = batches.active
    val pending = batches.pending

    internal var releaseEditorRasterOperation: () -> Unit = session.dependencies.renderGateway::releaseDecodedRaster

    fun refreshPending() = batches.refreshPending()
    fun retain(job: BatchJob) = batches.retain(job)
    fun hasActiveOrPending(): Boolean = active.value != null || pending.value.isNotEmpty()
    fun cancelForBackground() = batches.cancelForBackground()
    fun dispose() = batches.dispose()
    fun closeBatch() = batches.close()

    fun beginBatch() {
        val current = mutable.value
        if (!current.canExport || active.value != null) return
        val photo = current.photo ?: return
        val source = BatchSourceSnapshot(photo.identity, photo.file, current.edits, photo.name, inputKind = photo.inputKind)
        releaseEditorRasterForBatch { if (it) batches.begin(source, session.gpuMode()) }
    }

    fun resumeBatch(job: BatchJob) {
        if (active.value != null || mutable.value.committingAdjustments ||
            mutable.value.draft != null || mutable.value.operation != Operation.NONE
        ) return
        releaseEditorRasterForBatch { if (it) batches.resume(job, session.gpuMode()) }
    }

    fun resumeAttached(job: BatchJob, startAutomatically: Boolean) {
        batches.resume(job, session.gpuMode(), startAutomatically = startAutomatically)
    }

    fun releaseEditorRasterForBatch(completed: (Boolean) -> Unit) {
        if (session.disposed) {
            completed(false)
            return
        }
        session.actions.cancelMigration(true)
        if (mutable.value.committingAdjustments) {
            scope.launch {
                mutable.first { !it.committingAdjustments }
                releaseEditorRasterForBatch(completed)
            }
            return
        }
        // 页面切换沿用存储动作的输入门禁；只在渲染队列上释放完整解码图，保留仍在显示的预览。
        mutable.value = mutable.value.copy(committingAdjustments = true)
        session.actions.performAfterPendingRender {
            val result = runCatching { releaseEditorRasterOperation() }
            scope.launch {
                if (!session.disposed) {
                    mutable.value = mutable.value.copy(committingAdjustments = false)
                    try {
                        result.exceptionOrNull()?.let { mutable.value = mutable.value.copy(error = session.failure(it)) }
                        completed(result.isSuccess)
                    } finally {
                        session.actions.finishAdjustmentClose()
                        session.actions.releaseDeferredCollections()
                    }
                }
            }
        }
    }
}
