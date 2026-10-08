package com.rawlab.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class LookLibraryInstrumentedTest {
    @Test fun nativeValidatedCopySurvivesSourceRemovalAndRecreation() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.filesDir, "look-test-${UUID.randomUUID()}")
        val source = File(context.cacheDir, "source-${UUID.randomUUID()}.cube").apply { writeText(syntheticCube()) }
        try {
            val imported = LookLibrary(root).importLook(source)
            val original = source.readBytes()
            assertTrue(source.delete())
            val restored = LookLibrary(root).list().single()
            assertEquals(imported.id, restored.id)
            assertArrayEquals(original, restored.file(root).readBytes())
            assertEquals(LookValidation(LookFormat.CUBE, 0), NativeProcessor.validateLook(restored.file(root)))
        } finally {
            root.deleteRecursively()
            source.delete()
        }
    }

    @Test fun nativeInvalidImportRollsBackAndSameNamesDoNotOverwrite() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.filesDir, "look-test-${UUID.randomUUID()}")
        val invalid = File(context.cacheDir, "invalid-${UUID.randomUUID()}.cube").apply { writeText("not a LUT") }
        val first = File(context.cacheDir, "first-${UUID.randomUUID()}.cube").apply { writeText(syntheticCube()) }
        val second = File(context.cacheDir, "second-${UUID.randomUUID()}.cube").apply { writeText(syntheticCube()) }
        try {
            val library = LookLibrary(root)
            assertThrows(UnsupportedOperationException::class.java) { library.importLook(invalid) }
            assertTrue(library.list().isEmpty())
            assertTrue(root.listFiles().orEmpty().isEmpty())
            val a = library.importLook(first, "same.cube")
            val b = library.importLook(second, "same.cube")
            assertNotEquals(a.id, b.id)
            assertNotEquals(a.relativePath, b.relativePath)
        } finally {
            root.deleteRecursively()
            invalid.delete(); first.delete(); second.delete()
        }
    }

    @Test fun renameDeleteLeavesBuiltInResolutionAndSourceUntouched() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.filesDir, "look-test-${UUID.randomUUID()}")
        val source = File(context.cacheDir, "managed-${UUID.randomUUID()}.cube").apply { writeText(syntheticCube()) }
        try {
            val library = LookLibrary(root)
            val imported = library.importLook(source)
            assertEquals("Renamed", library.rename(imported.id, "Renamed").name)
            assertArrayEquals(syntheticCube().toByteArray(), source.readBytes())
            val storage = PhotoStorage(context, root)
            val builtIn = storage.filmPath("velvia")
            assertTrue(builtIn?.isFile == true)
            assertFalse(builtIn!!.canonicalPath.startsWith(root.canonicalPath))
            storage.deleteLook(imported.id)
            storage.close()
            assertTrue(source.exists())
            assertFalse(imported.file(root).exists())
            assertTrue(LookChoice.builtIns.none { it.managed })
        } finally {
            root.deleteRecursively(); source.delete()
        }
    }

    @Test fun nativeProviderWithoutDisplayNameUsesValidatedCubeContainer() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.filesDir, "look-test-${UUID.randomUUID()}")
        val source = File(context.cacheDir, "provider-${UUID.randomUUID()}").apply { writeText(syntheticCube()) }
        try {
            val imported = LookLibrary(root).importLook(source, originalName = "")
            assertEquals(LookFormat.CUBE, imported.format)
            assertEquals(LookValidation(LookFormat.CUBE, 0), NativeProcessor.validateLook(imported.file(root)))
        } finally {
            root.deleteRecursively(); source.delete()
        }
    }

    private fun syntheticCube() = """
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
    """.trimIndent() + "\n"
}
