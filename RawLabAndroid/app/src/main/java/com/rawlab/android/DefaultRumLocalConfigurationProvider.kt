package com.rawlab.android

import android.content.Context

object RumLocalConfigurationProvider {
    // The default build has no operator-verified collector policy.
    fun load(context: Context): RumLocalConfiguration? = null
}
