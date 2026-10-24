package com.rawlab.android.engine

import com.rawlab.android.settings.ToneCurveMode
import com.rawlab.android.settings.ToneCurvePoint
import com.rawlab.android.settings.ToneCurveSettings

/** 画布直接采样渲染核心，避免另写一份插值公式。 */
internal object ToneCurveSampling {
    init { System.loadLibrary("rawlab-jni") }
    fun samples(settings: ToneCurveSettings, count: Int = 257): List<ToneCurvePoint> {
        require(settings.mode == ToneCurveMode.CUSTOM && count in 2..4097)
        val values = nativeSamples(settings.packed(), count)
        require(values.size == count)
        return values.mapIndexed { index, y -> ToneCurvePoint(index.toDouble() / (count - 1), y) }
    }
    @JvmStatic private external fun nativeSamples(points: DoubleArray, count: Int): DoubleArray
}
