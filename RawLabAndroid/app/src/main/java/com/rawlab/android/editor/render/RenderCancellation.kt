package com.rawlab.android.editor.render

import java.util.concurrent.CancellationException

internal class RenderCancellation {
    @Volatile var isCancelled = false
        private set
    private var listener: (() -> Unit)? = null

    @Synchronized fun cancel() {
        if (isCancelled) return
        isCancelled = true
        listener?.invoke()
    }

    // 注册和注销与取消串行；已被替代的请求即使尚未进入 JNI 也不能漏掉信号。
    @Synchronized fun onCancel(action: (() -> Unit)?) {
        listener = action
        if (isCancelled) action?.invoke()
    }

    fun check() { if (isCancelled) throw CancellationException("Render superseded") }
}
