package com.rawlab.android.camera

import com.rawlab.android.camera.protocol.SonyTetherSession
import org.apache.sshd.common.SshConstants
import org.apache.sshd.common.config.keys.KeyUtils
import org.apache.sshd.common.keyprovider.KeyPairProvider
import org.apache.sshd.common.session.Session
import org.apache.sshd.common.util.buffer.Buffer
import org.apache.sshd.common.util.net.SshdSocketAddress
import org.apache.sshd.server.SshServer
import org.apache.sshd.server.auth.UserAuth
import org.apache.sshd.server.auth.UserAuthFactory
import org.apache.sshd.server.auth.keyboard.InteractiveChallenge
import org.apache.sshd.server.auth.keyboard.KeyboardInteractiveAuthenticator
import org.apache.sshd.server.auth.keyboard.UserAuthKeyboardInteractive
import org.apache.sshd.server.forward.ForwardingFilter
import org.apache.sshd.server.forward.TcpForwardingFilter
import org.apache.sshd.server.session.ServerSession
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.SocketTimeoutException
import java.net.URL
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.StandardCharsets
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.spec.ECGenParameterSpec
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class SonySshTunnelTest {

    private fun generateEcKeyPair(): KeyPair {
        val gen = KeyPairGenerator.getInstance("EC")
        gen.initialize(ECGenParameterSpec("secp256r1"))
        return gen.generateKeyPair()
    }

    private fun startTestSshServer(
        keyPair: KeyPair = generateEcKeyPair(),
        expectedUser: String = "sonyuser",
        expectedPass: String = "pass1234",
        allowPassword: Boolean = true,
        allowKeyboardInteractive: Boolean = true,
        twoStepEmptyChallenge: Boolean = false,
        authAttempts: AtomicInteger = AtomicInteger(0),
        forwardedHosts: CopyOnWriteArrayList<String> = CopyOnWriteArrayList(),
    ): Triple<SshServer, Int, String> {
        val server = SshServer.setUpDefaultServer()
        server.host = "127.0.0.1"
        server.port = 0
        server.keyPairProvider = KeyPairProvider.wrap(keyPair)
        server.forwardingFilter = object : ForwardingFilter {
            override fun canForwardAgent(session: Session, requestType: String) = false
            override fun canForwardX11(session: Session, requestType: String) = false
            override fun canListen(address: SshdSocketAddress, session: Session) = false
            override fun canConnect(
                type: TcpForwardingFilter.Type,
                address: SshdSocketAddress,
                session: Session,
            ): Boolean {
                forwardedHosts += address.hostName
                return type == TcpForwardingFilter.Type.Direct && address.hostName == "localhost"
            }
        }
        server.passwordAuthenticator = if (allowPassword) {
            org.apache.sshd.server.auth.password.PasswordAuthenticator { user, pass, _ ->
                authAttempts.incrementAndGet()
                user == expectedUser && pass == expectedPass
            }
        } else {
            null
        }
        if (twoStepEmptyChallenge) {
            server.userAuthFactories = listOf(
                object : UserAuthFactory {
                    override fun getName(): String = UserAuthKeyboardInteractive.NAME
                    override fun createUserAuth(session: ServerSession): UserAuth =
                        object : UserAuthKeyboardInteractive() {
                            private var stage = 0

                            override fun doInitialAuth(
                                session: ServerSession,
                                username: String,
                                auth: KeyboardInteractiveAuthenticator?,
                                buffer: Buffer,
                            ): Boolean? {
                                buffer.getString()
                                buffer.getString()
                                stage = 1
                                val challenge = InteractiveChallenge().apply {
                                    interactionName = "Sony Access Auth"
                                }
                                val pkt = session.createBuffer(SshConstants.SSH_MSG_USERAUTH_INFO_REQUEST)
                                challenge.append(pkt)
                                session.writePacket(pkt)
                                return null
                            }

                            override fun doValidateAuthResponse(
                                session: ServerSession,
                                username: String,
                                auth: KeyboardInteractiveAuthenticator?,
                                buffer: Buffer,
                            ): Boolean? {
                                val cmd = buffer.getUByte()
                                if (cmd != SshConstants.SSH_MSG_USERAUTH_INFO_RESPONSE.toInt()) {
                                    return false
                                }
                                val count = buffer.getInt()
                                val responses = List(count) { buffer.getString() }
                                if (stage == 1) {
                                    if (responses.isNotEmpty()) return false
                                    stage = 2
                                    val challenge = InteractiveChallenge().apply {
                                        interactionName = "Sony Access Auth"
                                        addPrompt("Enter Sony passcode", false)
                                    }
                                    val pkt = session.createBuffer(SshConstants.SSH_MSG_USERAUTH_INFO_REQUEST)
                                    challenge.append(pkt)
                                    session.writePacket(pkt)
                                    return null
                                }
                                authAttempts.incrementAndGet()
                                return username == expectedUser && responses == listOf(expectedPass)
                            }
                        }
                },
            )
        } else {
            server.keyboardInteractiveAuthenticator = if (allowKeyboardInteractive) {
                object : KeyboardInteractiveAuthenticator {
                    override fun generateChallenge(
                        session: ServerSession,
                        username: String,
                        lang: String,
                        subMethods: String,
                    ): InteractiveChallenge {
                        return InteractiveChallenge().apply {
                            interactionName = "Sony Access Auth"
                            addPrompt("Password: ", false)
                        }
                    }

                    override fun authenticate(
                        session: ServerSession,
                        username: String,
                        responses: List<String>,
                    ): Boolean {
                        authAttempts.incrementAndGet()
                        return username == expectedUser && responses.firstOrNull() == expectedPass
                    }
                }
            } else {
                null
            }
        }
        server.start()
        val fingerprint = KeyUtils.getFingerPrint(keyPair.public)
        return Triple(server, server.port, fingerprint)
    }

    @Test
    fun probeHostKeyExtractsSha256FingerprintWithoutAuthAttempts() {
        val authAttempts = AtomicInteger(0)
        val (server, sshPort, expectedFingerprint) = startTestSshServer(authAttempts = authAttempts)
        try {
            val probe = probeSshHostKey(
                address = InetAddress.getLoopbackAddress(),
                port = sshPort,
                timeoutMs = 3_000,
            )
            assertEquals(expectedFingerprint, probe.fingerprint)
            assertTrue(probe.keyType.startsWith("ecdsa-sha2-"))
            assertEquals(0, authAttempts.get())
        } finally {
            server.stop(true)
        }
    }

    @Test
    fun fingerprintMismatchRejectsBeforeSendingCredentials() {
        val authAttempts = AtomicInteger(0)
        val (server, sshPort, expectedFingerprint) = startTestSshServer(authAttempts = authAttempts)
        val wrongFingerprint = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        try {
            try {
                SonySshTunnel.connect(
                    address = InetAddress.getLoopbackAddress(),
                    username = "sonyuser",
                    password = "wrong-or-right-never-sent",
                    expectedFingerprint = wrongFingerprint,
                    port = sshPort,
                    timeoutMs = 3_000,
                )
                fail("Expected SshFingerprintMismatchException")
            } catch (mismatch: SshFingerprintMismatchException) {
                assertEquals(wrongFingerprint, mismatch.expectedFingerprint)
                assertEquals(expectedFingerprint, mismatch.actualFingerprint)
                assertEquals(0, authAttempts.get())
            }
        } finally {
            server.stop(true)
        }
    }

    @Test
    fun connectsWithPasswordAndForwardsTcpTraffic() {
        val (server, sshPort, expectedFingerprint) = startTestSshServer(allowKeyboardInteractive = false)
        val echoServer = ServerSocket(0, 2)
        val worker = Thread {
            echoServer.accept().use { client ->
                val buf = ByteArray(11)
                val read = client.getInputStream().read(buf)
                client.getOutputStream().write(buf, 0, read)
                client.getOutputStream().flush()
            }
        }.apply { start() }

        try {
            SonySshTunnel.connect(
                address = InetAddress.getLoopbackAddress(),
                username = "sonyuser",
                password = "pass1234",
                expectedFingerprint = expectedFingerprint,
                port = sshPort,
                timeoutMs = 3_000,
            ).use { tunnel ->
                val factory = tunnel.socketFactory(setOf(echoServer.localPort))
                factory.createSocket().use { socket ->
                    socket.connect(InetSocketAddress(InetAddress.getLoopbackAddress(), echoServer.localPort), 3_000)
                    val payload = "hello-ptpip".toByteArray(StandardCharsets.UTF_8)
                    socket.getOutputStream().write(payload)
                    socket.getOutputStream().flush()
                    val response = ByteArray(payload.size)
                    val count = socket.getInputStream().read(response)
                    assertEquals(payload.size, count)
                    assertArrayEquals(payload, response)
                }
            }
            worker.join(3_000)
        } finally {
            echoServer.close()
            server.stop(true)
        }
    }

    @Test
    fun connectsWhenServerOnlyAllowsKeyboardInteractive() {
        val (server, sshPort, expectedFingerprint) = startTestSshServer(
            allowPassword = false,
            allowKeyboardInteractive = true,
        )
        val target = ServerSocket(0, 2)
        val worker = Thread {
            target.accept().use { client ->
                client.getOutputStream().write(byteArrayOf(42))
                client.getOutputStream().flush()
            }
        }.apply { start() }

        try {
            SonySshTunnel.connect(
                address = InetAddress.getLoopbackAddress(),
                username = "sonyuser",
                password = "pass1234",
                expectedFingerprint = expectedFingerprint,
                port = sshPort,
                timeoutMs = 3_000,
            ).use { tunnel ->
                tunnel.socketFactory(setOf(target.localPort)).createSocket().use { sock ->
                    sock.connect(InetSocketAddress(InetAddress.getLoopbackAddress(), target.localPort), 3_000)
                    assertEquals(42, sock.getInputStream().read())
                }
            }
            worker.join(3_000)
        } finally {
            target.close()
            server.stop(true)
        }
    }

    @Test
    fun connectsWithTwoStepEmptyChallengeKeyboardInteractiveAndLocalhostOnlyForwarding() {
        val forwardedHosts = CopyOnWriteArrayList<String>()
        val authAttempts = AtomicInteger(0)
        val (server, sshPort, expectedFingerprint) = startTestSshServer(
            allowPassword = false,
            allowKeyboardInteractive = false,
            twoStepEmptyChallenge = true,
            authAttempts = authAttempts,
            forwardedHosts = forwardedHosts,
        )
        val target = ServerSocket(0, 2)
        val worker = Thread {
            target.accept().use { client ->
                client.getOutputStream().write(byteArrayOf(77))
                client.getOutputStream().flush()
            }
        }.apply { start() }

        try {
            SonySshTunnel.connect(
                address = InetAddress.getLoopbackAddress(),
                username = "sonyuser",
                password = "pass1234",
                expectedFingerprint = expectedFingerprint,
                port = sshPort,
                timeoutMs = 3_000,
            ).use { tunnel ->
                tunnel.socketFactory(setOf(target.localPort)).createSocket().use { sock ->
                    sock.connect(InetSocketAddress(InetAddress.getLoopbackAddress(), target.localPort), 3_000)
                    assertEquals(77, sock.getInputStream().read())
                }
            }
            worker.join(3_000)
            assertEquals(1, authAttempts.get())
            assertEquals(listOf("localhost"), forwardedHosts.toList())
        } finally {
            target.close()
            server.stop(true)
        }
    }

    @Test
    fun wrongPasswordThrowsSshAuthenticationException() {
        val (server, sshPort, expectedFingerprint) = startTestSshServer()
        try {
            try {
                SonySshTunnel.connect(
                    address = InetAddress.getLoopbackAddress(),
                    username = "sonyuser",
                    password = "bad-password",
                    expectedFingerprint = expectedFingerprint,
                    port = sshPort,
                    timeoutMs = 3_000,
                )
                fail("Expected SshAuthenticationException")
            } catch (_: SshAuthenticationException) {
                // Expected
            }
        } finally {
            server.stop(true)
        }
    }

    @Test
    fun socketFactoryRejectsUnlistedPorts() {
        val (server, sshPort, expectedFingerprint) = startTestSshServer()
        try {
            SonySshTunnel.connect(
                address = InetAddress.getLoopbackAddress(),
                username = "sonyuser",
                password = "pass1234",
                expectedFingerprint = expectedFingerprint,
                port = sshPort,
                timeoutMs = 3_000,
            ).use { tunnel ->
                val factory = tunnel.socketFactory(setOf(15740))
                try {
                    factory.createSocket().use { sock ->
                        sock.connect(InetSocketAddress(InetAddress.getLoopbackAddress(), 9999), 1_000)
                    }
                    fail("Expected IOException for disallowed port")
                } catch (_: IOException) {
                    // Expected
                }
            }
        } finally {
            server.stop(true)
        }
    }

    @Test
    fun soTimeoutThrowsWithoutLosingBytesAndIdleChannelSurvivesConnectTimeout() {
        val (server, sshPort, expectedFingerprint) = startTestSshServer()
        val backend = ServerSocket(0, 2)
        val delayedReady = CountDownLatch(1)
        val worker = Thread {
            backend.accept().use { client ->
                Thread.sleep(220)
                client.getOutputStream().write("AB".toByteArray(StandardCharsets.US_ASCII))
                client.getOutputStream().flush()
                delayedReady.countDown()
            }
            backend.accept().use { idleClient ->
                // Hold open longer than SSH connect timeoutMs (250ms), then send a byte.
                Thread.sleep(420)
                idleClient.getOutputStream().write(byteArrayOf(79))
                idleClient.getOutputStream().flush()
            }
        }.apply { start() }

        try {
            SonySshTunnel.connect(
                address = InetAddress.getLoopbackAddress(),
                username = "sonyuser",
                password = "pass1234",
                expectedFingerprint = expectedFingerprint,
                port = sshPort,
                timeoutMs = 250,
            ).use { tunnel ->
                val factory = tunnel.socketFactory(setOf(backend.localPort))
                factory.createSocket().use { timed ->
                    timed.connect(InetSocketAddress(InetAddress.getLoopbackAddress(), backend.localPort), 2_000)
                    timed.soTimeout = 70
                    val buf = ByteArray(2)
                    try {
                        timed.getInputStream().read(buf)
                        fail("Expected SocketTimeoutException")
                    } catch (_: SocketTimeoutException) {
                        // Expected; must not drop incoming bytes on retry
                    }
                    timed.soTimeout = 2_000
                    assertTrue(delayedReady.await(3, TimeUnit.SECONDS))
                    val read = timed.getInputStream().read(buf)
                    assertEquals(2, read)
                    assertArrayEquals("AB".toByteArray(StandardCharsets.US_ASCII), buf)
                }

                // Second channel with soTimeout=0 remains alive after sleeping past connect timeoutMs (250ms)
                factory.createSocket().use { idle ->
                    idle.connect(InetSocketAddress(InetAddress.getLoopbackAddress(), backend.localPort), 2_000)
                    idle.soTimeout = 0
                    assertEquals(79, idle.getInputStream().read())
                }
            }
            worker.join(3_000)
        } finally {
            backend.close()
            server.stop(true)
        }
    }

    @Test
    fun openLiveViewStreamReadsPlainAndChunkedHttpFrames() {
        val (server, sshPort, expectedFingerprint) = startTestSshServer()
        val liveServer = ServerSocket(0, 2)

        fun buildSonyLiveFramePacket(jpegBytes: ByteArray): ByteArray {
            val out = ByteArrayOutputStream()
            val header = ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN)
            header.putInt(16)
            header.putInt(jpegBytes.size)
            header.putInt(0)
            header.putInt(0)
            out.write(header.array())
            out.write(jpegBytes)
            return out.toByteArray()
        }

        val fakeJpeg = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE0.toByte(), 1, 2, 3, 4)
        val packet = buildSonyLiveFramePacket(fakeJpeg)

        val worker = Thread {
            // 1. Plain HTTP response
            liveServer.accept().use { s ->
                val reqBuf = ByteArray(512)
                s.getInputStream().read(reqBuf)
                val out = s.getOutputStream()
                out.write("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n\r\n".toByteArray(StandardCharsets.US_ASCII))
                out.write(packet)
                out.flush()
            }
            // 2. Chunked HTTP response
            liveServer.accept().use { s ->
                val reqBuf = ByteArray(512)
                s.getInputStream().read(reqBuf)
                val out = s.getOutputStream()
                out.write("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".toByteArray(StandardCharsets.US_ASCII))
                val split = packet.size / 2
                val chunk1Header = "${Integer.toHexString(split)}\r\n".toByteArray(StandardCharsets.US_ASCII)
                val chunk2Header = "${Integer.toHexString(packet.size - split)}\r\n".toByteArray(StandardCharsets.US_ASCII)
                out.write(chunk1Header)
                out.write(packet, 0, split)
                out.write("\r\n".toByteArray(StandardCharsets.US_ASCII))
                out.write(chunk2Header)
                out.write(packet, split, packet.size - split)
                out.write("\r\n0\r\n\r\n".toByteArray(StandardCharsets.US_ASCII))
                out.flush()
            }
        }.apply { start() }

        try {
            SonySshTunnel.connect(
                address = InetAddress.getLoopbackAddress(),
                username = "sonyuser",
                password = "pass1234",
                expectedFingerprint = expectedFingerprint,
                port = sshPort,
                timeoutMs = 3_000,
            ).use { tunnel ->
                val url = URL("http://127.0.0.1:${liveServer.localPort}/liveviewstream?%21test")
                tunnel.openLiveViewStream(url, timeoutMs = 3_000).use { plain ->
                    val frame = SonyTetherSession.readFrameWithMetadata(plain.inputStream)
                    assertArrayEquals(fakeJpeg, frame.jpeg)
                    assertEquals(0, frame.metadata.size)
                }
                tunnel.openLiveViewStream(url, timeoutMs = 3_000).use { chunked ->
                    val frame = SonyTetherSession.readFrameWithMetadata(chunked.inputStream)
                    assertArrayEquals(fakeJpeg, frame.jpeg)
                    assertEquals(0, frame.metadata.size)
                }
            }
            worker.join(3_000)
        } finally {
            liveServer.close()
            server.stop(true)
        }
    }

    @Test
    fun fingerprintValidationChecksCanonicalFormat() {
        val valid = formatSha256Fingerprint("test-host-key-bytes".toByteArray(StandardCharsets.UTF_8))
        assertTrue(isValidSha256Fingerprint(valid))
        assertEquals(valid, normalizeSha256Fingerprint("  $valid= "))
        assertFalse(isValidSha256Fingerprint("SHA256:short"))
        assertFalse(isValidSha256Fingerprint("MD5:aa:bb:cc"))
        assertFalse(isValidSha256Fingerprint(valid.replace('+', '-')))
    }
}
