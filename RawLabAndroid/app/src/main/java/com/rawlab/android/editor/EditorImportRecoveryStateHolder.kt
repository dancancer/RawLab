package com.rawlab.android.editor

import android.net.Uri
import com.rawlab.android.R
import com.rawlab.android.editor.render.Work
import com.rawlab.android.editor.render.WorkResult
import com.rawlab.android.editor.render.discardOwnedInput
import com.rawlab.android.editor.storage.EditSaveResult
import com.rawlab.android.editor.storage.EditorEditStore
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.HDRModeError
import com.rawlab.android.settings.PhotoIdentity
import kotlinx.coroutines.flow.MutableStateFlow
import java.io.File

internal class EditorImportRecoveryStateHolder(
    private val mutable: MutableStateFlow<EditorState>,
    private val editStore: EditorEditStore,
    private val draftStore: EditorDraftStore,
    private val strings: EditorStrings,
    private val isDisposed: () -> Boolean,
    private val gpuMode: () -> Int,
    private val formatFailure: (Throwable) -> String,
    private val collectionPhoto: (String) -> ImportedPhoto?,
    private val collectionOwns: (File) -> Boolean,
    private val onReleaseDeferredCollectionCopies: () -> Unit,
    private val onCancelAdjustmentInteraction: () -> Unit,
    private val onPersist: (ImportedPhoto, EditSettings, (EditSaveResult) -> Unit) -> Unit,
    private val onBeforeStartImport: () -> Unit,
    private val onSubmitImport: (Work.Import) -> Unit,
    private val onAcceptHistorySource: (ImportedPhoto, com.rawlab.android.settings.PhotoEditState?) -> Unit,
    private val onCollectionOpened: (String) -> Unit,
    private val onIncludeIndependentRecipeLook: (EditSettings) -> Unit,
    private val onCommitAdjustments: (work: () -> Unit, completed: (Result<Unit>) -> Unit) -> Unit,
) {
    private val pendingPhotoImport = PendingPhotoImport()
    private var failedX3fImport: Work.Import? = null
    private var failedUnusableImport: Pair<Work.Import, PhotoIdentity>? = null

    fun ownsFailedRecovery(file: File): Boolean =
        failedX3fImport?.retained?.file == file || failedUnusableImport?.first?.retained?.file == file

    fun completePendingImport(identity: PhotoIdentity): Boolean = pendingPhotoImport.complete(identity)

    fun clearPendingImport() = pendingPhotoImport.clear()

    fun importPhoto(uri: Uri?, completed: (Boolean) -> Unit = {}) {
        if (mutable.value.committingAdjustments) return completed(false)
        if (uri == null) {
            pendingPhotoImport.clear()
            return completed(false)
        }
        if (mutable.value.operation != Operation.NONE || mutable.value.draft != null) return completed(false)
        onCancelAdjustmentInteraction()
        val current = mutable.value
        if (current.photo != null) {
            onPersist(current.photo, current.edits) { saved ->
                if (saved.state == EditSaveState.FAILED) {
                    mutable.value = mutable.value.copy(saveState = saved.state, saveError = saved.message)
                    completed(false)
                } else {
                    startPhotoImport(uri)
                    completed(true)
                }
            }
        } else {
            startPhotoImport(uri)
            completed(true)
        }
    }

    fun clearX3fRecovery() {
        failedX3fImport?.let { if (it.ownsRetained) it.retained?.file?.delete() }
        failedX3fImport = null
        onReleaseDeferredCollectionCopies()
    }

    fun clearUnusableImportRecovery() {
        failedUnusableImport?.first?.discardOwnedInput()
        failedUnusableImport = null
        onReleaseDeferredCollectionCopies()
    }

    fun dismissUnusableImportRecovery() {
        clearUnusableImportRecovery()
        if (mutable.value.recoverUnusableRecord) {
            mutable.value = mutable.value.copy(recoverUnusableRecord = false)
        }
    }

    fun resetUnusableImportRecord() {
        val pending = failedUnusableImport ?: return
        if (isDisposed() || mutable.value.committingAdjustments || mutable.value.operation != Operation.NONE) return
        val (retry, identity) = pending
        onCommitAdjustments({
            runCatching { draftStore.clear(identity) }
            editStore.resetToUnmodified(identity)
        }) { result ->
            result.fold({
                if (failedUnusableImport?.first === retry) {
                    startPhotoImport(retry.uri, retry)
                }
            }, { error ->
                clearUnusableImportRecovery()
                val saveResult = EditSaveResult(EditSaveState.FAILED, error)
                val formatted = saveResult.formatMessage(strings)
                mutable.value = mutable.value.copy(
                    recoverUnusableRecord = false,
                    saveState = saveResult.state,
                    saveError = formatted,
                    error = formatted ?: formatFailure(error),
                )
            })
        }
    }

    fun retryX3fIfPresent(): Boolean {
        val pending = failedX3fImport ?: return false
        startPhotoImport(pending.uri, pending)
        return true
    }

    fun startPhotoImport(uri: Uri, retry: Work.Import? = null) {
        if (retry !== failedX3fImport) clearX3fRecovery()
        if (retry !== failedUnusableImport?.first) clearUnusableImportRecovery()
        onBeforeStartImport()
        pendingPhotoImport.begin(PhotoIdentity(uri.toString()))
        // A remains the displayed photo until B succeeds; its receipt belongs to that same state.
        // Successful import publishes B and B's receipt together in accept().
        mutable.value = mutable.value.copy(
            operation = Operation.IMPORT,
            exportStep = SingleExportStep.NONE,
            rendering = true,
            error = null,
            retryLegacyX3f = false,
            recoverUnusableRecord = false,
            hdrCameraDraft = null,
            previewResizePending = false,
        )
        // closeAdjustmentOperation 会释放延迟文件，先建立导入保护再移交恢复引用。
        failedX3fImport = null
        failedUnusableImport = null
        val retained = collectionPhoto(uri.toString())
        onSubmitImport(retry?.copy(gpuMode = gpuMode()) ?: Work.Import(uri, gpuMode(), retained))
    }

    fun handleX3fFailure(value: WorkResult.X3fImportFailure) {
        clearX3fRecovery()
        clearUnusableImportRecovery()
        failedX3fImport = value.retry
        pendingPhotoImport.clear()
        mutable.value = EditorStateReducer.renderFinished(mutable.value).copy(
            error = formatFailure(value.error),
            retryLegacyX3f = true,
            recoverUnusableRecord = false,
        )
    }

    fun handleUnusableFailure(value: WorkResult.UnusableEditImportFailure) {
        clearX3fRecovery()
        clearUnusableImportRecovery()
        failedUnusableImport = value.retry to value.identity
        pendingPhotoImport.clear()
        val message = if (value.error is HDRModeError.InvalidSettings)
            strings.text(R.string.hdr_unsupported)
        else EditSaveResult(EditSaveState.FAILED, value.error, reading = true).formatMessage(strings) ?: formatFailure(value.error)
        mutable.value = EditorStateReducer.renderFinished(mutable.value).copy(
            error = message,
            retryLegacyX3f = false,
            recoverUnusableRecord = true,
        )
    }

    fun handleMissingLook(value: WorkResult.MissingLook) {
        releasePreviousPhoto(value.photo)
        onAcceptHistorySource(value.photo, value.importedRecord)
        onCollectionOpened(value.photo.identity.value)
        mutable.value = EditorStateReducer.renderFinished(mutable.value).copy(
            photo = value.photo,
            edits = value.edits,
            preview = null,
            exact = false,
            saveState = EditSaveState.RESTORED,
            error = strings.text(R.string.look_unavailable),
            processingMigration = runCatching { editStore.processingMigration(value.photo.identity) }.getOrNull(),
        )
        onIncludeIndependentRecipeLook(value.edits)
        if (value.persistOnImport) onPersist(value.photo, value.edits) { saved ->
            mutable.value = mutable.value.copy(saveState = saved.state, saveError = saved.message)
        }
    }

    fun releasePreviousPhoto(next: ImportedPhoto) {
        val previous = mutable.value.photo ?: return
        if (previous.file != next.file && !collectionOwns(previous.file)) previous.file.delete()
    }

    fun clearAll() {
        clearX3fRecovery()
        clearUnusableImportRecovery()
    }
}
