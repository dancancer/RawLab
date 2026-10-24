package com.rawlab.android.batch

import com.rawlab.android.batch.journal.BatchJournal
import com.rawlab.android.photo.BatchGlobalFailure
import com.rawlab.android.settings.EditSettings

// ============================================================================
//  批量导出的逐行执行：渲染、写出、取消与重试
// ============================================================================

object BatchRunner {
    fun <T> run(
        job: BatchJob,
        render: (BatchTarget, EditSettings) -> T,
        write: (T, String, BatchTarget) -> Unit,
        shouldCancel: () -> Boolean = { false },
        journal: BatchJournal? = null,
        didUpdate: (BatchJob) -> Unit = {},
        publish: ((T, String, BatchTarget, (String) -> Unit) -> Unit)? = null,
        dispose: (T) -> Unit = {},
        onlyIDs: Set<String>? = null,
    ): BatchJob {
        job.validate()
        var current = job.withRows(job.rows.map { if (it.status == BatchRowStatus.PROCESSING) it.copy(status = BatchRowStatus.PENDING) else it }, null)
        fun commit(index: Int? = null) {
            if (index == null) journal?.save(current) else journal?.recordRow(current, index)
            didUpdate(current)
        }
        commit()
        current.rows.indices.forEach { index ->
            if (onlyIDs != null && current.rows[index].id !in onlyIDs) return@forEach
            if (current.rows[index].status in setOf(BatchRowStatus.SUCCESS, BatchRowStatus.NEEDS_CONFIRMATION, BatchRowStatus.PUBLISHING)) return@forEach
            if (shouldCancel()) {
                current = current.withRows(current.rows.mapIndexed { i, row ->
                    if (i >= index && (onlyIDs == null || row.id in onlyIDs) && row.status in setOf(BatchRowStatus.PENDING, BatchRowStatus.PROCESSING, BatchRowStatus.FAILED, BatchRowStatus.CANCELLED)) row.copy(status = BatchRowStatus.CANCELLED) else row
                })
                commit()
                return current
            }
            val processing = current.rows.toMutableList()
            processing[index] = processing[index].copy(status = BatchRowStatus.PROCESSING, error = null)
            current = current.withRows(processing)
            commit(index)
            try {
                val row = current.rows[index]
                if (current.settingsMode == BatchSettingsMode.PER_TARGET_FROZEN) row.target.frozen!!.verifyFiles(row.target.sourceFile)
                val payload = render(row.target, current.settingsFor(row.target))
                try {
                    current = current.withRows(current.rows.mapIndexed { i, item -> if (i == index) item.copy(status = BatchRowStatus.PUBLISHING) else item })
                    commit(index)
                    if (publish == null) write(payload, row.outputName, row.target)
                    else publish(payload, row.outputName, row.target) { uri ->
                        current = current.withRows(current.rows.mapIndexed { i, item -> if (i == index) item.copy(outputUri = uri, outputReady = false) else item })
                        commit(index)
                    }
                    current = current.withRows(current.rows.mapIndexed { i, item -> if (i == index) item.copy(outputReady = true) else item })
                    commit(index)
                    val done = current.rows.toMutableList()
                    done[index] = done[index].copy(status = BatchRowStatus.SUCCESS)
                    current = current.withRows(done)
                } finally { dispose(payload) }
            } catch (error: BatchGlobalFailure) {
                val failed = current.rows.map { row ->
                    if (row.status in setOf(BatchRowStatus.PROCESSING, BatchRowStatus.PUBLISHING)) row.copy(status = BatchRowStatus.FAILED, error = error.message) else row
                }
                current = current.withRows(failed, error.message)
                commit()
                return current
            } catch (error: Throwable) {
                val failed = current.rows.toMutableList()
                failed[index] = failed[index].copy(status = if (failed[index].status == BatchRowStatus.PUBLISHING) BatchRowStatus.NEEDS_CONFIRMATION else BatchRowStatus.FAILED,
                    error = error.message ?: error.javaClass.simpleName)
                current = current.withRows(failed)
            }
            commit(index)
        }
        return current
    }

    fun <T> retryFailed(
        job: BatchJob,
        render: (BatchTarget, EditSettings) -> T,
        write: (T, String, BatchTarget) -> Unit,
        shouldCancel: () -> Boolean = { false },
        journal: BatchJournal? = null,
        dispose: (T) -> Unit = {},
    ): BatchJob = run(job.withRows(job.rows.map { if (it.status == BatchRowStatus.FAILED) it.copy(status = BatchRowStatus.PENDING, error = null) else it }),
        render, write, shouldCancel, journal, dispose = dispose,
        onlyIDs = job.rows.filter { it.status == BatchRowStatus.FAILED }.map { it.id }.toSet())
}
