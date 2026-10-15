package com.rawlab.android

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

internal fun syntheticRlook(): ByteArray {
    val out = ByteArrayOutputStream()
    fun int(value: Int) { out.write(ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(value).array()) }
    fun float(value: Float) { out.write(ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putFloat(value).array()) }
    fun double(value: Double) { out.write(ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putDouble(value).array()) }
    out.write("RLOOKDCP".toByteArray())
    listOf(1, 0, 0, 2, 2, 2, 4097, 2).forEach(::int)
    repeat(2) { repeat(9) { index -> double(if (index % 4 == 0) 1.0 else 0.0) } }
    double(1.0)
    repeat(8) { float(0f); float(1f); float(1f) }
    repeat(4097) { index -> double(index / 4096.0) }
    out.write("{}".toByteArray())
    return out.toByteArray()
}
