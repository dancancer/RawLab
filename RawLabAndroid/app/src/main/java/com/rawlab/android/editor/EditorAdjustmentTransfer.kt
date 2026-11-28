package com.rawlab.android.editor

import android.content.Context
import android.net.Uri
import com.rawlab.android.R
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.settings.AdjustmentOperationExpiredException
import com.rawlab.android.settings.AdjustmentHistoryOrderException
import com.rawlab.android.settings.PhotoChangedException
import com.rawlab.android.settings.AdjustmentNotReadyException
import com.rawlab.android.adjustments.*
import com.rawlab.android.editor.storage.EditorEditStore
import com.rawlab.android.engine.LensInfo
import com.rawlab.android.engine.NativeHDRBridge
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.looks.MasterRecipe
import com.rawlab.android.photo.HDRSourceInfo
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.photo.SystemPhotoStorageFull
import com.rawlab.android.photo.WorkingCopyStorageFull
import com.rawlab.android.raster.RasterImageDecoder
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.requireHDRDecodeVersion
import com.rawlab.android.settings.PhotoIdentity
import java.io.IOException
import java.io.File
import java.util.UUID

data class EditorAdjustmentHistoryRequest(val transactionID: UUID, val photo: PhotoIdentity?, val undo: Boolean)
data class EditorAdjustmentTransferState(val preparing: Boolean = false, val prepared: PreparedAdjustmentTransfer? = null,
    val results: List<AdjustmentOutcome> = emptyList(), val historyRequest: EditorAdjustmentHistoryRequest? = null,
    val historyResults: List<AdjustmentOutcome> = emptyList(), val error: String? = null)
internal data class AdjustmentPreparationWork(val generation: UUID, val payload: AdjustmentPayload, val uris: List<Uri>,
    val currentPhoto: ImportedPhoto?, val isCurrent: (String) -> Boolean,
    val action: AdjustmentHistoryTransaction.Action = AdjustmentHistoryTransaction.Action.PASTE,
    val collectionPhotos: Map<String, ImportedPhoto> = emptyMap(), val validateCollection: ((String) -> Unit)? = null)
internal data class AdjustmentPreparationResult(val generation: UUID, val operation: PreparedAdjustmentTransfer, val ownedFiles: Map<String, File>)

internal val EditorState.adjustmentTransferFields: Set<AdjustmentField> get() = if (edits.isHDREditing) {
    AdjustmentField.hdrTransferFields(photo?.let { it.isCameraRawHDR && it.hdrSource?.isProRAW == false } == true)
} else AdjustmentField.entries.filterNot { it.isHDROnly }.toSet()

internal interface AdjustmentPreflightProbe {
    fun preflightImportSpace(uris: Iterable<Uri>)
    fun validateHdrMetadata(file: File, source: HDRSourceInfo, settings: EditSettings): HDRSourceInfo
    fun validateHdrCameraDevelopment(
        file: File,
        source: HDRSourceInfo,
        candidate: EditSettings,
        lookDirectory: File,
        profileDirectory: File,
        database: File,
    )
    fun validateRasterMetadata(file: File)
    fun validateRawMetadata(file: File, photo: ImportedPhoto, settings: EditSettings)
    fun resolveCameraWhiteBalance(file: File, settings: EditSettings, database: File): Pair<Float, Float>?
    fun inspectLens(file: File, settings: EditSettings, inputKind: PhotoInputKind, database: File): LensInfo
}

internal class NativeAdjustmentPreflightProbe(private val storage: PhotoStorage) : AdjustmentPreflightProbe {
    override fun preflightImportSpace(uris: Iterable<Uri>) {
        storage.preflightImportSpace(uris)
    }

    override fun validateHdrMetadata(file: File, source: HDRSourceInfo, settings: EditSettings): HDRSourceInfo {
        val info = NativeHDRBridge.cameraFraming(file, source, settings.processing.version)
        settings.requireHDRDecodeVersion(info.isProRAW)
        return info
    }

    override fun validateHdrCameraDevelopment(
        file: File,
        source: HDRSourceInfo,
        candidate: EditSettings,
        lookDirectory: File,
        profileDirectory: File,
        database: File,
    ) {
        val info = NativeHDRBridge.cameraFraming(file, source, candidate.processing.version)
        val hdr = requireNotNull(candidate.hdr)
        NativeProcessor(NativeProcessor.CPU, database).use { native ->
            native.decodeHDRCamera(file, info, 128, camera = hdr.cameraSettings, profileDirectory = profileDirectory).use { decoded ->
                native.renderHDR(decoded, hdr, 128, lookDirectory = lookDirectory).close()
            }
        }
    }

    override fun validateRasterMetadata(file: File) {
        RasterImageDecoder.validateMetadata(file)
    }

    override fun validateRawMetadata(file: File, photo: ImportedPhoto, settings: EditSettings) {
        NativeHDRBridge.probeCameraRaw(file, settings.processing.version)
        if (photo.isX3f) NativeProcessor.x3fDefaultMode(file)
    }

    override fun resolveCameraWhiteBalance(file: File, settings: EditSettings, database: File): Pair<Float, Float>? =
        NativeProcessor(NativeProcessor.CPU, database).use { native ->
            native.resolveCameraWhiteBalance(file, settings, PhotoInputKind.RAW)
        }

    override fun inspectLens(file: File, settings: EditSettings, inputKind: PhotoInputKind, database: File): LensInfo =
        NativeProcessor(NativeProcessor.CPU, database).use { native ->
            native.inspectLens(file, settings, inputKind)
        }
}

/** 与普通渲染一样在串行资源队列执行；每个 native processor 在该目标预检结束时释放。 */
internal class EditorAdjustmentPreparation(
    private val context: Context,
    private val storage: PhotoStorage,
    private val store: EditorEditStore,
    private val loadRecipes: () -> List<MasterRecipe> = { MasterRecipe.load(context) },
    private val probe: AdjustmentPreflightProbe = NativeAdjustmentPreflightProbe(storage),
    private val importPhoto: (Uri) -> ImportedPhoto = storage::import,
    private val lensDatabaseProvider: () -> File = storage::lensDatabase,
    private val sourceValidation: (ImportedPhoto) -> () -> Unit = EditorAdjustmentHistory::sourceValidation,
    private val historySourceValidation: (ImportedPhoto) -> () -> Unit = EditorAdjustmentHistory::historySourceValidation,
) {
    fun prepare(work: AdjustmentPreparationWork, isCancelled: () -> Boolean = { false }): AdjustmentPreparationResult = synchronized(storage) {
        fun checkActive() { if (isCancelled()) throw java.util.concurrent.CancellationException() }
        checkActive()
        val session = store.adjustmentSession ?: throw IOException("Edit store is unavailable; reload saved adjustments")
        val builtin = storage.builtinLookIDs()
        val recipes = loadRecipes()
        val available = builtin.keys.map { "builtin:$it" }.toSet() +
            storage.looks().filter { it.managed && it.available }.map { it.id } +
            recipes.map { "recipe:${it.id}" }
        val distinctUris = work.uris.distinct()
        val unretainedUris = distinctUris.filter { uri ->
            val id = uri.toString()
            work.collectionPhotos[id] == null && work.currentPhoto?.identity?.value != id
        }
        if (unretainedUris.isNotEmpty()) {
            probe.preflightImportSpace(unretainedUris)
        }
        val owned = mutableMapOf<String, File>()
        try {
            val targets = distinctUris.map { uri ->
                checkActive()
                val identity = PhotoIdentity(uri.toString())
                var displayName = uri.lastPathSegment ?: identity.value
                try {
                    val photo = work.collectionPhotos[identity.value]
                        ?: work.currentPhoto?.takeIf { it.identity == identity }
                        ?: importPhoto(uri).also { owned[identity.value] = it.file }
                    displayName = photo.name
                    val sourceValidator = sourceValidation(photo)
                    work.validateCollection?.invoke(identity.value)
                    sourceValidator()
                    checkActive()
                    val validate = sourceValidator
                    val isX3f = photo.inputKind == PhotoInputKind.RAW &&
                        com.rawlab.android.format.PhotoFiles.isX3fInput(photo.file, photo.name)
                    val saved = store.readState(identity).repairLegacyNormalX3f(isX3f)
                    val targetDefaults = saved.settings ?: photo.defaultEditSettings()
                    val neutral = EditSettings(processing = targetDefaults.processing, x3fMode = targetDefaults.x3fMode)
                    val database by lazy { lensDatabaseProvider() }
                    if (saved.settings?.isHDREditing == true) {
                        val source = photo.hdrSource ?: throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, "hdr.source")
                        probe.validateHdrMetadata(photo.file, source, saved.settings)
                    } else if (photo.inputKind == PhotoInputKind.RASTER) {
                        if (photo.hdrSource == null) probe.validateRasterMetadata(photo.file)
                    } else {
                        probe.validateRawMetadata(photo.file, photo, targetDefaults)
                    }
                    checkActive()
                    var wbProbed = false
                    var cachedWb: Pair<Float, Float>? = null
                    val wbProvider: (() -> Pair<Float, Float>?)? = if (photo.inputKind == PhotoInputKind.RAW && saved.settings?.isHDREditing != true) {
                        {
                            if (!wbProbed) {
                                checkActive()
                                cachedWb = probe.resolveCameraWhiteBalance(photo.file, targetDefaults, database)
                                wbProbed = true
                                checkActive()
                            }
                            cachedWb
                        }
                    } else null
                    val transferContext = AdjustmentTransferContext(identity.value, photo.inputKind == PhotoInputKind.RAW,
                        available, builtin,
                        sourceSupportsCameraHDR = photo.isCameraRawHDR, sourceIsProRAW = photo.hdrSource?.isProRAW == true,
                        hdrLookDirectory = storage.hdrLookDirectory,
                        validateHDRCamera = { candidate ->
                            checkActive()
                            sourceValidator()
                            val source = photo.hdrSource?.takeIf { it.isCameraRaw && !it.isProRAW }
                                ?: throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, "hdr.camera_development")
                            probe.validateHdrCameraDevelopment(
                                photo.file,
                                source,
                                candidate,
                                storage.hdrLookDirectory,
                                storage.hdrCameraProfileDirectory,
                                database,
                            )
                            checkActive()
                        },
                        recipeTintDefaults = recipes.associate { it.id to it.tint },
                        validateLens = { request ->
                            checkActive()
                            val report = probe.inspectLens(photo.file, neutral.copy(lens = request), photo.inputKind, database)
                            checkActive()
                            if ((request.distortion && !report.appliedDistortion) ||
                                (request.tca && !report.appliedTca) ||
                                (request.vignetting && !report.appliedVignetting))
                                throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE, "target lens calibration unavailable")
                        },
                        cameraWhiteBalanceProvider = wbProvider)
                    AdjustmentTransferTarget(identity, displayName,
                        targetDefaults, transferContext,
                        isCurrent = { work.isCurrent(identity.value) }, validateSource = validate,
                        validateHistorySource = historySourceValidation(photo), isX3f = isX3f)
                } catch (error: java.util.concurrent.CancellationException) { throw error }
                  catch (error: Exception) {
                    owned.remove(identity.value)?.delete()
                    AdjustmentTransferTarget(identity, displayName, EditSettings(), AdjustmentTransferContext(identity.value, true),
                        isCurrent = { work.isCurrent(identity.value) }, validateSource = { throw error })
                }
            }
            checkActive()
            val operation = session.prepare(work.payload, targets, work.action, ::checkActive)
            checkActive()
            AdjustmentPreparationResult(work.generation, operation, owned.toMap())
        } catch (error: Throwable) { owned.values.forEach(File::delete); throw error }
    }
}

internal fun adjustmentErrorMessage(error: Throwable?, strings: EditorStrings = EditorStrings()): String {
    if (error is com.rawlab.android.settings.UnusableEditRecordException) {
        return com.rawlab.android.editor.storage.EditSaveResult(EditSaveState.FAILED, error, reading = true).formatMessage(strings)
            ?: strings.text(R.string.transfer_error)
    }
    return strings.text(when {
        error is WorkingCopyStorageFull || error is SystemPhotoStorageFull -> R.string.system_open_storage_full
        error is PhotoChangedException -> R.string.collection_source_changed
        error is AdjustmentHistoryOrderException -> R.string.transfer_history_order_message
        error is AdjustmentOperationExpiredException -> R.string.transfer_conflict_message
        error is AdjustmentNotReadyException -> R.string.transfer_draft_message
        error is AdjustmentTransferException -> when (error.reason) {
            AdjustmentFailure.EMPTY_SCOPE -> R.string.transfer_empty_scope
            AdjustmentFailure.DRAFT -> R.string.transfer_draft_message
            AdjustmentFailure.MISSING_LOOK -> R.string.transfer_missing_look
            AdjustmentFailure.UNREPRESENTABLE -> R.string.transfer_unrepresentable
            AdjustmentFailure.INCOMPATIBLE -> R.string.transfer_incompatible
            AdjustmentFailure.INVALID_PAYLOAD, AdjustmentFailure.UNSUPPORTED_VERSION -> R.string.transfer_invalid_payload
        }
        else -> R.string.transfer_error
    })
}
