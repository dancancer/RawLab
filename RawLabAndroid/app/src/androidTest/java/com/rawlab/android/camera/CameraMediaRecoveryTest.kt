package com.rawlab.android.camera

import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import android.os.Process
import androidx.exifinterface.media.ExifInterface
import androidx.test.filters.SdkSuppress
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.photo.MediaPhoto
import com.rawlab.android.photo.MediaPhotoAccess
import com.rawlab.android.photo.MediaPhotoLibrary
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.UUID

/** 仅由 camera-media-recovery.sh 显式分阶段运行；默认设备套件跳过这些进程终止步骤。 */
@SdkSuppress(minSdkVersion = 29)
class CameraMediaRecoveryTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val manifest get() = File(context.filesDir, "camera-media-recovery-test.json")

    @Test fun stagePendingBeforeProcessDeath() { requirePhase("stage-pending"); stage(false) }
    @Test fun stagePublishedBeforeProcessDeath() { requirePhase("stage-published"); stage(true) }

    private fun requirePhase(phase: String) = assumeTrue("Run with explicit cameraRecoveryPhase=$phase",
        InstrumentationRegistry.getArguments().getString("cameraRecoveryPhase") == phase)

    private fun stage(published: Boolean) {
        assertFalse("A previous recovery fixture needs cleanup", manifest.exists())
        val token = UUID.randomUUID().toString()
        val root = File(context.filesDir, "camera-media-recovery-$token").apply { mkdirs() }
        val source = File(root, "source.jpg")
        val bitmap = Bitmap.createBitmap(24, 16, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(Color.CYAN)
        source.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it) }; bitmap.recycle()
        ExifInterface(source).apply { setAttribute(ExifInterface.TAG_DATETIME_ORIGINAL, "2026:10:22 18:28:03"); saveAttributes() }
        val digest = MessageDigest.getInstance("SHA-256").digest(source.readBytes()).joinToString("") { "%02x".format(it) }
        val library = MediaPhotoLibrary(context)
        val interrupted = object : MediaPhotoAccess by library {
            override fun publish(uri: String): MediaPhoto {
                if (published) library.publish(uri)
                assertEquals(!published, library.inspect(uri)!!.pending)
                val record = JSONObject().put("root", root.name).put("uri", uri).put("pid", Process.myPid())
                    .put("digest", digest).put("published", published)
                FileOutputStream(manifest).use { it.write(record.toString().toByteArray()); it.fd.sync() }
                Process.killProcess(Process.myPid())
                throw IllegalStateException("Expected process termination")
            }
        }
        val store = CameraImportStore(File(root, "jobs"), File(root, "partial"), interrupted, CameraCaptureDateReader::read)
        val job = store.create("fixture", listOf(CameraPhoto(token, "RECOVERY.JPG", source.length(), 0)),
            CameraImportDestination("RawLab/Tests/$token"))
        source.copyTo(store.partial(job.id))
        store.publish(job, 0, store.partial(job.id), digest, CameraTransferPermit())
        fail("Expected process termination")
    }

    @Test fun recoverInNewProcess() {
        requirePhase("recover")
        val record = JSONObject(manifest.readText())
        assertNotEquals(record.getInt("pid"), Process.myPid())
        assertFalse("The previous fixture process must have exited", File("/proc/${record.getInt("pid")}").exists())
        val root = checkedRoot(record)
        val uri = record.getString("uri")
        try {
            val library = MediaPhotoLibrary(context)
            val store = CameraImportStore(File(root, "jobs"), File(root, "partial"), library, CameraCaptureDateReader::read)
            val recovered = store.load().single()
            assertEquals(CameraJobStatus.COMPLETE, recovered.status)
            assertEquals(uri, store.savedUris(recovered).single())
            assertFalse(library.inspect(uri)!!.pending)
            assertArrayEquals(File(root, "source.jpg").readBytes(), library.open(uri).use { it.readBytes() })
            assertTrue(File(root, "partial").listFiles().orEmpty().isEmpty())
        } finally { cleanup(record) }
    }

    @Test fun cleanupRecoveryFixture() {
        requirePhase("cleanup")
        if (manifest.exists()) cleanup(JSONObject(manifest.readText()))
    }

    private fun checkedRoot(record: JSONObject): File {
        val name = record.getString("root")
        require(name.matches(Regex("camera-media-recovery-[0-9a-f-]{36}")))
        return File(context.filesDir, name)
    }
    private fun cleanup(record: JSONObject) {
        val root = checkedRoot(record)
        val uri = record.getString("uri")
        val sources = context.getSharedPreferences("camera-media-sources", 0)
        val media = MediaPhotoLibrary(context).inspect(uri)
        if (media != null) {
            require(media.displayName == "RECOVERY.JPG" &&
                media.relativePath == "Pictures/RawLab/Tests/${root.name.removePrefix("camera-media-recovery-")}/2026-10-22/")
            require(sources.getString(uri, null) == "${File(root, "source.jpg").length()}:${record.getString("digest")}")
            context.contentResolver.delete(Uri.parse(uri), null, null)
        }
        sources.edit().remove(uri).commit()
        root.deleteRecursively()
        manifest.delete()
    }
}
