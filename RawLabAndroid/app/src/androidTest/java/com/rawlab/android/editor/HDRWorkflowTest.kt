package com.rawlab.android.editor

import android.net.Uri
import android.content.ContentUris
import android.provider.MediaStore
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.MainActivity
import com.rawlab.android.R
import com.rawlab.android.adjustments.AdjustmentPayload
import com.rawlab.android.adjustments.AdjustmentScope
import com.rawlab.android.engine.NativeHDRBridge
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.looks.LUTCompatibility
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference

class HDRWorkflowTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Test fun cameraRawModePersistsAndExportsBothJpegRenditions() = cameraModeWorkflow("bayer-demosaic.dng", 128, 96)

    @Test fun proRAWModePersistsAndExportsBothJpegRenditions() = cameraModeWorkflow("proraw-sample.dng", 0, 0)

    @Test fun proRAWMemoryRejectionKeepsEditsAndRetriesWithSmallerOutput() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("expectProRAWMemoryRejection") == "true")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val file = File(compose.activity.cacheDir, "proraw-budget-${UUID.randomUUID()}.dng")
        instrumentation.context.assets.open("proraw-sample.dng").use { input -> file.outputStream().use(input::copyTo) }
        val model = compose.activity.model
        val resolver = compose.activity.contentResolver
        val gallery = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        fun outputs(): Set<Long> = resolver.query(gallery, arrayOf(MediaStore.Images.Media._ID),
            "${MediaStore.Images.Media.RELATIVE_PATH} = ?", arrayOf("Pictures/RawLab/"), null)!!.use { cursor ->
            buildSet { while (cursor.moveToNext()) add(cursor.getLong(0)) }
        }
        val before = outputs()
        fun beginExport() {
            val accepted = java.util.concurrent.atomic.AtomicBoolean()
            compose.waitUntil(120_000) {
                if (!accepted.get()) compose.runOnUiThread {
                    if (model.state.value.canExport) model.beginExport { accepted.set(it) }
                }
                accepted.get()
            }
        }
        try {
            val hash = com.rawlab.android.batch.BatchFrozenSettings.checksum(file)
            compose.runOnUiThread { model.setGpuEnabled(false); model.importPhoto(Uri.fromFile(file)) }
            compose.waitUntil(120_000) { model.state.value.canExport || model.state.value.error != null }
            assertNull(model.state.value.error)
            compose.runOnUiThread { model.setHDRMode(true) }
            compose.waitUntil(120_000) { model.state.value.canExport && model.state.value.edits.isHDREditing || model.state.value.error != null }
            assertNull(model.state.value.error)
            val edits = model.state.value.edits
            beginExport()
            compose.runOnUiThread { model.export(null, com.rawlab.android.format.ExportFormat.HDR_JPEG) }
            compose.waitUntil(240_000) { model.state.value.error != null && model.state.value.operation == Operation.NONE }
            assertTrue(model.state.value.error!!.contains(compose.activity.getString(R.string.hdr_memory)))
            assertEquals(before, outputs())
            assertEquals(edits, model.state.value.edits)
            assertTrue(model.state.value.canExport)
            beginExport()
            compose.runOnUiThread { model.export(null, com.rawlab.android.format.ExportFormat.HDR_JPEG, 512) }
            compose.waitUntil(240_000) { model.state.value.canExport && outputs().size == before.size + 1 || model.state.value.error != null }
            assertNull(model.state.value.error)
            val copy = File(compose.activity.cacheDir, "proraw-budget-output-${UUID.randomUUID()}.jpg")
            try {
                resolver.openInputStream(ContentUris.withAppendedId(gallery, (outputs() - before).single()))!!.use { input ->
                    copy.outputStream().use(input::copyTo)
                }
                val info = requireNotNull(NativeHDRBridge.probe(copy))
                assertEquals(512, maxOf(info.width, info.height))
            } finally { copy.delete() }
            assertEquals(hash, com.rawlab.android.batch.BatchFrozenSettings.checksum(file))
        } finally { (outputs() - before).forEach { resolver.delete(ContentUris.withAppendedId(gallery, it), null, null) }; file.delete() }
    }

    private fun cameraModeWorkflow(fixture: String, width: Int, height: Int) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        assumeTrue("Supply -PrawlabTestProRAW", instrumentation.context.assets.list("")!!.contains(fixture))
        val source = File(compose.activity.cacheDir, "camera-hdr-ui-${UUID.randomUUID()}.dng")
        instrumentation.context.assets.open(fixture).use { input ->
            source.outputStream().use { input.copyTo(it) }
        }
        val model = compose.activity.model
        val resolver = compose.activity.contentResolver
        val galleryUri = MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        fun gallery(): Set<Long> = resolver.query(galleryUri, arrayOf(MediaStore.Images.Media._ID),
            "${MediaStore.Images.Media.RELATIVE_PATH} = ?", arrayOf("Pictures/RawLab/"), null)!!.use { cursor ->
            buildSet { while (cursor.moveToNext()) add(cursor.getLong(0)) }
        }
        fun ready() = compose.waitUntil(120_000) {
            val state = model.state.value
            if (state.error != null) throw AssertionError(state.error)
            state.canExport
        }
        fun mode(enabled: Boolean) {
            compose.onNode(hasContentDescription(compose.activity.getString(R.string.more)) and
                hasAnyAncestor(hasTestTag("editor-menu"))).performClick()
            compose.onNodeWithText(compose.activity.getString(R.string.editor_settings)).performClick()
            compose.onNodeWithTag("hdr-editing").performClick()
            compose.onNodeWithText(compose.activity.getString(R.string.confirm)).performClick()
            ready()
            assertEquals(enabled, model.state.value.edits.isHDREditing)
        }
        fun export(format: String, expectHDR: Boolean) {
            val before = gallery()
            compose.onNodeWithContentDescription(compose.activity.getString(R.string.export)).performClick()
            compose.onNodeWithTag("export-format-$format").performClick().assertIsSelected()
            compose.onNodeWithText(compose.activity.getString(R.string.save_album)).performScrollTo().performClick()
            compose.onNode(hasText(compose.activity.getString(R.string.export)) and hasClickAction()).performClick()
            ready()
            val created = gallery() - before
            try {
                assertEquals(1, created.size)
                val uri = ContentUris.withAppendedId(galleryUri, created.single())
                val copy = File(compose.activity.cacheDir, "camera-export-${UUID.randomUUID()}.jpg")
                try {
                    resolver.openInputStream(uri)!!.use { input -> copy.outputStream().use { input.copyTo(it) } }
                    assertEquals(expectHDR, NativeHDRBridge.probe(copy) != null)
                    val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    android.graphics.BitmapFactory.decodeFile(copy.path, bounds)
                    assertEquals(if (width > 0) width else model.state.value.photo!!.hdrSource!!.width, bounds.outWidth)
                    assertEquals(if (height > 0) height else model.state.value.photo!!.hdrSource!!.height, bounds.outHeight)
                    if (fixture == "proraw-sample.dng") {
                        val original = android.media.ExifInterface(source.path)
                        val result = android.media.ExifInterface(copy.path)
                        for (tag in listOf(android.media.ExifInterface.TAG_MAKE, android.media.ExifInterface.TAG_MODEL,
                            android.media.ExifInterface.TAG_DATETIME_ORIGINAL)) {
                            original.getAttribute(tag)?.let { assertEquals(tag, it, result.getAttribute(tag)) }
                        }
                        for (tag in listOf(android.media.ExifInterface.TAG_EXPOSURE_TIME, android.media.ExifInterface.TAG_F_NUMBER)) {
                            original.getAttribute(tag)?.let {
                                assertEquals(tag, original.getAttributeDouble(tag, 0.0), result.getAttributeDouble(tag, -1.0), .00001)
                            }
                        }
                        assertEquals(1, result.getAttributeInt(android.media.ExifInterface.TAG_ORIENTATION, 0))
                        assertNull(result.getAttribute("MakerNote"))
                        if (InstrumentationRegistry.getArguments().getString("retainProRAWOutputs") == "true") {
                            val artifact = File(compose.activity.getExternalFilesDir(null), "hdr-tests/proraw-output-$expectHDR.jpg")
                            artifact.parentFile!!.mkdirs(); copy.copyTo(artifact, overwrite = true)
                        }
                    }
                } finally {
                    copy.delete()
                }
            } finally {
                created.forEach { resolver.delete(ContentUris.withAppendedId(galleryUri, it), null, null) }
            }
        }
        try {
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(source)) }
            ready()
            assertTrue(model.state.value.photo!!.isCameraRawHDR)
            assertEquals(fixture == "proraw-sample.dng", model.state.value.photo!!.hdrSource!!.isProRAW)
            assertFalse(model.state.value.edits.isHDREditing)
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(exposure = .5f)) }
            ready()

            mode(true)
            if (fixture == "proraw-sample.dng") assertEquals(2, model.state.value.edits.proRAWDecodeVersion)
            assertEquals(0f, model.state.value.edits.exposure)
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(exposure = 1.25f)) }
            ready()
            mode(false)
            assertEquals(.5f, model.state.value.edits.exposure)
            mode(true)
            assertEquals(1.25f, model.state.value.edits.exposure)
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(source)) }
            ready()
            assertTrue(model.state.value.edits.isHDREditing)
            assertEquals(1.25f, model.state.value.edits.exposure)

            if (fixture == "proraw-sample.dng") {
                val captured = AtomicReference<Result<AdjustmentPayload>?>(null)
                compose.runOnUiThread {
                    assertEquals(2, requireNotNull(model.copyAdjustments(AdjustmentScope.All)).payloadVersion)
                    model.capturePresetAdjustments(AdjustmentScope.All) { captured.set(it) }
                }
                compose.waitUntil(15_000) { captured.get() != null }
                assertEquals(2, captured.get()!!.getOrThrow().payloadVersion)
                assertTrue(captured.get()!!.getOrThrow().fields.contains(com.rawlab.android.adjustments.AdjustmentField.HDR_TEMPERATURE))
                val presetRoot = File(compose.activity.cacheDir, "proraw-preset-${UUID.randomUUID()}")
                try {
                    val preset = com.rawlab.android.presets.AdjustmentPresetStore(presetRoot)
                        .create("ProRAW HDR", captured.get()!!.getOrThrow())
                    compose.runOnUiThread { model.edit(model.state.value.edits.copy(exposure = -.25f)) }
                    ready()
                    compose.runOnUiThread { model.showQuickPresets(); model.applyPresetToCurrentPhoto(preset) }
                    compose.waitUntil(60_000) { model.quickPreset.value.phase in setOf(QuickPresetPhase.SAVED, QuickPresetPhase.FAILED) }
                    assertEquals(model.quickPreset.value.message, QuickPresetPhase.SAVED, model.quickPreset.value.phase)
                    ready()
                    assertEquals(1.25f, model.state.value.edits.exposure)
                    compose.runOnUiThread { model.undoQuickPreset() }
                    compose.waitUntil(60_000) { model.quickPreset.value.phase in setOf(QuickPresetPhase.UNDONE, QuickPresetPhase.UNDO_FAILED) }
                    assertEquals(QuickPresetPhase.UNDONE, model.quickPreset.value.phase)
                    ready()
                    assertEquals(-.25f, model.state.value.edits.exposure)
                    compose.runOnUiThread { model.closeQuickPresets(); model.edit(model.state.value.edits.copy(exposure = 1.25f)) }
                    ready()
                } finally { presetRoot.deleteRecursively() }
            }

            export("HDR_JPEG", expectHDR = true)
            export("JPEG", expectHDR = false)
        } finally {
            source.delete()
        }
    }

    @Test fun freshImportPresetMonitoringModeSwitchAndExportChoices() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        assumeTrue("Supply -PrawlabTestHDRJPEG", instrumentation.context.assets.list("")!!.contains("hdr-sample.jpg"))
        val fixture=InstrumentationRegistry.getArguments().getString("hdrFixture") ?: "hdr-sample.jpg"
        val source = File(compose.activity.cacheDir, "hdr-ui-${UUID.randomUUID()}.jpg")
        val screenshots=File(compose.activity.getExternalFilesDir(null),"hdr-tests").apply { mkdirs() }
        fun capture(name: String) {
            compose.waitForIdle()
            val bitmap=requireNotNull(instrumentation.uiAutomation.takeScreenshot())
            File(screenshots,name).outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it) }
            bitmap.recycle()
        }
        val look = File(compose.activity.cacheDir,"hdr-ui-${UUID.randomUUID()}.cube").apply {
            writeText("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n")
        }
        instrumentation.context.assets.open(fixture).use { input -> source.outputStream().use { input.copyTo(it) } }
        try {
            compose.runOnUiThread { compose.activity.model.importPhoto(Uri.fromFile(source)) }
            fun ready() = compose.waitUntil(120_000) {
                val state = compose.activity.model.state.value
                if (state.error != null) throw AssertionError(state.error)
                state.canExport
            }
            ready()
            capture("hdr-editor.png")
            compose.runOnIdle {
                assertTrue(compose.activity.model.state.value.edits.isHDREditing)
                assertEquals(EditSaveState.NONE,compose.activity.model.state.value.saveState)
            }
            val captured = AtomicReference<Result<AdjustmentPayload>?>(null)
            compose.runOnUiThread { compose.activity.model.capturePresetAdjustments(AdjustmentScope.All) { captured.set(it) } }
            compose.waitUntil(15_000) { captured.get() != null }
            assertEquals(2, captured.get()!!.getOrThrow().payloadVersion)
            compose.onNodeWithTag("hdr-monitoring").performClick()
            compose.onNodeWithTag("hdr-histogram").assertExists()
            compose.onNodeWithTag("hdr-preview-sdr").performClick()
            compose.onNodeWithTag("hdr-false-color").performClick().assertIsOn()
            compose.waitUntil(15_000) { compose.onAllNodes(SemanticsMatcher.expectValue(
                androidx.compose.ui.semantics.SemanticsProperties.StateDescription,compose.activity.getString(R.string.hdr_false_color))).fetchSemanticsNodes().isNotEmpty() }
            capture("hdr-monitoring.png")
            compose.onNodeWithTag("hdr-false-color").performClick().assertIsOff()
            compose.onNodeWithTag("hdr-preview-auto").performClick()
            compose.onNodeWithTag("hdr-monitoring").performClick()
            fun mode(enabled: Boolean) {
                compose.onNode(hasContentDescription(compose.activity.getString(R.string.more)) and hasAnyAncestor(hasTestTag("editor-menu"))).performClick()
                compose.onNodeWithText(compose.activity.getString(R.string.editor_settings)).performClick()
                compose.onNodeWithTag("hdr-editing").performClick()
                compose.onNodeWithText(compose.activity.getString(R.string.confirm)).performClick()
                ready()
                compose.runOnIdle { assertEquals(enabled, compose.activity.model.state.value.edits.isHDREditing) }
            }
            mode(false)
            compose.onNodeWithTag("hdr-monitoring").assertDoesNotExist()
            val draft=requireNotNull(LUTCompatibility.parse(NativeProcessor.inspectLutCompatibility(look)))
            compose.runOnUiThread { compose.activity.model.importLook(Uri.fromFile(look)) }
            val candidate=draft.candidates.first { draft.applying(it,true)!=null }
            compose.waitUntil(60_000) { compose.onAllNodes(hasTestTag("lut-${candidate.id}") and isEnabled()).fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithTag("lut-${candidate.id}").performScrollTo().performClick()
            compose.onNodeWithTag("lut-compatibility-confirm").assertIsEnabled()
            capture("sdr-lut-wizard.png")
            compose.onNodeWithText(compose.activity.getString(R.string.cancel)).performClick()
            ready()
            mode(true)
            compose.onNodeWithContentDescription(compose.activity.getString(R.string.export)).performClick()
            compose.onNodeWithTag("export-format-HDR_JPEG").assertExists().assertIsSelected()
            capture("hdr-export.png")
            compose.onNodeWithTag("export-format-JPEG").performClick().assertIsSelected()
            compose.onNodeWithTag("export-format-PNG").performClick().assertIsSelected()
            compose.onNodeWithTag("export-format-DNG").performClick().assertIsSelected()
            compose.onNodeWithTag("export-format-HDR_JPEG").performClick()
            compose.onNodeWithTag("export-size").performScrollTo().performClick()
            compose.onNodeWithTag("export-size-custom").performClick()
            compose.onNodeWithTag("export-size-custom-value").performScrollTo().performTextReplacement("128")
            compose.onNodeWithText(compose.activity.getString(R.string.save_album)).performScrollTo().performClick()
            val resolver=compose.activity.contentResolver
            fun gallery(): Set<Long> = resolver.query(MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                arrayOf(MediaStore.Images.Media._ID),"${MediaStore.Images.Media.RELATIVE_PATH} = ?",arrayOf("Pictures/RawLab/"),null)!!.use { cursor ->
                buildSet { while(cursor.moveToNext())add(cursor.getLong(0)) }
            }
            val before=gallery()
            compose.onNode(hasText(compose.activity.getString(R.string.export)) and hasClickAction()).performClick()
            ready()
            val created=gallery()-before
            try {
                assertEquals(1,created.size)
                val uri=ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI,created.single())
                val copy=File(compose.activity.cacheDir,"hdr-gallery-${UUID.randomUUID()}.jpg")
                try {
                    resolver.openInputStream(uri)!!.use { input -> copy.outputStream().use { input.copyTo(it) } }
                    val info=requireNotNull(NativeHDRBridge.probe(copy))
                    val sourceInfo=requireNotNull(NativeHDRBridge.probe(source))
                    assertEquals(minOf(128,maxOf(sourceInfo.width,sourceInfo.height)),maxOf(info.width,info.height))
                } finally { copy.delete() }
            } finally { created.forEach { resolver.delete(ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI,it),null,null) } }
        } finally { source.delete();look.delete() }
    }
}
