package com.rawlab.android.camera

import com.rawlab.android.camera.protocol.SonyLegacyImportSession
import com.rawlab.android.camera.protocol.SonyMobileSession
import com.rawlab.android.camera.protocol.SonyTetherSession
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStream
import java.net.InetAddress
import java.net.URL
import java.util.UUID
import javax.net.SocketFactory

internal data class CameraHostOriginal(val name: String, val size: Long, val digest: String)
internal data class CameraCardSnapshot(val photos: List<CameraPhoto>,
    val download: (CameraPhoto, FileOutputStream, (Long) -> Unit) -> String)
internal data class CameraTetherParameter(val code: Int, val current: Long, val options: List<Long>,
    val writable: Boolean, val enabled: Boolean)
internal data class CameraTetherParameterReadback(val values: List<CameraTetherParameter>, val writable: Boolean, val captureReady: Boolean)
internal data class CameraTetherParameterWrite(val confirmed: Boolean, val readback: CameraTetherParameterReadback)

/** 一个调度器独占此对象；只有停止操作可从其他线程调用。 */
internal class CameraTetherTransport(private val factory: SocketFactory, private val address: InetAddress,
    private val clientId: UUID, val model: SonyCameraModel, private val cardSavingConfirmed: Boolean) {
    var usesLegacyContents = false
        private set
    @Volatile private var stopped = false
    @Volatile private var remote: SonyTetherSession? = null
    @Volatile private var media: SonyLegacyImportSession? = null

    @Synchronized
    fun readCard(): CameraCardSnapshot {
        checkRunning()
        val openedRemote = activateRemoteSession()
        if (!usesLegacyContents) {
            val assets = openedRemote.listPhotos().associateBy { it.key() }
            return CameraCardSnapshot(assets.values.map(::photo)) { photo, output, progress ->
                openedRemote.download(assets.getValue(photo.key), object : OutputStream() {
                    var count = 0L
                    override fun write(value: Int) { output.write(value); progress(++count) }
                    override fun write(bytes: ByteArray, offset: Int, length: Int) {
                        output.write(bytes, offset, length); count += length; progress(count)
                    }
                })
            }
        }
        // 内容模式与遥控必须用不同 PTP 会话；否则 ZV-E10 会确认快门但不曝光。
        remote?.close(); remote = null
        media?.close()
        val opened = SonyLegacyImportSession(factory, address, clientId, ::trace)
        media = opened
        checkRunning()
        val info = opened.deviceInfo()
        opened.openSession()
        val assets = opened.listPhotos(info).associateBy { it.key() }
        return CameraCardSnapshot(assets.values.map(::photo)) { photo, output, progress ->
            opened.download(info, assets.getValue(photo.key), output) { bytes, _ -> progress(bytes) }
        }
    }

    @Synchronized
    fun activateRemote(): URL? {
        checkRunning()
        val opened = activateRemoteSession()
        val state = checkNotNull(remote).properties()
        val source = state[0xd278]?.text() ?: return null
        return SonyTetherSession.liveViewURL(source, address)
    }

    @Synchronized
    fun readParameters(): CameraTetherParameterReadback {
        checkRunning()
        val opened = activateRemoteSession()
        return parameterReadback(opened.properties(), opened.supportsParameterWrites(), opened.supportsShutter())
    }

    @Synchronized
    fun setParameter(code: Int, requested: Long): CameraTetherParameterWrite {
        checkRunning()
        val opened = activateRemoteSession()
        val result = opened.setNumericProperty(code, requested)
        return CameraTetherParameterWrite(result.confirmed,
            parameterReadback(result.properties, opened.supportsParameterWrites(), opened.supportsShutter()))
    }

    fun capture() {
        checkRunning()
        val opened = remote ?: throw IOException("Remote session unavailable")
        if (usesLegacyContents) opened.captureWithConfirmedCardSaving(cardSavingConfirmed) else opened.capture()
    }

    fun hasPendingHostImage(): Boolean {
        checkRunning()
        return usesLegacyContents && remote?.pendingLegacyCapture() != null
    }

    fun drainHostImages(): List<CameraHostOriginal> {
        checkRunning()
        val opened = remote ?: throw IOException("Remote session unavailable")
        val result = mutableListOf<CameraHostOriginal>()
        repeat(4) {
            val photo = opened.pendingLegacyCapture() ?: return result
            val digest = opened.downloadLegacyPending(photo, object : OutputStream() {
                override fun write(value: Int) { checkRunning() }
                override fun write(bytes: ByteArray, offset: Int, length: Int) { checkRunning() }
            })
            result += CameraHostOriginal(photo.name, photo.size, digest)
        }
        if (opened.pendingLegacyCapture() != null) throw CameraTetherBacklogException()
        return result
    }

    fun stop() {
        stopped = true
        remote?.requestStop()
        media?.close()
    }

    private fun trace(message: String) {
        if (com.rawlab.android.BuildConfig.DEBUG) android.util.Log.d("RawLabCamera", message)
    }
    fun close() { stopped = true; remote?.close(); remote = null; media?.close(); media = null }
    private fun checkRunning() { if (stopped) throw IOException("Camera tether stopped") }
    private fun photo(asset: SonyMobileSession.Asset) = CameraPhoto(asset.key(), asset.name, asset.size, asset.created)

    private fun activateRemoteSession(): SonyTetherSession {
        if (remote == null) {
            media?.finish(); media = null
            val opened = SonyTetherSession(factory, address, clientId, ::trace)
            remote = opened
            checkRunning()
            opened.connectRemote()
            usesLegacyContents = !opened.supportsOperation(0x923c) || !opened.supportsOperation(0x923d)
            if (usesLegacyContents && !listOf(0x9212, 0x1004, 0x1007, 0x1008, 0x1009).all(opened::supportsOperation))
                throw com.rawlab.android.camera.protocol.CameraMediaSession.UnsupportedCameraException("Photo import is unavailable in this camera mode")
            if (usesLegacyContents) {
                // 真机验证需要遥控初始化稳定后再读属性或接受拍摄。
                repeat(35) { checkRunning(); Thread.sleep(100) }
            }
        }
        return checkNotNull(remote)
    }

    private fun parameterReadback(properties: Map<Int, SonyTetherSession.Property>, writable: Boolean, shutter: Boolean): CameraTetherParameterReadback {
        val values = properties.values.mapNotNull { property ->
            runCatching { CameraTetherParameter(property.code, property.number(), property.options().filterNot { property.code == 0xd20d && it == 0L },
                property.writable && property.enabled == 1, property.enabled == 1) }.getOrNull()
        }.associateBy { it.code }.values.toList()
        val card = if (usesLegacyContents) cardSavingConfirmed else (properties[0xd222]?.number()?.and(0x10) ?: 0) != 0L
        return CameraTetherParameterReadback(values, writable, shutter && card && properties[0x5013]?.number() == 1L)
    }
}

internal class CameraTetherSettingsException : IOException("Camera must save to card in single-shot mode")

/** 手机回传可能是 2M 图；仅同名同尺寸的唯一对象参与额外摘要比对，卡内枚举始终是原件来源。 */
internal fun hostDigestsForCard(host: List<CameraHostOriginal>, photos: List<CameraPhoto>): Map<String, String> =
    host.mapNotNull { original ->
        photos.singleOrNull { it.name == original.name && it.size == original.size }?.let { it.key to original.digest }
    }.toMap()
