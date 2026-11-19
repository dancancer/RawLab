package com.rawlab.android.editor

import android.app.Application
import com.rawlab.android.analytics.UsageAnalytics
import com.rawlab.android.batch.BatchJob
import com.rawlab.android.batch.BatchSourceSnapshot
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.photo.PhotoStorage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import java.io.File

internal class EditorBatchStateHolder(
    application: Application,
    storage: PhotoStorage,
    private val scope: CoroutineScope,
    batchProcessorFactory: (Int, File?) -> NativeProcessor,
    usageProvider: () -> UsageAnalytics,
    strings: EditorStrings = EditorStrings(),
    private val mutable: MutableStateFlow<EditorState>,
    private val isDisposed: () -> Boolean,
    private val gpuMode: () -> Int,
    private val formatFailure: (Throwable) -> String,
    private val onCancelProcessingMigration: () -> Unit,
    private val onPerformAfterPendingRender: (() -> Unit) -> Unit,
    private val onFinishAdjustmentClose: () -> Unit,
    private val onReleaseDeferredCollections: () -> Unit,
    defaultReleaseRaster: () -> Unit,
) {
    private val batches = EditorBatches(
        application,
        storage,
        scope,
        batchProcessorFactory,
        usageProvider,
        strings,
    ) { error -> mutable.value = mutable.value.copy(error = error) }

    val active = batches.active
    val pending = batches.pending

    internal var releaseEditorRasterOperation: () -> Unit = defaultReleaseRaster

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
        releaseEditorRasterForBatch { if (it) batches.begin(source, gpuMode()) }
    }

    fun resumeBatch(job: BatchJob) {
        if (active.value != null || mutable.value.committingAdjustments ||
            mutable.value.draft != null || mutable.value.operation != Operation.NONE
        ) return
        releaseEditorRasterForBatch { if (it) batches.resume(job, gpuMode()) }
    }

    fun resumeAttached(job: BatchJob, startAutomatically: Boolean) {
        batches.resume(job, gpuMode(), startAutomatically = startAutomatically)
    }

    fun releaseEditorRasterForBatch(completed: (Boolean) -> Unit) {
        if (isDisposed()) {
            completed(false)
            return
        }
        onCancelProcessingMigration()
        if (mutable.value.committingAdjustments) {
            scope.launch {
                mutable.first { !it.committingAdjustments }
                releaseEditorRasterForBatch(completed)
            }
            return
        }
        // 页面切换沿用存储动作的输入门禁；只在渲染队列上释放完整解码图，保留仍在显示的预览。
        mutable.value = mutable.value.copy(committingAdjustments = true)
        onPerformAfterPendingRender {
            val result = runCatching { releaseEditorRasterOperation() }
            scope.launch {
                if (!isDisposed()) {
                    mutable.value = mutable.value.copy(committingAdjustments = false)
                    try {
                        result.exceptionOrNull()?.let { mutable.value = mutable.value.copy(error = formatFailure(it)) }
                        completed(result.isSuccess)
                    } finally {
                        onFinishAdjustmentClose()
                        onReleaseDeferredCollections()
                    }
                }
            }
        }
    }
}
