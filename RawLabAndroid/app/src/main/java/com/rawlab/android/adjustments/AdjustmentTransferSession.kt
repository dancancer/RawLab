package com.rawlab.android.adjustments

import com.rawlab.android.settings.*
import java.util.UUID

data class AdjustmentTransferTarget(val identity: PhotoIdentity, val displayName: String,
    val defaultSettings: EditSettings, val context: AdjustmentTransferContext,
    val isCurrent: () -> Boolean = { true }, val validateSource: (() -> Unit)? = null)
enum class AdjustmentStatus { APPLIED, UNCHANGED, SKIPPED, BLOCKED, CONFLICT, FAILED }
data class AdjustmentOutcome(val targetID: String, val status: AdjustmentStatus,
    val saved: VersionedPhotoEdit? = null, val error: Throwable? = null, val requiresHistoryDecision: Boolean = false)
data class PreparedAdjustmentTransfer(val id: UUID, val payload: AdjustmentPayload, val targets: List<Target>,
    val action: AdjustmentHistoryTransaction.Action = AdjustmentHistoryTransaction.Action.PASTE) {
    data class Target(val id: String, val displayName: String, val original: VersionedPhotoEdit?, val candidate: EditSettings?,
        val unchanged: Boolean, val isCurrent: () -> Boolean, val validateSource: (() -> Unit)?, val error: Throwable?)
}
data class AdjustmentHistoryTransaction(val id: UUID, val action: Action, val fields: Set<AdjustmentField>, val parts: List<Part>) {
    enum class Action { PASTE, EDIT, PRESET }
    enum class State { APPLIED, UNDONE, REDO_INVALIDATED }
    data class Part(val id: UUID, val priorHead: UUID?, val identity: PhotoIdentity, val displayName: String,
        val before: EditSettings?, val after: EditSettings?, val state: State)
}

/** prepare 只读，可在资源队列执行；提交、复制和历史由编辑器主线程串行拥有。 */
class AdjustmentTransferSession(private val store: EditStore) {
    private val outcomes = mutableMapOf<UUID, MutableMap<String, AdjustmentOutcome>>()
    private val knownRecords = mutableMapOf<String, VersionedPhotoEdit>()
    private val historyHeads = mutableMapOf<String, UUID?>()
    private val sourceValidators = mutableMapOf<String, () -> Unit>()
    private val history = mutableListOf<AdjustmentHistoryTransaction>()
    val transactions: List<AdjustmentHistoryTransaction> get() = history.toList()
    var clipboard: AdjustmentPayload? = null
        private set

    fun refreshSource(identity: PhotoIdentity, validate: () -> Unit) {
        if (identity.value in knownRecords) sourceValidators[identity.value] = validate
    }
    fun retainsSource(identity: PhotoIdentity) = identity.value in knownRecords
    fun copy(scope: AdjustmentScope, settings: EditSettings, context: AdjustmentTransferContext): AdjustmentPayload {
        val captured = AdjustmentTransfer.capture(scope, settings, context)
        clipboard = captured
        return captured
    }
    fun prepare(payload: AdjustmentPayload, targets: List<AdjustmentTransferTarget>,
        action: AdjustmentHistoryTransaction.Action = AdjustmentHistoryTransaction.Action.PASTE): PreparedAdjustmentTransfer {
        payload.validate()
        val prepared = targets.distinctBy { it.identity }.map { target ->
            try {
                if (!target.isCurrent()) throw draftError()
                target.validateSource?.invoke()
                val original = store.versionedState(target.identity)
                val before = original.settings ?: target.defaultSettings
                val candidate = AdjustmentTransfer.prepare(payload, before, target.context)
                PreparedAdjustmentTransfer.Target(target.identity.value, target.displayName, original, candidate,
                    candidate == before, target.isCurrent, target.validateSource, null)
            } catch (error: Exception) {
                PreparedAdjustmentTransfer.Target(target.identity.value, target.displayName, null, null,
                    false, target.isCurrent, target.validateSource, error)
            }
        }
        return PreparedAdjustmentTransfer(UUID.randomUUID(), payload, prepared, action)
    }
    fun apply(operation: PreparedAdjustmentTransfer, skipping: Set<String> = emptySet()): List<AdjustmentOutcome> {
        if (operation.targets.any { it.error != null && it.id !in skipping }) return operation.targets.map {
            AdjustmentOutcome(it.id, AdjustmentStatus.BLOCKED, error = it.error ?: unresolved("target preflight"))
        }
        return operation.targets.map { target ->
            val cached = outcomes[operation.id]?.get(target.id)
            if (cached?.status in setOf(AdjustmentStatus.APPLIED, AdjustmentStatus.UNCHANGED, AdjustmentStatus.SKIPPED)) return@map cached!!
            val result = when {
                target.id in skipping -> AdjustmentOutcome(target.id, AdjustmentStatus.SKIPPED)
                !target.isCurrent() -> AdjustmentOutcome(target.id, AdjustmentStatus.BLOCKED, error = draftError())
                target.original != null && target.candidate != null -> try {
                    target.validateSource?.invoke()
                    if (store.versionedState(target.original.identity) != target.original) throw EditPersistenceConflict()
                    if (target.unchanged) AdjustmentOutcome(target.id, AdjustmentStatus.UNCHANGED, saved = target.original) else {
                        val saved = store.compareAndSave(target.original, target.candidate)
                        record(operation.id, operation.action, operation.payload.fields, target.displayName,
                            target.original, saved, target.validateSource)
                        AdjustmentOutcome(target.id, AdjustmentStatus.APPLIED, saved = saved)
                    }
                } catch (error: EditPersistenceConflict) { AdjustmentOutcome(target.id, AdjustmentStatus.CONFLICT, error = error) }
                  catch (error: Exception) { AdjustmentOutcome(target.id, AdjustmentStatus.FAILED, error = error) }
                else -> AdjustmentOutcome(target.id, AdjustmentStatus.BLOCKED, error = target.error)
            }
            outcomes.getOrPut(operation.id) { mutableMapOf() }[target.id] = result
            result
        }
    }
    fun commitEdit(expected: VersionedPhotoEdit, settings: EditSettings, displayName: String = expected.identity.value,
        defaultSettings: EditSettings? = null, isCurrent: () -> Boolean = { true }, validateSource: (() -> Unit)? = null): AdjustmentOutcome {
        val id = expected.identity.value
        if (!isCurrent()) return AdjustmentOutcome(id, AdjustmentStatus.BLOCKED, error = draftError())
        return try {
            validateSource?.invoke()
            if (expected.settings == null && settings == defaultSettings) {
                if (store.versionedState(expected.identity) != expected) throw EditPersistenceConflict()
                AdjustmentOutcome(id, AdjustmentStatus.UNCHANGED, saved = expected)
            } else {
                val saved = store.compareAndSave(expected, settings)
                if (saved == expected) AdjustmentOutcome(id, AdjustmentStatus.UNCHANGED, saved = saved) else {
                    record(UUID.randomUUID(), AdjustmentHistoryTransaction.Action.EDIT, emptySet(), displayName, expected, saved, validateSource)
                    AdjustmentOutcome(id, AdjustmentStatus.APPLIED, saved = saved)
                }
            }
        } catch (error: EditPersistenceConflict) { AdjustmentOutcome(id, AdjustmentStatus.CONFLICT, error = error) }
          catch (error: Exception) { AdjustmentOutcome(id, AdjustmentStatus.FAILED, error = error) }
    }

    fun canUndoPhoto(identity: PhotoIdentity) = photoHistoryID(identity, true) != null
    fun canRedoPhoto(identity: PhotoIdentity) = photoHistoryID(identity, false) != null
    fun photoHistoryID(identity: PhotoIdentity, undo: Boolean): UUID? {
        val desired = if (undo) AdjustmentHistoryTransaction.State.APPLIED else AdjustmentHistoryTransaction.State.UNDONE
        return (if (undo) history.asReversed() else history).firstOrNull { transaction ->
            transaction.parts.any { it.identity == identity && it.state == desired }
        }?.id
    }
    fun undoPhoto(identity: PhotoIdentity, transactionID: UUID? = null, isCurrent: (String) -> Boolean = { true }) =
        historyPhoto(identity, transactionID, true, isCurrent)
    fun redoPhoto(identity: PhotoIdentity, transactionID: UUID? = null, isCurrent: (String) -> Boolean = { true }) =
        historyPhoto(identity, transactionID, false, isCurrent)
    fun undoTransaction(id: UUID, skipping: Set<String> = emptySet(), isCurrent: (String) -> Boolean = { true }) =
        runHistory(id, null, true, skipping, isCurrent)
    fun redoTransaction(id: UUID, skipping: Set<String> = emptySet(), isCurrent: (String) -> Boolean = { true }) =
        runHistory(id, null, false, skipping, isCurrent)
    private fun historyPhoto(identity: PhotoIdentity, id: UUID?, undo: Boolean, isCurrent: (String) -> Boolean): List<AdjustmentOutcome> {
        val transactionID = id ?: photoHistoryID(identity, undo) ?: return emptyList()
        return runHistory(transactionID, identity, undo, emptySet(), isCurrent)
    }
    private fun runHistory(id: UUID, photo: PhotoIdentity?, undo: Boolean, skipping: Set<String>,
        isCurrent: (String) -> Boolean): List<AdjustmentOutcome> {
        val transaction = history.indexOfFirst { it.id == id }
        if (transaction < 0) return emptyList()
        val desired = if (undo) AdjustmentHistoryTransaction.State.APPLIED else AdjustmentHistoryTransaction.State.UNDONE
        val selected = history[transaction].parts.withIndex().filter { (_, part) -> part.state == desired && (photo == null || part.identity == photo) }
        val prepared = mutableMapOf<Int, VersionedPhotoEdit>()
        val rejected = mutableMapOf<Int, AdjustmentOutcome>()
        for ((index, part) in selected) {
            val key = part.identity.value
            if (key in skipping) continue
            try {
                if (!isCurrent(key)) throw draftError()
                sourceValidators[key]?.invoke()
                val current = store.versionedState(part.identity)
                if (current != knownRecords[key] || historyHeads[key] != (if (undo) part.id else part.priorHead) ||
                    current.settings != (if (undo) part.after else part.before)) throw EditPersistenceConflict()
                prepared[index] = current
            } catch (error: Exception) {
                rejected[index] = AdjustmentOutcome(key, if (error is EditPersistenceConflict) AdjustmentStatus.CONFLICT else AdjustmentStatus.BLOCKED,
                    error = error, requiresHistoryDecision = true)
            }
        }
        if (rejected.isNotEmpty()) return selected.map { (index, part) ->
            rejected[index] ?: AdjustmentOutcome(part.identity.value, if (part.identity.value in skipping) AdjustmentStatus.SKIPPED else AdjustmentStatus.BLOCKED,
                error = unresolved("history conflict"))
        }
        return selected.map { (index, part) ->
            val key = part.identity.value
            val current = prepared[index] ?: return@map AdjustmentOutcome(key, AdjustmentStatus.SKIPPED)
            if (!isCurrent(key)) return@map AdjustmentOutcome(key, AdjustmentStatus.BLOCKED, error = draftError(), requiresHistoryDecision = true)
            try {
                sourceValidators[key]?.invoke()
                val saved = store.compareAndSave(current, if (undo) part.before else part.after)
                knownRecords[key] = saved; historyHeads[key] = if (undo) part.priorHead else part.id
                val parts = history[transaction].parts.toMutableList()
                parts[index] = part.copy(state = if (undo) AdjustmentHistoryTransaction.State.UNDONE else AdjustmentHistoryTransaction.State.APPLIED)
                history[transaction] = history[transaction].copy(parts = parts)
                AdjustmentOutcome(key, AdjustmentStatus.APPLIED, saved = saved)
            } catch (error: EditPersistenceConflict) { AdjustmentOutcome(key, AdjustmentStatus.CONFLICT, error = error, requiresHistoryDecision = true) }
              catch (error: Exception) { AdjustmentOutcome(key, AdjustmentStatus.FAILED, error = error) }
        }
    }

    private fun record(id: UUID, action: AdjustmentHistoryTransaction.Action, fields: Set<AdjustmentField>, displayName: String,
        before: VersionedPhotoEdit, after: VersionedPhotoEdit, validateSource: (() -> Unit)?) {
        val key = after.identity.value
        val priorHead = if (before == knownRecords[key]) historyHeads[key] else null
        knownRecords[key] = after
        if (validateSource != null) sourceValidators[key] = validateSource
        for (index in history.indices) history[index] = history[index].copy(parts = history[index].parts.map { part ->
            if (part.identity.value == key && part.state == AdjustmentHistoryTransaction.State.UNDONE)
                part.copy(state = AdjustmentHistoryTransaction.State.REDO_INVALIDATED) else part
        })
        val part = AdjustmentHistoryTransaction.Part(UUID.randomUUID(), priorHead, after.identity, displayName,
            before.settings, after.settings, AdjustmentHistoryTransaction.State.APPLIED)
        historyHeads[key] = part.id
        val index = history.indexOfFirst { it.id == id }
        if (index < 0) history += AdjustmentHistoryTransaction(id, action, fields.toSet(), listOf(part))
        else history[index] = history[index].copy(parts = history[index].parts + part)
    }
    private fun draftError() = AdjustmentTransferException(AdjustmentFailure.DRAFT)
    private fun unresolved(detail: String) = AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, "unresolved $detail")
}
