package com.rawlab.android.camera

import java.time.LocalDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.ResolverStyle
import java.util.Locale

internal enum class CameraDirectoryGrouping { NONE, CAPTURE_DAY, CAPTURE_MONTH }

internal data class CameraCaptureDate(val localTime: LocalDateTime, val offset: ZoneOffset?) {
    val day: String get() = localTime.toLocalDate().toString()
    val month: String get() = day.substring(0, 7)
    val epochMillis: Long? get() = offset?.let { localTime.toInstant(it).toEpochMilli() }

    companion object {
        private val originalFormat = DateTimeFormatter.ofPattern("uuuu:MM:dd HH:mm:ss", Locale.ROOT)
            .withResolverStyle(ResolverStyle.STRICT)

        fun parse(original: String?, offset: String?): CameraCaptureDate? {
            val value = original?.trim() ?: return null
            if (!value.matches(Regex("[0-9]{4}:[0-9]{2}:[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}"))) return null
            val local = runCatching { LocalDateTime.parse(value, originalFormat) }.getOrNull() ?: return null
            if (local.year !in 1..9999) return null
            // 日期始终采用原片的当地字段；offset 只用于有明确时区时登记媒体时间。
            val zone = offset?.trim()?.takeIf { it.matches(Regex("[+-][0-9]{2}:[0-9]{2}")) }
                ?.let { runCatching { ZoneOffset.of(it) }.getOrNull() }
            return CameraCaptureDate(local, zone)
        }
    }
}

internal data class CameraImportDestination(
    val directory: String = "RawLab/Camera",
    val grouping: CameraDirectoryGrouping = CameraDirectoryGrouping.CAPTURE_DAY,
) {
    init {
        val parts = directory.split('/')
        require(directory.toByteArray(Charsets.UTF_8).size <= 512 && parts.all { part ->
            part.isNotBlank() && part == part.trim() && !part.startsWith('.') && !part.endsWith('.') &&
                part.toByteArray(Charsets.UTF_8).size <= 200 &&
                part.none { it.isISOControl() || it in "\\:*?\"<>|" }
        }) { "Invalid camera import directory" }
    }

    fun relativePath(capture: CameraCaptureDate?): String {
        val group = when (grouping) {
            CameraDirectoryGrouping.NONE -> null
            CameraDirectoryGrouping.CAPTURE_DAY -> capture?.day ?: "Unknown date"
            CameraDirectoryGrouping.CAPTURE_MONTH -> capture?.month ?: "Unknown date"
        }
        return "Pictures/$directory/" + (group?.let { "$it/" } ?: "")
    }
}
