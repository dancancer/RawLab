package com.rawlab.android.photo

import org.junit.Assert.*
import org.junit.Test

class SystemPhotoIntentTest {
    @Test fun viewUsesOneLocalUri() {
        assertEquals(listOf("content://photos/one"), SystemPhotoIntent.uris("android.intent.action.VIEW",
            data = "content://photos/one", streams = listOf("content://photos/two")))
        assertEquals(emptyList<String>(), SystemPhotoIntent.uris("android.intent.action.VIEW", data = "https://example.com/a.jpg"))
    }
    @Test fun sendUsesStreamOrClipFallback() {
        assertEquals(listOf("content://photos/one"), SystemPhotoIntent.uris("android.intent.action.SEND",
            streams = listOf("content://photos/one"), clip = listOf("content://photos/two")))
        assertEquals(listOf("content://photos/two"), SystemPhotoIntent.uris("android.intent.action.SEND",
            clip = listOf("content://photos/two", "content://photos/three")))
    }
    @Test fun sendMultiplePreservesEveryUniqueGrantedUri() {
        assertEquals(listOf("content://photos/one", "content://photos/two", "file:///sdcard/three.x3f"),
            SystemPhotoIntent.uris("android.intent.action.SEND_MULTIPLE",
                streams = listOf("content://photos/one", "content://photos/two"),
                clip = listOf("content://photos/two", "file:///sdcard/three.x3f", "https://example.com/no.jpg")))
        assertTrue(SystemPhotoIntent.uris("android.intent.action.MAIN", data = "content://photos/one").isEmpty())
    }
}
