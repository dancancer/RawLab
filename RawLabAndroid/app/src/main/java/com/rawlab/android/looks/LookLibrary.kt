package com.rawlab.android.looks

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.RandomAccessFile
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.Properties
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import com.rawlab.android.engine.LookFormat
import com.rawlab.android.engine.LookValidation
import com.rawlab.android.engine.NativeProcessor

fun interface LookValidator {
    fun validate(file: File): LookValidation
}

object NativeLookValidator : LookValidator {
    override fun validate(file: File): LookValidation = NativeProcessor.validateLook(file)
}

class InvalidLookException(message: String, cause: Throwable? = null) : IllegalArgumentException(message, cause)

data class ManagedLook(
    val id: String,
    val name: String,
    val originalName: String,
    val format: LookFormat,
    val version: Int,
    val relativePath: String,
    val available: Boolean = true,
) {
    fun file(root: File): File = File(root, relativePath)
}

class LookLibrary(
    private val root: File,
    private val validator: LookValidator = NativeLookValidator,
    private val dcpCompiler: DcpCompiler = NativeDcpCompiler,
) {
    private val registry = File(root, REGISTRY_NAME)
    private val monitor = monitors.computeIfAbsent(root.canonicalPath) { Any() }

    init {
        if (root.exists() && !root.isDirectory) throw IOException("Look storage is not a directory")
        if (!root.isDirectory && !root.mkdirs() && !root.isDirectory) throw IOException("Cannot create look storage")
    }

    fun list(): List<ManagedLook> = locked {
        readRegistry().map { look ->
            val file = look.file(root)
            val available = file.isFile && runCatching {
                validator.validate(file) == LookValidation(look.format, look.version)
            }.getOrDefault(false)
            look.copy(available = available)
        }
    }

    fun importLook(source: File, originalName: String = source.name): ManagedLook =
        source.inputStream().use { importLook(it, originalName) }

    fun importLook(input: InputStream, originalName: String): ManagedLook = locked {
        val id = UUID.randomUUID().toString()
        val transaction = File(root, ".import-$id.pending")
        check(transaction.createNewFile()) { "Cannot record look import" }
        val namedFormat = LookFormat.fromExtension(originalName.substringAfterLast('.', ""))
        val rawStage = File(root, ".${id}.stage")
        try {
            val dcp = originalName.substringAfterLast('.').equals("dcp", ignoreCase = true)
            val format = if (dcp) {
                val compiled = dcpCompiler.compile(readBoundedDcp(input), sourceName(originalName))
                if (compiled.isEmpty()) throw DcpCompilationException(DcpFailureReason.MALFORMED)
                if (compiled.size > MAX_DCP_OUTPUT_BYTES)
                    throw DcpCompilationException(DcpFailureReason.TOO_LARGE)
                rawStage.outputStream().use { output -> output.write(compiled) }
                LookFormat.RLOOK
            } else {
                rawStage.outputStream().use { output -> input.copyTo(output) }
                namedFormat.takeUnless { it == LookFormat.UNKNOWN } ?: detectContainer(rawStage)
            }
            val staged = File(root, ".${id}.stage.${format.extension}")
            move(rawStage, staged)
            val relativePath = "${id}.${format.extension}"
            val destination = File(root, relativePath)
            val name = originalName.trim().ifEmpty { "Look.${format.extension}" }
            val validation = try { validator.validate(staged) }
            catch (error: IllegalArgumentException) { throw InvalidLookException(error.message ?: "Invalid look", error) }
            catch (error: UnsupportedOperationException) { throw InvalidLookException(error.message ?: "Invalid look", error) }
            if (validation.format != format) throw InvalidLookException("Look format does not match its extension")
            if (!validVersion(format, validation.version)) throw InvalidLookException("Invalid look version")
            move(staged, destination)
            val imported = ManagedLook(id, name, originalName, format, validation.version, relativePath)
            writeRegistry(readRegistry() + imported)
            transaction.delete()
            imported
        } catch (error: Throwable) {
            runCatching { recoverInterruptedImports() }
            throw error
        }
    }

    fun rename(id: String, name: String): ManagedLook = locked {
        val existing = requireLook(id)
        val trimmed = name.trim()
        require(trimmed.isNotEmpty()) { "Look name cannot be empty" }
        val renamed = existing.copy(name = trimmed)
        writeRegistry(readRegistry().map { if (it.id == id) renamed else it })
        renamed
    }

    fun remove(id: String) = locked {
        val existing = requireLook(id)
        val remaining = readRegistry().filterNot { it.id == id }
        writeRegistry(remaining)
        if (!existing.file(root).delete() && existing.file(root).exists()) {
            runCatching { writeRegistry(remaining + existing) }
            throw IOException("Cannot remove managed look")
        }
    }

    fun fileFor(id: String): File? = locked {
        readRegistry().firstOrNull { it.id == id }?.file(root)?.takeIf(File::isFile)
    }

    private fun requireLook(id: String): ManagedLook = readRegistry().firstOrNull { it.id == id }
        ?: throw NoSuchElementException("Unknown managed look: ${id}")

    private fun <T> locked(block: () -> T): T = synchronized(monitor) {
        // 文件锁会随 owner 进程退出释放，不能清理另一个仍在导入的实例。
        RandomAccessFile(File(root, ".lock"), "rw").use { file ->
            file.channel.use { channel -> channel.lock().use {
                recoverInterruptedImports()
                block()
            } }
        }
    }

    private fun recoverInterruptedImports() {
        // 损坏索引时先报错并保留全部事务，不把未知归属当成未提交。
        val committed = readRegistry().mapTo(mutableSetOf()) { it.id }
        fun remove(file: File) {
            if (file.exists() && !file.delete()) throw IOException("Cannot recover look import: ${file.name}")
        }
        for (marker in root.listFiles().orEmpty()) {
            val id = marker.name.removePrefix(".import-").removeSuffix(".pending")
            if (marker.name != ".import-$id.pending" || !isSafeId(id)) continue
            remove(File(root, ".$id.stage"))
            for (extension in listOf("cube", "rlook")) {
                remove(File(root, ".$id.stage.$extension"))
                if (id !in committed) remove(File(root, "$id.$extension"))
            }
            remove(marker)
        }
        for (file in root.listFiles().orEmpty()) {
            val stageId = file.name.removePrefix(".").substringBefore(".stage")
            val temporaryId = file.name.removePrefix(".$REGISTRY_NAME.").removeSuffix(".tmp")
            if ((isSafeId(stageId) && file.name in listOf(".$stageId.stage", ".$stageId.stage.cube", ".$stageId.stage.rlook")) ||
                (isSafeId(temporaryId) && file.name == ".$REGISTRY_NAME.$temporaryId.tmp")) remove(file)
        }
    }

    private fun readRegistry(): List<ManagedLook> {
        if (!registry.exists()) return emptyList()
        if (!registry.isFile) throw IOException("Look registry is not a file")
        val properties = Properties()
        try {
            registry.inputStream().use(properties::load)
            if (properties.getProperty("version")?.toIntOrNull() != REGISTRY_VERSION)
                throw IOException("Unsupported look registry version")
            val count = properties.getProperty("count")?.toIntOrNull()
                ?: throw IOException("Missing look registry count")
            require(count >= 0) { "Invalid look registry count" }
            val ids = mutableSetOf<String>()
            return (0 until count).map { index ->
                val prefix = "item.${index}."
                val id = properties.getProperty(prefix + "id") ?: throw IOException("Missing managed look id")
                val name = properties.getProperty(prefix + "name") ?: throw IOException("Missing managed look name")
                val originalName = properties.getProperty(prefix + "originalName") ?: throw IOException("Missing managed look source name")
                val format = LookFormat.fromExtension(properties.getProperty(prefix + "format").orEmpty())
                val version = properties.getProperty(prefix + "version")?.toIntOrNull()
                    ?: throw IOException("Missing managed look version")
                val path = properties.getProperty(prefix + "path") ?: throw IOException("Missing managed look path")
                if (!isSafeId(id) || !ids.add(id) || !validVersion(format, version) || !isSafePath(path, id, format))
                    throw IOException("Invalid or duplicate managed look metadata")
                ManagedLook(id, name, originalName, format, version, path)
            }
        } catch (error: IOException) {
            throw error
        } catch (error: Exception) {
            throw IOException("Cannot read look registry", error)
        }
    }

    private fun detectContainer(file: File): LookFormat {
        val magic = ByteArray(RLOOK_MAGIC.size)
        var read = 0
        file.inputStream().use { input ->
            while (read < magic.size) {
                val count = input.read(magic, read, magic.size - read)
                if (count <= 0) break
                read += count
            }
        }
        return if (read == magic.size && magic.contentEquals(RLOOK_MAGIC)) LookFormat.RLOOK else LookFormat.CUBE
    }

    private fun readBoundedDcp(input: InputStream): ByteArray {
        val data = ByteArrayOutputStream()
        val buffer = ByteArray(DCP_READ_BUFFER_BYTES)
        var total = 0L
        while (true) {
            val remaining = MAX_DCP_SOURCE_BYTES - total
            val request = minOf(buffer.size.toLong(), remaining + 1).toInt()
            val count = input.read(buffer, 0, request)
            if (count < 0) break
            if (count == 0) continue
            total += count
            if (total > MAX_DCP_SOURCE_BYTES) throw DcpCompilationException(DcpFailureReason.TOO_LARGE)
            data.write(buffer, 0, count)
        }
        return data.toByteArray()
    }

    private fun sourceName(originalName: String): String =
        originalName.substringAfterLast('/').ifEmpty { "look.dcp" }

    private fun writeRegistry(looks: List<ManagedLook>) {
        val temporary = File(root, ".${REGISTRY_NAME}.${UUID.randomUUID()}.tmp")
        try {
            val properties = Properties().apply {
                setProperty("version", REGISTRY_VERSION.toString())
                setProperty("count", looks.size.toString())
                looks.forEachIndexed { index, look ->
                    val prefix = "item.${index}."
                    setProperty(prefix + "id", look.id)
                    setProperty(prefix + "name", look.name)
                    setProperty(prefix + "originalName", look.originalName)
                    setProperty(prefix + "format", look.format.extension)
                    setProperty(prefix + "version", look.version.toString())
                    setProperty(prefix + "path", look.relativePath)
                }
            }
            temporary.outputStream().use { properties.store(it, null) }
            move(temporary, registry)
        } finally {
            temporary.delete()
        }
    }

    private fun move(source: File, destination: File) {
        try {
            Files.move(source.toPath(), destination.toPath(), StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING)
        } catch (_: AtomicMoveNotSupportedException) {
            Files.move(source.toPath(), destination.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
    }

    private fun isSafeId(id: String): Boolean = runCatching { UUID.fromString(id).toString() == id }.getOrDefault(false)

    private fun validVersion(format: LookFormat, version: Int): Boolean = when (format) {
        LookFormat.CUBE -> version == 0
        LookFormat.RLOOK -> version == 1 || version == 2
        LookFormat.UNKNOWN -> false
    }

    private fun isSafePath(path: String, id: String, format: LookFormat): Boolean =
        path == "$id.${format.extension}" && !path.contains('/') && !path.contains('\\')

    companion object {
        private val monitors = ConcurrentHashMap<String, Any>()
        private const val REGISTRY_NAME = "registry.properties"
        private const val REGISTRY_VERSION = 1
        private const val DCP_READ_BUFFER_BYTES = 64 * 1024
        private const val MAX_DCP_SOURCE_BYTES = 128 * 1024 * 1024L
        private const val MAX_DCP_OUTPUT_BYTES = 64 * 1024 * 1024
        private val RLOOK_MAGIC = "RLOOKDCP".toByteArray()
    }
}
