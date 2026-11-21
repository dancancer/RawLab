package com.rawlab.android.analytics.rum

import android.Manifest
import android.content.pm.PackageManager
import android.content.Context
import android.content.ContextWrapper
import java.io.File

/** SDK 的文件、数据库与偏好全部落在应用私有的 rum-sdk 目录与 rum_sdk_ 前缀下，关闭统计时整体删除 */
internal class RumIsolatedContext(base: Context) : ContextWrapper(base.applicationContext ?: base) {
    private val preferenceNames = mutableSetOf<String>()
    private val preferenceLock = Any()
    private val root = File(baseContext.filesDir, "rum-sdk").also(File::mkdirs)

    // 相机需要应用级网络权限，但固定版本 SDK 也会在启动时读取网络元数据。
    // 保持原有无网络状态权限的统计边界；SDK 2.3.2 的 manager-null 分支会跳过采集。
    override fun getSystemService(name: String): Any? =
        if (name == Context.CONNECTIVITY_SERVICE) null else super.getSystemService(name)
    override fun checkPermission(permission: String, pid: Int, uid: Int): Int =
        if (permission in CAMERA_PERMISSIONS) PackageManager.PERMISSION_DENIED else super.checkPermission(permission, pid, uid)
    override fun checkSelfPermission(permission: String): Int =
        if (permission in CAMERA_PERMISSIONS) PackageManager.PERMISSION_DENIED else super.checkSelfPermission(permission)
    override fun checkCallingOrSelfPermission(permission: String): Int =
        if (permission in CAMERA_PERMISSIONS) PackageManager.PERMISSION_DENIED else super.checkCallingOrSelfPermission(permission)

    override fun getApplicationContext(): Context = this
    override fun getDataDir(): File = root
    override fun getFilesDir(): File = directory("files")
    override fun getCacheDir(): File = directory("cache")
    override fun getNoBackupFilesDir(): File = directory("no-backup")
    override fun getDatabasePath(name: String): File = File(directory("databases"), name)
    override fun getFileStreamPath(name: String): File = File(getFilesDir(), name)
    override fun getDir(name: String, mode: Int): File = directory("dirs/$name")
    override fun getExternalFilesDir(type: String?): File = directory("external-files/${type.orEmpty()}")
    override fun getExternalCacheDir(): File = directory("external-cache")
    override fun getSharedPreferences(name: String, mode: Int) =
        baseContext.getSharedPreferences("$PREFERENCE_PREFIX$name", mode).also {
            synchronized(preferenceLock) { preferenceNames += "$PREFERENCE_PREFIX$name" }
        }

    fun cleanup(): Boolean {
        val names = synchronized(preferenceLock) { preferenceNames.filter(::isOwnedPreference) }
        val preferencesClean = names.all { baseContext.deleteSharedPreferences(it) }
        val filesClean = !root.exists() || root.deleteRecursively()
        return preferencesClean && filesClean
    }

    private fun directory(relative: String): File = File(root, relative).also(File::mkdirs)

    private fun isOwnedPreference(name: String): Boolean = name.startsWith(PREFERENCE_PREFIX)

    private companion object {
        const val PREFERENCE_PREFIX = "rum_sdk_"
        val CAMERA_PERMISSIONS = setOf(Manifest.permission.ACCESS_NETWORK_STATE, Manifest.permission.ACCESS_WIFI_STATE,
            Manifest.permission.CHANGE_NETWORK_STATE, Manifest.permission.CHANGE_WIFI_STATE,
            Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION,
            Manifest.permission.BLUETOOTH, Manifest.permission.BLUETOOTH_ADMIN,
            Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.NEARBY_WIFI_DEVICES)
    }
}
