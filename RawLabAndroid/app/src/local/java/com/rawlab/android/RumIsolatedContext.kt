package com.rawlab.android

import android.content.Context
import android.content.ContextWrapper
import java.io.File

internal class RumIsolatedContext(base: Context) : ContextWrapper(base.applicationContext ?: base) {
    private val preferenceNames = mutableSetOf<String>()
    private val preferenceLock = Any()
    private val root = File(baseContext.filesDir, "rum-local-sdk").also(File::mkdirs)

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
        const val PREFERENCE_PREFIX = "rum_local_sdk_"
    }
}
