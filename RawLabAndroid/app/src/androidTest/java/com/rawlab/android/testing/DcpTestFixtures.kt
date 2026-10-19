package com.rawlab.android.testing

import java.io.ByteArrayOutputStream

private data class DcpTag(val key: Int, val kind: Int, val data: ByteArray)

private fun appendInteger(output: ByteArrayOutputStream, value: Long, width: Int) {
    repeat(width) { index -> output.write((value shr (index * 8)).toInt() and 0xff) }
}

private fun type3(vararg values: Int): DcpTag = DcpTag(0, 3, ByteArrayOutputStream().apply {
    values.forEach { appendInteger(this, it.toLong(), 2) }
}.toByteArray())

private fun type4(vararg values: Int): DcpTag = DcpTag(0, 4, ByteArrayOutputStream().apply {
    values.forEach { appendInteger(this, it.toLong(), 4) }
}.toByteArray())

private fun type10(vararg values: Pair<Int, Int>): DcpTag = DcpTag(0, 10, ByteArrayOutputStream().apply {
    values.forEach { (numerator, denominator) ->
        appendInteger(this, numerator.toLong() and 0xffffffffL, 4)
        appendInteger(this, denominator.toLong() and 0xffffffffL, 4)
    }
}.toByteArray())

private fun type11(vararg values: Float): DcpTag = DcpTag(0, 11, ByteArrayOutputStream().apply {
    values.forEach { appendInteger(this, it.toRawBits().toLong() and 0xffffffffL, 4) }
}.toByteArray())

private fun tag(key: Int, value: DcpTag): DcpTag = value.copy(key = key)

internal fun syntheticDcp(): ByteArray {
    val identity = type10(
        1 to 1, 0 to 1, 0 to 1, 0 to 1, 1 to 1, 0 to 1, 0 to 1, 0 to 1, 1 to 1)
    val prophoto = type10(
        7976749 to 10000000, 1351917 to 10000000, 313534 to 10000000,
        2880402 to 10000000, 7118741 to 10000000, 857 to 10000000,
        0 to 1, 0 to 1, 8252100 to 10000000)
    val table = buildList {
        repeat(8) { addAll(listOf(0f, 1f, 1f)) }
    }
    val tags = listOf(
        tag(50708, DcpTag(0, 2, "Synthetic Camera\u0000".toByteArray())),
        tag(50722, identity), tag(50779, type3(21)),
        tag(50936, DcpTag(0, 2, "Synthetic Look\u0000".toByteArray())),
        tag(50940, type11(0f, 0f, 1f, 1f)), tag(50965, prophoto),
        tag(50981, type4(2, 2, 2)), tag(50982, type11(*table.toFloatArray())),
        tag(51110, type4(1)),
    ).sortedBy { it.key }
    val payloadStart = 8 + 2 + tags.size * 12 + 4
    val entries = ByteArrayOutputStream()
    val payload = ByteArrayOutputStream()
    tags.forEach { value ->
        appendInteger(entries, value.key.toLong(), 2)
        appendInteger(entries, value.kind.toLong(), 2)
        val width = when (value.kind) {
            3 -> 2
            4, 11 -> 4
            10 -> 8
            else -> 1
        }
        appendInteger(entries, (value.data.size / width).toLong(), 4)
        if (value.data.size <= 4) {
            entries.write(value.data)
            repeat(4 - value.data.size) { entries.write(0) }
        } else {
            appendInteger(entries, (payloadStart + payload.size()).toLong(), 4)
            payload.write(value.data)
        }
    }
    return ByteArrayOutputStream().apply {
        write('I'.code); write('I'.code)
        appendInteger(this, 0x4352, 2)
        appendInteger(this, 8, 4)
        appendInteger(this, tags.size.toLong(), 2)
        write(entries.toByteArray())
        appendInteger(this, 0, 4)
        write(payload.toByteArray())
    }.toByteArray()
}
