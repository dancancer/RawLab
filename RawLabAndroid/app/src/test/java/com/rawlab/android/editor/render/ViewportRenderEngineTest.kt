package com.rawlab.android.editor.render

import android.content.ComponentCallbacks2
import com.rawlab.android.editor.EditorDocumentSession
import com.rawlab.android.editor.EditorRenderGateway
import com.rawlab.android.editor.EditorViewModelTestHarness
import com.rawlab.android.editor.Operation
import com.rawlab.android.editor.TestBitmaps
import com.rawlab.android.editor.canvas.DetailTileKey
import com.rawlab.android.editor.canvas.DetailTileSpec
import com.rawlab.android.editor.canvas.NormalizedRect
import com.rawlab.android.editor.canvas.ViewportRoiRequest
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.PhotoIdentity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class ViewportRenderEngineTest {
    private fun tileOverlay(
        key: DetailTileKey,
        width: Int = 1024,
        height: Int = 1024,
        rect: NormalizedRect = NormalizedRect(0f, 0f, 0.25f, 0.25f),
        sourceRev: Long = 1L,
        editRev: Long = 1L,
        includeNeutral: Boolean = false,
    ): PreviewDetailOverlay {
        val resultBmp = TestBitmaps.stub()
        val neutralBmp = if (includeNeutral) TestBitmaps.stub() else null
        return PreviewDetailOverlay(
            neutral = neutralBmp,
            result = resultBmp,
            hdrNeutral = null,
            hdrResult = null,
            normalizedRect = rect,
            pixelWidth = width,
            pixelHeight = height,
            fullNativeWidth = 6000,
            fullNativeHeight = 4000,
            sourceRevision = sourceRev,
            editRevision = editRev,
            tileKey = key,
        )
    }

    @Test
    fun tileCacheEnforcesByteBudgetCountProtectsDesiredAndSupportsCoarseFallback() {
        val cache = ViewportTileCache(byteBudget = 12L * 1024L * 1024L, maxCount = 4)
        val k00 = DetailTileKey(0, 0, 0)
        val k10 = DetailTileKey(0, 1, 0)
        val k01 = DetailTileKey(0, 0, 1)
        val k11 = DetailTileKey(0, 1, 1)
        val k20 = DetailTileKey(0, 2, 0)

        // Each 1024x1024 RGBA8 tile is 4 MiB; budget is 12 MiB (max 3 tiles).
        cache.store(tileOverlay(k00), setOf(k00), setOf(k00))
        cache.store(tileOverlay(k10), setOf(k10), setOf(k10))
        cache.store(tileOverlay(k01), setOf(k01), setOf(k01))
        assertEquals(3, cache.count)
        assertEquals(12L * 1024L * 1024L, cache.totalBytes)

        // Touch in reverse priority so k00 (center visible) stays protected, k01 is oldest unprotected,
        // and storing k11 with desired={k00, k11} evicts k01/k10 without evicting k00.
        val spec00 = DetailTileSpec(k00, NormalizedRect(0f, 0f, 0.2f, 0.2f), 1024)
        val spec10 = DetailTileSpec(k10, NormalizedRect(0.2f, 0f, 0.4f, 0.2f), 1024)
        val spec01 = DetailTileSpec(k01, NormalizedRect(0f, 0.2f, 0.2f, 0.4f), 1024)
        val spec11 = DetailTileSpec(k11, NormalizedRect(0.2f, 0.2f, 0.4f, 0.4f), 1024)
        cache.touch(listOf(spec00, spec10, spec01))

        val evicted = cache.store(tileOverlay(k11), visibleKeys = setOf(k00, k11), desiredKeys = setOf(k00, k11, k10))
        assertEquals(listOf(k01), evicted)
        assertNotNull(cache.peek(k00))
        assertNotNull(cache.peek(k11))

        // Compare mode doubles tile bytes (8 MiB); storing k20 protects visibleKeys={k00, k20} against overscan k10.
        val evictedCompare = cache.store(
            tileOverlay(k20, includeNeutral = true),
            visibleKeys = setOf(k00, k20),
            desiredKeys = setOf(k00, k20, k10),
        )
        assertTrue(k10 in evictedCompare)
        assertNotNull(cache.peek(k00))
        assertNotNull(cache.peek(k20))

        // Coarse fallback: level 1 cached tile covers uncached level 0 visible spec.
        val coarseCache = ViewportTileCache()
        val coarseKey = DetailTileKey(1, 0, 0)
        val fineKey = DetailTileKey(0, 0, 0)
        val fineSpec = DetailTileSpec(fineKey, NormalizedRect(0f, 0f, 0.2f, 0.2f), 1024)
        coarseCache.store(
            tileOverlay(coarseKey, width = 512, height = 512, rect = NormalizedRect(0f, 0f, 0.4f, 0.4f)),
            visibleKeys = setOf(coarseKey),
            desiredKeys = setOf(coarseKey),
        )
        val activeWithFallback = coarseCache.activeTiles(allSpecs = listOf(fineSpec), visibleSpecs = listOf(fineSpec))
        assertEquals(listOf(coarseKey), activeWithFallback.map { it.tileKey })

        // Once fine tile is cached, coarse tile is no longer needed for that visible rect.
        coarseCache.store(
            tileOverlay(fineKey, width = 512, height = 512, rect = NormalizedRect(0f, 0f, 0.2f, 0.2f)),
            visibleKeys = setOf(fineKey),
            desiredKeys = setOf(fineKey),
        )
        val activeFineOnly = coarseCache.activeTiles(allSpecs = listOf(fineSpec), visibleSpecs = listOf(fineSpec))
        assertEquals(listOf(fineKey), activeFineOnly.map { it.tileKey })

        // Revision change & reclaimMemory clear all cached tiles.
        assertTrue(coarseCache.syncRevision(2L, 1L))
        assertEquals(0, coarseCache.count)
        assertEquals(0L, coarseCache.totalBytes)

        coarseCache.store(tileOverlay(fineKey, sourceRev = 2L, editRev = 1L), setOf(fineKey), setOf(fineKey))
        assertEquals(1, coarseCache.count)
        coarseCache.reclaimMemory()
        assertEquals(0, coarseCache.count)
        assertEquals(0L, coarseCache.totalBytes)
    }

    @Suppress("DEPRECATION")
    @Test
    fun viewportEngineEnforcesDetailActiveHysteresisAndMemoryTrimReclamation() {
        EditorViewModelTestHarness().use { harness ->
            val (file, uri) = harness.createTempPhoto("viewport-hysteresis.raw")
            val photo = ImportedPhoto(uri, file.name, file, PhotoIdentity("vh-1"), PhotoInputKind.RAW)
            val releaseRasterCalls = AtomicInteger()
            val releasedLatch = CountDownLatch(1)
            val gateway = object : EditorRenderGateway {
                override fun perform(work: Work, cancellation: RenderCancellation): WorkResult = harness.defaultRender(work)
                override fun releaseDecodedRaster() {
                    releaseRasterCalls.incrementAndGet()
                    releasedLatch.countDown()
                }
                override fun close() = Unit
            }
            val deps = harness.createDependencies(renderGateway = gateway, detailDebounceDelayMs = 0L, detailOverscanRing = 0)
            val session = EditorDocumentSession(deps, harness.scope)
            val engine = ViewportRenderEngine(session)
            try {
                session.incrementSourceRevision()
                session.incrementEditRevision()
                session.mutable.value = session.mutable.value.copy(
                    photo = photo,
                    edits = EditSettings(),
                    preview = TestBitmaps.pair(1600, 1067),
                    exact = true,
                    rendering = false,
                    operation = Operation.NONE,
                )

                val baseScale = 1600f / 6000f
                val hysteresisReq = ViewportRoiRequest(
                    visibleRect = NormalizedRect(0.4f, 0.4f, 0.6f, 0.6f),
                    overscanRect = NormalizedRect(0.38f, 0.38f, 0.62f, 0.62f),
                    zoomScale = baseScale * 0.92f,
                    baseScale = baseScale,
                    maxOutputLongEdge = 2048,
                )

                // Below 1.05 * baseScale while inactive -> remains inactive.
                engine.updateViewport(hysteresisReq)
                assertFalse(engine.detailActive)
                assertNull(engine.lastDetailRequest)

                // Activate above 1.05 * baseScale.
                engine.updateViewport(hysteresisReq.copy(zoomScale = 1.0f))
                assertTrue(engine.detailActive)
                assertNotNull(engine.lastDetailRequest)

                // Store a cached tile and verify hysteresis keeps detailActive true at 0.92 * baseScale.
                val k00 = DetailTileKey(0, 2, 1)
                engine.tileCache.store(
                    tileOverlay(k00, sourceRev = session.sourceRevision, editRev = session.editRevision),
                    visibleKeys = setOf(k00),
                    desiredKeys = setOf(k00),
                )
                engine.updateViewport(hysteresisReq)
                assertTrue(engine.detailActive)

                // Dropping to 0.80 * baseScale deactivates detailActive and clears overlays.
                engine.updateViewport(hysteresisReq.copy(zoomScale = baseScale * 0.80f))
                assertFalse(engine.detailActive)
                assertNull(engine.lastDetailRequest)
                assertNull(session.mutable.value.detail)
                assertTrue(session.mutable.value.detailTiles.isEmpty())

                // Re-activate and test TRIM_MEMORY_RUNNING_LOW vs TRIM_MEMORY_UI_HIDDEN.
                engine.updateViewport(hysteresisReq.copy(zoomScale = 1.0f))
                assertTrue(engine.detailActive)
                engine.tileCache.store(
                    tileOverlay(k00, sourceRev = session.sourceRevision, editRev = session.editRevision),
                    visibleKeys = setOf(k00),
                    desiredKeys = setOf(k00),
                )
                session.mutable.value = session.mutable.value.copy(
                    detailTiles = listOf(tileOverlay(k00, sourceRev = session.sourceRevision, editRev = session.editRevision)),
                )

                engine.reclaimMemory(ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW, keepLastRequest = true)
                assertEquals(0, engine.tileCache.count)
                assertTrue(session.mutable.value.detailTiles.isEmpty())
                assertNotNull(engine.lastDetailRequest)
                assertEquals(0, releaseRasterCalls.get())

                // TRIM_MEMORY_UI_HIDDEN while rendering == true must NOT release decoded raster.
                session.mutable.value = session.mutable.value.copy(rendering = true)
                engine.reclaimMemory(ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN, keepLastRequest = true)
                Thread.sleep(50)
                assertEquals(0, releaseRasterCalls.get())

                // TRIM_MEMORY_UI_HIDDEN while idle releases decoded raster via renderQueue.
                session.mutable.value = session.mutable.value.copy(rendering = false)
                engine.reclaimMemory(ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN, keepLastRequest = true)
                assertTrue(releasedLatch.await(3, TimeUnit.SECONDS))
                assertEquals(1, releaseRasterCalls.get())

                // reclaimMemory with keepLastRequest = false resets detailActive & lastDetailRequest.
                engine.reclaimMemory(ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW, keepLastRequest = false)
                assertFalse(engine.detailActive)
                assertNull(engine.lastDetailRequest)
            } finally {
                session.disposed = true
                engine.close()
                session.adjustmentQueue.close()
            }
        }
    }
}
