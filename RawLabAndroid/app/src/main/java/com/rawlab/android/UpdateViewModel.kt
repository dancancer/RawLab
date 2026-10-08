package com.rawlab.android

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

enum class UpdateStatus { UNCHECKED, CHECKING, CURRENT, AVAILABLE, FAILED }
data class UpdateState(val version: String, val automatic: Boolean = true,
                       val status: UpdateStatus = UpdateStatus.UNCHECKED,
                       val available: UpdateRelease? = null)

class UpdateViewModel @JvmOverloads constructor(
    application: Application,
    private val fetch: suspend () -> String = { fetchRelease() },
    private val preferences: SharedPreferences = application.getSharedPreferences("updates", Context.MODE_PRIVATE),
) : AndroidViewModel(application) {
    private val currentVersion = application.packageManager.getPackageInfo(application.packageName, 0).versionName ?: "unknown"
    private val mutableState = MutableStateFlow(UpdateState(currentVersion, preferences.getBoolean("automatic", true)))
    val state = mutableState.asStateFlow()

    init {
        val cached = preferences.getString("cachedRelease", null)?.let { runCatching { parseRelease(it, currentVersion) }.getOrNull() }
        if (cached != null) mutableState.value = mutableState.value.copy(available = cached, status = UpdateStatus.AVAILABLE)
    }

    fun setAutomatic(enabled: Boolean) {
        preferences.edit().putBoolean("automatic", enabled).apply()
        mutableState.value = mutableState.value.copy(automatic = enabled)
    }

    fun check(manual: Boolean) {
        if (state.value.status == UpdateStatus.CHECKING || !UpdateRelease.shouldCheck(manual,
                state.value.automatic, preferences.getLong("lastAttempt", 0), System.currentTimeMillis() / 1000)) return
        mutableState.value = mutableState.value.copy(status = UpdateStatus.CHECKING)
        preferences.edit().putLong("lastAttempt", System.currentTimeMillis() / 1000).apply()
        viewModelScope.launch {
            try {
                val body = withContext(Dispatchers.IO) { fetch() }
                val release = parseRelease(body, currentVersion)
                preferences.edit().putString("cachedRelease", body).apply()
                mutableState.value = mutableState.value.copy(available = release,
                    status = if (release == null) UpdateStatus.CURRENT else UpdateStatus.AVAILABLE)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                mutableState.value = mutableState.value.copy(status = UpdateStatus.FAILED)
            }
        }
    }

    companion object {
        internal fun parseRelease(body: String, current: String): UpdateRelease? {
            val json = JSONObject(body)
            val assets = json.getJSONArray("assets")
            return UpdateRelease.select(json.getString("tag_name"), json.getBoolean("draft"), json.getBoolean("prerelease"),
                if (json.isNull("body")) "" else json.getString("body"),
                (0 until assets.length()).map { assets.getJSONObject(it).getString("name") }, current)
        }

        private fun fetchRelease(): String {
            val connection = URL(UpdateRelease.ENDPOINT).openConnection() as HttpURLConnection
            try {
                connection.connectTimeout = 15000
                connection.readTimeout = 15000
                connection.useCaches = false
                connection.setRequestProperty("Accept", "application/vnd.github+json")
                connection.setRequestProperty("User-Agent", "RawLab-Update-Check")
                check(connection.responseCode == 200) { "Release request failed" }
                return connection.inputStream.bufferedReader().use { it.readText() }
            } finally { connection.disconnect() }
        }
    }
}
