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

    @Test fun unregisteredFirstShotRemainsRecoverableAfterDisconnect() {
        val identity = CameraHardwareIdentity("ILCE-7CM2", "1234567")
        val paused = CameraTetherRun("run", "camera", "profile", 0, emptyList(), CameraImportDestination(),
            status = CameraTetherStatus.PAUSED, shutterRequestedAt = 1L, hardwareIdentity = identity)
        // 首拍还没登记成批次就断线：没有已预留原件可重验，续接只允许 rebase。
        assertEquals(emptyList<CameraImportJob>(), paused.recoveryJobs(emptyList()))
        val withBaseline = paused.copy(baseline = listOf(photo("baseline")))
        assertEquals(emptyList<CameraImportJob>(), withBaseline.recoveryJobs(emptyList()))
        // 已结束或缺机身序列号的 run 仍然不可续接。
        assertNull(paused.copy(status = CameraTetherStatus.ENDED).recoveryJobs(emptyList()))
        assertNull(paused.copy(hardwareIdentity = null).recoveryJobs(emptyList()))
    }

    @Test fun confirmAndContinueIsOfferedOnlyForStuckPausedRuns() {
        val identity = CameraHardwareIdentity("ILCE-7CM2", "1234567")
        val batch = CameraTetherBatch("unregistered-batch", listOf(photo("shot")))
        val stuck = CameraTetherRun("run", "camera", "profile", 0, emptyList(), CameraImportDestination(),
            batches = listOf(batch), status = CameraTetherStatus.PAUSED, shutterRequestedAt = 1L, hardwareIdentity = identity)
        val stuckState = CameraTetherState(phase = CameraTetherPhase.PAUSED, run = stuck, failure = CameraTetherFailure.UNKNOWN_SHOT)
        assertFalse(stuckState.canResume)
        assertTrue(stuckState.canConfirmAndContinue)
        assertTrue(stuckState.copy(failure = CameraTetherFailure.PHOTO_LIMIT).canConfirmAndContinue)
        assertFalse(stuckState.copy(failure = CameraTetherFailure.SOURCE).canConfirmAndContinue)
        assertFalse(stuckState.copy(phase = CameraTetherPhase.RECEIVING).canConfirmAndContinue)
        assertFalse(CameraTetherState(phase = CameraTetherPhase.PAUSED, failure = CameraTetherFailure.UNKNOWN_SHOT).canConfirmAndContinue)
        // 能续接时继续走重连入口；确认按钮只给无法续接的卡死 run。
        val resumable = CameraTetherState(phase = CameraTetherPhase.PAUSED,
            run = stuck.copy(batches = emptyList()), failure = CameraTetherFailure.UNKNOWN_SHOT)
        assertTrue(resumable.canResume)
        assertFalse(resumable.canConfirmAndContinue)
    }

    @Test fun resumeStaysOfferedAfterRegisteredShotOnUnverifiedBaseline() {
        val identity = CameraHardwareIdentity("ILCE-7CM2", "1234567")
        val baseline = photo("baseline")
        val shot = photo("shot")
        val run = CameraTetherRun("run", "camera", "profile", 0, listOf(baseline), CameraImportDestination(),
            batches = listOf(CameraTetherBatch("job", listOf(shot))), status = CameraTetherStatus.PAUSED, hardwareIdentity = identity)
        // 基线从未下载没有摘要；拍成第一张后（批次已登记）续接不能因此退回 null。
        val job = CameraImportJob("job", "camera", 0, listOf(
            CameraImportItem(shot, saved = MediaPhoto("content://media/job", shot.name, "Pictures/", false), digest = "x")),
            CameraJobStatus.COMPLETE)
        assertEquals(listOf(job), run.recoveryJobs(listOf(job)))
        // 已登记批次缺失时仍然拒绝续接，由「确认结果后继续」兜底。
        assertNull(run.recoveryJobs(emptyList()))
    }

    private fun photo(key: String) = CameraPhoto(key, "$key.JPG", 100, 0)
    private fun run(batches: List<CameraTetherBatch>) = CameraTetherRun("run", "camera", "profile", 0, emptyList(), CameraImportDestination(), batches)
    private fun saved(id: String, photo: CameraPhoto) = CameraImportJob(id, "camera", 0, listOf(
        CameraImportItem(photo, saved = MediaPhoto("content://media/$id", photo.name, "Pictures/", false))), CameraJobStatus.COMPLETE)
}
