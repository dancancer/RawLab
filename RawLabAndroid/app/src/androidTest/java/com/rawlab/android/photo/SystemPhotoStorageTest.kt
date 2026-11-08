package com.rawlab.android.photo

import android.content.ContentProvider
import android.content.ContentResolver
import android.content.ContentValues
import android.content.ContextWrapper
import android.content.pm.ProviderInfo
import android.content.res.AssetFileDescriptor
import android.database.Cursor
import android.database.MatrixCursor
import android.graphics.Bitmap
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.EditStore
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class SystemPhotoStorageTest {
    @Test @SdkSuppress(minSdkVersion = 29)
    fun copiedShareSurvivesRevokedProviderAndRestoresEdits() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(base.cacheDir, "system-photo-test-${UUID.randomUUID()}").apply { mkdirs() }
        val source = File(root, "provider.png")
        val bitmap = Bitmap.createBitmap(4, 4, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(android.graphics.Color.MAGENTA)
        source.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        bitmap.recycle()
        var revoked = false
        val provider = object : ContentProvider() {
            override fun onCreate() = true
            override fun getType(uri: Uri): String? {
                if (uri.scheme != "content") return null
                if (revoked) throw SecurityException("grant revoked")
                return "image/png"
            }
            override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
                if (revoked) throw SecurityException("grant revoked")
                return MatrixCursor(arrayOf(OpenableColumns.DISPLAY_NAME)).apply { addRow(arrayOf("shared.png")) }
            }
            override fun insert(uri: Uri, values: ContentValues?): Uri? = null
            override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
            override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
            override fun openAssetFile(uri: Uri, mode: String): AssetFileDescriptor {
                // wrap 会把 file URI 也交给 provider；私有副本应按真实 resolver 的本地文件规则打开。
                if (uri.scheme == ContentResolver.SCHEME_FILE) {
                    return requireNotNull(base.contentResolver.openAssetFileDescriptor(uri, mode))
                }
                if (revoked) throw SecurityException("grant revoked")
                return AssetFileDescriptor(ParcelFileDescriptor.open(source, ParcelFileDescriptor.MODE_READ_ONLY), 0, source.length())
            }
        }
        provider.attachInfo(base, ProviderInfo().apply { authority = "com.rawlab.tests.system-photo"; exported = false })
        val resolver = ContentResolver.wrap(provider)
        val context = object : ContextWrapper(base) {
            override fun getContentResolver() = resolver
            override fun getFilesDir() = File(root, "files").apply { mkdirs() }
            override fun getCacheDir() = File(root, "cache").apply { mkdirs() }
        }
        val external = Uri.parse("content://com.rawlab.tests.system-photo/item")
        try {
            val bytes = source.readBytes()
            val stable = PhotoStorage(context).use { it.retainSystemPhoto(external) }
            assertEquals(ContentResolver.SCHEME_FILE, stable.scheme)
            revoked = true
            assertTrue(source.delete())
            assertThrows(SecurityException::class.java) { resolver.openInputStream(external) }
            assertThrows(SecurityException::class.java) { resolver.openAssetFileDescriptor(external, "r") }
            val edits = EditStore(File(root, "edits"))
            val identity = PhotoStorage(context).use { storage ->
                val photo = storage.import(stable)
                assertEquals(stable.toString(), photo.identity.value)
                assertEquals("shared.png", photo.name)
                assertArrayEquals(bytes, photo.file.readBytes())
                photo.validateOriginal?.invoke()
                edits.save(photo.identity, EditSettings(exposure = 1.25f))
                photo.identity
            }
            PhotoStorage(context).use { storage ->
                val photo = storage.import(stable)
                photo.validateOriginal?.invoke()
                assertEquals(identity, photo.identity)
                assertEquals(1.25f, edits.load(photo.identity)!!.exposure)
                File(stable.path!!).writeText("replaced original")
                assertThrows(java.io.IOException::class.java) { storage.import(stable) }
            }
        } finally { root.deleteRecursively() }
    }
}
