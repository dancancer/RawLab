package com.rawlab.android.photo

import android.content.ContentProvider
import android.content.ContentResolver
import android.content.ContentValues
import android.content.pm.ProviderInfo
import android.content.res.AssetFileDescriptor
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.filters.SdkSuppress
import com.rawlab.android.settings.EditPersistenceConflict
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class OriginalPhotoSourceTest {
    @Test @SdkSuppress(minSdkVersion = 29)
    fun subsectionProviderUsesItsContentAndRejectsChangedBytes() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val files = mutableListOf<File>()
        var bytes = byteArrayOf(1, 2, 3, 4)
        val provider = object : ContentProvider() {
            override fun onCreate() = true
            override fun getType(uri: Uri) = "application/octet-stream"
            override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null
            override fun insert(uri: Uri, values: ContentValues?): Uri? = null
            override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
            override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
            override fun openAssetFile(uri: Uri, mode: String): AssetFileDescriptor {
                val file = File.createTempFile("source-section-", ".bin", context.cacheDir).also(files::add)
                file.writeBytes(byteArrayOf(9, 9, 9, 9) + bytes + byteArrayOf(8, 8))
                return AssetFileDescriptor(ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY), 4, bytes.size.toLong())
            }
        }
        provider.attachInfo(context, ProviderInfo().apply { authority = "com.rawlab.test.source"; exported = false })
        val resolver = ContentResolver.wrap(provider)
        val uri = Uri.parse("content://com.rawlab.test.source/item")
        try {
            assertArrayEquals(bytes, resolver.openInputStream(uri)!!.use { it.readBytes() })
            val validate = OriginalPhotoSource.capture(resolver, uri)
            validate() // 每次返回新 fd/inode，但同一个逻辑流仍应可用。
            bytes = byteArrayOf(4, 3, 2, 1)
            try { validate(); fail("Changed provider content must be rejected") } catch (_: EditPersistenceConflict) { }
        } finally { files.forEach(File::delete) }
    }
}
