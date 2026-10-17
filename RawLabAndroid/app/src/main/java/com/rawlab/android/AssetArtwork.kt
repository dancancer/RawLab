package com.rawlab.android

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

// ============================================================================
//  随包插图（胶片封面、配方插图）的异步解码
//  缩样倍数按显示尺寸计算：1254 px 的胶片封面与 256 px 的配方插图共用一条规则
// ============================================================================

/** 保证短边不小于显示尺寸的最大 2 的幂缩样；尺寸未知或图为空时不缩样 */
internal fun artworkSampleSize(width: Int, height: Int, target: Int): Int {
    var sample = 1
    while (target > 0 && minOf(width, height) / (sample * 2) >= target) sample *= 2
    return sample
}

/** 读取失败返回 null，调用方显示通用图标 */
private fun decodeAsset(context: Context, path: String, target: Int): Bitmap? = runCatching {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    context.assets.open(path).use { BitmapFactory.decodeStream(it, null, bounds) }
    val options = BitmapFactory.Options().apply { inSampleSize = artworkSampleSize(bounds.outWidth, bounds.outHeight, target) }
    context.assets.open(path).use { BitmapFactory.decodeStream(it, null, options) }
}.getOrNull()

@Composable
internal fun assetBitmap(path: String, size: Dp): Bitmap? {
    val context = LocalContext.current
    val target = with(LocalDensity.current) { size.roundToPx() }
    val bitmap by produceState<Bitmap?>(null, path, target) {
        value = withContext(Dispatchers.IO) { decodeAsset(context, path, target) }
    }
    return bitmap
}
