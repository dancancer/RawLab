package com.rawlab.android.settings

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class VersionedEditPersistenceTest {
    private inline fun inStore(block: (File) -> Unit) {
        val directory = Files.createTempDirectory("rawlab-edit-store").toFile()
        try { block(directory) } finally { directory.deleteRecursively() }
    }

    @Test fun cachedReadsDetectSameSizePreservedTimeOverwriteAndSaveUsesIdentityOnly() = inStore { directory ->
        val identity = PhotoIdentity("a"); val store = EditStore(directory)
        store.save(identity, EditSettings(exposure = .5f))
        val file = File(directory, "edits.properties")
        val modified = Files.getLastModifiedTime(file.toPath())
        val before = file.readText()
        val replacement = before.replace("0.5", "0.9")
        assertNotEquals(before, replacement)
        file.writeText(replacement); Files.setLastModifiedTime(file.toPath(), modified)
        assertEquals(.9f, store.readState(identity).settings!!.exposure)
        // 外部调整变化不再阻挡普通按身份保存。
        assertEquals(1f, store.save(identity, EditSettings(exposure = 1f)).settings!!.exposure)
    }

    @Test fun legacyRevisionRecordsRemainReadableButNewWritesDoNotGenerateRevision() = inStore { directory ->
        val identity = PhotoIdentity("content://photos/original")
        val store = EditStore(directory)
        store.save(identity, EditSettings(exposure = .75f, processing = ProcessingIdentity.LEGACY))
        val file = File(directory, "edits.properties")
        val props = java.util.Properties().apply { file.inputStream().use(::load) }
        val valueKey = props.stringPropertyNames().single { it.endsWith(".values") }
        props.setProperty("revision.Y29udGVudDovL3Bob3Rvcy9vcmlnaW5hbA", "legacy")
        props.setProperty(valueKey, legacyCSVSettings(EditSettings(exposure = .75f)))
        file.outputStream().use { props.store(it, null) }
        val readable = EditStore(directory).readState(identity)
        assertEquals(ProcessingIdentity.LEGACY, readable.settings!!.processing)
        EditStore(directory).save(identity, readable.settings!!.copy(exposure = .8f))
        val rewritten = file.readText()
        assertFalse(rewritten.lineSequence().any { it.startsWith("revision.") })
    }

    @Test fun signedZeroIsCanonicalizedAndNoOpDoesNotCreateNewRecord() = inStore { directory ->
        val identity = PhotoIdentity("signed-zero")
        val store = EditStore(directory)
        val saved = store.save(identity, EditSettings(highlights = -0f, exposure = -0f))
        assertEquals(0, saved.settings!!.highlights.toRawBits())
        val bytes = File(directory, "edits.properties").readBytes()
        assertEquals(saved, store.save(identity, saved.settings))
        assertArrayEquals(bytes, File(directory, "edits.properties").readBytes())
    }

    @Test fun failedReplacementDoesNotPublishCandidate() = inStore { directory ->
        var fail = false
        val store = EditStore(directory) { from, to ->
            if (fail) throw IOException("injected replacement failure")
            Files.move(from.toPath(), to.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING)
        }
        val identity = PhotoIdentity("a")
        val before = store.save(identity, EditSettings(exposure = .5f))
        val bytes = File(directory, "edits.properties").readBytes()
        fail = true
        assertThrows(IOException::class.java) { store.save(identity, EditSettings(exposure = 1f)) }
        assertEquals(before, store.readState(identity))
        assertArrayEquals(bytes, File(directory, "edits.properties").readBytes())
        assertTrue(directory.listFiles()!!.none { it.extension == "tmp" })
    }

    @Test fun strictReadsNeverUseLastReadableCacheDuringStorageFailure() = inStore { root ->
        val directory = File(root, "store")
        File(directory.apply { mkdirs() }, "edits.properties").writeText("format.version=1\nrecord.YnJva2Vu.values=broken\n")
        val store = EditStore(directory)
        val identity = PhotoIdentity("a")
        val broken = PhotoIdentity("broken")
        val saved = store.save(identity, EditSettings(exposure = .5f))
        assertTrue(directory.renameTo(File(root, "backup")))
        directory.writeText("unavailable")
        assertEquals(saved.settings, store.load(identity))
        assertThrows(UnusableEditRecordException::class.java) { store.load(broken) }
        assertThrows(IOException::class.java) { store.readState(identity) }
        assertThrows(IOException::class.java) { store.save(identity, EditSettings()) }
    }

    @Test fun corruptAndFutureStoresCannotBeOverwritten() = inStore { directory ->
        val store = EditStore(directory)
        val identity = PhotoIdentity("a")
        val file = File(directory, "edits.properties")
        file.writeText("format.version=999")
        assertThrows(IllegalArgumentException::class.java) { store.readState(identity) }
        assertThrows(IllegalArgumentException::class.java) { store.save(identity, EditSettings()) }
        assertEquals("format.version=999", file.readText())

        file.writeText("record.YQ.values=broken")
        assertThrows(UnusableEditRecordException::class.java) { store.readState(identity) }
        assertThrows(UnusableEditRecordException::class.java) { store.save(identity, EditSettings()) }
        assertEquals("record.YQ.values=broken", file.readText())
    }

    @Test fun perRecordIsolationPreservesBrokenEntryVerbatimAndResetToUnmodifiedClearsOnlyTarget() = inStore { directory ->
        val healthyA = PhotoIdentity("photo-a")
        val healthyB = PhotoIdentity("photo-b")
        val brokenProcessing = PhotoIdentity("photo-future-processing")
        val brokenSubSetting = PhotoIdentity("photo-bad-subsetting")
        val store = EditStore(directory)
        val c5 = EditSettings(processing = ProcessingIdentity.C5, exposure = .5f)
        store.save(healthyA, c5)
        store.save(healthyB, EditSettings(exposure = -.25f))
        store.save(brokenProcessing, c5)
        val quality = ProcessingMigrationQuality(.001f, .002f, .001f, .001f, 80)
        store.commitProcessingMigration(store.readState(healthyA), EditSettings(exposure = .6f), quality)
        store.commitProcessingMigration(store.readState(brokenProcessing), EditSettings(exposure = .6f), quality)

        val file = File(directory, "edits.properties")
        val keyFuture = "record.${java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(brokenProcessing.value.toByteArray())}.values"
        val keyBadSub = "record.${java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(brokenSubSetting.value.toByteArray())}.values"
        val rawFutureLine = "$keyFuture=v2:{\"kind\":\"photo_edit\",\"version\":2,\"processing\":{\"engine\":\"rawlab\",\"version\":99,\"profile\":\"standard\"},\"settings\":{}}"
        val baseV2 = StructuredSettingsCodec.encode(EditSettings(), "photo_edit")
        val rawBadSubLine = "$keyBadSub=" + baseV2.replace("\"blackPoint\":0", "\"blackPoint\":999")
        val existingLines = file.readLines().filterNot { it.startsWith("$keyFuture=") }
        file.writeText((existingLines + rawFutureLine + rawBadSubLine).joinToString("\n", postfix = "\n"))

        val reopened = EditStore(directory)
        assertEquals(.6f, reopened.readState(healthyA).settings?.exposure)
        assertEquals(-.25f, reopened.readState(healthyB).settings?.exposure)
        assertThrows(UnusableEditRecordException::class.java) { reopened.load(brokenProcessing) }
        assertThrows(UnusableEditRecordException::class.java) { reopened.load(brokenSubSetting) }
        val unseen = PhotoIdentity("photo-unseen")
        assertNull(reopened.load(unseen))
        val batchStates = reopened.readStates(listOf(healthyA, unseen, brokenProcessing, brokenSubSetting))
        assertEquals(.6f, (batchStates[healthyA] as PhotoEditReadResult.Usable).state.settings?.exposure)
        assertNull((batchStates[unseen] as PhotoEditReadResult.Usable).state.settings)
        assertTrue(batchStates[brokenProcessing] is PhotoEditReadResult.Unusable)
        assertTrue(batchStates[brokenSubSetting] is PhotoEditReadResult.Unusable)
        assertThrows(UnusableEditRecordException::class.java) { batchStates.getValue(brokenProcessing).getOrThrow() }
        assertThrows(UnusableEditRecordException::class.java) { batchStates.getValue(brokenSubSetting).getOrThrow() }

        assertThrows(UnusableEditRecordException::class.java) { reopened.readState(brokenProcessing) }
        assertThrows(UnusableEditRecordException::class.java) { reopened.readState(brokenSubSetting) }
        assertThrows(UnusableEditRecordException::class.java) { reopened.save(brokenProcessing, EditSettings()) }
        assertThrows(UnusableEditRecordException::class.java) { reopened.reset(brokenProcessing) }

        // D1/b: Saving another photo preserves both broken entries verbatim on disk.
        reopened.save(healthyB, EditSettings(exposure = 1.25f))
        val afterHealthySave = file.readLines()
        assertTrue(rawFutureLine in afterHealthySave)
        assertTrue(rawBadSubLine in afterHealthySave)
        assertEquals(1.25f, EditStore(directory).readState(healthyB).settings?.exposure)
        assertNotNull(EditStore(directory).processingMigration(healthyA))
        assertNotNull(EditStore(directory).processingMigration(brokenProcessing))

        // D3/c: resetToUnmodified clears ONLY the target photo's record and migration receipt.
        val session = com.rawlab.android.adjustments.AdjustmentTransferSession(reopened)
        val cleared = session.resetToUnmodified(brokenProcessing)
        assertNull(cleared.settings)
        assertNull(reopened.readState(brokenProcessing).settings)
        assertNull(reopened.processingMigration(brokenProcessing))
        assertNotNull(reopened.processingMigration(healthyA))
        assertEquals(.6f, reopened.readState(healthyA).settings?.exposure)
        assertEquals(1.25f, reopened.readState(healthyB).settings?.exposure)
        assertTrue(rawBadSubLine in file.readLines())
        assertThrows(UnusableEditRecordException::class.java) { reopened.readState(brokenSubSetting) }

        // Recovered photo can be edited and saved again normally.
        reopened.save(brokenProcessing, EditSettings(exposure = .35f))
        assertEquals(.35f, EditStore(directory).readState(brokenProcessing).settings?.exposure)
    }

    @Test fun wholeStoreStructuralCorruptionRemainsFailClosed() = inStore { directory ->
        val file = File(directory, "edits.properties")
        val corruptVariants = listOf(
            "format.version=999",
            "format.version=",
            "corrupt-non-record-line",
            "record.YQ.values=\\uZZZZ",
            "record..values=1.0",
            "record.!!!.values=1.0",
            "format.version=1\nrecord.YQ.values=broken\nrecord.YQ.values=duplicate",
        )
        for (corrupt in corruptVariants) {
            file.writeText(corrupt)
            assertThrows("Expected whole-store rejection for: $corrupt", IllegalArgumentException::class.java) {
                EditStore(directory)
            }
        }
    }

    @Test fun parallelStoreInstancesRetainAllCommittedPhotos() = inStore { directory ->
        val count = 12
        val pool = Executors.newFixedThreadPool(count)
        val ready = CountDownLatch(count)
        val go = CountDownLatch(1)
        try {
            val jobs = (0 until count).map { index -> pool.submit {
                val store = EditStore(directory)
                ready.countDown(); check(go.await(10, TimeUnit.SECONDS))
                val identity = PhotoIdentity("photo-$index")
                store.save(identity, EditSettings(exposure = index / 10f))
            } }
            assertTrue(ready.await(10, TimeUnit.SECONDS)); go.countDown()
            jobs.forEach { it.get(15, TimeUnit.SECONDS) }
            val store = EditStore(directory)
            repeat(count) { assertEquals(it / 10f, store.readState(PhotoIdentity("photo-$it")).settings!!.exposure) }
        } finally { pool.shutdownNow() }
    }
}
