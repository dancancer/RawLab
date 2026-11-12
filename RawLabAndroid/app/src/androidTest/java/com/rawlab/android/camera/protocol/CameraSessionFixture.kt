package com.rawlab.android.camera.protocol

import java.io.Closeable
import java.io.IOException
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketAddress
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import javax.net.SocketFactory
import kotlin.concurrent.thread

/** 用本机 PTP responder 驱动真实会话，记录是否错误地开始下载；不连接实体相机。 */
internal class CameraSessionFixture(private val malformedPreview: Boolean = false) : Closeable {
    private val server = ServerSocket(0, 2, InetAddress.getLoopbackAddress())
    private val failure = AtomicReference<Throwable>()
    val downloads = AtomicInteger()
    private val worker = thread(name = "camera-interruption-fixture") {
        try {
            server.accept().use { command ->
                check(SonyMobileSession.readPacket(command, 4096).type == 1)
                SonyMobileSession.writePacket(command, 2, SonyMobileSession.u32(7) + ByteArray(20))
                server.accept().use { event ->
                    check(SonyMobileSession.readPacket(event, 32).type == 3)
                    SonyMobileSession.writePacket(event, 4, byteArrayOf())
                    while (true) {
                        val packet = SonyMobileSession.readPacket(command, 256)
                        check(packet.type == 6)
                        val reader = SonyMobileSession.Reader(packet.bytes)
                        check(reader.i32() == 1)
                        val operation = reader.u16()
                        val transaction = reader.i32()
                        if (operation == 0x923d) {
                            downloads.incrementAndGet()
                            break
                        }
                        check(operation == 0x923e)
                        SonyMobileSession.writePacket(command, 7,
                            SonyMobileSession.u16(if (malformedPreview) 0x2001 else 0x2005) +
                                SonyMobileSession.u32(transaction + if (malformedPreview) 1 else 0))
                    }
                }
            }
        } catch (error: Throwable) {
            if (error !is IOException) failure.set(error)
        }
    }
    private val factory = object : SocketFactory() {
        override fun createSocket() = object : Socket() {
            override fun connect(endpoint: SocketAddress, timeout: Int) =
                super.connect(InetSocketAddress(InetAddress.getLoopbackAddress(), server.localPort), timeout)
        }
        override fun createSocket(host: String, port: Int): Socket = error("Unused fixture overload")
        override fun createSocket(host: String, port: Int, local: InetAddress, localPort: Int): Socket = error("Unused fixture overload")
        override fun createSocket(host: InetAddress, port: Int): Socket = error("Unused fixture overload")
        override fun createSocket(host: InetAddress, port: Int, local: InetAddress, localPort: Int): Socket = error("Unused fixture overload")
    }
    val session = SonyMobileSession(factory, InetAddress.getLoopbackAddress(), UUID.randomUUID()) { }
    val device = SonyMobileSession.Device("Sony Corporation", "ILCE-7CM2", "2.00", setOf(0x923c, 0x923d))
    val asset = SonyMobileSession.Asset(session, 1, 1, "PREPARING.ARW", 12, 123)

    override fun close() {
        session.close()
        server.close()
        worker.join(3000)
        check(!worker.isAlive) { "Camera fixture thread leaked" }
        failure.get()?.let { throw AssertionError("Camera responder failed", it) }
    }
}

internal class CameraResumeFixture(name: String, private val bytes: ByteArray) : CameraMediaSession {
    val device = SonyMobileSession.Device("Sony Corporation", "ILCE-7CM2", "2.00", "test-123", setOf(0x923c, 0x923d))
    val asset = SonyMobileSession.Asset(this, 1, 1, name, bytes.size.toLong(), 123)
    val listings = AtomicInteger()
    val downloads = AtomicInteger()
    override fun deviceInfo() = device
    override fun openSession() = Unit
    override fun listPhotos(device: SonyMobileSession.Device): List<SonyMobileSession.Asset> {
        listings.incrementAndGet()
        return listOf(asset)
    }
    override fun preview(asset: SonyMobileSession.Asset, large: Boolean) = bytes
    override fun download(device: SonyMobileSession.Device, asset: SonyMobileSession.Asset,
        destination: OutputStream, progress: SonyMobileSession.Progress): String {
        check(asset === this.asset)
        downloads.incrementAndGet()
        destination.write(bytes)
        progress.transferred(asset.size, asset.size)
        return MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    }
    override fun close() = Unit
}
