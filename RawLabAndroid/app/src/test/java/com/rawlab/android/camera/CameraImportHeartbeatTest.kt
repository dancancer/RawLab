package com.rawlab.android.camera

import com.rawlab.android.camera.protocol.CameraMediaSession
import com.rawlab.android.camera.protocol.SonyMobileSession
import java.io.IOException
import java.io.OutputStream
import java.net.SocketException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraImportHeartbeatTest {
    private class FakeSession(private val open: Boolean = true, private val failure: IOException? = null) : CameraMediaSession {
        var deviceInfoCalls = 0
        override fun isOpen() = open
        override fun deviceInfo(): SonyMobileSession.Device {
            deviceInfoCalls++
            failure?.let { throw it }
            return SonyMobileSession.Device("Sony", "ILCE-7M5", "1.00", emptySet())
        }
        override fun openSession() = Unit
        override fun listPhotos(device: SonyMobileSession.Device) = emptyList<SonyMobileSession.Asset>()
        override fun preview(asset: SonyMobileSession.Asset, large: Boolean) = ByteArray(0)
        override fun download(device: SonyMobileSession.Device, asset: SonyMobileSession.Asset,
            destination: OutputStream, progress: SonyMobileSession.Progress?) = ""
        override fun close() = Unit
    }

    @Test fun heartbeatSendsReadOnlyDeviceInfoAndKeepsHealthySession() {
        val session = FakeSession()
        assertTrue(pingCameraSession(session))
        assertEquals(1, session.deviceInfoCalls)
    }

    @Test fun heartbeatReportsClosedOrBrokenSessionAsDisconnected() {
        val closed = FakeSession(open = false)
        assertFalse(pingCameraSession(closed))
        assertEquals(0, closed.deviceInfoCalls)
        assertFalse(pingCameraSession(FakeSession(failure = SocketException("Connection reset"))))
        assertFalse(pingCameraSession(FakeSession(failure = CameraMediaSession.PhotoTransferException(
            CameraMediaSession.FailureKind.SESSION, "Session not open"))))
    }

    @Test fun cameraResponseErrorStillProvesSessionIsAlive() {
        assertTrue(pingCameraSession(FakeSession(failure = SonyMobileSession.ResponseException(0x1001, 0x2019))))
    }
}
