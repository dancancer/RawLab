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

internal data class PreviewCacheEntry(val key: String, val size: Long, val lastModified: Long)

internal interface PreviewCacheFileSystem {
    fun listEntries(directory: File): List<PreviewCacheEntry>
    fun readBytes(file: File): ByteArray?
    fun writeAtomic(directory: File, target: File, data: ByteArray)
    fun delete(file: File): Boolean

    object Default : PreviewCacheFileSystem {
        override fun listEntries(directory: File): List<PreviewCacheEntry> {
            if (!directory.isDirectory) return emptyList()
            return directory.listFiles().orEmpty()
                .asSequence()
                .filter { it.isFile && it.extension == "preview" }
                .map { PreviewCacheEntry(it.nameWithoutExtension, it.length(), it.lastModified()) }
                .sortedWith(compareBy<PreviewCacheEntry> { it.lastModified }.thenBy { it.key })
                .toList()
        }

        override fun readBytes(file: File): ByteArray? = file.takeIf { it.isFile }?.readBytes()

        override fun writeAtomic(directory: File, target: File, data: ByteArray) {
            check(directory.isDirectory || directory.mkdirs())
            val temporary = File.createTempFile("preview-", ".tmp", directory)
            try {
                temporary.outputStream().use { it.write(data) }
                try { Files.move(temporary.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING) }
                catch (_: AtomicMoveNotSupportedException) { Files.move(temporary.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING) }
            } finally { temporary.delete() }
        }

        override fun delete(file: File): Boolean = file.delete() || !file.exists()
    }
}

internal class EditedPhotoPreviewCache(
    private val directory: File,
    private val maximumEntries: Int = 256,
    private val maximumBytes: Long = 64 * 1024 * 1024,
    private val fileSystem: PreviewCacheFileSystem = PreviewCacheFileSystem.Default
) {
    private val index = LinkedHashMap<String, Long>(16, 0.75f, true)
    private var totalBytes = 0L
    private var loaded = false

    private fun ensureLoaded() {
        if (loaded) return
        for (entry in fileSystem.listEntries(directory)) {
            if (isValidKey(entry.key)) {
                val previous = index.put(entry.key, entry.size)
                if (previous != null) totalBytes -= previous
                totalBytes += entry.size
            }
        }
        loaded = true
    }

    companion object {
        private val shared = HashMap<Pair<String, Int>, EditedPhotoPreviewCache>()

        // 生产默认缓存目录会被同进程的多个 EditedPhotoPreviews 实例共用（EditorViewModel 常驻实例 + AlbumScreen remember 实例），
        // 索引与淘汰预算必须进程内唯一，否则跨实例写入假未命中（重复重渲 RAW）且容量上限翻倍；锁共享表本身而非各实例。
        // 单测继续用直接构造（自定义 directory/fileSystem）保持相互隔离。
        @Synchronized
        fun shared(directory: File, maximumEntries: Int = 256, maximumBytes: Long = 64 * 1024 * 1024,
                   fileSystem: PreviewCacheFileSystem = PreviewCacheFileSystem.Default): EditedPhotoPreviewCache =
            shared.getOrPut(directory.canonicalPath to System.identityHashCode(fileSystem)) {
                EditedPhotoPreviewCache(directory, maximumEntries, maximumBytes, fileSystem)
            }
    }

    @Synchronized fun read(key: String): ByteArray? {
        val target = location(key)
        ensureLoaded()
        val size = index[key] ?: return null
        val bytes = fileSystem.readBytes(target)
        if (bytes == null) {
            index.remove(key)
            totalBytes -= size
        }
        return bytes
    }

    @Synchronized fun write(key: String, data: ByteArray) {
        if (data.size > maximumBytes) return
        val target = location(key)
        ensureLoaded()
        fileSystem.writeAtomic(directory, target, data)
        val size = data.size.toLong()
        val previous = index.put(key, size)
        if (previous != null) totalBytes -= previous
        totalBytes += size
        val entryLimit = maximumEntries.coerceAtLeast(1)
        if (index.size <= entryLimit && totalBytes <= maximumBytes) return
        val iterator = index.entries.iterator()
        while (iterator.hasNext() && (index.size > entryLimit || totalBytes > maximumBytes)) {
            val (evictKey, evictSize) = iterator.next()
            if (fileSystem.delete(location(evictKey))) {
                iterator.remove()
                totalBytes -= evictSize
            }
        }
    }

    private fun location(key: String): File {
        require(isValidKey(key))
        return File(directory, "$key.preview")
    }

    private fun isValidKey(key: String): Boolean =
        key.length == 64 && key.all { it in '0'..'9' || it in 'a'..'f' }
}
