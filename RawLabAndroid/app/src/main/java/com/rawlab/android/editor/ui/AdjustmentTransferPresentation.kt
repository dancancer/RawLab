package com.rawlab.android.editor.ui

import com.rawlab.android.R
import com.rawlab.android.adjustments.*
import com.rawlab.android.i18n.AppStrings

internal val AdjustmentField.title: String get() {
    hslLocation?.let { (axis, channel) ->
        return AppStrings.text(listOf(R.string.transfer_channel_0,R.string.transfer_channel_1,R.string.transfer_channel_2,R.string.transfer_channel_3,R.string.transfer_channel_4,R.string.transfer_channel_5,R.string.transfer_channel_6,R.string.transfer_channel_7)[channel]) + " · " +
            AppStrings.text(listOf(R.string.transfer_axis_0,R.string.transfer_axis_1,R.string.transfer_axis_2)[axis])
    }
    return AppStrings.text(when (this) {
        AdjustmentField.LOOK -> R.string.transfer_field_look
        AdjustmentField.STRENGTH -> R.string.transfer_field_strength
        AdjustmentField.EXPOSURE -> R.string.transfer_field_exposure
        AdjustmentField.EXPOSURE_MODE -> R.string.transfer_field_exposure_mode
        AdjustmentField.CONTRAST -> R.string.transfer_field_contrast
        AdjustmentField.HIGHLIGHTS -> R.string.transfer_field_highlights
        AdjustmentField.SHADOWS -> R.string.transfer_field_shadows
        AdjustmentField.S_CURVE -> R.string.transfer_field_s_curve
        AdjustmentField.WHITE_BALANCE_MODE -> R.string.transfer_field_white_balance_mode
        AdjustmentField.TEMPERATURE -> R.string.transfer_field_temperature
        AdjustmentField.TINT -> R.string.transfer_field_tint
        AdjustmentField.SATURATION -> R.string.transfer_field_saturation
        AdjustmentField.VIGNETTE_AMOUNT -> R.string.transfer_field_vignette_amount
        AdjustmentField.VIGNETTE_MIDPOINT -> R.string.transfer_field_vignette_midpoint
        AdjustmentField.VIGNETTE_ROUNDNESS -> R.string.transfer_field_vignette_roundness
        AdjustmentField.VIGNETTE_FEATHER -> R.string.transfer_field_vignette_feather
        AdjustmentField.VIGNETTE_HIGHLIGHTS -> R.string.transfer_field_vignette_highlights
        AdjustmentField.GRAIN_AMOUNT -> R.string.transfer_field_grain_amount
        AdjustmentField.GRAIN_SIZE -> R.string.transfer_field_grain_size
        AdjustmentField.GRAIN_ROUGHNESS -> R.string.transfer_field_grain_roughness
        AdjustmentField.SHARPENING -> R.string.transfer_field_sharpening
        AdjustmentField.RAW_DENOISE -> R.string.transfer_field_raw_denoise
        AdjustmentField.POST_RGB_DENOISE -> R.string.transfer_field_post_rgb_denoise
        AdjustmentField.CHROMA_DENOISE -> R.string.transfer_field_chroma_denoise
        AdjustmentField.WAVELET_DENOISE -> R.string.transfer_field_wavelet_denoise
        AdjustmentField.CROP_X -> R.string.transfer_field_crop_x
        AdjustmentField.CROP_Y -> R.string.transfer_field_crop_y
        AdjustmentField.CROP_WIDTH -> R.string.transfer_field_crop_width
        AdjustmentField.CROP_HEIGHT -> R.string.transfer_field_crop_height
        AdjustmentField.QUARTER_TURNS -> R.string.transfer_field_quarter_turns
        AdjustmentField.FLIP_HORIZONTAL -> R.string.transfer_field_flip_horizontal
        AdjustmentField.FLIP_VERTICAL -> R.string.transfer_field_flip_vertical
        AdjustmentField.STRAIGHTEN -> R.string.transfer_field_straighten
        AdjustmentField.PERSPECTIVE_HORIZONTAL -> R.string.transfer_field_perspective_horizontal
        AdjustmentField.PERSPECTIVE_VERTICAL -> R.string.transfer_field_perspective_vertical
        AdjustmentField.LENS_DISTORTION -> R.string.transfer_field_lens_distortion
        AdjustmentField.LENS_TCA -> R.string.transfer_field_lens_tca
        AdjustmentField.LENS_AUTO_CROP -> R.string.transfer_field_lens_auto_crop
        AdjustmentField.LENS_PROFILE -> R.string.transfer_field_lens_profile
        else -> error("HSL field must have a channel")
    })
}
internal val AdjustmentStatus.title: String get() = AppStrings.text(when (this) {
    AdjustmentStatus.APPLIED -> R.string.transfer_applied
    AdjustmentStatus.UNCHANGED -> R.string.transfer_unchanged
    AdjustmentStatus.SKIPPED -> R.string.transfer_skipped
    AdjustmentStatus.BLOCKED -> R.string.transfer_blocked
    AdjustmentStatus.CONFLICT -> R.string.transfer_conflict
    AdjustmentStatus.FAILED -> R.string.transfer_failed
})
