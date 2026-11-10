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

    /** 手动连接按实际热点隔离任务；热点身份变化时要求重新选片，不能接续旧相机任务。 */
    fun networkIdentity(ssid: String?, bssid: String?): String? {
        val name = ssid?.removeSurrounding("\"") ?: return null
        if (!name.startsWith("DIRECT-") || !name.endsWith(":$model")) return null
        val address = bssid?.lowercase(Locale.ROOT) ?: return null
        if (!Regex("(?:[0-9a-f]{2}:){5}[0-9a-f]{2}").matches(address) || address == "02:00:00:00:00:00" || address == "00:00:00:00:00:00") return null
        return "sony-wifi:$address"
    }

    companion object {
        private val unknownAdvertisement = Regex("(?:ILCE|DSC)-[A-Za-z0-9][A-Za-z0-9-]*(?:[. ].*)?|ZV-[0-9][A-Za-z0-9-]*(?:[. ].*)?")

        fun fromAdvertisement(name: String): SonyCameraModel? = entries.firstOrNull {
            it != UNKNOWN && (name == it.model || name.startsWith("${it.model}.") || name.startsWith("${it.model} "))
        } ?: UNKNOWN.takeIf { unknownAdvertisement.matches(name) }

        fun fromIdentity(model: String, firmware: String): SonyCameraModel = entries.firstOrNull {
            it != UNKNOWN && it.model == model && it.firmware == firmware
        } ?: UNKNOWN

        /** Sony 相机热点名称含机型后缀，但未知机型仍只绑定真实 BSSID，不据此宣称协议能力。 */
        fun networkIdentity(ssid: String?, bssid: String?): String? {
            val name = ssid?.removeSurrounding("\"") ?: return null
            if (!name.startsWith("DIRECT-")) return null
            val suffix = name.substringAfterLast(':', "")
            if (entries.none { it != UNKNOWN && it.model == suffix } && !unknownAdvertisement.matches(suffix)) return null
            val address = bssid?.lowercase(Locale.ROOT) ?: return null
            if (!Regex("(?:[0-9a-f]{2}:){5}[0-9a-f]{2}").matches(address) ||
                address == "02:00:00:00:00:00" || address == "00:00:00:00:00:00") return null
            return "sony-wifi:$address"
        }
    }
}
