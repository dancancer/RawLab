package com.rawlab.android.engine

import com.rawlab.android.R
import com.rawlab.android.i18n.AppStrings
import java.io.IOException

class HDRProcessingException(val status: Int, val reason: Int, val field: Int) : IOException(message(reason)) {
    companion object {
        private fun message(reason: Int): String = when(reason) {
            2,3,4 -> AppStrings.text(R.string.hdr_unsupported)
            10 -> AppStrings.text(R.string.hdr_memory)
            11 -> AppStrings.text(R.string.hdr_output_failed)
            13 -> AppStrings.text(R.string.hdr_processing_cpu)
            16 -> AppStrings.text(R.string.hdr_not_hdr)
            else -> AppStrings.format(R.string.hdr_processing_failed,reason)
        }
    }
}
