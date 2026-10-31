package com.rawlab.android.format

// ============================================================================
//  输入文件的种类：RAW 与普通图像（JPEG/PNG）按扩展名和 MIME 判断
// ============================================================================

enum class PhotoInputKind { RAW, RASTER }

internal object PhotoFiles {
    fun isX3f(file: java.io.File): Boolean = file.inputStream().use {
        val signature = ByteArray(4)
        it.read(signature) == 4 && signature.contentEquals(byteArrayOf(70, 79, 86, 98))
    }

    fun kind(name: String, mime: String?): PhotoInputKind? {
        val raw = RawFiles.accepts(name, mime)
        val raster = RasterFiles.accepts(name, mime)
        return when {
            raw && raster -> null
            raw -> PhotoInputKind.RAW
            raster -> PhotoInputKind.RASTER
            else -> null
        }
    }

    fun accepts(name: String, mime: String?): Boolean = kind(name, mime) != null
}

internal object RasterFiles {
    private val extensions = setOf("jpg", "jpeg", "png", "heic", "heif")
    private val mimes = setOf("image/jpeg", "image/png", "image/heic", "image/heif", "image/heif-sequence")

    fun accepts(name: String, mime: String?): Boolean =
        name.substringAfterLast('.', "").lowercase() in extensions || mime?.lowercase() in mimes
}

object RawFiles {
    private val extensions = setOf("dng", "arw", "arq", "srf", "sr2", "cr2", "cr3", "crw", "nef", "nrw", "raf", "orf", "rw2", "pef", "srw", "3fr", "iiq", "rwl", "mos", "mrw", "raw", "kdc", "dcr", "erf", "x3f")
    private val mimes = setOf("image/x-adobe-dng", "image/x-sony-arw", "image/x-canon-cr2", "image/x-canon-cr3", "image/x-nikon-nef", "image/x-fuji-raf", "image/x-panasonic-rw2", "image/x-olympus-orf", "image/x-pentax-pef")
    fun accepts(name: String, mime: String?) = name.substringAfterLast('.', "").lowercase() in extensions || mime?.lowercase() in mimes
}
