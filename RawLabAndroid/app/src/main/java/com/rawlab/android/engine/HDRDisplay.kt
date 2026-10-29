package com.rawlab.android.engine

import kotlin.math.log2
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

enum class HDRPreviewMode { AUTOMATIC, SDR }

data class HDRDisplayParameters(val headroom: Float, val mode: HDRPreviewMode = HDRPreviewMode.AUTOMATIC,
    val falseColor: Boolean = false) {
    val safeHeadroom get() = if (headroom.isFinite()) headroom.coerceIn(1f, 65504f) else 1f
}

data class HDRStatistics(val bins: IntArray, val aboveWhite: Int, val headroom: Float, val pixels: Int) {
    companion object {
        fun analyze(values: FloatArray, width: Int, height: Int, stride: Int): HDRStatistics {
            require(width > 0 && height > 0 && stride >= width * 3 && values.size >= (height - 1) * stride + width * 3)
            val bins = IntArray(256)
            var above = 0
            var peak = 1f
            for (y in 0 until height) for (x in 0 until width) {
                val index = y * stride + x * 3
                val r = values[index]; val g = values[index + 1]; val b = values[index + 2]
                require(r.isFinite() && g.isFinite() && b.isFinite())
                val luminance = HDRDisplayMath.luminance(r, g, b)
                require(luminance.isFinite())
                val ev = if (luminance > 0f) log2(luminance) else -8f
                val bin = (((ev.coerceIn(-8f, 8f) + 8f) * 16f).toInt()).coerceIn(0, 255)
                bins[bin] += 1
                if (luminance > 1f) above += 1
                peak = max(peak, luminance)
            }
            return HDRStatistics(bins, above, peak, width * height)
        }
    }
}

object HDRDisplayMath {
    fun luminance(r: Float, g: Float, b: Float): Float = .2126f * r + .7152f * g + .0722f * b

    fun pixel(hdr: FloatArray, sdr: FloatArray, contentHeadroom: Float,
        parameters: HDRDisplayParameters): FloatArray {
        require(hdr.size >= 3 && sdr.size >= 3 && hdr.take(3).all(Float::isFinite) && sdr.take(3).all(Float::isFinite))
        require(contentHeadroom.isFinite() && contentHeadroom >= 1f)
        val output = FloatArray(3)
        pixelInto(hdr, sdr, 0, contentHeadroom, parameters, output)
        return output
    }

    fun pixelInto(hdr: FloatArray, sdr: FloatArray, offset: Int, contentHeadroom: Float,
        parameters: HDRDisplayParameters, output: FloatArray) {
        require(offset >= 0 && offset + 3 <= hdr.size && offset + 3 <= sdr.size && output.size >= 3)
        require(hdr[offset].isFinite() && hdr[offset + 1].isFinite() && hdr[offset + 2].isFinite() &&
            sdr[offset].isFinite() && sdr[offset + 1].isFinite() && sdr[offset + 2].isFinite())
        require(contentHeadroom.isFinite() && contentHeadroom >= 1f)
        val h = parameters.safeHeadroom
        if (parameters.falseColor) {
            val y = luminance(hdr[offset], hdr[offset + 1], hdr[offset + 2])
            when {
                y > h -> { output[0] = 1f; output[1] = 0f; output[2] = .35f }
                y > 1f -> { output[0] = 1f; output[1] = .6f; output[2] = 0f }
                y <= .01f -> { output[0] = .02f; output[1] = .15f; output[2] = .7f }
                else -> { output[0] = .35f; output[1] = .35f; output[2] = .35f }
            }
            return
        }
        if (parameters.mode == HDRPreviewMode.SDR || h <= 1f) {
            output[0] = sdr[offset]; output[1] = sdr[offset + 1]; output[2] = sdr[offset + 2]; return
        }
        val y = luminance(hdr[offset], hdr[offset + 1], hdr[offset + 2])
        if (y <= 1f || contentHeadroom <= h) {
            output[0] = hdr[offset]; output[1] = hdr[offset + 1]; output[2] = hdr[offset + 2]; return
        }
        val a = (contentHeadroom - h) / ((h - 1f) * (contentHeadroom - 1f))
        val mapped = 1f + (y - 1f) / (1f + a * (y - 1f))
        val scale = mapped / y
        output[0] = hdr[offset] * scale; output[1] = hdr[offset + 1] * scale; output[2] = hdr[offset + 2] * scale
    }

    fun packHalf(values: FloatArray): ShortArray? {
        if (values.any { !it.isFinite() || it > 65504f || it < -65504f }) return null
        return ShortArray(values.size) { index -> floatToHalf(values[index]).toShort() }
    }

    fun packHalfInto(values: FloatArray, output: ShortArray, offset: Int): Boolean {
        if (offset < 0 || offset + values.size > output.size || values.any { !it.isFinite() || it > 65504f || it < -65504f }) return false
        values.forEachIndexed { index, value -> output[offset + index] = floatToHalf(value).toShort() }
        return true
    }

    fun halfToFloat(bits: Short): Float {
        val value = bits.toInt() and 0xffff
        val sign = (value ushr 15) and 1
        val exponent = (value ushr 10) and 0x1f
        val fraction = value and 0x3ff
        val result = when (exponent) {
            0 -> if (fraction == 0) 0f else (fraction / 1024f) * (1f / 16384f)
            31 -> if (fraction == 0) Float.POSITIVE_INFINITY else Float.NaN
            else -> (1f + fraction / 1024f) * 2f.pow(exponent - 15)
        }
        return if (sign == 0) result else -result
    }

    private fun floatToHalf(value: Float): Int {
        val bits = java.lang.Float.floatToRawIntBits(value)
        val sign = (bits ushr 16) and 0x8000
        val exponent = (bits ushr 23) and 0xff
        val fraction = bits and 0x7fffff
        if (exponent == 255) return sign or if (fraction == 0) 0x7c00 else 0x7e00
        if (exponent > 142) return sign or 0x7c00
        if (exponent < 102) return sign
        val significant = if (exponent < 113) fraction or 0x800000 else fraction
        val shift = if (exponent < 113) 126 - exponent else 13
        // ties-to-even，尾数舍入进位必须加到指数，不能按位 OR。
        val rounded = (significant + ((1 shl (shift - 1)) - 1) + ((significant ushr shift) and 1)) ushr shift
        val result = if (exponent < 113) rounded else ((exponent - 112) shl 10) + rounded
        return sign or result
    }

}
