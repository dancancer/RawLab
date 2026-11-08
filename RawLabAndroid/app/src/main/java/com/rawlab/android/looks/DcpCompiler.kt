package com.rawlab.android.looks

import android.net.Uri
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import com.rawlab.android.engine.NativeProcessor

// Android passes bytes through JNI; parsing and conversion stay in the shared core.

enum class DcpFailureReason(val code: Int, val messageKey: String) {
    MALFORMED(1, "DCP 文件损坏，或使用了不支持的 TIFF 结构。"),
    TOO_LARGE(2, "DCP 文件或外观数据超过安全大小限制。"),
    INVALID_CALIBRATION(3, "DCP 缺少唯一、有效的 D65 ColorMatrix/ForwardMatrix，无法转换。"),
    MISSING_TONE_CURVE(4, "DCP 没有内嵌色调曲线。"),
    AUTOMATIC_BLACK(5, "DCP 要求自动黑位处理。"),
    TRIPLE_ILLUMINANT(6, "DCP 使用三光源 HueSatMap，暂不支持转换。"),
    UNSUPPORTED_STAGES(7, "DCP 包含暂不支持的空间增益、HDR 或 RGB 表处理，无法转换。"),
    INVALID_TABLE(8, "DCP 的 HueSatMap/LookTable 数据、维度或编码不受支持。"),
    INVALID_TONE_CURVE(9, "DCP 曲线无效；需要 2 至 8192 个有限、范围为 0 至 1 且横坐标递增的点。"),
    INVALID_EXPOSURE(10, "DCP 曝光偏移无效；需要 -16 至 +16 EV 的有限数值。"),
    ;

    companion object {
        fun fromCode(code: Int): DcpFailureReason = entries.firstOrNull { it.code == code } ?: MALFORMED
    }
}

/** 编译器拒绝需与 CUBE/RLOOK 无效区分。 */
class DcpCompilationException internal constructor(code: Int) : IOException(
    DcpFailureReason.fromCode(code).messageKey
) {
    val reason: DcpFailureReason = DcpFailureReason.fromCode(code)

    constructor(reason: DcpFailureReason, cause: Throwable? = null) : this(reason.code) {
        if (cause != null) initCause(cause)
    }
}

data class DcpImportChoices(val toneCurve: Uri?, val omitAutomaticBlack: Boolean)

fun interface DcpCompiler {
    fun compile(source: ByteArray, sourceName: String, toneCurve: ByteArray?, omitAutomaticBlack: Boolean): ByteArray
}

object NativeDcpCompiler : DcpCompiler {
    override fun compile(source: ByteArray, sourceName: String, toneCurve: ByteArray?, omitAutomaticBlack: Boolean): ByteArray =
        NativeProcessor.compileDcp(source, sourceName, toneCurve, omitAutomaticBlack)
}

internal fun readDcpInput(input: InputStream, maxBytes: Int): ByteArray {
    val data = ByteArrayOutputStream()
    val buffer = ByteArray(64 * 1024)
    while (true) {
        val count = input.read(buffer, 0, minOf(buffer.size, maxBytes - data.size() + 1))
        if (count < 0) return data.toByteArray()
        if (data.size() + count > maxBytes) throw DcpCompilationException(DcpFailureReason.TOO_LARGE)
        data.write(buffer, 0, count)
    }
}
