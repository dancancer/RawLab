package com.rawlab.android.camera

import java.nio.charset.StandardCharsets
import java.util.Locale

internal data class CameraWifiQrCredentials(
    val ssid: String,
    val password: String,
    val model: String? = null,
    val format: Format,
) {
    enum class Format { SONY_W01, STANDARD_WIFI }
}

/**
 * Parses camera Wi-Fi QR code payloads without persisting or logging credentials.
 *
 * Supported formats:
 * - Sony Imaging Edge / Smartphone Connection QR:
 *   `W01:S:<suffix-or-ssid>;P:<password>;C:<model>;M:<mac>;`
 * - Standard Wi-Fi QR:
 *   `WIFI:T:WPA;S:<ssid>;P:<password>;;`
 */
internal object CameraWifiQrCode {
    private const val MAX_PAYLOAD_LENGTH = 1024
    private val ALLOWED_WIFI_SECURITY = setOf("", "WPA", "WPA2", "WPA3", "SAE", "WPA/WPA2", "WPA2/WPA3")

    fun parse(raw: String): CameraWifiQrCredentials? {
        val trimmed = raw.trim()
        if (trimmed.isEmpty() || trimmed.length > MAX_PAYLOAD_LENGTH) return null
        val upper = trimmed.uppercase(Locale.ROOT)
        return when {
            upper.startsWith("W01:") -> parseSonyW01(trimmed.substring(4))
            upper.startsWith("WIFI:") -> parseStandardWifi(trimmed.substring(5))
            else -> null
        }
    }

    /** Redacted structural summary safe for diagnostics (contains zero SSID/password/MAC bytes). */
    fun safeSummary(raw: String): String {
        val trimmed = raw.trim()
        val upper = trimmed.uppercase(Locale.ROOT)
        val scheme = when {
            upper.startsWith("W01:") -> "W01"
            upper.startsWith("WIFI:") -> "WIFI"
            else -> "other"
        }
        val body = when (scheme) {
            "W01" -> trimmed.substring(4)
            "WIFI" -> trimmed.substring(5)
            else -> ""
        }
        val keys = if (body.isEmpty()) {
            ""
        } else {
            splitEscapedFields(body, unescapeColons = scheme == "WIFI")
                .keys
                .sorted()
                .joinToString(",")
        }
        val parsed = parse(trimmed)
        return buildString {
            append("scheme=").append(scheme)
            append(",len=").append(trimmed.length)
            if (keys.isNotEmpty()) append(",keys=").append(keys)
            append(",valid=").append(parsed != null)
            if (parsed != null) {
                append(",ssidLen=").append(parsed.ssid.toByteArray(StandardCharsets.UTF_8).size)
                append(",passLen=").append(parsed.password.length)
                append(",knownModel=").append(
                    parsed.model?.let(SonyCameraModel::fromAdvertisement)?.name ?: SonyCameraModel.UNKNOWN.name,
                )
            }
        }
    }

    private fun parseSonyW01(body: String): CameraWifiQrCredentials? {
        val fields = splitEscapedFields(body, unescapeColons = false)
        val rawSsid = fields["S"]?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val password = fields["P"] ?: return null
        val modelField = fields["C"]?.trim()?.takeIf { it.isNotEmpty() }
        val ssid = if (!rawSsid.startsWith("DIRECT-") && modelField != null) {
            "DIRECT-$rawSsid:$modelField"
        } else {
            rawSsid
        }
        if (!isValidSsid(ssid) || !isValidPassphrase(password)) return null
        val model = modelField ?: extractDirectModel(ssid)
        return CameraWifiQrCredentials(
            ssid = ssid,
            password = password,
            model = model,
            format = CameraWifiQrCredentials.Format.SONY_W01,
        )
    }

    private fun parseStandardWifi(body: String): CameraWifiQrCredentials? {
        val fields = splitEscapedFields(body, unescapeColons = true)
        val security = fields["T"]?.trim()?.uppercase(Locale.ROOT).orEmpty()
        if (security !in ALLOWED_WIFI_SECURITY) return null
        val ssid = fields["S"]?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val password = fields["P"] ?: return null
        if (!isValidSsid(ssid) || !isValidPassphrase(password)) return null
        return CameraWifiQrCredentials(
            ssid = ssid,
            password = password,
            model = extractDirectModel(ssid),
            format = CameraWifiQrCredentials.Format.STANDARD_WIFI,
        )
    }

    private fun splitEscapedFields(body: String, unescapeColons: Boolean): Map<String, String> {
        val result = LinkedHashMap<String, String>()
        val token = StringBuilder()
        var index = 0
        fun flushToken() {
            if (token.isEmpty()) return
            val colon = token.indexOf(':')
            if (colon > 0) {
                val key = token.substring(0, colon).trim().uppercase(Locale.ROOT)
                val rawValue = token.substring(colon + 1)
                val value = unescapeValue(rawValue, unescapeColons)
                if (key.isNotEmpty() && key !in result) {
                    result[key] = value
                }
            }
            token.setLength(0)
        }
        while (index < body.length) {
            val ch = body[index]
            if (ch == '\\' && index + 1 < body.length) {
                token.append(ch).append(body[index + 1])
                index += 2
                continue
            }
            if (ch == ';') {
                flushToken()
                index++
                continue
            }
            token.append(ch)
            index++
        }
        flushToken()
        return result
    }

    private fun unescapeValue(raw: String, unescapeColons: Boolean): String {
        val out = StringBuilder(raw.length)
        var index = 0
        while (index < raw.length) {
            val ch = raw[index]
            if (ch == '\\' && index + 1 < raw.length) {
                val next = raw[index + 1]
                val shouldUnescape = next == '\\' || next == ';' ||
                    (unescapeColons && (next == ':' || next == ',' || next == '"'))
                if (shouldUnescape) {
                    out.append(next)
                    index += 2
                    continue
                }
            }
            out.append(ch)
            index++
        }
        return out.toString()
    }

    internal fun isValidSsid(ssid: String): Boolean {
        val bytes = ssid.toByteArray(StandardCharsets.UTF_8)
        if (bytes.isEmpty() || bytes.size > 32) return false
        return ssid.none { it.code < 32 || it.code == 127 }
    }

    internal fun isValidPassphrase(password: String): Boolean {
        if (password.length !in 8..63) return false
        return password.all { it.code in 32..126 }
    }

    private fun extractDirectModel(ssid: String): String? {
        if (!ssid.startsWith("DIRECT-")) return null
        val colon = ssid.indexOf(':')
        if (colon < 0 || colon + 1 >= ssid.length) return null
        return ssid.substring(colon + 1).trim().takeIf { it.isNotEmpty() }
    }
}
