package com.rawlab.android.camera

import com.rawlab.android.photo.MediaPhoto
import org.junit.Assert.*
import org.junit.Test

class CameraTetherStateTest {
    @Test fun latestPublishedOriginalComesFromNewestBatchEvenWhenJobsAreSortedNewestFirst() {
        val old = photo("old"); val latest = photo("new")
        val run = run(listOf(CameraTetherBatch("old-job", listOf(old)), CameraTetherBatch("new-job", listOf(latest))))
        val state = CameraTetherState(run = run, jobs = listOf(saved("new-job", latest), saved("old-job", old)))
        assertEquals(listOf("new", "old"), state.saved.map { it.photo.key })
    }

    @Test fun unrelatedSavedJobCannotHidePendingOriginalFromThisRun() {
        val photo = photo("same-key")
        val state = CameraTetherState(run = run(listOf(CameraTetherBatch("pending", listOf(photo)))),
            jobs = listOf(saved("another-camera", photo)))
        assertEquals(1, state.pendingCount)
        assertTrue(state.saved.isEmpty())
    }

    @Test fun scaledHostPreviewIsNotRequiredToMatchTheCardOriginal() {
        val card = photo("original")
        assertTrue(hostDigestsForCard(listOf(CameraHostOriginal(card.name, 10, "preview")), listOf(card)).isEmpty())
        assertEquals(mapOf(card.key to "original"), hostDigestsForCard(
            listOf(CameraHostOriginal(card.name, card.size, "original")), listOf(card)))
    }

    @Test fun recoveredOrUnacknowledgedShotCannotBeResolvedByReceivingPhotos() {
        val completed = saved("new", photo("new"))
        assertFalse(canFinishShutterWait(false, emptySet(), completed))
        assertFalse(canFinishShutterWait(true, null, completed))
    }

    @Test fun onlyANewCompleteBatchFinishesTheAcknowledgedRequestWait() {
        val completed = saved("new", photo("new"))
        assertFalse(canFinishShutterWait(true, setOf("new"), completed))
        assertFalse(canFinishShutterWait(true, emptySet(), completed.copy(status = CameraJobStatus.ACTIVE)))
        assertTrue(canFinishShutterWait(true, emptySet(), completed))
    }

    @Test fun aRequestedShotChecksTheCardEvenIfTheHostNotificationIsMissing() {
        assertFalse(needsCardReconciliation(SonyCameraModel.ZVE10, false, 3_999, 0, 1_000))
        assertTrue(needsCardReconciliation(SonyCameraModel.ZVE10, false, 4_000, 0, 1_000))
        assertFalse(needsCardReconciliation(SonyCameraModel.ZVE10, false, 6_000, 5_000, 1_000))
    }

    @Test fun aHostNotificationDoesNotWaitForTheIdleCardCheck() {
        assertTrue(needsCardReconciliation(SonyCameraModel.ZVE10, true, 1_001, 1_000, 0))
        assertFalse(needsCardReconciliation(SonyCameraModel.ZVE10, false, 60_000, 1_000, 0))
    }

    private fun photo(key: String) = CameraPhoto(key, "$key.JPG", 100, 0)
    private fun run(batches: List<CameraTetherBatch>) = CameraTetherRun("run", "camera", "profile", 0, emptyList(), CameraImportDestination(), batches)
    private fun saved(id: String, photo: CameraPhoto) = CameraImportJob(id, "camera", 0, listOf(
        CameraImportItem(photo, saved = MediaPhoto("content://media/$id", photo.name, "Pictures/", false))), CameraJobStatus.COMPLETE)
}
