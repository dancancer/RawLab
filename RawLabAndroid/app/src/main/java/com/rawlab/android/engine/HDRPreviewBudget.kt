package com.rawlab.android.engine

import kotlin.math.min
import kotlin.math.sqrt

internal object HDRPreviewBudget {
    fun edge(width: Int, height: Int, requested: Int, heapBytes: Long = Runtime.getRuntime().maxMemory(),
        // k826：瞬时可用堆把未回收垃圾也算作占用，同一请求会在 GC 前后渲染出不同长边的预览面
        // （HDR 预览面长边偶发跳变/降质，重开工程才恢复）。先回收可回收内存再按存活集计算预算；
        // 该默认值只在渲染工作线程求值，真实存活压力仍会按原公式降档。
        availableHeapBytes: Long = Runtime.getRuntime().let { runtime ->
            System.gc()
            runtime.maxMemory() - runtime.totalMemory() + runtime.freeMemory()
        }): Int {
        require(width > 0 && height > 0 && requested > 0 && heapBytes > 0 && availableHeapBytes >= 0)
        // 前后两图各有 HDR/SDR 浮点面；给新旧发布帧、位图转换和普通编辑留出堆空间。
        // Compose 和预设提交可能仍持有旧帧；不能只依据设备的最大堆分配下一帧。
        val bytes = minOf(heapBytes / 4, availableHeapBytes / 2)
        val pixels=(bytes/80).coerceAtLeast(1)
        val scale=min(1.0,sqrt(pixels.toDouble()/(width.toDouble()*height)))
        return minOf(requested,1600,(maxOf(width,height)*scale).toInt().coerceAtLeast(1))
    }
}
