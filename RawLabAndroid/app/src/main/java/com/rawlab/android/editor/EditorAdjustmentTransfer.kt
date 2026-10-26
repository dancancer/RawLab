package com.rawlab.android.editor

import android.content.Context
import android.net.Uri
import com.rawlab.android.R
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.settings.EditPersistenceConflict
import com.rawlab.android.adjustments.*
import com.rawlab.android.editor.storage.EditorEditStore
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.looks.MasterRecipe
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.PhotoIdentity
import java.io.IOException
import java.io.File
import java.util.UUID

data class EditorAdjustmentHistoryRequest(val transactionID: UUID, val photo: PhotoIdentity?, val undo: Boolean)
data class EditorAdjustmentTransferState(val preparing: Boolean = false, val prepared: PreparedAdjustmentTransfer? = null,
    val results: List<AdjustmentOutcome> = emptyList(), val historyRequest: EditorAdjustmentHistoryRequest? = null,
    val historyResults: List<AdjustmentOutcome> = emptyList(), val error: String? = null)
internal data class AdjustmentPreparationWork(val generation: UUID, val payload: AdjustmentPayload, val uris: List<Uri>,
    val currentPhoto: ImportedPhoto?, val isCurrent: (String) -> Boolean,
    val action: AdjustmentHistoryTransaction.Action = AdjustmentHistoryTransaction.Action.PASTE,
    val collectionPhotos: Map<String, ImportedPhoto> = emptyMap(), val validateCollection: ((String) -> Unit)? = null)
internal data class AdjustmentPreparationResult(val generation: UUID, val operation: PreparedAdjustmentTransfer, val ownedFiles: Map<String, File>)

/** 与普通渲染一样在串行资源队列执行；每个 native processor 在该目标预检结束时释放。 */
internal class EditorAdjustmentPreparation(private val context: Context, private val storage: PhotoStorage,
    private val store: EditorEditStore) {
    fun prepare(work: AdjustmentPreparationWork, isCancelled: () -> Boolean = { false }): AdjustmentPreparationResult = synchronized(storage) {
        fun checkActive() { if (isCancelled()) throw java.util.concurrent.CancellationException() }
        checkActive()
        val session = store.adjustmentSession ?: throw IOException("Edit store is unavailable; reload saved adjustments")
        val builtin = storage.builtinLookIDs()
        val available = builtin.keys.map { "builtin:$it" }.toSet() +
            storage.looks().filter { it.managed && it.available }.map { it.id } +
            MasterRecipe.load(context).map { "recipe:${it.id}" }
        val owned = mutableMapOf<String, File>()
        try {
            val targets = work.uris.distinct().map { uri ->
                checkActive()
                val identity = PhotoIdentity(uri.toString())
                var displayName = uri.lastPathSegment ?: identity.value
                try {
                    val photo = work.collectionPhotos[identity.value] ?: work.currentPhoto?.takeIf { it.identity == identity } ?: storage.import(uri).also { owned[identity.value] = it.file }
                    displayName = photo.name
                    val sourceValidator = EditorAdjustmentHistory.sourceValidation(photo)
                    work.validateCollection?.invoke(identity.value)
                    sourceValidator()
                    checkActive()
                    val validate = sourceValidator
                    val saved = store.versionedState(identity)
                    val neutral = EditSettings(processing = saved.settings?.processing ?: EditSettings().processing)
                    val database = storage.lensDatabase()
                    val frame = NativeProcessor(NativeProcessor.CPU, database).use {
                        it.preview(photo.file, null, neutral, 128, false, photo.inputKind)
                    }
                    checkActive()
                    val transferContext = AdjustmentTransferContext(identity.value, photo.inputKind == PhotoInputKind.RAW,
                        available, builtin, frame.temperature.takeIf { it.isFinite() }, frame.tint.takeIf { it.isFinite() },
                        validateLens = { request ->
                            checkActive()
                            val report = NativeProcessor(NativeProcessor.CPU, database).use {
                                it.preview(photo.file, null, neutral.copy(lens = request), 128, false, photo.inputKind).lens
                            }
                            checkActive()
                            if ((request.distortion && report?.appliedDistortion != true) || (request.tca && report?.appliedTca != true))
                                throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, "target lens calibration unavailable")
                        })
                    AdjustmentTransferTarget(identity, displayName, EditSettings(), transferContext,
                        isCurrent = { work.isCurrent(identity.value) }, validateSource = validate,
                        validateHistorySource = EditorAdjustmentHistory.historySourceValidation(photo))
                } catch (error: java.util.concurrent.CancellationException) { throw error }
                  catch (error: Exception) {
                    owned.remove(identity.value)?.delete()
                    AdjustmentTransferTarget(identity, displayName, EditSettings(), AdjustmentTransferContext(identity.value, true),
                        isCurrent = { work.isCurrent(identity.value) }, validateSource = { throw error })
                }
            }
            checkActive()
            val operation = session.prepare(work.payload, targets, work.action, ::checkActive)
            checkActive()
            AdjustmentPreparationResult(work.generation, operation, owned.toMap())
        } catch (error: Throwable) { owned.values.forEach(File::delete); throw error }
    }
}

internal fun adjustmentErrorMessage(error: Throwable?): String = AppStrings.text(when {
    error is EditPersistenceConflict -> R.string.transfer_conflict_message
    error is AdjustmentTransferException -> when (error.reason) {
        AdjustmentFailure.EMPTY_SCOPE -> R.string.transfer_empty_scope
        AdjustmentFailure.DRAFT -> R.string.transfer_draft_message
        AdjustmentFailure.MISSING_LOOK -> R.string.transfer_missing_look
        AdjustmentFailure.UNREPRESENTABLE -> R.string.transfer_unrepresentable
        AdjustmentFailure.INCOMPATIBLE -> R.string.transfer_incompatible
        AdjustmentFailure.INVALID_PAYLOAD, AdjustmentFailure.UNSUPPORTED_VERSION -> R.string.transfer_invalid_payload
    }
    else -> R.string.transfer_error
})
