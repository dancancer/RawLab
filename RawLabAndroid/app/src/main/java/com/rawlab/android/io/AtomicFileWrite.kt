package com.rawlab.android.io

import java.io.File
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.CopyOption
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption

/**
 * Publishes a caller-owned staging file, replacing the destination.
 * Only unsupported atomic moves fall back to a regular replacement; that fallback is not atomic.
 * Callers retain responsibility for locking, syncing and staging-file cleanup.
 */
internal fun replaceFileAtomically(
    source: File,
    destination: File,
    move: (Path, Path, Array<out CopyOption>) -> Unit = { from, to, options -> Files.move(from, to, *options) },
) {
    val from = source.toPath()
    val to = destination.toPath()
    try {
        move(from, to, arrayOf(StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING))
    } catch (_: AtomicMoveNotSupportedException) {
        move(from, to, arrayOf(StandardCopyOption.REPLACE_EXISTING))
    }
}
