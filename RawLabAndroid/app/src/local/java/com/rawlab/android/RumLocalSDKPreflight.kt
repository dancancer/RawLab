package com.rawlab.android

import android.content.Context
import org.json.JSONObject

internal fun interface RumLocalSDKPreflight {
    fun isSafe(context: Context): Boolean
}

internal object BundledRumLocalSDKPreflight : RumLocalSDKPreflight {
    override fun isSafe(context: Context): Boolean = runCatching {
        val root = context.assets.open("rum_android_config.json").bufferedReader().use { JSONObject(it.readText()) }
        if (!root.optBoolean("enable", false)) return false
        if (root.optJSONObject("tracing")?.optBoolean("enable", true) != false) return false
        val collectors = root.optJSONArray("collectors") ?: return false
        val enabled = buildSet {
            for (index in 0 until collectors.length()) {
                val collector = collectors.optJSONObject(index) ?: return@runCatching false
                val name = collector.optString("name", "")
                if (name.isBlank() || !collector.has("enable")) return@runCatching false
                if (collector.optBoolean("enable", false)) add(name)
            }
        }
        enabled == setOf("customevent")
    }.getOrDefault(false)
}
