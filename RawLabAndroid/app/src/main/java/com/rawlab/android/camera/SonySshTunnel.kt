package com.rawlab.android.camera

import com.jcraft.jsch.ChannelDirectTCPIP
import com.jcraft.jsch.HostKey
import com.jcraft.jsch.HostKeyRepository
import com.jcraft.jsch.JSch
import com.jcraft.jsch.JSchException
import com.jcraft.jsch.Session
import com.jcraft.jsch.UIKeyboardInteractive
import com.jcraft.jsch.UserInfo
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.InterruptedIOException
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketAddress
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.Base64
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.locks.ReentrantLock
import javax.net.SocketFactory
import kotlin.concurrent.withLock

internal data class SshHostProbe(
    val address: InetAddress,
    val port: Int,
    val fingerprint: String,
    val keyType: String,
)

internal class SshFingerprintMismatchException(
    val expectedFingerprint: String,
    val actualFingerprint: String,
    val keyType: String,
) : IOException("Camera SSH host key fingerprint mismatch (expected=$expectedFingerprint, actual=$actualFingerprint)")

internal class SshAuthenticationException(
    message: String,
    cause: Throwable? = null,
) : IOException(message, cause)

internal class CameraLiveStream(
    val inputStream: InputStream,
    private val onClose: () -> Unit,
) : Closeable {
    private val closed = AtomicBoolean(false)

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        runCatching { inputStream.close() }
        runCatching { onClose() }
    }
}

internal fun formatSha256Fingerprint(keyBlob: ByteArray): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(keyBlob)
    return "SHA256:" + Base64.getEncoder().withoutPadding().encodeToString(digest)
}

internal fun normalizeSha256Fingerprint(value: String): String? {
    val trimmed = value.trim()
    if (!trimmed.startsWith("SHA256:")) return null
    val rawPayload = trimmed.removePrefix("SHA256:")
    if (rawPayload.length !in 43..44) return null
    val unpadded = if (rawPayload.endsWith("=")) rawPayload.dropLast(1) else rawPayload
    if (unpadded.length != 43 || unpadded.any { it.isWhitespace() || it == '-' || it == '_' }) return null
    val decoded = try {
        Base64.getDecoder().decode(rawPayload)
    } catch (_: IllegalArgumentException) {
        return null
    }
    if (decoded.size != 32) return null
    val canonical = "SHA256:" + Base64.getEncoder().withoutPadding().encodeToString(decoded)
    return if (canonical.removePrefix("SHA256:") == unpadded) canonical else null
}

internal fun isValidSha256Fingerprint(value: String): Boolean = normalizeSha256Fingerprint(value) != null

internal fun parseSshKeyAlgorithm(keyBlob: ByteArray): String {
    if (keyBlob.size < 4) return "unknown"
    val len = ByteBuffer.wrap(keyBlob, 0, 4).order(ByteOrder.BIG_ENDIAN).int
    if (len <= 0 || len > keyBlob.size - 4 || len > 128) return "unknown"
    return String(keyBlob, 4, len, StandardCharsets.US_ASCII)
}

internal fun probeSshHostKey(
    address: InetAddress,
    port: Int = SonySshTunnel.DEFAULT_SSH_PORT,
    rawSocketFactory: SocketFactory = SocketFactory.getDefault(),
    timeoutMs: Int = SonySshTunnel.DEFAULT_TIMEOUT_MS,
): SshHostProbe {
    val jsch = JSch()
    var probed: SshHostProbe? = null
    val rawSocketHolder = arrayOfNulls<Socket>(1)
    val session = jsch.getSession("probe", address.hostAddress ?: address.hostName, port).apply {
        timeout = timeoutMs
        setConfig("StrictHostKeyChecking", "yes")
        setConfig("PreferredAuthentications", "none")
        setConfig("enable_auth_none", "yes")
        setSocketFactory(BoundJschSocketFactory(address, rawSocketFactory, timeoutMs, rawSocketHolder))
        setHostKeyRepository(object : HostKeyRepository {
            override fun check(host: String?, key: ByteArray?): Int {
                if (key != null) {
                    probed = SshHostProbe(
                        address = address,
                        port = port,
                        fingerprint = formatSha256Fingerprint(key),
                        keyType = parseSshKeyAlgorithm(key),
                    )
                }
                // Reject before userauth so no credentials or auth requests leave the client.
                return HostKeyRepository.NOT_INCLUDED
            }

            override fun add(hostkey: HostKey?, userinfo: UserInfo?) = Unit
            override fun remove(host: String?, type: String?) = Unit
            override fun remove(host: String?, type: String?, key: ByteArray?) = Unit
            override fun getKnownHostsRepositoryID(): String = "sony-probe"
            override fun getHostKey(): Array<HostKey> = emptyArray()
            override fun getHostKey(host: String?, type: String?): Array<HostKey> = emptyArray()
        })
    }

    try {
        session.connect(timeoutMs)
    } catch (error: Exception) {
        probed?.let { return it }
        throw IOException("Failed to probe camera SSH host key: ${error.message}", error)
    } finally {
        runCatching { session.disconnect() }
        runCatching { rawSocketHolder[0]?.close() }
    }
    return probed ?: throw IOException("Camera SSH server did not present a host key")
}

internal class SonySshTunnel private constructor(
    private val address: InetAddress,
    private val sshPort: Int,
    private val session: Session,
    private val rawSocket: Socket?,
    val hostProbe: SshHostProbe,
) : Closeable {

    private val closed = AtomicBoolean(false)
    private val activeChannels = ConcurrentHashMap.newKeySet<Closeable>()

    fun socketFactory(allowedPorts: Set<Int> = setOf(DEFAULT_FORWARD_PORT)): SocketFactory {
        return object : SocketFactory() {
            override fun createSocket(): Socket {
                checkOpen()
                return SshChannelSocket(allowedPorts)
            }

            override fun createSocket(host: String?, port: Int): Socket =
                createConnected(port)

            override fun createSocket(host: String?, port: Int, localHost: InetAddress?, localPort: Int): Socket =
                createConnected(port)

            override fun createSocket(host: InetAddress?, port: Int): Socket =
                createConnected(port)

            override fun createSocket(
                address: InetAddress?,
                port: Int,
                localAddress: InetAddress?,
                localPort: Int,
            ): Socket = createConnected(port)

            private fun createConnected(port: Int): Socket {
                val socket = createSocket()
                try {
                    socket.connect(InetSocketAddress(this@SonySshTunnel.address, port), DEFAULT_TIMEOUT_MS)
                    return socket
                } catch (error: Throwable) {
                    runCatching { socket.close() }
                    throw error
                }
            }
        }
    }

    fun openLiveViewStream(
        url: URL,
        timeoutMs: Int = DEFAULT_TIMEOUT_MS,
    ): CameraLiveStream {
        checkOpen()
        if (!url.protocol.equals("http", ignoreCase = true)) {
            throw IOException("Unsupported live view protocol: ${url.protocol}")
        }
        val port = if (url.port > 0) url.port else url.defaultPort
        if (port !in 1..65535) {
            throw IOException("Invalid live view port: $port")
        }
        val pathAndQuery = url.file.ifBlank { "/" }
        val socket = SshChannelSocket(setOf(port))
        try {
            socket.soTimeout = timeoutMs
            socket.connect(InetSocketAddress(address, port), timeoutMs)
            val request = buildString {
                append("GET ").append(pathAndQuery).append(" HTTP/1.1\r\n")
                append("Host: localhost:").append(port).append("\r\n")
                append("Connection: close\r\n")
                append("Accept: */*\r\n")
                append("\r\n")
            }.toByteArray(StandardCharsets.US_ASCII)
            socket.getOutputStream().apply {
                write(request)
                flush()
            }

            val rawInput = socket.getInputStream()
            val statusLine = readHttpLine(rawInput)
                ?: throw EOFException("Unexpected EOF reading live view HTTP status")
            val statusParts = statusLine.split(' ', limit = 3)
            val statusCode = statusParts.getOrNull(1)?.toIntOrNull()
                ?: throw IOException("Malformed live view HTTP status: $statusLine")

            var chunked = false
            var headerBytes = statusLine.length + 2
            while (true) {
                val line = readHttpLine(rawInput)
                    ?: throw EOFException("Unexpected EOF reading live view HTTP headers")
                headerBytes += line.length + 2
                if (headerBytes > MAX_HTTP_HEADER_BYTES) {
                    throw IOException("Live view HTTP headers too large")
                }
                if (line.isEmpty()) break
                val colon = line.indexOf(':')
                if (colon > 0) {
                    val name = line.substring(0, colon).trim().lowercase(Locale.ROOT)
                    val value = line.substring(colon + 1).trim().lowercase(Locale.ROOT)
                    if (name == "transfer-encoding" && value.contains("chunked")) {
                        chunked = true
                    }
                }
            }
            if (statusCode !in 200..299) {
                throw IOException("Unexpected live view HTTP status $statusCode")
            }

            val bodyStream: InputStream = if (chunked) ChunkedHttpInputStream(rawInput) else rawInput
            return CameraLiveStream(bodyStream) {
                runCatching { socket.close() }
            }
        } catch (error: Throwable) {
            runCatching { socket.close() }
            throw error
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        for (channel in activeChannels.toList()) {
            runCatching { channel.close() }
        }
        activeChannels.clear()
        runCatching { session.disconnect() }
        runCatching { rawSocket?.close() }
    }

    private fun checkOpen() {
        if (closed.get() || !session.isConnected) {
            throw SocketException("Camera SSH tunnel is closed")
        }
    }

    private inner class SshChannelSocket(
        private val allowedPorts: Set<Int>,
    ) : Socket() {
        private val socketClosed = AtomicBoolean(false)
        private val connected = AtomicBoolean(false)
        @Volatile private var timeoutMs: Int = 0
        @Volatile private var targetPort: Int = -1
        @Volatile private var channel: ChannelDirectTCPIP? = null
        @Volatile private var channelOutput: OutputStream? = null
        @Volatile private var readerThread: Thread? = null
        private var exposedInput: ChannelBufferedInputStream? = null
        private var exposedOutput: ChannelOutputStream? = null

        override fun connect(endpoint: SocketAddress?) {
            connect(endpoint, 0)
        }

        override fun connect(endpoint: SocketAddress?, timeout: Int) {
            checkOpen()
            if (socketClosed.get()) throw SocketException("Socket is closed")
            if (connected.get()) throw SocketException("Already connected")
            val inetEndpoint = endpoint as? InetSocketAddress
                ?: throw IllegalArgumentException("Unsupported SocketAddress: $endpoint")
            val port = inetEndpoint.port
            if (port !in allowedPorts) {
                throw IOException("Port $port is not permitted over camera SSH tunnel")
            }

            val connectTimeout = if (timeout > 0) timeout else DEFAULT_TIMEOUT_MS
            val openedChannel = session.openChannel("direct-tcpip") as? ChannelDirectTCPIP
                ?: throw IOException("Failed to open SSH direct-tcpip channel")
            openedChannel.setHost("127.0.0.1")
            openedChannel.setPort(port)
            openedChannel.setOrgIPAddress("127.0.0.1")
            openedChannel.setOrgPort(0)

            val rawInput: InputStream
            val rawOut: OutputStream
            try {
                // Wire channel streams before connect() so early SSH packets are never dropped.
                rawInput = openedChannel.inputStream
                rawOut = openedChannel.outputStream
                openedChannel.connect(connectTimeout)
            } catch (error: Throwable) {
                runCatching { openedChannel.disconnect() }
                if (error is IOException) throw error
                throw IOException("Failed to open forwarded channel to port $port: ${error.message}", error)
            }

            val bufferedInput = ChannelBufferedInputStream(rawInput) { timeoutMs }
            val pump = Thread(
                { bufferedInput.pumpLoop(openedChannel) },
                "rawlab-ssh-rx-$port-${CHANNEL_SEQ.incrementAndGet()}",
            ).apply {
                isDaemon = true
                start()
            }

            channel = openedChannel
            channelOutput = rawOut
            targetPort = port
            exposedInput = bufferedInput
            exposedOutput = ChannelOutputStream(rawOut)
            readerThread = pump
            connected.set(true)
            activeChannels.add(this)
        }

        override fun getInputStream(): InputStream {
            if (socketClosed.get()) throw SocketException("Socket is closed")
            return exposedInput ?: throw SocketException("Socket is not connected")
        }

        override fun getOutputStream(): OutputStream {
            if (socketClosed.get()) throw SocketException("Socket is closed")
            return exposedOutput ?: throw SocketException("Socket is not connected")
        }

        override fun setSoTimeout(timeout: Int) {
            if (timeout < 0) throw IllegalArgumentException("Negative timeout: $timeout")
            timeoutMs = timeout
        }

        override fun getSoTimeout(): Int = timeoutMs

        override fun setTcpNoDelay(on: Boolean) = Unit

        override fun getTcpNoDelay(): Boolean = true

        override fun isConnected(): Boolean = connected.get() && !socketClosed.get()

        override fun isClosed(): Boolean = socketClosed.get()

        override fun getPort(): Int = targetPort

        override fun getInetAddress(): InetAddress = address

        override fun close() {
            if (!socketClosed.compareAndSet(false, true)) return
            activeChannels.remove(this)
            exposedInput?.markClosed()
            runCatching { channelOutput?.close() }
            runCatching { channel?.disconnect() }
            readerThread?.interrupt()
        }

        private inner class ChannelOutputStream(
            private val delegate: OutputStream,
        ) : OutputStream() {
            override fun write(b: Int) {
                if (socketClosed.get()) throw SocketException("Socket is closed")
                delegate.write(b)
            }

            override fun write(b: ByteArray, off: Int, len: Int) {
                if (socketClosed.get()) throw SocketException("Socket is closed")
                delegate.write(b, off, len)
            }

            override fun flush() {
                if (socketClosed.get()) throw SocketException("Socket is closed")
                delegate.flush()
            }

            override fun close() {
                this@SshChannelSocket.close()
            }
        }
    }

    private class ChannelBufferedInputStream(
        private val rawInput: InputStream,
        private val timeoutProvider: () -> Int,
    ) : InputStream() {
        private val lock = ReentrantLock()
        private val notEmpty = lock.newCondition()
        private val notFull = lock.newCondition()
        private val ring = ByteArray(RING_CAPACITY)
        private var head = 0
        private var tail = 0
        private var size = 0
        private var eof = false
        private var closed = false
        private var pumpError: IOException? = null

        fun pumpLoop(channel: ChannelDirectTCPIP) {
            val tmp = ByteArray(16 * 1024)
            try {
                while (true) {
                    val read = rawInput.read(tmp)
                    if (read < 0) break
                    if (read == 0) continue
                    var offset = 0
                    lock.withLock {
                        while (offset < read) {
                            while (size == ring.size && !closed) {
                                notFull.await()
                            }
                            if (closed) return
                            val writable = minOf(read - offset, ring.size - size)
                            val firstCopy = minOf(writable, ring.size - tail)
                            System.arraycopy(tmp, offset, ring, tail, firstCopy)
                            val secondCopy = writable - firstCopy
                            if (secondCopy > 0) {
                                System.arraycopy(tmp, offset + firstCopy, ring, 0, secondCopy)
                            }
                            tail = (tail + writable) % ring.size
                            size += writable
                            offset += writable
                            notEmpty.signalAll()
                        }
                    }
                }
                lock.withLock {
                    eof = true
                    notEmpty.signalAll()
                }
            } catch (error: Throwable) {
                lock.withLock {
                    if (!closed && !channel.isClosed) {
                        pumpError = error as? IOException ?: IOException("SSH channel read failed", error)
                    }
                    eof = true
                    notEmpty.signalAll()
                }
            } finally {
                runCatching { rawInput.close() }
            }
        }

        fun markClosed() {
            lock.withLock {
                closed = true
                notEmpty.signalAll()
                notFull.signalAll()
            }
        }

        override fun read(): Int {
            val single = ByteArray(1)
            val count = read(single, 0, 1)
            return if (count < 0) -1 else single[0].toInt() and 0xFF
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (off < 0 || len < 0 || off + len > b.size) throw IndexOutOfBoundsException()
            if (len == 0) return 0

            val timeout = timeoutProvider()
            val deadlineNs = if (timeout > 0) System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeout.toLong()) else 0L

            lock.withLock {
                while (size == 0) {
                    if (closed) throw SocketException("Socket is closed")
                    pumpError?.let { throw it }
                    if (eof) return -1
                    try {
                        if (timeout > 0) {
                            val remainingNs = deadlineNs - System.nanoTime()
                            if (remainingNs <= 0L) {
                                throw SocketTimeoutException("SSH channel read timed out after ${timeout}ms")
                            }
                            notEmpty.awaitNanos(remainingNs)
                        } else {
                            notEmpty.await()
                        }
                    } catch (interrupted: InterruptedException) {
                        Thread.currentThread().interrupt()
                        throw InterruptedIOException("SSH channel read interrupted").apply {
                            initCause(interrupted)
                        }
                    }
                }

                val count = minOf(len, size)
                val firstCopy = minOf(count, ring.size - head)
                System.arraycopy(ring, head, b, off, firstCopy)
                val secondCopy = count - firstCopy
                if (secondCopy > 0) {
                    System.arraycopy(ring, 0, b, off + firstCopy, secondCopy)
                }
                head = (head + count) % ring.size
                size -= count
                notFull.signalAll()
                return count
            }
        }

        override fun available(): Int = lock.withLock { size }

        override fun close() {
            markClosed()
        }

        companion object {
            private const val RING_CAPACITY = 256 * 1024
        }
    }

    companion object {
        const val DEFAULT_SSH_PORT = 22
        const val DEFAULT_FORWARD_PORT = 15740
        const val DEFAULT_TIMEOUT_MS = 5_000
        private const val MAX_HTTP_HEADER_BYTES = 16 * 1024
        private val CHANNEL_SEQ = AtomicInteger(0)

        fun connect(
            address: InetAddress,
            username: String,
            password: String,
            expectedFingerprint: String,
            port: Int = DEFAULT_SSH_PORT,
            rawSocketFactory: SocketFactory = SocketFactory.getDefault(),
            timeoutMs: Int = DEFAULT_TIMEOUT_MS,
        ): SonySshTunnel {
            val expectedNormalized = normalizeSha256Fingerprint(expectedFingerprint)
                ?: throw SshFingerprintMismatchException(expectedFingerprint, "", "unknown")
            val trimmedUser = username.trim()
            if (trimmedUser.isEmpty() || password.isEmpty()) {
                throw SshAuthenticationException("Camera SSH username and password are required")
            }

            val jsch = JSch()
            var matchedProbe: SshHostProbe? = null
            var mismatchError: SshFingerprintMismatchException? = null
            val rawSocketHolder = arrayOfNulls<Socket>(1)
            val kbAttempts = AtomicInteger(0)

            val session = jsch.getSession(trimmedUser, address.hostAddress ?: address.hostName, port).apply {
                timeout = timeoutMs
                setPassword(password)
                setConfig("StrictHostKeyChecking", "yes")
                setConfig("PreferredAuthentications", "password,keyboard-interactive")
                setConfig("enable_auth_none", "yes")
                setSocketFactory(BoundJschSocketFactory(address, rawSocketFactory, timeoutMs, rawSocketHolder))
                setHostKeyRepository(object : HostKeyRepository {
                    override fun check(host: String?, key: ByteArray?): Int {
                        if (key == null) return HostKeyRepository.NOT_INCLUDED
                        val actual = formatSha256Fingerprint(key)
                        val keyType = parseSshKeyAlgorithm(key)
                        val expectedBytes = expectedNormalized.toByteArray(StandardCharsets.UTF_8)
                        val actualBytes = actual.toByteArray(StandardCharsets.UTF_8)
                        if (!MessageDigest.isEqual(expectedBytes, actualBytes)) {
                            mismatchError = SshFingerprintMismatchException(expectedNormalized, actual, keyType)
                            return HostKeyRepository.CHANGED
                        }
                        matchedProbe = SshHostProbe(address, port, actual, keyType)
                        return HostKeyRepository.OK
                    }

                    override fun add(hostkey: HostKey?, userinfo: UserInfo?) = Unit
                    override fun remove(host: String?, type: String?) = Unit
                    override fun remove(host: String?, type: String?, key: ByteArray?) = Unit
                    override fun getKnownHostsRepositoryID(): String = "sony-pinned"
                    override fun getHostKey(): Array<HostKey> = emptyArray()
                    override fun getHostKey(host: String?, type: String?): Array<HostKey> = emptyArray()
                })
                setUserInfo(object : UserInfo, UIKeyboardInteractive {
                    override fun getPassphrase(): String? = null
                    override fun getPassword(): String = password
                    override fun promptPassword(message: String?): Boolean = true
                    override fun promptPassphrase(message: String?): Boolean = false
                    override fun promptYesNo(message: String?): Boolean = false
                    override fun showMessage(message: String?) = Unit
                    override fun promptKeyboardInteractive(
                        destination: String?,
                        name: String?,
                        instruction: String?,
                        prompt: Array<out String>?,
                        echo: BooleanArray?,
                    ): Array<String>? {
                        if (prompt == null || prompt.isEmpty() || kbAttempts.incrementAndGet() > 2) return null
                        return Array(prompt.size) { idx -> if (idx == 0) password else "" }
                    }
                })
            }

            try {
                session.connect(timeoutMs)
            } catch (error: Exception) {
                runCatching { session.disconnect() }
                runCatching { rawSocketHolder[0]?.close() }
                mismatchError?.let { throw it }
                if (isAuthenticationFailure(error)) {
                    throw SshAuthenticationException("Camera SSH authentication failed", error)
                }
                throw IOException("Camera SSH connection failed: ${error.message}", error)
            }

            val probe = matchedProbe ?: run {
                runCatching { session.disconnect() }
                runCatching { rawSocketHolder[0]?.close() }
                throw SshFingerprintMismatchException(expectedNormalized, "", "unknown")
            }

            // Clear connect/KEX socket timeout so idle PTP/IP event sockets (setSoTimeout(0)) stay open.
            rawSocketHolder[0]?.let { raw ->
                runCatching { raw.soTimeout = 0 }
            }
            runCatching { session.timeout = 0 }

            return SonySshTunnel(address, port, session, rawSocketHolder[0], probe)
        }

        private fun isAuthenticationFailure(error: Throwable): Boolean {
            var current: Throwable? = error
            while (current != null) {
                val msg = current.message?.lowercase(Locale.ROOT).orEmpty()
                if (msg.contains("auth fail") ||
                    msg.contains("auth cancel") ||
                    msg.contains("authentication")
                ) {
                    return true
                }
                current = current.cause
            }
            return false
        }

        private fun readHttpLine(input: InputStream): String? {
            val buffer = ByteArrayOutputStream(128)
            while (true) {
                val b = input.read()
                if (b < 0) {
                    return if (buffer.size() == 0) null else buffer.toString(StandardCharsets.US_ASCII.name())
                }
                if (b == '\n'.code) {
                    val bytes = buffer.toByteArray()
                    val length = if (bytes.isNotEmpty() && bytes[bytes.size - 1] == '\r'.code.toByte()) {
                        bytes.size - 1
                    } else {
                        bytes.size
                    }
                    return String(bytes, 0, length, StandardCharsets.US_ASCII)
                }
                buffer.write(b)
                if (buffer.size() > MAX_HTTP_HEADER_BYTES) {
                    throw IOException("Live view HTTP header line too long")
                }
            }
        }
    }

    private class ChunkedHttpInputStream(
        private val raw: InputStream,
    ) : InputStream() {
        private var remainingInChunk = 0
        private var finished = false

        override fun read(): Int {
            val one = ByteArray(1)
            val count = read(one, 0, 1)
            return if (count < 0) -1 else one[0].toInt() and 0xFF
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (off < 0 || len < 0 || off + len > b.size) throw IndexOutOfBoundsException()
            if (len == 0) return 0
            if (finished) return -1
            while (remainingInChunk == 0) {
                val sizeLine = readHttpLine(raw)
                    ?: throw EOFException("Unexpected EOF in chunked live view stream")
                val hex = sizeLine.substringBefore(';').trim()
                val nextSize = hex.toIntOrNull(16)
                    ?: throw IOException("Invalid HTTP chunk size: $sizeLine")
                if (nextSize == 0) {
                    // Drain optional trailers up to blank line.
                    while (true) {
                        val trailer = readHttpLine(raw) ?: break
                        if (trailer.isEmpty()) break
                    }
                    finished = true
                    return -1
                }
                remainingInChunk = nextSize
            }
            val read = raw.read(b, off, minOf(len, remainingInChunk))
            if (read < 0) throw EOFException("Unexpected EOF inside HTTP chunk")
            remainingInChunk -= read
            if (remainingInChunk == 0) {
                val crlf = readHttpLine(raw)
                    ?: throw EOFException("Missing CRLF after HTTP chunk")
                if (crlf.isNotEmpty()) {
                    throw IOException("Expected empty line after HTTP chunk")
                }
            }
            return read
        }

        override fun close() {
            raw.close()
        }
    }
}

private class BoundJschSocketFactory(
    private val targetAddress: InetAddress,
    private val rawSocketFactory: SocketFactory,
    private val timeoutMs: Int,
    private val socketHolder: Array<Socket?>,
) : com.jcraft.jsch.SocketFactory {
    override fun createSocket(host: String?, port: Int): Socket {
        val socket = try {
            rawSocketFactory.createSocket().apply {
                connect(InetSocketAddress(targetAddress, port), timeoutMs)
            }
        } catch (_: UnsupportedOperationException) {
            rawSocketFactory.createSocket(targetAddress, port)
        } catch (error: UnknownHostException) {
            throw error
        }
        socket.soTimeout = timeoutMs
        socket.tcpNoDelay = true
        socketHolder[0] = socket
        return socket
    }

    override fun getInputStream(socket: Socket): InputStream = socket.getInputStream()

    override fun getOutputStream(socket: Socket): OutputStream = socket.getOutputStream()
}
