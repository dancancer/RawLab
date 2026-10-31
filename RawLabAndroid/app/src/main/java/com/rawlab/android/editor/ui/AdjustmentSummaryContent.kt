package com.rawlab.android.editor.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.rawlab.android.R
import com.rawlab.android.adjustments.*
import com.rawlab.android.editor.adjustmentErrorMessage
import com.rawlab.android.i18n.AppStrings

@Composable
internal fun adjustmentSummary(payload: AdjustmentPayload): AdjustmentSummary {
    val context = AppStrings.localizedContext(LocalContext.current)
    return AdjustmentSummary(payload, context.resources.configuration.locales[0], ::summaryText)
}

@Composable
internal fun AdjustmentSummaryContent(payload: AdjustmentPayload, lookName: (String, String) -> String?,
    tag: String = "adjustment-summary", showGroups: Boolean = true) {
    val summary = adjustmentSummary(payload)
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.adjustment_summary_overwrite, summary.count), Modifier.testTag("$tag-count"))
        if (payload.source.isHDR) Text("HDR · " + stringResource(R.string.adjustment_summary_relative_white_balance))
        Text(stringResource(if (summary.includesGeometry) R.string.adjustment_summary_geometry_included
            else R.string.adjustment_summary_geometry_excluded), style = MaterialTheme.typography.bodySmall)
        summary.recipeNote?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        if (showGroups) for (group in summary.groups) {
            TransferDisclosure(summaryGroupTitle(group.id) + " · " + group.fields.size, "$tag-group-${group.id}") {
                for (field in group.fields) Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                    Text(field.title, style = MaterialTheme.typography.labelLarge)
                    Text(summary.valueText(field, lookName), Modifier.testTag("$tag-value-${field.id}"),
                        style = MaterialTheme.typography.bodyMedium)
                }
            }
        }
    }
}

@Composable
internal fun AdjustmentScopeSummaryContent(preview: Result<AdjustmentPayload>, modified: Boolean,
    lookName: (String, String) -> String?, tag: String, showGroups: Boolean) {
    preview.getOrNull()?.let { AdjustmentSummaryContent(it, lookName, tag, showGroups); return }
    val error = preview.exceptionOrNull()
    val empty = (error as? AdjustmentTransferException)?.reason == AdjustmentFailure.EMPTY_SCOPE
    Text(if (empty) stringResource(if (modified) R.string.adjustment_summary_empty_modified else R.string.adjustment_summary_empty_custom)
        else adjustmentErrorMessage(error), modifier = Modifier.testTag("$tag-${if (empty) "empty" else "error"}"),
        color = if (empty) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.error)
}

internal fun summaryGroupTitle(id: String) = AppStrings.text(when (id) {
    "looks" -> R.string.transfer_group_looks
    "light" -> R.string.transfer_group_light
    "color" -> R.string.transfer_group_color
    "effects" -> R.string.transfer_group_effects
    "detail" -> R.string.transfer_group_detail
    else -> R.string.transfer_group_geometry
})

private fun summaryText(key: String) = AppStrings.text(when (key) {
    "以下为配方逻辑值；强度为 %s。部分范围会按此强度换算。" -> R.string.adjustment_summary_recipe_note
    "多点曲线（%d 个控制点）" -> R.string.curve_summary
    "场景" -> R.string.adjustment_summary_exposure_scene
    "预览" -> R.string.adjustment_summary_exposure_preview
    "传感器基准" -> R.string.exposure_sensor
    "相对白平衡" -> R.string.adjustment_summary_relative_white_balance
    "相机白平衡（按目标照片）" -> R.string.adjustment_summary_camera_wb
    "自定义" -> R.string.transfer_custom
    "不适用" -> R.string.adjustment_summary_not_applicable
    "色相" -> R.string.hsl_hue
    "饱和度" -> R.string.saturation
    "停用" -> R.string.disabled
    "细节优先" -> R.string.denoise_detail
    "去噪优先" -> R.string.denoise_clean
    "开启" -> R.string.message_on
    "自动（按目标照片）" -> R.string.adjustment_summary_auto_target_photo
    "待选择的镜头配置" -> R.string.adjustment_summary_lens_profile_pending
    "中性" -> R.string.neutral_look
    "内置" -> R.string.adjustment_summary_look_builtin
    "已保存" -> R.string.transfer_applied
    "配方" -> R.string.adjustment_summary_look_recipe
    "配方 LUT" -> R.string.adjustment_summary_look_recipe_lut
    "外观不可用。" -> R.string.collection_look_unavailable
    "S 曲线" -> R.string.tone_curve
    "默认降噪设置" -> R.string.adjustment_summary_default_denoise
    "亮度降噪" -> R.string.denoise_luma
    "色彩降噪" -> R.string.denoise_chroma
    "粗色斑抑制" -> R.string.denoise_coarse
    else -> error("Unmapped adjustment summary text: $key")
})
