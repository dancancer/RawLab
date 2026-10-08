package com.rawlab.android

import org.junit.Assert.*
import org.junit.Test

class UpdateReleaseTest {
    private fun release(tag: String, draft: Boolean = false, preview: Boolean = false,
                        assets: List<String> = listOf("RawLab-Android-0.5.0.apk")) =
        UpdateRelease.select(tag, draft, preview, "Notes", assets, "0.4.0")

    @Test fun comparesVersionsNumericallyAndNeverDowngrades() {
        assertEquals("0.10.0", release("v0.10.0")?.version)
        assertNull(release("v0.4"))
        assertNull(release("v0.3.9"))
        assertEquals("https://github.com/dancancer/RawLab/releases/tag/v0.4.1", release("v0.4.1")?.url)
    }

    @Test fun rejectsInvalidTagsAndIgnoresUnpublishedOrOtherPlatformReleases() {
        for (tag in listOf("v0.5.0-beta", "v0.5.0/evil", "bad", "0.-1.0")) {
            assertThrows(IllegalArgumentException::class.java) { release(tag) }
        }
        assertNull(release("v0.5.0", draft = true))
        assertNull(release("v0.5.0", preview = true))
        assertNull(release("v0.5.0", assets = listOf("RawLab-Mac-arm64.zip")))
    }

    @Test fun manualChecksBypassOptOutAndDailyInterval() {
        assertTrue(UpdateRelease.shouldCheck(true, false, 100, 101))
        assertFalse(UpdateRelease.shouldCheck(false, false, 0, 100000))
        assertFalse(UpdateRelease.shouldCheck(false, true, 100, 101))
        assertTrue(UpdateRelease.shouldCheck(false, true, 100, 86500))
        assertTrue(UpdateRelease.shouldCheck(false, true, 200, 100))
    }
}
