package com.rawlab.android.photo

import java.io.InputStream
import java.io.OutputStream
import java.io.IOException

internal const val maximumHDRCameraProfileBytes = 128L * 1024 * 1024

internal fun checkHDRCameraProfileSize(size: Long?) {
    if (size != null && size !in 1..maximumHDRCameraProfileBytes) throw IOException("Invalid HDR camera profile source size")
}

internal fun copyHDRCameraProfileSource(input: InputStream, output: OutputStream) {
    val buffer = ByteArray(65536)
    var size = 0L
    while (true) {
        val count = input.read(buffer, 0, minOf(buffer.size.toLong(), maximumHDRCameraProfileBytes - size + 1).toInt())
        if (count < 0) break
        size += count
        if (size > maximumHDRCameraProfileBytes) throw IOException("HDR camera profile source exceeds 128 MiB")
        output.write(buffer, 0, count)
    }
    checkHDRCameraProfileSize(size)
}
