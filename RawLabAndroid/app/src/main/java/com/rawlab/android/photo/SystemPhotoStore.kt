package com.rawlab.android.photo

import com.rawlab.android.format.PhotoInputKind
import java.io.ByteArrayInputStream
import java.io.BufferedInputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.SequenceInputStream
import java.nio.file.FileSystemException
import java.nio.file.Files
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.StandardCopyOption
import java.security.DigestInputStream
import java.security.MessageDigest

internal class UnsupportedSystemPhoto : IOException()
internal class ChangedSystemPhoto : IOException()
internal class SystemPhotoTooLarge : IOException()
internal class SystemPhotoStorageFull : IOException()

internal data class RetainedCopiesSummary(
    val fileCount: Int,
    val totalBytes: Long,
)

internal object SystemPhotoStore {
    // 系统分享输入允许到 1 GiB，覆盖约 40MP、304 MiB 的相机 RAW，同时避免无限制占满应用空间。
    const val MAX_BYTES = 1024L * 1024L * 1024L
    private const val HEADER_BYTES = 64
    private val RETAINED_COPY_NAME = Regex("[0-9a-fA-F]{64}\\.(?:raw|x3f|jpg|png|heic|name)")

    @Synchronized
    fun retain(directory: File, input: InputStream, name: String, mime: String?,
        temporaryDirectory: File = directory, expectedBytes: Long = -1L): File {
        // 只预读完整头部；大缓冲会在未知内容被拒绝前无谓吞掉几十 KiB。
        val buffered = BufferedInputStream(input, HEADER_BYTES)
        val header = readHeader(buffered)
        val detected = detect(header) ?: throw UnsupportedSystemPhoto()
        val declaredRaw = com.rawlab.android.format.RawFiles.accepts(name, mime)
        val declaredRaster = com.rawlab.android.format.RasterFiles.accepts(name, mime)
        if (declaredRaw && declaredRaster) throw UnsupportedSystemPhoto()
        val declared = when {
            declaredRaw -> PhotoInputKind.RAW
            declaredRaster -> PhotoInputKind.RASTER
            else -> null
        }
        if (declared != null && declared != detected.kind) throw UnsupportedSystemPhoto()
        // TIFF 既可能是普通扫描图，也可能是 RAW；没有扩展名或 RAW MIME 时不能猜测。
        if (detected.requiresRawDeclaration && declared != PhotoInputKind.RAW) throw UnsupportedSystemPhoto()
        if (expectedBytes > MAX_BYTES) throw SystemPhotoTooLarge()

        directory.mkdirs()
        temporaryDirectory.mkdirs()
        if (!directory.isDirectory || !temporaryDirectory.isDirectory) throw SystemPhotoStorageFull()
        if (expectedBytes >= 0 && directory.usableSpace < expectedBytes) throw SystemPhotoStorageFull()
        val digest = MessageDigest.getInstance("SHA-256")
        val temporary = try {
            val replay = SequenceInputStream(ByteArrayInputStream(header), buffered)
            WorkingCopy.import(temporaryDirectory, DigestInputStream(replay, digest), safeName(name),
                maxBytes = MAX_BYTES, expectedBytes = expectedBytes)
        } catch (_: WorkingCopyTooLarge) {
            throw SystemPhotoTooLarge()
        } catch (_: WorkingCopyStorageFull) {
            throw SystemPhotoStorageFull()
        }
        try {
            val hash = digest.digest().toHex()
            val destination = File(directory, "$hash.${detected.suffix}")
            if (destination.exists()) {
                validate(destination)
            } else {
                if (directory.usableSpace < temporary.length()) throw SystemPhotoStorageFull()
                moveToStore(temporary, destination)
            }
            writeOriginalName(directory, hash, safeName(name))
            return destination
        } finally {
            temporary.delete()
        }
    }

    fun originalName(file: File): String? = File(file.parentFile, "${file.nameWithoutExtension}.name")
        .takeIf { it.isFile }?.readText()

    fun validate(file: File) {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                if (count > 0) digest.update(buffer, 0, count)
            }
        }
        if (digest.digest().toHex() != file.nameWithoutExtension) throw ChangedSystemPhoto()
    }

    /** 进程启动时只清理本功能拥有的缓存文件，避免误删其他缓存或批量任务。 */
    fun cleanupTemporary(directory: File, storeDirectory: File? = null) {
        directory.listFiles().orEmpty().forEach { file ->
            if (file.isFile && file.name.startsWith("raw-")) file.delete()
        }
        storeDirectory?.listFiles().orEmpty().forEach { file ->
            if (file.isFile && file.name.matches(Regex("raw-[^.]+\\.(?:input|x3f)")) ||
                file.isFile && file.name.matches(Regex("\\.[0-9a-fA-F]{64}\\.(?:raw|x3f|jpg|png|heic)\\.part")) ||
                file.isFile && file.name.matches(Regex("\\.[0-9a-fA-F]{64}\\.name\\.part"))) file.delete()
        }
    }

    @Synchronized
    fun inspectRetainedCopies(directory: File): RetainedCopiesSummary {
        val files = listRetainedCopyFiles(directory)
        return RetainedCopiesSummary(
            fileCount = files.size,
            totalBytes = files.sumOf { it.length() },
        )
    }

    /** 仅由用户在设置中手动触发，只删除本应用拥有的 `<sha256>.<ext>` 与 `<sha256>.name` 副本文件。 */
    @Synchronized
    fun clearRetainedCopies(directory: File): RetainedCopiesSummary {
        val files = listRetainedCopyFiles(directory)
        var deletedCount = 0
        var deletedBytes = 0L
        var firstError: IOException? = null
        for (file in files) {
            val length = file.length()
            try {
                Files.delete(file.toPath())
                deletedCount++
                deletedBytes += length
            } catch (error: IOException) {
                if (firstError == null) firstError = error else firstError.addSuppressed(error)
            }
        }
        if (firstError != null) throw firstError
        return RetainedCopiesSummary(fileCount = deletedCount, totalBytes = deletedBytes)
    }

    private fun listRetainedCopyFiles(directory: File): List<File> {
        if (!directory.exists()) return emptyList()
        if (Files.isSymbolicLink(directory.toPath()) || !directory.isDirectory) {
            throw IOException("System photo store is not a directory")
        }
        val root = directory.canonicalFile.toPath()
        val entries = directory.listFiles() ?: throw IOException("Cannot list system photo store")
        return entries.filter { entry ->
            RETAINED_COPY_NAME.matches(entry.name) &&
                !Files.isSymbolicLink(entry.toPath()) &&
                entry.isFile &&
                entry.canonicalFile.toPath().parent == root
        }
    }

    private data class Detected(val kind: PhotoInputKind, val suffix: String, val requiresRawDeclaration: Boolean = false)

    private fun detect(header: ByteArray): Detected? = when {
        header.startsWith("FOVb".toByteArray(Charsets.US_ASCII)) -> Detected(PhotoInputKind.RAW, "x3f")
        header.startsWith(byteArrayOf(-1, -40, -1)) -> Detected(PhotoInputKind.RASTER, "jpg")
        header.startsWith(byteArrayOf(-119, 80, 78, 71, 13, 10, 26, 10)) -> Detected(PhotoInputKind.RASTER, "png")
        isRaf(header) -> Detected(PhotoInputKind.RAW, "raw")
        isCrw(header) -> Detected(PhotoInputKind.RAW, "raw")
        isCr3(header) -> Detected(PhotoInputKind.RAW, "raw")
        isTiff(header) -> Detected(PhotoInputKind.RAW, "raw", requiresRawDeclaration = true)
        isSpecialRawTiff(header) -> Detected(PhotoInputKind.RAW, "raw")
        isHeif(header) -> Detected(PhotoInputKind.RASTER, "heic")
        else -> null
    }

    private fun isRaf(header: ByteArray): Boolean = header.startsWith("FUJIFILMCCD-RAW".toByteArray(Charsets.US_ASCII))

    private fun isCrw(header: ByteArray): Boolean {
        if (header.size < 14) return false
        val littleEndian = header.startsWith(byteArrayOf(73, 73, 26, 0, 0, 0))
        val bigEndian = header.startsWith(byteArrayOf(77, 77, 0, 0, 0, 0))
        return (littleEndian || bigEndian) &&
            (header.ascii(6, 8) == "HEAPCCDR" || header.ascii(8, 8) == "HEAPCCDR")
    }

    private fun isCr3(header: ByteArray): Boolean = header.size >= 12 && header.ascii(4, 4) == "ftyp" &&
        header.ascii(8, 4).trim() == "crx"

    private fun isTiff(header: ByteArray): Boolean = header.size >= 4 &&
        ((header[0] == 73.toByte() && header[1] == 73.toByte() &&
            ((header[2] == 42.toByte() && header[3] == 0.toByte()) || (header[2] == 43.toByte() && header[3] == 0.toByte()))) ||
            (header[0] == 77.toByte() && header[1] == 77.toByte() &&
                ((header[2] == 0.toByte() && header[3] == 42.toByte()) || (header[2] == 0.toByte() && header[3] == 43.toByte()))))

    private fun isSpecialRawTiff(header: ByteArray): Boolean =
        header.ascii(0, 4) in setOf("IIRO", "IIRS", "IIU\u0000") || header.ascii(0, 4) == "\u0000MRM"

    private fun isHeif(header: ByteArray): Boolean = header.size >= 12 && header.ascii(4, 4) == "ftyp" &&
        header.ascii(8, header.size - 8).chunked(4).any { it in setOf("heic", "heix", "hevc", "hevx", "mif1") }

    private fun readHeader(input: InputStream): ByteArray {
        val header = ByteArray(HEADER_BYTES)
        var length = 0
        while (length < header.size) {
            val count = input.read(header, length, header.size - length)
            if (count < 0) break
            if (count > 0) length += count else {
                val single = input.read()
                if (single < 0) break
                header[length++] = single.toByte()
            }
        }
        return header.copyOf(length)
    }

    private fun moveToStore(source: File, destination: File) {
        destination.parentFile?.mkdirs()
        try {
            Files.move(source.toPath(), destination.toPath(), StandardCopyOption.ATOMIC_MOVE)
            return
        } catch (_: AtomicMoveNotSupportedException) {
            // 下面的隐藏 part 文件路径位于长期目录，可在跨文件系统时原子替换。
        } catch (_: FileSystemException) {
            // Android 的 cacheDir 与 filesDir 可能属于不同挂载点。
        }
        val part = File(destination.parentFile, ".${destination.name}.part")
        try {
            part.delete()
            source.inputStream().use { input ->
                FileOutputStream(part).use { output ->
                    input.copyTo(output)
                    output.fd.sync()
                }
            }
            try {
                Files.move(part.toPath(), destination.toPath(), StandardCopyOption.ATOMIC_MOVE)
            } catch (_: AtomicMoveNotSupportedException) {
                Files.move(part.toPath(), destination.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }
        } catch (error: IOException) {
            part.delete()
            throw error
        } finally {
            part.delete()
        }
        source.delete()
    }

    private fun writeOriginalName(directory: File, hash: String, name: String) {
        val destination = File(directory, "$hash.name")
        if (destination.exists()) return
        val part = File(directory, ".$hash.name.part")
        try {
            part.writeText(name, Charsets.UTF_8)
            try {
                Files.move(part.toPath(), destination.toPath(), StandardCopyOption.ATOMIC_MOVE)
            } catch (_: AtomicMoveNotSupportedException) {
                Files.move(part.toPath(), destination.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }
        } finally {
            part.delete()
        }
    }

    private fun safeName(name: String): String = name.substringAfterLast('/').substringAfterLast('\\')
        .take(255).ifBlank { "RAW" }

    private fun ByteArray.startsWith(prefix: ByteArray) = size >= prefix.size && prefix.indices.all { this[it] == prefix[it] }
    private fun ByteArray.ascii(offset: Int, length: Int): String =
        if (offset < 0 || length < 0 || offset + length > size) "" else String(this, offset, length, Charsets.US_ASCII)
    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
}
