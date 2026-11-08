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
        startActivity(SystemPhotoForwarding.intent(this, intent))
        finish()
    }
}

internal object SystemPhotoForwarding {
    const val EXTRA_REQUEST_ID = "com.rawlab.android.extra.SYSTEM_PHOTO_REQUEST_ID"

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
                val forwarded = ClipData.newUri(context.contentResolver, "RawLab", uris.first())
                uris.drop(1).forEach { forwarded.addItem(ClipData.Item(it)) }
                clipData = forwarded
            }
        }
    }
}
