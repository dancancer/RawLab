package com.rawlab.android.settings

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.Properties

class ProcessingIdentityTest {
    @Test fun settingsAndBatchSnapshotsPreserveIdentity() {
        assertEquals(ProcessingIdentity.CURRENT, EditSettings().processing)
        for (identity in listOf(ProcessingIdentity.LEGACY, ProcessingIdentity.CURRENT)) {
            val settings = EditSettings(exposure = .5f, processing = identity)
            assertEquals(settings, SettingsCodec.decode(SettingsCodec.encode(settings)))
            assertEquals(identity, settings.reset().processing)
        }
        val old = legacyPipeSettings(EditSettings()).split('|').take(53).joinToString("|")
        assertEquals(ProcessingIdentity.LEGACY, SettingsCodec.decode(old).processing)
        for (invalid in listOf("rawlab,3,standard", "other,2,standard", "rawlab,2,fast", "", "rawlab,2,standard,x")) {
            assertThrows(IllegalArgumentException::class.java) { SettingsCodec.decode("$old|$invalid") }
        }
    }

    @Test fun storeRoundTripAndMissingIdentityPreserveReleasedProcessing() {
        val directory = Files.createTempDirectory("rawlab-processing").toFile()
        try {
            val photo = PhotoIdentity("processing-photo")
            EditStore(directory).save(photo, EditSettings())
            assertEquals(ProcessingIdentity.CURRENT, EditStore(directory).load(photo)?.processing)
            val file = File(directory, "edits.properties")
            val values = Properties().also { file.inputStream().use(it::load) }
            val valueKey = values.stringPropertyNames().single { it.endsWith(".values") }
            values.setProperty(valueKey, legacyCSVSettings(EditSettings()))
            val key = valueKey.removeSuffix(".values") + ".processing"
            values.remove(key)
            file.outputStream().use { values.store(it, null) }
            val legacy = EditStore(directory).load(photo)!!
            assertEquals(ProcessingIdentity.LEGACY, legacy.processing)
            EditStore(directory).save(photo, legacy.copy(exposure = .75f))
            assertEquals(ProcessingIdentity.LEGACY, EditStore(directory).load(photo)?.processing)
            values.setProperty(key, "rawlab,99,standard")
            file.outputStream().use { values.store(it, null) }
            assertThrows(IllegalArgumentException::class.java) { EditStore(directory) }
        } finally { directory.deleteRecursively() }
    }
}
