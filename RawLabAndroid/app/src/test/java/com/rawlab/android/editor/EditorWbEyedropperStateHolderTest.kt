package com.rawlab.android.editor

import android.net.TestUri
import com.rawlab.android.editor.render.Work
import com.rawlab.android.editor.render.WorkResult
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.settings.WbProbeNotice
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class EditorWbEyedropperStateHolderTest {
    private fun makePhoto(kind: PhotoInputKind) = ImportedPhoto(
        uri = TestUri.of("/tmp/sample.${if (kind == PhotoInputKind.RAW) "arw" else "jpg"}"),
        name = "sample",
        file = File("/tmp/sample"),
        identity = PhotoIdentity("sample-${kind.name}"),
        inputKind = kind,
    )

    @Test
    fun appliesRawFixedAndRasterRelativeWhiteBalanceFromProbe() {
        for (kind in listOf(PhotoInputKind.RAW, PhotoInputKind.RASTER)) {
            EditorViewModelTestHarness().use { harness ->
                val photo = makePhoto(kind)
                val edits = EditSettings()
                val session = EditorDocumentSession(harness.createDependencies(), harness.scope).apply {
                    mutable.value = EditorState(photo = photo, edits = edits, exact = true)
                    incrementSourceRevision()
                    updateCurrentRevision(2L)
                }
                val submitted = mutableListOf<Work.WbProbe>()
                val applied = mutableListOf<EditSettings>()
                session.actions.submitRender = { work -> submitted += work as Work.WbProbe; 3L }
                session.actions.edit = { next, _, _ -> applied += next }
                val holder = EditorWbEyedropperStateHolder(session)
                val preview = Work.Preview(photo, edits, interactive = false, gpuMode = NativeProcessor.AUTO, edge = 1600)
                holder.recordAcceptedPreview(preview, edits, 1L, 2L)
                holder.setEnabled(true)
                holder.begin(0.4f, 0.6f)
                assertEquals(1, submitted.size)
                assertTrue(holder.state.value.waiting)

                holder.accept(
                    WorkResult.WbProbe(
                        submitted.single(),
                        NativeProcessor.WbProbeSample(NativeProcessor.WbProbeAvailability.AVAILABLE, 5300f, -11f, 25, 0),
                    ),
                )
                assertFalse(holder.state.value.waiting)
                assertNull(holder.state.value.notice)
                val next = applied.single()
                assertEquals(kind == PhotoInputKind.RAW, next.customWb)
                assertEquals(5300f, next.temperature, 0f)
                assertEquals(-11f, next.tint, 0f)
            }
        }
    }

    @Test
    fun rejectsOverexposedAndOutsideSamplesWithoutApplyingEdits() {
        EditorViewModelTestHarness().use { harness ->
            val photo = makePhoto(PhotoInputKind.RASTER)
            val edits = EditSettings()
            val session = EditorDocumentSession(harness.createDependencies(), harness.scope).apply {
                mutable.value = EditorState(photo = photo, edits = edits, exact = true)
                incrementSourceRevision()
                updateCurrentRevision(2L)
            }
            val submitted = mutableListOf<Work.WbProbe>()
            val applied = mutableListOf<EditSettings>()
            session.actions.submitRender = { work -> submitted += work as Work.WbProbe; 3L }
            session.actions.edit = { next, _, _ -> applied += next }
            val holder = EditorWbEyedropperStateHolder(session)
            holder.recordAcceptedPreview(Work.Preview(photo, edits, false, NativeProcessor.AUTO, edge = 1600), edits, 1L, 2L)
            holder.setEnabled(true)
            holder.begin(1.5f, 0.5f)
            assertEquals(WbProbeNotice.OUTSIDE, holder.state.value.notice)
            assertTrue(submitted.isEmpty())

            holder.begin(0.5f, 0.5f)
            holder.accept(
                WorkResult.WbProbe(
                    submitted.single(),
                    NativeProcessor.WbProbeSample(NativeProcessor.WbProbeAvailability.OVEREXPOSED, 6500f, 0f, 0, 81),
                ),
            )
            assertEquals(WbProbeNotice.OVEREXPOSED, holder.state.value.notice)
            assertTrue(applied.isEmpty())
        }
    }
}
