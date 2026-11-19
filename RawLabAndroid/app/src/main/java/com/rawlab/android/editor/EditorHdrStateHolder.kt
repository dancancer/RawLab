package com.rawlab.android.editor

import android.net.Uri
import com.rawlab.android.R
import com.rawlab.android.adjustments.AdjustmentField
import com.rawlab.android.adjustments.AdjustmentPayload
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
import com.rawlab.android.settings.HDRCameraProfile
import com.rawlab.android.settings.HDRLookSettings
import com.rawlab.android.settings.withHDRMode
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

internal class EditorHdrStateHolder(
    private val mutable: MutableStateFlow<EditorState>,
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher,
    private val strings: EditorStrings,
    private val hdrLookDirectory: () -> File,
    private val importHDRLook: (Uri) -> HDRLookSettings,
    private val installHDRSilver: () -> HDRLookSettings,
    private val loadHDRSilverMaster: () -> AdjustmentPayload,
    private val importHDRCameraProfile: (Uri) -> HDRCameraProfile,
    private val isDisposed: () -> Boolean,
    private val currentSourceRevision: () -> Long,
    private val currentEditRevision: () -> Long,
    private val currentDraftRevision: () -> Long,
    private val currentPreviewLongEdge: () -> Int,
    private val gpuMode: () -> Int,
    private val onEdit: (EditSettings) -> Unit,
    private val onSubmitPreflight: (Work.CameraHDRPreflight) -> Unit,
) {
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
            currentSourceRevision() == request.sourceRevision &&
            current.edits == request.before &&
            current.operation == Operation.NONE &&
            current.draft == null
        ) {
            onEdit(request.edits)
        }
    }

    fun beginHDRLookImport(): Boolean {
        val current = mutable.value
        if (!current.controlsEnabled || !current.edits.isHDREditing ||
            (current.draft != null && current.draft.group != AdjustmentGroup.LOOK)
        ) return false
        pendingHDRLookImport = Triple(currentSourceRevision(), currentEditRevision(), currentDraftRevision())
        return true
    }

    fun finishHDRLookImport(uri: Uri?) {
        val expected = pendingHDRLookImport
        pendingHDRLookImport = null
        if (uri == null || expected != Triple(currentSourceRevision(), currentEditRevision(), currentDraftRevision())) return
        applyHDRLook { _, target -> target.copy(hdr = target.hdr!!.withLook(importHDRLook(uri))) }
    }

    fun applyHDRSilver(master: Boolean) = applyHDRLook { photo, target ->
        val look = installHDRSilver()
        if (master) {
            val payload = loadHDRSilverMaster()
            require(payload[AdjustmentField.HDR_LOOK]?.hdrLook() == look)
            AdjustmentTransfer.prepare(
                payload,
                target,
                AdjustmentTransferContext(
                    photo.identity.value,
                    photo.inputKind == PhotoInputKind.RAW,
                    sourceSupportsCameraHDR = photo.isCameraRawHDR,
                    sourceIsProRAW = photo.hdrSource?.isProRAW == true,
                    hdrLookDirectory = hdrLookDirectory(),
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
        val expected = Triple(currentSourceRevision(), currentEditRevision(), currentDraftRevision())
        mutable.value = current.copy(operation = Operation.IMPORT_LOOK, error = null, importingHDRLook = true)
        val job = scope.launch(start = CoroutineStart.LAZY) {
            val self = coroutineContext[Job]
            runHDRLookImport(
                { withContext(ioDispatcher) { prepare(photo, current.visibleEdits) } },
                {
                    expected == Triple(currentSourceRevision(), currentEditRevision(), currentDraftRevision()) &&
                        mutable.value.operation == Operation.IMPORT_LOOK
                },
            ) { imported ->
                // 返回键已放弃本次导入时，迟到的结果不再改动界面。
                if (isDisposed() || hdrLookJob !== self) return@runHDRLookImport
                hdrLookJob = null
                mutable.value = finishedHDRLook(imported)
                imported.onSuccess { settings -> onEdit(settings) }
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
        if (enabled && photo.isCameraRawHDR) preflightHDRCamera(photo, current, candidate) else onEdit(candidate)
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
        pendingHDRCameraProfileImport = currentSourceRevision() to currentEditRevision()
        return true
    }

    fun finishHDRCameraProfileImport(uri: Uri?) {
        val revision = pendingHDRCameraProfileImport
        pendingHDRCameraProfileImport = null
        if (uri == null || revision == null) return
        if (revision != (currentSourceRevision() to currentEditRevision())) {
            mutable.value = mutable.value.copy(message = strings.text(R.string.hdr_camera_profile_changed))
            return
        }
        mutable.value = mutable.value.copy(importingHDRCameraProfile = true, error = null)
        scope.launch {
            try {
                val imported = readHDRCameraProfile(
                    { withContext(ioDispatcher) { importHDRCameraProfile(uri) } },
                    { revision == (currentSourceRevision() to currentEditRevision()) && mutable.value.controlsEnabled },
                )
                if (isDisposed()) return@launch
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
                if (!isDisposed()) mutable.value = mutable.value.copy(importingHDRCameraProfile = false)
            }
        }
    }

    private fun preflightHDRCamera(photo: ImportedPhoto, current: EditorState, candidate: EditSettings) {
        // Preserve the committed frame and saved settings until decoding succeeds.
        mutable.value = current.copy(rendering = true, error = null)
        onSubmitPreflight(
            Work.CameraHDRPreflight(
                photo,
                current.edits,
                candidate,
                gpuMode(),
                currentSourceRevision(),
                currentPreviewLongEdge(),
            ),
        )
    }
}
