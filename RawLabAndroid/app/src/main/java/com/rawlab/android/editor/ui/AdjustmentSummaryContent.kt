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

internal val summaryGroupStringResources: Map<String, Int> = mapOf(
    "looks" to R.string.transfer_group_looks,
    "light" to R.string.transfer_group_light,
    "color" to R.string.transfer_group_color,
    "effects" to R.string.transfer_group_effects,
    "detail" to R.string.transfer_group_detail,
    "geometry" to R.string.transfer_group_geometry,
)

internal fun summaryGroupTitle(id: String) = AppStrings.text(
    summaryGroupStringResources[id] ?: R.string.transfer_group_geometry
)

internal val summaryStringResources: Map<String, Int> = mapOf(
    "以下为配方逻辑值；强度为 %s。部分范围会按此强度换算。" to R.string.adjustment_summary_recipe_note,
    "多点曲线（%d 个控制点）" to R.string.curve_summary,
    "场景" to R.string.adjustment_summary_exposure_scene,
    "预览" to R.string.adjustment_summary_exposure_preview,
    "传感器基准" to R.string.exposure_sensor,
    "相对白平衡" to R.string.adjustment_summary_relative_white_balance,
    "相机白平衡（按目标照片）" to R.string.adjustment_summary_camera_wb,
    "自定义" to R.string.transfer_custom,
    "不适用" to R.string.adjustment_summary_not_applicable,
    "色相" to R.string.hsl_hue,
    "色调" to R.string.tint,
    "不限" to R.string.hdr_peak_unlimited,
    "饱和度" to R.string.saturation,
    "停用" to R.string.disabled,
    "关闭" to R.string.disabled,
    "细节优先" to R.string.denoise_detail,
    "去噪优先" to R.string.denoise_clean,
    "开启" to R.string.message_on,
    "自动（按目标照片）" to R.string.adjustment_summary_auto_target_photo,
    "待选择的镜头配置" to R.string.adjustment_summary_lens_profile_pending,
    "中性" to R.string.neutral_look,
    "内置" to R.string.adjustment_summary_look_builtin,
    "已保存" to R.string.transfer_applied,
    "配方" to R.string.adjustment_summary_look_recipe,
    "配方 LUT" to R.string.adjustment_summary_look_recipe_lut,
    "外观不可用。" to R.string.collection_look_unavailable,
    "S 曲线" to R.string.tone_curve,
    "默认降噪设置" to R.string.adjustment_summary_default_denoise,
    "亮度降噪" to R.string.denoise_luma,
    "色彩降噪" to R.string.denoise_chroma,
    "粗色斑抑制" to R.string.denoise_coarse,
)

private fun summaryText(key: String) = AppStrings.text(
    summaryStringResources[key] ?: error("Unmapped adjustment summary text: $key")
)
