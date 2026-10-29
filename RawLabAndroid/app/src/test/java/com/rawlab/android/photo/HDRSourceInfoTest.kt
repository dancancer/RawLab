package com.rawlab.android.photo

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class HDRSourceInfoTest {
    @Test fun unknownSourceHeadroomIsDistinctFromInvalidDeclaredHeadroom() {
        val value=HDRSourceInfo(64,32,1,1,1,1,0f,0,ByteArray(32))
        assertEquals(0f,value.contentHeadroom)
        assertThrows(IllegalArgumentException::class.java) {value.copy(headroomKind=1)}
    }
    @Test
    fun parsesTheNativeSourceContractWithoutDroppingFingerprint() {
        val bytes = ByteBuffer.allocate(64).order(ByteOrder.LITTLE_ENDIAN).apply {
            putInt(4000).putInt(3000).putInt(6).putInt(2).putInt(2).putInt(2)
            putFloat(4f).putInt(1)
            repeat(32) { put(it.toByte()) }
        }.array()

        val info = HDRSourceInfo.decode(bytes)

        assertEquals(4000, info.width)
        assertEquals(3000, info.height)
        assertEquals(6, info.orientation)
        assertEquals(4f, info.contentHeadroom)
        assertEquals(32, info.fingerprint.size)
        assertEquals(0, info.fingerprint.first().toInt())
        assertEquals(31, info.fingerprint.last().toInt())
    }

    @Test
    fun rejectsMalformedNativeSourceContract() {
        assertThrows(IllegalArgumentException::class.java) { HDRSourceInfo.decode(ByteArray(63)) }
    }

    @Test
    fun onlyGainMapContainersEnterStrictHdrProbe() {
        assertTrue(HDRSourceInfo.mayContainGainMap("phone.HEIC", "image/heic"))
        assertTrue(HDRSourceInfo.mayContainGainMap("phone.jpg", "image/jpeg"))
        assertTrue(!HDRSourceInfo.mayContainGainMap("camera.png", "image/png"))
    }
}
