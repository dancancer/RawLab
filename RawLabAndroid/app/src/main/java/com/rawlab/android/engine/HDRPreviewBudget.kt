package com.rawlab.android.engine

import kotlin.math.min
import kotlin.math.sqrt

internal object HDRPreviewBudget {
    fun edge(width: Int, height: Int, requested: Int, heapBytes: Long = Runtime.getRuntime().maxMemory()): Int {
        require(width > 0 && height > 0 && requested > 0 && heapBytes > 0)
        // 前后两图各有 HDR/SDR 浮点面；给新旧发布帧、位图转换和普通编辑留出堆空间。
        val pixels=(heapBytes/4/80).coerceAtLeast(1)
        val scale=min(1.0,sqrt(pixels.toDouble()/(width.toDouble()*height)))
        return minOf(requested,1600,(maxOf(width,height)*scale).toInt().coerceAtLeast(1))
    }
}
