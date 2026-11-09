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
        val store = EditStore(directory)
        val identity = PhotoIdentity("a")
        val saved = store.save(identity, EditSettings(exposure = .5f))
        assertTrue(directory.renameTo(File(root, "backup")))
        directory.writeText("unavailable")
        assertEquals(saved.settings, store.load(identity))
        assertThrows(IOException::class.java) { store.readState(identity) }
        assertThrows(IOException::class.java) { store.save(identity, EditSettings()) }
    }

    @Test fun corruptAndFutureStoresCannotBeOverwritten() = inStore { directory ->
        val store = EditStore(directory)
        val identity = PhotoIdentity("a")
        val file = File(directory, "edits.properties")
        for (contents in listOf("format.version=999", "record.YQ.values=broken")) {
            file.writeText(contents)
            assertThrows(Exception::class.java) { store.readState(identity) }
            assertThrows(Exception::class.java) { store.save(identity, EditSettings()) }
            assertEquals(contents, file.readText())
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
