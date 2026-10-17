package com.rawlab.android

import android.content.SharedPreferences
import androidx.annotation.StringRes
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

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

// ============================================================================
//  本机存储：同意值与安装标识，同在一个 SharedPreferences 文件
//  （正式 usage_analytics；本地验证构建用独立文件，见 BuildConfig.USAGE_PREFERENCES）
// ============================================================================

interface UsageConsentStore {
    fun load(): Boolean
    fun save(enabled: Boolean)
}

/** 没存过选择 → defaultEnabled；存为关闭 → 关闭；类型损坏读不出 → 抛出，调用方按关闭处理并提示 */
class SharedPreferencesUsageConsentStore(
    private val preferences: SharedPreferences,
    private val defaultEnabled: Boolean = true,
) : UsageConsentStore {
    override fun load(): Boolean = preferences.getBoolean(KEY_ENABLED, defaultEnabled)
    override fun save(enabled: Boolean) {
        check(preferences.edit().putBoolean(KEY_ENABLED, enabled).commit()) { "Unable to save usage consent" }
    }

    private companion object { const val KEY_ENABLED = "enabled" }
}

/** 统计活跃设备数用的安装标识：应用自己随机生成，不读取任何硬件编号 */
interface UsageInstallId {
    /** 已有则沿用；没有或不是 UUID v4 就生成新的并保存 */
    fun obtain(): String
    fun delete()
}

class SharedPreferencesUsageInstallId(private val preferences: SharedPreferences) : UsageInstallId {
    override fun obtain(): String = preferences.getString(KEY_INSTALL_ID, null)?.takeIf(::isVersion4) ?: create()

    override fun delete() {
        check(preferences.edit().remove(KEY_INSTALL_ID).commit()) { "Unable to delete the install ID" }
    }

    private fun create(): String = UUID.randomUUID().toString().also { id ->
        check(preferences.edit().putString(KEY_INSTALL_ID, id).commit()) { "Unable to save the install ID" }
    }

    private fun isVersion4(value: String): Boolean = runCatching { UUID.fromString(value).version() == 4 }.getOrDefault(false)

    private companion object { const val KEY_INSTALL_ID = "install_id" }
}

// ============================================================================
//  传输层：带 SDK 的构建是 RumUsageAnalyticsTransport，其余是 UnavailableUsageTransport
// ============================================================================

interface UsageAnalyticsTransport {
    val isAvailable: Boolean
    fun start(installId: String)
    fun record(record: UsageRecord)
    fun stop()
    fun setIssueListener(listener: (UsageIssue) -> Unit) = Unit
}

object UnavailableUsageTransport : UsageAnalyticsTransport {
    override val isAvailable = false
    override fun start(installId: String) = Unit
    override fun record(record: UsageRecord) = Unit
    override fun stop() = Unit
}

/** disablesProcess：本进程的统计从此不可用；只是标记，绝不改写用户的同意值 */
enum class UsageIssue(@StringRes val message: Int, val disablesProcess: Boolean) {
    STORAGE_FAILED(R.string.usage_storage_failed, false),
    START_FAILED(R.string.usage_start_failed, true),
    RECORD_FAILED(R.string.usage_record_failed, false),
    STOP_FAILED(R.string.usage_stop_failed, true),
    CLEANUP_FAILED(R.string.usage_cleanup_failed, true),
    RESTART_REQUIRED(R.string.usage_restart_required, true),
}

/** enabled 是用户的同意值；available 是本进程能否真正统计，两者互不改写 */
data class UsageAnalyticsState(
    val available: Boolean,
    val enabled: Boolean,
    val issue: UsageIssue? = null,
)

// ============================================================================
//  同意与生命周期
//  - 开启且可用时，会话开始即启动一次传输层，并只记一次 app_started
//  - 关闭：停止传输、保存关闭、删除安装标识；重新开启时生成新的安装标识
//  - 故障只把本进程标为不可用，不写入同意值：一次偶发故障不该永久关掉统计
// ============================================================================

class UsageAnalytics(
    private val store: UsageConsentStore,
    private val installId: UsageInstallId,
    private val transport: UsageAnalyticsTransport,
    private val platform: UsagePlatform = UsagePlatform.Android,
) {
    private val mutableState = MutableStateFlow(UsageAnalyticsState(available = transport.isAvailable, enabled = false))
    val state: StateFlow<UsageAnalyticsState> = mutableState.asStateFlow()

    private var sessionBegan = false
    @Volatile private var active = false
    private var launchRecorded = false

    init {
        transport.setIssueListener(::handleTransportIssue)
        val stored = runCatching { store.load() }.getOrElse {
            mutableState.update { it.copy(issue = UsageIssue.STORAGE_FAILED) }
            false
        }
        mutableState.update { it.copy(enabled = stored) }
        // 关闭状态下不应留有安装标识：补删上次关闭时没能删掉的
        if (!stored) runCatching { installId.delete() }
    }

    fun beginSession() {
        if (sessionBegan) return
        sessionBegan = true
        startIfAllowed()
    }

    /** 返回用户的选择是否已保存；启动等故障另由 state.issue 说明 */
    fun setEnabled(enabled: Boolean): Boolean = if (enabled) enable() else disable()

    fun record(event: UsageEvent) {
        if (!state.value.enabled || !active) return
        try {
            transport.record(event.toRecord(platform))
        } catch (_: Throwable) {
            mutableState.update { it.copy(issue = UsageIssue.RECORD_FAILED) }
        }
    }

    fun endSession() = stop()

    private fun enable(): Boolean {
        if (!state.value.available || !transport.isAvailable) return false
        return try {
            store.save(true)
            mutableState.update { it.copy(enabled = true, issue = null) }
            startIfAllowed()
            true
        } catch (_: Throwable) {
            mutableState.update { it.copy(enabled = false, issue = UsageIssue.STORAGE_FAILED) }
            false
        }
    }

    // 进程级故障的说明保留：关闭后仍要告诉用户为什么不能再开
    private fun disable(): Boolean {
        mutableState.update { it.copy(enabled = false, issue = it.issue?.takeIf(UsageIssue::disablesProcess)) }
        stop()
        val saved = runCatching { store.save(false) }.isSuccess
        val forgotten = runCatching { installId.delete() }.isSuccess
        if (saved && forgotten) return true
        mutableState.update { it.copy(issue = UsageIssue.STORAGE_FAILED) }
        return false
    }

    private fun handleTransportIssue(issue: UsageIssue) {
        if (issue.disablesProcess) active = false
        mutableState.update { it.copy(available = it.available && !issue.disablesProcess, issue = issue) }
    }

    private fun startIfAllowed() {
        if (!sessionBegan || !state.value.enabled || !state.value.available || active) return
        try {
            transport.start(installId.obtain())
            active = true
            if (!launchRecorded) {
                record(UsageEvent.AppStarted)
                launchRecorded = true
            }
        } catch (_: Throwable) {
            handleTransportIssue(UsageIssue.START_FAILED)
        }
    }

    private fun stop() {
        if (!active) return
        active = false
        runCatching { transport.stop() }
    }
}
