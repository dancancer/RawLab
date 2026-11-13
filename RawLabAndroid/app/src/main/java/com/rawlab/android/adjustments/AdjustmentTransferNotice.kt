package com.rawlab.android.adjustments

// Q3/Q4 粘贴提示：本平台不支持的键收到非 0 值时忽略并提示；处理版本与来源不同
// 时沿用目标处理版本并提示。两种情况都不拒绝粘贴，也不改动目标的其它字段。
enum class AdjustmentTransferNotice(val fieldId: String?) {
    IGNORED_RAW_DENOISE(AdjustmentField.RAW_DENOISE.id),
    IGNORED_POST_RGB_DENOISE(AdjustmentField.POST_RGB_DENOISE.id),
    RETAINED_TARGET_PROCESSING_VERSION(null),
}
