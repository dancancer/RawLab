package com.rawlab.android.photo

import com.rawlab.android.editor.TestBitmaps
import com.rawlab.android.editor.TestEditorApplication
import com.rawlab.android.editor.render.EditorRenderer
import com.rawlab.android.editor.render.HDRPreviewFrame
import com.rawlab.android.editor.render.RenderCancellation
import com.rawlab.android.editor.render.Work
import com.rawlab.android.editor.render.WorkResult
import com.rawlab.android.engine.NativeFrame
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.engine.RgbHistogram
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.*
import com.rawlab.android.geometry.GeometrySettings
import android.net.TestUri
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class EditedPhotoPreviewTest {
    @Test fun savedDefaultsAndResetHaveNoMarker() {
        assertFalse(EditedPhotoPreviewKey.isEdited(null, PhotoInputKind.RAW))
        assertFalse(EditedPhotoPreviewKey.isEdited(EditSettings(), PhotoInputKind.RAW))
        assertFalse(EditedPhotoPreviewKey.isEdited(EditSettings(exposureMode = 2), PhotoInputKind.RASTER))
        assertTrue(EditedPhotoPreviewKey.isEdited(EditSettings(exposure = .5f), PhotoInputKind.RAW))
        assertTrue(EditedPhotoPreviewKey.isEdited(EditSettings(geometry = GeometrySettings(quarterTurns = 1)), PhotoInputKind.RAW))
        assertTrue(PhotoEditFilter.EDITED.includes(true))
        assertFalse(PhotoEditFilter.UNEDITED.includes(null))
        assertTrue(PhotoEditFilter.ALL.includes(null))
    }
    @Test fun cacheUsesSourceSettingsResourcesAndSize() {
        val settings = EditSettings(exposure = .5f)
        val key = EditedPhotoPreviewKey.create("source-a", settings, "look-a")
        assertEquals(key, EditedPhotoPreviewKey.create("source-a", settings.copy(), "look-a"))
        assertNotEquals(key, EditedPhotoPreviewKey.create("source-b", settings, "look-a"))
        assertNotEquals(key, EditedPhotoPreviewKey.create("source-a", settings.copy(exposure = 1f), "look-a"))
        assertNotEquals(key, EditedPhotoPreviewKey.create("source-a", settings, "look-b"))
        assertNotEquals(key, EditedPhotoPreviewKey.create("source-a", settings, "look-a", edge = 128))
        val root = Files.createTempDirectory("rawlab-preview-cache").toFile()
        try {
            val cache = EditedPhotoPreviewCache(root, maximumEntries = 2, maximumBytes = 5)
            cache.write(key, jpegBytes(1))
            assertArrayEquals(jpegBytes(1), EditedPhotoPreviewCache(root).read(key))
            val next = EditedPhotoPreviewKey.create("source-b", settings, "look-a")
            cache.write(next, jpegBytes(2))
            assertNull(cache.read(key)); assertNotNull(cache.read(next))
            cache.write(key, ByteArray(10)); assertNull(cache.read(key))
        } finally { root.deleteRecursively() }
    }
    @Test fun cacheUsesLruIndexWithoutReEnumeratingDirectory() {
        val root = Files.createTempDirectory("rawlab-preview-lru").toFile()
        try {
            var listCalls = 0
            var readCalls = 0
            val storage = HashMap<String, ByteArray>()
            val fakeFs = object : PreviewCacheFileSystem {
                override fun listEntries(directory: File): List<PreviewCacheEntry> {
                    listCalls++
                    return emptyList()
                }
                override fun readBytes(file: File): ByteArray? {
                    readCalls++
                    return storage[file.name]
                }
                override fun writeAtomic(directory: File, target: File, data: ByteArray) {
                    storage[target.name] = data
                }
                override fun delete(file: File): Boolean = storage.remove(file.name) != null
            }
            val settings = EditSettings(exposure = .5f)
            val keyA = EditedPhotoPreviewKey.create("source-a", settings, "look-a")
            val keyB = EditedPhotoPreviewKey.create("source-b", settings, "look-a")
            val keyC = EditedPhotoPreviewKey.create("source-c", settings, "look-a")
            val cache = EditedPhotoPreviewCache(root, maximumEntries = 2, maximumBytes = 1024, fileSystem = fakeFs)
            cache.write(keyA, jpegBytes(1))
            cache.write(keyB, jpegBytes(2))
            assertEquals(1, listCalls)
            assertArrayEquals(jpegBytes(1), cache.read(keyA)) // touch keyA -> keyB becomes LRU
            assertEquals(1, readCalls)
            assertNull(cache.read(keyC)) // miss should not stat/read disk
            assertEquals(1, readCalls)
            cache.write(keyC, jpegBytes(3)) // evicts keyB without re-listing directory
            assertEquals(1, listCalls)
            assertNotNull(cache.read(keyA))
            assertNull(cache.read(keyB))
            assertNotNull(cache.read(keyC))
        } finally { root.deleteRecursively() }
    }
    @Test fun sharedCacheKeepsOneIndexAndEvictionBudgetPerDirectory() {
        val root = Files.createTempDirectory("rawlab-preview-shared").toFile()
        try {
            var listCalls = 0
            var readCalls = 0
            val storage = HashMap<String, ByteArray>()
            val fakeFs = object : PreviewCacheFileSystem {
                override fun listEntries(directory: File): List<PreviewCacheEntry> {
                    listCalls++
                    return storage.entries.map { PreviewCacheEntry(it.key.removeSuffix(".preview"), it.value.size.toLong(), 0) }
                }
                override fun readBytes(file: File): ByteArray? {
                    readCalls++
                    return storage[file.name]
                }
                override fun writeAtomic(directory: File, target: File, data: ByteArray) {
                    storage[target.name] = data
                }
                override fun delete(file: File): Boolean = storage.remove(file.name) != null
            }
            val settings = EditSettings(exposure = .5f)
            val keyA = EditedPhotoPreviewKey.create("source-a", settings, "look-a")
            val keyB = EditedPhotoPreviewKey.create("source-b", settings, "look-a")
            val keyC = EditedPhotoPreviewKey.create("source-c", settings, "look-a")
            val editor = EditedPhotoPreviewCache.shared(root, maximumEntries = 2, maximumBytes = 1024, fileSystem = fakeFs)
            val album = EditedPhotoPreviewCache.shared(root, maximumEntries = 2, maximumBytes = 1024, fileSystem = fakeFs)
            assertSame(editor, album)
            album.read(keyC) // 界面实例先建立索引（此刻目录为空）；编辑器实例之后的写入不能对其永久失明
            assertEquals(1, listCalls)
            editor.write(keyA, jpegBytes(1))
            assertArrayEquals(jpegBytes(1), album.read(keyA)) // A 写 B 读命中，只读盘一次，不触发重渲
            assertEquals(1, readCalls)
            editor.write(keyB, jpegBytes(2))
            album.write(keyC, jpegBytes(3)) // 共享索引执行预算：3 条只留 2 条，不会各实例一套上限（磁盘文件不翻倍）
            assertEquals(2, storage.size)
            assertNull(album.read(keyA))
            assertNotNull(editor.read(keyC))
        } finally { root.deleteRecursively() }
    }
    @Test fun truncatedJpegReadsAsMissAndIsOverwrittenAfterReRender() {
        val root = Files.createTempDirectory("rawlab-preview-truncated").toFile()
        try {
            val storage = HashMap<String, ByteArray>()
            val fakeFs = object : PreviewCacheFileSystem {
                override fun listEntries(directory: File): List<PreviewCacheEntry> =
                    storage.entries.map { PreviewCacheEntry(it.key.removeSuffix(".preview"), it.value.size.toLong(), 0) }
                override fun readBytes(file: File): ByteArray? = storage[file.name]
                override fun writeAtomic(directory: File, target: File, data: ByteArray) {
                    storage[target.name] = data
                }
                override fun delete(file: File): Boolean = storage.remove(file.name) != null
            }
            val settings = EditSettings(exposure = .5f)
            val key = EditedPhotoPreviewKey.create("source-a", settings, "look-a")
            val fileName = "$key.preview"
            val cache = EditedPhotoPreviewCache.shared(root, fileSystem = fakeFs)
            // 断电半写：SOI 头与部分扫描线已落盘，尾部扫描线与 EOI 缺失（BitmapFactory 会按 kIncompleteInput 返回非空残图）
            storage[fileName] = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0x11, 0x22, 0xFF.toByte(), 0xDA.toByte(), 0x33)
            assertNull(cache.read(key)) // SOI/EOI 不齐判未命中，残图不得当作缓存命中返回
            assertNull(storage[fileName]) // 坏条目已删除，为重渲的原子覆盖让位
            cache.write(key, jpegBytes(9)) // 重渲完成后原子覆盖
            assertArrayEquals(jpegBytes(9), cache.read(key)) // 再次读取为完整图
        } finally { root.deleteRecursively() }
    }
    @Test fun successfulSaveAndResetNotifyAllStoreInstances() = runBlocking {
        val root = Files.createTempDirectory("rawlab-preview-events").toFile()
        try {
            val store = EditStore(root)
            val changes = async(start = CoroutineStart.UNDISPATCHED) {
                EditStore.changes.filter { it.directory == root.canonicalPath }.take(2).toList()
            }
            val id = PhotoIdentity("photo")
            store.save(id, EditSettings(exposure = 1f))
            EditStore(root).reset(id)
            val result = withTimeout(2000) { changes.await() }
            assertEquals(1f, result[0].state.settings?.exposure)
            assertNull(result[1].state.settings)
        } finally { root.deleteRecursively() }
    }
    @Test fun thumbnailPreviewSkipsNeutralReferenceRenderForSdrAndGeometryEdits() {
        val root = Files.createTempDirectory("rawlab-thumb-sdr").toFile()
        try {
            val app = TestEditorApplication(root)
            val looksDir = File(root, "looks")
            val validator = com.rawlab.android.looks.LookValidator {
                com.rawlab.android.engine.LookValidation(com.rawlab.android.engine.LookFormat.CUBE, 0)
            }
            val storage = PhotoStorage(app, looksDir, lookValidator = validator, bundledFilms = emptyList())
            val cubeFile = File(root, "velvia-test.cube").apply {
                writeText("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n")
            }
            val managedLook = com.rawlab.android.looks.LookLibrary(looksDir, validator).importLook(cubeFile)
            val sourceFile = File(root, "photo.arw").apply { writeText("raw") }
            val photo = ImportedPhoto(TestUri.of("/1", authority = "photos"), "photo.arw", sourceFile, inputKind = PhotoInputKind.RAW)
            val edits = EditSettings(
                film = managedLook.id,
                exposure = 0.7f,
                geometry = GeometrySettings(cropWidth = 0.8f),
                lens = LensSettings(distortion = true),
            )
            val previewEdges = mutableListOf<Int>()
            val previewLutNames = mutableListOf<String?>()
            var neutralPreviewCalls = 0
            val engine = object : EditorRenderer.RenderEngine {
                override fun setGpuMode(mode: Int) = Unit
                override fun cancellationGeneration(): Long = 0L
                override fun cancelPreview() = Unit
                override fun releaseRasterCache() = Unit
                override fun preview(
                    input: File,
                    lut: File?,
                    settings: EditSettings,
                    edge: Int,
                    interactive: Boolean,
                    inputKind: PhotoInputKind,
                    cancellationGeneration: Long,
                ): NativeFrame {
                    previewEdges += edge
                    previewLutNames += lut?.name
                    if (lut == null && settings.film == "neutral") neutralPreviewCalls++
                    return NativeFrame(edge, edge, TestBitmaps.stub(), 5500f, 0f, NativeProcessor.CPU, IntArray(768))
                }
                override fun sampleHsl(input: File, lut: File?, settings: EditSettings, edge: Int, interactive: Boolean, inputKind: PhotoInputKind, revision: HslTargetRevision, x: Float, y: Float, cancellationGeneration: Long) = error("unused")
                override fun export(input: File, lut: File?, settings: EditSettings, output: File, format: ExportFormat, longEdge: Int?, inputKind: PhotoInputKind, cancellationGeneration: Long) = error("unused")
                override fun autoExposure(input: File, settings: EditSettings, inputKind: PhotoInputKind) = error("unused")
                override fun decodeHDRCamera(file: File, info: HDRSourceInfo, edge: Int, cancellationGeneration: Long, camera: HDRCameraDevelopmentSettings, profileDirectory: File?) = error("unused")
                override fun renderHDR(source: EditorRenderer.HdrImageHandle, settings: HDRSettings, edge: Int, cancellationGeneration: Long, lookDirectory: File?) = error("unused")
                override fun sampleHDRHsl(source: EditorRenderer.HdrImageHandle, settings: HDRSettings, edge: Int, revision: HslTargetRevision, x: Float, y: Float, cancellationGeneration: Long, lookDirectory: File?) = error("unused")
                override fun estimateHDRExposure(source: EditorRenderer.HdrImageHandle, settings: HDRSettings, cancellationGeneration: Long) = error("unused")
                override fun exportProRAW(file: File, info: HDRSourceInfo, edits: EditSettings, output: File, keepHDR: Boolean, edge: Int, cancellationGeneration: Long, lookDirectory: File?) = error("unused")
                override fun close() = Unit
            }
            val renderer = EditorRenderer(storage, { null }, false, engineFactory = { engine })
            val thumbWork = EditedPhotoPreviews.thumbnailPreviewWork(photo, edits)
            assertFalse(thumbWork.includeNeutral)
            assertEquals(EditedPhotoPreviewKey.EDGE, thumbWork.edge)
            val result = renderer.perform(thumbWork, RenderCancellation()) as WorkResult.Preview
            assertEquals(0, neutralPreviewCalls)
            assertEquals(listOf(EditedPhotoPreviewKey.EDGE), previewEdges)
            assertSame(result.pair.result, result.pair.neutral)

            // Editor path (default includeNeutral = true) still renders the 1600px neutral reference + transformed neutral.
            previewEdges.clear()
            renderer.perform(Work.Preview(photo, edits, false, NativeProcessor.AUTO, edge = EditedPhotoPreviewKey.EDGE), RenderCancellation())
            assertTrue("Editor preview must render 1600px neutral reference", neutralPreviewCalls >= 1 && 1600 in previewEdges)
            storage.close()
        } finally { root.deleteRecursively() }
    }

    @Test fun thumbnailPreviewSkipsNeutralReferenceRenderForHdr() {
        val root = Files.createTempDirectory("rawlab-thumb-hdr").toFile()
        try {
            val app = TestEditorApplication(root)
            val storage = PhotoStorage(app, File(root, "looks"), bundledFilms = Film.all.map { it.copy(file = null) })
            val sourceFile = File(root, "photo.jpg").apply { writeText("hdr") }
            val hdrInfo = HDRSourceInfo(
                width = 4000,
                height = 3000,
                orientation = 1,
                container = 1,
                protocol = 1,
                colorDescription = 1,
                contentHeadroom = 2f,
                headroomKind = 1,
                fingerprint = ByteArray(32) { 1 },
            )
            val photo = ImportedPhoto(TestUri.of("/hdr", authority = "photos"), "photo.jpg", sourceFile, inputKind = PhotoInputKind.RASTER, hdrSource = hdrInfo)
            val edits = EditSettings(exposure = 0.5f).withHDRMode(true, sourceIsHDR = true)
            var neutralHdrRenderCalls = 0
            var resultHdrRenderCalls = 0
            val fakeHdrHandle = object : EditorRenderer.HdrImageHandle {
                override val sourceInfo: HDRSourceInfo = hdrInfo
                override val outputNativeWidth: Int = 4000
                override val outputNativeHeight: Int = 3000
                override fun snapshot(): HDRPreviewFrame = HDRPreviewFrame(
                    2, 2, FloatArray(12), FloatArray(12), 2.0f, 2.0f, 4000, 3000,
                )
                override fun sdrBitmap() = TestBitmaps.stub()
                override fun close() = Unit
            }
            val fakeHdrBridge = object : EditorRenderer.HdrRenderBridge {
                override fun cameraFraming(file: File, info: HDRSourceInfo, processingVersion: Int): HDRSourceInfo = info
                override fun geometrySize(info: HDRSourceInfo, geometry: GeometrySettings): IntArray = intArrayOf(4000, 3000)
                override fun acquireCamera(file: File, info: HDRSourceInfo, edge: Int, camera: HDRCameraDevelopmentSettings?, lensDatabase: File?, decode: () -> EditorRenderer.HdrImageHandle) = error("unused")
                override fun acquireGainMap(file: File, info: HDRSourceInfo, edge: Int) = object : EditorRenderer.HdrSourceHandle {
                    override val image = fakeHdrHandle
                    override fun close() = Unit
                }
                override fun decodeGainMap(file: File, info: HDRSourceInfo, edge: Int) = fakeHdrHandle
                override fun exportJpeg(rendered: EditorRenderer.HdrImageHandle, metadataSource: File?, output: File) = Unit
                override fun exportSdr(rendered: EditorRenderer.HdrImageHandle, metadataSource: File?, output: File, format: Int) = Unit
                override fun clearCache() = Unit
            }
            val engine = object : EditorRenderer.RenderEngine {
                override fun setGpuMode(mode: Int) = Unit
                override fun cancellationGeneration(): Long = 0L
                override fun cancelPreview() = Unit
                override fun releaseRasterCache() = Unit
                override fun preview(input: File, lut: File?, settings: EditSettings, edge: Int, interactive: Boolean, inputKind: PhotoInputKind, cancellationGeneration: Long) = error("unused")
                override fun sampleHsl(input: File, lut: File?, settings: EditSettings, edge: Int, interactive: Boolean, inputKind: PhotoInputKind, revision: HslTargetRevision, x: Float, y: Float, cancellationGeneration: Long) = error("unused")
                override fun export(input: File, lut: File?, settings: EditSettings, output: File, format: ExportFormat, longEdge: Int?, inputKind: PhotoInputKind, cancellationGeneration: Long) = error("unused")
                override fun autoExposure(input: File, settings: EditSettings, inputKind: PhotoInputKind) = error("unused")
                override fun decodeHDRCamera(file: File, info: HDRSourceInfo, edge: Int, cancellationGeneration: Long, camera: HDRCameraDevelopmentSettings, profileDirectory: File?) = error("unused")
                override fun renderHDR(source: EditorRenderer.HdrImageHandle, settings: HDRSettings, edge: Int, cancellationGeneration: Long, lookDirectory: File?): EditorRenderer.HdrImageHandle {
                    if (lookDirectory == null) neutralHdrRenderCalls++ else resultHdrRenderCalls++
                    return fakeHdrHandle
                }
                override fun sampleHDRHsl(source: EditorRenderer.HdrImageHandle, settings: HDRSettings, edge: Int, revision: HslTargetRevision, x: Float, y: Float, cancellationGeneration: Long, lookDirectory: File?) = error("unused")
                override fun estimateHDRExposure(source: EditorRenderer.HdrImageHandle, settings: HDRSettings, cancellationGeneration: Long) = error("unused")
                override fun exportProRAW(file: File, info: HDRSourceInfo, edits: EditSettings, output: File, keepHDR: Boolean, edge: Int, cancellationGeneration: Long, lookDirectory: File?) = error("unused")
                override fun close() = Unit
            }
            val renderer = EditorRenderer(storage, { null }, false, engineFactory = { engine }, hdrBridge = fakeHdrBridge)
            val result = renderer.perform(EditedPhotoPreviews.thumbnailPreviewWork(photo, edits), RenderCancellation()) as WorkResult.Preview
            assertEquals(0, neutralHdrRenderCalls)
            assertEquals(1, resultHdrRenderCalls)
            assertNull(result.pair.hdr)

            // Editor path (includeNeutral = true) renders the neutral HDR reference too.
            renderer.perform(Work.Preview(photo, edits, false, NativeProcessor.AUTO, edge = EditedPhotoPreviewKey.EDGE), RenderCancellation())
            assertEquals(1, neutralHdrRenderCalls)
            assertEquals(2, resultHdrRenderCalls)
            storage.close()
        } finally { root.deleteRecursively() }
    }

    private fun jpegBytes(body: Int): ByteArray =
        byteArrayOf(0xFF.toByte(), 0xD8.toByte(), body.toByte(), 0xFF.toByte(), 0xD9.toByte())
}
