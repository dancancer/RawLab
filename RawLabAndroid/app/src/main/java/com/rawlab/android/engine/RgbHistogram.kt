package com.rawlab.android.engine

class RgbHistogram private constructor(val width: Int, val height: Int, private val bins: LongArray) {
    val peak: Long = bins.max()

    fun count(channel: Int, bin: Int): Long = bins[channel * 256 + bin]

    data class Segment(val lower: Float, val upper: Float, val channels: Int)

    fun segments(bin: Int): List<Segment> {
        if (bin !in 0..255) return emptyList()
        val heights = (0..2).map { count(it, bin).toFloat() / peak }
        var lower = 0f
        return heights.filter { it > 0f }.distinct().sorted().map { upper ->
            val channels = (0..2).fold(0) { mask, channel -> mask or if (heights[channel] >= upper) 1 shl channel else 0 }
            Segment(lower, upper, channels).also { lower = upper }
        }
    }

    companion object {
        fun fromNative(width: Int, height: Int, counts: IntArray?): RgbHistogram? {
            if (width <= 0 || height <= 0 || counts?.size != 768) return null
            val pixels = width.toLong() * height
            if (pixels > 0xffffffffL) return null
            // JNI IntArray 按位保留 UInt32；转换后只持有 Kotlin 自己的不可变统计。
            val bins = LongArray(768) { counts[it].toLong() and 0xffffffffL }
            if ((0..2).any { channel -> (0..255).sumOf { bins[channel * 256 + it] } != pixels }) return null
            return RgbHistogram(width, height, bins)
        }
    }
}
