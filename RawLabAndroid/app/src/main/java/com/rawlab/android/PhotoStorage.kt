package com.rawlab.android

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Size
import java.io.File
import java.io.IOException
import java.util.UUID

data class AlbumPhoto(val uri: Uri, val name: String, val album: String,
    val width: Int = 0, val height: Int = 0, val orientation: Int = 0) {
    val aspectRatio: Float? get() = albumAspectRatio(width, height, orientation)
}
data class ImportedPhoto(val uri: Uri, val name: String, val file: File)

internal fun albumAspectRatio(width: Int, height: Int, orientation: Int): Float? {
    if (width <= 0 || height <= 0) return null
    return if (orientation == 90 || orientation == 270) height.toFloat() / width else width.toFloat() / height
}

class PhotoStorage(private val context: Context) : AutoCloseable {
    private val resolver = context.contentResolver
    private val directory = File(context.cacheDir, "rawlab-${UUID.randomUUID()}")

    fun album(): List<AlbumPhoto> {
        val collection = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        val projection = arrayOf(MediaStore.Images.Media._ID, MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.MIME_TYPE, MediaStore.Images.Media.BUCKET_DISPLAY_NAME,
            MediaStore.Images.Media.WIDTH, MediaStore.Images.Media.HEIGHT, MediaStore.Images.Media.ORIENTATION)
        val result = mutableListOf<AlbumPhoto>()
        resolver.query(collection, projection, null, null, "${MediaStore.Images.Media.DATE_ADDED} DESC")?.use { cursor ->
            while (cursor.moveToNext()) {
                val name = cursor.getString(1) ?: "RAW"
                if (RawFiles.accepts(name, cursor.getString(2))) {
                    result += AlbumPhoto(ContentUris.withAppendedId(collection, cursor.getLong(0)), name, cursor.getString(3) ?: "RAW",
                        cursor.getInt(4), cursor.getInt(5), cursor.getInt(6))
                }
            }
        }
        return result
    }

    fun thumbnail(uri: Uri, size: Int = 256, orientation: Int = 0): Bitmap? = try {
        if (Build.VERSION.SDK_INT >= 29) resolver.loadThumbnail(uri, Size(size, size), null)
        else {
            @Suppress("DEPRECATION")
            val bitmap = MediaStore.Images.Thumbnails.getThumbnail(resolver, ContentUris.parseId(uri), MediaStore.Images.Thumbnails.MINI_KIND, null)
            // Android 10 起系统负责缩略图方向，旧接口需要单独旋转。
            if (bitmap == null || orientation == 0) bitmap else {
                val matrix = Matrix().apply { postRotate(orientation.toFloat()) }
                Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true).also {
                    if (it !== bitmap) bitmap.recycle()
                }
            }
        }
    } catch (_: Exception) { null }

    fun import(uri: Uri): ImportedPhoto {
        val name = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        } ?: "RAW"
        val stream = resolver.openInputStream(uri) ?: throw IOException("Cannot open input")
        return ImportedPhoto(uri, name, WorkingCopy.import(directory, stream))
    }

    fun filmPath(id: String): File? {
        val film = Film.all.single { it.id == id }
        val name = film.file?.let { "FLog2_to_${it}_65grid_V.1.00.cube" } ?: return null
        val destination = File(directory, name)
        if (!destination.exists()) {
            directory.mkdirs()
            try {
                context.assets.open("films/$name").use { input -> destination.outputStream().use { input.copyTo(it) } }
            } catch (error: Throwable) { destination.delete(); throw error }
        }
        return destination
    }

    fun temporaryOutput(png: Boolean): File {
        directory.mkdirs()
        return File.createTempFile("export-", if (png) ".png" else ".jpg", directory)
    }

    fun saveDocument(file: File, destination: Uri, original: Uri) {
        require(destination != original) { "Cannot overwrite original RAW" }
        val stream = resolver.openOutputStream(destination, "wt") ?: throw IOException("Cannot open destination")
        stream.use { output -> file.inputStream().use { it.copyTo(output) } }
    }

    fun saveAlbum(file: File, png: Boolean): Uri {
        check(Build.VERSION.SDK_INT >= 29)
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, "RawLab-${System.currentTimeMillis()}.${if (png) "png" else "jpg"}")
            put(MediaStore.Images.Media.MIME_TYPE, if (png) "image/png" else "image/jpeg")
            put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/RawLab")
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values) ?: throw IOException("Cannot create image")
        try {
            val output = resolver.openOutputStream(uri) ?: throw IOException("Cannot write image")
            output.use { to -> file.inputStream().use { it.copyTo(to) } }
            val published = resolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
            if (published != 1) throw IOException("Cannot publish image")
            return uri
        } catch (error: Throwable) {
            runCatching { resolver.delete(uri, null, null) }
            throw error
        }
    }

    override fun close() { directory.deleteRecursively() }
}
