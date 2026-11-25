package com.rawlab.android.editor.canvas

import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.EditSettings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.math.hypot

class ViewportNativeTest {
    @Test
    fun pyramidLevelTilesGridAndOverlayCoverageMatchCoreContract() {
        val baseScale = 1600f / 6000f
        assertNull(ViewportNative.pyramidLevel(baseScale * 1.04f, baseScale))
        assertEquals(1, ViewportNative.pyramidLevel(0.45f, baseScale))
        assertEquals(0, ViewportNative.pyramidLevel(1.0f, baseScale))
        assertEquals(0, ViewportNative.pyramidLevel(0.5f, 3072f / 8064f))

        val center = NormalizedRect(0.40f, 0.35f, 0.60f, 0.65f)
        val specs = ViewportNative.pyramidTiles(center, 6000, 4000, 1.0f, baseScale)
        assertTrue(specs.isNotEmpty())
        assertTrue(specs.all { it.key.level == 0 && it.maxOutputLongEdge == 1024 })
        val firstDist = hypot(
            ((specs[0].rect.x0 + specs[0].rect.x1) * 0.5f - 0.5f).toDouble(),
            ((specs[0].rect.y0 + specs[0].rect.y1) * 0.5f - 0.5f).toDouble(),
        )
        val lastDist = hypot(
            ((specs.last().rect.x0 + specs.last().rect.x1) * 0.5f - 0.5f).toDouble(),
            ((specs.last().rect.y0 + specs.last().rect.y1) * 0.5f - 0.5f).toDouble(),
        )
        assertTrue(firstDist <= lastDist + 1e-5)

        val edgeSpecs = ViewportNative.pyramidTiles(NormalizedRect(0.90f, 0.85f, 1.0f, 1.0f), 6000, 4000, 1.0f, baseScale)
        assertEquals(1, edgeSpecs.size)
        assertEquals(DetailTileKey(0, 5, 3), edgeSpecs[0].key)
        assertEquals(928, edgeSpecs[0].maxOutputLongEdge)

        val withRing = ViewportNative.pyramidTiles(center, 6000, 4000, 1.0f, baseScale, overscanRing = 1)
        assertTrue(withRing.size > specs.size)
        assertEquals(specs, withRing.take(specs.size))
        assertEquals(withRing.size, withRing.map { it.key }.distinct().size)

        val grid = ViewportNative.pyramidLevel0Grid(6000, 4000, tileSize = 1024)
        assertEquals(24, grid.size)

        val overscan = NormalizedRect(0.38f, 0.23f, 0.62f, 0.77f)
        assertTrue(
            ViewportNative.detailOverlayCovers(
                normalizedRect = overscan,
                pixelWidth = 1440,
                pixelHeight = 2160,
                fullNativeWidth = 6000,
                fullNativeHeight = 4000,
                visibleRect = NormalizedRect(0.385f, 0.235f, 0.585f, 0.685f),
                requiredZoomScale = 1f,
            ),
        )
        assertFalse(
            ViewportNative.detailOverlayCovers(
                normalizedRect = overscan,
                pixelWidth = 1440,
                pixelHeight = 2160,
                fullNativeWidth = 6000,
                fullNativeHeight = 4000,
                visibleRect = NormalizedRect(0.35f, 0.235f, 0.55f, 0.685f),
                requiredZoomScale = 1f,
            ),
        )
        assertTrue(
            ViewportNative.detailOverlayCovers(
                normalizedRect = NormalizedRect(0.2f, 0.2f, 0.6f, 0.6f),
                pixelWidth = 1280,
                pixelHeight = 853,
                fullNativeWidth = 6000,
                fullNativeHeight = 4000,
                visibleRect = NormalizedRect(0.25f, 0.25f, 0.55f, 0.55f),
                requiredZoomScale = 1f,
                maxOutputLongEdge = 1280,
            ),
        )
    }

    @Test
    fun supportsFastFullResGpuRespectsCpuModeAndInputKind() {
        NativeProcessor(NativeProcessor.CPU).use { cpu ->
            val supported = cpu.supportsFastFullResGpu(
                input = File("/tmp/sample.arw"),
                settings = EditSettings(),
                nativeWidth = 6000,
                nativeHeight = 4000,
                maxPixels = 28_000_000,
                inputKind = PhotoInputKind.RAW,
            )
            assertFalse(supported)
        }
        NativeProcessor(NativeProcessor.AUTO).use { auto ->
            val rasterSupported = auto.supportsFastFullResGpu(
                input = File("/tmp/sample.jpg"),
                settings = EditSettings(),
                nativeWidth = 6000,
                nativeHeight = 4000,
                maxPixels = 28_000_000,
                inputKind = PhotoInputKind.RASTER,
            )
            assertFalse(rasterSupported)
            assertNotNull(ViewportNative.pyramidLevel(1f, 0.25f))
        }
    }
}
