package com.rawlab.android.editor

import android.app.Application
import com.rawlab.android.R
import com.rawlab.android.analytics.UsageAnalytics
import com.rawlab.android.analytics.UsageEvent
import com.rawlab.android.batch.BatchExportModel
import com.rawlab.android.batch.BatchJob
import com.rawlab.android.batch.journal.BatchJournal
import com.rawlab.android.batch.BatchPhase
import com.rawlab.android.batch.BatchSourceSnapshot
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.photo.PhotoStorage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

// ============================================================================
//  编辑器里的批量导出：当前打开的任务与可续跑的未完成任务
//  生命周期跟随 EditorViewModel；读写失败通过 onError 交给编辑器显示
// ============================================================================

internal class EditorBatches(
    private val application: Application,
    private val storage: PhotoStorage,
    private val scope: CoroutineScope,
    private val processorFactory: (Int, File?) -> NativeProcessor,
    private val usage: UsageAnalytics,
    private val onError: (String?) -> Unit,
) {
    private val mutableActive = MutableStateFlow<BatchExportModel?>(null)
    val active = mutableActive.asStateFlow()
    private val mutablePending = MutableStateFlow<List<BatchJob>>(emptyList())
    val pending = mutablePending.asStateFlow()
    private var automaticStart: BatchExportModel? = null
    private var pendingRevision = 0

    fun begin(source: BatchSourceSnapshot, gpuMode: Int) { mutableActive.value = model(source, null, gpuMode) }

    fun retain(job: BatchJob) {
        pendingRevision++
        mutablePending.value = listOf(job) + mutablePending.value.filterNot { it.id == job.id }
    }

    fun resume(job: BatchJob, gpuMode: Int, startAutomatically: Boolean = false) {
        val resumed = model(job.source, job, gpuMode)
        pendingRevision++
        mutablePending.value = mutablePending.value.filterNot { it.id == job.id }
        mutableActive.value = resumed
        automaticStart = if (startAutomatically) resumed else null
        if (startAutomatically) scope.launch {
            resumed.state.first { it.phase != BatchPhase.PREPARING }
            if (mutableActive.value === resumed && automaticStart === resumed) {
                automaticStart = null
                resumed.continueUnfinished()
            }
        }
    }

    fun close() {
        val model = mutableActive.value ?: return
        if (model.state.value.phase in setOf(BatchPhase.RUNNING, BatchPhase.PREPARING)) return
        val cleanup = model.discardDraftOrCompleted()
        model.close()
        mutableActive.value = null
        scope.launch {
            try { cleanup?.await(); refreshPending() }
            catch (error: Exception) { onError(error.message) }
        }
    }

    fun refreshPending() {
        val revision = ++pendingRevision
        scope.launch {
            try {
                val pending = withContext(Dispatchers.IO) {
                    val journal = BatchJournal(File(application.filesDir, "RawLab/BatchJobs"))
                    journal.pending().mapNotNull(journal::load)
                }
                if (revision == pendingRevision) mutablePending.value = pending
            } catch (error: Exception) { onError(AppStrings.format(R.string.message_unable_to_read_batch_task, error.message.toString())) }
        }
    }

    fun cancelForBackground() { automaticStart = null; mutableActive.value?.cancel(forBackground = true) }

    fun dispose() { automaticStart = null; mutableActive.value?.close() }

    private fun model(source: BatchSourceSnapshot, job: BatchJob?, gpuMode: Int) = BatchExportModel(application, storage,
        source, job, gpuMode = gpuMode, processorFactory = processorFactory,
        onTerminal = { succeeded, failed, outcome -> usage.record(UsageEvent.BatchExportCompleted(succeeded, failed, outcome)) })
}
