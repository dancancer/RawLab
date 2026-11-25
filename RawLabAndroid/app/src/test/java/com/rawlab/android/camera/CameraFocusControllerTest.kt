package com.rawlab.android.camera

import com.rawlab.android.camera.protocol.SonyTetherSession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraFocusControllerTest {
    private class VirtualFocusClock(var nowMs: Long = 10_000L) {
        private data class ScheduledTask(
            val deadlineMs: Long,
            val action: () -> Unit,
            var cancelled: Boolean = false,
        )

        private val tasks = mutableListOf<ScheduledTask>()

        val scheduler = FocusScheduler { delayMs, action ->
            val task = ScheduledTask(nowMs + delayMs, action)
            tasks.add(task)
            object : FocusCancellable {
                override fun cancel() {
                    task.cancelled = true
                }
            }
        }

        fun advanceBy(ms: Long) {
            nowMs += ms
            while (true) {
                val due = tasks
                    .filter { !it.cancelled && it.deadlineMs <= nowMs }
                    .minByOrNull { it.deadlineMs } ?: break
                due.cancelled = true
                due.action()
            }
        }

        fun activeCount(): Int = tasks.count { !it.cancelled }
    }

    @Test
    fun tap_focus_expires_at_exact_1800ms_and_never_expires_while_busy() {
        val vclock = VirtualFocusClock(1_000L)
        val timeouts = mutableListOf<CameraFocusSnapshot>()
        val controller = CameraFocusController(
            clock = { vclock.nowMs },
            scheduler = vclock.scheduler,
            onTimeoutUpdate = { timeouts.add(it) },
        )

        val busySnap = controller.onTap(CameraFocusTap(u = 0.25f, v = 0.75f, x = 160, y = 360))
        assertTrue(busySnap.focusBusy)
        assertTrue(busySnap.tapActive)
        assertEquals(0.25f, busySnap.tapU!!, 1e-6f)
        assertEquals(0.75f, busySnap.tapV!!, 1e-6f)
        assertEquals(0, vclock.activeCount())

        // Advancing time while busy must never expire the reticle.
        vclock.advanceBy(5_000L)
        assertTrue(controller.snapshot().tapActive)
        assertTrue(controller.snapshot().focusBusy)
        assertTrue(timeouts.isEmpty())

        // Finish focusing -> arms exact 1800 ms timer.
        val finished = controller.onFocusFinished(succeeded = true, focusLocked = true)
        assertFalse(finished.focusBusy)
        assertTrue(finished.tapActive)
        assertTrue(finished.tapFocusLocked)
        assertEquals(1, vclock.activeCount())

        // 1799 ms: still visible.
        vclock.advanceBy(1_799L)
        assertTrue(controller.snapshot().tapActive)
        assertNotNull(controller.snapshot().tapU)
        assertTrue(timeouts.isEmpty())

        // +1 ms (= 1800 ms): expires reticle, keeps tapFocusLocked untouched.
        vclock.advanceBy(1L)
        val expired = controller.snapshot()
        assertFalse(expired.tapActive)
        assertNull(expired.tapU)
        assertNull(expired.tapV)
        assertTrue(expired.tapFocusLocked)
        assertEquals(1, timeouts.size)
        assertFalse(timeouts[0].tapActive)
    }

    @Test
    fun second_tap_supersedes_first_timer_and_generation() {
        val vclock = VirtualFocusClock(0L)
        val timeouts = mutableListOf<CameraFocusSnapshot>()
        val controller = CameraFocusController(
            clock = { vclock.nowMs },
            scheduler = vclock.scheduler,
            onTimeoutUpdate = { timeouts.add(it) },
        )

        controller.onTap(CameraFocusTap(u = 0.2f, v = 0.2f, x = 128, y = 96))
        controller.onFocusFinished(succeeded = true, focusLocked = false)

        vclock.advanceBy(1_000L)
        assertTrue(controller.snapshot().tapActive)

        // Second tap cancels old timer & starts new generation.
        controller.onTap(CameraFocusTap(u = 0.8f, v = 0.6f, x = 512, y = 288))
        assertEquals(0, vclock.activeCount())
        controller.onFocusFinished(succeeded = true, focusLocked = true)
        assertEquals(1, vclock.activeCount())

        // 800ms later (1800ms since first tap, only 800ms since second tap) -> must NOT expire.
        vclock.advanceBy(800L)
        val mid = controller.snapshot()
        assertTrue(mid.tapActive)
        assertEquals(0.8f, mid.tapU!!, 1e-6f)
        assertEquals(0.6f, mid.tapV!!, 1e-6f)
        assertTrue(timeouts.isEmpty())

        // 1000ms later (1800ms since second tap) -> expires.
        vclock.advanceBy(1_000L)
        assertFalse(controller.snapshot().tapActive)
        assertEquals(1, timeouts.size)
    }

    @Test
    fun live_frame_learns_square_ratio_suppresses_tap_reticle_and_clears_when_busy() {
        val vclock = VirtualFocusClock(100L)
        val controller = CameraFocusController(
            clock = { vclock.nowMs },
            scheduler = vclock.scheduler,
        )

        controller.onTap(CameraFocusTap(u = 0.5f, v = 0.5f, x = 320, y = 240))
        controller.onFocusFinished(succeeded = true, focusLocked = true)
        assertTrue(controller.snapshot().tapActive)

        val focusFrame = SonyTetherSession.LiveViewFocusFrame(
            SonyTetherSession.LiveViewFrameKind.FOCUS,
            0.5f,
            0.5f,
            0.12f,
            0.18f,
            true,
        )
        val liveSnap = controller.onLiveFrame(listOf(focusFrame), imageWidth = 640, imageHeight = 480)
        assertFalse(liveSnap.tapActive)
        assertEquals(1, liveSnap.focusFrames.size)
        assertNotNull(liveSnap.lastFocusSquareRatio)
        // 0.12 * (640/480) = 0.16; 0.18 * 1.0 = 0.18; mean = 0.17
        assertEquals(0.17f, liveSnap.lastFocusSquareRatio!!, 1e-5f)

        // Advancing past 1800ms after live frames took over does nothing.
        vclock.advanceBy(2_000L)
        assertEquals(1, controller.snapshot().focusFrames.size)

        // While busy, live frames must stay hidden, while preserving learned square ratio.
        val busyWithLive = controller.onTap(CameraFocusTap(u = 0.4f, v = 0.4f, x = 256, y = 192))
        assertTrue(busyWithLive.focusFrames.isEmpty())
        assertEquals(0.17f, busyWithLive.lastFocusSquareRatio!!, 1e-5f)

        val duringBusyFrame = controller.onLiveFrame(listOf(focusFrame), imageWidth = 640, imageHeight = 480)
        assertTrue(duringBusyFrame.focusFrames.isEmpty())
        assertTrue(duringBusyFrame.tapActive)
    }

    @Test
    fun failure_cancel_and_reset_clear_state_as_expected() {
        val vclock = VirtualFocusClock(0L)
        val controller = CameraFocusController(
            clock = { vclock.nowMs },
            scheduler = vclock.scheduler,
        )

        val focusFrame = SonyTetherSession.LiveViewFocusFrame(
            SonyTetherSession.LiveViewFrameKind.FOCUS,
            0.5f,
            0.5f,
            0.12f,
            0.18f,
            false,
        )
        controller.onLiveFrame(listOf(focusFrame), imageWidth = 640, imageHeight = 480)
        assertNotNull(controller.snapshot().lastFocusSquareRatio)

        // Failed focus clears tapActive and tapFocusLocked.
        controller.onTap(CameraFocusTap(u = 0.3f, v = 0.3f, x = 192, y = 144))
        val failed = controller.onFocusFinished(succeeded = false, focusLocked = false)
        assertFalse(failed.focusBusy)
        assertFalse(failed.tapActive)
        assertFalse(failed.tapFocusLocked)

        // Properties failure / cancel disappearing clears tapFocusLocked.
        controller.onTap(CameraFocusTap(u = 0.5f, v = 0.5f, x = 320, y = 240))
        controller.onFocusFinished(succeeded = true, focusLocked = true)
        controller.onProperties(canCancelTouchFocus = true, propsFocusLocked = false, propsFocusFailed = false)
        assertTrue(controller.snapshot().tapFocusLocked)
        val cancelGone = controller.onProperties(canCancelTouchFocus = false, propsFocusLocked = false, propsFocusFailed = false)
        assertFalse(cancelGone.tapFocusLocked)

        // Reset with preserveLastRatio=false clears learned ratio too.
        val wiped = controller.reset(preserveLastRatio = false)
        assertNull(wiped.lastFocusSquareRatio)
        assertFalse(wiped.tapActive)
        assertEquals(0, vclock.activeCount())
    }
}
