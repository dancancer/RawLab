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
import com.rawlab.android.format.OutputSharpening
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
    private var prepareRevision: Long = 0

    val cleanup: ExportDestinationCleanup get() = exportDestinationCleanup

    fun beginExport(completed: (Boolean) -> Unit = {}) {
        if (isDisposed() || !mutable.value.canExport) return completed(false)
        val photo = mutable.value.photo ?: return completed(false)
        val token = ++prepareRevision
        mutable.value = mutable.value.copy(
            operation = Operation.PREPARE_EXPORT,
            exportStep = SingleExportStep.PREPARING,
            error = null,
        )
        onPersist(photo, mutable.value.edits) { saved ->
            if (isDisposed()) return@onPersist completed(false)
            if (mutable.value.photo?.identity == photo.identity) {
                mutable.value = mutable.value.copy(
                    saveState = saved.state,
                    saveError = saved.formatMessage(strings),
                )
            }
            if (token != prepareRevision ||
                mutable.value.operation != Operation.PREPARE_EXPORT ||
                mutable.value.photo?.identity != photo.identity
            ) {
                completed(false)
                return@onPersist
            }
            if (saved.state == EditSaveState.FAILED) {
                mutable.value = mutable.value.copy(
                    operation = Operation.NONE,
                    exportStep = SingleExportStep.NONE,
                )
                onUpdatePreviewSize(requestedPreviewLongEdge())
                completed(false)
            } else {
                mutable.value = mutable.value.copy(
                    operation = Operation.PICK_EXPORT,
                    exportStep = SingleExportStep.OPTIONS,
                    error = null,
                )
                completed(true)
            }
        }
    }

    fun beginExportDestinationPick() {
        val current = mutable.value
        if (!isDisposed() &&
            current.operation == Operation.PICK_EXPORT &&
            current.exportStep == SingleExportStep.OPTIONS &&
            current.photo != null
        ) {
            mutable.value = current.copy(exportStep = SingleExportStep.PICKING_DESTINATION)
        }
    }

    fun returnToExportOptions() {
        val current = mutable.value
        if (!isDisposed() &&
            current.operation == Operation.PICK_EXPORT &&
            current.exportStep == SingleExportStep.PICKING_DESTINATION &&
            current.photo != null
        ) {
            mutable.value = current.copy(exportStep = SingleExportStep.OPTIONS)
        }
    }

    fun cancelExport() {
        prepareRevision += 1
        val operation = mutable.value.operation
        if (operation == Operation.PREPARE_EXPORT || operation == Operation.PICK_EXPORT) {
            mutable.value = mutable.value.copy(operation = Operation.NONE, exportStep = SingleExportStep.NONE)
        } else if (operation == Operation.EXPORT) {
            onInvalidateRender()
            mutable.value = EditorStateReducer.renderFinished(mutable.value)
            onReleaseDeferredCollections()
        }
        onUpdatePreviewSize(requestedPreviewLongEdge())
    }

    fun export(
        destination: Uri?,
        format: ExportFormat,
        longEdge: Int? = null,
        outputSharpening: OutputSharpening = OutputSharpening.OFF,
    ) {
        when (val submission = prepareExportSubmission(
            mutable.value,
            destination,
            format,
            longEdge,
            gpuMode(),
            exportDestinationCleanup,
            isDisposed(),
            outputSharpening,
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
        mutable.value = mutable.value.copy(
            operation = Operation.NONE,
            exportStep = SingleExportStep.NONE,
            exportProgress = null,
            message = strings.text(R.string.export_done),
        )
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
