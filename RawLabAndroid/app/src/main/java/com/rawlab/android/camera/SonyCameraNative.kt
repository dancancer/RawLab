package com.rawlab.android.camera

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.StandardCharsets
import java.util.UUID

internal object SonyCameraNative {
    init {
        System.loadLibrary("rawlab-jni")
    }

    const val STATUS_OK = 0
    const val STATUS_UNSUPPORTED = 2

    const val VALUE_KIND_NUMBER = 0
    const val VALUE_KIND_TEXT = 1
    const val VALUE_KIND_OPAQUE = 2

    const val RENDER_MODE_NONE = 0
    const val RENDER_MODE_LIVE_FRAMES = 1
    const val RENDER_MODE_TAP_RETICLE = 2

    data class DecodedDeviceInfo(
        val status: Int,
        val manufacturer: String,
        val model: String,
        val firmware: String,
        val serial: String,
        val operations: Set<Int>,
    )

    data class DecodedRemoteDescriptor(
        val status: Int,
        val version: Int,
        val enumTables: Int,
        val properties: Set<Int>,
        val controls: Set<Int>,
    )

    data class DecodedProperty(
        val code: Int,
        val type: Int,
        val writable: Boolean,
        val enabled: Int,
        val form: Int,
        val valueKind: Int,
        val numberValue: Long,
        val textValue: String,
        val hasRange: Boolean,
        val minimum: Long,
        val maximum: Long,
        val step: Long,
        val choices: LongArray,
    )

    data class DecodedMobileAsset(
        val content: Int,
        val file: Int,
        val size: Long,
        val created: Long,
        val name: String,
    )

    data class DecodedMobilePage(
        val entryCount: Int,
        val cursor: Long,
        val assets: List<DecodedMobileAsset>,
    )

    data class DecodedLegacyObject(
        val storage: Int,
        val format: Int,
        val size: Long,
        val name: String,
        val created: String,
        val modified: String,
    )

    data class LiveFrameBounds(
        val bodySize: Int,
        val imageOffset: Int,
        val imageLength: Int,
        val hasMetadata: Boolean,
        val metadataOffset: Int,
        val metadataLength: Int,
    )

    data class DecodedLiveFrame(
        val kind: Int,
        val focused: Boolean,
        val cx: Double,
        val cy: Double,
        val width: Double,
        val height: Double,
    )

    @JvmStatic external fun nativeInitCmdPacket(guid16: ByteArray, clientName: String, protocolVersion: Int): ByteArray
    @JvmStatic external fun nativeInitEvtPacket(connectionNumber: Int): ByteArray
    @JvmStatic external fun nativeOpReqPacket(dataPhase: Int, opCode: Int, transactionId: Int, params: IntArray): ByteArray
    @JvmStatic external fun nativeStartDataPacket(transactionId: Int, totalBytes: Long): ByteArray
    @JvmStatic external fun nativeEndDataPacket(transactionId: Int, payload: ByteArray): ByteArray
    @JvmStatic external fun nativeProbeRespPacket(): ByteArray
    @JvmStatic external fun nativeParseHeader(header8: ByteArray, maxPayloadBytes: Long): LongArray
    @JvmStatic external fun nativeParseInitCmdAck(payload: ByteArray): Int
    @JvmStatic external fun nativeParseStartData(payload: ByteArray): LongArray
    @JvmStatic external fun nativeParseResponse(payload: ByteArray): IntArray
    @JvmStatic external fun nativeParseEvent(payload: ByteArray): IntArray

    @JvmStatic external fun nativeIsValidPhotoFilename(name: String): Boolean
    @JvmStatic external fun nativeIsPhotoFilename(name: String): Boolean
    @JvmStatic external fun nativeValidatePhotoHeader(name: String, prefix: ByteArray): Boolean

    @JvmStatic external fun nativeParseDeviceInfo(data: ByteArray): ByteArray
    @JvmStatic external fun nativeParseRemoteDescriptor(data: ByteArray): IntArray
    @JvmStatic external fun nativeParseProperties(data: ByteArray, enumTables: Int): ByteArray
    @JvmStatic external fun nativePropertyCanSet(
        code: Int, type: Int, writable: Boolean, enabled: Int, form: Int,
        hasRange: Boolean, min: Long, max: Long, step: Long, choices: LongArray?, value: Long,
    ): Boolean
    @JvmStatic external fun nativePropertyOptions(
        code: Int, type: Int, writable: Boolean, enabled: Int, form: Int,
        hasRange: Boolean, min: Long, max: Long, step: Long, choices: LongArray?,
        onlySettable: Boolean, sortUnique: Boolean, maxRangeCount: Int,
    ): LongArray

    @JvmStatic external fun nativeFocusIndication(propTableBytes: ByteArray): IntArray
    @JvmStatic external fun nativeCanCancelTouchFocus(
        propTableBytes: ByteArray, controls: IntArray, operations: IntArray, remoteReady: Boolean,
    ): Boolean
    @JvmStatic external fun nativeResolveFocusTarget(
        propTableBytes: ByteArray, controls: IntArray, operations: IntArray, remoteReady: Boolean,
    ): IntArray

    @JvmStatic external fun nativeParseSlotPhotoCount(data: ByteArray): Long
    @JvmStatic external fun nativeParseMobilePage(data: ByteArray): ByteArray
    @JvmStatic external fun nativeParseLegacyObject(data: ByteArray): ByteArray
    @JvmStatic external fun nativeParseLiveFrameBounds(fields4: IntArray, maxTotalBytes: Long): IntArray
    @JvmStatic external fun nativeParseLiveViewFrames(metadata: ByteArray): DoubleArray

    @JvmStatic external fun nativeFocusPointFromTap(
        tapX: Double, tapY: Double, containerWidth: Double, containerHeight: Double,
        imageWidth: Double, imageHeight: Double,
    ): DoubleArray?
    @JvmStatic external fun nativeFocusOverlayBox(
        kind: Int, focused: Boolean, cx: Double, cy: Double, width: Double, height: Double,
        left: Double, top: Double, fittedWidth: Double, fittedHeight: Double,
    ): DoubleArray
    @JvmStatic external fun nativeNormalizedFocusSquareRatio(
        kind: Int, width: Double, height: Double, imageWidth: Double, imageHeight: Double,
    ): Double
    @JvmStatic external fun nativeTapFocusSide(
        fittedWidth: Double, fittedHeight: Double, minDefaultPx: Double,
        maxDefaultPx: Double, minLearnedPx: Double, hasLastRatio: Boolean, lastRatio: Double,
    ): Double

    @JvmStatic external fun nativeFocusStateSize(): Int
    @JvmStatic external fun nativeFocusStateInit(state: ByteArray)
    @JvmStatic external fun nativeFocusStateReset(state: ByteArray, preserveLastRatio: Boolean)
    @JvmStatic external fun nativeFocusStateOnTap(state: ByteArray, u: Double, v: Double, x: Int, y: Int, nowMs: Long)
    @JvmStatic external fun nativeFocusStateOnCancelStart(state: ByteArray)
    @JvmStatic external fun nativeFocusStateOnFocusFinished(state: ByteArray, succeeded: Boolean, focusLocked: Boolean, nowMs: Long)
    @JvmStatic external fun nativeFocusStateOnLiveFrame(state: ByteArray, framesData: DoubleArray, imageWidth: Double, imageHeight: Double)
    @JvmStatic external fun nativeFocusStateOnProperties(
        state: ByteArray, canCancelTouchFocus: Boolean, propsFocusLocked: Boolean, propsFocusFailed: Boolean,
    )
    @JvmStatic external fun nativeFocusStateOnCaptureOrParamStart(state: ByteArray)
    @JvmStatic external fun nativeFocusStateOnLiveChanged(state: ByteArray, liveActive: Boolean)
    @JvmStatic external fun nativeFocusStateOnTick(state: ByteArray, nowMs: Long)
    @JvmStatic external fun nativeFocusStateOnTimeout(state: ByteArray, generation: Long, nowMs: Long)
    @JvmStatic external fun nativeFocusStateSnapshot(state: ByteArray): DoubleArray
    @JvmStatic external fun nativeFocusStateResolveRender(
        state: ByteArray, left: Double, top: Double, fittedWidth: Double, fittedHeight: Double,
        minDefaultPx: Double, maxDefaultPx: Double, minLearnedPx: Double,
    ): DoubleArray

    @JvmStatic
    fun initCmdPacket(guid: UUID, clientName: String, protocolVersion: Int = 0x10000): ByteArray {
        val id = ByteBuffer.allocate(16)
            .putLong(guid.mostSignificantBits)
            .putLong(guid.leastSignificantBits)
            .array()
        return nativeInitCmdPacket(id, clientName, protocolVersion)
    }

    @JvmStatic
    fun parseDeviceInfo(data: ByteArray): DecodedDeviceInfo {
        val buf = ByteBuffer.wrap(nativeParseDeviceInfo(data)).order(ByteOrder.LITTLE_ENDIAN)
        val status = buf.int
        if (status != STATUS_OK) {
            return DecodedDeviceInfo(status, "", "", "", "", emptySet())
        }
        val manufacturer = readLenString(buf)
        val model = readLenString(buf)
        val firmware = readLenString(buf)
        val serial = readLenString(buf)
        val opCount = buf.int
        val ops = HashSet<Int>(opCount)
        repeat(opCount) { ops.add(buf.short.toInt() and 0xffff) }
        return DecodedDeviceInfo(status, manufacturer, model, firmware, serial, ops)
    }

    @JvmStatic
    fun parseRemoteDescriptor(data: ByteArray): DecodedRemoteDescriptor {
        val raw = nativeParseRemoteDescriptor(data)
        val status = raw[0]
        val version = raw[1]
        val enumTables = raw[2]
        if (status != STATUS_OK) {
            return DecodedRemoteDescriptor(status, version, enumTables, emptySet(), emptySet())
        }
        val propCount = raw[3]
        val ctrlCount = raw[4]
        val props = HashSet<Int>(propCount)
        var idx = 5
        repeat(propCount) { props.add(raw[idx++]) }
        val ctrls = HashSet<Int>(ctrlCount)
        repeat(ctrlCount) { ctrls.add(raw[idx++]) }
        return DecodedRemoteDescriptor(status, version, enumTables, props, ctrls)
    }

    @JvmStatic
    fun parseProperties(data: ByteArray, enumTables: Int): List<DecodedProperty> {
        val buf = ByteBuffer.wrap(nativeParseProperties(data, enumTables)).order(ByteOrder.LITTLE_ENDIAN)
        val count = buf.int
        val list = ArrayList<DecodedProperty>(count)
        repeat(count) {
            val code = buf.short.toInt() and 0xffff
            val type = buf.short.toInt() and 0xffff
            val writable = buf.get().toInt() != 0
            val enabled = buf.get().toInt() and 0xff
            val form = buf.get().toInt() and 0xff
            val valueKind = buf.get().toInt() and 0xff
            val numberValue = buf.long
            val textValue = readLenString(buf)
            val hasRange = buf.get().toInt() != 0
            val minimum = buf.long
            val maximum = buf.long
            val step = buf.long
            val choiceCount = buf.int
            val choices = LongArray(choiceCount) { buf.long }
            list.add(
                DecodedProperty(
                    code = code,
                    type = type,
                    writable = writable,
                    enabled = enabled,
                    form = form,
                    valueKind = valueKind,
                    numberValue = numberValue,
                    textValue = textValue,
                    hasRange = hasRange,
                    minimum = minimum,
                    maximum = maximum,
                    step = step,
                    choices = choices,
                ),
            )
        }
        return list
    }

    @JvmStatic
    fun encodeNumericPropertyTable(entries: List<LongArray>): ByteArray {
        // Each entry is [code, writable(0/1), enabled, numberValue].
        val buf = ByteBuffer.allocate(8 + entries.size * 23).order(ByteOrder.LITTLE_ENDIAN)
        buf.putLong(entries.size.toLong())
        for (e in entries) {
            buf.putShort(e[0].toInt().toShort())
            buf.putShort(8.toShort())
            buf.put(e[1].toByte())
            buf.put(e[2].toByte())
            buf.putLong(e[3])
            buf.putLong(e[3])
            buf.put(0.toByte())
        }
        return buf.array()
    }

    @JvmStatic
    fun parseMobilePage(data: ByteArray): DecodedMobilePage {
        val buf = ByteBuffer.wrap(nativeParseMobilePage(data)).order(ByteOrder.LITTLE_ENDIAN)
        val entryCount = buf.int
        val cursor = buf.long
        val assetCount = buf.int
        val assets = ArrayList<DecodedMobileAsset>(assetCount)
        repeat(assetCount) {
            val content = buf.int
            val file = buf.int
            val size = buf.long
            val created = buf.long
            val name = readLenString(buf)
            assets.add(DecodedMobileAsset(content, file, size, created, name))
        }
        return DecodedMobilePage(entryCount, cursor, assets)
    }

    @JvmStatic
    fun parseLegacyObject(data: ByteArray): DecodedLegacyObject {
        val buf = ByteBuffer.wrap(nativeParseLegacyObject(data)).order(ByteOrder.LITTLE_ENDIAN)
        val storage = buf.int
        val format = buf.short.toInt() and 0xffff
        val size = buf.long
        val name = readLenString(buf)
        val created = readLenString(buf)
        val modified = readLenString(buf)
        return DecodedLegacyObject(storage, format, size, name, created, modified)
    }

    @JvmStatic
    fun parseLiveFrameBounds(fields4: IntArray, maxTotalBytes: Long): LiveFrameBounds {
        val r = nativeParseLiveFrameBounds(fields4, maxTotalBytes)
        return LiveFrameBounds(
            bodySize = r[0],
            imageOffset = r[1],
            imageLength = r[2],
            hasMetadata = r[3] != 0,
            metadataOffset = r[4],
            metadataLength = r[5],
        )
    }

    @JvmStatic
    fun parseLiveViewFrames(metadata: ByteArray): List<DecodedLiveFrame> {
        val raw = nativeParseLiveViewFrames(metadata)
        val count = raw.size / 6
        val list = ArrayList<DecodedLiveFrame>(count)
        for (i in 0 until count) {
            val b = i * 6
            list.add(
                DecodedLiveFrame(
                    kind = raw[b + 0].toInt(),
                    focused = raw[b + 1] != 0.0,
                    cx = raw[b + 2],
                    cy = raw[b + 3],
                    width = raw[b + 4],
                    height = raw[b + 5],
                ),
            )
        }
        return list
    }

    private fun readLenString(buf: ByteBuffer): String {
        val len = buf.int
        if (len <= 0) return ""
        val bytes = ByteArray(len)
        buf.get(bytes)
        return String(bytes, StandardCharsets.UTF_8)
    }
}
