package com.rawlab.android.looks

import java.io.IOException
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class LookFailureTest {
    @Test fun invalidValidationKeepsATypedCauseWithoutBreakingIllegalArgumentCompatibility() {
        val root = Files.createTempDirectory("rawlab-look-invalid").toFile()
        val cause = UnsupportedOperationException("unsupported look format")
        try {
            val error = assertThrows(InvalidLookException::class.java) {
                LookLibrary(root, LookValidator { throw cause }).importLook("broken".byteInputStream(), "bad.cube")
            }
            assertSame(cause, error.cause)
            assertEquals(cause.message, error.message)
            assertTrue(error is IllegalArgumentException)
        } finally { root.deleteRecursively() }
    }

    @Test fun storageFailureIsNotReclassifiedAsAnInvalidLook() {
        val root = Files.createTempDirectory("rawlab-look-io").toFile()
        val cause = IOException("cannot read look storage")
        try {
            val error = assertThrows(IOException::class.java) {
                LookLibrary(root, LookValidator { throw cause }).importLook("valid".byteInputStream(), "good.cube")
            }
            assertSame(cause, error)
        } finally { root.deleteRecursively() }
    }

    @Test fun dcpFailureIsNotReclassifiedAsGenericInvalidLook() {
        val root = Files.createTempDirectory("rawlab-look-dcp-typed").toFile()
        val failure = DcpCompilationException(DcpFailureReason.INVALID_CALIBRATION)
        try {
            val error = assertThrows(DcpCompilationException::class.java) {
                LookLibrary(root, dcpCompiler = DcpCompiler { _, _ -> throw failure })
                    .importLook("dcp".byteInputStream(), "camera.dcp")
            }
            assertSame(failure, error)
            assertNotEquals(InvalidLookException::class.java, error.javaClass)
        } finally { root.deleteRecursively() }
    }
}
