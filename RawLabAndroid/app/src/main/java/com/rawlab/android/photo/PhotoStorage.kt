package com.rawlab.android.photo

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
import com.rawlab.android.R
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.PhotoFiles
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.looks.BundledLooks
import com.rawlab.android.looks.DcpCompiler
import com.rawlab.android.looks.LookLibrary
import com.rawlab.android.looks.LookValidator
import com.rawlab.android.looks.ManagedLook
import com.rawlab.android.looks.LUTCompatibility
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.editor.PendingLookCompatibility
import com.rawlab.android.looks.MasterRecipe
import com.rawlab.android.looks.NativeDcpCompiler
import com.rawlab.android.looks.NativeLookValidator
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.Film
import com.rawlab.android.settings.LookChoice
import com.rawlab.android.settings.PhotoIdentity

data class AlbumPhoto(val uri: Uri, val name: String, val album: String,
    val width: Int = 0, val height: Int = 0, val orientation: Int = 0) {
    val aspectRatio: Float? get() = albumAspectRatio(width, height, orientation)
}
data class ImportedPhoto(val uri: Uri, val name: String, val file: File,
    val identity: PhotoIdentity = PhotoIdentity(uri.toString()),
    val inputKind: PhotoInputKind = PhotoInputKind.RAW,
    val validateOriginal: (() -> Unit)? = null)

internal fun albumAspectRatio(width: Int, height: Int, orientation: Int): Float? {
    if (width <= 0 || height <= 0) return null
    return if (orientation == 90 || orientation == 270) height.toFloat() / width else width.toFloat() / height
}

class PhotoStorage(
    private val context: Context,
    looksDirectory: File = File(context.filesDir, "looks"),
    lookValidator: LookValidator = NativeLookValidator,
    dcpCompiler: DcpCompiler = NativeDcpCompiler,
) : AutoCloseable {
    private val resolver = context.contentResolver
    private val directory = File(context.cacheDir, "rawlab-${UUID.randomUUID()}")
    private val lookLibrary = LookLibrary(looksDirectory, lookValidator, dcpCompiler)
    private val films = Film.all + BundledLooks.load(context)
    private var lensDirectory: File? = null

    @Synchronized
    fun lensDatabase(): File {
        lensDirectory?.let { return it }
        val target = File(context.filesDir, "lensfun-db1-20261012")
        if (!target.isDirectory && !target.mkdirs()) throw IOException("Cannot create lens database directory")
        val names = context.assets.list("Lensfun")?.filter { it.endsWith(".xml") }.orEmpty()
        if (names.isEmpty()) throw IOException("Lens database is missing")
        for (name in names) {
            val temporary = File(target, "$name.tmp")
            try {
                context.assets.open("Lensfun/$name").use { input -> temporary.outputStream().use(input::copyTo) }
                java.nio.file.Files.move(temporary.toPath(), File(target, name).toPath(),
                    java.nio.file.StandardCopyOption.REPLACE_EXISTING)
            } finally { temporary.delete() }
        }
        lensDirectory = target
        return target
    }

    fun album(): List<AlbumPhoto> {
        val collection = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        val projection = arrayOf(MediaStore.Images.Media._ID, MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.MIME_TYPE, MediaStore.Images.Media.BUCKET_DISPLAY_NAME,
            MediaStore.Images.Media.WIDTH, MediaStore.Images.Media.HEIGHT, MediaStore.Images.Media.ORIENTATION)
        val result = mutableListOf<AlbumPhoto>()
        resolver.query(collection, projection, null, null, "${MediaStore.Images.Media.DATE_ADDED} DESC")?.use { cursor ->
            while (cursor.moveToNext()) {
                val name = cursor.getString(1) ?: "RAW"
                if (PhotoFiles.accepts(name, cursor.getString(2))) {
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
        runCatching {
            resolver.takePersistableUriPermission(uri, android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val name = runCatching { resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null) }.getOrNull()?.use {
            if (it.moveToFirst()) it.getString(0) else null
        } ?: uri.lastPathSegment?.substringAfterLast('/') ?: "RAW"
        val inputKind = PhotoFiles.kind(name, resolver.getType(uri))
            ?: throw IOException("Selected item is not a supported photo")
        val validate = OriginalPhotoSource.capture(resolver, uri)
        val stream = resolver.openInputStream(uri) ?: throw IOException("Cannot open input")
        val file = WorkingCopy.import(directory, stream)
        try {
            validate()
            return ImportedPhoto(uri, name, file, PhotoIdentity(uri.toString()), inputKind, validate)
        } catch (error: Throwable) { file.delete(); throw error }
    }

    fun looks(): List<LookChoice> = films.map { LookChoice(it.id, it.name, managed = false) } + lookLibrary.list().map {
        LookChoice(it.id, it.name, managed = true, available = it.available, appearanceUnverified = it.appearanceUnverified, compatibilityMode = it.compatibilityMode)
    }
    fun builtinLookIDs(): Map<String, String> = films.mapNotNull { film -> film.fileName?.let { it to film.id } }.toMap()

    private fun lookSourceName(uri: Uri): String = runCatching { resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null) }.getOrNull()?.use {
            if (it.moveToFirst()) it.getString(0) else null
        } ?: uri.lastPathSegment?.substringAfterLast('/') ?: "Look"

    fun importLook(uri: Uri, compatibility: LUTCompatibility? = null): ManagedLook {
        val name = lookSourceName(uri)
        try {
            val stream = resolver.openInputStream(uri) ?: throw IOException("Cannot open look")
            return stream.use { lookLibrary.importLook(it, name, compatibility) }
        } catch (error: Exception) {
            throw IOException("${name}: ${error.message ?: error.javaClass.simpleName}", error)
        }
    }

    fun inspectLookCompatibility(uri: Uri): PendingLookCompatibility? {
        val name = lookSourceName(uri)
        val suffix = name.substringAfterLast('.', "").lowercase()
        if (suffix !in listOf("cube", "vlt")) return null
        directory.mkdirs()
        val temporary = File.createTempFile("lut-compatibility-", ".$suffix", directory)
        try {
            (resolver.openInputStream(uri) ?: throw IOException("Cannot open look")).use { input ->
                temporary.outputStream().use { output ->
                    val buffer = ByteArray(65536); var total = 0L
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        if (total > 256L * 1024 * 1024) throw IOException("LUT exceeds size limit")
                        output.write(buffer, 0, count)
                    }
                }
            }
            return LUTCompatibility.parse(NativeProcessor.inspectLutCompatibility(temporary))?.let { PendingLookCompatibility(uri, name, it) }
        } finally { temporary.delete() }
    }

    fun renameLook(id: String, name: String): ManagedLook = lookLibrary.rename(id, name)

    fun deleteLook(id: String) = lookLibrary.remove(id)

    fun filmPath(id: String): File? {
        val film = films.firstOrNull { it.id == id }
        if (film == null) return lookLibrary.fileFor(id)
            ?: throw IllegalArgumentException("Unknown look: ${id}")
        val name = film.fileName ?: return null
        val destination = File(directory, name)
        if (!destination.exists()) {
            directory.mkdirs()
            try {
                context.assets.open("films/${name}").use { input -> destination.outputStream().use { input.copyTo(it) } }
            } catch (error: Throwable) { destination.delete(); throw error }
        }
        return destination
    }
    fun lookPath(settings: EditSettings): File? {
        val id = settings.recipeID ?: settings.film.takeIf { it.startsWith("recipe-lut:") }?.removePrefix("recipe-lut:")
            ?: return filmPath(settings.film)
        val recipe = MasterRecipe.load(context).first { it.id == id }
        val destination = File(directory, recipe.lutFileName)
        if (!destination.exists()) {
            directory.mkdirs()
            try {
                context.assets.open("MasterRecipes/${recipe.lutFileName}").use { input -> destination.outputStream().use { input.copyTo(it) } }
            } catch (error: Throwable) { destination.delete(); throw error }
        }
        return destination
    }

    fun temporaryOutput(format: ExportFormat): File {
        directory.mkdirs()
        return File.createTempFile("export-", format.suffix, directory)
    }

    fun saveDocument(file: File, destination: Uri, original: Uri) {
        require(destination != original) { "Cannot overwrite source photo" }
        val stream = resolver.openOutputStream(destination, "wt") ?: throw IOException("Cannot open destination")
        stream.use { output -> file.inputStream().use { it.copyTo(output) } }
    }

    fun saveAlbum(file: File, format: ExportFormat, outputName: String? = null, onCreated: (Uri) -> Unit = {}): Uri {
        check(Build.VERSION.SDK_INT >= 29)
        require(format.allowsGallery) { "${format.name} export cannot be saved to the gallery" }
        val names = mutableSetOf<String>()
        resolver.query(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, arrayOf(MediaStore.Images.Media.DISPLAY_NAME),
            "${MediaStore.Images.Media.RELATIVE_PATH} = ?", arrayOf("Pictures/RawLab/"), null)?.use { cursor ->
            while (cursor.moveToNext()) names += cursor.getString(0).lowercase()
        }
        val name = outputName ?: "RawLab-${System.currentTimeMillis()}${format.suffix}"
        var candidate = name
        var suffix = 2
        while (candidate.lowercase() in names) candidate = "${name.substringBeforeLast('.')}-${suffix++}.${name.substringAfterLast('.')}"
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, candidate)
            put(MediaStore.Images.Media.MIME_TYPE, format.mimeType)
            put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/RawLab")
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values) ?: throw IOException("Cannot create image")
        try {
            onCreated(uri)
            val output = resolver.openOutputStream(uri) ?: throw IOException("Cannot write image")
            output.use { to -> file.inputStream().use { it.copyTo(to) } }
            val published = resolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
            if (published != 1) throw IOException("Cannot publish image")
            return uri
        } catch (error: Throwable) {
            if (runCatching { resolver.delete(uri, null, null) }.getOrDefault(0) != 1) throw BatchPublicationUncertain(AppStrings.text(R.string.message_could_not_confirm_whether_the_photo_was), error)
            throw error
        }
    }

    override fun close() { directory.deleteRecursively() }
}
