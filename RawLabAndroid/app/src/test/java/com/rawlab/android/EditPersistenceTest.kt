package com.rawlab.android

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class EditPersistenceTest {
    @Test fun failedReplacementKeepsLastDurableValueInMemory() {
        val root = Files.createTempDirectory("rawlab-atomic").toFile()
        try {
            val directory = File(root, "store")
            val store = EditStore(directory)
            val identity = PhotoIdentity("original")
            store.save(identity, EditSettings(exposure = .5f))
            assertTrue(directory.renameTo(File(root, "backup")))
            directory.writeText("blocked")
            assertThrows(Exception::class.java) { store.save(identity, EditSettings(exposure = 1f)) }
            assertEquals(.5f, store.load(identity)?.exposure)
        } finally { root.deleteRecursively() }
    }
    @Test fun uriIdentityRoundTripsAcrossStoreInstancesAndResets() {
        val directory = Files.createTempDirectory("rawlab-edits").toFile()
        try {
            val identity = PhotoIdentity("content://media/external/images/media/7")
            val changed = EditSettings(film = "velvia", exposure = .75f, contrast = .25f,
                exposureMode = 2, hsl = HslSettings().withValue(1, 0, -60f),
                highlights = .25f, customWb = true, temperature = 4200f,
                denoise = DenoiseSettings(true, 10f, 72f, 100f), displayChromaDenoise = 2,
                effects = PhotoEffectsSettings(vignetteAmount = -40f, vignetteMidpoint = 20f,
                    grainAmount = 65f, grainSize = 70f),
                recipeID = "recipe",
                lens = LensSettings(true, true, false, true, "Maker\n镜头 Model,|\nMount\n1.000000"),
                geometry = GeometrySettings(.2f, .1f, .8f, .7f, 3, true, true, -10f, .45f, -.3f))
            EditStore(directory).save(identity, changed)
            val reopened = EditStore(directory)
            assertEquals(changed, reopened.load(identity))
            val file = File(directory, "edits.properties")
            val properties = java.util.Properties().also { file.inputStream().use(it::load) }
            val key = properties.stringPropertyNames().first { it.endsWith(".values") }
            val geometryKey = key.removeSuffix(".values") + ".geometry"
            properties.setProperty(geometryKey, "1,0.2,0.1,0.8,0.7,3,1,1,-10.0")
            file.outputStream().use { properties.store(it, null) }
            assertEquals(changed.copy(geometry = changed.geometry.copy(perspectiveHorizontal = 0f,
                perspectiveVertical = 0f)), EditStore(directory).load(identity))
            properties.setProperty(key, properties.getProperty(key).split(',').take(24).joinToString(","))
            properties.remove(key.removeSuffix(".values") + ".lens")
            properties.remove(geometryKey)
            file.outputStream().use { properties.store(it, null) }
            val legacy = EditStore(directory).load(identity)!!
            assertEquals(0, legacy.exposureMode)
            assertTrue(legacy.hsl.isIdentity)
            assertEquals(LensSettings(), legacy.lens)
            assertEquals(GeometrySettings(), legacy.geometry)
            assertNull(reopened.load(PhotoIdentity("content://media/external/images/media/8")))
            reopened.reset(identity)
            assertNull(EditStore(directory).load(identity))
        } finally { directory.deleteRecursively() }
    }

    @Test fun sameBasenameAndFailedWriteDoNotCrossContaminate() {
        val directory = Files.createTempDirectory("rawlab-edits").toFile()
        try {
            val first = PhotoIdentity("content://one/IMG_0001.ARW")
            val second = PhotoIdentity("content://two/IMG_0001.ARW")
            EditStore(directory).save(first, EditSettings(exposure = .5f))
            EditStore(directory).save(second, EditSettings(exposure = -.5f))
            assertEquals(.5f, EditStore(directory).load(first)?.exposure)
            assertEquals(-.5f, EditStore(directory).load(second)?.exposure)

            val broken = File(directory, "not-a-directory")
            broken.writeText("occupied")
            assertThrows(Exception::class.java) { EditStore(File(broken, "child")).save(first, EditSettings()) }
        } finally { directory.deleteRecursively() }
    }
}
