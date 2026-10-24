package com.rawlab.android.settings

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.Properties

class StructuredSettingsCodecTest {
    @Test fun gradingPendingHueSurvivesStructuredSettings() {
        val json = org.json.JSONObject(SettingsCodec.encode(EditSettings()).removePrefix("v2:"))
        val grading = org.json.JSONObject("""{"shadows":{"hue":231.25,"saturation":0},"midtones":{"hue":0,"saturation":0},"highlights":{"hue":0,"saturation":0}}""")
        json.getJSONObject("settings").put("colorGrading", grading)
        val restored = SettingsCodec.decode("v2:$json")
        val result = org.json.JSONObject(SettingsCodec.encode(restored).removePrefix("v2:"))
        assertEquals(231.25, result.getJSONObject("settings").getJSONObject("colorGrading").getJSONObject("shadows").getDouble("hue"), 0.0)
    }
    @Test fun batchSettingsWritesExplicitV2AndRoundTripsDelimitedNames() {
        val settings = EditSettings(film = "look|,\n特殊", recipeID = "recipe|name")
        val encoded = SettingsCodec.encode(settings)
        assertTrue("Batch settings use a versioned structured record", encoded.startsWith("v2:"))
        assertEquals(settings, SettingsCodec.decode(encoded))
        assertThrows(Exception::class.java) { SettingsCodec.decode(encoded.replaceFirst("v2:", "v3:")) }
    }
    @Test fun photoEditWritesV2UnderTheExistingRecordKey() {
        val directory = Files.createTempDirectory("rawlab-v2-record").toFile()
        try {
            val settings = EditSettings(exposure = .75f)
            val identity = PhotoIdentity("image")
            EditStore(directory).save(identity, settings)
            val file = File(directory, "edits.properties")
            val properties = Properties().also { file.inputStream().use(it::load) }
            val key = properties.stringPropertyNames().single { it.endsWith(".values") }
            assertTrue("Photo values use a versioned structured record", properties.getProperty(key).startsWith("v2:"))
            assertEquals(settings, EditStore(directory).load(identity))
        } finally { directory.deleteRecursively() }
    }
    @Test fun toneValuesRoundTripAndRejectMalformedOrFutureRecords() {
        val settings = EditSettings(blackPoint = -37.25f, whitePoint = 42.5f, vibrance = 18.125f,
            film = "look|,\n特殊", lens = LensSettings(manual = true, profileId = "lens|,\n特殊"))
        val encoded = SettingsCodec.encode(settings)
        assertEquals(settings, SettingsCodec.decode(encoded))
        val json = org.json.JSONObject(encoded.removePrefix("v2:"))
        val variants = listOf(
            encoded.replace("\"version\":2", "\"version\":3"),
            encoded.replace("\"version\":2", "\"version\":2.0"),
            encoded.replace("\"blackPoint\":-37.25", "\"blackPoint\":-100.1"),
            encoded.replace("\"blackPoint\":-37.25", "\"blackPoint\":\"-37.25\""),
            encoded.replace("\"vibrance\":18.125", "\"vibrance\":18.125,\"vibrance\":0"),
            "v2:" + org.json.JSONObject(json.toString()).put("future", true),
            encoded + " trailing")
        for (invalid in variants) {
            assertNotEquals(encoded, invalid)
            assertThrows(Exception::class.java) { SettingsCodec.decode(invalid) }
        }
        for (bad in listOf(-100.1f, 100.1f, Float.NaN, Float.POSITIVE_INFINITY)) {
            assertThrows(IllegalArgumentException::class.java) { settings.copy(blackPoint = bad) }
            assertThrows(IllegalArgumentException::class.java) { settings.copy(whitePoint = bad) }
            assertThrows(IllegalArgumentException::class.java) { settings.copy(vibrance = bad) }
        }
    }

    @Test fun legacyRecordsStayReadableAndOnlyTheEditedPhotoMigrates() {
        val directory = Files.createTempDirectory("rawlab-v2-migration").toFile()
        try {
            val file = File(directory, "edits.properties")
            val original = EditSettings(exposure = .75f)
            val values = legacyCSVSettings(original).split(',')
            val properties = Properties()
            for (count in listOf(11, 15, 24, 49)) {
                val key = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString("legacy-$count".toByteArray())
                properties.setProperty("record.$key.values", values.take(count).joinToString(","))
            }
            file.outputStream().use { properties.store(it, null) }
            val bytes = file.readBytes()
            val store = EditStore(directory)
            for (count in listOf(11, 15, 24, 49)) {
                val identity = PhotoIdentity("legacy-$count")
                val old = store.versionedState(identity)
                assertEquals(.75f, old.settings!!.exposure)
                assertEquals(0f, old.settings.blackPoint); assertEquals(0f, old.settings.whitePoint); assertEquals(0f, old.settings.vibrance)
                assertEquals(old, store.compareAndSave(old, old.settings))
            }
            assertArrayEquals(bytes, file.readBytes())
            val identity = PhotoIdentity("legacy-49")
            val before = store.versionedState(identity)
            val changed = before.settings!!.copy(blackPoint = -37.25f, whitePoint = 42.5f, vibrance = 18.125f)
            store.compareAndSave(before, changed)
            assertEquals(changed, EditStore(directory).load(identity))
            val updated = Properties().also { file.inputStream().use(it::load) }
            for (key in properties.stringPropertyNames()) {
                val id = String(java.util.Base64.getUrlDecoder().decode(key.removePrefix("record.").removeSuffix(".values")))
                if (id != identity.value) assertEquals(properties.getProperty(key), updated.getProperty(key))
                else assertTrue(updated.getProperty(key).startsWith("v2:"))
            }
            val key = updated.stringPropertyNames().single { it.endsWith(".values") && updated.getProperty(it).startsWith("v2:") }
            updated.setProperty(key, updated.getProperty(key).replaceFirst("v2:", "v3:"))
            file.outputStream().use { updated.store(it, null) }
            val protected = file.readBytes()
            assertThrows(Exception::class.java) { store.save(PhotoIdentity("other"), EditSettings()) }
            assertArrayEquals(protected, file.readBytes())
        } finally { directory.deleteRecursively() }
    }

    @Test fun legacyBatchLengthsNeverAcquireToneValues() {
        val values = legacyPipeSettings(EditSettings()).split('|')
        for (length in listOf(12, 16, 25, 50, 51, 52, 53, 54)) {
            val old = SettingsCodec.decode(values.take(length).joinToString("|"))
            assertEquals(0f, old.blackPoint); assertEquals(0f, old.whitePoint); assertEquals(0f, old.vibrance)
        }
    }
    @Test fun unknownOuterRecordPropertiesBlockCASAndPreserveBytes() {
        val directory = Files.createTempDirectory("rawlab-future-property").toFile()
        try {
            val file = File(directory, "edits.properties")
            val properties = Properties().apply { setProperty("record.YQ.values", legacyCSVSettings(EditSettings())) }
            file.outputStream().use { properties.store(it, null) }
            val store = EditStore(directory)
            val before = store.versionedState(PhotoIdentity("a"))
            properties.setProperty("record.YQ.future", "future-editor-state")
            file.outputStream().use { properties.store(it, null) }
            val bytes = file.readBytes()
            assertThrows(Exception::class.java) { store.compareAndSave(before, before.settings!!.copy(blackPoint = 10f)) }
            assertArrayEquals(bytes, file.readBytes())
            properties.remove("record.YQ.future")
            properties.setProperty("record.YQ.values", StructuredSettingsCodec.encode(EditSettings(), "photo_edit"))
            properties.setProperty("record.YQ.processing", "rawlab,99,standard")
            file.outputStream().use { properties.store(it, null) }
            val v2Bytes = file.readBytes()
            assertThrows(Exception::class.java) { store.save(PhotoIdentity("a"), EditSettings(whitePoint = 10f)) }
            assertArrayEquals(v2Bytes, file.readBytes())
        } finally { directory.deleteRecursively() }
    }

    @Test fun oldFilmNamesWithVersionPrefixRemainReadable() {
        for (name in listOf("v2:custom-look", "v2:{custom-look}", "v3:future-named-look")) {
            val settings = EditSettings(film = name)
            assertEquals(settings, SettingsCodec.decode(legacyPipeSettings(settings)))
        }
    }

    @Test fun malformedLegacyBooleansCannotMigrateIntoValidSettings() {
        val fields = legacyPipeSettings(EditSettings()).split('|')
        for (index in listOf(8, 12)) for (bad in listOf("garbage", "2")) {
            val invalid = fields.toMutableList().also { it[index] = bad }.joinToString("|")
            assertThrows(Exception::class.java) { SettingsCodec.decode(invalid) }
        }
        val directory = Files.createTempDirectory("rawlab-invalid-old-boolean").toFile()
        try {
            for (index in listOf(7, 11)) for (bad in listOf("2", "NaN")) {
                val fields = legacyCSVSettings(EditSettings()).split(',').toMutableList().also { it[index] = bad }
                val file = File(directory, "edits.properties")
                Properties().apply { setProperty("record.YQ.values", fields.joinToString(",")) }
                    .also { props -> file.outputStream().use { props.store(it, null) } }
                val bytes = file.readBytes()
                assertThrows(Exception::class.java) { EditStore(directory) }
                assertArrayEquals(bytes, file.readBytes())
            }
        } finally { directory.deleteRecursively() }
    }

    @Test fun toneBoundsAreCheckedBeforeFloatRounding() {
        val settings = EditSettings()
        for (field in listOf("blackPoint", "whitePoint", "vibrance")) for (invalid in listOf(-100.000001, 100.000001)) {
            val json = org.json.JSONObject(SettingsCodec.encode(settings).removePrefix("v2:"))
            json.getJSONObject("settings").getJSONObject("tone").put(field, invalid)
            assertThrows(Exception::class.java) { SettingsCodec.decode("v2:$json") }
        }
    }
}
