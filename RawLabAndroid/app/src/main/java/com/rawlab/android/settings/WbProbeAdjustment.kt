package com.rawlab.android.settings

enum class WbProbeNotice { AVAILABLE, OVEREXPOSED, OUTSIDE, UNAVAILABLE, STALE }

data class WbProbeState(
    val enabled: Boolean = false,
    val x: Float? = null,
    val y: Float? = null,
    val waiting: Boolean = false,
    val notice: WbProbeNotice? = null,
)
