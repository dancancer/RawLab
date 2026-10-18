package com.rawlab.android.batch.publish

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import com.rawlab.android.R
import com.rawlab.android.batch.BatchJob
import com.rawlab.android.batch.BatchTarget
import com.rawlab.android.batch.asBatchOutputFailure
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.photo.BatchGlobalFailure
import com.rawlab.android.photo.BatchPublicationUncertain
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.settings.EditSettings
import java.io.File
import java.io.IOException

// ============================================================================
//  批量输出：临时渲染、发布与失败清理
// ============================================================================

internal class BatchOutputPublisher(
    private val context: Context,
    private val storage: PhotoStorage,
    private val processor: NativeProcessor,
    private val job: BatchJob,
    private val destination: Uri?,
) {
    private val resolver = context.contentResolver

    fun render(target: BatchTarget, settings: EditSettings): File {
        val temporary = File.createTempFile("render-", job.outputFormat.suffix, context.filesDir)
        try {
            val backend = processor.export(target.sourceFile, job.source.lookFile, settings,
                temporary, job.outputFormat, job.outputLongEdge, target.inputKind)
            android.util.Log.i("RawLabBatch", "job=${job.id} exportBackend=$backend")
            return temporary
        } catch (error: Throwable) {
            temporary.delete()
            throw asBatchOutputFailure(error)
        }
    }

    fun publish(rendered: File, outputName: String, checkpoint: (String) -> Unit) {
        try {
            if (destination == null) {
                if (android.os.Build.VERSION.SDK_INT < 29) throw BatchGlobalFailure(AppStrings.text(R.string.message_saving_to_the_photo_gallery_requires_android))
                storage.saveAlbum(rendered, job.outputFormat, outputName) { checkpoint(it.toString()) }
            } else {
                saveDocumentChild(destination, rendered, outputName) { checkpoint(it.toString()) }
            }
        } catch (error: BatchPublicationUncertain) {
            throw error
        } catch (error: Exception) {
            throw BatchGlobalFailure(AppStrings.format(R.string.message_output_storage_failed, error.message.orEmpty()), error)
        }
    }

    private fun saveDocumentChild(tree: Uri, file: File, name: String, onCreated: (Uri) -> Unit): Uri {
        val parent = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val names = mutableSetOf<String>()
        resolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) names += cursor.getString(0).lowercase()
        } ?: throw IOException(AppStrings.text(R.string.message_unable_to_read_output_directory))
        var candidate = name
        var suffix = 2
        while (candidate.lowercase() in names) candidate = "${name.substringBeforeLast('.')}-${suffix++}.${name.substringAfterLast('.')}"
        val child = DocumentsContract.createDocument(resolver, parent, job.outputFormat.mimeType, candidate)
            ?: throw IOException("Cannot create output document")
        try {
            onCreated(child)
            val output = resolver.openOutputStream(child, "wt") ?: throw IOException("Cannot open output document")
            output.use { outputStream -> file.inputStream().use { it.copyTo(outputStream) } }
            return child
        } catch (error: Exception) {
            if (!runCatching { DocumentsContract.deleteDocument(resolver, child) }.getOrDefault(false)) throw BatchPublicationUncertain(AppStrings.text(R.string.message_writing_was_incomplete_and_cleanup_failed_check), error)
            throw BatchGlobalFailure(AppStrings.format(R.string.message_unable_to_write_to_output_directory, error.message.toString()), error)
        }
    }
}
