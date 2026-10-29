package com.rawlab.android.editor

import android.system.Os
import com.rawlab.android.adjustments.*
import com.rawlab.android.editor.storage.EditSaveResult
import com.rawlab.android.editor.storage.EditorEditStore
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.*
import java.io.File
import java.io.IOException

internal class EditorAdjustmentHistory(private val store: EditorEditStore) {
    val session get() = store.adjustmentSession
    var loaded: VersionedPhotoEdit? = null
        private set
    private var sourcePath: String? = null
    private var validator: (() -> Unit)? = null
    private data class Interaction(val identity: PhotoIdentity, val path: String, val revision: Long, val before: EditSettings)
    @Volatile private var interaction: Interaction? = null
    val interacting get() = interaction != null
    @Volatile var reloadRequired = false
        private set

    fun acceptSource(photo: ImportedPhoto, record: VersionedPhotoEdit?) {
        loaded = record
        sourcePath = photo.file.absolutePath
        interaction = null
        reloadRequired = false
        validator = try { sourceValidation(photo) } catch (error: Exception) { { throw error } }
        session?.refreshSource(photo.identity, historySourceValidation(photo))
    }
    fun acceptSaved(photo: ImportedPhoto, saved: VersionedPhotoEdit, receiptVerified: Boolean = false): Boolean {
        if (saved.identity != photo.identity || interacting) return false
        try {
            if (!receiptVerified && store.versionedState(photo.identity) != saved) throw EditPersistenceConflict()
        } catch (error: Exception) { reloadRequired = true; throw error }
        loaded = saved
        sourcePath = photo.file.absolutePath
        reloadRequired = false
        return true
    }
    fun committedValidation(photo: ImportedPhoto, settings: EditSettings): () -> Unit {
        val expected = loaded ?: throw EditPersistenceConflict()
        check(!interacting && expected.identity == photo.identity && sourcePath == photo.file.absolutePath) { "Apply, discard or skip this photo's draft" }
        val validate = validator
        return {
            if (store.versionedState(photo.identity) != expected) throw EditPersistenceConflict()
            validate?.invoke()
            if (!AdjustmentTransfer.sameAdjustments(expected.settings ?: sourceDefaults(photo, expected), settings, photo.inputKind == PhotoInputKind.RAW))
                throw AdjustmentTransferException(AdjustmentFailure.DRAFT)
        }
    }
    fun validateCommitted(photo: ImportedPhoto, settings: EditSettings) {
        val expected = loaded ?: throw EditPersistenceConflict()
        try {
            if (interacting || expected.identity != photo.identity || sourcePath != photo.file.absolutePath ||
                store.versionedState(photo.identity) != expected) throw EditPersistenceConflict()
            validator?.invoke()
            if (!AdjustmentTransfer.sameAdjustments(expected.settings ?: sourceDefaults(photo, expected), settings, photo.inputKind == PhotoInputKind.RAW))
                throw AdjustmentTransferException(AdjustmentFailure.DRAFT)
        } catch (error: Exception) { reloadRequired = error is EditPersistenceConflict; throw error }
    }
    fun begin(photo: ImportedPhoto, settings: EditSettings, revision: Long): EditSaveResult {
        if (interacting) return EditSaveResult(EditSaveState.SAVED)
        val expected = loaded
        if (expected == null || expected.identity != photo.identity || sourcePath != photo.file.absolutePath ||
            !AdjustmentTransfer.sameAdjustments(expected.settings ?: sourceDefaults(photo, expected), settings, photo.inputKind == PhotoInputKind.RAW))
            return EditSaveResult(EditSaveState.FAILED, IOException("Reload saved adjustments before editing"))
        interaction = Interaction(photo.identity, photo.file.absolutePath, revision, settings)
        return EditSaveResult(EditSaveState.SAVED)
    }

    fun finish(photo: ImportedPhoto, revision: Long): Boolean {
        val previous = interaction ?: return true
        interaction = null
        return previous.identity == photo.identity && previous.path == photo.file.absolutePath && previous.revision == revision
    }
    fun cancel(photo: ImportedPhoto?, revision: Long): EditSettings? {
        val previous = interaction
        interaction = null
        if (photo == null) return null
        return previous?.takeIf { it.identity == photo.identity && it.path == photo.file.absolutePath && it.revision == revision }?.before
    }
    fun commit(photo: ImportedPhoto, settings: EditSettings): EditSaveResult {
        if (interacting) return EditSaveResult(EditSaveState.FAILED, IOException("Finish or cancel the active adjustment"))
        val expected = loaded
        val currentSession = session
        if (expected == null || currentSession == null || expected.identity != photo.identity || sourcePath != photo.file.absolutePath) {
            reloadRequired = true
            return EditSaveResult(EditSaveState.FAILED, IOException("Reload saved adjustments before editing"))
        }
        val raw = photo.inputKind == PhotoInputKind.RAW
        val candidate = expected.settings?.takeIf { AdjustmentTransfer.sameAdjustments(it, settings, raw) } ?: settings
        val sourceDefault = sourceDefaults(photo, expected)
        val defaults = if (AdjustmentTransfer.sameAdjustments(settings, sourceDefault, raw)) settings else sourceDefault
        val result = currentSession.commitEdit(expected, candidate, photo.name, defaults, validateSource = validator, validateHistorySource = historySourceValidation(photo))
        if (result.saved != null) {
            loaded = result.saved
            reloadRequired = false
            return EditSaveResult(EditSaveState.SAVED)
        }
        reloadRequired = result.status == AdjustmentStatus.CONFLICT
        return EditSaveResult(EditSaveState.FAILED, result.error ?: IOException("Could not save adjustments"))
    }
    fun reload(photo: ImportedPhoto): EditSettings {
        if (!store.available) {
            val reopened = store.reopen()
            reopened.error?.let { throw it }
        }
        validator?.invoke()
        val record = store.versionedState(photo.identity)
        loaded = record
        interaction = null
        sourcePath = photo.file.absolutePath
        reloadRequired = false
        if (validator == null) validator = sourceValidation(photo)
        session?.refreshSource(photo.identity, historySourceValidation(photo))
        return record.settings ?: sourceDefaults(photo, record)
    }
    companion object {
        private fun sourceDefaults(photo: ImportedPhoto, record: VersionedPhotoEdit) =
            com.rawlab.android.settings.sourceDefaultSettings(photo.isHDRSource)
        private data class SourceStamp(val inode: Long, val length: Long, val modified: Long)
        fun historySourceValidation(photo: ImportedPhoto): () -> Unit = photo.validateOriginal ?: sourceValidation(photo.file)
        fun sourceValidation(photo: ImportedPhoto): () -> Unit {
            val copy = sourceValidation(photo.file)
            return { photo.validateOriginal?.invoke(); copy() }
        }
        fun sourceValidation(file: File): () -> Unit {
            fun stamp(): SourceStamp {
                val stat = Os.stat(file.absolutePath)
                if (!file.isFile || !file.canRead()) throw IOException("Photo source is unavailable")
                return SourceStamp(stat.st_ino, stat.st_size, file.lastModified())
            }
            val original = stamp()
            return { if (stamp() != original) throw EditPersistenceConflict() }
        }
    }
}
