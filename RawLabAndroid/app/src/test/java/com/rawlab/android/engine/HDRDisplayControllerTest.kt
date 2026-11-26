package com.rawlab.android.engine

import android.content.pm.ActivityInfo
import com.rawlab.android.editor.render.canRetainBitmap
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.Executor

private class FakeDisplayHost(
    override var hasHdrTypes: Boolean = true,
    override var isHdrSdrRatioAvailable: Boolean = true,
    override var hdrSdrRatio: Float = 3.0f,
) : HDRDisplayHost {
    private var activeListener: (() -> Unit)? = null
    var registerCalls = 0
        private set
    var unregisterCalls = 0
        private set

    override fun registerRatioListener(executor: Executor, onChanged: () -> Unit): AutoCloseable? {
        if (!isHdrSdrRatioAvailable) return null
        registerCalls += 1
        activeListener = onChanged
        return AutoCloseable {
            unregisterCalls += 1
            if (activeListener === onChanged) activeListener = null
        }
    }

    fun emitRatioChange(newRatio: Float) {
        hdrSdrRatio = newRatio
        activeListener?.invoke()
    }

    fun emitStaleCallback(callback: () -> Unit) {
        callback()
    }
}

private class FakeWindowHost(
    override var sdkInt: Int = 35,
    var displayHost: HDRDisplayHost? = FakeDisplayHost(),
) : HDRWindowHost {
    val colorModes = mutableListOf<Int>()
    val desiredHeadrooms = mutableListOf<Float>()

    override fun currentDisplay(): HDRDisplayHost? = displayHost

    override fun setColorMode(mode: Int) {
        colorModes += mode
    }

    override fun setDesiredHdrHeadroom(headroom: Float) {
        desiredHeadrooms += headroom
    }
}

class HDRDisplayControllerTest {
    private val immediateExecutor = Executor { it.run() }

    @Test
    fun api35RequestsUnconstrainedDesiredHeadroomEvenWhenContentDropsToSdr() {
        val display = FakeDisplayHost(hdrSdrRatio = 4.0f)
        val window = FakeWindowHost(sdkInt = 35, displayHost = display)
        val controller = HDRDisplayController(window)

        val high = controller.refresh(surfaceReady = true, contentHeadroom = 4.0f)
        val dimmed = controller.refresh(surfaceReady = true, contentHeadroom = 1.0f)

        assertTrue(high.available)
        assertTrue(dimmed.available)
        assertEquals(listOf(ActivityInfo.COLOR_MODE_HDR), window.colorModes)
        assertEquals(listOf(0f), window.desiredHeadrooms)
    }

    @Test
    fun transientSdrRatioKeepsHdrWindowActiveAndRecoversAutomatically() {
        val display = FakeDisplayHost(hdrSdrRatio = 3.0f)
        val window = FakeWindowHost(sdkInt = 35, displayHost = display)
        val controller = HDRDisplayController(window)
        val updates = mutableListOf<HDRDisplayState>()

        controller.registerRatioChanges(immediateExecutor) { updates += it }
        val initial = controller.refresh(surfaceReady = true, contentHeadroom = 4.0f)
        assertTrue(initial.available)
        assertEquals(3.0f, initial.headroom, 1e-4f)
        assertNull(initial.reason)

        display.emitRatioChange(1.0f)
        val sdrFallback = updates.last()
        assertTrue(sdrFallback.available)
        assertEquals(1.0f, sdrFallback.headroom, 1e-4f)
        assertEquals("Display headroom is SDR", sdrFallback.reason)
        assertEquals(listOf(ActivityInfo.COLOR_MODE_HDR), window.colorModes)
        assertEquals(listOf(0f), window.desiredHeadrooms)

        display.emitRatioChange(2.75f)
        val recovered = updates.last()
        assertTrue(recovered.available)
        assertEquals(2.75f, recovered.headroom, 1e-4f)
        assertNull(recovered.reason)
    }

    @Test
    fun initialSdrRatioAfterEnablingHdrStillConfiguresWindowAndRecovers() {
        val display = FakeDisplayHost(hdrSdrRatio = 1.0f)
        val window = FakeWindowHost(sdkInt = 35, displayHost = display)
        val controller = HDRDisplayController(window)
        val updates = mutableListOf<HDRDisplayState>()

        controller.registerRatioChanges(immediateExecutor) { updates += it }
        assertFalse(controller.refresh(surfaceReady = false, contentHeadroom = 4.0f).available)

        val entered = controller.refresh(surfaceReady = true, contentHeadroom = 4.0f)
        assertTrue(entered.available)
        assertEquals(1.0f, entered.headroom, 1e-4f)
        assertEquals(ActivityInfo.COLOR_MODE_HDR, window.colorModes.last())
        assertEquals(0f, window.desiredHeadrooms.last(), 1e-6f)

        display.emitRatioChange(2.5f)
        assertTrue(updates.last().available)
        assertEquals(2.5f, updates.last().headroom, 1e-4f)
        assertNull(updates.last().reason)
    }

    @Test
    fun subQuantizationJitterDoesNotChangeHeadroom() {
        assertEquals(1.0f, quantizedHdrHeadroom(1.0f), 1e-6f)
        assertEquals(1.0f, quantizedHdrHeadroom(1.002f), 1e-6f)
        assertEquals(1.005f, quantizedHdrHeadroom(1.003f), 1e-6f)
        assertEquals(2.0f, quantizedHdrHeadroom(2.0f), 1e-6f)
        assertEquals(2.0f, quantizedHdrHeadroom(2.002f), 1e-6f)
        assertEquals(1.0f, quantizedHdrHeadroom(Float.NaN), 1e-6f)
    }

    @Test
    fun hardwareUnavailableFallsBackAndResetsDesiredHeadroom() {
        val cases = listOf(
            FakeWindowHost(sdkInt = 33, displayHost = FakeDisplayHost()),
            FakeWindowHost(sdkInt = 35, displayHost = null),
            FakeWindowHost(sdkInt = 35, displayHost = FakeDisplayHost(hasHdrTypes = false)),
            FakeWindowHost(sdkInt = 35, displayHost = FakeDisplayHost(isHdrSdrRatioAvailable = false)),
        )
        for (window in cases) {
            val controller = HDRDisplayController(window)
            val state = controller.refresh(surfaceReady = true, contentHeadroom = 4.0f)
            assertFalse(state.available)
            assertEquals(1.0f, state.headroom, 1e-6f)
            assertEquals(ActivityInfo.COLOR_MODE_DEFAULT, window.colorModes.last())
            if (window.sdkInt >= 35) {
                assertEquals(0f, window.desiredHeadrooms.last(), 1e-6f)
            }
        }
    }

    @Test
    fun closeAndFallbackResetDesiredHeadroomAndUnregisterListener() {
        var capturedCallback: (() -> Unit)? = null
        val display = object : HDRDisplayHost {
            override val hasHdrTypes = true
            override val isHdrSdrRatioAvailable = true
            override val hdrSdrRatio = 3.0f
            var unregistered = false
            override fun registerRatioListener(executor: Executor, onChanged: () -> Unit): AutoCloseable {
                capturedCallback = onChanged
                return AutoCloseable { unregistered = true }
            }
        }
        val window = FakeWindowHost(sdkInt = 35, displayHost = display)
        val controller = HDRDisplayController(window)
        val updates = mutableListOf<HDRDisplayState>()

        controller.registerRatioChanges(immediateExecutor) { updates += it }
        assertTrue(controller.refresh(surfaceReady = true, contentHeadroom = 4.0f).available)

        controller.close()
        assertTrue(display.unregistered)
        assertEquals(ActivityInfo.COLOR_MODE_DEFAULT, window.colorModes.last())
        assertEquals(0f, window.desiredHeadrooms.last(), 1e-6f)

        capturedCallback?.invoke()
        assertTrue(updates.isEmpty())
    }

    @Test
    fun ratioListenerBindsLazilyWhenDisplayAttachesOnRefresh() {
        val display = FakeDisplayHost(hdrSdrRatio = 2.5f)
        val window = FakeWindowHost(sdkInt = 35, displayHost = null)
        val controller = HDRDisplayController(window)
        val updates = mutableListOf<HDRDisplayState>()

        controller.registerRatioChanges(immediateExecutor) { updates += it }
        assertEquals(0, display.registerCalls)

        window.displayHost = display
        assertTrue(controller.refresh(surfaceReady = true, contentHeadroom = 2.0f).available)
        assertEquals(1, display.registerCalls)

        display.emitRatioChange(3.5f)
        assertEquals(3.5f, updates.single().headroom, 1e-4f)
    }

    @Test
    fun repeatedRefreshDoesNotSpamWindowAttributes() {
        val display = FakeDisplayHost(hdrSdrRatio = 3.0f)
        val window = FakeWindowHost(sdkInt = 35, displayHost = display)
        val controller = HDRDisplayController(window)

        controller.refresh(surfaceReady = true, contentHeadroom = 2.0f)
        controller.refresh(surfaceReady = true, contentHeadroom = 4.0f)
        controller.refresh(surfaceReady = true, contentHeadroom = 1.2f)

        assertEquals(1, window.colorModes.size)
        assertEquals(1, window.desiredHeadrooms.size)
    }

    @Test
    fun bitmapRetentionAllowsSameAspectResizeAndRejectsGeometryMismatch() {
        assertTrue(canRetainBitmap(480, 360, 1600, 1200))
        assertTrue(canRetainBitmap(1000, 750, 1600, 1200))
        assertFalse(canRetainBitmap(1600, 1200, 1200, 1600))
        assertFalse(canRetainBitmap(1600, 1200, 1600, 900))
        assertFalse(canRetainBitmap(0, 1200, 1600, 1200))
    }
}
