package com.rawlab.android.camera

import com.rawlab.android.photo.HDRSourceInfo
import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraJPEGProcessingTest {
    @Test fun fullSizeJpegAccountsForBitmapMemoryBeforeDecoding() {
        val available = 128L * 1024 * 1024
        assertTrue(CameraJPEGProcessing.requiredBitmapBytes(9504, 6336, 1, 9504, 6336) > available)
        assertTrue(CameraJPEGProcessing.requiredBitmapBytes(9504, 6336, 4, 2048, 1365) < available)
        assertEquals(4L * (30L * 20 + 21L * 14), CameraJPEGProcessing.requiredBitmapBytes(59, 39, 2, 21, 14))
    }

    @Test fun gainMapAdjustmentIsRejectedBeforeBitmapDecodeForEverySupportedProtocol() {
        val root = Files.createTempDirectory("camera-jpeg-hdr-test").toFile()
        try {
            val source = File(root, "source.jpg").apply { writeBytes(byteArrayOf(0xff.toByte(), 0xd8.toByte())) }
            val destination = File(root, "adjusted.jpg").apply { writeText("must-not-be-touched") }
            for (protocol in listOf(1, 2, 3, 4)) {
                val error = assertThrows(CameraJPEGGainMapAdjustmentException::class.java) {
                    CameraJPEGProcessing.processWithProbe(source, destination, CameraJPEGOptions(true, 64, 90),
                        gainMapProbe = {
                            HDRSourceInfo(1, 1, 1, 1, protocol, 1,
                                2f, 1, ByteArray(32))
                        })
                }
                assertEquals(protocol, error.protocol)
                assertEquals("must-not-be-touched", destination.readText())
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test fun gainMapProbeIsNotCalledForNonRasterSignatures() {
        val root = Files.createTempDirectory("camera-jpeg-sdr-test").toFile()
        try {
            val source = File(root, "source.bin").apply { writeText("not an image") }
            var called = false
            assertNull(CameraJPEGProcessing.probeGainMap(source, gainMapProbe = {
                called = true
                null
            }))
            assertFalse(called)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test fun adjustmentPreflightRejectsGainMapsBeforeDerivativeReuse() {
        val root = Files.createTempDirectory("camera-jpeg-preflight-test").toFile()
        try {
            val source = File(root, "source.jpg").apply { writeBytes(byteArrayOf(0xff.toByte(), 0xd8.toByte())) }
            val error = assertThrows(CameraJPEGGainMapAdjustmentException::class.java) {
                CameraJPEGProcessing.ensureAdjustmentSupported(source, gainMapProbe = {
                    HDRSourceInfo(1, 1, 1, 1, 3, 1,
                        2f, 1, ByteArray(32))
                })
            }
            assertEquals(3, error.protocol)
        } finally {
            root.deleteRecursively()
        }
    }
}
