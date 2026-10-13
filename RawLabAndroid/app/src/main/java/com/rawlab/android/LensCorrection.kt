package com.rawlab.android

data class LensCandidate(val id: String, val maker: String, val model: String,
    val hasDistortion: Boolean, val hasTca: Boolean, val isMatch: Boolean) {
    val title: String get() = if (model.contains(maker, ignoreCase = true)) model else "$maker $model"
}

data class LensInfo(val state: Int, val detectedLens: String, val selectedLens: String,
    val appliedDistortion: Boolean, val appliedTca: Boolean, val cropScale: Float,
    val candidates: List<LensCandidate>) {
    /** Native status values are stable; keep them as integers at this boundary. */
    val message: String get() = when (state) {
        STATE_OFF -> AppStrings.text(R.string.lens_off)
        STATE_APPLIED -> if (appliedDistortion || appliedTca) {
            val corrections = listOfNotNull(
                AppStrings.text(R.string.lens_distortion_short).takeIf { appliedDistortion },
                AppStrings.text(R.string.lens_tca).takeIf { appliedTca },
            ).joinToString(" / ")
            AppStrings.format(R.string.lens_corrected, corrections)
        } else AppStrings.text(R.string.lens_matched)
        STATE_DATABASE_UNAVAILABLE -> AppStrings.text(R.string.lens_database_unavailable)
        STATE_CAMERA_INFO_MISSING -> AppStrings.text(R.string.lens_camera_info_missing)
        STATE_NO_MATCH -> AppStrings.text(R.string.lens_manual_required)
        STATE_AMBIGUOUS -> AppStrings.text(R.string.lens_ambiguous)
        STATE_NO_CALIBRATION -> AppStrings.text(R.string.lens_no_calibration)
        STATE_FOCAL_LENGTH_MISSING -> AppStrings.text(R.string.lens_focal_length_missing)
        STATE_EMBEDDED_GEOMETRY -> AppStrings.text(R.string.lens_embedded_geometry)
        STATE_INPUT_UNSUPPORTED -> AppStrings.text(R.string.lens_input_unsupported)
        else -> AppStrings.text(R.string.lens_manual_required)
    }

    val cropPercent: Float?
        get() = cropScale.takeIf { it.isFinite() && it > 1.0001f }
            ?.let { (1f - 1f / it) * 100f }

    companion object {
        const val STATE_OFF = 0
        const val STATE_APPLIED = 1
        const val STATE_DATABASE_UNAVAILABLE = 2
        const val STATE_CAMERA_INFO_MISSING = 3
        const val STATE_NO_MATCH = 4
        const val STATE_AMBIGUOUS = 5
        const val STATE_NO_CALIBRATION = 6
        const val STATE_FOCAL_LENGTH_MISSING = 7
        const val STATE_EMBEDDED_GEOMETRY = 8
        const val STATE_INPUT_UNSUPPORTED = 9
    }
}
