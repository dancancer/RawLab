package com.rawlab.android.presets

import com.rawlab.android.adjustments.AdjustmentField
import com.rawlab.android.adjustments.AdjustmentPayload
import com.rawlab.android.adjustments.AdjustmentSource
import com.rawlab.android.adjustments.AdjustmentValue
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.Callable
import java.util.concurrent.Executors

class AdjustmentPresetStoreTest {
    @get:Rule val temporary = TemporaryFolder()
    private fun payload(exposure: Double = 1.25) = AdjustmentPayload(
        AdjustmentSource("/removed/original.ARW", true, 2),
        mapOf(AdjustmentField.EXPOSURE to AdjustmentValue.Number(exposure)))

    @Test fun absentLibraryIsReadOnlyAndNamesAreNormalized() {
        val directory = File(temporary.root, "not-created")
        val store = AdjustmentPresetStore(directory, clock = { 1000 })
        assertTrue(store.list().isEmpty()); assertFalse(directory.exists())
        val first = store.create("\u200B\u0085Cafe\u0301\u00A0", payload())
        assertEquals("Café", first.name)
        assertEquals(1000, first.createdAt); assertEquals(1000, first.updatedAt)
        assertEquals(UUID.fromString(first.id).toString(), first.id)
        assertEquals("preset:${first.id}", first.payload.source.identifier)
        assertEquals(payload().values, first.payload.values)
        assertEquals(listOf(first), AdjustmentPresetStore(directory).list())
        val duplicate = assertThrows(AdjustmentPresetException::class.java) { store.create("Café", payload(2.0)) }
        assertEquals(PresetFailure.DUPLICATE_NAME, duplicate.reason); assertEquals(first, duplicate.existing)
        assertEquals(PresetFailure.EMPTY_NAME,
            assertThrows(AdjustmentPresetException::class.java) { store.create(" \u200B\u00A0", payload()) }.reason)
    }

    @Test fun renameOverwriteAndStaleConfirmationsPreserveIdentity() {
        val directory = temporary.newFolder("identity")
        val store = AdjustmentPresetStore(directory, clock = { 1000 })
        val first = store.create("A", payload())
        val renamed = store.rename(first, "B")
        assertEquals(first.id, renamed.id); assertEquals(first.createdAt, renamed.createdAt)
        assertEquals(first.payload, renamed.payload); assertEquals(1001, renamed.updatedAt)
        val replaced = store.overwrite(renamed, payload(2.0))
        assertEquals(renamed.id, replaced.id); assertEquals("B", replaced.name)
        assertEquals(2.0, replaced.payload[AdjustmentField.EXPOSURE]?.number)
        assertEquals(1002, replaced.updatedAt)
        for (action in listOf<() -> Unit>(
            { store.overwrite(first, payload(3.0)) }, { store.rename(first, "C") }, { store.delete(first) },
        )) assertEquals(PresetFailure.CHANGED, assertThrows(AdjustmentPresetException::class.java, action).reason)
        assertEquals(listOf(replaced), store.list())
        val external = AdjustmentPresetStore(directory, clock = { 0 })
        val back = external.rename(replaced, "A")
        assertEquals(1003, back.updatedAt)
        assertEquals(PresetFailure.CHANGED,
            assertThrows(AdjustmentPresetException::class.java) { store.overwrite(first, payload(5.0)) }.reason)
        assertEquals(listOf(back), store.list())
    }

    @Test fun sameValueUpdatesLeaveTheReceiptAndFileUntouched() {
        val directory = temporary.newFolder("no-op")
        val store = AdjustmentPresetStore(directory)
        val first = store.create("A", payload())
        val file = File(directory, "presets.json"); val original = file.readBytes()
        assertTrue(file.setLastModified(1000))
        assertEquals(first, store.rename(first, " A "))
        assertEquals(first, store.overwrite(first, payload()))
        assertArrayEquals(original, file.readBytes()); assertEquals(1000, file.lastModified())
    }

    @Test fun deletingOtherPresetsCannotReuseAnIdentity() {
        val directory = temporary.newFolder("retired")
        val store = AdjustmentPresetStore(directory)
        val first = store.create("A", payload()); val second = store.create("B", payload(2.0))
        store.delete(first)
        val colliding = AdjustmentPresetStore(directory, makeID = { first.id })
        assertEquals(PresetFailure.IDENTITY_COLLISION,
            assertThrows(AdjustmentPresetException::class.java) { colliding.create("C", payload()) }.reason)
        val created = store.create("C", payload(3.0))
        assertEquals(3, setOf(first.id, second.id, created.id).size)
        assertEquals(listOf(second, created), store.list())
        val liveCollision = AdjustmentPresetStore(directory, makeID = { second.id })
        assertEquals(PresetFailure.IDENTITY_COLLISION,
            assertThrows(AdjustmentPresetException::class.java) { liveCollision.create("D", payload()) }.reason)
        var calls = 0
        val retry = AdjustmentPresetStore(directory, makeID = { if (calls++ == 0) second.id else UUID.randomUUID().toString() })
        assertNotEquals(second.id, retry.create("D", payload()).id); assertEquals(2, calls)
    }

    @Test fun atomicReplacementFailureKeepsThePreviousFileAndRemovesTemporaryFiles() {
        val directory = temporary.newFolder("write-failure")
        val store = AdjustmentPresetStore(directory); val original = store.create("A", payload())
        val file = File(directory, "presets.json"); val bytes = file.readBytes()
        val failing = AdjustmentPresetStore(directory, replaceFile = { _, _ -> throw IOException("injected replacement failure") })
        for (action in listOf<() -> Unit>(
            { failing.create("B", payload()) }, { failing.rename(original, "B") },
            { failing.overwrite(original, payload(2.0)) }, { failing.delete(original) },
        )) {
            assertThrows(IOException::class.java, action)
            assertArrayEquals(bytes, file.readBytes())
            assertEquals(listOf(original), store.list())
            assertTrue(directory.listFiles()!!.none { it.extension == "tmp" })
        }
    }

    @Test fun independentConcurrentInstancesUseFreshLockedReads() {
        val directory = temporary.newFolder("concurrent")
        val executor = Executors.newFixedThreadPool(4)
        try {
            val created = executor.invokeAll((0 until 8).map { index -> Callable {
                AdjustmentPresetStore(directory).create("Item $index", payload(index.toDouble()))
            } }).map { it.get() }
            assertEquals(8, created.map { it.id }.toSet().size)
            assertEquals(created.toSet(), AdjustmentPresetStore(directory).list().toSet())
        } finally { executor.shutdownNow() }
    }

    @Test fun sharedPresetVectorsHaveTheSameAcceptanceAndFailurePreservation() {
        val directory = temporary.newFolder("vectors")
        val store = AdjustmentPresetStore(directory); val file = File(directory, "presets.json")
        val fixtures = JSONArray(File("../../Shared/fixtures/adjustment-presets-v1.json").readText())
        val registryFailures = setOf("future-registry", "unknown-registry-field", "duplicate-id", "duplicate-name",
            "invalid-retired-id", "overlapping-retired-id", "duplicate-retired-id", "registry-decimal", "registry-exponent",
            "registry-rounded-fraction", "registry-boolean", "registry-string", "registry-null", "json-unquoted-metadata-key",
            "json-single-quoted-key", "json-trailing-document", "json-trailing-comma", "json-comment",
            "duplicate-root-key", "duplicate-escaped-root-key")
        assertEquals(55, fixtures.length())
        for (index in 0 until fixtures.length()) {
            val fixture = fixtures.getJSONObject(index); val id = fixture.getString("id")
            val json = if (fixture.has("registry_json")) fixture.getString("registry_json") else fixture.getJSONObject("registry").toString()
            file.writeText(json); val bytes = file.readBytes()
            if (fixture.getBoolean("valid")) {
                val loaded = store.list()
                assertEquals(id, 1, loaded.size); assertEquals(1.25, loaded[0].payload[AdjustmentField.EXPOSURE]?.number)
            } else if (id in registryFailures) {
                assertThrows(id, AdjustmentPresetException::class.java) { store.list() }
                assertThrows(id, AdjustmentPresetException::class.java) { store.create("Blocked", payload()) }
                assertArrayEquals(id, bytes, file.readBytes())
            } else {
                // P2-16：单条目损坏只降级这一条，坏条目原文保留并可透传写回。
                try {
                    assertTrue(id, store.list().isEmpty())
                    val unreadable = store.listUnreadable()
                    assertEquals(id, 1, unreadable.size)
                    if (!fixture.has("registry_json")) assertEquals(id,
                        fixture.getJSONObject("registry").getJSONArray("presets").getJSONObject(0).toString(), unreadable[0].raw)
                    store.create("Pass Through", payload())
                    assertTrue(id, file.readText().contains(unreadable[0].raw))
                } catch (error: Exception) { throw AssertionError("$id: $error") }
            }
        }
    }

    @Test fun oneBadEntryDegradesOnlyItselfAndKeepsIdentityReserved() {
        val directory = temporary.newFolder("mixed")
        val store = AdjustmentPresetStore(directory, clock = { 1000 })
        val alpha = store.create("Alpha", payload())
        val beta = store.create("Beta", payload(2.0))
        val file = File(directory, "presets.json")
        val badID = "7c9e1b12-45a5-4e2f-9c3d-1b2a3c4d5e6f"
        val bad = "{\"id\":\"$badID\",\"name\":\"Broken\",\"created_at\":1000,\"updated_at\":1000,\"payload_version\":9}"
        file.writeText(file.readText().replaceFirst("\"presets\":[", "\"presets\":[$bad,"))
        val reloaded = AdjustmentPresetStore(directory, clock = { 2000 })
        assertEquals(listOf(alpha, beta), reloaded.list())
        val unreadable = reloaded.listUnreadable()
        assertEquals(1, unreadable.size)
        assertEquals(badID, unreadable[0].id); assertEquals("Broken", unreadable[0].name); assertEquals(bad, unreadable[0].raw)
        assertEquals(PresetFailure.DUPLICATE_NAME,
            assertThrows(AdjustmentPresetException::class.java) { reloaded.create("Broken", payload(3.0)) }.reason)
        val colliding = AdjustmentPresetStore(directory, makeID = { badID })
        assertEquals(PresetFailure.IDENTITY_COLLISION,
            assertThrows(AdjustmentPresetException::class.java) { colliding.create("Gamma", payload()) }.reason)
        reloaded.rename(alpha, "Alpha Two")
        assertTrue(file.readText().contains(bad))
        reloaded.delete(unreadable[0])
        assertFalse(file.readText().contains(bad))
        assertEquals(listOf("Alpha Two", "Beta"), reloaded.list().map { it.name })
        assertEquals(PresetFailure.CHANGED,
            assertThrows(AdjustmentPresetException::class.java) { reloaded.delete(unreadable[0]) }.reason)
    }

    @Test fun unreadableTwinKeepsTheSharedIDRetiredOnlyWhenBothGone() {
        val directory = temporary.newFolder("twin")
        val store = AdjustmentPresetStore(directory, clock = { 1000 })
        val twin = store.create("Twin", payload())
        val file = File(directory, "presets.json")
        val ghost = "{\"id\":\"${twin.id}\",\"name\":\"Ghost\",\"created_at\":1,\"updated_at\":1,\"payload_version\":9}"
        file.writeText(file.readText().replaceFirst("\"presets\":[", "\"presets\":[$ghost,"))
        val reloaded = AdjustmentPresetStore(directory, clock = { 2000 })
        assertEquals(listOf(twin), reloaded.list()); assertEquals(1, reloaded.listUnreadable().size)
        reloaded.delete(twin)
        assertTrue(file.readText().contains(ghost)); assertFalse(file.readText().contains("\"retired_ids\":[\"${twin.id}\"]"))
        reloaded.delete(reloaded.listUnreadable()[0])
        assertTrue(file.readText().contains("\"retired_ids\":[\"${twin.id}\"]"))
        assertTrue(reloaded.list().isEmpty()); assertTrue(reloaded.listUnreadable().isEmpty())
    }

    // 红锚点 B2：删除 ID 已退休的坏条目不得在 retired_ids 里写出重复 UUID（与 Windows !Contains 同守）。
    @Test fun deletingRetiredUnreadableNeverDuplicatesRetiredIDs() {
        val directory = temporary.newFolder("retired-ghost")
        val file = File(directory, "presets.json")
        val ghostID = "7c9e1b12-45a5-4e2f-9c3d-1b2a3c4d5e6f"
        val ghost = "{\"id\":\"$ghostID\",\"name\":\"Ghost\",\"created_at\":1,\"updated_at\":1,\"payload_version\":9}"
        file.writeText("{\"registry_version\":1,\"presets\":[$ghost],\"retired_ids\":[\"$ghostID\"]}")
        val store = AdjustmentPresetStore(directory)
        assertTrue(store.list().isEmpty())
        val unreadable = store.listUnreadable()
        assertEquals(1, unreadable.size)
        store.delete(unreadable[0])
        val after = file.readText()
        assertFalse(ghost, after.contains(ghost))
        assertTrue("retired_ids must stay duplicate-free: $after", after.contains("\"retired_ids\":[\"$ghostID\"]"))
        val reloaded = AdjustmentPresetStore(directory)
        assertTrue(reloaded.list().isEmpty()); assertTrue(reloaded.listUnreadable().isEmpty())
    }

    // 红锚点 B4：非数组 retired_ids 属文件级损坏，整库拒绝（Windows/Swift 同语义），不得静默吞成空列表。
    @Test fun nonArrayRetiredIDsRejectTheWholeLibrary() {
        val directory = temporary.newFolder("retired-shape")
        val store = AdjustmentPresetStore(directory)
        val file = File(directory, "presets.json")
        for (value in listOf("null", "123", "{}", "\"bad\"")) {
            val json = "{\"registry_version\":1,\"presets\":[],\"retired_ids\":$value}"
            file.writeText(json)
            val bytes = file.readBytes()
            assertEquals(value, PresetFailure.CORRUPT_LIBRARY,
                assertThrows(value, AdjustmentPresetException::class.java) { store.list() }.reason)
            assertEquals(value, PresetFailure.CORRUPT_LIBRARY,
                assertThrows(value, AdjustmentPresetException::class.java) { store.create("Blocked", payload()) }.reason)
            assertArrayEquals(value, bytes, file.readBytes())
        }
    }

    @Test fun malformedLibraryAndDuplicateRenameNeverReplaceSavedData() {
        val directory = temporary.newFolder("bad")
        val store = AdjustmentPresetStore(directory)
        val first = store.create("A", payload()); store.create("B", payload(2.0))
        assertEquals(PresetFailure.DUPLICATE_NAME,
            assertThrows(AdjustmentPresetException::class.java) { store.rename(first, "B") }.reason)
        val file = File(directory, "presets.json")
        file.writeText("{broken")
        assertThrows(AdjustmentPresetException::class.java) { store.list() }
        assertThrows(AdjustmentPresetException::class.java) { store.create("New", payload()) }
        assertEquals("{broken", file.readText())
    }
}
