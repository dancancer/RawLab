package com.rawlab.android.editor.render

import java.util.concurrent.Executors

internal class RenderQueue<T, R>(
    private val render: (T, RenderCancellation) -> R,
    private val publish: (Long, Result<R>) -> Unit,
    private val release: () -> Unit,
    private val discard: (R) -> Unit = {},
    private val discardPending: (T) -> Unit = {},
    /** 「取消类」判据：代次失效时仅这类结果可吞；其余失败（如 BatchPublicationUncertain）仍须上抛。 */
    private val isCancellation: (Throwable) -> Boolean = { isExportCancellation(it) },
) : AutoCloseable {
    constructor(render: (T) -> R, publish: (Long, Result<R>) -> Unit, release: () -> Unit,
        discard: (R) -> Unit = {}, discardPending: (T) -> Unit = {},
        isCancellation: (Throwable) -> Boolean = { isExportCancellation(it) }) :
        this({ value, _ -> render(value) }, publish, release, discard, discardPending, isCancellation)

    private val worker = Executors.newSingleThreadExecutor { Thread(it, "rawlab-render") }
    private val lock = Any()
    private data class Task<T>(val revision: Long, val value: T, val cancellation: RenderCancellation = RenderCancellation())
    private var pending: Task<T>? = null
    private var revision = 0L
    private var running = false
    private var closed = false
    private var active: RenderCancellation? = null

    fun submit(value: T): Long = synchronized(lock) {
        check(!closed)
        revision += 1
        active?.cancel()
        pending?.value?.let(discardPending)
        pending = Task(revision, value)
        if (!running) {
            running = true
            worker.execute(::drain)
        }
        revision
    }

    /** 失效旧帧而不启动新渲染；已提交的新设置可以等待编辑页恢复。 */
    fun invalidate(): Long = synchronized(lock) {
        check(!closed)
        revision += 1
        active?.cancel()
        pending?.value?.let(discardPending)
        pending = null
        revision
    }

    private fun drain() {
        while (true) {
            val task = synchronized(lock) {
                val next = pending
                pending = null
                if (next == null || closed) { running = false; return }
                active = next.cancellation
                next
            }
            val result = runCatching { render(task.value, task.cancellation) }
            val accepted = synchronized(lock) {
                active = null
                if (!closed && task.revision == revision) { publish(task.revision, result); true } else false
            }
            // Q12（不确定≠取消）：代次失效只吞「取消类」结果；取消类之外的失败（如发布结果不确定，
            // 文件可能已落盘）仍以旧代次上抛，由消费方上屏并保留清理入口。close 路径消费者正在拆除，维持吞弃。
            if (!accepted) result.fold({ discard(it) },
                { error -> if (!closed && !isCancellation(error)) publish(task.revision, result) })
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
            pending?.value?.let(discardPending)
            pending = null
            active?.cancel()
            worker.execute { try { release() } finally { worker.shutdown() } }
        }
    }
}
