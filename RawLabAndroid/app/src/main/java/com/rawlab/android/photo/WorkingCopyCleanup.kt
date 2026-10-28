package com.rawlab.android.photo

import com.rawlab.android.batch.journal.BatchJournal
import java.io.File
import java.nio.file.Files

/** 仅在进程入口、创建任何 PhotoStorage 之前调用。无法确认恢复引用时保留全部副本。 */
internal object WorkingCopyCleanup {
    fun atProcessStart(cache: File, journalRoot: File) {
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
