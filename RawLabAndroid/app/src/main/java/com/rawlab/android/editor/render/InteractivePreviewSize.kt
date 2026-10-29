package com.rawlab.android.editor.render

internal class InteractivePreviewSize {
    private var previousInput: Long? = null

    fun edge(requested: Int, interactive: Boolean, now: Long): Int {
        if (!interactive) { previousInput = null; return requested }
        val rapid = previousInput?.let { now - it < 50 } == true
        previousInput = now
        // 连续快速输入先交付小预览；停顿和松手恢复较高精度，最终尺寸仍由视口决定。
        return minOf(requested, if (rapid) 480 else 1000)
    }
}
