package com.rawlab.android.editor.render

import java.util.concurrent.Executors

/** 每个队列按提交顺序执行；任何已接受的写入都不能被较新的请求丢弃。 */
internal class SerialWorkQueue(private val release: () -> Unit) : AutoCloseable {
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "rawlab-adjustments") }
    private var closed = false
    @Synchronized fun <T> submit(work: () -> T, completed: (Result<T>) -> Unit) {
        check(!closed)
        worker.execute { completed(runCatching(work)) }
    }
    @Synchronized override fun close() {
        if (closed) return
        closed = true
        worker.execute { try { release() } finally { worker.shutdown() } }
    }
}
