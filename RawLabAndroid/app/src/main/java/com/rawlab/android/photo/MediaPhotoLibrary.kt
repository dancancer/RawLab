package com.rawlab.android.photo

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest

internal class MediaPhotoChanged : IOException("The original photo has changed")

/** 只登记内容摘要和媒体 URI，不保存第二份原件。 */
internal class MediaPhotoLibrary(private val context: Context) : MediaPhotoAccess {
    private val resolver = context.contentResolver
    private val sources = context.getSharedPreferences("camera-media-sources", Context.MODE_PRIVATE)
    private val marker = "RawLab camera import:"

    override fun createPending(name: String, relativePath: String, mime: String, token: String): MediaPhoto {
        if (Build.VERSION.SDK_INT < 29) throw IOException("Camera media import requires Android 10")
        require(relativePath.startsWith("Pictures/") && relativePath.split('/').none { it == ".." || it == "." } && relativePath.endsWith('/'))
        require(mime == "image/x-sony-arw" || mime == "image/jpeg")
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, availableName(name, relativePath))
            put(MediaStore.Images.Media.MIME_TYPE, mime)
            put(MediaStore.Images.Media.RELATIVE_PATH, relativePath)
            put(MediaStore.Images.Media.DESCRIPTION, marker + token)
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection(), values) ?: throw IOException("Cannot create camera photo")
        // 插入成功后进程可能先退出；恢复时通过自有 pending 标记清理尚未登记的行。
        return inspect(uri.toString()) ?: throw IOException("Cannot read created camera photo")
    }

    override fun write(uri: String, source: File) {
        requireOwnedPending(uri)
        val descriptor = resolver.openFileDescriptor(checkedUri(uri), "w") ?: throw IOException("Cannot write camera photo")
        ParcelFileDescriptor.AutoCloseOutputStream(descriptor).use { output ->
            source.inputStream().use { it.copyTo(output) }
            output.fd.sync()
        }
    }

    override fun publish(uri: String): MediaPhoto {
        if (Build.VERSION.SDK_INT < 29) throw IOException("Camera media import requires Android 10")
        requireOwnedPending(uri)
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.IS_PENDING, 0)
            putNull(MediaStore.Images.Media.DESCRIPTION)
        }
        if (resolver.update(checkedUri(uri), values, null, null) != 1) throw IOException("Cannot publish camera photo")
        return inspect(uri)?.takeUnless { it.pending } ?: throw IOException("Camera photo publication is uncertain")
    }

    override fun inspect(uri: String): MediaPhoto? {
        if (Build.VERSION.SDK_INT < 29) return null
        @Suppress("DEPRECATION")
        val pendingAware = MediaStore.setIncludePending(checkedUri(uri))
        return resolver.query(pendingAware, arrayOf(MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.RELATIVE_PATH, MediaStore.Images.Media.IS_PENDING), null, null, null)?.use { cursor ->
            if (!cursor.moveToFirst()) null else MediaPhoto(uri, cursor.getString(0).orEmpty(), cursor.getString(1).orEmpty(), cursor.getInt(2) != 0)
        }
    }

    override fun open(uri: String): InputStream = resolver.openInputStream(checkedUri(uri))
        ?: throw IOException("Camera original is unavailable")

    override fun remember(uri: String, size: Long, digest: String) {
        checkedUri(uri)
        require(size in 1..SystemPhotoStore.MAX_BYTES && digest.matches(Regex("[0-9a-f]{64}")))
        val value = "$size:$digest"
        if (sources.getString(uri, null) != value && !sources.edit().putString(uri, value).commit())
            throw IOException("Cannot save camera media reference")
    }

    override fun deletePending(uri: String) {
        if (Build.VERSION.SDK_INT < 29) return
        val row = inspect(uri) ?: return
        if (!row.pending) return
        requireOwnedPending(uri)
        if (resolver.delete(checkedUri(uri), null, null) != 1) throw IOException("Cannot remove unfinished camera photo")
        sources.edit().remove(uri).commit()
    }

    override fun cleanupOrphans(referenced: Set<String>) {
        if (Build.VERSION.SDK_INT < 29) return
        @Suppress("DEPRECATION")
        val pendingAware = MediaStore.setIncludePending(collection())
        val orphanUris = resolver.query(pendingAware, arrayOf(MediaStore.Images.Media._ID),
            "${MediaStore.Images.Media.OWNER_PACKAGE_NAME} = ? AND ${MediaStore.Images.Media.IS_PENDING} = 1 AND ${MediaStore.Images.Media.DESCRIPTION} LIKE ?",
            arrayOf(context.packageName, "$marker%"), null)?.use { cursor ->
            buildList { while (cursor.moveToNext()) {
                val uri = ContentUris.withAppendedId(collection(), cursor.getLong(0)).toString()
                if (uri !in referenced) add(uri)
            } }
        }.orEmpty()
        orphanUris.forEach(::deletePending)
    }

    /** 聚合相册可以使用别名；只有本功能登记的行改用具体卷身份，旧照片编辑键不变。 */
    fun canonicalIfKnown(volume: String?, id: Long): Uri? {
        if (Build.VERSION.SDK_INT < 29 || volume != MediaStore.VOLUME_EXTERNAL_PRIMARY || id <= 0) return null
        val uri = ContentUris.withAppendedId(collection(), id)
        return uri.takeIf { sources.contains(it.toString()) }
    }

    fun resolveKnown(input: Uri): Uri? {
        if (Build.VERSION.SDK_INT < 29 || input.scheme != "content") return null
        val mediaUri = when (input.authority) {
            MediaStore.AUTHORITY -> input
            "com.android.providers.media.documents" -> runCatching { MediaStore.getMediaUri(context, input) }.getOrNull() ?: return null
            else -> return null
        }
        val parts = mediaUri.pathSegments
        val imageRow = parts.size == 4 && parts[1] == "images" && parts[2] == "media"
        val fileRow = parts.size == 3 && parts[1] == "file"
        if ((!imageRow && !fileRow) || parts.firstOrNull() !in setOf(MediaStore.VOLUME_EXTERNAL, MediaStore.VOLUME_EXTERNAL_PRIMARY) ||
            parts.lastOrNull()?.toLongOrNull()?.let { it > 0 } != true) return null
        // Photo Picker 也使用 media authority，但不是 Images 行，不能对它请求内部媒体列。
        val canonical = resolver.query(mediaUri, arrayOf(MediaStore.Images.Media._ID, MediaStore.Images.Media.VOLUME_NAME,
            MediaStore.Images.Media.MIME_TYPE, MediaStore.Images.Media.IS_PENDING), null, null, null)?.use { cursor ->
            if (!cursor.moveToFirst() || !cursor.getString(2).orEmpty().startsWith("image/")) null
            else canonicalIfKnown(cursor.getString(1), cursor.getLong(0))?.also {
                if (cursor.getInt(3) != 0) throw IOException("Camera original is not published")
            }
        } ?: return null
        val record = sources.getString(canonical.toString(), null)?.split(':', limit = 2)
            ?: throw IOException("Camera media reference is unavailable")
        val size = record.firstOrNull()?.toLongOrNull() ?: throw IOException("Invalid camera media reference")
        val expected = record.getOrNull(1) ?: throw IOException("Invalid camera media reference")
        var total = 0L
        val digest = MessageDigest.getInstance("SHA-256")
        open(canonical.toString()).use { inputStream ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = inputStream.read(buffer); if (count < 0) break
                total += count
                if (total > size) throw MediaPhotoChanged()
                digest.update(buffer, 0, count)
            }
        }
        if (total != size || digest.digest().joinToString("") { "%02x".format(it) } != expected) throw MediaPhotoChanged()
        return canonical
    }

    private fun availableName(name: String, relativePath: String): String {
        if (Build.VERSION.SDK_INT < 29) throw IOException("Camera media import requires Android 10")
        @Suppress("DEPRECATION")
        val pendingAware = MediaStore.setIncludePending(collection())
        val names = resolver.query(pendingAware, arrayOf(MediaStore.Images.Media.DISPLAY_NAME),
            "${MediaStore.Images.Media.RELATIVE_PATH} = ?", arrayOf(relativePath), null)?.use { cursor ->
            buildSet { while (cursor.moveToNext()) add(cursor.getString(0).orEmpty().lowercase(java.util.Locale.ROOT)) }
        }.orEmpty()
        var candidate = name; var number = 2
        while (candidate.lowercase(java.util.Locale.ROOT) in names) {
            candidate = "${name.substringBeforeLast('.')}-${number++}.${name.substringAfterLast('.')}"
        }
        // 系统 insert 还会解决其他应用不可见文件或并发写入造成的同名冲突。
        return candidate
    }

    private fun requireOwnedPending(uri: String) {
        if (Build.VERSION.SDK_INT < 29) throw IOException("Camera media import requires Android 10")
        @Suppress("DEPRECATION")
        val pendingAware = MediaStore.setIncludePending(checkedUri(uri))
        val owned = resolver.query(pendingAware, arrayOf(MediaStore.Images.Media.OWNER_PACKAGE_NAME,
            MediaStore.Images.Media.DESCRIPTION, MediaStore.Images.Media.IS_PENDING), null, null, null)?.use { cursor ->
            cursor.moveToFirst() && cursor.getString(0) == context.packageName &&
                cursor.getString(1).orEmpty().startsWith(marker) && cursor.getInt(2) == 1
        } == true
        if (!owned) throw IOException("Media item is not an unfinished camera import")
    }

    private fun checkedUri(value: String): Uri {
        if (!value.matches(Regex("content://media/external_primary/images/media/[1-9][0-9]*")))
            throw IOException("Invalid camera media URI")
        return Uri.parse(value)
    }
    private fun collection(): Uri = if (Build.VERSION.SDK_INT >= 29)
        MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY) else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
}
