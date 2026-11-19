package com.rawlab.android.editor

import android.net.Uri
import com.rawlab.android.R
import com.rawlab.android.analytics.UsageEvent
import com.rawlab.android.editor.render.ExportDestinationCleanup
import com.rawlab.android.editor.render.Work
import com.rawlab.android.editor.render.WorkResult
import com.rawlab.android.editor.render.discardOwnedInput
import com.rawlab.android.editor.storage.EditSaveResult
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.EditSettings
import kotlinx.coroutines.flow.MutableStateFlow

internal class EditorExportStateHolder(
    private val mutable: MutableStateFlow<EditorState>,
    private val exportDestinationCleanup: ExportDestinationCleanup,
    private val strings: EditorStrings,
    private val mainDelivery: (() -> Unit) -> Unit,
    private val recordUsage: (UsageEvent) -> Unit,
    private val isDisposed: () -> Boolean,
    private val gpuMode: () -> Int,
    private val requestedPreviewLongEdge: () -> Int,
    private val onPersist: (ImportedPhoto, EditSettings, (EditSaveResult) -> Unit) -> Unit,
    private val onSubmitExport: (Work.Export) -> Unit,
    private val onInvalidateRender: () -> Unit,
    private val onReleaseDeferredCollections: () -> Unit,
    private val onUpdatePreviewSize: (Int) -> Unit,
) {
    val cleanup: ExportDestinationCleanup get() = exportDestinationCleanup

    fun beginExport(completed: (Boolean) -> Unit = {}) {
        if (!mutable.value.canExport) return completed(false)
        val photo = mutable.value.photo ?: return completed(false)
        onPersist(photo, mutable.value.edits) { saved ->
            mutable.value = mutable.value.copy(saveState = saved.state, saveError = saved.message)
            if (saved.state == EditSaveState.FAILED) completed(false)
            else {
                mutable.value = mutable.value.copy(operation = Operation.PICK_EXPORT, error = null)
                completed(true)
            }
        }
    }

    fun cancelExport() {
        val operation = mutable.value.operation
        if (operation == Operation.PICK_EXPORT) {
            mutable.value = mutable.value.copy(operation = Operation.NONE)
        } else if (operation == Operation.EXPORT) {
            onInvalidateRender()
            mutable.value = EditorStateReducer.renderFinished(mutable.value)
            onReleaseDeferredCollections()
        }
        onUpdatePreviewSize(requestedPreviewLongEdge())
    }

    fun export(destination: Uri?, format: ExportFormat, longEdge: Int? = null) {
        when (val submission = prepareExportSubmission(
            mutable.value,
            destination,
            format,
            longEdge,
            gpuMode(),
            exportDestinationCleanup,
            isDisposed(),
        )) {
            is ExportSubmission.Rejected -> {
                val next = if (submission.errorKey != null) {
                    submission.state.copy(error = strings.text(submission.errorKey))
                } else submission.state
                if (next != mutable.value) mutable.value = next
                if (submission.refreshPreviewSize) onUpdatePreviewSize(requestedPreviewLongEdge())
            }
            is ExportSubmission.Ready -> {
                mutable.value = submission.state
                onSubmitExport(submission.work)
            }
        }
    }

    fun onExportCompleted() {
        mutable.value = mutable.value.copy(operation = Operation.NONE, message = strings.text(R.string.export_done))
        recordUsage(UsageEvent.ExportCompleted)
    }

    // Q12: A late cancel after the commit point still completes the export and keeps the rendered file.
    fun onLateExportCompleted(result: WorkResult) {
        result.discardOwnedInput()
        if (result is WorkResult.Export && !isDisposed()) {
            mainDelivery {
                if (isDisposed()) return@mainDelivery
                mutable.value = EditorStateReducer.lateExportCompleted(mutable.value, strings.text(R.string.export_done))
                recordUsage(UsageEvent.ExportCompleted)
            }
        }
    }
}
