package com.rawlab.android.editor

import android.content.SharedPreferences
import android.net.Uri
import com.rawlab.android.photo.PhotoStorage
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

data class SystemPhotoOpenRequest(
    val uris: List<Uri>,
    val id: UUID = UUID.randomUUID(),
    val externalRequestID: String? = null,
    val openAsCollection: Boolean = uris.size > 1,
)

private fun loadSystemPhotoRequestQueue(preferences: SharedPreferences): SystemPhotoRequestQueue {
    val pending = mutableListOf<DurableSystemPhotoRequest>()
    val processed = linkedSetOf<String>()
    runCatching {
        val values = JSONArray(preferences.getString("pending_requests", "[]"))
        for (index in 0 until values.length()) {
            val value = values.optJSONObject(index) ?: continue
            val id = value.optString("id").takeIf { it.isNotBlank() } ?: continue
            val uris = value.optJSONArray("uris")?.let { array ->
                List(array.length()) { array.getString(it) }.distinct()
            }.orEmpty()
            if (uris.isNotEmpty()) pending += DurableSystemPhotoRequest(id, uris)
        }
    }
    runCatching {
        val values = JSONArray(preferences.getString("processed_requests", "[]"))
        for (index in 0 until values.length()) processed += values.getString(index)
    }
    return SystemPhotoRequestQueue(pending, processed)
}

internal class EditorSystemPhotoStateHolder(
    private val storage: PhotoStorage,
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher,
    preferencesFactory: () -> SharedPreferences,
    private val onError: (Throwable) -> Unit,
    private val parseUri: (String) -> Uri = Uri::parse,
    private val retainUri: (Uri) -> Uri = { uri ->
        if (storage.isRetainedSystemPhoto(uri)) uri else storage.retainSystemPhoto(uri)
    },
) {
    private val importLock = Mutex()
    private val mutableRequests = MutableStateFlow<List<SystemPhotoOpenRequest>>(emptyList())
    val requests = mutableRequests.asStateFlow()
    private val queueLock = Any()
    private val preferences by lazy(LazyThreadSafetyMode.SYNCHRONIZED, preferencesFactory)
    private val queue by lazy(LazyThreadSafetyMode.SYNCHRONIZED) { loadSystemPhotoRequestQueue(preferences) }

    fun receive(uris: List<Uri>, requestID: String = UUID.randomUUID().toString()) {
        if (uris.isEmpty()) return
        val durableID = requestID.ifBlank { UUID.randomUUID().toString() }
        val accepted = synchronized(queueLock) {
            if (queue.isProcessed(durableID) || !queue.enqueue(durableID, uris.map(Uri::toString))) false
            else {
                saveQueueLocked()
                true
            }
        }
        if (accepted) importRequest(durableID)
    }

    fun restorePending() {
        scope.launch {
            val pending = withContext(ioDispatcher) { synchronized(queueLock) { queue.ids() } }
            pending.forEach(::importRequest)
        }
    }

    private fun importRequest(requestID: String) {
        scope.launch {
            importLock.withLock {
                val uris = synchronized(queueLock) {
                    queue.uris(requestID).map(parseUri)
                }
                if (uris.isEmpty()) return@withLock
                val (retained, errors) = withContext(ioDispatcher) {
                    val results = uris.distinct().map { uri ->
                        runCatching { retainUri(uri) }
                    }
                    results.mapNotNull { it.getOrNull() }.distinct() to results.mapNotNull { it.exceptionOrNull() }
                }
                synchronized(queueLock) {
                    queue.replace(requestID, retained.map(Uri::toString))
                    saveQueueLocked()
                }
                if (retained.isNotEmpty()) {
                    mutableRequests.value += SystemPhotoOpenRequest(
                        retained,
                        externalRequestID = requestID,
                        openAsCollection = uris.size > 1,
                    )
                }
                if (errors.isNotEmpty()) onError(errors.first())
            }
        }
    }

    fun consume(request: SystemPhotoOpenRequest) {
        mutableRequests.value = mutableRequests.value.filterNot { it.id == request.id }
        request.externalRequestID?.let { requestID ->
            synchronized(queueLock) {
                queue.consume(requestID)
                saveQueueLocked()
            }
        }
    }

    private fun saveQueueLocked() {
        val pending = JSONArray().apply {
            queue.pending().forEach { request ->
                val uris = JSONArray().apply { request.uris.forEach(::put) }
                put(JSONObject().put("id", request.id).put("uris", uris))
            }
        }
        val processed = JSONArray().apply { queue.processed().forEach(::put) }
        preferences.edit()
            .putString("pending_requests", pending.toString())
            .putString("processed_requests", processed.toString())
            .apply()
    }
}
