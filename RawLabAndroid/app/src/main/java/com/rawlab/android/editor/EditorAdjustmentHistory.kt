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
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

internal class EditorAdjustmentHistory(
    private val store: EditorEditStore,
    private val validateSource: (ImportedPhoto) -> () -> Unit = Companion::sourceValidation,
) {
    internal data class Interaction(val identity: PhotoIdentity, val path: String, val revision: Long, val before: EditSettings)

    class Snapshot internal constructor(
        val sourceToken: Long = 0L,
        val loaded: PhotoEditState? = null,
        internal val sourceIdentity: PhotoIdentity? = null,
        internal val sourcePath: String? = null,
        internal val validator: (() -> Unit)? = null,
        internal val interaction: Interaction? = null,
    ) {
        val interacting: Boolean get() = interaction != null

        fun committedValidation(photo: ImportedPhoto, settings: EditSettings): () -> Unit {
            val expected = loaded ?: throw AdjustmentNotReadyException()
            check(interaction == null) { "Apply, discard or skip this photo's draft" }
            if (expected.identity != photo.identity || sourcePath != photo.file.absolutePath) throw PhotoChangedException()
            val validate = validator
            return {
                validate?.invoke()
                if (!AdjustmentTransfer.sameAdjustments(expected.settings ?: sourceDefaults(photo, expected), settings,
                        photo.inputKind == PhotoInputKind.RAW)) throw AdjustmentTransferException(AdjustmentFailure.DRAFT)
            }
        }

        fun validateCommitted(photo: ImportedPhoto, settings: EditSettings) {
            val expected = loaded ?: throw AdjustmentNotReadyException()
            if (interaction != null || expected.identity != photo.identity || sourcePath != photo.file.absolutePath)
                throw PhotoChangedException()
            validator?.invoke()
            if (!AdjustmentTransfer.sameAdjustments(expected.settings ?: sourceDefaults(photo, expected), settings,
                    photo.inputKind == PhotoInputKind.RAW)) throw AdjustmentTransferException(AdjustmentFailure.DRAFT)
        }

        internal fun canAcceptSaved(photo: ImportedPhoto, path: String, expectedSourceToken: Long): Boolean =
            expectedSourceToken > 0L &&
                sourceToken == expectedSourceToken &&
                interaction == null &&
                loaded?.identity == photo.identity &&
                sourceIdentity == photo.identity &&
                sourcePath == path &&
                validator != null

        internal fun matchesSource(photo: ImportedPhoto, path: String): Boolean =
            (sourceIdentity == null || sourceIdentity == photo.identity) &&
                (sourcePath == null || sourcePath == path) &&
                (loaded == null || loaded.identity == photo.identity)

        internal fun withLoaded(saved: PhotoEditState) = Snapshot(
            sourceToken = sourceToken,
            loaded = saved,
            sourceIdentity = sourceIdentity,
            sourcePath = sourcePath,
            validator = validator,
            interaction = interaction,
        )

        internal fun withInteraction(next: Interaction?) = Snapshot(
            sourceToken = sourceToken,
            loaded = loaded,
            sourceIdentity = sourceIdentity,
            sourcePath = sourcePath,
            validator = validator,
            interaction = next,
        )
    }

    private val sourceTokens = AtomicLong(0L)
    private val state = AtomicReference(Snapshot())
    val session get() = store.adjustmentSession
    fun snapshot(): Snapshot = state.get()

    fun acceptSource(photo: ImportedPhoto, record: PhotoEditState?) {
        val token = sourceTokens.incrementAndGet()
        val path = photo.file.absolutePath
        val nextValidator = try { validateSource(photo) } catch (error: Exception) { { throw error } }
        var published = false
        while (true) {
            val current = state.get()
            if (current.sourceToken >= token) break
            val next = Snapshot(
                sourceToken = token,
                loaded = record,
                sourceIdentity = photo.identity,
                sourcePath = path,
                validator = nextValidator,
                interaction = null,
            )
            if (state.compareAndSet(current, next)) {
                published = true
                break
            }
        }
        if (published) {
            session?.refreshSource(photo.identity, historySourceValidation(photo), record) {
                state.get().sourceToken == token
            }
        }
    }

    fun acceptSaved(photo: ImportedPhoto, saved: PhotoEditState, expectedSourceToken: Long): Boolean {
        if (expectedSourceToken <= 0L || saved.identity != photo.identity) return false
        val path = photo.file.absolutePath
        while (true) {
            val current = state.get()
            if (!current.canAcceptSaved(photo, path, expectedSourceToken) || session?.isCurrentSave(saved) == false) {
                return false
            }
            if (state.compareAndSet(current, current.withLoaded(saved))) return true
        }
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
            val next = current.withInteraction(Interaction(photo.identity, path, revision, settings))
            if (state.compareAndSet(current, next)) return EditSaveResult(EditSaveState.SAVED)
        }
    }

    fun finish(photo: ImportedPhoto, revision: Long): Boolean {
        val path = photo.file.absolutePath
        while (true) {
            val current = state.get()
            val previous = current.interaction ?: return true
            if (state.compareAndSet(current, current.withInteraction(null))) {
                return previous.identity == photo.identity && previous.path == path && previous.revision == revision
            }
        }
    }

    fun cancel(photo: ImportedPhoto?, revision: Long): EditSettings? {
        val path = photo?.file?.absolutePath
        while (true) {
            val current = state.get()
            val previous = current.interaction
            if (previous == null || state.compareAndSet(current, current.withInteraction(null))) {
                if (photo == null) return null
                return previous?.takeIf { it.identity == photo.identity && it.path == path && it.revision == revision }?.before
            }
        }
    }

    fun recoverSource(photo: ImportedPhoto): PhotoEditState {
        val baseline = state.get()
        val path = photo.file.absolutePath
        if (!baseline.matchesSource(photo, path) || sourceTokens.get() != baseline.sourceToken) {
            throw PhotoChangedException()
        }
        baseline.validator?.invoke()
        if (!store.available) {
            val opened = store.reopen()
            if (opened.state == EditSaveState.FAILED) throw opened.error ?: IOException("Edit store is unavailable")
        }
        val record = store.readState(photo.identity)
        val nextValidator = try { validateSource(photo) } catch (error: Exception) { { throw error } }
        val token = baseline.sourceToken + 1L
        if (!sourceTokens.compareAndSet(baseline.sourceToken, token)) throw PhotoChangedException()
        while (true) {
            val current = state.get()
            if (current.sourceToken != baseline.sourceToken) throw PhotoChangedException()
            val next = Snapshot(
                sourceToken = token,
                loaded = record,
                sourceIdentity = photo.identity,
                sourcePath = path,
                validator = nextValidator,
                interaction = null,
            )
            if (state.compareAndSet(current, next)) break
        }
        session?.refreshSource(photo.identity, historySourceValidation(photo), record) {
            state.get().sourceToken == token
        }
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
        val result = currentSession.commitEdit(
            expected,
            candidate,
            photo.name,
            defaults,
            validateSource = {
                if (state.get().sourceToken != baseline.sourceToken) throw PhotoChangedException()
                baseline.validator?.invoke()
                if (state.get().sourceToken != baseline.sourceToken) throw PhotoChangedException()
            },
            validateHistorySource = historySourceValidation(photo),
            clearProcessingMigration = clearProcessingMigration,
            acceptCommit = { saved -> publishCommitted(baseline.sourceToken, saved) },
        )
        if (result.saved != null) return EditSaveResult(EditSaveState.SAVED)
        return EditSaveResult(EditSaveState.FAILED, result.error ?: IOException("Could not save adjustments"))
    }

    private fun publishCommitted(expectedSourceToken: Long, saved: PhotoEditState): Boolean {
        while (true) {
            val current = state.get()
            if (current.sourceToken != expectedSourceToken) return false
            if (state.compareAndSet(current, current.withLoaded(saved))) return true
        }
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
