package com.rawlab.android.settings

import android.net.TestUri
import android.net.Uri
import com.rawlab.android.adjustments.*
import com.rawlab.android.batch.*
import com.rawlab.android.editor.*
import com.rawlab.android.editor.render.*
import com.rawlab.android.editor.storage.EditorEditStore
import com.rawlab.android.engine.LensInfo
import com.rawlab.android.engine.NativeFrame
import com.rawlab.android.engine.RgbHistogram
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.photo.HDRSourceInfo
import com.rawlab.android.photo.ImportedPhoto
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.UUID

class X3fLegacyRepairTest {
    private fun fileUri(file: File): Uri = TestUri.of(file.absolutePath, scheme = "file", authority = "")

    @Test fun collectionExportRepairsLegacyNormalX3fInMemoryWithoutWritingDisk() {
        val root = Files.createTempDirectory("android-x3f-collection").toFile()
        try {
            val editDir = File(root, "edits")
            val seedStore = EditStore(editDir)

            val x3fFile = File(root, "sigma.X3F").apply { writeText("FOVb-x3f") }
            val mislabeledFile = File(root, "mislabeled.raw").apply { writeText("FOVb-mislabeled") }
            val legacyX3fFile = File(root, "legacy.X3F").apply { writeText("FOVb-legacy") }
            val arwFile = File(root, "sony.ARW").apply { writeText("II*\u0000sony") }

            val brokenNormal = EditSettings(
                exposure = 0.5f,
                x3fMode = X3fMode.NORMAL,
                lens = LensSettings(
                    distortion = true,
                    tca = true,
                    autoCrop = false,
                    manual = true,
                    profileId = "sigma-35",
                    focalLength = 35f,
                    cropFactor = 1.5f,
                    vignetting = true,
                ),
            )
            val legacyX3f = brokenNormal.copy(x3fMode = X3fMode.LEGACY)

            val x3fTarget = BatchTarget(PhotoIdentity("x3f"), x3fFile, "sigma.X3F", inputKind = PhotoInputKind.RAW)
            val mislabeledTarget = BatchTarget(PhotoIdentity("mislabeled"), mislabeledFile, "mislabeled.raw", inputKind = PhotoInputKind.RAW)
            val legacyTarget = BatchTarget(PhotoIdentity("legacy"), legacyX3fFile, "legacy.X3F", inputKind = PhotoInputKind.RAW)
            val arwTarget = BatchTarget(PhotoIdentity("arw"), arwFile, "sony.ARW", inputKind = PhotoInputKind.RAW)

            seedStore.save(x3fTarget.identity, brokenNormal)
            seedStore.save(mislabeledTarget.identity, brokenNormal)
            seedStore.save(legacyTarget.identity, legacyX3f)
            seedStore.save(arwTarget.identity, brokenNormal)

            val propertiesFile = File(editDir, "edits.properties")
            val rawBefore = propertiesFile.readBytes()
            val store = EditStore(editDir)

            val selection = BatchSelectionState().append(listOf(x3fTarget, mislabeledTarget, legacyTarget, arwTarget))
            val exporter = BatchSelectionExport(File(root, "jobs"), store::readState, { null })
            val review = exporter.prepare(selection, emptySet(), ExportFormat.PNG, 1024, "out") {}
            assertTrue(review.ready)

            val x3fRow = review.rows[0]
            assertEquals(X3fMode.NORMAL, x3fRow.settings!!.x3fMode)
            assertFalse("Normal X3F collection export must clear lens flags", x3fRow.settings!!.lens.enabled)
            assertFalse(x3fRow.record!!.settings!!.lens.enabled)
            assertEquals("sigma-35", x3fRow.settings!!.lens.profileId)
            assertFalse(x3fRow.settings!!.lens.autoCrop)
            assertEquals(0.5f, x3fRow.settings!!.exposure)

            val mislabeledRow = review.rows[1]
            assertFalse("Mislabeled FOVb X3F collection export must clear lens flags", mislabeledRow.settings!!.lens.enabled)

            val legacyRow = review.rows[2]
            assertEquals("Legacy-mode X3F must stay untouched", legacyX3f, legacyRow.settings)

            val arwRow = review.rows[3]
            assertEquals("Non-X3F with normal x3fMode must stay untouched", brokenNormal, arwRow.settings)

            val job = exporter.freeze(selection, review) {}
            assertFalse(job.rows[0].target.frozen!!.settings.lens.enabled)
            assertFalse(job.rows[1].target.frozen!!.settings.lens.enabled)
            assertTrue(job.rows[2].target.frozen!!.settings.lens.enabled)
            assertTrue(job.rows[3].target.frozen!!.settings.lens.enabled)

            assertArrayEquals("Read-only collection export must leave edits.properties untouched", rawBefore, propertiesFile.readBytes())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test fun hdrBatchPreparationRepairsLegacyNormalX3fInMemoryWithoutWritingDisk() {
        val root = Files.createTempDirectory("android-x3f-hdr-batch").toFile()
        try {
            val editDir = File(root, "edits")
            val store = EditStore(editDir)
            val sourceFile = File(root, "source.dng").apply { writeText("hdr-source") }
            val x3fFile = File(root, "unopened.X3F").apply { writeText("FOVb-unopened") }

            val broken = EditSettings(
                exposure = 0.25f,
                x3fMode = X3fMode.NORMAL,
                lens = LensSettings(distortion = true, tca = true, vignetting = true, profileId = "sigma-45"),
            )
            val x3fTarget = BatchTarget(PhotoIdentity("x3f-hdr"), x3fFile, "unopened.X3F", inputKind = PhotoInputKind.RAW)
            store.save(x3fTarget.identity, broken)

            val propertiesFile = File(editDir, "edits.properties")
            val rawBefore = propertiesFile.readBytes()

            val hdrSource = BatchSourceSnapshot(
                PhotoIdentity("hdr-src"),
                sourceFile,
                EditSettings().withHDRMode(true, false, cameraRaw = true).let {
                    it.copy(hdr = it.hdr!!.copy(exposure = 0.5f))
                },
                displayName = "source.dng",
                inputKind = PhotoInputKind.RAW,
            )
            val hdrInfo = HDRSourceInfo(
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
            val prep = BatchHDRPreparation(
                source = hdrSource,
                readRecord = store::readState,
                resolveLook = { null },
                probeSource = { file, _ -> if (file == sourceFile) hdrInfo else null },
            )
            val frozen = prep.prepare(x3fTarget, 0, ExportFormat.JPEG, 512)
            assertEquals(X3fMode.NORMAL, frozen.settings.x3fMode)
            assertFalse("HDR batch target prep must clear legacy normal X3F lens flags", frozen.settings.lens.enabled)
            assertEquals("sigma-45", frozen.settings.lens.profileId)
            assertArrayEquals("Read-only HDR batch prep must not write edits.properties", rawBefore, propertiesFile.readBytes())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test fun pastePreflightRepairsUnopenedLegacyNormalX3fInMemory() {
        EditorViewModelTestHarness().use { harness ->
            val storage = harness.createStorage()
            val editDir = File(harness.root, "edits").apply { mkdirs() }
            val store = EditorEditStore(editDir)

            val sourceFile = File(harness.root, "source.ARW").apply { writeText("arw-source") }
            val x3fFile = File(harness.root, "unopened.X3F").apply { writeText("FOVb-unopened") }
            val x3fUri = fileUri(x3fFile)
            val x3fIdentity = PhotoIdentity(x3fUri.toString())

            val broken = EditSettings(
                exposure = 0.35f,
                x3fMode = X3fMode.NORMAL,
                lens = LensSettings(
                    distortion = true,
                    tca = true,
                    autoCrop = true,
                    manual = true,
                    profileId = "sigma-45",
                    focalLength = 45f,
                    cropFactor = 1.0f,
                    vignetting = true,
                ),
            )
            store.save(x3fIdentity, broken)
            val propertiesFile = File(editDir, "edits.properties")
            val rawBefore = propertiesFile.readBytes()

            var inspectLensCalls = 0
            val probe = object : AdjustmentPreflightProbe {
                override fun preflightImportSpace(uris: Iterable<Uri>) = Unit
                override fun validateHdrMetadata(file: File, source: HDRSourceInfo, settings: EditSettings) = source
                override fun validateHdrCameraDevelopment(file: File, source: HDRSourceInfo, candidate: EditSettings, lookDirectory: File, profileDirectory: File, database: File) = Unit
                override fun validateRasterMetadata(file: File) = Unit
                override fun validateRawMetadata(file: File, photo: ImportedPhoto, settings: EditSettings) = Unit
                override fun resolveCameraWhiteBalance(file: File, settings: EditSettings, database: File) = 5400f to 6f
                override fun inspectLens(file: File, settings: EditSettings, inputKind: PhotoInputKind, database: File): LensInfo {
                    inspectLensCalls++
                    return LensInfo(
                        state = LensInfo.STATE_OFF,
                        detectedLens = "",
                        selectedLens = "",
                        appliedDistortion = false,
                        appliedTca = false,
                        cropScale = 1f,
                        candidates = emptyList(),
                        appliedVignetting = false,
                    )
                }
            }

            val prep = EditorAdjustmentPreparation(
                context = harness.app,
                storage = storage,
                store = store,
                loadRecipes = { emptyList() },
                probe = probe,
                importPhoto = { uri -> ImportedPhoto(uri, x3fFile.name, x3fFile, x3fIdentity, PhotoInputKind.RAW) },
                lensDatabaseProvider = { File(harness.root, "lensdb").apply { mkdirs() } },
                sourceValidation = { {} },
                historySourceValidation = { {} },
            )

            val payload = AdjustmentTransfer.capture(
                AdjustmentScope.Custom(setOf(AdjustmentField.EXPOSURE, AdjustmentField.LENS_AUTO_CROP)),
                EditSettings(exposure = 0.9f, lens = LensSettings(autoCrop = false)),
                AdjustmentTransferContext(fileUri(sourceFile).toString(), true),
            )

            val result = prep.prepare(
                AdjustmentPreparationWork(
                    generation = UUID.randomUUID(),
                    payload = payload,
                    uris = listOf(x3fUri),
                    currentPhoto = null,
                    isCurrent = { true },
                ),
            )
            val target = result.operation.targets.single()
            assertNull("Pasting non-lens + lensAutoCrop onto unopened legacy normal X3F must succeed", target.error)
            assertEquals(0, inspectLensCalls)
            assertFalse(target.original!!.settings!!.lens.enabled)
            assertFalse(target.candidate!!.lens.enabled)
            assertFalse(target.candidate!!.lens.autoCrop)
            assertEquals("sigma-45", target.candidate!!.lens.profileId)
            assertEquals(0.9f, target.candidate!!.exposure)
            assertArrayEquals("Prepare must not mutate edits.properties on disk", rawBefore, propertiesFile.readBytes())

            val session = store.adjustmentSession!!
            val applied = session.apply(result.operation).single()
            assertEquals(AdjustmentStatus.APPLIED, applied.status)
            val undone = session.undoTransaction(result.operation.id).single()
            assertEquals(AdjustmentStatus.APPLIED, undone.status)
            assertFalse("Undoing paste restores repaired baseline without broken flags", undone.saved!!.settings!!.lens.enabled)
            assertEquals("sigma-45", undone.saved!!.settings!!.lens.profileId)
            assertEquals(0.35f, undone.saved!!.settings!!.exposure)
        }
    }

    @Test fun pureRepairClearsLensFlagsOnlyForNormalX3f() {
        for ((distortion, tca, vignetting) in listOf(
            Triple(true, false, false),
            Triple(false, true, false),
            Triple(false, false, true),
            Triple(true, true, true),
        )) {
            val broken = EditSettings(
                film = "provia",
                exposure = 0.25f,
                processing = ProcessingIdentity.C5,
                x3fMode = X3fMode.NORMAL,
                lens = LensSettings(
                    distortion = distortion,
                    tca = tca,
                    autoCrop = false,
                    manual = true,
                    profileId = "saved-lens-profile",
                    focalLength = 35f,
                    cropFactor = 1.5f,
                    vignetting = vignetting,
                ),
            )
            val repaired = broken.repairLegacyNormalX3f(isX3f = true)
            assertEquals(X3fMode.NORMAL, repaired.x3fMode)
            assertFalse(repaired.lens.enabled)
            assertFalse(repaired.lens.autoCrop)
            assertTrue(repaired.lens.manual)
            assertEquals("saved-lens-profile", repaired.lens.profileId)
            assertEquals(35f, repaired.lens.focalLength)
            assertEquals(1.5f, repaired.lens.cropFactor)
            assertEquals(0.25f, repaired.exposure)
            assertEquals("provia", repaired.film)
            assertEquals(ProcessingIdentity.C5, repaired.processing)
            assertEquals(repaired, repaired.repairLegacyNormalX3f(isX3f = true))

            assertEquals("Non-X3F normal record stays untouched", broken, broken.repairLegacyNormalX3f(isX3f = false))
            val legacy = broken.copy(x3fMode = X3fMode.LEGACY)
            assertEquals("Legacy X3F record stays untouched", legacy, legacy.repairLegacyNormalX3f(isX3f = true))
        }
    }

    @Test fun openWritebackRepairsOnceAndSupportsProcessingMigrationAndPreviewFlag() {
        val root = Files.createTempDirectory("android-x3f-open").toFile()
        try {
            val editDir = File(root, "edits")
            val seedStore = EditStore(editDir)
            val flagsId = PhotoIdentity("content://flags-only-x3f")
            val migrateId = PhotoIdentity("content://migrate-x3f")
            val legacyId = PhotoIdentity("content://legacy-x3f")
            val arwId = PhotoIdentity("content://arw-normal")

            val flagsBroken = EditSettings(
                x3fMode = X3fMode.NORMAL,
                lens = LensSettings(distortion = true, tca = true, vignetting = true),
            )
            val migrateBroken = EditSettings(
                processing = ProcessingIdentity.C5,
                exposure = 0.7f,
                x3fMode = X3fMode.NORMAL,
                lens = LensSettings(distortion = true, profileId = "sigma-35", autoCrop = false),
            )
            val legacyBroken = flagsBroken.copy(x3fMode = X3fMode.LEGACY)

            seedStore.save(flagsId, flagsBroken)
            seedStore.save(migrateId, migrateBroken)
            seedStore.save(legacyId, legacyBroken)
            seedStore.save(arwId, flagsBroken)

            // Thumbnail edited-state helper does not mark flags-only normal X3F as edited, while keeping legacy X3F / non-X3F edited.
            assertFalse(com.rawlab.android.photo.EditedPhotoPreviewKey.isEdited(flagsBroken, PhotoInputKind.RAW, isX3f = true))
            assertTrue(com.rawlab.android.photo.EditedPhotoPreviewKey.isEdited(migrateBroken, PhotoInputKind.RAW, isX3f = true))
            assertTrue(com.rawlab.android.photo.EditedPhotoPreviewKey.isEdited(legacyBroken, PhotoInputKind.RAW, isX3f = true))
            assertTrue(com.rawlab.android.photo.EditedPhotoPreviewKey.isEdited(flagsBroken, PhotoInputKind.RAW, isX3f = false))

            var writes = 0
            val store = EditStore(editDir) { from, to ->
                writes++
                com.rawlab.android.io.replaceFileAtomically(from, to)
            }

            // First open writes repaired flags-only X3F once; second open does 0 writes.
            val repairedFlags = store.repairLegacyNormalX3fOnOpen(flagsId, isX3f = true)
            assertEquals(1, writes)
            assertFalse(repairedFlags.settings!!.lens.enabled)
            assertEquals(repairedFlags, store.repairLegacyNormalX3fOnOpen(flagsId, isX3f = true))
            assertEquals(1, writes)

            // Legacy X3F and non-X3F do 0 writes on open.
            assertEquals(legacyBroken, store.repairLegacyNormalX3fOnOpen(legacyId, isX3f = true).settings)
            assertEquals(flagsBroken, store.repairLegacyNormalX3fOnOpen(arwId, isX3f = false).settings)
            assertEquals(1, writes)

            // Repaired v2 normal X3F commits processing migration and rollback restores repaired baseline.
            val repairedMigrate = store.repairLegacyNormalX3fOnOpen(migrateId, isX3f = true)
            assertEquals(2, writes)
            assertFalse(repairedMigrate.settings!!.lens.enabled)
            val migrated = store.commitProcessingMigration(
                repairedMigrate,
                repairedMigrate.settings!!.copy(processing = ProcessingIdentity.CURRENT, exposure = 1.1f),
                ProcessingMigrationQuality(0.002f, 0.01f, 0.004f, 0.003f, 8),
            )
            assertEquals(ProcessingIdentity.CURRENT, migrated.settings!!.processing)
            assertFalse(migrated.settings!!.lens.enabled)
            val rolledBack = store.rollbackProcessingMigration(migrated)
            assertEquals(repairedMigrate.settings, rolledBack.settings)
            assertFalse(rolledBack.settings!!.lens.enabled)

            // Uniform SDR batch target recognizes mislabeled FOVb X3F.
            val mislabeled = File(root, "mislabeled.jpeg").apply { writeText("FOVb-batch") }
            val mislabeledTarget = BatchTarget(PhotoIdentity("mislabeled-batch"), mislabeled, "mislabeled.jpeg", inputKind = PhotoInputKind.RAW)
            assertTrue(mislabeledTarget.isX3f)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test fun editorRendererImportAndRecoverSourceRepairLegacyNormalX3f() {
        EditorViewModelTestHarness().use { harness ->
            val storage = harness.createStorage()
            val editDir = File(harness.root, "edits").apply { mkdirs() }
            val store = EditorEditStore(editDir)
            val x3fFile = File(harness.root, "import-target.X3F").apply { writeText("FOVb-import") }
            val x3fUri = fileUri(x3fFile)
            val x3fId = PhotoIdentity(x3fUri.toString())
            val photo = ImportedPhoto(x3fUri, x3fFile.name, x3fFile, x3fId, PhotoInputKind.RAW)

            val broken = EditSettings(
                exposure = 0.4f,
                x3fMode = X3fMode.NORMAL,
                lens = LensSettings(distortion = true, tca = true, vignetting = true, profileId = "sigma-28"),
            )
            store.save(x3fId, broken)

            val observedSettings = mutableListOf<EditSettings>()
            val fakeEngine = object : EditorRenderer.RenderEngine {
                override fun close() = Unit
                override fun setGpuMode(mode: Int) = Unit
                override fun cancellationGeneration() = 0L
                override fun cancelPreview() = Unit
                override fun releaseRasterCache() = Unit
                override fun preview(input: File, lut: File?, settings: EditSettings, edge: Int, interactive: Boolean, inputKind: PhotoInputKind, cancellationGeneration: Long): NativeFrame {
                    observedSettings += settings
                    return NativeFrame(
                        width = 4,
                        height = 4,
                        backingBitmap = TestBitmaps.stub(),
                        temperature = 6500f,
                        tint = 0f,
                        backend = 0,
                    )
                }
                override fun sampleHsl(input: File, lut: File?, settings: EditSettings, edge: Int, interactive: Boolean, inputKind: PhotoInputKind, revision: HslTargetRevision, x: Float, y: Float, cancellationGeneration: Long) =
                    HslTargetSample.unavailable(revision, HslTargetAvailability.FAILED)
                override fun export(input: File, lut: File?, settings: EditSettings, output: File, format: ExportFormat, longEdge: Int?, inputKind: PhotoInputKind, cancellationGeneration: Long) = 0
                override fun autoExposure(input: File, settings: EditSettings, inputKind: PhotoInputKind) = 0f
                override fun decodeHDRCamera(file: File, info: HDRSourceInfo, edge: Int, cancellationGeneration: Long, camera: HDRCameraDevelopmentSettings, profileDirectory: File?) = error("unused")
                override fun renderHDR(source: EditorRenderer.HdrImageHandle, settings: HDRSettings, edge: Int, cancellationGeneration: Long, lookDirectory: File?) = error("unused")
                override fun sampleHDRHsl(source: EditorRenderer.HdrImageHandle, settings: HDRSettings, edge: Int, revision: HslTargetRevision, x: Float, y: Float, cancellationGeneration: Long, lookDirectory: File?) = error("unused")
                override fun estimateHDRExposure(source: EditorRenderer.HdrImageHandle, settings: HDRSettings, cancellationGeneration: Long) = 0f
                override fun exportProRAW(file: File, info: HDRSourceInfo, edits: EditSettings, output: File, keepHDR: Boolean, edge: Int, cancellationGeneration: Long, lookDirectory: File?) = Unit
            }

            val renderer = EditorRenderer(
                storage = storage,
                restore = { store.readState(it) },
                debuggable = false,
                engineFactory = { fakeEngine },
                repairOnOpen = { id, isX3f -> store.repairLegacyNormalX3fOnOpen(id, isX3f) },
            )
            val result = renderer.perform(Work.Import(x3fUri, 0, retained = photo, ownsRetained = false), RenderCancellation()) as WorkResult.Preview
            assertFalse("Import preview must render repaired normal X3F settings", result.request.edits.lens.enabled)
            assertEquals("sigma-28", result.request.edits.lens.profileId)
            assertTrue(observedSettings.all { !it.lens.enabled })
            assertFalse("Opening X3F photo in editor must write repaired record back to EditStore", store.readState(x3fId).settings!!.lens.enabled)

            // recoverSource also repairs a broken normal X3F record on disk.
            store.save(x3fId, broken)
            val history = EditorAdjustmentHistory(store, validateSource = { {} })
            history.acceptSource(photo, null)
            val recovered = history.recoverSource(photo)
            assertFalse(recovered.settings!!.lens.enabled)
            assertFalse(store.readState(x3fId).settings!!.lens.enabled)
        }
    }
}
