package com.rawlab.android.editor

import android.content.SharedPreferences
import android.net.Uri
import android.util.Log
import com.rawlab.android.R
import com.rawlab.android.editor.render.LookResult
import com.rawlab.android.editor.render.LookWork
import com.rawlab.android.editor.render.RenderQueue
import com.rawlab.android.editor.render.Work
import com.rawlab.android.editor.storage.EditSaveResult
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.looks.DcpFailureReason
import com.rawlab.android.looks.DcpImportChoices
import com.rawlab.android.looks.LUTCompatibility
import com.rawlab.android.looks.MasterRecipe
import com.rawlab.android.looks.RecentLooks
import com.rawlab.android.looks.UnreadableLook
import com.rawlab.android.looks.localizedName
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.LookChoice
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import org.json.JSONArray

private const val LOOK_TAG = "com.rawlab.EditorViewModel"

internal class EditorLookStateHolder(
    private val mutable: MutableStateFlow<EditorState>,
    private val scope: CoroutineScope,
    private val strings: EditorStrings,
    preferencesFactory: () -> SharedPreferences,
    private val loadMasterRecipes: () -> List<MasterRecipe>,
    lookWorkRunner: (LookWork) -> LookResult,
    onQueueReleased: () -> Unit,
    private val isDisposed: () -> Boolean,
    private val currentSourceRevision: () -> Long,
    private val currentDraftRevision: () -> Long,
    private val currentPreviewLongEdge: () -> Int,
    private val requestedPreviewLongEdge: () -> Int,
    private val gpuMode: () -> Int,
    private val onEdit: (EditSettings, Boolean) -> Unit,
    private val onRenderDraft: (Boolean) -> Unit,
    private val onClearPendingResetMigration: () -> Unit,
    private val onPersist: (ImportedPhoto, EditSettings, (EditSaveResult) -> Unit) -> Unit,
    private val onIncrementEditRevision: () -> Unit,
    private val onClearDurablePreview: () -> Unit,
    private val onSubmitPreview: (Work.Preview) -> Unit,
    private val onUpdatePreviewSize: (Int) -> Unit,
) {
    private val preferences by lazy(LazyThreadSafetyMode.SYNCHRONIZED, preferencesFactory)
    private val recentLooks by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        RecentLooks(runCatching {
            val entries = JSONArray(preferences.getString("recent", "[]"))
            List(entries.length()) { entries.getString(it) }
        }.getOrDefault(emptyList()))
    }
    private var lookRevision = 0L
    private var lookImportSelectionContext: Pair<Long, Long>? = null

    val queue = RenderQueue<LookWork, LookResult>(
        lookWorkRunner,
        { revision, result ->
            scope.launch {
                if (!isDisposed() && revision == lookRevision) acceptLook(result)
            }
        },
        onQueueReleased,
    )

    fun loadInitial() {
        lookRevision = queue.submit(LookWork.Load)
    }

    fun close() = queue.close()

    private fun acceptLook(result: Result<LookResult>) {
        if (mutable.value.committingAdjustments) {
            val revision = lookRevision
            scope.launch {
                mutable.first { !it.committingAdjustments }
                if (!isDisposed() && revision == lookRevision) acceptLook(result)
            }
            return
        }
        result.fold(::acceptLookValue) { error ->
            mutable.value = mutable.value.copy(
                operation = if (mutable.value.pendingLookImports.isEmpty()) Operation.NONE else Operation.IMPORT_LOOK,
                lookImportPreparing = false,
                error = strings.text(R.string.look_storage_error) + "\n" + (error.message ?: error.javaClass.simpleName),
            )
        }
        onUpdatePreviewSize(requestedPreviewLongEdge())
    }

    private fun acceptLookValue(result: LookResult) {
        when (result) {
            is LookResult.Loaded -> {
                mutable.value = EditorStateReducer.looksLoaded(mutable.value, result.entries)
                recentLooks.ids.filter { it.startsWith("recipe-lut:") }.forEach { includeIndependentRecipeLook(EditSettings(film = it)) }
                includeIndependentRecipeLook(mutable.value.edits)
                updateRecentLooks()
            }
            is LookResult.UnreadableDeleted -> {
                mutable.value = EditorStateReducer.looksLoaded(mutable.value, result.entries).copy(operation = Operation.NONE)
                recentLooks.ids.filter { it.startsWith("recipe-lut:") }.forEach { includeIndependentRecipeLook(EditSettings(film = it)) }
                includeIndependentRecipeLook(mutable.value.edits)
                updateRecentLooks()
            }
            is LookResult.Imported -> {
                val contextMatches = lookImportSelectionContext == (currentSourceRevision() to currentDraftRevision())
                val mutation = result.imported.lastOrNull()?.takeIf { contextMatches }
                    ?.let { EditorStateReducer.lookImported(mutable.value, it) }
                    ?: EditorMutation(mutable.value.copy(operation = Operation.NONE), null)
                val report = if (result.failures.isEmpty()) null else {
                    strings.format(R.string.look_import_summary, arrayOf(result.imported.size, result.failures.size)) +
                        result.failures.joinToString("\n") { failure ->
                            val colorMessage = when (failure.colorReason) {
                                0 -> strings.text(R.string.lut_missing_color)
                                1 -> strings.text(R.string.lut_missing_reference)
                                2 -> strings.text(R.string.lut_unsupported_color)
                                3 -> strings.text(R.string.lut_conflicting_color)
                                9 -> strings.text(R.string.lut_compatibility_changed)
                                else -> null
                            }
                            val message = colorMessage ?: failure.dcpReason?.let(::dcpFailureText) ?: failure.message
                            if (failure.invalid && colorMessage == null) message + "\n" + strings.text(R.string.look_invalid_file) else message
                        }
                }
                val pending = mutable.value.pendingLookImports + result.pending
                mutable.value = mutation.state.copy(
                    looks = result.looks,
                    pendingLookImports = pending,
                    lookImportPreparing = false,
                    operation = if (pending.isEmpty()) Operation.NONE else Operation.IMPORT_LOOK,
                    lookImportReport = listOfNotNull(mutable.value.lookImportReport, report).takeIf { it.isNotEmpty() }?.joinToString("\n"),
                    error = if (mutation.blockedRecipeSelection) strings.text(R.string.editor_reset_unrepresentable) else mutation.state.error,
                    message = if (result.imported.isEmpty()) null else strings.text(R.string.look_imported),
                )
                scheduleLookPreview(mutation.preview)
            }
            is LookResult.Renamed -> {
                val mutation = EditorStateReducer.lookRenamed(mutable.value, result.look)
                mutable.value = mutation.state.copy(looks = result.looks)
            }
            is LookResult.Deleted -> {
                val mutation = EditorStateReducer.lookDeleted(mutable.value, result.id)
                mutable.value = mutation.state.copy(looks = result.looks)
                updateRecentLooks()
                scheduleLookPreview(mutation.preview)
            }
            is LookResult.Failed -> {
                if (result.reload) lookRevision = queue.submit(LookWork.Load)
                val title = strings.text(if (result.reload) R.string.look_error else R.string.look_storage_error)
                mutable.value = mutable.value.copy(
                    operation = if (mutable.value.pendingLookImports.isEmpty()) Operation.NONE else Operation.IMPORT_LOOK,
                    lookImportPreparing = false,
                    error = title + "\n" + (result.error.message ?: result.error.javaClass.simpleName),
                )
            }
        }
    }

    private fun scheduleLookPreview(edits: EditSettings?) {
        val photo = mutable.value.photo ?: return
        if (edits == null) return
        if (mutable.value.draft != null) {
            onRenderDraft(false)
            return
        }
        onClearPendingResetMigration()
        onPersist(photo, edits) { saved ->
            mutable.value = mutable.value.copy(saveState = saved.state, saveError = saved.message)
            onIncrementEditRevision()
            onClearDurablePreview()
            onSubmitPreview(Work.Preview(photo, edits, false, gpuMode(), edge = currentPreviewLongEdge()))
        }
    }

    private fun dcpFailureText(reason: DcpFailureReason): String = strings.text(
        when (reason) {
            DcpFailureReason.MALFORMED -> R.string.dcp_malformed
            DcpFailureReason.TOO_LARGE -> R.string.dcp_too_large
            DcpFailureReason.INVALID_CALIBRATION -> R.string.dcp_invalid_calibration
            DcpFailureReason.MISSING_TONE_CURVE -> R.string.dcp_missing_tone_curve
            DcpFailureReason.AUTOMATIC_BLACK -> R.string.dcp_automatic_black
            DcpFailureReason.TRIPLE_ILLUMINANT -> R.string.dcp_triple_illuminant
            DcpFailureReason.UNSUPPORTED_STAGES -> R.string.dcp_unsupported_stages
            DcpFailureReason.INVALID_TABLE -> R.string.dcp_invalid_table
            DcpFailureReason.INVALID_TONE_CURVE -> R.string.dcp_invalid_tone_curve
            DcpFailureReason.INVALID_EXPOSURE -> R.string.dcp_invalid_exposure
        },
    )

    fun importLook(uri: Uri?) {
        if (uri != null) importLooks(listOf(uri))
    }

    fun importLooks(uris: List<Uri>) {
        if (uris.isEmpty() || mutable.value.operation != Operation.NONE ||
            (mutable.value.draft != null && mutable.value.draft?.group != AdjustmentGroup.LOOK)
        ) return
        mutable.value = mutable.value.copy(operation = Operation.IMPORT_LOOK, error = null, lookImportReport = null)
        lookImportSelectionContext = currentSourceRevision() to currentDraftRevision()
        lookRevision = queue.submit(LookWork.Import(uris.toList()))
    }

    fun dismissLookImportReport() {
        mutable.value = mutable.value.copy(lookImportReport = null)
    }

    fun resolveLookCompatibility(draft: LUTCompatibility?) {
        if (mutable.value.lookImportPreparing) return
        val pending = mutable.value.pendingLookImports.firstOrNull() as? PendingLookCompatibility ?: return
        if (draft != null && (!draft.canImport || draft.sourceHash != pending.draft.sourceHash)) return
        resolveLookImport(draft?.let { LookWork.Import(listOf(pending.uri), compatibility = it) })
    }

    fun resolveDcpImport(choices: DcpImportChoices?) {
        if (mutable.value.lookImportPreparing) return
        val pending = mutable.value.pendingLookImports.firstOrNull() as? PendingDcpImport ?: return
        resolveLookImport(choices?.let { LookWork.Import(listOf(pending.uri), dcp = it) })
    }

    private fun resolveLookImport(work: LookWork.Import?) {
        val remaining = mutable.value.pendingLookImports.drop(1)
        mutable.value = mutable.value.copy(
            pendingLookImports = remaining,
            lookImportPreparing = work != null,
            operation = if (work != null || remaining.isNotEmpty()) Operation.IMPORT_LOOK else Operation.NONE,
        )
        if (work != null) lookRevision = queue.submit(work)
    }

    fun renameLook(id: String, name: String) {
        if (mutable.value.committingAdjustments || mutable.value.operation != Operation.NONE || mutable.value.draft != null) return
        mutable.value = mutable.value.copy(operation = Operation.IMPORT_LOOK, error = null)
        lookRevision = queue.submit(LookWork.Rename(id, name))
    }

    fun deleteLook(id: String) {
        if (mutable.value.committingAdjustments || mutable.value.operation != Operation.NONE || mutable.value.draft != null) return
        mutable.value = mutable.value.copy(operation = Operation.IMPORT_LOOK, error = null)
        lookRevision = queue.submit(LookWork.Delete(id))
    }

    fun deleteUnreadableLook(entry: UnreadableLook) {
        if (mutable.value.committingAdjustments || mutable.value.operation != Operation.NONE ||
            (mutable.value.draft != null && mutable.value.draft?.group != AdjustmentGroup.LOOK)
        ) return
        mutable.value = mutable.value.copy(operation = Operation.IMPORT_LOOK, error = null)
        lookRevision = queue.submit(LookWork.DeleteUnreadable(entry))
    }

    fun selectFilm(id: String): Boolean {
        val current = mutable.value
        if (!current.controlsEnabled || (current.draft != null && current.draft.group !in listOf(AdjustmentGroup.LOOK, AdjustmentGroup.RECIPE))) {
            if (!current.controlsEnabled) Log.w(LOOK_TAG, "edit-dropped method=selectFilm reason=controlsDisabled op=${current.operation}")
            return false
        }
        val candidate = try {
            current.visibleEdits.selectFilm(id, current.preview?.tint, current.preview?.temperature, current.photo!!.inputKind)
        } catch (_: IllegalArgumentException) {
            mutable.value = current.copy(
                error = strings.text(
                    if (current.preview == null) R.string.editor_reset_missing_wb else R.string.editor_reset_unrepresentable,
                ),
            )
            return false
        }
        onEdit(candidate, false)
        return mutable.value.visibleEdits == candidate
    }

    fun updateRecentLooks(applied: String? = null) {
        val available = mutable.value.looks.filter { it.available }.mapTo(mutableSetOf()) { it.id }
        if (applied == null) recentLooks.prune(available) else recentLooks.record(applied, available)
        if (mutable.value.recentLookIds == recentLooks.ids) return
        mutable.value = mutable.value.copy(recentLookIds = recentLooks.ids)
        preferences.edit().putString("recent", JSONArray(recentLooks.ids).toString()).apply()
    }

    fun includeIndependentRecipeLook(settings: EditSettings) {
        if (!settings.film.startsWith("recipe-lut:") || mutable.value.looks.any { it.id == settings.film }) return
        val id = settings.film.removePrefix("recipe-lut:")
        val recipe = loadMasterRecipes().firstOrNull { it.id == id } ?: return
        mutable.value = mutable.value.copy(looks = mutable.value.looks + LookChoice(settings.film, "${recipe.localizedName} LUT", managed = false))
    }
}
