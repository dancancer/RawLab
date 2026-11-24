package com.rawlab.android.editor

import android.net.Uri
import com.rawlab.android.R
import com.rawlab.android.adjustments.AdjustmentField
import com.rawlab.android.adjustments.AdjustmentTransfer
import com.rawlab.android.adjustments.AdjustmentTransferContext
import com.rawlab.android.adjustments.hdrLook
import com.rawlab.android.editor.render.Work
import com.rawlab.android.editor.render.WorkResult
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.AdjustmentOperationExpiredException
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.HDRCameraDevelopmentSettings
import com.rawlab.android.settings.withHDRMode
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal class EditorHdrStateHolder(
    private val session: EditorDocumentSession,
) {
    private val mutable get() = session.mutable
    private val scope get() = session.scope
    private val ioDispatcher get() = session.dependencies.ioDispatcher
    private val strings get() = session.strings
    private val deps get() = session.dependencies

    var cameraHDRPreflightPending: Boolean = false
        private set
    private var pendingHDRLookImport: Triple<Long, Long, Long>? = null
    private var hdrLookJob: Job? = null
    private var pendingHDRCameraProfileImport: Pair<Long, Long>? = null

    fun onRenderSubmitted(work: Work) {
        cameraHDRPreflightPending = work is Work.CameraHDRPreflight
    }

    fun onRenderResult() {
        cameraHDRPreflightPending = false
    }

    fun onCameraHDRPreflight(value: WorkResult.CameraHDRPreflight) {
        val request = value.request
        val current = mutable.value
        if (current.photo?.identity == request.photo.identity &&
            session.sourceRevision == request.sourceRevision &&
            current.edits == request.before &&
            current.operation == Operation.NONE &&
            current.draft == null
        ) {
            session.actions.edit(request.edits, false, false)
        }
    }

    fun beginHDRLookImport(): Boolean {
        val current = mutable.value
        if (!current.controlsEnabled || !current.edits.isHDREditing ||
            (current.draft != null && current.draft.group != AdjustmentGroup.LOOK)
        ) return false
        pendingHDRLookImport = Triple(session.sourceRevision, session.editRevision, session.actions.draftRevision())
        return true
    }

    fun finishHDRLookImport(uri: Uri?) {
        val expected = pendingHDRLookImport
        pendingHDRLookImport = null
        if (uri == null || expected != Triple(session.sourceRevision, session.editRevision, session.actions.draftRevision())) return
        applyHDRLook { _, target -> target.copy(hdr = target.hdr!!.withLook(deps.hdrLookImporter(uri))) }
    }

    fun applyHDRSilver(master: Boolean) = applyHDRLook { photo, target ->
        val look = deps.hdrSilverInstaller()
        if (master) {
            val payload = deps.hdrSilverMasterLoader()
            require(payload[AdjustmentField.HDR_LOOK]?.hdrLook() == look)
            AdjustmentTransfer.prepare(
                payload,
                target,
                AdjustmentTransferContext(
                    photo.identity.value,
                    photo.inputKind == PhotoInputKind.RAW,
                    sourceSupportsCameraHDR = photo.isCameraRawHDR,
                    sourceIsProRAW = photo.hdrSource?.isProRAW == true,
                    hdrLookDirectory = session.storage.hdrLookDirectory,
                ),
            )
        } else target.copy(hdr = target.hdr!!.withLook(look))
    }

    private fun applyHDRLook(prepare: (ImportedPhoto, EditSettings) -> EditSettings) {
        val current = mutable.value
        val photo = current.photo ?: return
        if (!current.controlsEnabled || !current.edits.isHDREditing ||
            (current.draft != null && current.draft.group != AdjustmentGroup.LOOK)
        ) return
        val expected = Triple(session.sourceRevision, session.editRevision, session.actions.draftRevision())
        mutable.value = current.copy(
            operation = Operation.IMPORT_LOOK,
            exportStep = SingleExportStep.NONE,
            error = null,
            importingHDRLook = true,
        )
        val job = scope.launch(start = CoroutineStart.LAZY) {
            val self = coroutineContext[Job]
            runHDRLookImport(
                { withContext(ioDispatcher) { prepare(photo, current.visibleEdits) } },
                {
                    expected == Triple(session.sourceRevision, session.editRevision, session.actions.draftRevision()) &&
                        mutable.value.operation == Operation.IMPORT_LOOK
                },
            ) { imported ->
                // 返回键已放弃本次导入时，迟到的结果不再改动界面。
                if (session.disposed || hdrLookJob !== self) return@runHDRLookImport
                hdrLookJob = null
                mutable.value = finishedHDRLook(imported)
                imported.onSuccess { settings -> session.actions.edit(settings, false, false) }
            }
        }
        hdrLookJob = job
        job.start()
    }

    private fun finishedHDRLook(outcome: Result<*>) = EditorStateReducer.hdrLookImportFinished(
        mutable.value,
        outcome,
        strings.text(R.string.message_cancelled),
        strings.text(R.string.collection_look_unavailable),
    )

    fun cancelHDRLookImport() {
        val job = hdrLookJob ?: return
        hdrLookJob = null
        job.cancel()
        // 后台写入无法中断，已写出的外观文件不会被应用；明确提示取消而不是静默结束。
        mutable.value = finishedHDRLook(Result.failure<Unit>(CancellationException()))
    }

    fun setHDRMode(enabled: Boolean) {
        val current = mutable.value
        val photo = current.photo ?: return
        if (!photo.isHDRSource || !current.controlsEnabled || current.draft != null) return
        val candidate = runCatching {
            current.edits.withHDRMode(
                enabled,
                sourceIsHDR = !photo.isCameraRawHDR,
                cameraRaw = photo.isCameraRawHDR,
                proRAW = photo.hdrSource?.isProRAW == true,
            )
        }.getOrElse {
            mutable.value = current.copy(error = strings.text(R.string.hdr_unsupported))
            return
        }
        if (enabled && photo.isCameraRawHDR) preflightHDRCamera(photo, current, candidate) else session.actions.edit(candidate, false, false)
    }

    fun applyHDRCameraDevelopment(development: HDRCameraDevelopmentSettings) {
        val current = mutable.value
        val photo = current.photo ?: return
        val hdr = current.edits.hdr ?: return
        if (!current.edits.isHDREditing || !photo.isCameraRawHDR || photo.hdrSource?.isProRAW == true ||
            !current.controlsEnabled || current.draft != null || current.importingHDRCameraProfile ||
            cameraHDRPreflightPending || development == hdr.cameraSettings
        ) return
        preflightHDRCamera(photo, current, current.edits.copy(hdr = hdr.withCameraDevelopment(development)))
    }

    fun changeHDRCameraDraft(settings: HDRCameraDevelopmentSettings) {
        val current = mutable.value
        val photo = current.photo ?: return
        val baseline = current.edits.hdr?.cameraSettings ?: return
        if (!current.controlsEnabled || current.importingHDRCameraProfile || !current.edits.isHDREditing) return
        mutable.value = current.copy(hdrCameraDraft = HDRCameraPanelDraft(photo.identity, baseline, settings))
    }

    fun beginHDRCameraProfileImport(): Boolean {
        val current = mutable.value
        if (!current.controlsEnabled || !current.edits.isHDREditing || current.draft != null || current.rendering ||
            current.importingHDRCameraProfile || pendingHDRCameraProfileImport != null ||
            current.photo?.isCameraRawHDR != true || current.photo.hdrSource?.isProRAW == true
        ) return false
        pendingHDRCameraProfileImport = session.sourceRevision to session.editRevision
        return true
    }

    fun finishHDRCameraProfileImport(uri: Uri?) {
        val revision = pendingHDRCameraProfileImport
        pendingHDRCameraProfileImport = null
        if (uri == null || revision == null) return
        if (revision != (session.sourceRevision to session.editRevision)) {
            mutable.value = mutable.value.copy(message = strings.text(R.string.hdr_camera_profile_changed))
            return
        }
        mutable.value = mutable.value.copy(importingHDRCameraProfile = true, error = null)
        scope.launch {
            try {
                val imported = readHDRCameraProfile(
                    { withContext(ioDispatcher) { deps.hdrCameraProfileImporter(uri) } },
                    { revision == (session.sourceRevision to session.editRevision) && mutable.value.controlsEnabled },
                )
                if (session.disposed) return@launch
                imported.onSuccess { profile ->
                    val current = mutable.value
                    val photo = current.photo ?: return@onSuccess
                    val baseline = current.edits.hdr?.cameraSettings ?: return@onSuccess
                    val draft = HDRCameraPanelDraft(photo.identity, baseline, current.hdrCameraDraftSettings ?: baseline)
                    mutable.value = current.copy(hdrCameraDraft = draft.withProfile(profile))
                }.onFailure {
                    if (it is AdjustmentOperationExpiredException)
                        mutable.value = mutable.value.copy(message = strings.text(R.string.hdr_camera_profile_changed))
                    else mutable.value = mutable.value.copy(error = strings.text(R.string.hdr_camera_profile_invalid))
                }
            } finally {
                if (!session.disposed) mutable.value = mutable.value.copy(importingHDRCameraProfile = false)
            }
        }
    }

    private fun preflightHDRCamera(photo: ImportedPhoto, current: EditorState, candidate: EditSettings) {
        // Preserve the committed frame and saved settings until decoding succeeds.
        mutable.value = current.copy(rendering = true, error = null)
        session.actions.submitRender(
            Work.CameraHDRPreflight(
                photo,
                current.edits,
                candidate,
                session.gpuMode(),
                session.sourceRevision,
                session.previewLongEdge,
            ),
        )
    }
}
