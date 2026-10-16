package com.rawlab.android

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class BatchExportTest {
    @Test fun lensCodecPreservesAllDevelopmentFieldsAndLegacySnapshots() {
        val lens = LensSettings(true, true, false, true, "Maker\n镜头 Model,|\nMount\n1.000000")
        val settings = EditSettings(exposureMode = 2, hsl = HslSettings().withValue(1, 0, -60f),
            recipeID = "recipe", displayChromaDenoise = 2,
            effects = PhotoEffectsSettings(vignetteAmount = -40f, grainAmount = 65f), lens = lens,
            geometry = GeometrySettings(.2f, .1f, .8f, .75f, 3, true, true, -8.5f, -.7f, .25f))
        val fields = SettingsCodec.encode(settings).split('|')
        assertEquals(53, fields.size)
        assertEquals(settings, SettingsCodec.decode(fields.joinToString("|")))
        for (count in listOf(12, 16, 25, 50, 51, 52)) {
            val legacy = SettingsCodec.decode(fields.take(count).joinToString("|"))
            assertEquals(if (count == 52) lens else LensSettings(), legacy.lens)
            assertEquals(GeometrySettings(), legacy.geometry)
            if (count >= 25) assertEquals(settings.effects, legacy.effects)
            if (count >= 50) assertEquals(settings.hsl, legacy.hsl)
            if (count >= 51) assertEquals(settings.recipeID, legacy.recipeID)
        }
        assertEquals("", lens.copy(manual = false).coreProfileId)
        assertEquals("__rawlab_manual_selection_required__", LensSettings(manual = true).coreProfileId)
        assertEquals(LensSettings(), settings.reset().lens)
    }

    @Test fun exportFormatsKeepNativeValuesAndStorageContracts() {
        assertEquals(0, ExportFormat.JPEG.nativeValue)
        assertEquals(1, ExportFormat.PNG.nativeValue)
        assertEquals(4, ExportFormat.DNG.nativeValue)
        assertEquals(".jpg", ExportFormat.JPEG.suffix)
        assertEquals(".png", ExportFormat.PNG.suffix)
        assertEquals(".dng", ExportFormat.DNG.suffix)
        assertFalse(ExportFormat.DNG.allowsGallery)
        assertEquals(ExportFormat.DNG, ExportFormat.fromNativeValue(4))
        assertThrows(IllegalArgumentException::class.java) { ExportFormat.fromNativeValue(5) }
    }

    @Test fun dngJournalUsesExplicitFormatAndLegacyPngStillDecodes() {
        val root = Files.createTempDirectory("rawlab-format-journal").toFile()
        try {
            val source = BatchSourceSnapshot(PhotoIdentity("source"), File(root, "source.raw"), EditSettings())
            val journal = BatchJournal(root)
            val legacy = BatchJob(source, listOf(BatchTarget(PhotoIdentity("target"), File(root, "target.raw"), "target.raw")), outputFormat = ExportFormat.PNG)
            journal.save(legacy)
            val legacyFile = File(root, "${legacy.id}.properties")
            val legacyText = legacyFile.readText()
                .lineSequence().filterNot { it.startsWith("journal.version=") || it.startsWith("output.format=") }.joinToString("\n")
            legacyFile.writeText(legacyText)
            assertEquals(ExportFormat.PNG, journal.load(legacy.id)!!.outputFormat)

            val dng = BatchJob(source, legacy.targets, id = legacy.id, outputFormat = ExportFormat.DNG)
            assertTrue(dng.rows.single().outputName.endsWith(".dng"))
            journal.save(dng)
            val dngJournal = File(root, "${dng.id}.properties").readText()
            assertTrue(dngJournal.contains("journal.version=2"))
            assertTrue(dngJournal.contains("output.format=dng"))
            assertEquals(ExportFormat.DNG, journal.load(dng.id)!!.outputFormat)
        } finally { root.deleteRecursively() }
    }

    @Test fun batchRunnerDisposesOwnedPayloadsAfterSuccessFailureAndCancellation() {
        val root = Files.createTempDirectory("rawlab-payloads").toFile()
        try {
            val source = BatchSourceSnapshot(PhotoIdentity("source"), File(root, "source.raw"), EditSettings())
            fun job() = BatchJob(source, listOf(
                BatchTarget(PhotoIdentity("one"), File(root, "one.raw"), "one.raw"),
                BatchTarget(PhotoIdentity("two"), File(root, "two.raw"), "two.raw"),
            ))
            val disposed = mutableListOf<File>()
            val success = BatchRunner.run(job(), render = { target, _ ->
                File(root, "${target.id}.payload").also { it.writeText("payload") }
            }, write = { payload, _, _ -> assertTrue(payload.isFile) }, dispose = { payload ->
                disposed += payload
                assertTrue(payload.delete())
            })
            assertTrue(success.rows.all { it.status == BatchRowStatus.SUCCESS })
            assertEquals(2, disposed.size)
            assertTrue(disposed.none(File::exists))

            disposed.clear()
            val failed = BatchRunner.run(BatchJob(source, listOf(
                BatchTarget(PhotoIdentity("failed"), File(root, "failed.raw"), "failed.raw"),
            )), render = { target, _ ->
                File(root, "${target.id}.failed").also { it.writeText("payload") }
            }, write = { _, _, _ -> }, dispose = { payload ->
                disposed += payload
                assertTrue(payload.delete())
            }, publish = { _, _, _, _ -> throw IllegalStateException("publish failed") })
            assertEquals(BatchRowStatus.NEEDS_CONFIRMATION, failed.rows.first().status)
            assertEquals(1, disposed.size)
            assertTrue(disposed.none(File::exists))

            disposed.clear()
            var writes = 0
            val cancelled = BatchRunner.run(job(), render = { target, _ ->
                File(root, "${target.id}.cancelled").also { it.writeText("payload") }
            }, write = { _, _, _ -> writes++ }, shouldCancel = { writes > 0 }, dispose = { payload ->
                disposed += payload
                assertTrue(payload.delete())
            })
            assertEquals(1, cancelled.rows.count { it.status == BatchRowStatus.SUCCESS })
            assertEquals(1, disposed.size)
            assertTrue(disposed.none(File::exists))
        } finally { root.deleteRecursively() }
    }

    @Test fun sourceIoFailureStaysPerTargetButOutputIoStopsBatch() {
        val sourceFailure = asBatchOutputFailure(NativeProcessingException(NativeProcessingException.IO_ERROR, "source missing"))
        assertTrue(sourceFailure is NativeProcessingException)
        val outputFailure = asBatchOutputFailure(NativeProcessingException(NativeProcessingException.OUTPUT_IO_ERROR, "disk full"))
        assertTrue(outputFailure is BatchGlobalFailure)
        assertTrue(outputFailure.message!!.contains("disk full"))
        assertEquals(IllegalStateException::class.java, asBatchOutputFailure(IllegalStateException())::class.java)

        val root = Files.createTempDirectory("rawlab-status-routing").toFile()
        try {
            val source = BatchSourceSnapshot(PhotoIdentity("source"), File(root, "source.raw"), EditSettings())
            val targets = listOf(
                BatchTarget(PhotoIdentity("bad"), File(root, "bad.raw"), "bad.raw"),
                BatchTarget(PhotoIdentity("good"), File(root, "good.raw"), "good.raw"),
            )
            val perTarget = BatchRunner.run(BatchJob(source, targets), render = { target, _ ->
                if (target.id == "bad") throw NativeProcessingException(NativeProcessingException.IO_ERROR, "source missing")
                byteArrayOf(1)
            }, write = { _, _, _ -> })
            assertEquals(BatchRowStatus.FAILED, perTarget.rows[0].status)
            assertEquals(BatchRowStatus.SUCCESS, perTarget.rows[1].status)

            val global = BatchRunner.run(BatchJob(source, targets), render = { target, _ ->
                if (target.id == "bad") throw asBatchOutputFailure(
                    NativeProcessingException(NativeProcessingException.OUTPUT_IO_ERROR, "disk full"))
                byteArrayOf(1)
            }, write = { _, _, _ -> })
            assertEquals(BatchRowStatus.FAILED, global.rows[0].status)
            assertEquals(BatchRowStatus.PENDING, global.rows[1].status)
        } finally { root.deleteRecursively() }
    }

    @Test fun olderSnapshotsDefaultToDisabledDenoise() {
        val settings = SettingsCodec.decode("neutral|1.0|0.0|0.0|0.0|0.0|0.0|0.0|false|6500.0|0.0|0.0")
        assertEquals(DenoiseSettings(), settings.denoise)
        assertEquals(PhotoEffectsSettings(), settings.effects)
        assertEquals(0, settings.displayChromaDenoise)
        val withDenoise = SettingsCodec.decode("neutral|1.0|0.0|0.0|0.0|0.0|0.0|0.0|false|6500.0|0.0|0.0|true|10.0|72.0|100.0")
        assertEquals(DenoiseSettings(true, 10f, 72f, 100f), withDenoise.denoise)
        assertEquals(PhotoEffectsSettings(), withDenoise.effects)
    }

    @Test fun settingsCodecRoundTripsEffectsAndDisplayChromaAlongsideWaveletDenoise() {
        val settings = EditSettings(
            denoise = DenoiseSettings(true, 10f, 72f, 100f),
            displayChromaDenoise = 1,
            effects = PhotoEffectsSettings(vignetteAmount = -40f, vignetteMidpoint = 20f,
                vignetteRoundness = -30f, vignetteFeather = 70f, vignetteHighlights = 60f,
                grainAmount = 65f, grainSize = 70f, grainRoughness = 80f),
        )
        assertEquals(settings, SettingsCodec.decode(SettingsCodec.encode(settings)))
    }

    @Test fun pngResumeAndPublishingCheckpointAreDurable() {
        val root = Files.createTempDirectory("rawlab-recovery").toFile()
        try {
            val source = BatchSourceSnapshot(PhotoIdentity("source"), File(root, "s.raw"),
                EditSettings(denoise = DenoiseSettings(true, 10f, 72f, 100f)))
            val job = BatchJob(source, (1..2).map { BatchTarget(PhotoIdentity("$it"), File(root, "$it.raw"), "$it.raw") }, outputFormat = ExportFormat.PNG)
            assertTrue(job.rows.all { it.outputName.endsWith(".png") })
            val journal = BatchJournal(root)
            var writes = 0
            val updates = mutableListOf<BatchJob>()
            val stopped = BatchRunner.run(job, { _, _ -> byteArrayOf(1) }, { _, _, _ -> },
                shouldCancel = { writes == 1 }, journal = journal, didUpdate = { updates += it },
                publish = { _, _, _, checkpoint -> writes++; checkpoint("content://output/$writes") })
            assertEquals(1, stopped.rows.count { it.status == BatchRowStatus.SUCCESS })
            assertTrue(updates.any { it.rows[0].status == BatchRowStatus.PUBLISHING && it.rows[0].outputUri != null })
            assertEquals(listOf(job.id), journal.pending())
            assertEquals(source.settings, journal.load(job.id)!!.source.settings)
            val resumed = BatchRunner.run(journal.load(job.id)!!, { _, _ -> byteArrayOf(1) }, { _, _, _ -> writes++ })
            assertEquals(2, writes)
            assertTrue(resumed.rows.all { it.status == BatchRowStatus.SUCCESS })
            val uncertain = job.withRows(job.rows.map { it.copy(status = BatchRowStatus.PUBLISHING) })
            journal.save(uncertain)
            val recovered = journal.load(job.id)!!
            assertTrue(recovered.rows.all { it.status == BatchRowStatus.NEEDS_CONFIRMATION })
            BatchRunner.run(recovered, { _, _ -> error("must not rerender unknown publication") }, { _, _, _ -> error("must not publish") })
        } finally { root.deleteRecursively() }
    }
    @Test fun sourceSnapshotIsImmutableAndTargetsHaveIndependentRows() {
        val root = Files.createTempDirectory("rawlab-batch").toFile()
        try {
            val source = BatchSourceSnapshot(PhotoIdentity("source"), File(root, "source.raw"),
                EditSettings(exposure = .75f, denoise = DenoiseSettings(true, 10f, 72f, 100f),
                    geometry = GeometrySettings(.1f, .2f, .6f, .8f, 1, true, false, 4.5f)))
            val targets = (1..6).map { BatchTarget(PhotoIdentity("target-$it"), File(root, "same.raw"), "same.raw") }
            var job = BatchJob(source, targets)
            var settingsSeen = EditSettings()
            job = BatchRunner.run(job, render = { _, settings -> settingsSeen = settings; ByteArray(1) }, write = { _, _, _ -> })
            assertEquals(.75f, settingsSeen.exposure)
            assertEquals(source.settings.denoise, settingsSeen.denoise)
            assertEquals(source.settings.geometry, settingsSeen.geometry)
            assertEquals(6, job.rows.count { it.status == BatchRowStatus.SUCCESS })
            assertEquals(6, job.rows.map { it.outputName }.toSet().size)
        } finally { root.deleteRecursively() }
    }

    @Test fun sourceSnapshotResolvesCameraStateForBothBatchDirections() {
        val root = Files.createTempDirectory("rawlab-raster-settings").toFile()
        try {
            val hsl = HslSettings().withValue(0, 2, 32f)
            val stored = EditSettings(film = "velvia", strength = .6f, exposure = .35f,
                customWb = true, temperature = 4300f, tint = 18f, exposureMode = 0,
                hsl = hsl, recipeID = "recipe", lens = LensSettings(distortion = true),
                denoise = DenoiseSettings(true, 10f, 72f, 100f))
            val rasterSource = BatchSourceSnapshot(PhotoIdentity("raster-source"), File(root, "source.jpg"),
                stored, inputKind = PhotoInputKind.RASTER)
            val rawTarget = rasterSource.settingsFor(PhotoInputKind.RAW)
            assertFalse(rawTarget.customWb)
            assertEquals(6500f, rawTarget.temperature)
            assertEquals(stored.tint, rawTarget.tint)
            assertEquals(EditSettings().exposureMode, rawTarget.exposureMode)
            assertEquals(LensSettings(), rawTarget.lens)
            assertEquals(stored.recipeID, rawTarget.recipeID)
            assertEquals(stored.strength, rawTarget.strength)
            assertEquals(stored.hsl, rawTarget.hsl)
            assertEquals(stored.denoise, rawTarget.denoise)
            assertEquals(stored.exposure, rawTarget.exposure)
            assertEquals(stored, rasterSource.settingsFor(PhotoInputKind.RASTER))
            var rendered: EditSettings? = null
            BatchRunner.run(
                BatchJob(rasterSource, listOf(BatchTarget(PhotoIdentity("raw-target"), File(root, "target.arw"),
                    "target.arw", inputKind = PhotoInputKind.RAW))),
                render = { _, effective -> rendered = effective; ByteArray(1) },
                write = { _, _, _ -> },
            )
            assertEquals(rawTarget, rendered)

            val rawSource = BatchSourceSnapshot(PhotoIdentity("raw-source"), File(root, "source.arw"),
                stored, inputKind = PhotoInputKind.RAW)
            assertEquals(stored, rawSource.settingsFor(PhotoInputKind.RAW))
            val rasterTarget = rawSource.settingsFor(PhotoInputKind.RASTER).effectiveFor(PhotoInputKind.RASTER)
            assertFalse(rasterTarget.customWb)
            assertEquals(6500f, rasterTarget.temperature)
            assertEquals(0f, rasterTarget.tint)
            assertEquals(2, rasterTarget.exposureMode)
            assertEquals(LensSettings(), rasterTarget.lens)
            assertEquals(stored.recipeID, rasterTarget.recipeID)
            assertEquals(stored.hsl, rasterTarget.hsl)
            assertEquals(stored.denoise, rasterTarget.denoise)
        } finally { root.deleteRecursively() }
    }

    @Test fun failuresContinueCancellationPreservesSuccessAndRetrySkipsSuccesses() {
        val root = Files.createTempDirectory("rawlab-batch").toFile()
        try {
            val source = BatchSourceSnapshot(PhotoIdentity("source"), File(root, "source.raw"), EditSettings())
            val targets = (1..6).map { BatchTarget(PhotoIdentity("target-$it"), File(root, "$it.raw"), "$it.raw") }
            var job = BatchJob(source, targets)
            var failed = true
            job = BatchRunner.run(job, render = { target, _ ->
                if (target.id == "target-3" && failed) throw IllegalStateException("fixture")
                ByteArray(1)
            }, write = { _, _, _ -> })
            assertEquals(5, job.rows.count { it.status == BatchRowStatus.SUCCESS })
            assertEquals(1, job.rows.count { it.status == BatchRowStatus.FAILED })
            val successCount = job.rows.count { it.status == BatchRowStatus.SUCCESS }
            failed = false
            job = BatchRunner.retryFailed(job, render = { _, _ -> ByteArray(1) }, write = { _, _, _ -> })
            assertEquals(6, job.rows.count { it.status == BatchRowStatus.SUCCESS })
            assertEquals(successCount, 5)

            var cancelled = BatchJob(source, targets)
            var writes = 0
            cancelled = BatchRunner.run(cancelled, render = { _, _ -> ByteArray(1) }, write = { _, _, _ -> writes++ }, shouldCancel = { writes >= 2 })
            assertEquals(2, cancelled.rows.count { it.status == BatchRowStatus.SUCCESS })
            assertTrue(cancelled.rows.drop(2).all { it.status == BatchRowStatus.CANCELLED })
        } finally { root.deleteRecursively() }
    }

    @Test fun journalRoundTripsPendingRowsAndDropsCompletedJobs() {
        val root = Files.createTempDirectory("rawlab-journal").toFile()
        try {
            val source = BatchSourceSnapshot(PhotoIdentity("source"), File(root, "source.raw"), EditSettings())
            val job = BatchJob(source, listOf(BatchTarget(PhotoIdentity("target"), File(root, "target.raw"), "target.raw")))
            val journal = BatchJournal(root)
            journal.save(job)
            assertEquals(job.id, journal.load(job.id)?.id)
            assertEquals(listOf(job.id), journal.pending())
            val done = BatchRunner.run(job, render = { _, _ -> byteArrayOf(1) }, write = { _, _, _ -> }, journal = journal)
            assertEquals(BatchRowStatus.SUCCESS, done.rows.single().status)
            assertTrue(journal.pending().isEmpty())
        } finally { root.deleteRecursively() }
    }

    @Test fun journalRoundTripsRequestedOutputLongEdge() {
        val root = Files.createTempDirectory("rawlab-size").toFile()
        try {
            val source = BatchSourceSnapshot(PhotoIdentity("source"), File(root, "source.raw"), EditSettings())
            val job = BatchJob(source, listOf(BatchTarget(PhotoIdentity("target"), File(root, "target.raw"), "target.raw")),
                outputLongEdge = 3000)
            val journal = BatchJournal(root)
            journal.save(job)
            assertEquals(3000, journal.load(job.id)?.outputLongEdge)
        } finally { root.deleteRecursively() }
    }
}
