package com.rawlab.android.presets

import com.rawlab.android.adjustments.*
import com.rawlab.android.settings.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class AdjustmentPresetApplicationTest {
    @Test fun independentPresetUsesTheSameCandidateAndHistoryWithoutChangingClipboard() {
        val directory = Files.createTempDirectory("preset-application").toFile()
        try {
            val source = File(directory, "source.raw").apply { writeText("source") }
            val session = AdjustmentTransferSession(EditStore(File(directory, "edits")))
            val context = AdjustmentTransferContext(source.absolutePath, true)
            val clipboard = session.copy(AdjustmentScope.Custom(setOf(AdjustmentField.CONTRAST)), EditSettings(contrast = .2f), context)
            val payload = AdjustmentTransfer.capture(AdjustmentScope.Custom(setOf(AdjustmentField.EXPOSURE)), EditSettings(exposure = 1.25f), context)
            val preset = AdjustmentPresetStore(File(directory, "presets")).create("Morning", payload)
            assertTrue(source.delete())
            val identity = PhotoIdentity("target")
            val target = AdjustmentTransferTarget(identity, "target", EditSettings(contrast = .3f), AdjustmentTransferContext("target", true))
            val prepared = session.prepare(preset.payload, listOf(target), AdjustmentHistoryTransaction.Action.PRESET)
            assertEquals(session.prepare(payload, listOf(target)).targets.single().candidate, prepared.targets.single().candidate)
            assertEquals(.3f, prepared.targets.single().candidate!!.contrast)
            assertEquals(AdjustmentStatus.APPLIED, session.apply(prepared).single().status)
            assertEquals(clipboard, session.clipboard)
            assertEquals(AdjustmentHistoryTransaction.Action.PRESET, session.transactions.single().action)
            assertEquals(AdjustmentStatus.APPLIED, session.undoPhoto(identity).single().status)
            assertTrue(session.canRedoPhoto(identity))
            val neutral = AdjustmentTransfer.capture(AdjustmentScope.Custom(setOf(AdjustmentField.EXPOSURE)), EditSettings(), context)
            assertEquals(AdjustmentStatus.UNCHANGED, session.apply(session.prepare(neutral, listOf(target), AdjustmentHistoryTransaction.Action.PRESET)).single().status)
            assertTrue(session.canRedoPhoto(identity))
            assertEquals(AdjustmentStatus.APPLIED, session.redoPhoto(identity).single().status)
        } finally { directory.deleteRecursively() }
    }

    @Test fun missingLookBlocksPresetBeforeAnyWrite() {
        val directory = Files.createTempDirectory("preset-missing-look").toFile()
        try {
            val store = EditStore(directory)
            val session = AdjustmentTransferSession(store)
            val payload = AdjustmentPayload(AdjustmentSource("preset:fixture", true, 2),
                mapOf(AdjustmentField.LOOK to AdjustmentValue.Object(mapOf("kind" to AdjustmentValue.Text("managed"), "id" to AdjustmentValue.Text("missing")))))
            val target = AdjustmentTransferTarget(PhotoIdentity("target"), "target", EditSettings(), AdjustmentTransferContext("target", true))
            val operation = session.prepare(payload, listOf(target), AdjustmentHistoryTransaction.Action.PRESET)
            assertEquals(AdjustmentStatus.BLOCKED, session.apply(operation).single().status)
            assertNull(store.load(target.identity)); assertTrue(session.transactions.isEmpty())
        } finally { directory.deleteRecursively() }
    }
}
