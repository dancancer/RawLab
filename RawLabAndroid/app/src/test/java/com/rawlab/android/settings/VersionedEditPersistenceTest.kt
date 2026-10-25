package com.rawlab.android.settings

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.Properties
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class VersionedEditPersistenceTest {
    private inline fun inStore(block: (File) -> Unit) {
        val directory = Files.createTempDirectory("rawlab-versioned-edits").toFile()
        try { block(directory) } finally { directory.deleteRecursively() }
    }

    @Test fun legacyReadAndUnchangedSavePreserveBytesAndReceipt() = inStore { directory ->
        val identity = PhotoIdentity("content://photos/original")
        EditStore(directory).save(identity, EditSettings(exposure = .75f, processing = ProcessingIdentity.LEGACY))
        val file = File(directory, "edits.properties")
        val legacy = Properties().apply { file.inputStream().use(::load) }
        val valueKey = legacy.stringPropertyNames().single { it.endsWith(".values") }
        legacy.setProperty(valueKey, legacyCSVSettings(EditSettings(exposure = .75f)))
        legacy.stringPropertyNames().filter { it.startsWith("revision.") || it == "format.version" }
            .forEach(legacy::remove)
        file.outputStream().use { legacy.store(it, null) }
        val bytes = file.readBytes()
        val store = EditStore(directory)
        val receipt = store.versionedState(identity)
        assertNull(receipt.revision)
        assertEquals(ProcessingIdentity.LEGACY, receipt.settings!!.processing)
        assertEquals(receipt, store.compareAndSave(receipt, receipt.settings))
        assertArrayEquals(bytes, file.readBytes())
    }

    @Test fun revisionsRejectExternalChangesAndAbsentPresentAbsentABA() = inStore { directory ->
        val identity = PhotoIdentity("a")
        val first = EditStore(directory)
        val second = EditStore(directory)
        val missing = first.versionedState(identity)
        val saved = first.compareAndSave(missing, EditSettings(exposure = .5f))
        assertNotNull(saved.revision)
        assertThrows(EditPersistenceConflict::class.java) {
            second.compareAndSave(missing, EditSettings(exposure = 1f))
        }
        val deleted = second.compareAndSave(saved, null)
        assertNull(deleted.settings)
        assertNotEquals(saved.revision, deleted.revision)
        assertEquals(deleted, EditStore(directory).versionedState(identity))
        assertThrows(EditPersistenceConflict::class.java) { first.compareAndSave(missing, EditSettings()) }
        assertEquals(deleted, first.compareAndSave(deleted, null))
    }

    @Test fun conditionalSaveChecksFullRecordEvenIfRevisionIsUnchanged() = inStore { directory ->
        val identity = PhotoIdentity("a")
        val store = EditStore(directory)
        val saved = store.compareAndSave(store.versionedState(identity), EditSettings(exposure = .5f))
        val file = File(directory, "edits.properties")
        val props = Properties().apply { file.inputStream().use(::load) }
        val key = props.stringPropertyNames().single { it.endsWith(".values") }
        val encoded = org.json.JSONObject(props.getProperty(key).removePrefix("v2:"))
        encoded.getJSONObject("settings").put("exposure", 1.0)
        props.setProperty(key, "v2:$encoded")
        file.outputStream().use { props.store(it, null) }
        assertThrows(EditPersistenceConflict::class.java) { store.compareAndSave(saved, saved.settings) }
        assertEquals(1f, store.versionedState(identity).settings!!.exposure)
    }

    @Test fun failedReplacementDoesNotPublishCandidateOrNewRevision() = inStore { directory ->
        var fail = false
        val store = EditStore(directory) { from, to ->
            if (fail) throw IOException("injected replacement failure")
            Files.move(from.toPath(), to.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING)
        }
        val identity = PhotoIdentity("a")
        val before = store.compareAndSave(store.versionedState(identity), EditSettings(exposure = .5f))
        val bytes = File(directory, "edits.properties").readBytes()
        fail = true
        assertThrows(IOException::class.java) { store.compareAndSave(before, EditSettings(exposure = 1f)) }
        assertEquals(before, store.versionedState(identity))
        assertArrayEquals(bytes, File(directory, "edits.properties").readBytes())
        assertTrue(directory.listFiles()!!.none { it.extension == "tmp" })
        fail = false
        assertEquals(1f, store.compareAndSave(before, EditSettings(exposure = 1f)).settings!!.exposure)
    }

    @Test fun strictReadsNeverUseLastReadableCacheDuringStorageFailure() = inStore { root ->
        val directory = File(root, "store")
        val store = EditStore(directory)
        val identity = PhotoIdentity("a")
        val saved = store.compareAndSave(store.versionedState(identity), EditSettings(exposure = .5f))
        assertTrue(directory.renameTo(File(root, "backup")))
        directory.writeText("unavailable")
        assertEquals(saved.settings, store.load(identity))
        assertThrows(IOException::class.java) { store.versionedState(identity) }
        assertThrows(IOException::class.java) { store.compareAndSave(saved, EditSettings()) }
    }

    @Test fun corruptAndFutureStoresCannotBeOverwritten() = inStore { directory ->
        val store = EditStore(directory)
        val identity = PhotoIdentity("a")
        val receipt = store.versionedState(identity)
        val file = File(directory, "edits.properties")
        for (contents in listOf("format.version=999", "record.YQ.values=broken")) {
            file.writeText(contents)
            assertThrows(Exception::class.java) { store.versionedState(identity) }
            assertThrows(Exception::class.java) { store.compareAndSave(receipt, EditSettings()) }
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
                store.compareAndSave(store.versionedState(identity), EditSettings(exposure = index / 10f))
            } }
            assertTrue(ready.await(10, TimeUnit.SECONDS)); go.countDown()
            jobs.forEach { it.get(15, TimeUnit.SECONDS) }
            val store = EditStore(directory)
            repeat(count) { assertEquals(it / 10f, store.versionedState(PhotoIdentity("photo-$it")).settings!!.exposure) }
        } finally { pool.shutdownNow() }
    }
}
