package com.rawlab.android.editor

import android.app.Application
import android.net.Uri
import com.rawlab.android.adjustments.AdjustmentFailure
import com.rawlab.android.adjustments.AdjustmentHistoryTransaction
import com.rawlab.android.adjustments.AdjustmentOutcome
import com.rawlab.android.adjustments.AdjustmentPayload
import com.rawlab.android.adjustments.AdjustmentScope
import com.rawlab.android.adjustments.AdjustmentStatus
import com.rawlab.android.adjustments.AdjustmentTransfer
import com.rawlab.android.adjustments.AdjustmentTransferContext
import com.rawlab.android.adjustments.AdjustmentTransferException
import com.rawlab.android.adjustments.PreparedAdjustmentTransfer
import com.rawlab.android.adjustments.effectiveTransferNotices
import com.rawlab.android.batch.BatchTarget
import com.rawlab.android.editor.render.SerialWorkQueue
import com.rawlab.android.editor.storage.EditorEditStore
import com.rawlab.android.editor.ui.transferNoticeLabel
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.looks.MasterRecipe
import com.rawlab.android.looks.localizedName
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.presets.AdjustmentPreset
import com.rawlab.android.settings.AdjustmentOperationExpiredException
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.PhotoIdentity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.io.File
import java.util.UUID

internal class EditorAdjustmentTransferStateHolder(
    application: Application,
    private val storage: PhotoStorage,
    private val editStore: EditorEditStore,
    private val adjustmentHistory: EditorAdjustmentHistory,
    private val mutable: MutableStateFlow<EditorState>,
    private val scope: CoroutineScope,
    private val strings: EditorStrings,
    private val loadMasterRecipes: () -> List<MasterRecipe>,
    customPreparationRunner: ((AdjustmentPreparationWork, () -> Boolean) -> AdjustmentPreparationResult)?,
    onQueueReleased: () -> Unit,
    private val isDisposed: () -> Boolean,
    private val currentSourceRevision: () -> Long,
    private val currentEditRevision: () -> Long,
    private val collectionPhoto: (String) -> ImportedPhoto?,
    private val collectionTargets: () -> List<BatchTarget>,
    private val validateCollectionTarget: (BatchTarget) -> Unit,
    private val onCollectionSynchronized: (UUID, Boolean) -> Unit,
    private val onReleaseDeferredCollections: () -> Unit,
    private val onCommitAdjustments: (work: () -> List<AdjustmentOutcome>, completed: (Result<List<AdjustmentOutcome>>) -> Unit) -> Unit,
    private val onPersist: (ImportedPhoto, EditSettings, (com.rawlab.android.editor.storage.EditSaveResult) -> Unit) -> Unit,
    private val onClearHslTarget: () -> Unit,
    private val onCancelProcessingMigration: () -> Unit,
    private val onClearPendingResetMigration: () -> Unit,
    private val onIncrementEditRevision: () -> Unit,
    private val onIncludeIndependentRecipeLook: (EditSettings) -> Unit,
    private val onUpdateRecentLooks: (String?) -> Unit,
    private val onRenderCommittedForNavigation: () -> Unit,
) {
    private val mutableTransfer = MutableStateFlow(EditorAdjustmentTransferState())
    val transfer = mutableTransfer.asStateFlow()
    private val mutableQuickPreset = MutableStateFlow(EditorQuickPresetState())
    val quickPreset = mutableQuickPreset.asStateFlow()

    var clipboardSourceName: String? = null
        private set
    private var quickPresetGeneration = UUID.randomUUID()
    internal var ownedFiles = emptyMap<String, File>()
        private set
    @Volatile private var preparationGeneration = UUID.randomUUID()
    private var preparations = 0
    private var closeRequested = false

    private val defaultPreparation = EditorAdjustmentPreparation(application, storage, editStore, loadMasterRecipes)
    internal var prepareAdjustmentOperation: (AdjustmentPreparationWork, () -> Boolean) -> AdjustmentPreparationResult =
        customPreparationRunner ?: defaultPreparation::prepare
    val preparationQueue = SerialWorkQueue(onQueueReleased)

    fun hasActivePreparations(): Boolean = preparations > 0

    fun close() = preparationQueue.close()

    fun onDisposed() {
        preparationGeneration = UUID.randomUUID()
    }

    fun cancelInteraction() {
        onCancelProcessingMigration()
        if (mutable.value.committingAdjustments) return
        onClearHslTarget()
        val restored = adjustmentHistory.cancel(mutable.value.photo, currentSourceRevision()) ?: return
        onClearPendingResetMigration()
        onIncrementEditRevision()
        mutable.value = mutable.value.copy(edits = restored)
        onRenderCommittedForNavigation()
    }

    fun undo(completed: (List<AdjustmentOutcome>) -> Unit = {}) = performHistory(undo = true, completed = completed)
    fun redo(completed: (List<AdjustmentOutcome>) -> Unit = {}) = performHistory(undo = false, completed = completed)

    fun performHistory(
        undo: Boolean,
        transactionID: UUID? = null,
        wholeTransaction: Boolean = false,
        skipping: Set<String> = emptySet(),
        completed: (List<AdjustmentOutcome>) -> Unit = {},
    ) {
        val session = adjustmentHistory.session ?: return completed(emptyList())
        val photo = mutable.value.photo ?: return completed(emptyList())
        val id = transactionID ?: session.photoHistoryID(photo.identity, undo) ?: return completed(emptyList())
        executeHistory(EditorAdjustmentHistoryRequest(id, if (wholeTransaction) null else photo.identity, undo), skipping, completed)
    }

    fun executeHistory(
        request: EditorAdjustmentHistoryRequest,
        skipping: Set<String> = emptySet(),
        completed: (List<AdjustmentOutcome>) -> Unit = {},
    ) {
        val session = adjustmentHistory.session ?: return completed(emptyList())
        val expectedSourceToken = adjustmentHistory.snapshot().sourceToken
        onCommitAdjustments({
            if (request.photo == null) {
                if (request.undo) session.undoTransaction(request.transactionID, skipping, ::targetIsCurrent)
                else session.redoTransaction(request.transactionID, skipping, ::targetIsCurrent)
            } else if (request.undo) {
                session.undoPhoto(request.photo, request.transactionID, ::targetIsCurrent)
            } else {
                session.redoPhoto(request.photo, request.transactionID, ::targetIsCurrent)
            }
        }) { outcome ->
            (outcome.exceptionOrNull() as? AdjustmentTransferException)?.takeIf { it.reason == AdjustmentFailure.DRAFT }?.let {
                mutable.value = mutable.value.copy(message = adjustmentErrorMessage(it, strings))
            }
            val results = outcome.getOrElse { listOf(AdjustmentOutcome(request.photo?.value.orEmpty(), AdjustmentStatus.FAILED, error = it)) }
            val accepted = acceptOutcomes(results, expectedSourceToken = expectedSourceToken)
            mutableTransfer.value = mutableTransfer.value.copy(historyRequest = request, historyResults = accepted)
            completed(accepted)
        }
    }

    fun targetIsCurrent(identity: String): Boolean = targetIsCurrent(identity, adjustmentHistory.snapshot())

    fun targetIsCurrent(identity: String, history: EditorAdjustmentHistory.Snapshot): Boolean {
        val current = mutable.value
        if (current.photo?.identity?.value != identity) return true
        return current.operation == Operation.NONE && current.draft == null && !history.interacting &&
            current.saveState != EditSaveState.FAILED
    }

    internal fun acceptOutcomes(
        results: List<AdjustmentOutcome>,
        cachedTargets: Set<String> = emptySet(),
        expectedSourceToken: Long? = null,
    ): List<AdjustmentOutcome> {
        val current = mutable.value
        val photo = current.photo
        val history = adjustmentHistory.snapshot()
        var restored: EditSettings? = null
        if (photo != null && targetIsCurrent(photo.identity.value, history)) {
            val token = expectedSourceToken ?: history.sourceToken
            for (result in results) {
                val saved = result.saved ?: continue
                if (result.targetID != photo.identity.value || result.targetID in cachedTargets ||
                    result.status !in setOf(AdjustmentStatus.APPLIED, AdjustmentStatus.UNCHANGED)
                ) continue
                if (adjustmentHistory.acceptSaved(photo, saved, token)) restored = saved.settings ?: photo.defaultEditSettings()
            }
        }
        mutable.value = current.copy(adjustmentRevision = current.adjustmentRevision + 1)
        if (restored != null) {
            onClearPendingResetMigration()
            if (!mutableQuickPreset.value.busy) {
                quickPresetGeneration = UUID.randomUUID()
                mutableQuickPreset.value = EditorQuickPresetState(visible = mutableQuickPreset.value.visible)
            }
            onIncrementEditRevision()
            mutable.value = mutable.value.copy(
                edits = restored,
                saveState = EditSaveState.SAVED,
                saveError = null,
                error = null,
                hdrCameraDraft = mutable.value.hdrCameraDraft?.retainedFor(restored.hdr?.cameraSettings),
            )
            onIncludeIndependentRecipeLook(restored)
            if (restored.recipeID == null && current.edits.film != restored.film) onUpdateRecentLooks(restored.film)
            onRenderCommittedForNavigation()
        }
        return results
    }

    fun copy(scope: AdjustmentScope): AdjustmentPayload? {
        val current = mutable.value
        val photo = current.photo ?: return null
        if (!current.controlsEnabled || current.draft != null || adjustmentHistory.snapshot().interacting) return null
        if (current.saveState == EditSaveState.FAILED) return null
        return try {
            val captured = adjustmentHistory.session!!.copy(
                scope,
                current.edits,
                AdjustmentTransferContext(
                    photo.identity.value,
                    photo.inputKind == PhotoInputKind.RAW,
                    builtinLookIDs = storage.builtinLookIDs(),
                    cameraTemperature = current.preview?.temperature,
                    cameraTint = current.preview?.tint,
                    sourceSupportsCameraHDR = photo.isCameraRawHDR,
                    sourceIsProRAW = photo.hdrSource?.isProRAW == true,
                ),
            )
            clipboardSourceName = photo.name
            mutable.value = current.copy(adjustmentRevision = current.adjustmentRevision + 1)
            captured
        } catch (error: Exception) {
            mutableTransfer.value = mutableTransfer.value.copy(error = adjustmentErrorMessage(error, strings))
            null
        }
    }

    fun capturePreset(
        scope: AdjustmentScope,
        commitCapture: (work: () -> AdjustmentPayload, completed: (Result<AdjustmentPayload>) -> Unit) -> Unit,
        completed: (Result<AdjustmentPayload>) -> Unit,
    ) {
        val current = mutable.value
        val photo = current.photo
        if (isDisposed() || current.committingAdjustments || photo == null ||
            !targetIsCurrent(photo.identity.value) || adjustmentHistory.session == null
        ) {
            completed(Result.failure(AdjustmentTransferException(AdjustmentFailure.DRAFT)))
            return
        }
        val context = AdjustmentTransferContext(
            photo.identity.value,
            photo.inputKind == PhotoInputKind.RAW,
            builtinLookIDs = storage.builtinLookIDs(),
            cameraTemperature = current.preview?.temperature,
            cameraTint = current.preview?.tint,
            sourceSupportsCameraHDR = photo.isCameraRawHDR,
            sourceIsProRAW = photo.hdrSource?.isProRAW == true,
        )
        commitCapture({
            adjustmentHistory.snapshot().validateCommitted(photo, current.edits)
            AdjustmentTransfer.capture(scope, current.edits, context)
        }, completed)
    }

    fun previewPayload(scope: AdjustmentScope): Result<AdjustmentPayload> = runCatching {
        val current = mutable.value
        val photo = current.photo ?: throw AdjustmentTransferException(AdjustmentFailure.DRAFT)
        val history = adjustmentHistory.snapshot()
        val record = history.loaded ?: throw AdjustmentTransferException(AdjustmentFailure.DRAFT)
        if (isDisposed() || current.committingAdjustments || record.identity != photo.identity ||
            !targetIsCurrent(photo.identity.value, history)
        ) {
            throw AdjustmentTransferException(AdjustmentFailure.DRAFT)
        }
        AdjustmentTransfer.previewCapture(
            scope,
            current.edits,
            record.settings ?: photo.defaultEditSettings(),
            AdjustmentTransferContext(
                photo.identity.value,
                photo.inputKind == PhotoInputKind.RAW,
                builtinLookIDs = storage.builtinLookIDs(),
                cameraTemperature = current.preview?.temperature,
                cameraTint = current.preview?.tint,
                sourceSupportsCameraHDR = photo.isCameraRawHDR,
                sourceIsProRAW = photo.hdrSource?.isProRAW == true,
            ),
        )
    }

    fun summaryLookName(kind: String, id: String): String? {
        if (kind == "recipe" || kind == "recipe_lut") {
            return loadMasterRecipes().firstOrNull { it.id == id }?.localizedName
        }
        val localID = if (kind == "builtin") storage.builtinLookIDs()[id] ?: return null else id
        return mutable.value.looks.firstOrNull { it.id == localID && it.available }?.name
    }

    fun preparePaste(
        payload: AdjustmentPayload,
        uris: List<Uri>,
        action: AdjustmentHistoryTransaction.Action = AdjustmentHistoryTransaction.Action.PASTE,
    ) {
        if (isDisposed() || mutable.value.committingAdjustments) {
            mutableTransfer.value = mutableTransfer.value.copy(
                error = adjustmentErrorMessage(AdjustmentTransferException(AdjustmentFailure.DRAFT), strings),
            )
            return
        }
        closeOperation()
        startPreparation(payload, uris, action)
    }

    private fun startPreparation(
        payload: AdjustmentPayload,
        uris: List<Uri>,
        action: AdjustmentHistoryTransaction.Action,
        completed: (Result<PreparedAdjustmentTransfer>) -> Unit = {},
    ) {
        closeRequested = false
        val generation = UUID.randomUUID()
        preparationGeneration = generation
        mutableTransfer.value = EditorAdjustmentTransferState(preparing = true)
        val work = AdjustmentPreparationWork(
            generation,
            payload,
            uris.toList(),
            mutable.value.photo,
            ::targetIsCurrent,
            action,
            collectionPhotos = if (action == AdjustmentHistoryTransaction.Action.SYNCHRONIZE) {
                uris.mapNotNull { uri -> collectionPhoto(uri.toString())?.let { uri.toString() to it } }.toMap()
            } else emptyMap(),
            validateCollection = if (action == AdjustmentHistoryTransaction.Action.SYNCHRONIZE) {
                { id ->
                    collectionTargets().firstOrNull { it.id == id }?.let(validateCollectionTarget)
                        ?: error("Photo left the collection")
                }
            } else null,
        )
        preparations += 1
        val prepare = prepareAdjustmentOperation
        preparationQueue.submit({ prepare(work) { generation != preparationGeneration } }) { result ->
            if (isDisposed()) result.getOrNull()?.ownedFiles?.values?.forEach(File::delete)
            else scope.launch {
                preparations -= 1
                result.fold({ value ->
                    if (!isDisposed() && value.generation == preparationGeneration) {
                        ownedFiles = value.ownedFiles
                        mutableTransfer.value = mutableTransfer.value.copy(
                            preparing = false,
                            prepared = value.operation,
                            results = emptyList(),
                            error = null,
                        )
                        completed(Result.success(value.operation))
                    } else {
                        value.ownedFiles.values.forEach(File::delete)
                    }
                }, { error ->
                    if (!isDisposed() && generation == preparationGeneration) {
                        mutableTransfer.value = mutableTransfer.value.copy(
                            preparing = false,
                            error = adjustmentErrorMessage(error, strings),
                        )
                        completed(Result.failure(error))
                    }
                })
                onReleaseDeferredCollections()
            }
        }
    }

    fun applyPaste(
        operation: PreparedAdjustmentTransfer,
        skipping: Set<String> = emptySet(),
        completed: (List<AdjustmentOutcome>) -> Unit = {},
    ) {
        if (mutableTransfer.value.prepared?.id != operation.id) return completed(emptyList())
        val previous = mutableTransfer.value.results.filter {
            it.status in setOf(AdjustmentStatus.APPLIED, AdjustmentStatus.UNCHANGED, AdjustmentStatus.SKIPPED)
        }.map { it.targetID }.toSet()
        val session = adjustmentHistory.session ?: return completed(emptyList())
        val expectedSourceToken = adjustmentHistory.snapshot().sourceToken
        onCommitAdjustments({ session.apply(operation, skipping) }) { outcome ->
            val results = outcome.getOrElse {
                operation.targets.map { target -> AdjustmentOutcome(target.id, AdjustmentStatus.FAILED, error = it) }
            }
            val accepted = acceptOutcomes(results, previous, expectedSourceToken = expectedSourceToken)
            if (!closeRequested) mutableTransfer.value = mutableTransfer.value.copy(results = accepted)
            if (operation.action == AdjustmentHistoryTransaction.Action.SYNCHRONIZE) {
                onCollectionSynchronized(operation.id, accepted.any { it.status == AdjustmentStatus.APPLIED })
            }
            completed(accepted)
        }
    }

    private fun transferNoticeText(operation: PreparedAdjustmentTransfer, outcomes: List<AdjustmentOutcome>): String? {
        val notices = effectiveTransferNotices(operation.targets, outcomes)
        if (notices.isEmpty()) return null
        return notices.joinToString("；") { strings.text(transferNoticeLabel(it)) }
    }

    fun closeOperation() {
        quickPresetGeneration = UUID.randomUUID()
        mutableQuickPreset.value = EditorQuickPresetState(visible = mutableQuickPreset.value.visible)
        preparationGeneration = UUID.randomUUID()
        mutableTransfer.value = EditorAdjustmentTransferState()
        closeRequested = true
        finishClose()
        onReleaseDeferredCollections()
    }

    fun finishClose() {
        if (!closeRequested || mutable.value.committingAdjustments) return
        ownedFiles.values.forEach(File::delete)
        ownedFiles = emptyMap()
        closeRequested = false
    }

    fun showQuickPresets() {
        if (mutable.value.photo != null && mutable.value.operation == Operation.NONE) {
            mutableQuickPreset.value = mutableQuickPreset.value.copy(visible = true)
        }
    }

    fun closeQuickPresets() {
        if (!mutableQuickPreset.value.visible && !mutableQuickPreset.value.busy) return
        closeOperation()
        mutableQuickPreset.value = EditorQuickPresetState()
    }

    fun cancelQuickPreset() = closeOperation()

    fun applyPresetToCurrentPhoto(preset: AdjustmentPreset) {
        val current = mutable.value
        val photo = current.photo ?: return
        if (!mutableQuickPreset.value.visible || mutableQuickPreset.value.busy || !current.controlsEnabled || current.draft != null) {
            return
        }
        closeOperation()
        val generation = UUID.randomUUID()
        val source = currentSourceRevision()
        val revision = currentEditRevision()
        quickPresetGeneration = generation
        mutableQuickPreset.value = EditorQuickPresetState(true, QuickPresetPhase.PREPARING, preset)
        fun active() = !isDisposed() && quickPresetGeneration == generation && mutableQuickPreset.value.visible &&
            mutable.value.photo == photo && currentSourceRevision() == source && currentEditRevision() == revision
        fun failed(error: Throwable?) {
            mutableQuickPreset.value = EditorQuickPresetState(
                true,
                QuickPresetPhase.FAILED,
                preset,
                message = quickPresetErrorMessage(error, strings),
            )
        }
        onPersist(photo, current.edits) { saved ->
            if (!active()) return@onPersist
            if (saved.state == EditSaveState.FAILED) {
                mutable.value = mutable.value.copy(saveState = saved.state, saveError = saved.message)
                failed(saved.error)
                return@onPersist
            }
            mutable.value = mutable.value.copy(saveState = saved.state, saveError = saved.message)
            val history = adjustmentHistory.snapshot()
            if (history.loaded?.identity != photo.identity || !targetIsCurrent(photo.identity.value, history)) {
                failed(AdjustmentTransferException(AdjustmentFailure.DRAFT))
                return@onPersist
            }
            startPreparation(preset.payload, listOf(photo.uri), AdjustmentHistoryTransaction.Action.PRESET) { result ->
                if (!active()) {
                    if (quickPresetGeneration == generation) cancelQuickPreset()
                    return@startPreparation
                }
                val operation = result.getOrElse { failed(it); return@startPreparation }
                val target = operation.targets.singleOrNull()
                if (target?.error != null) { failed(target.error); return@startPreparation }
                if (target == null) { failed(AdjustmentOperationExpiredException()); return@startPreparation }
                mutableQuickPreset.value = mutableQuickPreset.value.copy(phase = QuickPresetPhase.COMMITTING)
                applyPaste(operation) { outcomes ->
                    if (quickPresetGeneration != generation || !mutableQuickPreset.value.visible) return@applyPaste
                    val outcome = outcomes.singleOrNull()
                    if (outcome?.saved == null) { failed(outcome?.error); return@applyPaste }
                    val phase = when (outcome.status) {
                        AdjustmentStatus.APPLIED -> QuickPresetPhase.SAVED
                        AdjustmentStatus.UNCHANGED -> QuickPresetPhase.UNCHANGED
                        else -> { failed(outcome.error); return@applyPaste }
                    }
                    mutableQuickPreset.value = EditorQuickPresetState(true, phase, preset, operation.id)
                    transferNoticeText(operation, listOf(outcome))?.let { message ->
                        mutable.value = mutable.value.copy(message = message)
                    }
                }
            }
        }
    }

    fun undoQuickPreset() {
        val quick = mutableQuickPreset.value
        val transaction = quick.transactionID ?: return
        if (quick.phase !in setOf(QuickPresetPhase.SAVED, QuickPresetPhase.UNDO_FAILED) ||
            !mutable.value.controlsEnabled || mutable.value.draft != null
        ) return
        val generation = quickPresetGeneration
        mutableQuickPreset.value = quick.copy(phase = QuickPresetPhase.COMMITTING, message = null)
        performHistory(true, transactionID = transaction) { outcomes ->
            if (quickPresetGeneration != generation || !mutableQuickPreset.value.visible) return@performHistory
            val outcome = outcomes.singleOrNull()
            mutableQuickPreset.value = if (outcome?.status == AdjustmentStatus.APPLIED && outcome.saved != null) {
                quick.copy(phase = QuickPresetPhase.UNDONE, message = null)
            } else {
                quick.copy(phase = QuickPresetPhase.UNDO_FAILED, message = adjustmentErrorMessage(outcome?.error, strings))
            }
        }
    }
}
