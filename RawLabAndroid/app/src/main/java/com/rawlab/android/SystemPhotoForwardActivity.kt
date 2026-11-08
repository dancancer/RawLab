package com.rawlab.android

import android.app.Activity
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import java.util.UUID

/** 只负责把外部分享的 URI 授权完整转交给主界面，不承载编辑状态。 */
class SystemPhotoForwardActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        SystemPhotoForwarding.start(SystemPhotoForwarding.intent(this, intent), intent, ::startActivity)
        finish()
    }
}

internal object SystemPhotoForwarding {
    const val EXTRA_REQUEST_ID = "com.rawlab.android.extra.SYSTEM_PHOTO_REQUEST_ID"

    fun start(intent: Intent, source: Intent, startActivity: (Intent) -> Unit) {
        try {
            startActivity(intent)
        } catch (_: SecurityException) {
            if (source.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0) {
                // 只重授来源已经交给本 Activity 的授权；否则 finish 后可读照片的临时授权也会消失。
                // 没有 ClipData 时用文本占位，避免 EXTRA_STREAM 中未授权 URI 被系统自动提升为授权。
                intent.clipData = source.clipData ?: ClipData.newPlainText("RawLab", "")
                try {
                    startActivity(intent)
                    return
                } catch (_: SecurityException) { }
            }
            // 保留 ClipData，避免 Android 从 EXTRA_STREAM 重建它并再次添加读取授权标志。
            // 来源授权也已失效时，让主界面沿现有路径逐张报告读取失败。
            intent.removeFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            startActivity(intent)
        }
    }

    @Suppress("DEPRECATION")
    fun intent(context: Context, source: Intent): Intent {
        val streams = runCatching {
            if (source.action == Intent.ACTION_SEND_MULTIPLE) {
                if (Build.VERSION.SDK_INT >= 33) source.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
                else source.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
            } else listOfNotNull(
                if (Build.VERSION.SDK_INT >= 33) source.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                else source.getParcelableExtra<android.os.Parcelable>(Intent.EXTRA_STREAM) as? Uri,
            )
        }.getOrDefault(emptyList())
        val clip = source.clipData?.let { data -> (0 until data.itemCount).mapNotNull { data.getItemAt(it).uri } }.orEmpty()
        val uris = buildList {
            if (source.action == Intent.ACTION_VIEW) source.data?.let(::add)
            addAll(streams)
            addAll(clip)
        }.distinct()
        return Intent(context, MainActivity::class.java).apply {
            action = source.action
            setDataAndType(source.data, source.type)
            putExtras(source)
            putExtra(EXTRA_REQUEST_ID, UUID.randomUUID().toString())
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            if (uris.isNotEmpty()) {
                // 转发前不查询外部 provider 的类型，未授权 URI 的读取失败交给主界面处理。
                val forwarded = ClipData.newRawUri("RawLab", uris.first())
                uris.drop(1).forEach { forwarded.addItem(ClipData.Item(it)) }
                clipData = forwarded
            }
        }
    }
}
