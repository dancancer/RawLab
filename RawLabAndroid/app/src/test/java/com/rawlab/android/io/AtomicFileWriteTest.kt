package com.rawlab.android.io

import java.io.IOException
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.CopyOption
import java.nio.file.Files
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardCopyOption.REPLACE_EXISTING
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class AtomicFileWriteTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun atomicPublishReplacesExistingFileAndConsumesStaging() {
        val target = temporary.newFile("target").apply { writeText("old") }
        val staging = temporary.newFile("staging").apply { writeText("new") }
        val calls = mutableListOf<List<CopyOption>>()

        replaceFileAtomically(staging, target) { from, to, options ->
            calls += options.toList()
            Files.move(from, to, *options)
        }

        assertEquals(listOf(listOf(ATOMIC_MOVE, REPLACE_EXISTING)), calls)
        assertEquals("new", target.readText())
        assertFalse(staging.exists())
    }

    @Test fun unsupportedAtomicMoveFallsBackToReplacementExactlyOnce() {
        val target = temporary.newFile("target").apply { writeText("old") }
        val staging = temporary.newFile("staging").apply { writeText("new") }
        val calls = mutableListOf<List<CopyOption>>()

        replaceFileAtomically(staging, target) { from, to, options ->
            calls += options.toList()
            if (ATOMIC_MOVE in options) {
                assertEquals("old", target.readText())
                throw AtomicMoveNotSupportedException(from.toString(), to.toString(), "unsupported")
            }
            Files.move(from, to, *options)
        }

        assertEquals(listOf(listOf(ATOMIC_MOVE, REPLACE_EXISTING), listOf(REPLACE_EXISTING)), calls)
        assertEquals("new", target.readText())
        assertFalse(staging.exists())
    }

    @Test fun ordinaryIoFailureIsPropagatedWithoutRetryOrChangingOriginal() {
        val target = temporary.newFile("target").apply { writeText("original") }
        val staging = temporary.newFile("staging").apply { writeText("next") }
        val failure = IOException("permission denied")
        var calls = 0

        val thrown = assertThrows(IOException::class.java) {
            replaceFileAtomically(staging, target) { _, _, _ -> calls++; throw failure }
        }

        assertSame(failure, thrown)
        assertEquals(1, calls)
        assertEquals("original", target.readText())
        assertEquals("next", staging.readText())
    }

    @Test fun fallbackIoFailureIsPropagatedWithoutFurtherAttempts() {
        val target = temporary.newFile("target").apply { writeText("original") }
        val staging = temporary.newFile("staging").apply { writeText("next") }
        val failure = IOException("storage unavailable")
        var calls = 0

        val thrown = assertThrows(IOException::class.java) {
            replaceFileAtomically(staging, target) { from, to, _ ->
                calls++
                if (calls == 1) throw AtomicMoveNotSupportedException(from.toString(), to.toString(), "unsupported")
                throw failure
            }
        }

        assertSame(failure, thrown)
        assertEquals(2, calls)
        assertEquals("original", target.readText())
        assertEquals("next", staging.readText())
    }
}
