package com.rawlab.android.camera.protocol

import android.graphics.Bitmap
import androidx.exifinterface.media.ExifInterface
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketAddress
import java.net.SocketException
import java.nio.charset.StandardCharsets
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import javax.net.SocketFactory
import kotlin.concurrent.thread

/**
 * A small Sony PTP/IP responder for the incremental import UI test.
 *
 * The responder serves one RAW and one JPEG from the same card/capture.  The
 * first JPEG download closes the command channel; a later session can then
 * continue the same card using newly assigned content and file handles.
 */
internal class CameraIncrementalSessionFixture(
    cacheDirectory: File,
    jpegSource: ByteArray? = null,
    interruptJpeg: Boolean = true,
) : Closeable {
    data class DownloadRequest(
        val connection: Int,
        val content: Int,
        val file: Int,
        val offset: Int,
        val size: Int,
    )

    private companion object {
        const val CONTENT_BASE = 0x4a01
        const val RAW_FILE = 1
        const val JPEG_FILE = 2
    }

    private val token = UUID.randomUUID().toString().replace("-", "").take(10)
    private val server = ServerSocket(0, 8, InetAddress.getLoopbackAddress())
    private val clients = CopyOnWriteArrayList<Socket>()
    private val failure = AtomicReference<Throwable?>()
    private val connectionCount = AtomicInteger()
    private val firstJpegFailed = AtomicBoolean(!interruptJpeg)
    private val requests = CopyOnWriteArrayList<DownloadRequest>()
    private val worker = thread(name = "camera-incremental-fixture") { serve() }

    val address: InetAddress = InetAddress.getLoopbackAddress()
    val factory: SocketFactory = object : SocketFactory() {
        override fun createSocket(): Socket = object : Socket() {
            override fun connect(endpoint: SocketAddress, timeout: Int) {
                super.connect(InetSocketAddress(InetAddress.getLoopbackAddress(), server.localPort), timeout)
            }
        }.also(clients::add)

        override fun createSocket(host: String, port: Int): Socket = error("Unused fixture overload")
        override fun createSocket(host: String, port: Int, local: InetAddress, localPort: Int): Socket =
            error("Unused fixture overload")
        override fun createSocket(host: InetAddress, port: Int): Socket = error("Unused fixture overload")
        override fun createSocket(host: InetAddress, port: Int, local: InetAddress, localPort: Int): Socket =
            error("Unused fixture overload")
    }

    val cameraId: String = "sony-incremental-$token"
    val rawName: String = "DSC${token}.ARW"
    val jpegName: String = "DSC${token}.JPG"
    /** Both files are in the current capture window, and share one timestamp. */
    val created: Long = System.currentTimeMillis()
    val rawBytes: ByteArray = byteArrayOf(0x49, 0x49, 0x2a, 0x00, 0x52, 0x41, 0x57, 0x00)
    private val jpegBytes: ByteArray = jpegSource ?: createJpeg(cacheDirectory)

    val downloadRequests: List<DownloadRequest>
        get() = requests.toList()

    private fun createJpeg(cacheDirectory: File): ByteArray {
        val bitmap = Bitmap.createBitmap(64, 32, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(0xff4f46e5.toInt())
        val file = File.createTempFile("camera-incremental-", ".jpg", cacheDirectory)
        try {
            file.outputStream().use { output ->
                check(bitmap.compress(Bitmap.CompressFormat.JPEG, 100, output)) { "Could not create fixture JPEG" }
            }
            ExifInterface(file).apply {
                setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_ROTATE_90.toString())
                setAttribute(ExifInterface.TAG_DATETIME_ORIGINAL, "2026:11:11 08:30:00")
                saveAttributes()
            }
            return file.readBytes()
        } finally {
            bitmap.recycle()
            file.delete()
        }
    }

    private fun serve() {
        try {
            while (!server.isClosed) {
                val command = server.accept()
                clients.add(command)
                val connection = connectionCount.incrementAndGet()
                var event: Socket? = null
                try {
                    // SonyMobileSession waits for the command acknowledgement
                    // before opening its event socket; accepting both sockets
                    // before replying deadlocks the fixture at construction.
                    handshakeCommand(command)
                    val eventSocket = server.accept()
                    event = eventSocket
                    clients.add(eventSocket)
                    handshakeEvent(eventSocket)
                    serveCommands(command, eventSocket, connection)
                } catch (_: IOException) {
                    // EOF/socket close is expected when the queue disconnects after a fault or cleanup.
                } finally {
                    closeQuietly(command)
                    event?.let(::closeQuietly)
                }
            }
        } catch (error: SocketException) {
            if (!server.isClosed) failure.compareAndSet(null, error)
        } catch (error: Throwable) {
            if (!server.isClosed) failure.compareAndSet(null, error)
        }
    }

    private fun handshakeCommand(command: Socket) {
        check(SonyMobileSession.readPacket(command, 4_096).type == 1) { "Expected PTP/IP command init" }
        SonyMobileSession.writePacket(command, 2, SonyMobileSession.u32(7) + ByteArray(20))
    }

    private fun handshakeEvent(event: Socket) {
        val eventInit = SonyMobileSession.readPacket(event, 32)
        check(eventInit.type == 3) { "Expected PTP/IP event init" }
        check(SonyMobileSession.Reader(eventInit.bytes).i32() == 7) { "Wrong PTP/IP connection number" }
        SonyMobileSession.writePacket(event, 4, ByteArray(0))
    }

    private fun serveCommands(command: Socket, event: Socket, connection: Int) {
        while (!command.isClosed) {
            val packet = SonyMobileSession.readPacket(command, 256)
            check(packet.type == 6) { "Expected PTP/IP command packet" }
            val reader = SonyMobileSession.Reader(packet.bytes)
            check(reader.i32() == 1) { "Wrong PTP operation container" }
            val operation = reader.u16()
            val transaction = reader.i32()
            val parameters = IntArray(reader.remaining() / 4) { reader.i32() }
            when (operation) {
                0x1001 -> sendData(command, transaction, deviceInfo())
                0x923d -> download(command, event, connection, transaction, parameters)
                0x923c -> sendData(command, transaction, contentsPage(connection))
                0x923e -> sendData(command, transaction, jpegBytes)
                else -> SonyMobileSession.writePacket(
                    command, 7, SonyMobileSession.u16(0x2001) + SonyMobileSession.u32(transaction),
                )
            }
        }
    }

    private fun deviceInfo(): ByteArray = ByteArrayOutputStream().apply {
        write(SonyMobileSession.u16(100))
        write(SonyMobileSession.u32(17))
        write(SonyMobileSession.u16(100))
        write(0)
        write(SonyMobileSession.u16(0))
        val operations = listOf(0x1001, 0x1002, 0x923c, 0x923d, 0x923e)
        write(SonyMobileSession.u32(operations.size))
        operations.forEach { write(SonyMobileSession.u16(it)) }
        repeat(4) { write(SonyMobileSession.u32(0)) }
        listOf("Sony Corporation", "ILCE-7CM2", "2.00", "TEST1234").forEach { value ->
            write(value.length + 1)
            write((value + '\u0000').toByteArray(StandardCharsets.UTF_16LE))
        }
    }.toByteArray()

    private fun download(command: Socket, event: Socket, connection: Int, transaction: Int, parameters: IntArray) {
        check(parameters.size == 5) { "Unexpected 0x923d parameter count" }
        val content = parameters[0]
        val file = parameters[1] and 0xffff
        val offset = parameters[2]
        val size = parameters[4]
        requests += DownloadRequest(connection, content, file, offset, size)
        if (file == fileFor(connection, JPEG_FILE) && firstJpegFailed.compareAndSet(false, true)) {
            closeQuietly(command)
            closeQuietly(event)
            return
        }
        val source = when (file) {
            fileFor(connection, RAW_FILE) -> rawBytes
            fileFor(connection, JPEG_FILE) -> jpegBytes
            else -> error("Unexpected camera file $file")
        }
        check(content == contentFor(connection) && offset >= 0 && size >= 0 && offset + size <= source.size)
        sendData(command, transaction, source.copyOfRange(offset, offset + size))
    }

    private fun sendData(command: Socket, transaction: Int, bytes: ByteArray) {
        SonyMobileSession.writePacket(
            command, 9,
            SonyMobileSession.u32(transaction) + SonyMobileSession.u32(bytes.size) + ByteArray(4),
        )
        SonyMobileSession.writePacket(command, 12, SonyMobileSession.u32(transaction) + bytes)
        SonyMobileSession.writePacket(command, 7, SonyMobileSession.u16(0x2001) + SonyMobileSession.u32(transaction))
    }

    private fun contentFor(connection: Int): Int = CONTENT_BASE + connection - 1
    private fun fileFor(connection: Int, file: Int): Int = file + (connection - 1) * 10

    private fun contentsPage(connection: Int): ByteArray {
        val content = contentFor(connection)
        val output = ByteArrayOutputStream()
        output.write(ByteArray(144))
        output.write(SonyMobileSession.u32(1)) // one content record
        output.write(SonyMobileSession.u32(1)) // record type, ignored by the client
        output.write(SonyMobileSession.u32(content))
        output.write(ByteArray(20))
        output.write(SonyMobileSession.u32(created.toInt()))
        output.write(SonyMobileSession.u32((created ushr 32).toInt()))
        output.write(ByteArray(36))
        output.write(SonyMobileSession.u32(0)) // shot marks
        output.write(SonyMobileSession.u32(2)) // RAW and JPEG share this capture
        appendFile(output, fileFor(connection, RAW_FILE), rawName, rawBytes.size.toLong())
        appendFile(output, fileFor(connection, JPEG_FILE), jpegName, jpegBytes.size.toLong())
        return output.toByteArray()
    }

    private fun appendFile(output: ByteArrayOutputStream, file: Int, name: String, size: Long) {
        val path = ("/DCIM/100MSDCF/$name\u0000").toByteArray(StandardCharsets.UTF_8)
        output.write(SonyMobileSession.u32(file))
        output.write(SonyMobileSession.u32(path.size))
        output.write(path)
        output.write(SonyMobileSession.u32(0))
        output.write(SonyMobileSession.u32(size.toInt()))
        output.write(SonyMobileSession.u32((size ushr 32).toInt()))
        output.write(ByteArray(32))
        output.write(ByteArray(12))
    }

    override fun close() {
        closeQuietly(server)
        clients.forEach(::closeQuietly)
        worker.join(3_000)
        check(!worker.isAlive) { "Camera incremental fixture thread leaked" }
        failure.get()?.let { throw AssertionError("Camera incremental responder failed", it) }
    }

    private fun closeQuietly(socket: Socket) = runCatching { socket.close() }
    private fun closeQuietly(socket: ServerSocket) = runCatching { socket.close() }
}
