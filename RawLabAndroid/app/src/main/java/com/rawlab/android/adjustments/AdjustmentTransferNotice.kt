package com.rawlab.android.adjustments

// Q3/Q4 粘贴提示：本平台不支持的键收到非 0 值时忽略并提示；处理版本与来源不同
// 时沿用目标处理版本并提示。两种情况都不拒绝粘贴，也不改动目标的其它字段。
enum class AdjustmentTransferNotice(val fieldId: String?, val fixtureId: String) {
    IGNORED_RAW_DENOISE(AdjustmentField.RAW_DENOISE.id, "ignored_raw_denoise"),
    IGNORED_POST_RGB_DENOISE(AdjustmentField.POST_RGB_DENOISE.id, "ignored_post_rgb_denoise"),
    RETAINED_TARGET_PROCESSING_VERSION(null, "retained_target_processing_version"),
}

// Q3/S1：仅聚合实际应用（或确认无需改动）目标的去重提示；跳过、失败或冲突目标不产生误报。
fun effectiveTransferNotices(targets: List<PreparedAdjustmentTransfer.Target>,
    outcomes: List<AdjustmentOutcome>): List<AdjustmentTransferNotice> =
    targets.filter { target -> target.error == null && outcomes.any {
        it.targetID == target.id && it.status in setOf(AdjustmentStatus.APPLIED, AdjustmentStatus.UNCHANGED) } }
        .flatMap { it.notices }.distinct()
