package com.rawlab.android.editor

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import android.content.pm.ApplicationInfo
import android.graphics.Bitmap
import android.net.TestUri
import android.net.Uri
import com.rawlab.android.R
import com.rawlab.android.adjustments.AdjustmentPayload
import com.rawlab.android.analytics.UsageAnalytics
import com.rawlab.android.analytics.UsageConsentStore
import com.rawlab.android.analytics.UsageInstallId
import com.rawlab.android.analytics.UnavailableUsageTransport
import com.rawlab.android.editor.render.ExportDestinationCleanup
import com.rawlab.android.editor.render.LookResult
import com.rawlab.android.editor.render.LookWork
import com.rawlab.android.editor.render.PreviewPair
import com.rawlab.android.editor.render.RenderCancellation
import com.rawlab.android.editor.render.Work
import com.rawlab.android.editor.render.WorkResult
import com.rawlab.android.editor.render.runLookWork
import com.rawlab.android.editor.storage.EditorEditStore
import com.rawlab.android.engine.LookFormat
import com.rawlab.android.engine.LookValidation
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.looks.DcpCompiler
import com.rawlab.android.looks.DcpImportChoices
import com.rawlab.android.looks.LookValidator
import com.rawlab.android.looks.MasterRecipe
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.HDRCameraProfile
import com.rawlab.android.settings.HDRLookSettings
import com.rawlab.android.settings.PhotoIdentity
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import org.junit.Assert.assertTrue
import java.io.File
import java.nio.file.Files
import java.util.concurrent.Callable
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

internal class InMemorySharedPreferences : SharedPreferences {
    private val data = ConcurrentHashMap<String, Any?>()
    val commitCalls = AtomicInteger()
    val applyCalls = AtomicInteger()

    @Synchronized
    override fun getAll(): MutableMap<String, *> = HashMap(data)

    override fun getString(key: String?, defValue: String?): String? =
        (data[key] as? String) ?: defValue

    @Suppress("UNCHECKED_CAST")
    override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? =
        (data[key] as? Set<String>)?.toMutableSet() ?: defValues

    override fun getInt(key: String?, defValue: Int): Int = (data[key] as? Int) ?: defValue
    override fun getLong(key: String?, defValue: Long): Long = (data[key] as? Long) ?: defValue
    override fun getFloat(key: String?, defValue: Float): Float = (data[key] as? Float) ?: defValue
    override fun getBoolean(key: String?, defValue: Boolean): Boolean = (data[key] as? Boolean) ?: defValue
    override fun contains(key: String?): Boolean = key != null && data.containsKey(key)

    override fun edit(): SharedPreferences.Editor = object : SharedPreferences.Editor {
        private val pending = LinkedHashMap<String, Any?>()
        private var clearAll = false

        override fun putString(key: String?, value: String?): SharedPreferences.Editor = apply {
            if (key != null) pending[key] = value
        }

        override fun putStringSet(key: String?, values: MutableSet<String>?): SharedPreferences.Editor = apply {
            if (key != null) pending[key] = values?.toSet()
        }

        override fun putInt(key: String?, value: Int): SharedPreferences.Editor = apply {
            if (key != null) pending[key] = value
        }

        override fun putLong(key: String?, value: Long): SharedPreferences.Editor = apply {
            if (key != null) pending[key] = value
        }

        override fun putFloat(key: String?, value: Float): SharedPreferences.Editor = apply {
            if (key != null) pending[key] = value
        }

        override fun putBoolean(key: String?, value: Boolean): SharedPreferences.Editor = apply {
            if (key != null) pending[key] = value
        }

        override fun remove(key: String?): SharedPreferences.Editor = apply {
            if (key != null) pending[key] = REMOVED
        }

        override fun clear(): SharedPreferences.Editor = apply { clearAll = true }

        private fun flush() {
            synchronized(this@InMemorySharedPreferences) {
                if (clearAll) data.clear()
                for ((k, v) in pending) {
                    if (v === REMOVED || v == null) data.remove(k) else data[k] = v
                }
            }
        }

        override fun commit(): Boolean {
            commitCalls.incrementAndGet()
            flush()
            return true
        }

        override fun apply() {
            applyCalls.incrementAndGet()
            flush()
        }
    }

    override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit
    override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit

    private companion object {
        val REMOVED = Any()
    }
}

internal class TestEditorApplication(private val root: File) : Application() {
    val filesDirectory = File(root, "files").apply { mkdirs() }
    val cacheDirectory = File(root, "cache").apply { mkdirs() }
    val sharedPrefsMap = ConcurrentHashMap<String, InMemorySharedPreferences>()
    val getSharedPreferencesCalls = CopyOnWriteArrayList<String>()
    val getSharedPreferencesThreadCalls = CopyOnWriteArrayList<Pair<String, String>>()

    override fun getFilesDir(): File = filesDirectory
    override fun getCacheDir(): File = cacheDirectory
    override fun getApplicationContext(): Context = this
    override fun getApplicationInfo(): ApplicationInfo = ApplicationInfo().apply { flags = 0 }
    override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
        getSharedPreferencesCalls += name
        getSharedPreferencesThreadCalls += name to Thread.currentThread().name
        return sharedPrefsMap.getOrPut(name) { InMemorySharedPreferences() }
    }
}

internal object TestBitmaps {
    private val unsafePair: Pair<Any, java.lang.reflect.Method> by lazy {
        val unsafeClass = Class.forName("sun.misc.Unsafe")
        val field = unsafeClass.getDeclaredField("theUnsafe").apply { isAccessible = true }
        val instance = field.get(null)!!
        val allocate = unsafeClass.getMethod("allocateInstance", Class::class.java)
        instance to allocate
    }

    fun stub(): Bitmap = unsafePair.second.invoke(unsafePair.first, Bitmap::class.java) as Bitmap

    fun pair(
        width: Int = 800,
        height: Int = 600,
        temperature: Float = 5500f,
        tint: Float = 2f,
        renderedGeometry: GeometrySettings = GeometrySettings(),
    ): PreviewPair = PreviewPair(
        neutral = stub(),
        result = stub(),
        temperature = temperature,
        tint = tint,
        comparisonWidth = width.toFloat(),
        comparisonHeight = height.toFloat(),
        originalAspect = width.toFloat() / height,
        renderedGeometry = renderedGeometry,
        nativeWidth = width,
        nativeHeight = height,
    )
}

internal class FakeRenderGateway(
    private val handler: (Work, RenderCancellation) -> WorkResult,
) : EditorRenderGateway {
    val performed = CopyOnWriteArrayList<Work>()
    val releaseDecodedRasterCalls = AtomicInteger()
    val closeCalls = AtomicInteger()

    override fun perform(work: Work, cancellation: RenderCancellation): WorkResult {
        performed += work
        return handler(work, cancellation)
    }

    override fun releaseDecodedRaster() {
        releaseDecodedRasterCalls.incrementAndGet()
    }

    override fun close() {
        closeCalls.incrementAndGet()
    }
}

internal class FakePreviewCacheSink : EditorPreviewCacheSink {
    val busyEvents = CopyOnWriteArrayList<Boolean>()
    val accepted = CopyOnWriteArrayList<Pair<PhotoIdentity, EditSettings>>()
    val closeCalls = AtomicInteger()

    override fun setForegroundBusy(owner: String, busy: Boolean) {
        busyEvents += busy
    }

    override suspend fun accept(photo: ImportedPhoto, edits: EditSettings, image: Bitmap) {
        accepted += photo.identity to edits
    }

    override fun close() {
        closeCalls.incrementAndGet()
    }
}

internal class EditorViewModelTestHarness : AutoCloseable {
    val root: File = Files.createTempDirectory("rawlab-vm-jvm").toFile()
    val app = TestEditorApplication(root)
    val mainExecutor = Executors.newSingleThreadExecutor { Thread(it, "test-vm-main") }
    private val mainThreadRef = AtomicInteger(0)
    @Volatile private var mainThread: Thread? = null
    val mainDispatcher: CoroutineDispatcher = mainExecutor.asCoroutineDispatcher()
    val ioExecutor = Executors.newSingleThreadExecutor { Thread(it, "test-vm-io") }
    val ioDispatcher: CoroutineDispatcher = ioExecutor.asCoroutineDispatcher()
    val scope = CoroutineScope(SupervisorJob() + mainDispatcher)
    val previewCache = FakePreviewCacheSink()
    val uptime = AtomicLong(10_000L)
    val deletedIncompleteExports = CopyOnWriteArrayList<Pair<Uri, Uri?>>()
    val usageConsent = object : UsageConsentStore {
        private var enabled = false
        override fun load(): Boolean = enabled
        override fun save(enabled: Boolean) { this.enabled = enabled }
    }
    val usageInstallId = object : UsageInstallId {
        override fun obtain(): String = "00000000-0000-4000-8000-000000000001"
        override fun delete() = Unit
    }

    val testLookValidator = LookValidator { file ->
        val text = file.readText()
        if ("LUT_3D_SIZE" in text) LookValidation(LookFormat.CUBE, 0)
        else throw IllegalArgumentException("Invalid look: ${file.name}")
    }
    val testDcpCompiler = DcpCompiler { _, _, _, _ -> throw UnsupportedOperationException("No DCP in JVM test") }

    init {
        mainExecutor.submit { mainThread = Thread.currentThread() }.get(5, TimeUnit.SECONDS)
    }

    fun createStorage(): PhotoStorage = PhotoStorage(
        context = app,
        looksDirectory = File(app.filesDirectory, "looks"),
        lookValidator = testLookValidator,
        dcpCompiler = testDcpCompiler,
        bundledFilms = emptyList(),
    )

    fun createDependencies(
        storage: PhotoStorage = createStorage(),
        editStoreFactory: (File) -> EditStore = { EditStore(it) },
        renderHandler: (Work, RenderCancellation) -> WorkResult = { work, _ -> defaultRender(work) },
        renderGateway: EditorRenderGateway = FakeRenderGateway(renderHandler),
        lookWorkRunner: (LookWork) -> LookResult = { runLookWork(storage, it) },
        masterRecipesLoader: () -> List<MasterRecipe> = { emptyList() },
        hdrLookImporter: (Uri) -> HDRLookSettings = { throw UnsupportedOperationException() },
        hdrSilverInstaller: () -> HDRLookSettings = { throw UnsupportedOperationException() },
        hdrSilverMasterLoader: () -> AdjustmentPayload = { throw UnsupportedOperationException() },
        hdrCameraProfileImporter: (Uri) -> HDRCameraProfile = { throw UnsupportedOperationException() },
        previewResizeDelayMs: Long = 50L,
        saveNoticeFadeDelayMs: Long = 5_000L,
    ): EditorDependencies {
        val editStore = EditorEditStore(File(app.filesDirectory, "edits"), editStoreFactory)
        val draftStore = EditorDraftStore(File(app.filesDirectory, "editor-draft"))
        val usageLazy = lazy { UsageAnalytics(usageConsent, usageInstallId, UnavailableUsageTransport) }
        return EditorDependencies(
            storage = storage,
            editStore = editStore,
            draftStore = draftStore,
            presetStoreFactory = { com.rawlab.android.presets.AdjustmentPresetStore(File(app.filesDirectory, "presets")) },
            renderGateway = renderGateway,
            renderer = null,
            previewCache = previewCache,
            exportCleanup = ExportDestinationCleanup(scope) { destination, original ->
                deletedIncompleteExports += destination to original
            },
            strings = EditorStrings(
                text = { id ->
                    when (id) {
                        R.string.export_done -> "Export complete"
                        R.string.message_cancelled -> "Cancelled"
                        R.string.look_unavailable -> "Look unavailable"
                        else -> "str:$id"
                    }
                },
                format = { id, args -> "fmt:$id:${args.joinToString(",")}" },
            ),
            scope = scope,
            ioDispatcher = ioDispatcher,
            mainDelivery = { action -> mainExecutor.execute(action) },
            uptimeMillis = { uptime.get() },
            lookPreferencesFactory = { app.getSharedPreferences("look-browser", Context.MODE_PRIVATE) },
            systemPhotoPreferencesFactory = { app.getSharedPreferences("system-photo-requests", Context.MODE_PRIVATE) },
            usageFactory = { usageLazy.value },
            recordUsage = { usageLazy.value.record(it) },
            batchProcessorFactory = { mode, db -> NativeProcessor(mode, db) },
            migrationProcessorFactory = { mode, db -> NativeProcessor(mode, db) },
            masterRecipesLoader = masterRecipesLoader,
            lookWorkRunner = lookWorkRunner,
            hdrLookImporter = hdrLookImporter,
            hdrSilverInstaller = hdrSilverInstaller,
            hdrSilverMasterLoader = hdrSilverMasterLoader,
            hdrCameraProfileImporter = hdrCameraProfileImporter,
            uncroppedGeometrySize = { pair, _ -> pair.nativeWidth to pair.nativeHeight },
            previewResizedDelayMs = previewResizeDelayMs,
            saveNoticeFadeDelayMs = saveNoticeFadeDelayMs,
            sourceValidator = { photo -> { check(photo.file.isFile) } },
            parseSystemPhotoUri = { raw ->
                val parsed = java.net.URI(raw)
                TestUri.of(parsed.path ?: raw, scheme = parsed.scheme ?: "file", authority = parsed.authority ?: "")
            },
            retainSystemPhoto = { it },
        )
    }

    fun defaultRender(work: Work, editStoreDir: File = File(app.filesDirectory, "edits")): WorkResult = when (work) {
        is Work.Import -> {
            val file = work.retained?.file ?: File(work.uri.path ?: error("missing path"))
            val photo = work.retained ?: ImportedPhoto(
                work.uri,
                file.name,
                file,
                PhotoIdentity(work.uri.toString()),
                PhotoInputKind.RAW,
                validateOriginal = { check(file.isFile) },
            )
            val record = runCatching { EditStore(editStoreDir).readState(photo.identity) }.getOrNull()
            val edits = record?.settings ?: EditSettings()
            WorkResult.Preview(
                Work.Preview(
                    photo, edits, false, work.gpuMode,
                    importing = true, restored = record?.settings != null, importedRecord = record,
                    persistOnImport = work.x3fModeOverride != null, ownsImportedInput = false,
                ),
                TestBitmaps.pair(1600, 1200),
            )
        }
        is Work.Preview -> WorkResult.Preview(work, TestBitmaps.pair(work.edge, (work.edge * 3) / 4))
        is Work.HslProbe -> WorkResult.HslProbe(work, com.rawlab.android.settings.HslTargetSample.unavailable(work.revision, com.rawlab.android.settings.HslTargetAvailability.FAILED))
        is Work.CameraHDRPreflight -> WorkResult.CameraHDRPreflight(work)
        is Work.Export -> WorkResult.Export
        is Work.AutoExposure -> WorkResult.AutoExposure(work, work.edits.exposure + 0.5f)
    }

    fun createViewModel(
        storage: PhotoStorage = createStorage(),
        editStoreFactory: (File) -> EditStore = { EditStore(it) },
        renderHandler: (Work, RenderCancellation) -> WorkResult = { work, _ -> defaultRender(work) },
        renderGateway: EditorRenderGateway = FakeRenderGateway(renderHandler),
        lookWorkRunner: (LookWork) -> LookResult = { runLookWork(storage, it) },
        masterRecipesLoader: () -> List<MasterRecipe> = { emptyList() },
        hdrLookImporter: (Uri) -> HDRLookSettings = { throw UnsupportedOperationException() },
        hdrCameraProfileImporter: (Uri) -> HDRCameraProfile = { throw UnsupportedOperationException() },
        previewResizeDelayMs: Long = 50L,
    ): EditorViewModel = onMain {
        EditorViewModel(
            app,
            createDependencies(
                storage = storage,
                editStoreFactory = editStoreFactory,
                renderHandler = renderHandler,
                renderGateway = renderGateway,
                lookWorkRunner = lookWorkRunner,
                masterRecipesLoader = masterRecipesLoader,
                hdrLookImporter = hdrLookImporter,
                hdrCameraProfileImporter = hdrCameraProfileImporter,
                previewResizeDelayMs = previewResizeDelayMs,
            ),
        )
    }

    fun <T> onMain(block: () -> T): T {
        if (Thread.currentThread() === mainThread) return block()
        return mainExecutor.submit(Callable(block)).get(10, TimeUnit.SECONDS)
    }

    fun drainMain() = onMain { }

    fun awaitState(model: EditorViewModel, timeoutMs: Long = 10_000L, predicate: (EditorState) -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (onMain { predicate(model.state.value) }) return
            Thread.sleep(15)
        }
        val latest = onMain { model.state.value }
        assertTrue("Timed out waiting for EditorState; latest=$latest", predicate(latest))
    }

    fun createTempPhoto(name: String = "photo.raw"): Pair<File, Uri> {
        val file = File(root, name).apply { writeText("raw-content-$name") }
        return file to TestUri.of("/${file.absolutePath.trimStart('/')}", scheme = "file", authority = "")
    }

    fun syntheticCube(name: String = "look.cube"): File = File(root, name).apply {
        writeText(
            """
            #Gamma:F-Log2 to Synthetic Look
            #Gamut:F-Gamut to ITU-R BT.709
            LUT_3D_SIZE 2
            DOMAIN_MIN 0 0 0
            DOMAIN_MAX 1 1 1
            0 0 0
            1 0 0
            0 1 0
            1 1 0
            0 0 1
            1 0 1
            0 1 1
            1 1 1
            """.trimIndent() + "\n",
        )
    }

    override fun close() {
        scope.cancel()
        mainExecutor.shutdownNow()
        ioExecutor.shutdownNow()
        root.deleteRecursively()
    }
}
