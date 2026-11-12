package com.rawlab.android.photo

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Process
import com.rawlab.android.BuildConfig
import com.rawlab.android.editor.render.EditorRenderer
import com.rawlab.android.editor.render.RenderCancellation
import com.rawlab.android.editor.render.Work
import com.rawlab.android.editor.render.WorkResult
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.format.PhotoFiles
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.*
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal class EditedPhotoPreviews(context: Context) : AutoCloseable {
    private val context = context.applicationContext
    private val editDirectory = File(context.filesDir, "edits")
    private val store by lazy { EditStore(editDirectory) }
    private val storageDelegate = lazy { PhotoStorage(this.context) }
    private val storage by storageDelegate
    private val rendererDelegate = lazy { EditorRenderer(storage, { store.readState(it) }, BuildConfig.DEBUG) }
    private val renderer by rendererDelegate
    private val cache = EditedPhotoPreviewCache(File(context.cacheDir, "edited-photo-previews"))
    private val requests = ConcurrentHashMap.newKeySet<RenderCancellation>()
    private val closed = AtomicBoolean(false)
    private val executor = Executors.newSingleThreadExecutor { action ->
        Thread({ Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND); action.run() }, "rawlab-photo-previews")
    }

    suspend fun states(photos: List<AlbumPhoto>): Map<String, Boolean> = work { cancellation ->
        val records = store.readStates(photos.map { PhotoIdentity(it.uri.toString()) })
        buildMap(photos.size) {
            for (photo in photos) {
                cancellation.check()
                val input = PhotoFiles.kind(photo.name, photo.mimeType) ?: PhotoInputKind.RAW
                when (val result = records[PhotoIdentity(photo.uri.toString())]) {
                    is PhotoEditReadResult.Usable ->
                        put(photo.uri.toString(), EditedPhotoPreviewKey.isEdited(result.state.settings, input))
                    is PhotoEditReadResult.Unusable, null -> Unit
                }
            }
        }
    }

    suspend fun image(photo: AlbumPhoto): Bitmap = work { cancellation ->
        val identity = PhotoIdentity(photo.uri.toString())
        val record = store.readState(identity)
        val settings = record.settings ?: throw AdjustmentOperationExpiredException()
        val stamp = OriginalPhotoSource.fingerprint(context.contentResolver, photo.uri)
        val resources = resources(settings)
        val key = key(identity, stamp, settings, resources)
        requireCurrent(record, photo.uri, stamp, resources)
        runCatching { cache.read(key)?.let { BitmapFactory.decodeByteArray(it, 0, it.size) } }.getOrNull()?.let {
            cancellation.check(); requireCurrent(record, photo.uri, stamp, resources)
            return@work it
        }
        cancellation.check()
        val imported = storage.import(photo.uri)
        try {
            cancellation.check()
            val result = renderer.perform(Work.Preview(imported, settings, false, NativeProcessor.AUTO,
                edge = EditedPhotoPreviewKey.EDGE), cancellation) as WorkResult.Preview
            cancellation.check()
            requireCurrent(record, photo.uri, stamp, resources)
            val bytes = encode(result.pair.result)
            runCatching { cache.write(key, bytes) }
            result.pair.result
        } finally {
            if (rendererDelegate.isInitialized()) renderer.releaseDecodedRaster()
            imported.file.delete()
        }
    }

    suspend fun accept(photo: ImportedPhoto, renderedSettings: EditSettings, image: Bitmap) = work { cancellation ->
        val record = store.readState(photo.identity)
        val saved = record.settings ?: return@work
        if (renderedSettings.normalizedWhiteBalance() != saved.normalizedWhiteBalance()) return@work
        if (!EditedPhotoPreviewKey.isEdited(saved, photo.inputKind)) return@work
        photo.validateOriginal?.invoke()
        val stamp = OriginalPhotoSource.fingerprint(context.contentResolver, photo.uri)
        val resources = resources(saved)
        cancellation.check()
        requireCurrent(record, photo.uri, stamp, resources)
        val bytes = encode(image)
        requireCurrent(record, photo.uri, stamp, resources)
        cache.write(key(photo.identity, stamp, saved, resources), bytes)
        completed.tryEmit(photo.identity)
    }

    private fun EditSettings.normalizedWhiteBalance(): EditSettings {
        val synchronized = synchronizeHDR().canonicalZeros()
        return if (!synchronized.isHDREditing && !synchronized.customWb)
            synchronized.copy(temperature = 6500f, tint = if (synchronized.recipeID == null) 0f else synchronized.tint)
        else synchronized
    }
    private fun resources(settings: EditSettings): String {
        val files = mutableListOf<File>()
        if (settings.isHDREditing) {
            val hdr = requireNotNull(settings.hdr)
            if (!hdr.lookSettings.assetIsAvailable(storage.hdrLookDirectory)) throw IOException("HDR look is unavailable")
            hdr.lookSettings.asset(storage.hdrLookDirectory)?.let(files::add)
            hdr.cameraDevelopment?.cameraProfile?.let { files += it.asset(storage.hdrCameraProfileDirectory) }
        } else storage.lookPath(settings)?.let(files::add)
        return files.joinToString(":") { file ->
            file.inputStream().use { input ->
                val digest = MessageDigest.getInstance("SHA-256")
                val buffer = ByteArray(64 * 1024)
                while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) }
                digest.digest().joinToString("") { "%02x".format(it) }
            }
        }
    }
    private fun key(identity: PhotoIdentity, stamp: String, settings: EditSettings, resources: String) =
        EditedPhotoPreviewKey.create("${identity.value.length}:${identity.value}$stamp", settings, resources, rendererVersion = BuildConfig.VERSION_CODE)
    private fun requireCurrent(record: PhotoEditState, uri: android.net.Uri, stamp: String, resources: String) {
        if (!record.sameAs(store.readState(record.identity)) || OriginalPhotoSource.fingerprint(context.contentResolver, uri) != stamp ||
            resources(record.settings ?: throw AdjustmentOperationExpiredException()) != resources) throw AdjustmentOperationExpiredException()
    }
    private fun encode(image: Bitmap): ByteArray {
        val scale = minOf(1f, EditedPhotoPreviewKey.EDGE.toFloat() / maxOf(image.width, image.height))
        val small = if (scale < 1) Bitmap.createScaledBitmap(image, (image.width * scale).toInt().coerceAtLeast(1),
            (image.height * scale).toInt().coerceAtLeast(1), true) else image
        try {
            return ByteArrayOutputStream().use { output ->
                check(small.compress(Bitmap.CompressFormat.JPEG, 88, output)); output.toByteArray()
            }
        } finally { if (small !== image) small.recycle() }
    }
    private suspend fun <T> work(action: (RenderCancellation) -> T): T = suspendCancellableCoroutine { continuation ->
        val cancellation = RenderCancellation()
        synchronized(this) {
        if (closed.get()) { continuation.cancel(); return@suspendCancellableCoroutine }
        requests += cancellation
        continuation.invokeOnCancellation { cancellation.cancel() }
        try {
            executor.execute {
                try {
                    cancellation.check()
                    val value = action(cancellation)
                    if (continuation.isActive) continuation.resume(value)
                } catch (error: Throwable) { if (continuation.isActive) continuation.resumeWithException(error) }
                finally { requests -= cancellation }
            }
        } catch (error: Throwable) {
            requests -= cancellation
            if (continuation.isActive) continuation.resumeWithException(error)
        }
        }
    }
    @Synchronized override fun close() {
        if (!closed.compareAndSet(false, true)) return
        requests.forEach(RenderCancellation::cancel)
        executor.execute {
            try {
                if (rendererDelegate.isInitialized()) renderer.close()
                if (storageDelegate.isInitialized()) storage.close()
            } finally { executor.shutdown() }
        }
    }
    companion object {
        private val completed = MutableSharedFlow<PhotoIdentity>(extraBufferCapacity = 64, onBufferOverflow = BufferOverflow.DROP_OLDEST)
        val ready = completed.asSharedFlow()
        private val busyOwners = mutableSetOf<String>()
        private val busy = MutableStateFlow(false)
        val foregroundBusy = busy.asStateFlow()
        @Synchronized fun setForegroundBusy(owner: String, value: Boolean) {
            if (value) busyOwners += owner else busyOwners -= owner
            busy.value = busyOwners.isNotEmpty()
        }
    }
}
