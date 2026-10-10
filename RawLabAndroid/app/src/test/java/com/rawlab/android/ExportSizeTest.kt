package com.rawlab.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ExportSizeTest {
    @Test fun presetsAndOriginalUseTheExpectedLongEdge() {
        assertNull(ExportSize.parse(ExportSizeChoice.ORIGINAL, ""))
        assertEquals(2048, ExportSize.parse(ExportSizeChoice.EDGE_2048, ""))
        assertEquals(3000, ExportSize.parse(ExportSizeChoice.EDGE_3000, ""))
        assertEquals(4096, ExportSize.parse(ExportSizeChoice.EDGE_4096, ""))
    }

    @Test fun customLongEdgeAcceptsOnlyTheContractRange() {
        assertEquals(1, ExportSize.parseCustom("1"))
        assertEquals(65535, ExportSize.parseCustom("65535"))
        assertNull(ExportSize.parseCustom("0"))
        assertNull(ExportSize.parseCustom("65536"))
        assertNull(ExportSize.parseCustom("100000"))
        assertNull(ExportSize.parseCustom("-2048"))
        assertNull(ExportSize.parseCustom("not-a-size"))
        assertTrue(ExportSize.isValid(null))
        assertFalse(ExportSize.isValid(0))
        assertFalse(ExportSize.isValid(65536))
    }

    @Test fun oldBatchJobsDefaultToOriginalSize() {
        val source = BatchSourceSnapshot(PhotoIdentity("source"), java.io.File("source.raw"), EditSettings())
        assertNull(BatchJob(source, emptyList()).outputLongEdge)
    }
}
