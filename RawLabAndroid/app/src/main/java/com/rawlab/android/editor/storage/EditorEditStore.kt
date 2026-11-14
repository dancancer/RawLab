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
import java.util.concurrent.atomic.AtomicReference

internal data class EditSaveResult(val state: EditSaveState, val error: Throwable? = null, val reading: Boolean = false) {
    val detail: String? get() = error?.let { it.message?.takeIf(String::isNotBlank) ?: it.javaClass.simpleName }
    val message: String? get() = error?.let {
        val dedicated = when (it) {
            is PhotoChangedException -> R.string.collection_source_changed
            is AdjustmentOperationExpiredException -> R.string.transfer_conflict_message
            is AdjustmentHistoryOrderException -> R.string.transfer_history_order_message
            is AdjustmentNotReadyException -> if (reading) R.string.edit_store_unavailable else R.string.transfer_draft_message
            else -> null
        }
        dedicated?.let(AppStrings::text) ?: AppStrings.format(if (reading) R.string.edit_read_error else R.string.edit_unsaved_detail,
            detail.orEmpty())
    }
}

internal class EditorEditStore(private val directory: File, private val createStore: (File) -> EditStore = { EditStore(it) }) {
    /**
     * 不可变配对快照（A-N1）：`store` 与 `adjustmentSession` 只随快照成对重建，整对原子替换。
     * 读者单次观测（一次 handles.get()）要么是旧配对、要么是新配对，不存在 (新 store, 旧 session)
     * 或 available 而 session 为 null 的跨字段撕裂；跨方法的两次观测允许跨越一次 reopen，与旧实现一致。
     */
    private data class Handles(val store: EditStore?, val adjustmentSession: AdjustmentTransferSession?)

    private val handles = AtomicReference(Handles(null, null))
    private val store: EditStore? get() = handles.get().store
    val adjustmentSession: AdjustmentTransferSession? get() = handles.get().adjustmentSession
    val initialResult = reopen()
    val available get() = store != null

    private fun rebuild(): Handles =
        createStore(directory).let { Handles(it, AdjustmentTransferSession(it)) }.also(handles::set)

    fun reopen(): EditSaveResult = try {
        rebuild()
        EditSaveResult(EditSaveState.NONE)
    } catch (error: Throwable) { EditSaveResult(EditSaveState.FAILED, error, reading = true) }

    fun load(identity: PhotoIdentity): EditSettings? = store?.load(identity)
    fun readState(identity: PhotoIdentity): PhotoEditState =
        (store ?: throw IOException("Edit store is unavailable")).readState(identity)

    fun processingMigration(identity: PhotoIdentity) =
        (store ?: throw IOException("Edit store is unavailable")).processingMigration(identity)

    fun commitProcessingMigration(expected: PhotoEditState, candidate: EditSettings?,
        quality: com.rawlab.android.settings.ProcessingMigrationQuality): PhotoEditState =
        (store ?: throw IOException("Edit store is unavailable")).commitProcessingMigration(expected, candidate, quality)

    fun rollbackProcessingMigration(expected: PhotoEditState): PhotoEditState =
        (store ?: throw IOException("Edit store is unavailable")).rollbackProcessingMigration(expected)

    fun resetToUnmodified(identity: PhotoIdentity): PhotoEditState {
        var current = handles.get()
        if (current.store == null) current = rebuild()
        return checkNotNull(current.adjustmentSession).resetToUnmodified(identity)
    }

    fun save(identity: PhotoIdentity, settings: EditSettings): EditSaveResult = try {
        var current = handles.get()
        if (current.store == null) current = rebuild()
        checkNotNull(current.store).save(identity, settings)
        EditSaveResult(EditSaveState.SAVED)
    } catch (error: Throwable) { EditSaveResult(EditSaveState.FAILED, error) }
}
