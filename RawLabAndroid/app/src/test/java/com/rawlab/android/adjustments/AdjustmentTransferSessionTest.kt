package com.rawlab.android.adjustments

import com.rawlab.android.settings.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

class AdjustmentTransferSessionTest {
    private val a = PhotoIdentity("a")
    private val b = PhotoIdentity("b")
    private fun payload(exposure: Double = 1.0) = AdjustmentPayload(AdjustmentSource("source", true, 2),
        mapOf(AdjustmentField.EXPOSURE to AdjustmentValue.Number(exposure)))
    private fun target(id: PhotoIdentity) = AdjustmentTransferTarget(id, id.value, EditSettings(),
        AdjustmentTransferContext(id.value, true))
    private inline fun inStore(block: (File) -> Unit) {
        val directory = Files.createTempDirectory("rawlab-transfer-session").toFile()
        try { block(directory) } finally { directory.deleteRecursively() }
    }

    @Test fun partialFailureRetryDoesNotRewriteAnAlreadyUndonePhoto() = inStore { directory ->
        var writes = 0
        val store = EditStore(directory) { from, to ->
            writes++
            if (writes == 4) throw IOException("second target write failed")
            Files.move(from.toPath(), to.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
        store.save(a, EditSettings(exposure = .2f)); store.save(b, EditSettings(exposure = -.2f))
        val session = AdjustmentTransferSession(store)
        val operation = session.prepare(payload(), listOf(target(a), target(b), target(a)))
        val first = session.apply(operation)
        assertEquals(listOf(AdjustmentStatus.APPLIED, AdjustmentStatus.FAILED), first.map { it.status })
        assertEquals(1, session.transactions.single().parts.size)
        assertEquals(AdjustmentStatus.APPLIED, session.undoPhoto(a).single().status)
        val aReceipt = store.versionedState(a)
        val retried = session.apply(operation)
        assertEquals(listOf(AdjustmentStatus.APPLIED, AdjustmentStatus.APPLIED), retried.map { it.status })
        assertEquals(aReceipt, store.versionedState(a)); assertEquals(1f, store.load(b)!!.exposure)
        assertEquals(2, session.transactions.single().parts.size)
        assertEquals(listOf(b.value), session.undoTransaction(operation.id).map { it.targetID })
        assertEquals(-.2f, store.load(b)!!.exposure)
        assertEquals(2, session.redoTransaction(operation.id).size)
        assertEquals(1f, store.load(a)!!.exposure); assertEquals(1f, store.load(b)!!.exposure)
    }

    @Test fun laterEditInvalidatesOnlyThatPhotosRedoBranch() = inStore { directory ->
        val store = EditStore(directory); val session = AdjustmentTransferSession(store)
        val operation = session.prepare(payload(), listOf(target(a), target(b)))
        session.apply(operation); session.undoTransaction(operation.id)
        session.commitEdit(store.versionedState(a), EditSettings(exposure = .3f))
        assertFalse(session.canRedoPhoto(a)); assertTrue(session.canRedoPhoto(b))
        assertEquals(listOf(b.value), session.redoTransaction(operation.id).map { it.targetID })
        assertEquals(.3f, store.load(a)!!.exposure)
        val before = store.versionedState(a)
        assertEquals(AdjustmentStatus.UNCHANGED, session.commitEdit(before, before.settings!!).status)
        assertEquals(2, session.transactions.size)
    }

    @Test fun externalAndOwnABACannotOvertakeNewerHistoryHeads() = inStore { directory ->
        val store = EditStore(directory); val session = AdjustmentTransferSession(store)
        val operation = session.prepare(payload(), listOf(target(a), target(b)))
        session.apply(operation)
        val afterA = store.versionedState(a)
        EditStore(directory).save(a, EditSettings(exposure = .5f))
        EditStore(directory).save(a, afterA.settings!!)
        val blocked = session.undoTransaction(operation.id)
        assertEquals(AdjustmentStatus.CONFLICT, blocked.first().status)
        assertTrue(blocked.first().requiresHistoryDecision)
        assertEquals(1f, store.load(b)!!.exposure)
        assertEquals(listOf(AdjustmentStatus.SKIPPED, AdjustmentStatus.APPLIED),
            session.undoTransaction(operation.id, skipping = setOf(a.value)).map { it.status })
        assertNull(store.load(b))

        val current = store.versionedState(a)
        val first = session.commitEdit(current, EditSettings(exposure = .4f))
        session.commitEdit(first.saved!!, afterA.settings)
        assertEquals(AdjustmentStatus.CONFLICT, session.undoTransaction(operation.id).first().status)
        assertEquals(AdjustmentStatus.APPLIED, session.undoPhoto(a).single().status)
        assertEquals(.4f, store.load(a)!!.exposure)
    }

    @Test fun allTargetsPreflightBeforeWritesAndExplicitSkipKeepsTheOthers() = inStore { directory ->
        val store = EditStore(directory); val session = AdjustmentTransferSession(store)
        val bad = target(b).copy(validateSource = { throw IOException("source unreadable") })
        val operation = session.prepare(payload(), listOf(target(a), bad))
        assertTrue(session.apply(operation).all { it.status == AdjustmentStatus.BLOCKED })
        assertNull(store.load(a)); assertTrue(session.transactions.isEmpty())
        assertEquals(listOf(AdjustmentStatus.APPLIED, AdjustmentStatus.SKIPPED),
            session.apply(operation, skipping = setOf(b.value)).map { it.status })
        val later = session.prepare(payload(.5), listOf(target(a).copy(isCurrent = { false })))
        assertEquals(AdjustmentStatus.BLOCKED, session.apply(later).single().status)
        assertTrue(session.apply(session.prepare(payload(), emptyList())).isEmpty())
    }

    @Test fun absentNeutralEditsDoNotCreateRecordsAndUndoRestoresAbsence() = inStore { directory ->
        val store = EditStore(directory); val session = AdjustmentTransferSession(store)
        val missing = store.versionedState(a)
        assertEquals(AdjustmentStatus.UNCHANGED, session.commitEdit(missing, EditSettings(), defaultSettings = EditSettings()).status)
        assertNull(store.load(a)); assertTrue(session.transactions.isEmpty())
        val edit = session.commitEdit(missing, EditSettings(exposure = .5f))
        assertEquals(AdjustmentStatus.APPLIED, edit.status)
        session.undoPhoto(a); assertNull(store.load(a))
        val operation = session.prepare(payload(0.0), listOf(target(a)))
        assertEquals(AdjustmentStatus.UNCHANGED, session.apply(operation).single().status)
        assertTrue(session.canRedoPhoto(a)); session.redoPhoto(a)
        assertEquals(.5f, store.load(a)!!.exposure)
    }

    @Test fun failedInverseKeepsHistoryDirectionAndCanRetry() = inStore { directory ->
        var fail = false
        val store = EditStore(directory) { from, to ->
            if (fail) throw IOException("blocked")
            Files.move(from.toPath(), to.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
        val session = AdjustmentTransferSession(store)
        session.commitEdit(store.versionedState(a), EditSettings(exposure = .5f))
        val id = session.photoHistoryID(a, undo = true)!!
        fail = true
        assertEquals(AdjustmentStatus.FAILED, session.undoPhoto(a, transactionID = id).single().status)
        assertTrue(session.canUndoPhoto(a)); assertFalse(session.canRedoPhoto(a))
        fail = false
        assertEquals(AdjustmentStatus.APPLIED, session.undoPhoto(a, transactionID = id).single().status)
        assertTrue(session.canRedoPhoto(a))
    }

    @Test fun failedCopyDoesNotReplaceFrozenClipboard() = inStore { directory ->
        val session = AdjustmentTransferSession(EditStore(directory))
        val copied = session.copy(AdjustmentScope.Custom(setOf(AdjustmentField.EXPOSURE)), EditSettings(exposure = 1f), target(a).context)
        assertThrows(AdjustmentTransferException::class.java) {
            session.copy(AdjustmentScope.All, EditSettings(), target(a).context.copy(hasUncommittedDraft = true))
        }
        assertEquals(copied, session.clipboard)
    }
    @Test fun synchronizationExcludesFrozenSourceTwiceAndDoesNotTouchClipboard() = inStore { directory ->
        val store = EditStore(directory); val session = AdjustmentTransferSession(store)
        val source = PhotoIdentity("source")
        store.save(source, EditSettings(exposure = 1f)); store.save(a, EditSettings(contrast = .4f))
        val sourceBefore = store.versionedState(source)
        val clipboard = session.copy(AdjustmentScope.Custom(setOf(AdjustmentField.CONTRAST)), EditSettings(contrast = .2f), target(b).context)
        val operation = session.prepare(payload(), listOf(target(source).copy(displayName = "same.raw"),
            target(a).copy(displayName = "same.raw"), target(a)), AdjustmentHistoryTransaction.Action.SYNCHRONIZE)
        assertEquals(listOf(a.value), operation.targets.map { it.id })
        assertEquals(AdjustmentStatus.APPLIED, session.apply(operation).single().status)
        assertEquals(sourceBefore, store.versionedState(source))
        assertEquals(.4f, store.load(a)!!.contrast)
        assertEquals(clipboard, session.clipboard)
        val forgedTarget = session.prepare(payload(2.0), listOf(target(source))).targets.single()
        val forged = operation.copy(id = java.util.UUID.randomUUID(), targets = listOf(forgedTarget))
        assertEquals(AdjustmentStatus.BLOCKED, session.apply(forged).single().status)
        assertEquals(sourceBefore, store.versionedState(source))
        assertEquals(listOf(a.value), session.undoTransaction(operation.id).map { it.targetID })
        assertEquals(0f, store.load(a)!!.exposure); assertEquals(.4f, store.load(a)!!.contrast)
    }

}
