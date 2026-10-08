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

class LookLibraryTest {
    private val validator = LookValidator { file ->
        val bytes = file.readBytes()
        if (bytes.contentEquals("RLOOKDCP".toByteArray())) return@LookValidator LookValidation(LookFormat.RLOOK, 2)
        if (bytes.toString(Charsets.UTF_8) != "valid") throw IllegalArgumentException("invalid look")
        LookValidation(if (file.extension == "rlook") LookFormat.RLOOK else LookFormat.CUBE,
            if (file.extension == "rlook") 2 else 0)
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
            assertTrue(root.listFiles().orEmpty().none { it.name != "." && it.name != ".." })
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
            assertTrue(root.listFiles().orEmpty().all { it.name == "registry.properties" })
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
