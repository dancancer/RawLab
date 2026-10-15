package com.rawlab.android

import android.content.ContentUris
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.os.Process
import android.provider.MediaStore
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.rules.ExternalResource
import java.io.File
import java.util.Properties
import java.util.UUID

/** 只清理本测试记录的资源；active native 必须先随进程退出，不能靠 cancel 假装已停止。 */
@Suppress("DEPRECATION")
internal class BatchTestCleanup(private val context: Context) : ExternalResource() {
    private val manifest = File(context.filesDir, "batch-gpu-test-cleanup.properties")
    private val journalRoot = File(context.filesDir, "RawLab/BatchJobs")
    private var owned = Properties()

    override fun before() { recover() }

    fun begin(id: String) {
        check(!manifest.exists()) { "Previous batch test has not been cleaned" }
        UUID.fromString(id)
        owned = Properties().apply {
            setProperty("pid", Process.myPid().toString())
            setProperty("fixture", id)
            setProperty("job", id)
            setProperty("existingRenders", renderFiles().joinToString(",") { it.name })
        }
        persist()
    }

    fun trackJob(id: String) { UUID.fromString(id); owned.setProperty("job", id); persist() }
    fun trackLookImport(name: String) {
        check(name == "batch-gpu-${owned.getProperty("fixture")}.rlook")
        owned.setProperty("lookSource", name)
        persist()
    }
    fun targetName(id: String) = "batch-gpu-$id.dng"

    fun finish(active: Boolean, cancel: () -> Unit, close: () -> Unit,
               abort: () -> Nothing = ::abortProcess) {
        if (active) {
            cancel()
            abort()
        }
        close()
        clean()
    }

    fun recover() {
        if (!manifest.isFile) return
        owned = Properties().also { manifest.inputStream().use(it::load) }
        val oldPid = owned.getProperty("pid").toInt()
        check(!File("/proc/$oldPid").exists()) { "Batch test owner $oldPid is still alive; refusing cleanup" }
        status("recover oldPid=$oldPid newPid=${Process.myPid()}")
        clean()
    }

    private fun clean() {
        val fixture = owned.getProperty("fixture").also { UUID.fromString(it) }
        val job = owned.getProperty("job").also { UUID.fromString(it) }
        val journal = BatchJournal(journalRoot)
        val resolver = context.contentResolver
        // 先回读最终 checkpoint；唯一名字还覆盖 insert 已成功但 checkpoint 尚未写入的窗口。
        val outputs = journal.load(job)?.rows.orEmpty().mapNotNull { it.outputUri }
            .map { ContentUris.parseId(Uri.parse(it)) }.toMutableSet()
        val images = MediaStore.setIncludePending(MediaStore.Images.Media.EXTERNAL_CONTENT_URI)
        resolver.query(images, arrayOf(MediaStore.Images.Media._ID),
            "${MediaStore.Images.Media.RELATIVE_PATH} = ? AND ${MediaStore.Images.Media.DISPLAY_NAME} LIKE ?",
            arrayOf("Pictures/RawLab/", "batch-gpu-$fixture%"), null)?.use { cursor ->
            while (cursor.moveToNext()) outputs += cursor.getLong(0)
        }
        fun exists(id: Long): Boolean = requireNotNull(resolver.query(images, arrayOf(MediaStore.Images.Media._ID),
            "${MediaStore.Images.Media._ID} = ?", arrayOf(id.toString()), null)).use { it.moveToFirst() }
        outputs.forEach { id ->
            if (exists(id)) resolver.delete(ContentUris.withAppendedId(images, id), null, null)
            check(!exists(id)) { "Batch test output still exists: $id" }
        }
        journal.discard(job)
        journal.discard(fixture)
        journalRoot.listFiles().orEmpty().filter {
            it.extension == "tmp" && (it.name.startsWith("$job.") || it.name.startsWith("$fixture."))
        }.forEach { check(it.delete()) }
        owned.getProperty("lookSource")?.let { name ->
            val library = LookLibrary(File(context.filesDir, "looks"))
            library.list().filter { it.originalName == name }.forEach { library.remove(it.id) }
            check(library.list().none { it.originalName == name })
        }
        val existing = owned.getProperty("existingRenders", "").split(',').toSet()
        renderFiles().filterNot { it.name in existing }.forEach { check(it.delete()) }
        check(!File(journalRoot, job).exists() && !File(journalRoot, fixture).exists())
        check(!File(journalRoot, "$job.properties").exists() && !File(journalRoot, "$fixture.properties").exists())
        check(manifest.delete()) { "Cannot remove batch test cleanup manifest" }
        status("cleanupComplete fixture=$fixture job=$job outputs=${outputs.size}")
    }

    private fun persist() {
        val temporary = File(manifest.path + ".tmp")
        temporary.outputStream().use { owned.store(it, null) }
        check(temporary.renameTo(manifest)) { "Cannot checkpoint batch test ownership" }
    }

    private fun renderFiles() = context.filesDir.listFiles().orEmpty().filter { it.name.startsWith("render-") && it.isFile }

    private fun abortProcess(): Nothing {
        status("cleanupDeferred=true active=true pid=${Process.myPid()} fixture=${owned.getProperty("fixture")} job=${owned.getProperty("job")}; terminating failed test process")
        Process.killProcess(Process.myPid())
        throw AssertionError("Active native work: instrumentation must not continue")
    }

    private fun status(message: String) {
        InstrumentationRegistry.getInstrumentation().sendStatus(2, Bundle().apply { putString("stream", "BATCH_GPU $message\n") })
    }
}
