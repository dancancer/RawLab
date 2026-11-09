package com.rawlab.android.engine

import com.rawlab.android.R
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.settings.HDRCameraProfile
import java.io.File
import java.io.IOException

class HDRProcessingException(val status: Int, val reason: Int, val field: Int) : IOException(message(status, reason)) {
    companion object {
        private fun message(status: Int, reason: Int): String = when(reason) {
            2,3,4 -> AppStrings.text(R.string.hdr_unsupported)
            10 -> AppStrings.text(R.string.hdr_memory)
            11 -> AppStrings.text(R.string.hdr_output_failed)
            13 -> AppStrings.text(R.string.hdr_processing_cpu)
            16 -> AppStrings.text(R.string.hdr_not_hdr)
            18 -> AppStrings.text(R.string.collection_look_unavailable)
            19 -> AppStrings.text(R.string.hdr_camera_development_unavailable)
            21 -> AppStrings.text(if (status == 3) R.string.hdr_camera_profile_missing else R.string.hdr_camera_profile_invalid)
            else -> AppStrings.format(R.string.hdr_processing_failed,reason)
        }
    }
}

internal fun HDRCameraProfile.requireAsset(directory: File?): File =
    directory?.let { asset(it) }?.takeIf { it.isFile } ?: throw HDRProcessingException(3, 21, 11)
