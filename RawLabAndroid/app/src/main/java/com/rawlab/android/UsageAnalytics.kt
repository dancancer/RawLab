package com.rawlab.android

import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class UsagePlatform(val value: String) { Android("android") }

enum class UsageFilmKind(val value: String) { None("none"), BuiltIn("built_in"), Custom("custom") }

enum class UsageBatchOutcome(val value: String) { Completed("completed"), Partial("partial"), Cancelled("cancelled"), Interrupted("interrupted") }

sealed interface UsageEvent {
    data object AppStarted : UsageEvent
    data object PhotoImported : UsageEvent
    data class FilmSelected(val kind: UsageFilmKind) : UsageEvent
    data object ExportCompleted : UsageEvent
    data class BatchExportCompleted(val succeeded: Int, val failed: Int, val outcome: UsageBatchOutcome) : UsageEvent

    fun toRecord(platform: UsagePlatform = UsagePlatform.Android): UsageRecord {
        val properties = linkedMapOf("schema_version" to "1", "platform" to platform.value)
        return when (this) {
            AppStarted -> UsageRecord("app_started", 1, properties)
            PhotoImported -> UsageRecord("photo_imported", 1, properties)
            is FilmSelected -> UsageRecord("film_selected", 1, properties + ("kind" to kind.value))
            ExportCompleted -> UsageRecord("export_completed", 1, properties)
            is BatchExportCompleted -> UsageRecord("batch_export_completed", bounded(succeeded), properties + mapOf(
                "outcome" to outcome.value,
                "succeeded_count" to bounded(succeeded).toString(),
                "failed_count" to bounded(failed).toString(),
            ))
        }
    }

    companion object {
        private const val MAX_COUNT = 100_000
        private fun bounded(value: Int): Int = value.coerceIn(0, MAX_COUNT)
    }
}

data class UsageRecord(
    val name: String,
    val value: Int,
    val properties: Map<String, String>,
    val group: String = "usage",
)

interface UsageConsentStore {
    fun load(): Boolean
    fun save(enabled: Boolean)
}

class SharedPreferencesUsageConsentStore(private val preferences: SharedPreferences) : UsageConsentStore {
    override fun load(): Boolean = preferences.getBoolean(KEY_ENABLED, false)
    override fun save(enabled: Boolean) {
        check(preferences.edit().putBoolean(KEY_ENABLED, enabled).commit()) { "Unable to save usage consent" }
    }

    private companion object { const val KEY_ENABLED = "enabled" }
}

interface UsageAnalyticsTransport {
    val isAvailable: Boolean
    fun start()
    fun record(record: UsageRecord)
    fun stop()
    fun setIssueListener(listener: (UsageIssue) -> Unit) = Unit
}

object UnavailableUsageTransport : UsageAnalyticsTransport {
    override val isAvailable = false
    override fun start() = Unit
    override fun record(record: UsageRecord) = Unit
    override fun stop() = Unit
}

enum class UsageIssue {
    STORAGE_FAILED,
    START_FAILED,
    RECORD_FAILED,
    STOP_FAILED,
    CLEANUP_FAILED,
    RESTART_REQUIRED,
}

data class UsageAnalyticsState(
    val available: Boolean,
    val enabled: Boolean,
    val issue: UsageIssue? = null,
)

class UsageAnalytics(
    private val store: UsageConsentStore,
    private val transport: UsageAnalyticsTransport,
    private val platform: UsagePlatform = UsagePlatform.Android,
) {
    private val mutableState = MutableStateFlow(UsageAnalyticsState(available = transport.isAvailable, enabled = false))
    val state: StateFlow<UsageAnalyticsState> = mutableState.asStateFlow()

    private var sessionBegan = false
    private var active = false
    private var launchRecorded = false

    init {
        transport.setIssueListener(::handleTransportIssue)
        val stored = runCatching { store.load() }.getOrElse {
            mutableState.value = mutableState.value.copy(issue = UsageIssue.STORAGE_FAILED)
            false
        }
        mutableState.value = mutableState.value.copy(enabled = stored)
    }

    fun beginSession() {
        if (sessionBegan) return
        sessionBegan = true
        startIfAllowed()
    }

    fun setEnabled(enabled: Boolean): Boolean {
        if (enabled && !transport.isAvailable) return false
        if (!enabled) {
            mutableState.value = mutableState.value.copy(enabled = false, issue = null)
            stop()
            return try {
                store.save(false)
                true
            } catch (_: Throwable) {
                mutableState.value = mutableState.value.copy(issue = UsageIssue.STORAGE_FAILED)
                false
            }
        }
        return try {
            store.save(true)
            mutableState.value = mutableState.value.copy(enabled = true, issue = null)
            startIfAllowed()
            state.value.enabled
        } catch (_: Throwable) {
            mutableState.value = mutableState.value.copy(enabled = false, issue = UsageIssue.STORAGE_FAILED)
            stop()
            false
        }
    }

    fun record(event: UsageEvent) {
        if (!state.value.enabled || !active) return
        try {
            transport.record(event.toRecord(platform))
        } catch (_: Throwable) {
            mutableState.value = mutableState.value.copy(issue = UsageIssue.RECORD_FAILED)
        }
    }

    fun endSession() = stop()

    private fun handleTransportIssue(issue: UsageIssue) {
        when (issue) {
            UsageIssue.START_FAILED -> {
                active = false
                mutableState.value = mutableState.value.copy(enabled = false, issue = issue)
                runCatching { store.save(false) }
            }
            UsageIssue.RECORD_FAILED -> {
                mutableState.value = mutableState.value.copy(issue = issue)
            }
            UsageIssue.STORAGE_FAILED -> {
                mutableState.value = mutableState.value.copy(issue = issue)
            }
            UsageIssue.STOP_FAILED,
            UsageIssue.CLEANUP_FAILED,
            UsageIssue.RESTART_REQUIRED -> {
                active = false
                mutableState.value = mutableState.value.copy(
                    available = false,
                    enabled = false,
                    issue = issue,
                )
                runCatching { store.save(false) }
            }
        }
    }

    private fun startIfAllowed() {
        if (!sessionBegan || !state.value.enabled || !transport.isAvailable || active) return
        try {
            transport.start()
            active = true
            if (!launchRecorded) {
                record(UsageEvent.AppStarted)
                launchRecorded = true
            }
        } catch (_: Throwable) {
            active = false
            mutableState.value = mutableState.value.copy(enabled = false, issue = UsageIssue.START_FAILED)
            runCatching { store.save(false) }
        }
    }

    private fun stop() {
        if (!active) return
        active = false
        runCatching { transport.stop() }
    }
}
