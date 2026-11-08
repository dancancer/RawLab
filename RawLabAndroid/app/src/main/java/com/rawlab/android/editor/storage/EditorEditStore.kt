package com.rawlab.android.editor.storage

import com.rawlab.android.R
import com.rawlab.android.editor.EditSaveState
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.settings.PhotoEditState
import com.rawlab.android.settings.PhotoChangedException
import com.rawlab.android.settings.AdjustmentOperationExpiredException
import com.rawlab.android.settings.AdjustmentHistoryOrderException
import com.rawlab.android.settings.AdjustmentNotReadyException
import com.rawlab.android.adjustments.AdjustmentTransferSession
import java.io.File
import java.io.IOException

internal data class EditSaveResult(val state: EditSaveState, val error: Throwable? = null, val reading: Boolean = false) {
    val detail: String? get() = error?.let { it.message?.takeIf(String::isNotBlank) ?: it.javaClass.simpleName }
    val message: String? get() = error?.let {
        val dedicated = when (it) {
            is PhotoChangedException -> R.string.collection_source_changed
            is AdjustmentOperationExpiredException -> R.string.transfer_conflict_message
            is AdjustmentHistoryOrderException -> R.string.transfer_history_order_message
            is AdjustmentNotReadyException -> R.string.transfer_draft_message
            else -> null
        }
        dedicated?.let(AppStrings::text) ?: AppStrings.format(if (reading) R.string.edit_read_error else R.string.edit_unsaved_detail,
            detail.orEmpty())
    }
}

internal class EditorEditStore(private val directory: File, private val createStore: (File) -> EditStore = { EditStore(it) }) {
    private var store: EditStore? = null
    var adjustmentSession: AdjustmentTransferSession? = null
        private set
    val initialResult = reopen()
    val available get() = store != null

    fun reopen(): EditSaveResult = try {
        store = createStore(directory)
        adjustmentSession = AdjustmentTransferSession(store!!)
        EditSaveResult(EditSaveState.NONE)
    } catch (error: Throwable) { EditSaveResult(EditSaveState.FAILED, error, reading = true) }

    fun load(identity: PhotoIdentity): EditSettings? = store?.load(identity)
    fun readState(identity: PhotoIdentity): PhotoEditState =
        (store ?: throw IOException("Edit store is unavailable")).readState(identity)

    fun save(identity: PhotoIdentity, settings: EditSettings): EditSaveResult = try {
        if (store == null) {
            store = createStore(directory)
            adjustmentSession = AdjustmentTransferSession(store!!)
        }
        store!!.save(identity, settings)
        EditSaveResult(EditSaveState.SAVED)
    } catch (error: Throwable) { EditSaveResult(EditSaveState.FAILED, error) }
}
