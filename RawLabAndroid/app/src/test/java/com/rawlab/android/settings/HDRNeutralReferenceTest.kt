package com.rawlab.android.settings

import com.rawlab.android.geometry.GeometrySettings
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

    @Test fun rendererUsesTheSameNeutralSettingsForCameraDecodeAndReferenceKey() {
        val source = File("src/main/java/com/rawlab/android/editor/render/EditorRenderer.kt").readText()
        assertTrue("Reference decode must use the neutral lens settings", source.contains(
            "cachedHDRSource(work.photo, info, generation, neutralSettings.cameraSettings)"))
        assertTrue("Reference key must contain the neutral settings", source.contains(
            "HDRReferenceKey(it, work.photo, neutralSettings, edge, work.edits.proRAWDecodeVersion, info.cameraProcessingVersion)"))
        assertTrue("Reference rendering must use the neutral model", source.contains(".neutralGeometrySettings"))
    }
}
