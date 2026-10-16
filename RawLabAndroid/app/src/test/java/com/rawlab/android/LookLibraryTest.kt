package com.rawlab.android

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.Properties
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

class LookLibraryTest {
    private val validator = LookValidator { file ->
        val bytes = file.readBytes()
        if (bytes.contentEquals("RLOOKDCP".toByteArray())) return@LookValidator LookValidation(LookFormat.RLOOK, 2)
        if (bytes.toString(Charsets.UTF_8) != "valid") throw IllegalArgumentException("invalid look")
        LookValidation(if (file.extension == "rlook") LookFormat.RLOOK else LookFormat.CUBE,
            if (file.extension == "rlook") 2 else 0)
    }

    @Test
    fun interruptedImportRecoveryPreservesCommittedAndUnownedLooks() {
        val root = Files.createTempDirectory("rawlab-look-recovery").toFile()
        try {
            val committed = LookLibrary(root, validator).importLook("valid".byteInputStream(), "existing.cube")
            val orphanId = UUID.randomUUID().toString()
            val unowned = File(root, "${UUID.randomUUID()}.cube").apply { writeText("user-owned") }
            val marker = File(root, ".import-$orphanId.pending").apply { writeText("") }
            val orphan = File(root, "$orphanId.cube").apply { writeText("valid") }
            val stage = File(root, ".$orphanId.stage").apply { writeText("partial") }
            val typedStage = File(root, ".${committed.id}.stage.cube").apply { writeText("partial") }
            val committedMarker = File(root, ".import-${committed.id}.pending").apply { writeText("") }
            val registryTemp = File(root, ".registry.properties.${UUID.randomUUID()}.tmp").apply { writeText("partial") }
            val legacyStage = File(root, ".${UUID.randomUUID()}.stage.rlook").apply { writeText("partial") }
            val registry = File(root, "registry.properties").readBytes()

            assertEquals(listOf(committed.id), LookLibrary(root, validator).list().map { it.id })
            for (file in listOf(marker, orphan, stage, typedStage, committedMarker, registryTemp, legacyStage)) {
                assertFalse("Interrupted import resource must be recovered: ${file.name}", file.exists())
            }
            assertEquals("valid", committed.file(root).readText())
            assertEquals("user-owned", unowned.readText())
            assertArrayEquals(registry, File(root, "registry.properties").readBytes())
        } finally { root.deleteRecursively() }
    }

    @Test
    fun corruptRegistryPreservesInterruptedTransactionForRecovery() {
        val root = Files.createTempDirectory("rawlab-look-corrupt-recovery").toFile()
        try {
            val id = UUID.randomUUID().toString()
            val marker = File(root, ".import-$id.pending").apply { writeText("") }
            val orphan = File(root, "$id.rlook").apply { writeText("valid") }
            val stage = File(root, ".$id.stage.rlook").apply { writeText("partial") }
            val registryTemp = File(root, ".registry.properties.${UUID.randomUUID()}.tmp").apply { writeText("partial registry") }
            val registry = "version=99\ncount=0\n".toByteArray()
            File(root, "registry.properties").writeBytes(registry)
            assertThrows(IOException::class.java) { LookLibrary(root, validator).list() }
            assertTrue(marker.isFile)
            assertEquals("valid", orphan.readText())
            assertEquals("partial", stage.readText())
            assertEquals("partial registry", registryTemp.readText())
            assertArrayEquals(registry, File(root, "registry.properties").readBytes())
        } finally { root.deleteRecursively() }
    }

    @Test
    fun anotherLibraryCannotRecoverAnImportThatIsStillRunning() {
        val root = Files.createTempDirectory("rawlab-look-live-owner").toFile()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val secondStarted = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        try {
            val first = executor.submit<ManagedLook> {
                LookLibrary(root, LookValidator { file ->
                    entered.countDown()
                    check(release.await(5, TimeUnit.SECONDS))
                    validator.validate(file)
                }).importLook("valid".byteInputStream(), "first.cube")
            }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val second = executor.submit<ManagedLook> {
                secondStarted.countDown()
                LookLibrary(root, validator).importLook("valid".byteInputStream(), "second.cube")
            }
            assertTrue(secondStarted.await(5, TimeUnit.SECONDS))
            assertThrows(TimeoutException::class.java) { second.get(200, TimeUnit.MILLISECONDS) }
            assertEquals(1, root.listFiles().orEmpty().count { it.name.endsWith(".stage.cube") })
            release.countDown()
            val a = first.get(5, TimeUnit.SECONDS)
            val b = second.get(5, TimeUnit.SECONDS)
            assertNotEquals(a.id, b.id)
            assertEquals(setOf(a.id, b.id), LookLibrary(root, validator).list().map { it.id }.toSet())
            assertEquals("valid", a.file(root).readText())
            assertEquals("valid", b.file(root).readText())
        } finally {
            release.countDown()
            executor.shutdownNow()
            assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS))
            root.deleteRecursively()
        }
    }

    @Test
    fun directoryCreatedByAnotherOwnerDuringMkdirsIsAccepted() {
        val parent = Files.createTempDirectory("rawlab-look-root-race").toFile()
        val root = object : File(parent, "looks") {
            override fun mkdirs(): Boolean {
                File(path).mkdirs()
                return super.mkdirs()
            }
        }
        try {
            assertTrue(LookLibrary(root, validator).list().isEmpty())
            assertTrue(root.isDirectory)
        } finally { parent.deleteRecursively() }
    }

    @Test
    fun importedLookSurvivesSourceRemovalAndLibraryRecreation() {
        val root = Files.createTempDirectory("rawlab-looks").toFile()
        val source = File(root.parentFile, "source.cube").apply { writeText("valid") }
        try {
            val imported = LookLibrary(root, validator).importLook(source)
            assertTrue(source.delete())

            val restored = LookLibrary(root, validator).list().single()
            assertEquals(imported.id, restored.id)
            assertEquals("source.cube", restored.originalName)
            assertEquals("valid", restored.file(root).readText())
            assertEquals(imported.id, LookLibrary(root, validator).list().single().id)
        } finally {
            root.deleteRecursively()
            source.delete()
        }
    }

    @Test
    fun sameNameImportsUseDistinctStableFiles() {
        val root = Files.createTempDirectory("rawlab-looks").toFile()
        val first = File(root.parentFile, "same.cube").apply { writeText("valid") }
        val second = File(root.parentFile, "same.cube-2").apply { writeText("valid") }
        try {
            val library = LookLibrary(root, validator)
            val a = library.importLook(first, originalName = "same.cube")
            val b = library.importLook(second, originalName = "same.cube")
            assertNotEquals(a.id, b.id)
            assertNotEquals(a.file(root).canonicalPath, b.file(root).canonicalPath)
            assertTrue(a.file(root).isFile)
            assertTrue(b.file(root).isFile)
            assertEquals(listOf("same.cube", "same.cube"), library.list().map { it.originalName })
        } finally {
            root.deleteRecursively()
            first.delete()
            second.delete()
        }
    }

    @Test
    fun invalidImportRollsBackOwnedFileAndRegistry() {
        val root = Files.createTempDirectory("rawlab-looks").toFile()
        val source = File(root.parentFile, "broken.cube").apply { writeText("broken") }
        try {
            val library = LookLibrary(root, validator)
            assertThrows(IllegalArgumentException::class.java) { library.importLook(source) }
            assertTrue(library.list().isEmpty())
            assertTrue(root.listFiles().orEmpty().all { it.name == ".lock" })
        } finally {
            root.deleteRecursively()
            source.delete()
        }
    }

    @Test
    fun renameAndDeleteOnlyManagedLook() {
        val root = Files.createTempDirectory("rawlab-looks").toFile()
        val source = File(root.parentFile, "managed.rlook").apply { writeText("valid") }
        try {
            val library = LookLibrary(root, validator)
            val imported = library.importLook(source)
            val renamed = library.rename(imported.id, "My look")
            assertEquals("My look", renamed.name)
            assertTrue(imported.file(root).isFile)
            assertArrayEquals("valid".toByteArray(), source.readBytes())

            library.remove(imported.id)
            assertTrue(library.list().isEmpty())
            assertFalse(imported.file(root).exists())
            assertTrue(source.exists())
            assertTrue(LookChoice.builtIns.any { it.id == "velvia" })
        } finally {
            root.deleteRecursively()
            source.delete()
        }
    }

    @Test
    fun corruptRegistryRejectsImportAndPreservesOriginalBytes() {
        val root = Files.createTempDirectory("rawlab-looks").toFile()
        val source = File(root.parentFile, "new.cube").apply { writeText("valid") }
        val bytes = "version=99\ncount=0\n".toByteArray()
        try {
            root.resolve("registry.properties").writeBytes(bytes)
            val library = LookLibrary(root, validator)
            assertThrows(IOException::class.java) { library.importLook(source) }
            assertArrayEquals(bytes, root.resolve("registry.properties").readBytes())
            assertTrue(root.listFiles().orEmpty().all { it.name in listOf("registry.properties", ".lock") })
        } finally {
            root.deleteRecursively()
            source.delete()
        }
    }

    @Test
    fun duplicateRegistryIdsAreRejectedBeforeTheyReachTheLookStrip() {
        val root = Files.createTempDirectory("rawlab-looks").toFile()
        val id = "00000000-0000-0000-0000-000000000001"
        try {
            root.resolve("$id.cube").writeText("valid")
            val properties = Properties().apply {
                setProperty("version", "1")
                setProperty("count", "2")
                for (index in 0..1) {
                    val prefix = "item.$index."
                    setProperty(prefix + "id", id)
                    setProperty(prefix + "name", "Duplicate $index")
                    setProperty(prefix + "originalName", "duplicate.cube")
                    setProperty(prefix + "format", "cube")
                    setProperty(prefix + "version", "0")
                    setProperty(prefix + "path", "$id.cube")
                }
            }
            root.resolve("registry.properties").outputStream().use { properties.store(it, null) }
            assertThrows(IOException::class.java) { LookLibrary(root, validator).list() }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun missingManagedFileRemainsRemovableAndIsMarkedUnavailable() {
        val root = Files.createTempDirectory("rawlab-looks").toFile()
        val source = File(root.parentFile, "missing.cube").apply { writeText("valid") }
        try {
            val library = LookLibrary(root, validator)
            val imported = library.importLook(source)
            assertTrue(imported.file(root).delete())
            val unavailable = library.list().single()
            assertFalse(unavailable.available)
            library.remove(unavailable.id)
            assertTrue(library.list().isEmpty())
        } finally {
            root.deleteRecursively()
            source.delete()
        }
    }

    @Test
    fun providerWithoutDisplayExtensionUsesContentContainerForCube() {
        val root = Files.createTempDirectory("rawlab-looks").toFile()
        val source = File(root.parentFile, "provider-document").apply { writeText("valid") }
        try {
            val imported = LookLibrary(root, validator).importLook(source, originalName = "provider-document")
            assertEquals(LookFormat.CUBE, imported.format)
            assertTrue(imported.file(root).name.endsWith(".cube"))
            assertEquals("provider-document", imported.name)
        } finally {
            root.deleteRecursively()
            source.delete()
        }
    }

    @Test
    fun providerWithoutDisplayExtensionUsesRlookMagicContainer() {
        val root = Files.createTempDirectory("rawlab-looks").toFile()
        val source = File(root.parentFile, "provider-rlook").apply { writeBytes("RLOOKDCP".toByteArray()) }
        try {
            val imported = LookLibrary(root, validator).importLook(source, originalName = "")
            assertEquals(LookFormat.RLOOK, imported.format)
            assertTrue(imported.file(root).name.endsWith(".rlook"))
        } finally {
            root.deleteRecursively()
            source.delete()
        }
    }
}
