package com.rawlab.android.camera

import com.rawlab.android.photo.MediaPhoto
import com.rawlab.android.photo.MediaPhotoAccess
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.sync.Mutex
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.DataInputStream
import java.io.EOFException
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketAddress
import java.net.SocketTimeoutException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import javax.net.SocketFactory

class CameraTetherLivenessTest {
    private fun rawPayload(tag: Int): ByteArray =
        byteArrayOf(73, 73, 42, 0, 8, 0, 0, 0) + ByteArray(56) { ((it + tag) and 0xff).toByte() }

    private class TestMedia(private val root: File) : MediaPhotoAccess {
        private val rows = linkedMapOf<String, MediaPhoto>()
        private var next = 0
        private fun file(uri: String) = File(root, uri.substringAfterLast('/'))

        @Synchronized
        override fun createPending(name: String, relativePath: String, mime: String, token: String): MediaPhoto {
            val uri = "content://media/external_primary/images/media/${++next}"
            return MediaPhoto(uri, name, relativePath, true).also {
                rows[uri] = it
                file(uri).writeBytes(byteArrayOf())
            }
        }

        override fun write(uri: String, source: File) {
            source.copyTo(file(uri), overwrite = true)
        }

        @Synchronized
        override fun publish(uri: String): MediaPhoto =
            rows.getValue(uri).copy(pending = false).also { rows[uri] = it }

        @Synchronized
        override fun inspect(uri: String): MediaPhoto? = rows[uri]?.takeIf { file(uri).isFile }

        override fun open(uri: String) = file(uri).inputStream()
        override fun remember(uri: String, size: Long, digest: String) = Unit

        @Synchronized
        override fun deletePending(uri: String) {
            if (rows[uri]?.pending == true) {
                file(uri).delete()
                rows.remove(uri)
            }
        }

        @Synchronized
        override fun cleanupOrphans(referenced: Set<String>) {
            rows.values.filter { it.pending && it.uri !in referenced }.map { it.uri }.forEach(::deletePending)
        }
    }

    private class VirtualLoopClock(
        private val camera: FakeTetherCameraServer,
        initialMillis: Long = 10_000L,
    ) {
        private val currentMillis = AtomicLong(initialMillis)
        private val lastClockActivityNanos = AtomicLong(System.nanoTime())
        private val arrived = Channel<Unit>(Channel.RENDEZVOUS)
        private val release = Channel<Unit>(Channel.RENDEZVOUS)

        private fun markActivity() {
            lastClockActivityNanos.set(System.nanoTime())
        }

        fun now(): Long {
            markActivity()
            return currentMillis.get()
        }

        suspend fun pause() {
            markActivity()
            arrived.send(Unit)
            release.receive()
            markActivity()
        }

        suspend fun awaitParked(controller: CameraTetherController) {
            markActivity()
            assertTrue(
                "Controller exited before parking in main loop (phase=${controller.state.value.phase}, failure=${controller.state.value.failure})",
                awaitParkOrExit(controller),
            )
        }

        /** Advances virtual time from a parked state; returns true if parked again, false if controller exited loop. */
        suspend fun stepParkedTick(controller: CameraTetherController, deltaMillis: Long = 250L): Boolean {
            markActivity()
            currentMillis.addAndGet(deltaMillis)
            release.send(Unit)
            return awaitParkOrExit(controller)
        }

        private suspend fun awaitParkOrExit(
            controller: CameraTetherController,
            idleStallMillis: Long = 30_000L,
        ): Boolean = coroutineScope {
            val outcome = CompletableDeferred<Boolean>()
            val parkWaiter = launch(start = CoroutineStart.UNDISPATCHED) {
                outcome.complete(arrived.receiveCatching().isSuccess)
            }
            val exitWaiter = launch {
                controller.join()
                outcome.complete(false)
            }
            val watchdog = launch {
                val stallBudgetNanos = idleStallMillis * 1_000_000L
                while (!outcome.isCompleted) {
                    val lastActive = maxOf(lastClockActivityNanos.get(), camera.lastActivityNanos.get())
                    val idleNanos = System.nanoTime() - lastActive
                    if (idleNanos >= stallBudgetNanos) {
                        outcome.completeExceptionally(
                            AssertionError(
                                "Tether controller stalled with no protocol/loop progress for ${idleNanos / 1_000_000}ms " +
                                    "(phase=${controller.state.value.phase}, failure=${controller.state.value.failure})"
                            )
                        )
                        return@launch
                    }
                    val remainingMillis = ((stallBudgetNanos - idleNanos) / 1_000_000L).coerceAtLeast(50L)
                    delay(minOf(remainingMillis, 1_000L))
                }
            }
            try {
                outcome.await()
            } finally {
                parkWaiter.cancel()
                exitWaiter.cancel()
                watchdog.cancel()
            }
        }

        fun close() {
            arrived.close()
            release.close()
        }
    }

    internal data class FakeCardEntry(
        val content: Int,
        val file: Int = 1,
        val name: String,
        val created: Long,
        val bytes: ByteArray,
    )

    internal class FakeTetherCameraServer(
        private val legacy: Boolean = false,
        initialEntries: List<FakeCardEntry> = emptyList(),
    ) : Closeable {
        private val server = ServerSocket(0, 8, InetAddress.getLoopbackAddress())
        private val entries = CopyOnWriteArrayList(initialEntries)
        private val entriesBySlot = ConcurrentHashMap<Long, FakeCardEntry>().apply {
            initialEntries.forEach { put(slotKey(it.content, it.file), it) }
        }
        private val sockets = CopyOnWriteArrayList<Socket>()
        private val workerThreads = CopyOnWriteArrayList<Thread>()
        private val serverError = AtomicReference<Throwable>()
        @Volatile private var closed = false

        val lastActivityNanos = AtomicLong(System.nanoTime())
        val list923cCalls = AtomicInteger()
        val storage1004Calls = AtomicInteger()
        val handles1007Calls = AtomicInteger()
        val objectInfo1008Calls = AtomicInteger()
        val downloadCalls = AtomicInteger()
        val shutterCaptures = AtomicInteger()

        @Volatile var onShutterTriggered: (() -> Unit)? = null

        private fun markActivity() {
            lastActivityNanos.set(System.nanoTime())
        }

        private val acceptor = Thread({
            while (!closed) {
                val command = try {
                    server.accept()
                } catch (_: IOException) {
                    break
                }
                markActivity()
                sockets += command
                var event: Socket? = null
                try {
                    command.tcpNoDelay = true
                    command.soTimeout = 30_000
                    val init = readPtpPacket(command)
                    markActivity()
                    check(init.first == 1) { "Expected command init packet 1, got ${init.first}" }
                    writePtpPacket(command, 2, u32(1) + ByteArray(20))
                    markActivity()

                    event = server.accept()
                    markActivity()
                    sockets += event
                    event.tcpNoDelay = true
                    event.soTimeout = 30_000
                    val eventInit = readPtpPacket(event)
                    markActivity()
                    check(eventInit.first == 3) { "Expected event init packet 3, got ${eventInit.first}" }
                    writePtpPacket(event, 4, byteArrayOf())
                    command.soTimeout = 0
                    event.soTimeout = 0
                    markActivity()
                } catch (error: Throwable) {
                    runCatching { command.close() }
                    runCatching { event?.close() }
                    if (!closed && (error !is IOException || error is SocketTimeoutException)) {
                        serverError.compareAndSet(null, error)
                    }
                    continue
                }
                val acceptedEvent = checkNotNull(event)
                val worker = Thread({ handleConnection(command, acceptedEvent) }, "fake-tether-conn")
                workerThreads += worker
                worker.start()
            }
        }, "fake-tether-accept").apply { isDaemon = true; start() }

        fun addEntry(entry: FakeCardEntry) {
            entriesBySlot[slotKey(entry.content, entry.file)] = entry
            entries += entry
        }

        fun resetCounters() {
            list923cCalls.set(0)
            storage1004Calls.set(0)
            handles1007Calls.set(0)
            objectInfo1008Calls.set(0)
            downloadCalls.set(0)
        }

        fun socketFactory(): SocketFactory = object : SocketFactory() {
            override fun createSocket(): Socket = object : Socket() {
                override fun connect(endpoint: SocketAddress?, timeout: Int) {
                    super.connect(InetSocketAddress(InetAddress.getLoopbackAddress(), server.localPort), timeout)
                    tcpNoDelay = true
                }
            }.also { sockets += it }
            override fun createSocket(host: String?, port: Int) = throw UnsupportedOperationException()
            override fun createSocket(host: String?, port: Int, localHost: InetAddress?, localPort: Int) = throw UnsupportedOperationException()
            override fun createSocket(host: InetAddress?, port: Int) = throw UnsupportedOperationException()
            override fun createSocket(address: InetAddress?, port: Int, localAddress: InetAddress?, localPort: Int) = throw UnsupportedOperationException()
        }

        private fun handleConnection(command: Socket, event: Socket) {
            try {
                while (!closed) {
                    val (type, payload) = try {
                        readPtpPacket(command)
                    } catch (_: EOFException) {
                        break
                    } catch (timeout: SocketTimeoutException) {
                        throw timeout
                    } catch (_: IOException) {
                        break
                    }
                    markActivity()
                    check(type == 6) { "Expected command packet 6, got $type" }
                    val buf = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN)
                    val phase = buf.int
                    val op = buf.short.toInt() and 0xffff
                    val tid = buf.int
                    val params = IntArray(buf.remaining() / 4) { buf.int }
                    var outgoing: ByteArray? = null
                    if (phase == 2) {
                        val (startType, startBytes) = readPtpPacket(command)
                        check(startType == 9 && startBytes.size == 12)
                        val (endType, endBytes) = readPtpPacket(command)
                        check(endType == 12 && endBytes.size >= 4)
                        outgoing = endBytes.copyOfRange(4, endBytes.size)
                        markActivity()
                    }
                    respond(command, op, tid, params, outgoing)
                    markActivity()
                }
            } catch (error: Throwable) {
                if (!closed && (error !is IOException || error is SocketTimeoutException)) {
                    serverError.compareAndSet(null, error)
                }
            } finally {
                runCatching { command.close() }
                runCatching { event.close() }
            }
        }

        private fun respond(command: Socket, op: Int, tid: Int, params: IntArray, outgoing: ByteArray?) {
            var data: ByteArray? = null
            var code = 0x2001
            when (op) {
                0x1001 -> {
                    val ops = if (legacy) {
                        intArrayOf(0x1001, 0x1002, 0x1004, 0x1007, 0x1008, 0x1009, 0x100a, 0x9201, 0x9202, 0x9207, 0x9209, 0x9212)
                    } else {
                        intArrayOf(0x1001, 0x1002, 0x9201, 0x9202, 0x9205, 0x9207, 0x9209, 0x923c, 0x923d)
                    }
                    val modelName = if (legacy) "ZV-E10" else "ILCE-7CM2"
                    val firmware = if (legacy) "2.02" else "2.00"
                    val out = ByteArrayOutputStream()
                    out.write(u16(100)); out.write(u32(17)); out.write(u16(100))
                    out.write(ptpString("Sony")); out.write(u16(0))
                    out.write(u32(ops.size)); ops.forEach { out.write(u16(it)) }
                    out.write(ByteArray(16))
                    out.write(ptpString("Sony Corporation"))
                    out.write(ptpString(modelName))
                    out.write(ptpString(firmware))
                    out.write(ptpString("7654321"))
                    data = out.toByteArray()
                }
                0x1002, 0x9201, 0x9212 -> Unit
                0x9202 -> {
                    data = u16(0x12c) + u32(2) + u16(0xd222) + u16(0x5013) + u32(2) + u16(0xd2c1) + u16(0xd2c2)
                }
                0x9209 -> {
                    val destValue = if (legacy) 1 else 0x10
                    data = u32(2) + u32(0) +
                        u16(0xd222) + u16(4) + byteArrayOf(1, 1) + u16(destValue) + u16(destValue) + byteArrayOf(0) +
                        u16(0x5013) + u16(4) + byteArrayOf(1, 1) + u16(1) + u16(1) + byteArrayOf(0)
                }
                0x9207 -> {
                    val control = params[0]
                    val value = ByteBuffer.wrap(checkNotNull(outgoing)).order(ByteOrder.LITTLE_ENDIAN).short.toInt() and 0xffff
                    if (control == 0xd2c2 && value == 2) {
                        shutterCaptures.incrementAndGet()
                        onShutterTriggered?.invoke()
                    }
                }
                0x923c -> {
                    list923cCalls.incrementAndGet()
                    val low = params[0].toLong() and 0xffffffffL
                    val high = params[1].toLong() and 0xffffffffL
                    val after = low or (high shl 32)
                    val maxItems = params[2]
                    val snapshot = entries.filter { it.created > after }.sortedWith(compareBy({ it.created }, { it.content }, { it.file }))
                    val page = snapshot.take(maxItems)
                    val out = ByteArrayOutputStream()
                    out.write(ByteArray(144))
                    out.write(u32(page.size))
                    for (entry in page) {
                        val path = ("/DCIM/100MSDCF/${entry.name}\u0000").toByteArray(StandardCharsets.UTF_8)
                        out.write(u32(1))
                        out.write(u32(entry.content))
                        out.write(ByteArray(20))
                        out.write(i64(entry.created))
                        out.write(ByteArray(36))
                        out.write(u32(0))
                        out.write(u32(1))
                        out.write(u32(entry.file))
                        out.write(u32(path.size))
                        out.write(path)
                        out.write(u32(0))
                        out.write(i64(entry.bytes.size.toLong()))
                        out.write(ByteArray(32))
                        out.write(ByteArray(12))
                    }
                    data = out.toByteArray()
                }
                0x923d -> {
                    downloadCalls.incrementAndGet()
                    val content = params[0]
                    val file = params[1] and 0xffff
                    val offset = (params[2].toLong() and 0xffffffffL) or ((params[3].toLong() and 0xffffffffL) shl 32)
                    val count = params[4]
                    val match = entriesBySlot[slotKey(content, file)]
                    if (match == null) {
                        code = 0x2009
                    } else {
                        val start = offset.toInt()
                        data = match.bytes.copyOfRange(start, minOf(match.bytes.size, start + count))
                    }
                }
                0x1004 -> {
                    storage1004Calls.incrementAndGet()
                    data = u32(1) + u32(65537)
                }
                0x1007 -> {
                    handles1007Calls.incrementAndGet()
                    val snapshot = entries.toList()
                    val out = ByteArrayOutputStream()
                    out.write(u32(snapshot.size))
                    snapshot.forEach { out.write(u32(it.content)) }
                    data = out.toByteArray()
                }
                0x1008 -> {
                    objectInfo1008Calls.incrementAndGet()
                    val handle = params[0]
                    val match = entriesBySlot[slotKey(handle, 1)]
                    if (match == null) {
                        code = 0x2009
                    } else {
                        data = u32(65537) + u16(0xb101) + u16(0) + u32(match.bytes.size) +
                            ByteArray(40) + ptpString(match.name) + ptpString("20261113T100000") + ptpString("") + ptpString("")
                    }
                }
                0x1009 -> {
                    downloadCalls.incrementAndGet()
                    val handle = params[0]
                    val match = entriesBySlot[slotKey(handle, 1)]
                    if (match == null) code = 0x2009 else data = match.bytes
                }
                else -> error("Unexpected PTP op 0x${op.toString(16)}")
            }
            // Write all PTP frames for one transaction in a single write+flush to avoid Linux loopback Nagle + delayed-ACK stalls.
            val reply = ByteArrayOutputStream()
            if (data != null) {
                reply.write(encodePtpPacket(9, u32(tid) + i64(data.size.toLong())))
                reply.write(encodePtpPacket(12, u32(tid) + data))
            }
            reply.write(encodePtpPacket(7, u16(code) + u32(tid)))
            command.getOutputStream().write(reply.toByteArray())
            command.getOutputStream().flush()
        }

        override fun close() {
            closed = true
            runCatching { server.close() }
            sockets.forEach { runCatching { it.close() } }
            acceptor.join(3_000)
            workerThreads.forEach { it.join(3_000) }
            serverError.get()?.let { throw AssertionError("Fake tether server failed", it) }
        }

        companion object {
            private fun slotKey(content: Int, file: Int): Long =
                (content.toLong() shl 16) or (file.toLong() and 0xffffL)
            private fun u16(v: Int): ByteArray = ByteBuffer.allocate(2).order(ByteOrder.LITTLE_ENDIAN).putShort(v.toShort()).array()
            private fun u32(v: Int): ByteArray = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(v).array()
            private fun i64(v: Long): ByteArray = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(v).array()
            private fun ptpString(s: String): ByteArray {
                if (s.isEmpty()) return byteArrayOf(0)
                val utf16 = (s + "\u0000").toByteArray(StandardCharsets.UTF_16LE)
                return byteArrayOf((s.length + 1).toByte()) + utf16
            }
            private fun encodePtpPacket(type: Int, payload: ByteArray): ByteArray =
                ByteBuffer.allocate(payload.size + 8).order(ByteOrder.LITTLE_ENDIAN)
                    .putInt(payload.size + 8).putInt(type).put(payload).array()
            private fun writePtpPacket(socket: Socket, type: Int, payload: ByteArray) {
                socket.getOutputStream().write(encodePtpPacket(type, payload))
                socket.getOutputStream().flush()
            }
            private fun readPtpPacket(socket: Socket): Pair<Int, ByteArray> {
                val input = DataInputStream(socket.getInputStream())
                val header = ByteArray(8)
                input.readFully(header)
                val hBuf = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
                val length = hBuf.int
                val type = hBuf.int
                check(length >= 8) { "Invalid PTP packet length $length" }
                val body = ByteArray(length - 8)
                input.readFully(body)
                return type to body
            }
        }
    }

    private fun withWorkspace(block: suspend CoroutineScope.(File, CameraImportStore, CameraTetherJournal, Mutex) -> Unit) {
        val root = Files.createTempDirectory("camera-tether-liveness").toFile()
        try {
            val media = TestMedia(File(root, "media").apply { mkdirs() })
            val store = CameraImportStore(File(root, "jobs"), File(root, "partial"), media) { null }
            val journal = CameraTetherJournal(File(root, "tether"))
            val lock = Mutex()
            runBlocking { block(root, store, journal, lock) }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun resumingWithPendingShutterMarkerReachesReadyClearsMarkerAndDoesNotFailAfter35Seconds() = withWorkspace { _, store, journal, lock ->
        val firstShot = FakeCardEntry(1, 1, "DSC00001.ARW", 1_730_000_001_000L, rawPayload(1))
        val offlineUnknownShot = FakeCardEntry(2, 1, "DSC00002.ARW", 1_730_000_002_000L, rawPayload(2))
        val clientId = UUID.randomUUID()
        val destination = CameraImportDestination()

        FakeTetherCameraServer().use { camera ->
            val clock = VirtualLoopClock(camera, initialMillis = 10_000L)
            val controllerScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            val controller = CameraTetherController(controllerScope, store, journal, lock, {}, clock::now, clock::pause)
            try {
                // 1) Initial session: shoot photo #1 and receive it so the run has a registered batch and canResume == true.
                camera.onShutterTriggered = { camera.addEntry(firstShot) }
                controller.start(camera.socketFactory(), InetAddress.getLoopbackAddress(), clientId,
                    SonyCameraModel.A7CII, "BLE:sony", destination, resume = false, cardSavingConfirmed = false)
                clock.awaitParked(controller)
                assertEquals(CameraTetherPhase.READY, controller.state.value.phase)
                assertNull(controller.state.value.failure)

                controller.capture()
                // Tick 1..12 (3,000 ms): processes shutter request and reconciles card to download firstShot.
                repeat(12) { assertTrue(clock.stepParkedTick(controller)) }
                assertEquals(CameraTetherPhase.READY, controller.state.value.phase)
                assertEquals(1, controller.state.value.saved.size)
                assertNull(controller.state.value.run?.shutterRequestedAt)

                // 2) Press shutter for shot #2, then simulate backgrounding/disconnect before photo arrives.
                camera.onShutterTriggered = null
                controller.capture()
                assertTrue(clock.stepParkedTick(controller))
                assertEquals(CameraTetherPhase.WAITING, controller.state.value.phase)
                assertNotNull(controller.state.value.run?.shutterRequestedAt)

                controller.stop()
                controller.join()
                assertEquals(CameraTetherPhase.PAUSED, controller.state.value.phase)
                val pausedFailureAfterStop = controller.state.value.failure
                assertTrue(controller.state.value.canResume)
                assertNotNull(journal.load().single().shutterRequestedAt)

                // Simulate camera having written offlineUnknownShot while disconnected.
                camera.addEntry(offlineUnknownShot)

                // 3) Resume session with pending shutterRequestedAt marker.
                val resumeClock = VirtualLoopClock(camera, initialMillis = 100_000L)
                val resumedController = CameraTetherController(controllerScope, store, journal, lock, {}, resumeClock::now, resumeClock::pause)
                resumedController.restore(journal.load(), store.load())
                assertEquals(CameraTetherPhase.PAUSED, resumedController.state.value.phase)
                val pausedFailureBeforeResume = resumedController.state.value.failure
                assertTrue(resumedController.state.value.canResume)

                resumedController.start(camera.socketFactory(), InetAddress.getLoopbackAddress(), clientId,
                    SonyCameraModel.A7CII, "BLE:sony", destination, resume = true, cardSavingConfirmed = false)
                resumeClock.awaitParked(resumedController)
                val initialResumedPhase = resumedController.state.value.phase
                val markerAfterResume = resumedController.state.value.run?.shutterRequestedAt

                // Advance 45 seconds (180 ticks * 250ms = 45,000ms > 35,000ms): must NOT fail or loop!
                var survivedTicks = 0
                for (tick in 1..180) {
                    if (!resumeClock.stepParkedTick(resumedController)) break
                    survivedTicks = tick
                }
                assertEquals(
                    "Expected resumed session to stay active in READY for 45s, but initialPhase=$initialResumedPhase, markerAfterResume=$markerAfterResume, survived=${survivedTicks * 250}ms, finalPhase=${resumedController.state.value.phase}, failure=${resumedController.state.value.failure}",
                    180,
                    survivedTicks,
                )
                assertEquals(CameraTetherFailure.UNKNOWN_SHOT, pausedFailureAfterStop)
                assertEquals(CameraTetherFailure.UNKNOWN_SHOT, pausedFailureBeforeResume)
                assertEquals(CameraTetherPhase.READY, initialResumedPhase)
                assertEquals(CameraTetherPhase.READY, resumedController.state.value.phase)
                assertEquals(CameraTetherFailure.UNKNOWN_SHOT, resumedController.state.value.failure)
                assertNull(markerAfterResume)
                assertNull(journal.load().single().shutterRequestedAt)
                // Offline unknown shot was folded into baseline, not auto-imported.
                assertEquals(1, resumedController.state.value.saved.size)

                // 4) Control check: normal in-session shutter confirmation still works and clears the notice!
                val confirmedShot = FakeCardEntry(3, 1, "DSC00003.ARW", 1_730_000_003_000L, rawPayload(3))
                camera.onShutterTriggered = { camera.addEntry(confirmedShot) }
                resumedController.capture()
                repeat(12) { assertTrue(resumeClock.stepParkedTick(resumedController)) }
                assertEquals(CameraTetherPhase.READY, resumedController.state.value.phase)
                assertNull(resumedController.state.value.failure)
                assertNull(resumedController.state.value.run?.shutterRequestedAt)
                assertEquals(2, resumedController.state.value.saved.size)

                // 5) Control check: an in-session unconfirmed shot STILL times out after 35s with UNKNOWN_SHOT!
                camera.onShutterTriggered = null
                resumedController.capture()
                var exited = false
                for (tick in 1..150) {
                    if (!resumeClock.stepParkedTick(resumedController)) {
                        exited = true
                        break
                    }
                }
                assertTrue("Expected in-session unconfirmed shot to time out after 35s", exited)
                assertEquals(CameraTetherPhase.PAUSED, resumedController.state.value.phase)
                assertEquals(CameraTetherFailure.UNKNOWN_SHOT, resumedController.state.value.failure)
                assertNotNull(journal.load().single().shutterRequestedAt)

                resumeClock.close()
            } finally {
                clock.close()
                controllerScope.cancel()
            }
        }
    }

    @Test
    fun modernIdlePollingRoundTripsStayConstantAcrossCardSizesAndStillDiscoverNewPhotos() {
        val basePayload = rawPayload(10)
        fun cardEntries(count: Int): List<FakeCardEntry> = (1..count).map { index ->
            FakeCardEntry(index, 1, "DSC%05d.ARW".format(index), 1_730_000_000_000L + index * 1_000L, basePayload)
        }

        var smallIdle923c = -1
        withWorkspace { _, store, journal, lock ->
            FakeTetherCameraServer(legacy = false, initialEntries = cardEntries(500)).use { camera ->
                val clock = VirtualLoopClock(camera)
                val controllerScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
                val controller = CameraTetherController(controllerScope, store, journal, lock, {}, clock::now, clock::pause)
                try {
                    controller.start(camera.socketFactory(), InetAddress.getLoopbackAddress(), UUID.randomUUID(),
                        SonyCameraModel.A7CII, "BLE:sony-500", CameraImportDestination(), resume = false, cardSavingConfirmed = false)
                    clock.awaitParked(controller)
                    assertEquals(CameraTetherPhase.READY, controller.state.value.phase)
                    camera.resetCounters()
                    // 60 seconds idle = 240 ticks * 250ms (40 reconciliations at 1,500ms interval).
                    repeat(240) { assertTrue(clock.stepParkedTick(controller)) }
                    smallIdle923c = camera.list923cCalls.get()
                    controller.stop(ended = true)
                    controller.join()
                } finally {
                    clock.close()
                    controllerScope.cancel()
                }
            }
        }

        var largeIdle923c = -1
        var sameTimestamp923c = -1
        var singleNewPhoto923c = -1
        var savedNames = emptyList<String>()
        withWorkspace { _, store, journal, lock ->
            FakeTetherCameraServer(legacy = false, initialEntries = cardEntries(2_500)).use { camera ->
                val clock = VirtualLoopClock(camera)
                val controllerScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
                val controller = CameraTetherController(controllerScope, store, journal, lock, {}, clock::now, clock::pause)
                try {
                    controller.start(camera.socketFactory(), InetAddress.getLoopbackAddress(), UUID.randomUUID(),
                        SonyCameraModel.A7CII, "BLE:sony-2500", CameraImportDestination(), resume = false, cardSavingConfirmed = false)
                    clock.awaitParked(controller)
                    assertEquals(CameraTetherPhase.READY, controller.state.value.phase)
                    camera.resetCounters()
                    // 60 seconds idle = 240 ticks * 250ms.
                    repeat(240) { assertTrue(clock.stepParkedTick(controller)) }
                    largeIdle923c = camera.list923cCalls.get()

                    // New photo #1 sharing exact tail timestamp with entry #2500 (1_730_002_500_000L).
                    camera.resetCounters()
                    camera.addEntry(FakeCardEntry(2_501, 1, "DSC02501.ARW", 1_730_002_500_000L, rawPayload(21)))
                    repeat(6) { assertTrue(clock.stepParkedTick(controller)) }
                    sameTimestamp923c = camera.list923cCalls.get()

                    // New photo #2 with advancing timestamp (1_730_002_501_000L).
                    camera.resetCounters()
                    camera.addEntry(FakeCardEntry(2_502, 1, "DSC02502.ARW", 1_730_002_501_000L, rawPayload(22)))
                    repeat(6) { assertTrue(clock.stepParkedTick(controller)) }
                    singleNewPhoto923c = camera.list923cCalls.get()
                    savedNames = controller.state.value.saved.map { it.photo.name }

                    controller.stop(ended = true)
                    controller.join()
                } finally {
                    clock.close()
                    controllerScope.cancel()
                }
            }
        }

        assertEquals(
            "60s idle 0x923c calls grew with card size: 500-photo card=$smallIdle923c, 2500-photo card=$largeIdle923c, singleNewPhoto923c=$singleNewPhoto923c",
            smallIdle923c,
            largeIdle923c,
        )
        assertEquals("Expected 40 single-page 0x923c polls during 60s idle", 40, largeIdle923c)
        assertEquals("Expected 1 poll + 1 targeted page verification = 2 0x923c calls for same-timestamp capture", 2, sameTimestamp923c)
        assertEquals("Expected 1 poll + 1 targeted page verification = 2 0x923c calls for new capture on 2500-photo card", 2, singleNewPhoto923c)
        assertEquals(listOf("DSC02502.ARW", "DSC02501.ARW"), savedNames)
    }

    @Test
    fun legacyReconciliationSkipsKnownHandlesAndStillDiscoversNewPhotos() {
        val basePayload = rawPayload(30)
        fun cardEntries(count: Int): List<FakeCardEntry> = (1..count).map { index ->
            FakeCardEntry(index, 1, "DSC%05d.ARW".format(index), 1_730_000_000_000L + index * 1_000L, basePayload)
        }

        var smallIdle60sOps = -1
        var smallReconcileOps = -1
        var smallReconcile1008 = -1
        withWorkspace { _, store, journal, lock ->
            FakeTetherCameraServer(legacy = true, initialEntries = cardEntries(100)).use { camera ->
                val clock = VirtualLoopClock(camera)
                val controllerScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
                val controller = CameraTetherController(controllerScope, store, journal, lock, {}, clock::now, clock::pause)
                try {
                    controller.start(camera.socketFactory(), InetAddress.getLoopbackAddress(), UUID.randomUUID(),
                        SonyCameraModel.ZVE10, "BLE:zve10-100", CameraImportDestination(), resume = false, cardSavingConfirmed = true)
                    clock.awaitParked(controller)
                    assertEquals(CameraTetherPhase.READY, controller.state.value.phase)
                    camera.resetCounters()
                    // Advance first 60s idle (4 * 15s) -> 0 card reconciliations; next 60s (total 120s) -> 1 full legacy idle reconciliation.
                    repeat(4) { assertTrue(clock.stepParkedTick(controller, deltaMillis = 15_000L)) }
                    smallIdle60sOps = camera.storage1004Calls.get() + camera.handles1007Calls.get() + camera.objectInfo1008Calls.get()
                    repeat(4) { assertTrue(clock.stepParkedTick(controller, deltaMillis = 15_000L)) }
                    smallReconcile1008 = camera.objectInfo1008Calls.get()
                    smallReconcileOps = camera.storage1004Calls.get() + camera.handles1007Calls.get() + smallReconcile1008
                    controller.stop(ended = true)
                    controller.join()
                } finally {
                    clock.close()
                    controllerScope.cancel()
                }
            }
        }

        var largeIdle60sOps = -1
        var largeReconcileOps = -1
        var largeReconcile1008 = -1
        var newPhoto1008 = -1
        var savedNames = emptyList<String>()
        withWorkspace { _, store, journal, lock ->
            FakeTetherCameraServer(legacy = true, initialEntries = cardEntries(1_000)).use { camera ->
                val clock = VirtualLoopClock(camera)
                val controllerScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
                val controller = CameraTetherController(controllerScope, store, journal, lock, {}, clock::now, clock::pause)
                try {
                    controller.start(camera.socketFactory(), InetAddress.getLoopbackAddress(), UUID.randomUUID(),
                        SonyCameraModel.ZVE10, "BLE:zve10-1000", CameraImportDestination(), resume = false, cardSavingConfirmed = true)
                    clock.awaitParked(controller)
                    assertEquals(CameraTetherPhase.READY, controller.state.value.phase)
                    camera.resetCounters()
                    repeat(4) { assertTrue(clock.stepParkedTick(controller, deltaMillis = 15_000L)) }
                    largeIdle60sOps = camera.storage1004Calls.get() + camera.handles1007Calls.get() + camera.objectInfo1008Calls.get()
                    repeat(4) { assertTrue(clock.stepParkedTick(controller, deltaMillis = 15_000L)) }
                    largeReconcile1008 = camera.objectInfo1008Calls.get()
                    largeReconcileOps = camera.storage1004Calls.get() + camera.handles1007Calls.get() + largeReconcile1008

                    // Add a new photo (#1001) and advance one full 120s reconciliation period.
                    camera.resetCounters()
                    camera.addEntry(FakeCardEntry(1_001, 1, "DSC01001.ARW", 1_730_001_001_000L, rawPayload(31)))
                    assertTrue(clock.stepParkedTick(controller, deltaMillis = 120_000L))
                    newPhoto1008 = camera.objectInfo1008Calls.get()
                    savedNames = controller.state.value.saved.map { it.photo.name }

                    controller.stop(ended = true)
                    controller.join()
                } finally {
                    clock.close()
                    controllerScope.cancel()
                }
            }
        }

        assertEquals(0, smallIdle60sOps)
        assertEquals(0, largeIdle60sOps)
        assertEquals(listOf("DSC01001.ARW"), savedNames)
        assertEquals(
            "Legacy reconciliation list/query round-trips grew with card size: 100-photo card=$smallReconcileOps (1008=$smallReconcile1008), 1000-photo card=$largeReconcileOps (1008=$largeReconcile1008), newPhoto1008=$newPhoto1008",
            smallReconcileOps,
            largeReconcileOps,
        )
        assertEquals("Legacy idle reconciliation must send 0 GetObjectInfo (0x1008) queries", 0, largeReconcile1008)
        assertEquals("Legacy idle reconciliation must only send mount/list storage + handles = 3 ops", 3, largeReconcileOps)
        assertEquals("Expected 1 discovery + 2 transfer-check 0x1008 queries for 1 new legacy photo", 3, newPhoto1008)
    }

    @Test
    fun unregisteredFirstShotReconnectResumesInsteadOfFailingAgain() = withWorkspace { _, store, journal, lock ->
        val offlineShot = FakeCardEntry(1, 1, "DSC00001.ARW", 1_730_000_001_000L, rawPayload(40))
        val clientId = UUID.randomUUID()
        val destination = CameraImportDestination()
        FakeTetherCameraServer().use { camera ->
            val clock = VirtualLoopClock(camera, initialMillis = 10_000L)
            val controllerScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            val controller = CameraTetherController(controllerScope, store, journal, lock, {}, clock::now, clock::pause)
            try {
                controller.start(camera.socketFactory(), InetAddress.getLoopbackAddress(), clientId,
                    SonyCameraModel.A7CII, "BLE:sony", destination, resume = false, cardSavingConfirmed = false)
                clock.awaitParked(controller)
                assertEquals(CameraTetherPhase.READY, controller.state.value.phase)

                // 按下快门后照片落到卡上，但这次联机还没把它登记成批次就断了连接。
                camera.onShutterTriggered = { camera.addEntry(offlineShot) }
                controller.capture()
                assertTrue(clock.stepParkedTick(controller))
                camera.onShutterTriggered = null
                assertEquals(CameraTetherPhase.WAITING, controller.state.value.phase)
                controller.stop()
                controller.join()
                assertEquals(CameraTetherPhase.PAUSED, controller.state.value.phase)
                assertEquals(CameraTetherFailure.UNKNOWN_SHOT, controller.state.value.failure)
                val paused = journal.load().single()
                assertEquals(CameraTetherStatus.PAUSED, paused.status)
                assertTrue(paused.batches.isEmpty())
                assertNotNull(paused.shutterRequestedAt)
                // 首拍未登记也必须可以续接，而不是再拒一次逼用户手动导入。
                assertTrue("unregistered first shot must stay resumable", controller.state.value.canResume)

                val resumeClock = VirtualLoopClock(camera, initialMillis = 100_000L)
                val resumed = CameraTetherController(controllerScope, store, journal, lock, {}, resumeClock::now, resumeClock::pause)
                resumed.restore(journal.load(), store.load())
                assertTrue(resumed.state.value.canResume)
                resumed.start(camera.socketFactory(), InetAddress.getLoopbackAddress(), clientId,
                    SonyCameraModel.A7CII, "BLE:sony", destination, resume = true, cardSavingConfirmed = false)
                resumeClock.awaitParked(resumed)
                assertEquals("resume after unregistered first shot must reach READY",
                    CameraTetherPhase.READY, resumed.state.value.phase)
                assertEquals(CameraTetherFailure.UNKNOWN_SHOT, resumed.state.value.failure)
                assertNull(resumed.state.value.run?.shutterRequestedAt)
                // 断线期间的照片折叠进新基线，不自动补传，等待机身核对。
                assertEquals(emptyList<String>(), resumed.state.value.saved.map { it.photo.name })
                assertEquals(1, resumed.state.value.run?.baseline?.size)
                assertEquals(CameraTetherStatus.ACTIVE, resumed.state.value.run?.status)
                assertNull(resumed.state.value.run?.shutterRequestedAt)
                resumeClock.close()
            } finally {
                clock.close()
                controllerScope.cancel()
            }
        }
    }

    @Test
    fun confirmPausedRunEndsStuckRunAndAllowsFreshSession() = withWorkspace { _, store, journal, lock ->
        val shot = CameraPhoto("1", "DSC00001.ARW", 100L, 42L)
        val controllerScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val controller = CameraTetherController(controllerScope, store, journal, lock, {})
        try {
            // 批次没登记进 Store 的暂停 run：无法续接，只能确认结果后结束。
            val created = journal.create("BLE:sony", "sony", emptyList(), CameraImportDestination())
            val stuck = journal.reserve(created, listOf(shot)).first
                .copy(status = CameraTetherStatus.PAUSED, shutterRequestedAt = 5L)
            journal.save(stuck)
            controller.restore(journal.load(), store.load())
            assertFalse(controller.state.value.canResume)
            assertTrue(controller.state.value.canConfirmAndContinue)

            controller.confirmPausedRun()
            assertNull(controller.state.value.run)
            assertEquals(CameraTetherPhase.IDLE, controller.state.value.phase)
            assertNull(controller.state.value.failure)
            assertFalse(controller.state.value.canConfirmAndContinue)
            controller.join()
            val ended = journal.load().single()
            assertEquals(CameraTetherStatus.ENDED, ended.status)
            assertNull(ended.shutterRequestedAt)
            // 已结束的 run 不再参与续接或确认入口。
            controller.restore(journal.load(), store.load())
            assertFalse(controller.state.value.canConfirmAndContinue)
        } finally {
            controllerScope.cancel()
        }
    }

    @Test
    fun oversizedCardKeepsTetherConnectedWithLimitNoticeAndStillCaptures() = withWorkspace { _, store, journal, lock ->
        val basePayload = rawPayload(41)
        fun cardEntries(count: Int): List<FakeCardEntry> = (1..count).map { index ->
            FakeCardEntry(index, 1, "DSC%05d.ARW".format(index), 1_730_000_000_000L + index * 1_000L, basePayload)
        }
        val captureShot = FakeCardEntry(10_002, 1, "DSC10002.ARW", 1_730_100_000_000L, rawPayload(42))
        FakeTetherCameraServer(initialEntries = cardEntries(10_001)).use { camera ->
            val clock = VirtualLoopClock(camera, initialMillis = 10_000L)
            val controllerScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            val controller = CameraTetherController(controllerScope, store, journal, lock, {}, clock::now, clock::pause)
            try {
                controller.start(camera.socketFactory(), InetAddress.getLoopbackAddress(), UUID.randomUUID(),
                    SonyCameraModel.A7CII, "BLE:sony-oversized", CameraImportDestination(), resume = false, cardSavingConfirmed = false)
                clock.awaitParked(controller)
                // 超限只提示并只列出最近窗口，连接必须保持而不是断开回选片。
                assertEquals(CameraTetherPhase.READY, controller.state.value.phase)
                assertEquals(CameraTetherFailure.PHOTO_LIMIT, controller.state.value.failure)
                assertNotNull(controller.state.value.run)
                assertTrue(controller.state.value.run?.truncatedListing == true)
                assertEquals(10_000, controller.state.value.run?.baseline?.size)

                // 窗口语义下新拍一张仍能正常接收。
                camera.onShutterTriggered = { camera.addEntry(captureShot) }
                controller.capture()
                var ticks = 0
                while (ticks < 24 && controller.state.value.saved.isEmpty() && clock.stepParkedTick(controller)) ticks++
                assertEquals(listOf("DSC10002.ARW"), controller.state.value.saved.map { it.photo.name })
                assertEquals(CameraTetherPhase.READY, controller.state.value.phase)
                assertEquals(CameraTetherFailure.PHOTO_LIMIT, controller.state.value.failure)
                assertNull(controller.state.value.run?.shutterRequestedAt)
                assertEquals(CameraTetherStatus.ACTIVE, controller.state.value.run?.status)
            } finally {
                clock.close()
                controllerScope.cancel()
            }
        }
    }
}
