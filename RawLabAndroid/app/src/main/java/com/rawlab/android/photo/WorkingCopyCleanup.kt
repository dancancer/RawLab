package com.rawlab.android.photo

import com.rawlab.android.batch.journal.BatchJournal
import java.io.File
import java.nio.file.Files

/** 仅在进程入口、创建任何 PhotoStorage 之前调用。无法确认恢复引用时保留全部副本。 */
internal object WorkingCopyCleanup {
    private const val UUID_HEX = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    private val BATCH_RENDER_TEMP_PATTERN = Regex("^render-.+\\.(jpg|png|dng)$", RegexOption.IGNORE_CASE)
    private val EXPORT_STAGING_PART_PATTERN = Regex("^\\..+\\.$UUID_HEX\\.part(\\.[A-Za-z0-9]+)?$")

    internal fun isTransientExportFileName(name: String): Boolean =
        BATCH_RENDER_TEMP_PATTERN.matches(name) || EXPORT_STAGING_PART_PATTERN.matches(name)

    internal fun transientExportFiles(directories: Iterable<File>): List<File> {
        val matched = mutableListOf<File>()
        val seenRoots = mutableSetOf<java.nio.file.Path>()
        for (directory in directories) {
            val root = try {
                if (!directory.isDirectory || Files.isSymbolicLink(directory.toPath())) continue
                directory.canonicalFile.toPath()
            } catch (_: Exception) { continue }
            if (!seenRoots.add(root)) continue
            for (entry in directory.listFiles().orEmpty()) {
                if (!isTransientExportFileName(entry.name)) continue
                val regularOwnedFile = try {
                    !Files.isSymbolicLink(entry.toPath()) &&
                        entry.isFile &&
                        entry.canonicalFile.toPath().parent == root
                } catch (_: Exception) { false }
                if (regularOwnedFile) matched += entry
            }
        }
        return matched
    }

    internal fun cleanTransientExportFiles(directories: Iterable<File>): List<File> =
        transientExportFiles(directories).filter { it.delete() }

    fun atProcessStart(cache: File, journalRoot: File, exportTempRoots: Iterable<File> = listOf(cache)) {
        cleanTransientExportFiles(exportTempRoots)
        val protected = try {
            if (!journalRoot.exists()) emptyList() else {
                val journal = BatchJournal(journalRoot)
                journalRoot.listFiles()?.filter { it.extension == "properties" }?.flatMap { snapshot ->
                    val job = journal.load(snapshot.nameWithoutExtension) ?: return
                    listOf(job.source.sourceFile) + listOfNotNull(job.source.lookFile) +
                        job.rows.flatMap { listOf(it.target.sourceFile) + listOfNotNull(it.target.frozen?.lookFile) }
                } ?: return
            }
        } catch (_: Exception) { return }
        val root = cache.canonicalFile.toPath()
        val paths = try { protected.map { it.canonicalFile.toPath() } } catch (_: Exception) { return }
        for (directory in cache.listFiles().orEmpty()) {
            if (!directory.name.matches(Regex("rawlab-[0-9a-fA-F-]{36}")) || !directory.isDirectory || Files.isSymbolicLink(directory.toPath())) continue
            val candidate = directory.canonicalFile.toPath()
            if (candidate.parent == root && paths.none { it.startsWith(candidate) }) directory.deleteRecursively()
        }
    }
}
