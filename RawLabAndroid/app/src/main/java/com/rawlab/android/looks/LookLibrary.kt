package com.rawlab.android.looks

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

// 读不懂的外观条目：保留原 key 组的后缀到值映射（重写时可原样放回），只隔离自己（P2-16）。
data class UnreadableLook(val keys: Map<String, String>) {
    val id: String? get() = keys["id"]
    val name: String? get() = keys["name"]
    val path: String? get() = keys["path"]
}

data class ManagedLook(
    val id: String,
    val name: String,
    val originalName: String,
    val format: LookFormat,
    val version: Int,
    val relativePath: String,
    val available: Boolean = true,
    val appearanceUnverified: Boolean = false,
    val compatibilityMode: Int = 0,
) {
    fun file(root: File): File = File(root, relativePath)
}

class LookLibrary(
    private val root: File,
    private val validator: LookValidator = NativeLookValidator,
    private val dcpCompiler: DcpCompiler = NativeDcpCompiler,
    private val compatibilityCompiler: (File, LUTCompatibility) -> ByteArray = { file, draft -> NativeProcessor.prepareLutCompatibility(file, draft.request()) },
) {
    private val registry = File(root, REGISTRY_NAME)
    private val monitor = monitors.computeIfAbsent(root.canonicalPath) { Any() }

    init {
        if (root.exists() && !root.isDirectory) throw IOException("Look storage is not a directory")
        if (!root.isDirectory && !root.mkdirs() && !root.isDirectory) throw IOException("Cannot create look storage")
    }

    fun list(): List<ManagedLook> = locked {
        readRegistry().looks.map { look ->
            val file = look.file(root)
            val available = file.isFile && runCatching {
                validator.validate(file).let { it.format == look.format && it.version == look.version }
            }.getOrDefault(false)
            look.copy(available = available)
        }
    }

    fun importLook(source: File, originalName: String = source.name): ManagedLook =
        source.inputStream().use { importLook(it, originalName) }

    fun importLook(input: InputStream, originalName: String, compatibility: LUTCompatibility? = null,
        toneCurve: ByteArray? = null, omitAutomaticBlack: Boolean = false): ManagedLook = locked {
        val id = UUID.randomUUID().toString()
        val transaction = File(root, ".import-$id.pending")
        check(transaction.createNewFile()) { "Cannot record look import" }
        val namedFormat = LookFormat.fromExtension(originalName.substringAfterLast('.', ""))
        val rawStage = File(root, ".${id}.stage")
        try {
            val dcp = originalName.substringAfterLast('.').equals("dcp", ignoreCase = true)
            val format = if (dcp) {
                val compiled = dcpCompiler.compile(readDcpInput(input, MAX_DCP_SOURCE_BYTES), sourceName(originalName),
                    toneCurve, omitAutomaticBlack)
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
            if (compatibility != null) {
                require(format == LookFormat.CUBE || format == LookFormat.VLT)
                val prepared = compatibilityCompiler(staged, compatibility)
                staged.writeBytes(prepared)
            }
            val relativePath = "${id}.${format.extension}"
            val destination = File(root, relativePath)
            val name = originalName.trim().ifEmpty { "Look.${format.extension}" }
            val validation = try { validator.validate(staged) }
            catch (error: IllegalArgumentException) { throw InvalidLookException(error.message ?: "Invalid look", error) }
            catch (error: UnsupportedOperationException) { throw InvalidLookException(error.message ?: "Invalid look", error) }
            if (compatibility == null && validation.colorState in listOf(7, 8))
                throw com.rawlab.android.engine.LUTColorContractException(1)
            if (validation.format != format) throw InvalidLookException("Look format does not match its extension")
            if (!validVersion(format, validation.version)) throw InvalidLookException("Invalid look version")
            move(staged, destination)
            val imported = ManagedLook(id, name, originalName, format, validation.version, relativePath,
                appearanceUnverified = validation.colorState in listOf(4, 7, 8),
                compatibilityMode = validation.colorState.takeIf { it == 7 || it == 8 } ?: 0)
            val state = readRegistry()
            writeRegistry(state.looks + imported, state.unreadable)
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
        require(trimmed.isNotEmpty() && trimmed.none(Char::isISOControl)) { "Look name cannot be empty or contain control characters" }
        val renamed = existing.copy(name = trimmed)
        val state = readRegistry()
        writeRegistry(state.looks.map { if (it.id == id) renamed else it }, state.unreadable)
        renamed
    }

    fun remove(id: String) = locked {
        val existing = requireLook(id)
        val state = readRegistry()
        val remaining = state.looks.filterNot { it.id == id }
        writeRegistry(remaining, state.unreadable)
        if (!existing.file(root).delete() && existing.file(root).exists()) {
            runCatching { writeRegistry(remaining + existing, state.unreadable) }
            throw IOException("Cannot remove managed look")
        }
    }

    fun listUnreadable(): List<UnreadableLook> = locked { readRegistry().unreadable }

    // 删除读不懂的条目：按 key 组只删单条；实体文件须文件名安全（无分隔符与 ..、扩展名白名单、
    // 前缀为 UUID）且不被任何存活条目引用才清理，防止误删有效外观文件或 registry 自身。
    fun removeUnreadable(look: UnreadableLook) = locked {
        val state = readRegistry()
        val index = state.unreadable.indexOfFirst { it.keys == look.keys }
        if (index < 0) throw NoSuchElementException("Unknown unreadable look")
        val remaining = state.unreadable.filterIndexed { position, _ -> position != index }
        val name = look.path?.takeIf { candidate ->
            !candidate.contains('/') && !candidate.contains('\\') && !candidate.contains("..") &&
                candidate.substringAfterLast('.', "").lowercase() in setOf("cube", "vlt", "rlook") &&
                isSafeId(candidate.substringBeforeLast('.')) &&
                state.looks.none { it.relativePath == candidate } &&
                remaining.none { it.path == candidate }
        }
        val file = name?.let { File(root, it) }
        writeRegistry(state.looks, remaining)
        if (file != null && file.isFile && !file.delete() && file.exists()) {
            runCatching { writeRegistry(state.looks, state.unreadable) }
            throw IOException("Cannot remove unreadable look file")
        }
    }

    fun fileFor(id: String): File? = locked {
        readRegistry().looks.firstOrNull { it.id == id }?.file(root)?.takeIf(File::isFile)
    }

    private fun requireLook(id: String): ManagedLook = readRegistry().looks.firstOrNull { it.id == id }
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
        val state = readRegistry()
        val committed = state.looks.mapTo(mutableSetOf()) { it.id }
        for (unreadable in state.unreadable) {
            unreadable.id?.let { committed.add(it) }
            unreadable.path?.let { committed.add(it.substringBeforeLast('.')) }
        }
        fun remove(file: File) {
            if (file.exists() && !file.delete()) throw IOException("Cannot recover look import: ${file.name}")
        }
        for (marker in root.listFiles().orEmpty()) {
            val id = marker.name.removePrefix(".import-").removeSuffix(".pending")
            if (marker.name != ".import-$id.pending" || !isSafeId(id)) continue
            remove(File(root, ".$id.stage"))
            for (extension in listOf("cube", "vlt", "rlook")) {
                remove(File(root, ".$id.stage.$extension"))
                if (id !in committed) remove(File(root, "$id.$extension"))
            }
            remove(marker)
        }
        for (file in root.listFiles().orEmpty()) {
            val stageId = file.name.removePrefix(".").substringBefore(".stage")
            val temporaryId = file.name.removePrefix(".$REGISTRY_NAME.").removeSuffix(".tmp")
            if ((isSafeId(stageId) && file.name in listOf(".$stageId.stage", ".$stageId.stage.cube", ".$stageId.stage.vlt", ".$stageId.stage.rlook")) ||
                (isSafeId(temporaryId) && file.name == ".$REGISTRY_NAME.$temporaryId.tmp")) remove(file)
        }
    }

    private class RegistryState(val looks: List<ManagedLook>, val unreadable: List<UnreadableLook>)

    private fun readRegistry(): RegistryState {
        if (!registry.exists()) return RegistryState(emptyList(), emptyList())
        if (!registry.isFile) throw IOException("Look registry is not a file")
        val properties = Properties()
        try {
            registry.inputStream().use(properties::load)
            if (properties.getProperty("version")?.toIntOrNull() != REGISTRY_VERSION)
                throw IOException("Unsupported look registry version")
            val count = properties.getProperty("count")?.toIntOrNull()
                ?: throw IOException("Missing look registry count")
            require(count >= 0) { "Invalid look registry count" }
            // P2-16：条目级损坏只降级这一条；文件级失败（版本、count、有效条目重名 ID）仍让整库不可用。
            val looks = mutableListOf<ManagedLook>()
            val unreadable = mutableListOf<UnreadableLook>()
            for (index in 0 until count) {
                val prefix = "item.${index}."
                val keys = properties.keys.asSequence().map { it.toString() }.filter { it.startsWith(prefix) }
                    .sorted().associate { it.removePrefix(prefix) to properties.getProperty(it).orEmpty() }
                val look = decodeItem(keys)
                if (look == null) unreadable += UnreadableLook(keys) else looks += look
            }
            require(looks.map { it.id }.toSet().size == looks.size) { "Invalid or duplicate managed look metadata" }
            return RegistryState(looks, unreadable)
        } catch (error: IOException) {
            throw error
        } catch (error: Exception) {
            throw IOException("Cannot read look registry", error)
        }
    }

    private fun decodeItem(keys: Map<String, String>): ManagedLook? {
        val id = keys["id"] ?: return null
        val name = keys["name"] ?: return null
        val originalName = keys["originalName"] ?: return null
        val format = LookFormat.fromExtension(keys["format"].orEmpty())
        val version = keys["version"]?.toIntOrNull() ?: return null
        val path = keys["path"] ?: return null
        if (!isSafeId(id) || !validVersion(format, version) || !isSafePath(path, id, format)) return null
        return ManagedLook(id, name, originalName, format, version, path,
            appearanceUnverified = keys["appearanceUnverified"] == "true",
            compatibilityMode = keys["compatibilityMode"]?.toIntOrNull()?.takeIf { it == 7 || it == 8 } ?: 0)
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

    private fun sourceName(originalName: String): String =
        originalName.substringAfterLast('/').ifEmpty { "look.dcp" }

    private fun writeRegistry(looks: List<ManagedLook>, unreadable: List<UnreadableLook> = emptyList()) {
        val temporary = File(root, ".${REGISTRY_NAME}.${UUID.randomUUID()}.tmp")
        try {
            val properties = Properties().apply {
                setProperty("version", REGISTRY_VERSION.toString())
                setProperty("count", (looks.size + unreadable.size).toString())
                looks.forEachIndexed { index, look ->
                    val prefix = "item.${index}."
                    setProperty(prefix + "id", look.id)
                    setProperty(prefix + "name", look.name)
                    setProperty(prefix + "originalName", look.originalName)
                    setProperty(prefix + "format", look.format.extension)
                    setProperty(prefix + "version", look.version.toString())
                    setProperty(prefix + "path", look.relativePath)
                    setProperty(prefix + "appearanceUnverified", look.appearanceUnverified.toString())
                    setProperty(prefix + "compatibilityMode", look.compatibilityMode.toString())
                }
                // 坏条目原文 key 组排在有效条目之后，序号顺延，删除前逐字保留。
                unreadable.forEachIndexed { offset, look ->
                    val prefix = "item.${looks.size + offset}."
                    look.keys.forEach { (suffix, value) -> setProperty(prefix + suffix, value) }
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
        LookFormat.VLT -> version == 1
        LookFormat.RLOOK -> version == 1 || version == 2
        LookFormat.UNKNOWN -> false
    }

    private fun isSafePath(path: String, id: String, format: LookFormat): Boolean =
        path == "$id.${format.extension}" && !path.contains('/') && !path.contains('\\')

    companion object {
        private val monitors = ConcurrentHashMap<String, Any>()
        private const val REGISTRY_NAME = "registry.properties"
        private const val REGISTRY_VERSION = 1
        private const val MAX_DCP_SOURCE_BYTES = 128 * 1024 * 1024
        private const val MAX_DCP_OUTPUT_BYTES = 64 * 1024 * 1024
        private val RLOOK_MAGIC = "RLOOKDCP".toByteArray()
    }
}
