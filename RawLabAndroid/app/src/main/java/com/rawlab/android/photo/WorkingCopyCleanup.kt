package com.rawlab.android.photo

import com.rawlab.android.batch.journal.BatchJournal
import java.io.File
import java.nio.file.Files

/** 仅在进程入口、创建任何 PhotoStorage 之前调用。无法确认恢复引用时保留全部副本。 */
internal object WorkingCopyCleanup {
    private val protectedPaths = java.util.concurrent.ConcurrentHashMap.newKeySet<java.nio.file.Path>()
    private const val UUID_HEX = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    private val BATCH_RENDER_TEMP_PATTERN = Regex("^render-.+\\.(jpg|png|dng)$", RegexOption.IGNORE_CASE)
    private val EXPORT_STAGING_PART_PATTERN = Regex("^\\..+\\.$UUID_HEX\\.part(\\.[A-Za-z0-9]+)?$")
    private val LUT_PREVIEW_DIRECTORY_PATTERN = Regex("^lut-preview-$UUID_HEX$")
    private val BATCH_JOB_DIRECTORY_PATTERN = Regex("^$UUID_HEX$")

    /** 只删 parent 下直属、非符号链接、且满足 orphan 的目录。 */
    private fun deleteOwnedDirectories(parent: File, orphan: (File, java.nio.file.Path) -> Boolean) {
        val root = try { parent.canonicalFile.toPath() } catch (_: Exception) { return }
        for (directory in parent.listFiles().orEmpty()) {
            if (!directory.isDirectory || Files.isSymbolicLink(directory.toPath())) continue
            val candidate = try { directory.canonicalFile.toPath() } catch (_: Exception) { continue }
            if (candidate.parent == root && candidate !in protectedPaths && orphan(directory, candidate)) directory.deleteRecursively()
        }
    }

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
                val canonical = try { entry.canonicalFile.toPath() } catch (_: Exception) { continue }
                val regularOwnedFile = try {
                    !Files.isSymbolicLink(entry.toPath()) &&
                        entry.isFile &&
                        canonical.parent == root &&
                        canonical !in protectedPaths
                } catch (_: Exception) { false }
                if (regularOwnedFile) matched += entry
            }
        }
        return matched
    }

    internal fun cleanTransientExportFiles(directories: Iterable<File>): List<File> =
        transientExportFiles(directories).filter { it.delete() }

    /** 在后台启动清理期间注册新建的工作目录或临时文件，避免与进程入口清理竞态。 */
    fun protect(path: File) {
        try { protectedPaths.add(path.canonicalFile.toPath()) } catch (_: Exception) {}
    }

    fun atProcessStart(cache: File, journalRoot: File, exportTempRoots: Iterable<File> = listOf(cache)) {
        cleanTransientExportFiles(exportTempRoots)
        // LUT 兼容性预览目录只属于单次对话框，进程重启后不再有持有者。
        deleteOwnedDirectories(cache) { directory, _ -> LUT_PREVIEW_DIRECTORY_PATTERN.matches(directory.name) }
        val (paths, root) = synchronized(BatchJournal.rootLock) {
            val protected = try {
                if (!journalRoot.exists()) emptyList() else {
                    val journal = BatchJournal(journalRoot)
                    journalRoot.listFiles()?.filter { it.extension == "properties" }?.flatMap { snapshot ->
                        val job = journal.load(snapshot.nameWithoutExtension) ?: return@synchronized null
                        listOf(job.source.sourceFile) + listOfNotNull(job.source.lookFile) +
                            job.rows.flatMap { listOf(it.target.sourceFile) + listOfNotNull(it.target.frozen?.lookFile) }
                    } ?: return@synchronized null
                }
            } catch (_: Exception) { return@synchronized null }
            val resolvedRoot = cache.canonicalFile.toPath()
            val resolvedPaths = try { protected.map { it.canonicalFile.toPath() } } catch (_: Exception) { return@synchronized null }
            // 没有快照的任务目录无法恢复；有快照（含失败、取消或读不出的）一律保留供重试。
            deleteOwnedDirectories(journalRoot) { directory, candidate ->
                BATCH_JOB_DIRECTORY_PATTERN.matches(directory.name) &&
                    !File(journalRoot, "${directory.name}.properties").exists() &&
                    resolvedPaths.none { it.startsWith(candidate) }
            }
            resolvedPaths to resolvedRoot
        } ?: return
        for (directory in cache.listFiles().orEmpty()) {
            if (!directory.name.matches(Regex("rawlab-[0-9a-fA-F-]{36}")) || !directory.isDirectory || Files.isSymbolicLink(directory.toPath())) continue
            val candidate = directory.canonicalFile.toPath()
            if (candidate.parent == root && candidate !in protectedPaths && paths.none { it.startsWith(candidate) }) directory.deleteRecursively()
        }
    }
}
