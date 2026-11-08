package com.rawlab.android.editor

internal data class DurableSystemPhotoRequest(val id: String, val uris: List<String>)

/** 按外部请求分组保存 URI，避免同一原图的两个独立分享互相消费。 */
internal class SystemPhotoRequestQueue(
    pending: List<DurableSystemPhotoRequest> = emptyList(),
    processed: Set<String> = emptySet(),
) {
    private val pendingByID = linkedMapOf<String, MutableList<String>>()
    private val processedIDs = linkedSetOf<String>()

    init {
        pending.forEach { if (it.id.isNotBlank() && it.uris.isNotEmpty()) pendingByID[it.id] = it.uris.distinct().toMutableList() }
        processedIDs += processed
    }

    fun enqueue(id: String, uris: List<String>): Boolean {
        if (id.isBlank() || uris.isEmpty() || id in processedIDs || pendingByID.containsKey(id)) return false
        pendingByID[id] = uris.distinct().toMutableList()
        return true
    }

    fun uris(id: String): List<String> = pendingByID[id].orEmpty().toList()
    fun ids(): List<String> = pendingByID.keys.toList()
    fun replace(id: String, uris: List<String>): Boolean {
        if (!pendingByID.containsKey(id)) return false
        if (uris.isEmpty()) {
            pendingByID.remove(id)
            markProcessed(id)
        } else pendingByID[id] = uris.distinct().toMutableList()
        return true
    }

    fun consume(id: String): Boolean {
        if (pendingByID.remove(id) == null) return false
        markProcessed(id)
        return true
    }

    fun isProcessed(id: String): Boolean = id in processedIDs
    fun pending(): List<DurableSystemPhotoRequest> = pendingByID.map { DurableSystemPhotoRequest(it.key, it.value.toList()) }
    fun processed(): Set<String> = processedIDs.toSet()

    private fun markProcessed(id: String) {
        processedIDs += id
        while (processedIDs.size > 256) processedIDs.remove(processedIDs.first())
    }
}
