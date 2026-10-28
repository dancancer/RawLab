package com.rawlab.android.editor.render

import java.util.concurrent.Executors
import com.rawlab.android.R

class RenderQueue<T, R>(
    private val render: (T) -> R,
    private val publish: (Long, Result<R>) -> Unit,
    private val release: () -> Unit,
    private val discard: (R) -> Unit,
) : AutoCloseable {
    constructor(render: (T) -> R, publish: (Long, Result<R>) -> Unit, release: () -> Unit) :
        this(render, publish, release, {})

    private val worker = Executors.newSingleThreadExecutor { Thread(it, "rawlab-render") }
    private val lock = Any()
    private var pending: Pair<Long, T>? = null
    private var revision = 0L
    private var running = false
    private var closed = false

    fun submit(value: T): Long = synchronized(lock) {
        check(!closed)
        revision += 1
        pending = revision to value
        if (!running) {
            running = true
            worker.execute(::drain)
        }
        revision
    }

    private fun drain() {
        while (true) {
            val task = synchronized(lock) {
                val next = pending
                pending = null
                if (next == null || closed) { running = false; return }
                next
            }
            val result = runCatching { render(task.second) }
            val accepted = synchronized(lock) {
                if (!closed && task.first == revision) { publish(task.first, result); true } else false
            }
            if (!accepted) result.getOrNull()?.let(discard)
        }
    }

    /** 生命周期操作与渲染串行，但不能像预览请求一样被合并丢弃。 */
    fun performAfterPending(work: () -> Unit) = synchronized(lock) {
        check(!closed)
        worker.execute(work)
    }

    override fun close() = synchronized(lock) {
        if (!closed) {
            closed = true
            pending = null
            worker.execute { try { release() } finally { worker.shutdown() } }
        }
    }
}
