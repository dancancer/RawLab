package com.rawlab.android

import android.content.Intent
import org.junit.Assert.*
import org.junit.Test

class SystemPhotoForwardingTest {
    @Test fun successfulLaunchIsNotRepeated() {
        val request = Intent()
        val launched = mutableListOf<Intent>()

        SystemPhotoForwarding.start(request, request) { launched += it }

        assertEquals(1, launched.size)
        assertSame(request, launched.single())
    }

    @Test fun deniedGrantRetriesTheSameRequestOnce() {
        val request = Intent()
        val launched = mutableListOf<Intent>()

        SystemPhotoForwarding.start(request, request) {
            launched += it
            if (launched.size == 1) throw SecurityException("URI is not granted")
        }

        assertEquals(2, launched.size)
        assertTrue(launched.all { it === request })
    }

    @Test fun unrelatedLaunchFailureIsNotRetried() {
        val failure = IllegalStateException("launch failed")
        var attempts = 0

        val thrown = assertThrows(IllegalStateException::class.java) {
            SystemPhotoForwarding.start(Intent(), Intent()) { attempts++; throw failure }
        }

        assertSame(failure, thrown)
        assertEquals(1, attempts)
    }

    @Test fun fallbackFailureIsNotRetriedAgain() {
        val failure = SecurityException("fallback failed")
        var attempts = 0

        val thrown = assertThrows(SecurityException::class.java) {
            SystemPhotoForwarding.start(Intent(), Intent()) {
                attempts++
                if (attempts == 1) throw SecurityException("URI is not granted")
                throw failure
            }
        }

        assertSame(failure, thrown)
        assertEquals(2, attempts)
    }

    @Test fun revokedOriginalGrantRetriesWithoutTheGrant() {
        val source = object : Intent() {
            override fun getFlags() = FLAG_GRANT_READ_URI_PERMISSION
        }
        var attempts = 0

        SystemPhotoForwarding.start(Intent(), source) {
            attempts++
            if (attempts <= 2) throw SecurityException("grant revoked")
        }

        assertEquals(3, attempts)
    }
}
