package com.rawlab.android

internal enum class ExportSizeChoice(val key: String, val longEdge: Int?) {
    ORIGINAL("original", null),
    EDGE_2048("2048", 2048),
    EDGE_3000("3000", 3000),
    EDGE_4096("4096", 4096),
    CUSTOM("custom", null),
    ;

    companion object {
        fun fromKey(key: String): ExportSizeChoice = entries.firstOrNull { it.key == key } ?: ORIGINAL
    }
}

internal object ExportSize {
    const val MIN_LONG_EDGE = 1
    const val MAX_LONG_EDGE = 65535

    fun isValid(longEdge: Int?): Boolean = longEdge == null || longEdge in MIN_LONG_EDGE..MAX_LONG_EDGE

    fun parseCustom(value: String): Int? = value.trim().toIntOrNull()
        ?.takeIf { it in MIN_LONG_EDGE..MAX_LONG_EDGE }

    fun parse(choice: ExportSizeChoice, custom: String): Int? = when (choice) {
        ExportSizeChoice.ORIGINAL -> null
        ExportSizeChoice.EDGE_2048, ExportSizeChoice.EDGE_3000, ExportSizeChoice.EDGE_4096 -> choice.longEdge
        ExportSizeChoice.CUSTOM -> parseCustom(custom)
    }
}
