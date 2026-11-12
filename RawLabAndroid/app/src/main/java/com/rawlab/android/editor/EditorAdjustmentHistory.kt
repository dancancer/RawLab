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
import java.util.concurrent.atomic.AtomicReference

internal class EditorAdjustmentHistory(
    private val store: EditorEditStore,
    private val validateSource: (ImportedPhoto) -> () -> Unit = Companion::sourceValidation,
) {
    private data class Interaction(val identity: PhotoIdentity, val path: String, val revision: Long, val before: EditSettings)
    private data class Snapshot(
        val sourceToken: Long = 0L,
        val loaded: PhotoEditState? = null,
        val sourcePath: String? = null,
        val validator: (() -> Unit)? = null,
        val interaction: Interaction? = null,
    )

    private val state = AtomicReference(Snapshot())
    val session get() = store.adjustmentSession
    val loaded: PhotoEditState? get() = state.get().loaded
    val interacting: Boolean get() = state.get().interaction != null

    fun acceptSource(photo: ImportedPhoto, record: PhotoEditState?) {
        val path = photo.file.absolutePath
        val nextValidator = try { validateSource(photo) } catch (error: Exception) { { throw error } }
        while (true) {
            val current = state.get()
            val next = Snapshot(
                sourceToken = current.sourceToken + 1L,
                loaded = record,
                sourcePath = path,
                validator = nextValidator,
                interaction = null,
            )
            if (state.compareAndSet(current, next)) break
        }
        session?.refreshSource(photo.identity, historySourceValidation(photo))
    }
    fun acceptSaved(photo: ImportedPhoto, saved: PhotoEditState): Boolean {
        if (saved.identity != photo.identity) return false
        val path = photo.file.absolutePath
        while (true) {
            val current = state.get()
            if (current.interaction != null || session?.isCurrentSave(saved) == false) return false
            if (current.sourcePath != null && current.sourcePath != path) return false
            if (current.loaded != null && current.loaded.identity != photo.identity) return false
            if (state.compareAndSet(current, current.copy(loaded = saved, sourcePath = path))) return true
        }
    }
    fun committedValidation(photo: ImportedPhoto, settings: EditSettings): () -> Unit {
        val current = state.get()
        val expected = current.loaded ?: throw AdjustmentNotReadyException()
        check(current.interaction == null) { "Apply, discard or skip this photo's draft" }
        if (expected.identity != photo.identity || current.sourcePath != photo.file.absolutePath) throw PhotoChangedException()
        val validate = current.validator
        return {
            validate?.invoke()
            if (!AdjustmentTransfer.sameAdjustments(expected.settings ?: sourceDefaults(photo, expected), settings,
                    photo.inputKind == PhotoInputKind.RAW)) throw AdjustmentTransferException(AdjustmentFailure.DRAFT)
        }
    }
    fun validateCommitted(photo: ImportedPhoto, settings: EditSettings) {
        val current = state.get()
        val expected = current.loaded ?: throw AdjustmentNotReadyException()
        if (current.interaction != null || expected.identity != photo.identity || current.sourcePath != photo.file.absolutePath)
            throw PhotoChangedException()
        current.validator?.invoke()
        if (!AdjustmentTransfer.sameAdjustments(expected.settings ?: sourceDefaults(photo, expected), settings,
                photo.inputKind == PhotoInputKind.RAW)) throw AdjustmentTransferException(AdjustmentFailure.DRAFT)
    }
    fun begin(photo: ImportedPhoto, settings: EditSettings, revision: Long): EditSaveResult {
        val path = photo.file.absolutePath
        while (true) {
            val current = state.get()
            if (current.interaction != null) return EditSaveResult(EditSaveState.SAVED)
            val expected = current.loaded
                ?: return EditSaveResult(EditSaveState.FAILED, AdjustmentNotReadyException(), reading = true)
            if (expected.identity != photo.identity || current.sourcePath != path)
                return EditSaveResult(EditSaveState.FAILED, PhotoChangedException())
            val next = current.copy(interaction = Interaction(photo.identity, path, revision, settings))
            if (state.compareAndSet(current, next)) return EditSaveResult(EditSaveState.SAVED)
        }
    }

    fun finish(photo: ImportedPhoto, revision: Long): Boolean {
        val path = photo.file.absolutePath
        while (true) {
            val current = state.get()
            val previous = current.interaction ?: return true
            if (state.compareAndSet(current, current.copy(interaction = null))) {
                return previous.identity == photo.identity && previous.path == path && previous.revision == revision
            }
        }
    }
    fun cancel(photo: ImportedPhoto?, revision: Long): EditSettings? {
        val path = photo?.file?.absolutePath
        while (true) {
            val current = state.get()
            val previous = current.interaction
            if (previous == null || state.compareAndSet(current, current.copy(interaction = null))) {
                if (photo == null) return null
                return previous?.takeIf { it.identity == photo.identity && it.path == path && it.revision == revision }?.before
            }
        }
    }
    fun recoverSource(photo: ImportedPhoto): PhotoEditState {
        val baseline = state.get()
        val path = photo.file.absolutePath
        if ((baseline.sourcePath != null && baseline.sourcePath != path) ||
            (baseline.loaded != null && baseline.loaded.identity != photo.identity)) {
            throw PhotoChangedException()
        }
        baseline.validator?.invoke()
        if (!store.available) {
            val opened = store.reopen()
            if (opened.state == EditSaveState.FAILED) throw opened.error ?: IOException("Edit store is unavailable")
        }
        val record = store.readState(photo.identity)
        val nextValidator = try { validateSource(photo) } catch (error: Exception) { { throw error } }
        while (true) {
            val current = state.get()
            if (current.sourceToken != baseline.sourceToken) throw PhotoChangedException()
            val next = Snapshot(
                sourceToken = current.sourceToken + 1L,
                loaded = record,
                sourcePath = path,
                validator = nextValidator,
                interaction = null,
            )
            if (state.compareAndSet(current, next)) break
        }
        session?.refreshSource(photo.identity, historySourceValidation(photo))
        return record
    }
    fun commit(photo: ImportedPhoto, settings: EditSettings, clearProcessingMigration: Boolean = false): EditSaveResult {
        val baseline = state.get()
        if (baseline.interaction != null) return EditSaveResult(EditSaveState.FAILED, IOException("Finish or cancel the active adjustment"))
        val expected = baseline.loaded
        val currentSession = session
        if (expected == null || currentSession == null)
            return EditSaveResult(EditSaveState.FAILED, AdjustmentNotReadyException(), reading = true)
        val path = photo.file.absolutePath
        if (expected.identity != photo.identity || baseline.sourcePath != path)
            return EditSaveResult(EditSaveState.FAILED, PhotoChangedException())
        val raw = photo.inputKind == PhotoInputKind.RAW
        val candidate = expected.settings?.takeIf { AdjustmentTransfer.sameAdjustments(it, settings, raw) } ?: settings
        val sourceDefault = sourceDefaults(photo, expected)
        val defaults = if (AdjustmentTransfer.sameAdjustments(settings, sourceDefault, raw)) settings else sourceDefault
        val result = currentSession.commitEdit(expected, candidate, photo.name, defaults,
            validateSource = baseline.validator, validateHistorySource = historySourceValidation(photo),
            clearProcessingMigration = clearProcessingMigration)
        if (result.saved != null) {
            while (true) {
                val current = state.get()
                if (current.sourceToken != baseline.sourceToken || !currentSession.isCurrentSave(result.saved)) break
                if (state.compareAndSet(current, current.copy(loaded = result.saved))) break
            }
            return EditSaveResult(EditSaveState.SAVED)
        }
        return EditSaveResult(EditSaveState.FAILED, result.error ?: IOException("Could not save adjustments"))
    }

    companion object {
        private fun sourceDefaults(photo: ImportedPhoto, record: PhotoEditState) = record.settings ?: photo.defaultEditSettings()
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
            return { if (stamp() != original) throw PhotoChangedException() }
        }
    }
}
