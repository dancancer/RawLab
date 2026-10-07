package com.rawlab.android

import java.io.File
import java.io.IOException
import java.io.InputStream
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.Locale
import java.util.Properties
import java.util.UUID

enum class LookFormat(val extension: String) {
    UNKNOWN(""), CUBE("cube"), RLOOK("rlook");

    companion object {
        fun fromExtension(extension: String): LookFormat = when (extension.lowercase(Locale.ROOT)) {
            "cube" -> CUBE
            "rlook" -> RLOOK
            else -> UNKNOWN
        }
    }
}

data class LookValidation(val format: LookFormat, val version: Int)

fun interface LookValidator {
    fun validate(file: File): LookValidation
}

object NativeLookValidator : LookValidator {
    override fun validate(file: File): LookValidation = NativeProcessor.validateLook(file)
}

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
) {
    private val registry = File(root, REGISTRY_NAME)

    init {
        if (root.exists() && !root.isDirectory) throw IOException("Look storage is not a directory")
        if (!root.exists() && !root.mkdirs()) throw IOException("Cannot create look storage")
    }

    fun list(): List<ManagedLook> = synchronized(this) {
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

    fun importLook(input: InputStream, originalName: String): ManagedLook = synchronized(this) {
        val id = UUID.randomUUID().toString()
        val namedFormat = LookFormat.fromExtension(originalName.substringAfterLast('.', ""))
        val rawStage = File(root, ".$id.stage")
        var staged: File? = null
        var destination: File? = null
        try {
            rawStage.outputStream().use { output -> input.copyTo(output) }
            val format = namedFormat.takeUnless { it == LookFormat.UNKNOWN } ?: detectContainer(rawStage)
            staged = File(root, ".$id.stage.${format.extension}")
            move(rawStage, staged!!)
            val relativePath = "$id.${format.extension}"
            destination = File(root, relativePath)
            val name = originalName.trim().ifEmpty { "Look.${format.extension}" }
            val validation = validator.validate(staged!!)
            require(validation.format == format) { "Look format does not match its extension" }
            require(validVersion(format, validation.version)) { "Invalid look version" }
            move(staged!!, destination!!)
            val imported = ManagedLook(id, name, originalName, format, validation.version, relativePath)
            try {
                writeRegistry(readRegistry() + imported)
            } catch (error: Throwable) {
                destination?.delete()
                throw error
            }
            imported
        } catch (error: Throwable) {
            rawStage.delete()
            staged?.delete()
            destination?.delete()
            throw error
        }
    }

    fun rename(id: String, name: String): ManagedLook = synchronized(this) {
        val existing = requireLook(id)
        val trimmed = name.trim()
        require(trimmed.isNotEmpty()) { "Look name cannot be empty" }
        val renamed = existing.copy(name = trimmed)
        writeRegistry(readRegistry().map { if (it.id == id) renamed else it })
        renamed
    }

    fun remove(id: String) = synchronized(this) {
        val existing = requireLook(id)
        val remaining = readRegistry().filterNot { it.id == id }
        writeRegistry(remaining)
        if (!existing.file(root).delete() && existing.file(root).exists()) {
            runCatching { writeRegistry(remaining + existing) }
            throw IOException("Cannot remove managed look")
        }
    }

    fun fileFor(id: String): File? = synchronized(this) {
        readRegistry().firstOrNull { it.id == id }?.file(root)?.takeIf(File::isFile)
    }

    private fun requireLook(id: String): ManagedLook = readRegistry().firstOrNull { it.id == id }
        ?: throw NoSuchElementException("Unknown managed look: $id")

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
                val prefix = "item.$index."
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

    private fun writeRegistry(looks: List<ManagedLook>) {
        val temporary = File(root, ".$REGISTRY_NAME.${UUID.randomUUID()}.tmp")
        try {
            val properties = Properties().apply {
                setProperty("version", REGISTRY_VERSION.toString())
                setProperty("count", looks.size.toString())
                looks.forEachIndexed { index, look ->
                    val prefix = "item.$index."
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
        private const val REGISTRY_NAME = "registry.properties"
        private const val REGISTRY_VERSION = 1
        private val RLOOK_MAGIC = "RLOOKDCP".toByteArray()
    }
}
