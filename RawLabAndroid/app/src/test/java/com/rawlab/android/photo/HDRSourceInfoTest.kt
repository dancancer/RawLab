package com.rawlab.android.photo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class HDRSourceInfoTest {
    @Test fun proRawContainerIsAnExplicitRawCapability() {
        val source = HDRSourceInfo(8064, 6048, 1, 4, 0, 1, 0f, 0, ByteArray(32))
        assertTrue(source.isCameraRaw)
        assertTrue(source.isProRAW)
        assertTrue(!com.rawlab.android.settings.sourceDefaultSettings(true, cameraRaw = source.isCameraRaw).isHDREditing)
    }
    @Test fun unknownSourceHeadroomIsDistinctFromInvalidDeclaredHeadroom() {
        val value=HDRSourceInfo(64,32,1,1,1,1,0f,0,ByteArray(32))
        assertEquals(0f,value.contentHeadroom)
        assertThrows(IllegalArgumentException::class.java) {value.copy(headroomKind=1)}
    }
    @Test
    fun internalJniConstructorPreservesFingerprintAndCameraProcessingVersion() {
        val fingerprint = ByteArray(32) { it.toByte() }
        val info = HDRSourceInfo(
            width = 4000,
            height = 3000,
            orientation = 6,
            container = HDRSourceInfo.CONTAINER_CAMERA_RAW,
            protocol = 2,
            colorDescription = 2,
            contentHeadroom = 4f,
            headroomKind = 1,
            fingerprint = fingerprint,
            supportsBayerDevelopment = true,
            cameraProcessingVersion = 2,
        )

        assertEquals(4000, info.width)
        assertEquals(3000, info.height)
        assertEquals(6, info.orientation)
        assertEquals(4f, info.contentHeadroom)
        assertEquals(32, info.fingerprint.size)
        assertEquals(0, info.fingerprint.first().toInt())
        assertEquals(31, info.fingerprint.last().toInt())
        assertTrue(info.supportsBayerDevelopment)
        assertEquals(2, info.cameraProcessingVersion)
    }

    @Test
    fun rejectsMalformedFingerprintLength() {
        assertThrows(IllegalArgumentException::class.java) {
            HDRSourceInfo(64, 32, 1, 1, 1, 1, 0f, 0, ByteArray(31))
        }
    }

    @Test
    fun onlyGainMapContainersEnterStrictHdrProbe() {
        assertTrue(HDRSourceInfo.mayContainGainMap("phone.HEIC", "image/heic"))
        assertTrue(HDRSourceInfo.mayContainGainMap("phone.jpg", "image/jpeg"))
        assertTrue(!HDRSourceInfo.mayContainGainMap("camera.png", "image/png"))
    }

    @Test fun cameraRawContainerIsASeparateHdrCapability() {
        val value = HDRSourceInfo(64, 32, 1, HDRSourceInfo.CONTAINER_CAMERA_RAW, 0, 1, 0f, 0, ByteArray(32))
        assertTrue(value.isCameraRaw)
    }
}
