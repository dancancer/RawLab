package com.rawlab.android.engine

import com.rawlab.android.settings.ToneCurveChannel
import com.rawlab.android.settings.ToneCurveMode
import com.rawlab.android.settings.ToneCurveParametric
import com.rawlab.android.settings.ToneCurvePoint
import com.rawlab.android.settings.ToneCurveSettings

/** 画布直接采样渲染核心，避免另写一份插值公式。 */
internal object ToneCurveSampling {
    init { System.loadLibrary("rawlab-jni") }
    fun samples(settings: ToneCurveSettings, count: Int = 257): List<ToneCurvePoint> =
        samples(settings, ToneCurveChannel.RGB, count)

    fun samples(
        settings: ToneCurveSettings,
        channel: ToneCurveChannel = ToneCurveChannel.RGB,
        count: Int = 257,
    ): List<ToneCurvePoint> {
        val shape = settings.shape(channel)
        require(shape.mode == ToneCurveMode.CUSTOM && count in 2..4097)
        val parametricArray = if (channel == ToneCurveChannel.RGB && !settings.parametric.isDefault) {
            settings.parametric.packed()
        } else null
        val values = nativeSamples(shape.packed(), parametricArray, count)
        require(values.size == count)
        return values.mapIndexed { index, y -> ToneCurvePoint(index.toDouble() / (count - 1), y) }
    }

    private fun ToneCurveParametric.packed(): DoubleArray = doubleArrayOf(
        highlights, lights, darks, shadows, splitShadow, splitMidtone, splitHighlight,
    )

    @JvmStatic private external fun nativeSamples(points: DoubleArray, parametric: DoubleArray?, count: Int): DoubleArray
}
