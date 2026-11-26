package com.rawlab.android.editor.ui

import com.rawlab.android.R
import com.rawlab.android.adjustments.*
import com.rawlab.android.i18n.AppStrings

internal val AdjustmentField.title: String get() {
    if (this == AdjustmentField.HDR_CAMERA_DEVELOPMENT) return "HDR RAW"
    gradingZone?.let { return AppStrings.text(R.string.color_grading) + " · " + AppStrings.text(gradingZoneTitle(it)) }
    hslLocation?.let { (axis, channel) ->
        return AppStrings.text(listOf(R.string.transfer_channel_0,R.string.transfer_channel_1,R.string.transfer_channel_2,R.string.transfer_channel_3,R.string.transfer_channel_4,R.string.transfer_channel_5,R.string.transfer_channel_6,R.string.transfer_channel_7)[channel]) + " · " +
            AppStrings.text(listOf(R.string.transfer_axis_0,R.string.transfer_axis_1,R.string.transfer_axis_2)[axis])
    }
    return AppStrings.text(when (this) {
        AdjustmentField.LOOK, AdjustmentField.HDR_LOOK -> R.string.transfer_field_look
        AdjustmentField.STRENGTH -> R.string.transfer_field_strength
        AdjustmentField.EXPOSURE -> R.string.transfer_field_exposure
        AdjustmentField.EXPOSURE_MODE -> R.string.transfer_field_exposure_mode
        AdjustmentField.CONTRAST -> R.string.transfer_field_contrast
        AdjustmentField.HIGHLIGHTS -> R.string.transfer_field_highlights
        AdjustmentField.SHADOWS -> R.string.transfer_field_shadows
        AdjustmentField.S_CURVE -> R.string.transfer_field_s_curve
        AdjustmentField.CURVE -> R.string.transfer_field_curve
        AdjustmentField.CURVE_APPLY_TO_LUMINOSITY -> R.string.curve_luminosity_only
        AdjustmentField.CURVE_PARAMETRIC -> R.string.curve_parametric_mode
        AdjustmentField.WHITE_BALANCE_MODE -> R.string.transfer_field_white_balance_mode
        AdjustmentField.TEMPERATURE, AdjustmentField.HDR_TEMPERATURE -> R.string.transfer_field_temperature
        AdjustmentField.TINT, AdjustmentField.HDR_TINT -> R.string.transfer_field_tint
        AdjustmentField.HDR_PEAK_LIMIT -> R.string.hdr_peak_limit
        AdjustmentField.HDR_SDR_EXPOSURE -> R.string.hdr_sdr_exposure
        AdjustmentField.HDR_SDR_CONTRAST -> R.string.hdr_sdr_contrast
        AdjustmentField.HDR_SDR_SATURATION -> R.string.hdr_sdr_saturation
        AdjustmentField.BLACK_POINT -> R.string.black_point
        AdjustmentField.WHITE_POINT -> R.string.white_point
        AdjustmentField.VIBRANCE -> R.string.vibrance
        AdjustmentField.CLARITY -> R.string.clarity
        AdjustmentField.DEHAZE -> R.string.dehaze
        AdjustmentField.TEXTURE -> R.string.texture
        AdjustmentField.CALIBRATION_SHADOW_TINT -> R.string.calibration_shadow_tint
        AdjustmentField.CALIBRATION_RED_HUE -> R.string.calibration_red_hue
        AdjustmentField.CALIBRATION_RED_SATURATION -> R.string.calibration_red_saturation
        AdjustmentField.CALIBRATION_GREEN_HUE -> R.string.calibration_green_hue
        AdjustmentField.CALIBRATION_GREEN_SATURATION -> R.string.calibration_green_saturation
        AdjustmentField.CALIBRATION_BLUE_HUE -> R.string.calibration_blue_hue
        AdjustmentField.CALIBRATION_BLUE_SATURATION -> R.string.calibration_blue_saturation
        AdjustmentField.POINT_COLOR -> R.string.point_color
        AdjustmentField.SELECTIVE_COLOR -> R.string.selective_color
        AdjustmentField.BW_ENABLED -> R.string.bw_enable_toggle
        AdjustmentField.BW_MIXER -> R.string.bw_mixer
        AdjustmentField.SATURATION -> R.string.transfer_field_saturation
        AdjustmentField.VIGNETTE_AMOUNT -> R.string.transfer_field_vignette_amount
        AdjustmentField.VIGNETTE_MIDPOINT -> R.string.transfer_field_vignette_midpoint
        AdjustmentField.VIGNETTE_ROUNDNESS -> R.string.transfer_field_vignette_roundness
        AdjustmentField.VIGNETTE_FEATHER -> R.string.transfer_field_vignette_feather
        AdjustmentField.VIGNETTE_HIGHLIGHTS -> R.string.transfer_field_vignette_highlights
        AdjustmentField.GRAIN_AMOUNT -> R.string.transfer_field_grain_amount
        AdjustmentField.GRAIN_SIZE -> R.string.transfer_field_grain_size
        AdjustmentField.GRAIN_ROUGHNESS -> R.string.transfer_field_grain_roughness
        AdjustmentField.GRAIN_TONE_CURVE -> R.string.grain_tone_curve
        AdjustmentField.GRAIN_FORMAT_PRESET -> R.string.grain_format_preset
        AdjustmentField.HALATION_AMOUNT -> R.string.halation_amount
        AdjustmentField.HALATION_THRESHOLD -> R.string.halation_threshold
        AdjustmentField.HALATION_RADIUS -> R.string.halation_radius
        AdjustmentField.HALATION_HUE -> R.string.halation_hue
        AdjustmentField.BLOOM_AMOUNT -> R.string.bloom_amount
        AdjustmentField.BLOOM_THRESHOLD -> R.string.bloom_threshold
        AdjustmentField.BLOOM_RADIUS -> R.string.bloom_radius
        AdjustmentField.SHARPENING -> R.string.transfer_field_sharpening
        AdjustmentField.SHARPENING_LUMINANCE_V2 -> R.string.sharpening_luminance_v2
        AdjustmentField.SHARPENING_RADIUS -> R.string.sharpening_radius
        AdjustmentField.SHARPENING_DETAIL -> R.string.sharpening_detail
        AdjustmentField.SHARPENING_MASKING -> R.string.sharpening_masking
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
        AdjustmentField.LENS_VIGNETTING -> R.string.lens_vignetting
        AdjustmentField.LENS_AUTO_CROP -> R.string.transfer_field_lens_auto_crop
        AdjustmentField.LENS_PROFILE -> R.string.transfer_field_lens_profile
        AdjustmentField.LENS_DEFRINGE_PURPLE_AMOUNT -> R.string.lens_defringe_purple_amount
        AdjustmentField.LENS_DEFRINGE_PURPLE_HUE -> R.string.lens_defringe_purple_hue
        AdjustmentField.LENS_DEFRINGE_GREEN_AMOUNT -> R.string.lens_defringe_green_amount
        AdjustmentField.LENS_DEFRINGE_GREEN_HUE -> R.string.lens_defringe_green_hue
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
