package com.rawlab.android.editor

import com.rawlab.android.R
import com.rawlab.android.adjustments.AdjustmentFailure
import com.rawlab.android.adjustments.AdjustmentTransferException
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.presets.AdjustmentPreset
import java.util.UUID

enum class QuickPresetPhase { IDLE, PREPARING, COMMITTING, SAVED, UNCHANGED, UNDONE, FAILED, UNDO_FAILED }
data class EditorQuickPresetState(val visible: Boolean = false, val phase: QuickPresetPhase = QuickPresetPhase.IDLE,
    val preset: AdjustmentPreset? = null, val transactionID: UUID? = null, val message: String? = null) {
    val busy get() = phase == QuickPresetPhase.PREPARING || phase == QuickPresetPhase.COMMITTING
}

internal fun quickPresetErrorMessage(error: Throwable?): String = when {
    error is AdjustmentTransferException && error.reason == AdjustmentFailure.INCOMPATIBLE -> AppStrings.text(when {
        error.field == "hdr.relative_white_balance" -> R.string.preset_quick_error_mode
        error.field?.startsWith("select white balance mode") == true -> R.string.preset_quick_error_white_balance_scope
        error.field == "target camera white balance unavailable" -> R.string.tool_white_balance_unavailable
        else -> R.string.preset_quick_error_incompatible
    })
    error is AdjustmentTransferException && error.reason == AdjustmentFailure.UNREPRESENTABLE -> AppStrings.text(R.string.preset_quick_error_preserve)
    else -> adjustmentErrorMessage(error)
}
