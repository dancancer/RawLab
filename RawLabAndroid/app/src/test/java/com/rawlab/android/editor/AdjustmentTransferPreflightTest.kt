package com.rawlab.android.editor

import android.net.TestUri
import android.net.Uri
import com.rawlab.android.R
import com.rawlab.android.adjustments.*
import com.rawlab.android.editor.storage.EditorEditStore
import com.rawlab.android.engine.LensInfo
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.photo.HDRSourceInfo
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.photo.SystemPhotoStorageFull
import com.rawlab.android.photo.WorkingCopyStorageFull
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.withHDRMode
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class AdjustmentTransferPreflightTest {
    private class FakeProbe : AdjustmentPreflightProbe {
        var preflightSpaceError: Throwable? = null
        val preflightSpaceBatches = mutableListOf<List<Uri>>()
        var validateHdrMetadataCalls = 0
        var validateHdrCameraDevelopmentCalls = 0
        var validateRasterMetadataCalls = 0
        var validateRawMetadataCalls = 0
        var resolveCameraWhiteBalanceCalls = 0
        var inspectLensCalls = 0
        var wbResult: Pair<Float, Float>? = 5400f to 6f
        var lensInfoResult: LensInfo = LensInfo(
            state = LensInfo.STATE_APPLIED,
            detectedLens = "FE 35mm F1.4 GM",
            selectedLens = "FE 35mm F1.4 GM",
            appliedDistortion = true,
            appliedTca = true,
            cropScale = 1f,
            candidates = emptyList(),
            appliedVignetting = true,
        )

        override fun preflightImportSpace(uris: Iterable<Uri>) {
            val list = uris.toList()
            preflightSpaceBatches += list
            preflightSpaceError?.let { throw it }
        }

        override fun validateHdrMetadata(file: File, source: HDRSourceInfo, settings: EditSettings): HDRSourceInfo {
            validateHdrMetadataCalls++
            return source
        }

        override fun validateHdrCameraDevelopment(
            file: File,
            source: HDRSourceInfo,
            candidate: EditSettings,
            lookDirectory: File,
            profileDirectory: File,
            database: File,
        ) {
            validateHdrCameraDevelopmentCalls++
        }

        override fun validateRasterMetadata(file: File) {
            validateRasterMetadataCalls++
        }

        override fun validateRawMetadata(file: File, photo: ImportedPhoto, settings: EditSettings) {
            validateRawMetadataCalls++
        }

        override fun resolveCameraWhiteBalance(file: File, settings: EditSettings, database: File): Pair<Float, Float>? {
            resolveCameraWhiteBalanceCalls++
            return wbResult
        }

        override fun inspectLens(file: File, settings: EditSettings, inputKind: PhotoInputKind, database: File): LensInfo {
            inspectLensCalls++
            return lensInfoResult
        }
    }

    private fun fileUri(file: File): Uri = TestUri.of(file.absolutePath, scheme = "file", authority = "")

    private fun hdrSource(): HDRSourceInfo = HDRSourceInfo(
        width = 1600,
        height = 1200,
        orientation = 1,
        container = HDRSourceInfo.CONTAINER_CAMERA_RAW,
        protocol = 0,
        colorDescription = 0,
        contentHeadroom = 4f,
        headroomKind = 1,
        fingerprint = ByteArray(32) { 1 },
        supportsBayerDevelopment = true,
    )

    @Test fun prepareChecksTotalImportSpaceBeforeImportingAnyUri() {
        EditorViewModelTestHarness().use { harness ->
            val storage = harness.createStorage()
            val store = EditorEditStore(File(harness.root, "edits").apply { mkdirs() })
            val probe = FakeProbe().apply { preflightSpaceError = WorkingCopyStorageFull() }
            var imports = 0
            val u1 = fileUri(File(harness.root, "one.dng"))
            val u2 = fileUri(File(harness.root, "two.dng"))
            val retainedFile = File(harness.root, "retained.dng").apply { writeText("raw") }
            val retainedUri = fileUri(retainedFile)
            val retainedPhoto = ImportedPhoto(retainedUri, "retained.dng", retainedFile)

            val prep = EditorAdjustmentPreparation(
                context = harness.app,
                storage = storage,
                store = store,
                loadRecipes = { emptyList() },
                probe = probe,
                importPhoto = { uri ->
                    imports++
                    ImportedPhoto(uri, "x.dng", File(harness.root, "x.dng"))
                },
                lensDatabaseProvider = { File(harness.root, "lensdb") },
                sourceValidation = { _: ImportedPhoto -> {} },
                historySourceValidation = { _: ImportedPhoto -> {} },
            )
            val payload = AdjustmentPayload(
                AdjustmentSource("src", true, 3),
                mapOf(AdjustmentField.EXPOSURE to AdjustmentValue.Number(0.5)),
            )
            val result = runCatching {
                prep.prepare(
                    AdjustmentPreparationWork(
                        generation = UUID.randomUUID(),
                        payload = payload,
                        uris = listOf(retainedUri, u1, u2, u1),
                        currentPhoto = null,
                        isCurrent = { true },
                        collectionPhotos = mapOf(retainedUri.toString() to retainedPhoto),
                    )
                )
            }
            assertTrue(result.exceptionOrNull() is WorkingCopyStorageFull)
            assertEquals("Total space preflight must fail before any URI import", 0, imports)
            assertEquals(listOf(listOf(u1, u2)), probe.preflightSpaceBatches)

            val strings = EditorStrings(
                text = { id -> "res:$id" },
                format = { id, args -> "res:$id:${args.joinToString()}" },
            )
            assertEquals(
                strings.text(R.string.system_open_storage_full),
                adjustmentErrorMessage(WorkingCopyStorageFull(), strings),
            )
            assertEquals(
                strings.text(R.string.system_open_storage_full),
                adjustmentErrorMessage(SystemPhotoStorageFull(), strings),
            )
        }
    }

    @Test fun nonWbPreflightUsesMetadataOnlyWithZeroWbOrHdrPixelDecodeCalls() {
        EditorViewModelTestHarness().use { harness ->
            val storage = harness.createStorage()
            val store = EditorEditStore(File(harness.root, "edits").apply { mkdirs() })
            val probe = FakeProbe()

            val rawFile = File(harness.root, "raw.dng").apply { writeText("raw") }
            val jpgFile = File(harness.root, "jpg.jpg").apply { writeText("jpg") }
            val hdrFile = File(harness.root, "hdr.dng").apply { writeText("hdr") }
            val rawPhoto = ImportedPhoto(fileUri(rawFile), "raw.dng", rawFile, inputKind = PhotoInputKind.RAW)
            val jpgPhoto = ImportedPhoto(fileUri(jpgFile), "jpg.jpg", jpgFile, inputKind = PhotoInputKind.RASTER)
            val hdrPhoto = ImportedPhoto(fileUri(hdrFile), "hdr.dng", hdrFile, inputKind = PhotoInputKind.RAW, hdrSource = hdrSource())
            store.save(hdrPhoto.identity, EditSettings().withHDRMode(true, sourceIsHDR = false, cameraRaw = true))

            val prep = EditorAdjustmentPreparation(
                context = harness.app,
                storage = storage,
                store = store,
                loadRecipes = { emptyList() },
                probe = probe,
                importPhoto = { error("unexpected import") },
                lensDatabaseProvider = { File(harness.root, "lensdb") },
                sourceValidation = { _: ImportedPhoto -> {} },
                historySourceValidation = { _: ImportedPhoto -> {} },
            )
            val payload = AdjustmentPayload(
                AdjustmentSource("src", true, 3),
                mapOf(AdjustmentField.EXPOSURE to AdjustmentValue.Number(0.5)),
            )
            val result = prep.prepare(
                AdjustmentPreparationWork(
                    generation = UUID.randomUUID(),
                    payload = payload,
                    uris = listOf(rawPhoto.uri, jpgPhoto.uri, hdrPhoto.uri),
                    currentPhoto = null,
                    isCurrent = { true },
                    collectionPhotos = listOf(rawPhoto, jpgPhoto, hdrPhoto).associateBy { it.identity.value },
                )
            )
            assertEquals(3, result.operation.targets.size)
            assertTrue("Targets must prepare cleanly: ${result.operation.targets.map { it.error }}",
                result.operation.targets.all { it.error == null })
            assertEquals(1, probe.validateRawMetadataCalls)
            assertEquals(1, probe.validateRasterMetadataCalls)
            assertEquals(1, probe.validateHdrMetadataCalls)
            assertEquals("Non-WB paste must not probe camera WB", 0, probe.resolveCameraWhiteBalanceCalls)
            assertEquals("Non-HDR-camera paste must not decode/render HDR pixels", 0, probe.validateHdrCameraDevelopmentCalls)
            assertEquals("Non-lens paste must not inspect lens", 0, probe.inspectLensCalls)
        }
    }

    @Test fun wbPasteLazilyProbesRawCameraWhiteBalanceOnceAndSkipsRaster() {
        EditorViewModelTestHarness().use { harness ->
            val storage = harness.createStorage()
            val store = EditorEditStore(File(harness.root, "edits").apply { mkdirs() })
            val probe = FakeProbe()

            val rawFile = File(harness.root, "raw.dng").apply { writeText("raw") }
            val jpgFile = File(harness.root, "jpg.jpg").apply { writeText("jpg") }
            val rawPhoto = ImportedPhoto(fileUri(rawFile), "raw.dng", rawFile, inputKind = PhotoInputKind.RAW)
            val jpgPhoto = ImportedPhoto(fileUri(jpgFile), "jpg.jpg", jpgFile, inputKind = PhotoInputKind.RASTER)
            // Target RAW uses a recipe where custom WB tint is relative to camera WB, so WB paste lazily probes once;
            // non-RAW target never probes camera WB.
            store.save(rawPhoto.identity, EditSettings(recipeID = "classic", tint = 5f))

            val prep = EditorAdjustmentPreparation(
                context = harness.app,
                storage = storage,
                store = store,
                loadRecipes = { emptyList() },
                probe = probe,
                importPhoto = { error("unexpected import") },
                lensDatabaseProvider = { File(harness.root, "lensdb") },
                sourceValidation = { _: ImportedPhoto -> {} },
                historySourceValidation = { _: ImportedPhoto -> {} },
            )
            val payload = AdjustmentPayload(
                AdjustmentSource("src", true, 3),
                mapOf<AdjustmentField, AdjustmentValue>(
                    AdjustmentField.WHITE_BALANCE_MODE to AdjustmentValue.Text("temperature"),
                    AdjustmentField.TEMPERATURE to AdjustmentValue.Number(6000.0),
                    AdjustmentField.TINT to AdjustmentValue.Number(8.0),
                ),
            )
            val result = prep.prepare(
                AdjustmentPreparationWork(
                    generation = UUID.randomUUID(),
                    payload = payload,
                    uris = listOf(rawPhoto.uri, jpgPhoto.uri),
                    currentPhoto = null,
                    isCurrent = { true },
                    collectionPhotos = mapOf(
                        rawPhoto.identity.value to rawPhoto,
                        jpgPhoto.identity.value to jpgPhoto,
                    ),
                )
            )
            assertEquals(2, result.operation.targets.size)
            assertNull("RAW target must prepare cleanly", result.operation.targets[0].error)
            assertEquals("WB paste probes camera WB once for RAW and skips RASTER", 1, probe.resolveCameraWhiteBalanceCalls)
            assertEquals(0, probe.validateHdrCameraDevelopmentCalls)
        }
    }

    @Test fun lensPasteInspectsLensViaMetadataProbeOnly() {
        EditorViewModelTestHarness().use { harness ->
            val storage = harness.createStorage()
            val store = EditorEditStore(File(harness.root, "edits").apply { mkdirs() })
            val probe = FakeProbe()

            val rawFile = File(harness.root, "raw.dng").apply { writeText("raw") }
            val rawPhoto = ImportedPhoto(fileUri(rawFile), "raw.dng", rawFile, inputKind = PhotoInputKind.RAW)

            val prep = EditorAdjustmentPreparation(
                context = harness.app,
                storage = storage,
                store = store,
                loadRecipes = { emptyList() },
                probe = probe,
                importPhoto = { error("unexpected import") },
                lensDatabaseProvider = { File(harness.root, "lensdb") },
                sourceValidation = { _: ImportedPhoto -> {} },
                historySourceValidation = { _: ImportedPhoto -> {} },
            )
            val payload = AdjustmentPayload(
                AdjustmentSource("src", true, 3),
                mapOf<AdjustmentField, AdjustmentValue>(
                    AdjustmentField.LENS_DISTORTION to AdjustmentValue.Boolean(true),
                    AdjustmentField.LENS_TCA to AdjustmentValue.Boolean(false),
                    AdjustmentField.LENS_VIGNETTING to AdjustmentValue.Boolean(false),
                ),
            )
            val result = prep.prepare(
                AdjustmentPreparationWork(
                    generation = UUID.randomUUID(),
                    payload = payload,
                    uris = listOf(rawPhoto.uri),
                    currentPhoto = null,
                    isCurrent = { true },
                    collectionPhotos = mapOf(rawPhoto.identity.value to rawPhoto),
                )
            )
            assertEquals(1, result.operation.targets.size)
            assertTrue("Target must prepare cleanly: ${result.operation.targets.map { it.error }}",
                result.operation.targets.all { it.error == null })
            assertEquals(1, probe.inspectLensCalls)
            assertEquals(0, probe.resolveCameraWhiteBalanceCalls)
            assertEquals(0, probe.validateHdrCameraDevelopmentCalls)
        }
    }
}
