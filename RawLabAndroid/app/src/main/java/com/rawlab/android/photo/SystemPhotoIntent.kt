package com.rawlab.android.photo

internal object SystemPhotoIntent {
    fun uris(action: String?, data: String? = null, streams: List<String> = emptyList(),
             clip: List<String> = emptyList()): List<String> {
        val candidates = when (action) {
            "android.intent.action.VIEW" -> listOfNotNull(data)
            "android.intent.action.SEND" -> (streams.ifEmpty { clip }).take(1)
            "android.intent.action.SEND_MULTIPLE" -> streams + clip
            else -> emptyList()
        }
        return candidates.filter { it.startsWith("content://") || it.startsWith("file:///") }.distinct()
    }
}
