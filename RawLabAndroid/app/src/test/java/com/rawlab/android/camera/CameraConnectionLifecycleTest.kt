package com.rawlab.android.camera

import com.rawlab.android.R
import com.rawlab.android.camera.protocol.CameraMediaSession
import com.rawlab.android.camera.protocol.SonyMobileSession
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketAddress
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.StandardCharsets
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import javax.net.SocketFactory

class CameraConnectionLifecycleTest {

    private val fp1 = formatSha256Fingerprint("camera-key-1".toByteArray(StandardCharsets.UTF_8))
    private val fp2 = formatSha256Fingerprint("camera-key-2".toByteArray(StandardCharsets.UTF_8))
    private val loopback = InetAddress.getLoopbackAddress()

    @Test
    fun shouldStopCameraOnBackgroundPreservesTransientSystemAndAuthFlows() {
        val preservedStages = listOf(
            null,
            SonyCameraConnection.Stage.MANUAL_WIFI,
            SonyCameraConnection.Stage.PAIRING,
            SonyCameraConnection.Stage.WIFI_CONFIRMATION,
        )
        for (stage in preservedStages) {
            assertFalse(
                "Expected backgrounding to preserve stage=$stage",
                shouldStopCameraOnBackground(
                    state = CameraImportState(stage = stage),
                    hasActiveImportPreparation = false,
                    hasActiveConnectionWork = false,
                    tetherActive = false,
                ),
            )
        }

        val stoppedStages = listOf(
            SonyCameraConnection.Stage.SCANNING,
            SonyCameraConnection.Stage.BLUETOOTH,
            SonyCameraConnection.Stage.WIFI_STARTING,
            SonyCameraConnection.Stage.NETWORK,
        )
        for (stage in stoppedStages) {
            assertTrue(
                "Expected backgrounding to stop stage=$stage",
                shouldStopCameraOnBackground(
                    state = CameraImportState(stage = stage),
                    hasActiveImportPreparation = false,
                    hasActiveConnectionWork = false,
                    tetherActive = false,
                ),
            )
        }

        // Idle auth prompt lets the user read username/password from camera menu across app switches.
        val idleAuth = CameraAccessAuthPrompt("cam-1", fp1, "ssh-ed25519")
        assertFalse(
            shouldStopCameraOnBackground(
                state = CameraImportState(accessAuth = idleAuth),
                hasActiveImportPreparation = false,
                hasActiveConnectionWork = false,
                tetherActive = false,
            ),
        )
        assertTrue(
            shouldStopCameraOnBackground(
                state = CameraImportState(accessAuth = idleAuth.copy(submitting = true)),
                hasActiveImportPreparation = false,
                hasActiveConnectionWork = false,
                tetherActive = false,
            ),
        )
        assertTrue(
            shouldStopCameraOnBackground(
                state = CameraImportState(stage = SonyCameraConnection.Stage.PAIRING, transferring = true),
                hasActiveImportPreparation = false,
                hasActiveConnectionWork = false,
                tetherActive = false,
            ),
        )
        assertTrue(
            shouldStopCameraOnBackground(
                state = CameraImportState(stage = SonyCameraConnection.Stage.WIFI_CONFIRMATION),
                hasActiveImportPreparation = false,
                hasActiveConnectionWork = true,
                tetherActive = false,
            ),
        )
    }

    @Test
    fun resolveCameraAccessAuthHandlesDirectPromptSavedAndFingerprintMismatch() {
        runBlocking {
        // 1. No saved creds, direct works -> Direct (never probes SSH)
        var sshProbed = 0
        val resDirect = resolveCameraAccessAuth(
            cameraId = "cam",
            loadSaved = { null },
            probeSsh = {
                sshProbed++
                SshHostProbe(loopback, 22, fp1, "ssh-ed25519")
            },
            connectSsh = { _, _, _ -> error("unexpected") },
            tryDirect = { null },
        )
        assertTrue(resDirect is CameraAuthResolution.Direct)
        assertEquals(0, sshProbed)

        // 2. No saved creds, direct refuses, SSH probe succeeds -> PromptAuth
        val resPrompt = resolveCameraAccessAuth(
            cameraId = "cam",
            loadSaved = { null },
            probeSsh = { SshHostProbe(loopback, 22, fp1, "ssh-ed25519") },
            connectSsh = { _, _, _ -> error("unexpected") },
            tryDirect = { throw IOException("ECONNREFUSED 15740") },
        ) as CameraAuthResolution.PromptAuth
        assertEquals(fp1, resPrompt.prompt.fingerprint)
        assertFalse(resPrompt.prompt.hasSavedCredentials)
        assertFalse(resPrompt.prompt.fingerprintChanged)

        // 3. No saved creds, UnsupportedCameraException -> Failed(UNSUPPORTED)
        val resUnsupported = resolveCameraAccessAuth(
            cameraId = "cam",
            loadSaved = { null },
            probeSsh = { error("unexpected") },
            connectSsh = { _, _, _ -> error("unexpected") },
            tryDirect = { throw CameraMediaSession.UnsupportedCameraException("unsupported") },
        )
        assertEquals(CameraAuthResolution.Failed(SonyCameraConnection.Failure.UNSUPPORTED), resUnsupported)

        // 4. Saved creds, fingerprint mismatch -> PromptAuth(fingerprintChanged=true) WITHOUT sending creds!
        var connectCalls = 0
        val resMismatch = resolveCameraAccessAuth(
            cameraId = "cam",
            loadSaved = { CameraAccessAuthRecord("u1", "p1", fp1) },
            probeSsh = { SshHostProbe(loopback, 22, fp2, "ssh-ed25519") },
            connectSsh = { _, _, _ ->
                connectCalls++
                error("must not authenticate on mismatched fingerprint")
            },
            tryDirect = { error("unexpected") },
        ) as CameraAuthResolution.PromptAuth
        assertEquals(0, connectCalls)
        assertEquals(fp2, resMismatch.prompt.fingerprint)
        assertTrue(resMismatch.prompt.fingerprintChanged)
        assertEquals("u1", resMismatch.prompt.initialUser)
        assertEquals(R.string.camera_auth_fingerprint_changed, resMismatch.prompt.errorMessage)

        // 5. Saved creds, password changed on camera -> SshAuthenticationException -> PromptAuth with error
        val resBadPass = resolveCameraAccessAuth(
            cameraId = "cam",
            loadSaved = { CameraAccessAuthRecord("u1", "old-pass", fp1) },
            probeSsh = { SshHostProbe(loopback, 22, fp1, "ssh-ed25519") },
            connectSsh = { _, _, _ -> throw SshAuthenticationException("rejected") },
            tryDirect = { error("unexpected") },
        ) as CameraAuthResolution.PromptAuth
        assertEquals("u1", resBadPass.prompt.initialUser)
        assertTrue(resBadPass.prompt.hasSavedCredentials)
        assertEquals(R.string.camera_auth_failed, resBadPass.prompt.errorMessage)

        // 6. Saved creds exist, Access Auth later turned off -> falls back to direct
        var directCalled = 0
        val resFallbackDirect = resolveCameraAccessAuth(
            cameraId = "cam",
            loadSaved = { CameraAccessAuthRecord("u1", "p1", fp1) },
            probeSsh = { throw IOException("port 22 closed") },
            connectSsh = { _, _, _ -> error("unexpected") },
            tryDirect = {
                directCalled++
                null
            },
        )
        assertEquals(1, directCalled)
        assertTrue(resFallbackDirect is CameraAuthResolution.Direct)
        }
    }

    @Test
    fun openCameraImportSessionRetriesWithRemoteInitWhen0x923cRejects2005() {
        runBlocking {
        val observedOps = CopyOnWriteArrayList<Int>()
        val serverFailure = AtomicReference<Throwable?>(null)
        val remoteInitialized = AtomicBoolean(false)
        val server = ServerSocket(0, 2, InetAddress.getLoopbackAddress())
        val worker = Thread {
            try {
                server.accept().use { command ->
                    val (initType, _) = readPtpPacket(command)
                    assertEquals(1, initType)
                    writePtpPacket(command, 2, ByteArray(24))
                    server.accept().use { event ->
                        val (eventType, _) = readPtpPacket(event)
                        assertEquals(3, eventType)
                        writePtpPacket(event, 4, ByteArray(0))

                        var saw9202 = false
                        while (true) {
                            val (packetType, packetBytes) = try {
                                readPtpPacket(command)
                            } catch (_: IOException) {
                                break
                            }
                            if (packetType != 6) continue
                            val buf = ByteBuffer.wrap(packetBytes).order(ByteOrder.LITTLE_ENDIAN)
                            buf.int // phase
                            val op = buf.short.toInt() and 0xFFFF
                            val tid = buf.int
                            observedOps += op
                            when (op) {
                                0x1001 -> {
                                    val deviceData = buildSonyDeviceInfo(
                                        intArrayOf(0x1001, 0x1002, 0x9201, 0x9202, 0x923c, 0x923d),
                                    )
                                    sendPtpData(command, tid, deviceData)
                                    sendPtpResponse(command, 0x2001, tid)
                                }
                                0x1002 -> sendPtpResponse(command, 0x2001, tid)
                                0x9201 -> {
                                    val phase = buf.int
                                    if (saw9202 && phase == 3) remoteInitialized.set(true)
                                    sendPtpResponse(command, 0x2001, tid)
                                }
                                0x9202 -> {
                                    saw9202 = true
                                    sendPtpData(command, tid, leU16(0x12c))
                                    sendPtpResponse(command, 0x2001, tid)
                                }
                                0x923c -> {
                                    if (!remoteInitialized.get()) {
                                        sendPtpResponse(command, 0x2005, tid)
                                    } else {
                                        sendPtpData(command, tid, buildSingleArwPage("DSC00001.ARW", 128L, 1_700_000_000L))
                                        sendPtpResponse(command, 0x2001, tid)
                                    }
                                }
                                else -> sendPtpResponse(command, 0x2005, tid)
                            }
                        }
                    }
                }
            } catch (t: Throwable) {
                serverFailure.set(t)
            }
        }.apply { start() }

        val factory = object : SocketFactory() {
            override fun createSocket(): Socket = object : Socket() {
                override fun connect(ignored: SocketAddress?, timeout: Int) {
                    super.connect(InetSocketAddress(InetAddress.getLoopbackAddress(), server.localPort), timeout)
                }
            }
            override fun createSocket(host: String?, port: Int) = throw UnsupportedOperationException()
            override fun createSocket(host: String?, port: Int, localHost: InetAddress?, localPort: Int) = throw UnsupportedOperationException()
            override fun createSocket(host: InetAddress?, port: Int) = throw UnsupportedOperationException()
            override fun createSocket(address: InetAddress?, port: Int, localAddress: InetAddress?, localPort: Int) = throw UnsupportedOperationException()
        }

        try {
            val connected = openCameraImportSession(
                createMobile = { SonyMobileSession(factory, InetAddress.getLoopbackAddress(), UUID.randomUUID()) {} },
                createLegacy = { error("should remain on mobile session") },
                initializeRemote = false,
            )
            connected.session.close()
            assertTrue(remoteInitialized.get())
            assertEquals(1, connected.listing.assets.size)
            assertEquals("DSC00001.ARW", connected.listing.assets.single().name)
            assertEquals(listOf(0x1001, 0x1002, 0x923c), observedOps.take(3))
            assertEquals(listOf(0x9201, 0x9201, 0x9202, 0x9201, 0x923c), observedOps.takeLast(5))
            server.close()
            worker.join(3_000)
            serverFailure.get()?.let { throw AssertionError("Server failed", it) }
        } finally {
            server.close()
        }
        }
    }

    @Test
    fun openCameraImportSessionRetriesWithRemoteInitWhen0x923bRejects2005() {
        runBlocking {
        val observedOps = CopyOnWriteArrayList<Int>()
        val serverFailure = AtomicReference<Throwable?>(null)
        val remoteInitialized = AtomicBoolean(false)
        val server = ServerSocket(0, 2, InetAddress.getLoopbackAddress())
        val worker = Thread {
            try {
                server.accept().use { command ->
                    val (initType, _) = readPtpPacket(command)
                    assertEquals(1, initType)
                    writePtpPacket(command, 2, ByteArray(24))
                    server.accept().use { event ->
                        val (eventType, _) = readPtpPacket(event)
                        assertEquals(3, eventType)
                        writePtpPacket(event, 4, ByteArray(0))

                        var saw9202 = false
                        while (true) {
                            val (packetType, packetBytes) = try {
                                readPtpPacket(command)
                            } catch (_: IOException) {
                                break
                            }
                            if (packetType != 6) continue
                            val buf = ByteBuffer.wrap(packetBytes).order(ByteOrder.LITTLE_ENDIAN)
                            buf.int
                            val op = buf.short.toInt() and 0xFFFF
                            val tid = buf.int
                            observedOps += op
                            when (op) {
                                0x1001 -> {
                                    val deviceData = buildSonyDeviceInfo(
                                        intArrayOf(0x1001, 0x1002, 0x9201, 0x9202, 0x923b, 0x923c, 0x923d),
                                    )
                                    sendPtpData(command, tid, deviceData)
                                    sendPtpResponse(command, 0x2001, tid)
                                }
                                0x1002 -> sendPtpResponse(command, 0x2001, tid)
                                0x9201 -> {
                                    val phase = buf.int
                                    if (saw9202 && phase == 3) remoteInitialized.set(true)
                                    sendPtpResponse(command, 0x2001, tid)
                                }
                                0x9202 -> {
                                    saw9202 = true
                                    sendPtpData(command, tid, leU16(0x12c))
                                    sendPtpResponse(command, 0x2001, tid)
                                }
                                0x923b -> {
                                    val slot = buf.int
                                    if (!remoteInitialized.get()) {
                                        sendPtpResponse(command, 0x2005, tid)
                                    } else if (slot == 1) {
                                        sendPtpData(command, tid, leU32(1) + ByteArray(8))
                                        sendPtpResponse(command, 0x2001, tid)
                                    } else {
                                        sendPtpResponse(command, 0x201d, tid)
                                    }
                                }
                                0x923c -> {
                                    sendPtpData(command, tid, buildSingleArwPage("DSC00001.ARW", 128L, 1_700_000_000L))
                                    sendPtpResponse(command, 0x2001, tid)
                                }
                                else -> sendPtpResponse(command, 0x2005, tid)
                            }
                        }
                    }
                }
            } catch (t: Throwable) {
                serverFailure.set(t)
            }
        }.apply { start() }

        val factory = object : SocketFactory() {
            override fun createSocket(): Socket = object : Socket() {
                override fun connect(ignored: SocketAddress?, timeout: Int) {
                    super.connect(InetSocketAddress(InetAddress.getLoopbackAddress(), server.localPort), timeout)
                }
            }
            override fun createSocket(host: String?, port: Int) = throw UnsupportedOperationException()
            override fun createSocket(host: String?, port: Int, localHost: InetAddress?, localPort: Int) = throw UnsupportedOperationException()
            override fun createSocket(host: InetAddress?, port: Int) = throw UnsupportedOperationException()
            override fun createSocket(address: InetAddress?, port: Int, localAddress: InetAddress?, localPort: Int) = throw UnsupportedOperationException()
        }

        try {
            val connected = openCameraImportSession(
                createMobile = { SonyMobileSession(factory, InetAddress.getLoopbackAddress(), UUID.randomUUID()) {} },
                createLegacy = { error("should remain on mobile session") },
                initializeRemote = false,
            )
            connected.session.close()
            assertTrue(remoteInitialized.get())
            assertEquals(1, connected.listing.assets.size)
            assertEquals("DSC00001.ARW", connected.listing.assets.single().name)
            assertEquals(listOf(0x1001, 0x1002, 0x923b), observedOps.take(3))
            assertEquals(listOf(0x9201, 0x9201, 0x9202, 0x9201), observedOps.subList(3, 7))
            server.close()
            worker.join(3_000)
            serverFailure.get()?.let { throw AssertionError("Server failed", it) }
        } finally {
            server.close()
        }
        }
    }

    private fun leU16(v: Int): ByteArray = ByteBuffer.allocate(2).order(ByteOrder.LITTLE_ENDIAN).putShort(v.toShort()).array()

    private fun leU32(v: Int): ByteArray = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(v).array()

    private fun readPtpPacket(socket: Socket): Pair<Int, ByteArray> {
        val input = DataInputStream(socket.getInputStream())
        val len = Integer.reverseBytes(input.readInt())
        val type = Integer.reverseBytes(input.readInt())
        val payload = ByteArray(len - 8)
        input.readFully(payload)
        return type to payload
    }

    private fun writePtpPacket(socket: Socket, type: Int, payload: ByteArray) {
        val pkt = ByteBuffer.allocate(payload.size + 8).order(ByteOrder.LITTLE_ENDIAN)
            .putInt(payload.size + 8)
            .putInt(type)
            .put(payload)
            .array()
        socket.getOutputStream().write(pkt)
        socket.getOutputStream().flush()
    }

    private fun buildSonyDeviceInfo(ops: IntArray): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(leU16(100))
        out.write(leU32(17))
        out.write(leU16(100))
        out.write(ptpText("Sony"))
        out.write(leU16(0))
        out.write(leU32(ops.size))
        for (op in ops) out.write(leU16(op))
        out.write(ByteArray(16))
        out.write(ptpText("Sony Corporation"))
        out.write(ptpText("ILCE-7M5"))
        out.write(ptpText("1.00"))
        out.write(ptpText("fixture"))
        return out.toByteArray()
    }

    private fun ptpText(value: String): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(value.length + 1)
        out.write((value + "\u0000").toByteArray(StandardCharsets.UTF_16LE))
        return out.toByteArray()
    }

    private fun buildSingleArwPage(name: String, size: Long, created: Long): ByteArray {
        val path = "/DCIM/100MSDCF/$name\u0000".toByteArray(StandardCharsets.UTF_8)
        val out = ByteArrayOutputStream()
        out.write(ByteArray(144))
        out.write(leU32(1))
        out.write(leU32(1))
        out.write(leU32(10))
        out.write(ByteArray(20))
        out.write(leU32(created.toInt()))
        out.write(leU32((created ushr 32).toInt()))
        out.write(ByteArray(36))
        out.write(leU32(0))
        out.write(leU32(1))
        out.write(leU32(1))
        out.write(leU32(path.size))
        out.write(path)
        out.write(leU32(0))
        out.write(leU32(size.toInt()))
        out.write(leU32((size ushr 32).toInt()))
        out.write(ByteArray(32))
        out.write(ByteArray(12))
        return out.toByteArray()
    }

    private fun sendPtpData(command: Socket, tid: Int, data: ByteArray) {
        val start = ByteArrayOutputStream().apply {
            write(leU32(tid))
            write(leU32(data.size))
            write(ByteArray(4))
        }.toByteArray()
        writePtpPacket(command, 9, start)
        val end = ByteArrayOutputStream().apply {
            write(leU32(tid))
            write(data)
        }.toByteArray()
        writePtpPacket(command, 12, end)
    }

    private fun sendPtpResponse(command: Socket, code: Int, tid: Int) {
        val payload = ByteArrayOutputStream().apply {
            write(leU16(code))
            write(leU32(tid))
        }.toByteArray()
        writePtpPacket(command, 7, payload)
    }
}
