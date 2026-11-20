package com.rawlab.android.editor

import com.rawlab.android.R
import com.rawlab.android.editor.render.Work
import com.rawlab.android.engine.NativeProcessingException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ForceGpuErrorMappingTest {
    @Test fun nativeProcessingExceptionDistinguishesForceGpuUnsupportedFromGenericUnsupported() {
        val forceGpu = NativeProcessingException(
            NativeProcessingException.UNSUPPORTED,
            "unsupported",
            NativeProcessingException.UNSUPPORTED_FORCE_GPU,
        )
        assertTrue(forceGpu.isForceGpuUnsupported)
        assertEquals(NativeProcessingException.UNSUPPORTED, forceGpu.status)
        assertEquals(NativeProcessingException.UNSUPPORTED_FORCE_GPU, forceGpu.unsupportedReason)

        val genericUnsupported = NativeProcessingException(
            NativeProcessingException.UNSUPPORTED,
            "unsupported",
            NativeProcessingException.UNSUPPORTED_NONE,
        )
        assertFalse(genericUnsupported.isForceGpuUnsupported)

        val twoArgLegacy = NativeProcessingException(
            NativeProcessingException.IO_ERROR,
            "io error",
        )
        assertFalse(twoArgLegacy.isForceGpuUnsupported)
        assertEquals(NativeProcessingException.UNSUPPORTED_NONE, twoArgLegacy.unsupportedReason)
    }

    @Test fun editorViewModelSurfacesDedicatedForceGpuUnsupportedMessageOnRenderFailure() {
        EditorViewModelTestHarness().use { harness ->
            val (_, uri) = harness.createTempPhoto("force_gpu_err.raw")
            val model = harness.onMain {
                val dependencies = harness.createDependencies(
                    renderHandler = { work, _ ->
                        if (work is Work.Preview && work.edits.film == "neutral") {
                            throw NativeProcessingException(
                                NativeProcessingException.UNSUPPORTED,
                                "unsupported",
                                NativeProcessingException.UNSUPPORTED_FORCE_GPU,
                            )
                        }
                        harness.defaultRender(work)
                    },
                )
                EditorViewModel(harness.app, dependencies)
            }
            try {
                harness.onMain { model.importPhoto(uri) }
                harness.awaitState(model) { it.canExport }

                harness.onMain {
                    model.selectFilm("neutral")
                }
                harness.awaitState(model) {
                    it.error == "str:${R.string.force_gpu_unsupported}"
                }
                assertEquals("str:${R.string.force_gpu_unsupported}", model.state.value.error)
                assertFalse(
                    model.state.value.error?.contains("str:${R.string.process_error}") == true,
                )
            } finally {
                harness.onMain { model.clearForTest() }
            }
        }
    }
}
