package com.rawlab.android

import android.content.ClipData
import android.content.Intent
import android.net.Uri
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test

class SystemPhotoForwardingTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test fun viewPreservesDataTypeAndEveryGrantedClipUri() {
        val source = Intent(Intent.ACTION_VIEW).setDataAndType(Uri.parse("content://photos/one"), "image/jpeg").apply {
            clipData = ClipData.newRawUri("source", Uri.parse("content://photos/one"))
            clipData!!.addItem(ClipData.Item(Uri.parse("content://photos/two")))
        }
        val forwarded = SystemPhotoForwarding.intent(context, source)

        assertEquals(source.data, forwarded.data)
        assertEquals("content://photos/one", forwarded.data.toString())
        assertEquals("image/jpeg", forwarded.type)
        assertEquals(2, forwarded.clipData!!.itemCount)
        assertEquals("content://photos/one", forwarded.clipData!!.getItemAt(0).uri.toString())
        assertEquals("content://photos/two", forwarded.clipData!!.getItemAt(1).uri.toString())
        assertTrue(forwarded.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
        assertTrue(forwarded.getStringExtra(SystemPhotoForwarding.EXTRA_REQUEST_ID).orEmpty().isNotBlank())
    }

    @Test fun sendDoesNotTreatItsUnrelatedDataUriAsAStream() {
        val source = Intent(Intent.ACTION_SEND).setDataAndType(Uri.parse("content://unrelated/data"), "image/jpeg").apply {
            putExtra(Intent.EXTRA_STREAM, Uri.parse("content://photos/stream"))
            clipData = ClipData.newRawUri("source", Uri.parse("content://photos/clip"))
        }
        val forwarded = SystemPhotoForwarding.intent(context, source)
        val uris = (0 until forwarded.clipData!!.itemCount).map { forwarded.clipData!!.getItemAt(it).uri.toString() }

        assertEquals(listOf("content://photos/stream", "content://photos/clip"), uris)
    }
}
