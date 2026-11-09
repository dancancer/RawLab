package com.rawlab.android.camera

import android.content.ContentUris
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.exifinterface.media.ExifInterface
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.photo.MediaPhoto
import com.rawlab.android.photo.MediaPhotoAccess
import com.rawlab.android.photo.MediaPhotoLibrary
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.EditStore
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@SdkSuppress(minSdkVersion = 29)
class CameraMediaLibraryTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val resolver get() = context.contentResolver
    private fun hash(file: File) = MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }
    private fun withStore(test: (File, CameraImportDestination, MediaPhotoLibrary, CameraImportStore) -> Unit) {
        val token = UUID.randomUUID().toString()
        val root = File(context.cacheDir, "camera-media-$token").apply { mkdirs() }
        val destination = CameraImportDestination("RawLab/Tests/$token")
        val library = MediaPhotoLibrary(context)
        val store = CameraImportStore(File(root, "jobs"), File(root, "partial"), library, CameraCaptureDateReader::read)
        try { test(root, destination, library, store) }
        finally {
            @Suppress("DEPRECATION")
            val collection = MediaStore.setIncludePending(MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY))
            val uris = resolver.query(collection, arrayOf(MediaStore.Images.Media._ID), "${MediaStore.Images.Media.RELATIVE_PATH} LIKE ?",
                arrayOf("Pictures/${destination.directory}/%"), null)?.use { cursor ->
                buildList { while (cursor.moveToNext()) add(ContentUris.withAppendedId(MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), cursor.getLong(0))) }
            }.orEmpty()
            for (uri in uris) {
                resolver.delete(uri, null, null)
                context.getSharedPreferences("camera-media-sources", 0).edit().remove(uri.toString()).commit()
            }
            root.deleteRecursively()
        }
    }
    private fun jpeg(root: File, color: Int, original: String?, modified: String? = null): File {
        val file = File(root, "${UUID.randomUUID()}.jpg")
        val bitmap = Bitmap.createBitmap(12, 8, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(color)
        file.outputStream().use { assertTrue(bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it)) }; bitmap.recycle()
        ExifInterface(file).apply {
            setAttribute(ExifInterface.TAG_DATETIME_ORIGINAL, original)
            setAttribute(ExifInterface.TAG_DATETIME, modified)
            if (original != null) setAttribute(ExifInterface.TAG_OFFSET_TIME_ORIGINAL, "+14:00")
            saveAttributes()
        }
        return file
    }
    private fun save(store: CameraImportStore, destination: CameraImportDestination, file: File): CameraImportJob {
        val job = store.create("fixture", listOf(CameraPhoto(UUID.randomUUID().toString(), "DSC00001.JPG", file.length(), 0)), destination)
        file.copyTo(store.partial(job.id), overwrite = true)
        return store.publish(job, 0, store.partial(job.id), hash(file), CameraTransferPermit())
    }
    private fun bytes(uri: String) = resolver.openInputStream(Uri.parse(uri))!!.use { it.readBytes() }

    @Test fun unrelatedMediaPickerUriKeepsTheExternalProviderRoute() {
        val picker = Uri.parse("content://media/picker/0/com.android.providers.media.photopicker/media/123")
        assertNull(MediaPhotoLibrary(context).resolveKnown(picker))
    }

    @Test fun captureDatePublishesOriginalBytesAndMissingDateUsesUnknown() = withStore { root, destination, library, store ->
        val original = jpeg(root, Color.RED, "2024:02:29 00:10:00", "2026:11:09 12:00:00")
        ExifInterface(original).apply { setLatLong(37.4, -122.0); saveAttributes() }
        val saved = save(store, destination, original).items.single().saved!!
        assertEquals("Pictures/${destination.directory}/2024-02-29/", saved.relativePath)
        assertTrue(saved.uri.startsWith("content://media/external_primary/images/media/"))
        assertFalse(library.inspect(saved.uri)!!.pending)
        assertArrayEquals(original.readBytes(), bytes(saved.uri))
        val unknown = save(store, destination, jpeg(root, Color.GREEN, null, "2026:11:09 12:00:00")).items.single()
        assertEquals("Pictures/${destination.directory}/Unknown date/", unknown.saved!!.relativePath)
        assertNull(unknown.captureDay)
    }

    @Test fun aliasesAndDirectHandoffReuseOneOriginalAndItsEdits() = withStore { root, destination, _, store ->
        val file = jpeg(root, Color.BLUE, "2026:10:22 18:28:03")
        val job = save(store, destination, file)
        val uri = Uri.parse(job.items.single().saved!!.uri)
        val alias = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, ContentUris.parseId(uri))
        val privateOriginals = File(context.filesDir, "system-photos").listFiles().orEmpty().map { it.name }.toSet()
        PhotoStorage(context).use { storage ->
            assertEquals(uri, storage.retainSystemPhoto(alias))
            val direct = storage.import(uri)
            val fromAlias = storage.import(alias)
            assertEquals(direct.identity, fromAlias.identity)
            val edits = EditStore(File(root, "edits"))
            edits.save(direct.identity, EditSettings(exposure = .75f))
            assertEquals(.75f, edits.load(fromAlias.identity)!!.exposure, .001f)
            assertEquals(uri, storage.album().single { it.uri == uri }.uri)
        }
        assertEquals(privateOriginals, File(context.filesDir, "system-photos").listFiles().orEmpty().map { it.name }.toSet())
        val duplicate = save(store, destination, file)
        assertTrue(duplicate.items.single().duplicate)
        assertEquals(uri.toString(), duplicate.items.single().saved!!.uri)
    }

    @Test fun sameNameDifferentBytesAreKeptAndExternalChangesAreRejected() = withStore { root, destination, library, store ->
        val red = jpeg(root, Color.RED, "2026:10:22 12:00:00")
        val green = jpeg(root, Color.GREEN, "2026:10:22 12:00:00")
        val first = save(store, destination, red)
        val second = save(store, destination, green)
        val a = first.items.single().saved!!; val b = second.items.single().saved!!
        assertNotEquals(a.uri, b.uri); assertNotEquals(a.displayName, b.displayName)
        assertArrayEquals(red.readBytes(), bytes(a.uri)); assertArrayEquals(green.readBytes(), bytes(b.uri))
        resolver.openOutputStream(Uri.parse(a.uri), "wt")!!.use { it.write(green.readBytes()) }
        assertThrows(IOException::class.java) { store.savedUris(first) }
        assertThrows(IOException::class.java) { library.resolveKnown(Uri.parse(a.uri)) }
        resolver.delete(Uri.parse(b.uri), null, null)
        assertThrows(IOException::class.java) { store.savedUris(second) }
    }

    @Test fun fullyWrittenPendingRowIsRecoveredWithoutRepublishingAnotherItem() = withStore { root, destination, library, _ ->
        val interrupted = object : MediaPhotoAccess by library {
            override fun publish(uri: String): MediaPhoto = throw IOException("Interrupted before publication")
        }
        val store = CameraImportStore(File(root, "jobs"), File(root, "partial"), interrupted, CameraCaptureDateReader::read)
        assertThrows(IOException::class.java) { save(store, destination, jpeg(root, Color.RED, "2026:10:22 12:00:00")) }
        val before = org.json.JSONObject(File(root, "jobs").listFiles()!!.single { it.extension == "json" }.readText())
            .getJSONArray("items").getJSONObject(0).getJSONObject("prepared").getString("uri")
        assertTrue(library.inspect(before)!!.pending)
        assertFalse(PhotoStorage(context).use { it.album() }.any { it.uri.toString() == before })
        val reopened = CameraImportStore(File(root, "jobs"), File(root, "partial"), library, CameraCaptureDateReader::read)
        val recovered = reopened.load().single()
        assertEquals(CameraJobStatus.COMPLETE, recovered.status)
        assertEquals(before, recovered.items.single().saved!!.uri)
        assertFalse(library.inspect(before)!!.pending)
    }

    @Test fun anotherApplicationUidReadsExactlyThePublishedOriginal() = withStore { root, destination, _, store ->
        // 此样片不带 GPS；系统可能对其他 UID 的定位元数据脱敏，不能将其误判为原件损坏。
        val file = jpeg(root, Color.YELLOW, "2026:10:22 12:00:00")
        val uri = Uri.parse(save(store, destination, file).items.single().saved!!.uri)
        val action = context.packageName + ".MEDIA_READ_" + UUID.randomUUID().toString()
        val complete = CountDownLatch(1)
        var result: Intent? = null
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) { result = intent; complete.countDown() }
        }
        if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(receiver, IntentFilter(action), Context.RECEIVER_EXPORTED)
        else context.registerReceiver(receiver, IntentFilter(action))
        try {
            context.startActivity(Intent().setClassName(InstrumentationRegistry.getInstrumentation().context.packageName,
                CameraMediaReaderActivity::class.java.name).setDataAndType(uri, "image/jpeg").apply {
                clipData = ClipData.newRawUri("test", uri)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                putExtra("reportAction", action); putExtra("reportPackage", context.packageName)
            })
            assertTrue("The independent media reader must finish", complete.await(15, TimeUnit.SECONDS))
            assertNull(result!!.getStringExtra("error"))
            assertNotEquals(context.applicationInfo.uid, result!!.getIntExtra("uid", -1))
            assertEquals(file.length(), result!!.getLongExtra("bytes", -1))
            assertEquals(hash(file), result!!.getStringExtra("sha256"))
        } finally { context.unregisterReceiver(receiver); context.revokeUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
    }
}
