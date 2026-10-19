package com.rawlab.android.looks

import java.io.IOException
import com.rawlab.android.engine.NativeProcessor

// Android passes bytes through JNI; parsing and conversion stay in the shared core.

enum class DcpFailureReason(val code: Int, val messageKey: String) {
    MALFORMED(1, "DCP 文件损坏，或使用了不支持的 TIFF 结构。"),
    TOO_LARGE(2, "DCP 文件或外观数据超过安全大小限制。"),
    INVALID_CALIBRATION(3, "DCP 缺少唯一、有效的 D65 ColorMatrix/ForwardMatrix，无法转换。"),
    MISSING_TONE_CURVE(4, "DCP 缺少 ProfileToneCurve；无法自动推断 Adobe 默认曲线。请先用制备工具明确指定曲线。"),
    AUTOMATIC_BLACK(5, "DCP 要求自动黑位处理，自动转换暂不支持。请先用制备工具明确选择黑位策略。"),
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

fun interface DcpCompiler {
    fun compile(source: ByteArray, sourceName: String): ByteArray
}

object NativeDcpCompiler : DcpCompiler {
    override fun compile(source: ByteArray, sourceName: String): ByteArray =
        NativeProcessor.compileDcp(source, sourceName)
}
