package com.rawlab.android.editor.storage

import com.rawlab.android.R
import com.rawlab.android.editor.EditSaveState
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.PhotoIdentity
import java.io.File

internal data class EditSaveResult(val state: EditSaveState, val error: Throwable? = null, val reading: Boolean = false) {
    val detail: String? get() = error?.let { it.message?.takeIf(String::isNotBlank) ?: it.javaClass.simpleName }
    val message: String? get() = error?.let {
        AppStrings.format(if (reading) R.string.edit_read_error else R.string.edit_unsaved_detail,
            detail.orEmpty())
    }
}

internal class EditorEditStore(private val directory: File) {
    private var store: EditStore? = null
    val initialResult = reopen()
    val available get() = store != null

    fun reopen(): EditSaveResult = try {
        store = EditStore(directory)
        EditSaveResult(EditSaveState.NONE)
    } catch (error: Throwable) { EditSaveResult(EditSaveState.FAILED, error, reading = true) }

    fun load(identity: PhotoIdentity): EditSettings? = store?.load(identity)

    fun save(identity: PhotoIdentity, settings: EditSettings): EditSaveResult = try {
        if (store == null) store = EditStore(directory)
        store!!.save(identity, settings)
        EditSaveResult(EditSaveState.SAVED)
    } catch (error: Throwable) { EditSaveResult(EditSaveState.FAILED, error) }
}
