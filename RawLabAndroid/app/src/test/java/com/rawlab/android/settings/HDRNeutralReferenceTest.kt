package com.rawlab.android.settings

import android.net.TestUri
import com.rawlab.android.editor.render.HDRReferenceCoordinator
import com.rawlab.android.editor.render.buildHDRRenderPlan
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.photo.ImportedPhoto
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class HDRNeutralReferenceTest {
    @Test fun referenceKeepsOnlyCameraLensSettings() {
        val camera = HDRCameraDevelopmentSettings(true, 8400f, 24f, true, 2, true, true, false, "lens-id",
            HDRCameraProfile("a".repeat(64), "D65"))
        val settings = HDRSettings(exposure = 1f, temperature = 7200f, tint = 12f, contrast = 30f,
            geometry = GeometrySettings(quarterTurns = 1), cameraDevelopment = camera)
            .withDetail(HDRDetailSettings(1f, .4f, .3f, .2f))
        val before = settings.neutralGeometrySettings
        assertEquals(HDRCameraDevelopmentSettings(lensDistortion = true, lensTca = true,
            lensAutoCrop = false, lensProfile = "lens-id"), before.cameraSettings)
        assertEquals(settings.reset().copy(geometry = settings.geometry, cameraDevelopment = before.cameraDevelopment), before)
        assertEquals(camera, settings.cameraSettings)
        assertNull(HDRSettings().neutralGeometrySettings.cameraDevelopment)
        assertTrue(settings.reset().cameraSettings.isDefault)
    }

    @Test fun referenceIdentityChangesForEachLensFieldButReusesColorEdits() {
        val settings = HDRSettings(cameraDevelopment = HDRCameraDevelopmentSettings(lensDistortion = true))
        val reference = settings.neutralGeometrySettings
        for (camera in listOf(settings.cameraSettings.copy(lensDistortion = false),
            settings.cameraSettings.copy(lensTca = true), settings.cameraSettings.copy(lensAutoCrop = false),
            settings.cameraSettings.copy(lensProfile = "another lens"))) {
            assertNotEquals(reference, settings.copy(cameraDevelopment = camera).neutralGeometrySettings)
        }
        assertEquals(reference, settings.copy(exposure = 1f, cameraDevelopment =
            settings.cameraSettings.copy(customWhiteBalance = true, temperature = 8400f, tint = 24f,
                sensorExposure = true, fbddLevel = 2, cameraProfile = HDRCameraProfile("b".repeat(64), "D65"))).neutralGeometrySettings)
    }

    @Test fun renderPlanAndCacheReuseNeutralDecodeForColorEditsAndInvalidateOnLensOrGeometry() {
        val photo = ImportedPhoto(TestUri.value, "hdr.dng", File("/tmp/hdr.dng"))
        val coordinator = HDRReferenceCoordinator<String, String>()
        val decodedNeutralCameras = mutableListOf<HDRCameraDevelopmentSettings>()
        val renderedNeutralSettings = mutableListOf<HDRSettings>()

        fun runRender(edits: EditSettings, edge: Int = 1200): Pair<String, HDRCameraDevelopmentSettings> {
            val plan = buildHDRRenderPlan("stamp-1", photo, edits, edits.geometry, edge, cameraProcessingVersion = 3)
            val ref = coordinator.resolveReference(plan) { neutralCamera, neutralSettings ->
                decodedNeutralCameras += neutralCamera
                renderedNeutralSettings += neutralSettings
                "ref-${renderedNeutralSettings.size}"
            }
            return ref to plan.resultCameraSettings
        }

        val initialCamera = HDRCameraDevelopmentSettings(
            customWhiteBalance = true, temperature = 8400f, tint = 24f,
            sensorExposure = true, fbddLevel = 2,
            lensDistortion = true, lensTca = false, lensAutoCrop = true, lensProfile = "lens-a",
            cameraProfile = HDRCameraProfile("a".repeat(64), "D65"),
        )
        val initialEdits = EditSettings(hdr = HDRSettings(exposure = 0.5f, cameraDevelopment = initialCamera))
        val (firstRef, firstResultCam) = runRender(initialEdits)
        assertEquals("ref-1", firstRef)
        assertEquals(1, decodedNeutralCameras.size)
        assertEquals(initialCamera, firstResultCam)
        assertEquals(
            HDRCameraDevelopmentSettings(lensDistortion = true, lensTca = false, lensAutoCrop = true, lensProfile = "lens-a"),
            decodedNeutralCameras.single(),
        )
        assertEquals(0f, renderedNeutralSettings.single().exposure, 0f)

        // Changing color/tone/customWB/fbdd reuses both neutral decode and rendered reference.
        val colorChangedEdits = EditSettings(hdr = HDRSettings(
            exposure = 2.0f,
            contrast = 35f,
            cameraDevelopment = initialCamera.copy(temperature = 4200f, tint = -10f, fbddLevel = 0),
        ))
        val (secondRef, secondResultCam) = runRender(colorChangedEdits)
        assertEquals("ref-1", secondRef)
        assertEquals(1, decodedNeutralCameras.size)
        assertEquals(1, renderedNeutralSettings.size)
        assertEquals(4200f, secondResultCam.temperature, 0f)

        // Changing a lens field invalidates the reference key and triggers a neutral decode with new lens settings.
        val lensChangedEdits = colorChangedEdits.copy(
            hdr = colorChangedEdits.hdr!!.copy(cameraDevelopment = initialCamera.copy(lensTca = true))
        )
        val (thirdRef, _) = runRender(lensChangedEdits)
        assertEquals("ref-2", thirdRef)
        assertEquals(2, decodedNeutralCameras.size)
        assertTrue(decodedNeutralCameras.last().lensTca)
        assertFalse(decodedNeutralCameras.last().customWhiteBalance)

        // Changing geometry invalidates the reference key as well.
        val geometryChangedEdits = lensChangedEdits.copy(geometry = GeometrySettings(quarterTurns = 1))
        val (fourthRef, _) = runRender(geometryChangedEdits)
        assertEquals("ref-3", fourthRef)
        assertEquals(3, decodedNeutralCameras.size)
        assertEquals(1, renderedNeutralSettings.last().geometry.quarterTurns)
    }
}
