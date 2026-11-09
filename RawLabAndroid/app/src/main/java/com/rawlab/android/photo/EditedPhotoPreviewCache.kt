package com.rawlab.android.photo

import com.rawlab.android.editor.EditorAdjustmentRules
import com.rawlab.android.editor.EditorResetContext
import com.rawlab.android.editor.EditorResetScope
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.StructuredSettingsCodec
import com.rawlab.android.settings.sourceDefaultSettings
import java.io.File
import java.nio.ByteBuffer
import java.nio.file.Files
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.StandardCopyOption
import java.security.MessageDigest

internal enum class PhotoEditFilter {
    ALL, EDITED, UNEDITED;
    fun includes(edited: Boolean?): Boolean = when (this) {
        ALL -> true
        EDITED -> edited == true
        UNEDITED -> edited == false
    }
}

internal object EditedPhotoPreviewKey {
    const val EDGE = 512
    fun isEdited(settings: EditSettings?, input: PhotoInputKind): Boolean = settings != null &&
        EditorAdjustmentRules.isModified(EditorResetScope.All, settings,
            EditorResetContext(input, sourceDefaultSettings(false, inputKind = input)))

    fun create(source: String, settings: EditSettings, resources: String, edge: Int = EDGE, rendererVersion: Int = 1): String {
        val hash = MessageDigest.getInstance("SHA-256")
        for (part in listOf("edited-photo-preview-v1:$rendererVersion", source,
            StructuredSettingsCodec.encode(settings, "photo_edit"), resources, edge.toString())) {
            val bytes = part.toByteArray(Charsets.UTF_8)
            hash.update(ByteBuffer.allocate(8).putLong(bytes.size.toLong()).array()); hash.update(bytes)
        }
        return hash.digest().joinToString("") { "%02x".format(it) }
    }
}

internal class EditedPhotoPreviewCache(private val directory: File, private val maximumEntries: Int = 256,
    private val maximumBytes: Long = 64 * 1024 * 1024) {
    @Synchronized fun read(key: String): ByteArray? = location(key).takeIf { it.isFile }?.readBytes()
    @Synchronized fun write(key: String, data: ByteArray) {
        if (data.size > maximumBytes) return
        check(directory.isDirectory || directory.mkdirs())
        val target = location(key)
        val temporary = File.createTempFile("preview-", ".tmp", directory)
        try {
            temporary.outputStream().use { it.write(data); it.fd.sync() }
            try { Files.move(temporary.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING) }
            catch (_: AtomicMoveNotSupportedException) { Files.move(temporary.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING) }
        } finally { temporary.delete() }
        val entries = directory.listFiles().orEmpty().filter { it.isFile && it.extension == "preview" }
            .sortedWith(compareBy<File> { it == target }.thenBy { it.lastModified() }.thenBy { it.name })
        var count = entries.size
        var bytes = entries.sumOf { it.length() }
        for (file in entries) {
            if (count <= maximumEntries.coerceAtLeast(1) && bytes <= maximumBytes) break
            val length = file.length()
            if (file.delete()) { count--; bytes -= length }
        }
    }
    private fun location(key: String): File {
        require(key.length == 64 && key.all { it in '0'..'9' || it in 'a'..'f' })
        return File(directory, "$key.preview")
    }
}
