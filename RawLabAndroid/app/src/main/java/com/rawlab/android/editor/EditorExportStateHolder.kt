package com.rawlab.android.editor

import android.net.Uri
import com.rawlab.android.R
import com.rawlab.android.analytics.UsageEvent
import com.rawlab.android.editor.render.ExportDestinationCleanup
import com.rawlab.android.editor.render.WorkResult
import com.rawlab.android.editor.render.discardOwnedInput
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.OutputSharpening

internal class EditorExportStateHolder(
    private val session: EditorDocumentSession,
) {
    private val mutable get() = session.mutable
    private val exportDestinationCleanup get() = session.dependencies.exportCleanup
    private val strings get() = session.strings
    private val mainDelivery get() = session.dependencies.mainDelivery
    private val recordUsage get() = session.dependencies.recordUsage
    private var prepareRevision: Long = 0

    val cleanup: ExportDestinationCleanup get() = exportDestinationCleanup

    fun beginExport(completed: (Boolean) -> Unit = {}) {
        if (session.disposed || !mutable.value.canExport) return completed(false)
        val photo = mutable.value.photo ?: return completed(false)
        val token = ++prepareRevision
        mutable.value = mutable.value.copy(
            operation = Operation.PREPARE_EXPORT,
            exportStep = SingleExportStep.PREPARING,
            error = null,
        )
        session.actions.persist(photo, mutable.value.edits, false) { saved ->
            if (session.disposed) return@persist completed(false)
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
                return@persist
            }
            if (saved.state == EditSaveState.FAILED) {
                mutable.value = mutable.value.copy(
                    operation = Operation.NONE,
                    exportStep = SingleExportStep.NONE,
                )
                session.actions.updatePreviewSize(session.actions.requestedPreviewLongEdge())
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
        if (!session.disposed &&
            current.operation == Operation.PICK_EXPORT &&
            current.exportStep == SingleExportStep.OPTIONS &&
            current.photo != null
        ) {
            mutable.value = current.copy(exportStep = SingleExportStep.PICKING_DESTINATION)
        }
    }

    fun returnToExportOptions() {
        val current = mutable.value
        if (!session.disposed &&
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
            session.actions.invalidateRender()
            mutable.value = EditorStateReducer.renderFinished(mutable.value)
            session.actions.releaseDeferredCollections()
        }
        session.actions.updatePreviewSize(session.actions.requestedPreviewLongEdge())
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
            session.gpuMode(),
            exportDestinationCleanup,
            session.disposed,
            outputSharpening,
        )) {
            is ExportSubmission.Rejected -> {
                val next = if (submission.errorKey != null) {
                    submission.state.copy(error = strings.text(submission.errorKey))
                } else submission.state
                if (next != mutable.value) mutable.value = next
                if (submission.refreshPreviewSize) session.actions.updatePreviewSize(session.actions.requestedPreviewLongEdge())
            }
            is ExportSubmission.Ready -> {
                mutable.value = submission.state
                session.actions.submitRender(submission.work)
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
        com.rawlab.android.diagnostics.DiagnosticRegistry.peek()?.recordBreadcrumb(
            category = "export",
            stage = "exportCompleted",
            message = "Single photo export completed",
        )
        recordUsage(UsageEvent.ExportCompleted)
        session.emit(EditorSessionEvent.ExportCompleted(late = false))
    }

    // Q12: A late cancel after the commit point still completes the export and keeps the rendered file.
    fun onLateExportCompleted(result: WorkResult) {
        result.discardOwnedInput()
        if (result is WorkResult.Export && !session.disposed) {
            mainDelivery {
                if (session.disposed) return@mainDelivery
                mutable.value = EditorStateReducer.lateExportCompleted(mutable.value, strings.text(R.string.export_done))
                com.rawlab.android.diagnostics.DiagnosticRegistry.peek()?.recordBreadcrumb(
                    category = "export",
                    stage = "lateExportCompleted",
                    message = "Late single photo export completed",
                )
                recordUsage(UsageEvent.ExportCompleted)
                session.emit(EditorSessionEvent.ExportCompleted(late = true))
            }
        }
    }
}
