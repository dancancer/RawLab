package com.rawlab.android.about

data class UpdateRelease(val version: String, val notes: String, val url: String) {
    companion object {
        const val REPOSITORY = "https://github.com/dancancer/RawLab"
        const val AUTHOR = "https://www.xiaohongshu.com/user/profile/6474b1560000000010037c8e"
        const val ENDPOINT = "https://api.github.com/repos/dancancer/RawLab/releases/latest"

        fun select(tag: String, draft: Boolean, preview: Boolean, notes: String,
                   assets: List<String>, current: String): UpdateRelease? {
            if (draft || preview) return null
            val latest = numbersOrNull(tag) ?: return null
            val installed = numbersOrNull(current) ?: return null
            val difference = latest.zip(installed).firstOrNull { (a, b) -> a != b }
            if (difference == null || difference.first < difference.second) return null
            if (assets.none { it.startsWith("RawLab-Android-") && it.endsWith(".apk") }) return null
            return UpdateRelease(latest.joinToString("."), notes, "${REPOSITORY}/releases/tag/${tag}")
        }

        private fun numbersOrNull(text: String): List<Int>? {
            if (!Regex("v?[0-9]+\\.[0-9]+(?:\\.[0-9]+)?").matches(text)) return null
            val parts = text.removePrefix("v").split('.').map { it.toIntOrNull() ?: return null }
            return if (parts.size == 2) parts + 0 else parts
        }

        fun shouldCheck(manual: Boolean, enabled: Boolean, last: Long, now: Long) =
            manual || (enabled && (last == 0L || now < last || now - last >= 86400))
    }
}
