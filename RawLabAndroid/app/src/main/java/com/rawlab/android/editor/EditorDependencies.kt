package com.rawlab.android.editor

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import android.content.pm.ApplicationInfo
import android.graphics.Bitmap
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.rawlab.android.adjustments.AdjustmentPayload
import com.rawlab.android.analytics.UsageAnalytics
import com.rawlab.android.analytics.UsageEvent
import com.rawlab.android.analytics.setup.UsageAnalyticsRegistry
import com.rawlab.android.editor.render.EditorRenderer
import com.rawlab.android.editor.render.ExportDestinationCleanup
import com.rawlab.android.editor.render.LookResult
import com.rawlab.android.editor.render.LookWork
import com.rawlab.android.editor.render.PreviewPair
import com.rawlab.android.editor.render.RenderCancellation
import com.rawlab.android.editor.render.Work
import com.rawlab.android.editor.render.WorkResult
import com.rawlab.android.editor.render.runLookWork
import com.rawlab.android.editor.render.uncroppedGeometrySize
import com.rawlab.android.editor.storage.EditorEditStore
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.looks.MasterRecipe
import com.rawlab.android.photo.EditedPhotoPreviews
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.HDRCameraProfile
import com.rawlab.android.settings.HDRLookSettings
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import java.io.File

internal class EditorStrings(
    val text: (Int) -> String = AppStrings::text,
    val format: (Int, Array<out Any>) -> String = { id, arguments -> AppStrings.format(id, *arguments) },
)

internal interface EditorRenderGateway {
    fun perform(work: Work, cancellation: RenderCancellation): WorkResult
    fun setExportProgressListener(listener: ((Work.Export, Float) -> Unit)?) = Unit
    fun releaseDecodedRaster()
    fun close()
}

internal class DefaultEditorRenderGateway(val renderer: EditorRenderer) : EditorRenderGateway {
    override fun perform(work: Work, cancellation: RenderCancellation): WorkResult = renderer.perform(work, cancellation)
    override fun setExportProgressListener(listener: ((Work.Export, Float) -> Unit)?) {
        renderer.onExportProgress = listener ?: { _, _ -> }
    }
    override fun releaseDecodedRaster() = renderer.releaseDecodedRaster()
    override fun close() = renderer.close()
}

internal interface EditorPreviewCacheSink {
    fun setForegroundBusy(owner: String, busy: Boolean)
    suspend fun accept(photo: ImportedPhoto, edits: EditSettings, image: Bitmap)
    fun close()
}

internal class DefaultEditorPreviewCacheSink(application: Application) : EditorPreviewCacheSink {
    private val previews by lazy { EditedPhotoPreviews(application) }

    override fun setForegroundBusy(owner: String, busy: Boolean) =
        EditedPhotoPreviews.setForegroundBusy(owner, busy)

    override suspend fun accept(photo: ImportedPhoto, edits: EditSettings, image: Bitmap) =
        previews.accept(photo, edits, image)

    override fun close() = previews.close()
}

/** 按显式参与方清单追踪存储释放，只有全部登记节点都释放后才关闭共享 PhotoStorage（P3-32）。 */
internal class StorageReleaseManifest(
    participants: Set<String>,
    private val onReleaseAll: () -> Unit,
) {
    init {
        require(participants.isNotEmpty()) { "Storage release manifest must contain at least one participant" }
    }

    private val expected = participants.toSet()
    private val remaining = participants.toMutableSet()
    private var closed = false

    @Synchronized
    fun release(participant: String): Boolean {
        if (participant !in expected) return false
        remaining.remove(participant)
        if (remaining.isEmpty() && !closed) {
            closed = true
            onReleaseAll()
            return true
        }
        return false
    }

    fun releaserFor(participant: String): () -> Unit {
        require(participant in expected) { "Unknown storage release participant: $participant" }
        return { release(participant) }
    }

    @Synchronized
    fun pendingCount(): Int = remaining.size

    @Synchronized
    fun isReleased(): Boolean = closed
}

internal class EditorDependencies(
    val storage: PhotoStorage,
    val editStore: EditorEditStore,
    val draftStore: EditorDraftStore,
    val presetStoreFactory: () -> com.rawlab.android.presets.AdjustmentPresetStore,
    val renderGateway: EditorRenderGateway,
    val renderer: EditorRenderer? = null,
    val previewCache: EditorPreviewCacheSink,
    val exportCleanup: ExportDestinationCleanup,
    val strings: EditorStrings = EditorStrings(),
    val scope: CoroutineScope? = null,
    val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    val mainDelivery: (() -> Unit) -> Unit,
    val uptimeMillis: () -> Long = SystemClock::uptimeMillis,
    val lookPreferencesFactory: () -> SharedPreferences,
    val systemPhotoPreferencesFactory: () -> SharedPreferences,
    val usageFactory: () -> UsageAnalytics,
    val recordUsage: (UsageEvent) -> Unit = { usageFactory().record(it) },
    val batchProcessorFactory: (Int, File?) -> NativeProcessor = { mode, database -> NativeProcessor(mode, database) },
    val migrationProcessorFactory: (Int, File?) -> NativeProcessor = batchProcessorFactory,
    val masterRecipesLoader: () -> List<MasterRecipe>,
    val lookWorkRunner: (LookWork) -> LookResult = { runLookWork(storage, it) },
    val hdrLookImporter: (Uri) -> HDRLookSettings = { storage.importHDRLook(it) },
    val hdrSilverInstaller: () -> HDRLookSettings = { storage.installHDRSilver() },
    val hdrSilverMasterLoader: () -> AdjustmentPayload = { storage.hdrSilverMaster() },
    val hdrCameraProfileImporter: (Uri) -> HDRCameraProfile = { storage.importHDRCameraProfile(it) },
    val adjustmentPreparationRunner: ((AdjustmentPreparationWork, () -> Boolean) -> AdjustmentPreparationResult)? = null,
    val uncroppedGeometrySize: (PreviewPair, GeometrySettings) -> Pair<Int, Int> = { pair, geometry ->
        pair.uncroppedGeometrySize(geometry).let { it[0] to it[1] }
    },
    val previewResizedDelayMs: Long = 200L,
    val detailDebounceDelayMs: Long = 0L,
    val detailOverscanRing: Int = 1,
    val saveNoticeFadeDelayMs: Long = 3000L,
    val sourceValidator: (com.rawlab.android.photo.ImportedPhoto) -> () -> Unit =
        EditorAdjustmentHistory.Companion::sourceValidation,
    val parseSystemPhotoUri: (String) -> Uri = Uri::parse,
    val retainSystemPhoto: ((Uri) -> Uri)? = null,
    val curveSampler: (com.rawlab.android.settings.ToneCurveSettings, com.rawlab.android.settings.ToneCurveChannel) -> List<com.rawlab.android.settings.ToneCurvePoint> = { settings, channel ->
        com.rawlab.android.engine.ToneCurveSampling.samples(settings, channel)
    },
    val curveParametricSampler: (com.rawlab.android.settings.ToneCurveSettings, Double) -> Double = { settings, x ->
        com.rawlab.android.engine.ToneCurveSampling.sampleParametricValue(settings, x)
    },
) {
    companion object {
        fun production(
            application: Application,
            editStoreFactory: (File) -> EditStore = { EditStore(it) },
            batchProcessorFactory: (Int, File?) -> NativeProcessor = { mode, database -> NativeProcessor(mode, database) },
        ): EditorDependencies {
            val storage = PhotoStorage(application)
            val editStore = EditorEditStore(File(application.filesDir, "edits"), editStoreFactory)
            val draftStore = EditorDraftStore(File(application.filesDir, "editor-draft"))
            val debuggable = (application.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
            val renderer = EditorRenderer(storage, { if (editStore.available) editStore.readState(it) else null }, debuggable)
            val mainHandler = Handler(Looper.getMainLooper())
            val usageLazy = lazy(LazyThreadSafetyMode.SYNCHRONIZED) { UsageAnalyticsRegistry.get(application) }
            return EditorDependencies(
                storage = storage,
                editStore = editStore,
                draftStore = draftStore,
                presetStoreFactory = { com.rawlab.android.presets.AdjustmentPresetStore(File(application.filesDir, "presets")) },
                renderGateway = DefaultEditorRenderGateway(renderer),
                renderer = renderer,
                previewCache = DefaultEditorPreviewCacheSink(application),
                exportCleanup = ExportDestinationCleanup { destination, original ->
                    storage.deleteIncompleteDocument(destination, original)
                },
                strings = EditorStrings(),
                scope = null,
                ioDispatcher = Dispatchers.IO,
                mainDelivery = { action -> mainHandler.post(action) },
                uptimeMillis = SystemClock::uptimeMillis,
                lookPreferencesFactory = { application.getSharedPreferences("look-browser", Context.MODE_PRIVATE) },
                systemPhotoPreferencesFactory = { application.getSharedPreferences("system-photo-requests", Context.MODE_PRIVATE) },
                usageFactory = { usageLazy.value },
                batchProcessorFactory = batchProcessorFactory,
                migrationProcessorFactory = batchProcessorFactory,
                masterRecipesLoader = { MasterRecipe.load(application) },
                lookWorkRunner = { runLookWork(storage, it) },
                hdrLookImporter = storage::importHDRLook,
                hdrSilverInstaller = storage::installHDRSilver,
                hdrSilverMasterLoader = storage::hdrSilverMaster,
                hdrCameraProfileImporter = storage::importHDRCameraProfile,
            )
        }
    }
}
