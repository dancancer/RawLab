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
    private var interaction: Interaction? = null
    val interacting get() = interaction != null
    var reloadRequired = false
        private set

    fun acceptSource(photo: ImportedPhoto, record: VersionedPhotoEdit?) {
        loaded = record
        sourcePath = photo.file.absolutePath
        interaction = null
        reloadRequired = false
        validator = try { sourceValidation(photo) } catch (error: Exception) { { throw error } }
        validator?.let { session?.refreshSource(photo.identity, it) }
    }
    fun acceptSaved(photo: ImportedPhoto, saved: VersionedPhotoEdit): Boolean {
        if (saved.identity != photo.identity || interacting) return false
        try {
            if (store.versionedState(photo.identity) != saved) throw EditPersistenceConflict()
        } catch (error: Exception) { reloadRequired = true; throw error }
        loaded = saved
        sourcePath = photo.file.absolutePath
        reloadRequired = false
        return true
    }
    fun begin(photo: ImportedPhoto, settings: EditSettings, revision: Long): EditSaveResult {
        if (interacting) return EditSaveResult(EditSaveState.SAVED)
        val saved = commit(photo, settings)
        if (saved.state != EditSaveState.FAILED) interaction = Interaction(photo.identity, photo.file.absolutePath, revision, settings)
        return saved
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
        val defaults = if (AdjustmentTransfer.sameAdjustments(settings, EditSettings(), raw)) settings else EditSettings()
        val result = currentSession.commitEdit(expected, candidate, photo.name, defaults, validateSource = validator)
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
        validator?.let { session?.refreshSource(photo.identity, it) }
        return record.settings ?: EditSettings()
    }
    companion object {
        private data class SourceStamp(val inode: Long, val length: Long, val modified: Long)
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
