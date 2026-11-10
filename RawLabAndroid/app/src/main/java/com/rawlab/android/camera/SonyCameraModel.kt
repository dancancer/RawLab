package com.rawlab.android.camera

import java.util.Locale

internal enum class SonyCameraModel(val model: String, val firmware: String) {
    A7CII("ILCE-7CM2", "2.00"), ZVE10("ZV-E10", "2.02"), UNKNOWN("", "");

    val displayName: String get() = when (this) {
        A7CII -> "α7C II"
        ZVE10 -> model
        UNKNOWN -> "Sony camera"
    }
    val profileId: String get() = if (this == UNKNOWN) "unknown" else "$model/$firmware"
    val verified: Boolean get() = this != UNKNOWN

    companion object {
        fun fromAdvertisement(name: String): SonyCameraModel = entries.firstOrNull {
            it != UNKNOWN && (name == it.model || name.startsWith("${it.model}.") || name.startsWith("${it.model} "))
        } ?: UNKNOWN

        fun fromIdentity(model: String, firmware: String): SonyCameraModel = entries.firstOrNull {
            it != UNKNOWN && it.model == model && it.firmware == firmware
        } ?: UNKNOWN

        /** 用户选择当前 Wi-Fi 后按真实 BSSID 隔离任务；相机身份和能力由协议握手确认。 */
        fun networkIdentity(ssid: String?, bssid: String?): String? {
            val name = ssid?.removeSurrounding("\"") ?: return null
            if (name.isBlank() || name == "<unknown ssid>") return null
            val address = bssid?.lowercase(Locale.ROOT) ?: return null
            if (!Regex("(?:[0-9a-f]{2}:){5}[0-9a-f]{2}").matches(address) ||
                address == "02:00:00:00:00:00" || address == "00:00:00:00:00:00") return null
            return "sony-wifi:$address"
        }
    }
}
