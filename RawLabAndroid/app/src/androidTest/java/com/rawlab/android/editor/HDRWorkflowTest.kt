package com.rawlab.android.editor

import android.net.Uri
import android.content.ContentUris
import android.content.ContentValues
import android.os.Build
import android.provider.MediaStore
import android.view.accessibility.AccessibilityNodeInfo
import androidx.compose.ui.geometry.Offset
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

    @Test fun hdrLookImportsThroughFilesAndSurvivesUndoAndReopen() {
        assumeTrue(Build.VERSION.SDK_INT >= 29)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        assumeTrue(instrumentation.context.assets.list("")!!.contains("hdr-sample.jpg"))
        val source = File(compose.activity.cacheDir, "hdr-look-${UUID.randomUUID()}.jpg")
        instrumentation.context.assets.open("hdr-sample.jpg").use { input -> source.outputStream().use(input::copyTo) }
        val model = compose.activity.model
        val resolver = compose.activity.contentResolver
        val name = "Acceptance HDR ${UUID.randomUUID().toString().take(8)}.cube"
        val uri = requireNotNull(resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, "application/octet-stream")
        }))
        var asset: File? = null
        fun ready() = compose.waitUntil(120_000) {
            val state = model.state.value
            if (state.error != null) throw AssertionError(state.error)
            state.canExport
        }
        fun click(node: AccessibilityNodeInfo?): Boolean {
            var current = node
            while (current != null) {
                if (current.isClickable && current.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return true
                current = current.parent
            }
            return false
        }
        try {
            requireNotNull(resolver.openOutputStream(uri)).use { output ->
                instrumentation.context.assets.open("hdr-look-linear.cube").use { it.copyTo(output) }
                output.write("\n# $name\n".toByteArray())
            }
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(source)) }
            ready()
            val before = model.state.value.preview!!.hdr!!.result
            val lookGroup = "editor-group-looks"
            compose.onNodeWithTag("editor-groups").performScrollToNode(hasTestTag(lookGroup))
            compose.onNodeWithTag(lookGroup).assertIsEnabled().performClick()
            compose.onNodeWithTag("hdr-look-silver").performScrollTo().performClick()
            compose.waitUntil(30_000) { model.state.value.edits.hdr?.lookSettings?.name == "HDR Silver" }
            ready()
            assertEquals(0f, model.state.value.edits.hdr!!.effectSettings.grainAmount, 0f)
            compose.onNodeWithTag("hdr-look-silver-master").performScrollTo().performClick()
            compose.waitUntil(30_000) { model.state.value.edits.hdr?.effectSettings?.grainAmount == 14f }
            ready()
            val master = model.state.value.edits.hdr!!
            assertEquals(-8f, master.toneSettings.blackPoint, 0f)
            assertEquals(14f, master.toneSettings.curveStrength, .0001f)
            compose.onNodeWithTag("hdr-look-import").performScrollTo().performClick()
            val accessibility = instrumentation.uiAutomation
            fun pickerRoot() = accessibility.rootInActiveWindow?.takeIf { it.packageName.toString().endsWith("documentsui") }
            fun findFile() = pickerRoot()?.findAccessibilityNodeInfosByText(name)?.firstOrNull { it.text?.toString() == name }
            compose.waitUntil(10_000) { pickerRoot() != null }
            if (findFile() == null) {
                fun navigation(node: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
                    if (node == null) return null
                    if (node.contentDescription?.toString() in setOf("Show roots", "Open navigation drawer")) return node
                    return (0 until node.childCount).firstNotNullOfOrNull { navigation(node.getChild(it)) }
                }
                assertTrue("Open the Files location drawer", click(navigation(pickerRoot())))
                compose.waitUntil(10_000) { pickerRoot()?.findAccessibilityNodeInfosByText("Downloads")?.isNotEmpty() == true }
                assertTrue(click(pickerRoot()?.findAccessibilityNodeInfosByText("Downloads")?.firstOrNull()))
            }
            compose.waitUntil(10_000) { findFile() != null }
            assertTrue("Choose the HDR CUBE in Files", click(findFile()))
            compose.waitUntil(30_000) { model.state.value.edits.hdr?.lookSettings?.name == name.removeSuffix(".cube") ||
                model.state.value.error != null }
            ready()
            val imported = model.state.value.edits.hdr!!
            asset = imported.lookSettings.asset(model.storage.hdrLookDirectory)
            assertTrue(asset!!.isFile)
            assertFalse(before.hdr.contentEquals(model.state.value.preview!!.hdr!!.result.hdr))
            assertFalse(before.sdr.contentEquals(model.state.value.preview!!.hdr!!.result.sdr))
            compose.onNodeWithTag("adjustment-value-${R.string.transfer_field_strength}").performScrollTo().performClick()
            compose.onNodeWithTag("adjustment-input").performTextReplacement("65")
            compose.onNodeWithTag("adjustment-input-apply").assertIsEnabled().performClick()
            ready()
            val edited = model.state.value.edits.hdr!!
            assertEquals(7, edited.processingVersion)
            assertEquals(.65f, edited.lookSettings.strength, 0f)
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(source)) }
            ready()
            assertEquals(edited, model.state.value.edits.hdr)
            if (compose.onAllNodesWithTag("hdr-look-clear").fetchSemanticsNodes().isEmpty()) {
                compose.onNodeWithTag("editor-groups").performScrollToNode(hasTestTag(lookGroup))
                compose.onNodeWithTag(lookGroup).performClick()
            }
            compose.onNodeWithTag("hdr-look-clear").performScrollTo().performClick()
            ready()
            assertTrue(model.state.value.edits.hdr!!.lookSettings.isDefault)
            compose.onNode(hasContentDescription(compose.activity.getString(R.string.more)) and
                hasAnyAncestor(hasTestTag("editor-menu"))).performClick()
            compose.onNodeWithTag("adjustment-menu-undo").performClick()
            ready()
            assertEquals(edited, model.state.value.edits.hdr)
        } finally {
            source.delete()
            asset?.delete()
            resolver.delete(uri, null, null)
        }
    }

    @Test fun hdrEffectsAndDetailPersistIndependently() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        assumeTrue(instrumentation.context.assets.list("")!!.contains("hdr-sample.jpg"))
        val source = File(compose.activity.cacheDir, "hdr-effects-${UUID.randomUUID()}.jpg")
        instrumentation.context.assets.open("hdr-sample.jpg").use { input -> source.outputStream().use(input::copyTo) }
        val model = compose.activity.model
        fun ready() = compose.waitUntil(120_000) {
            val state = model.state.value
            if (state.error != null) throw AssertionError(state.error)
            state.canExport
        }
        fun edit(tool: Int, label: Int, value: String) {
            compose.onNodeWithTag("editor-tools").performScrollToNode(hasTestTag("editor-tool-$tool"))
            compose.onNodeWithTag("editor-tool-$tool").assertIsEnabled().performClick()
            compose.onNodeWithTag("adjustment-value-$label").performScrollTo().performClick()
            compose.onNodeWithTag("adjustment-input").performTextReplacement(value)
            compose.onNodeWithTag("adjustment-input-apply").assertIsEnabled().performClick()
            ready()
        }
        fun frame() = model.state.value.preview!!.hdr!!.result
        fun openGroup(group: String) {
            val tag = "editor-group-$group"
            compose.onNodeWithTag("editor-groups").performScrollToNode(hasTestTag(tag))
            if (compose.onAllNodes(hasTestTag(tag) and isSelected()).fetchSemanticsNodes().isEmpty()) {
                compose.onNodeWithTag(tag).performClick()
            }
        }
        try {
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(source)) }
            ready()
            val original = frame()
            val dormant = model.state.value.edits.sdrSnapshot
            openGroup("effects")
            edit(12, R.string.vignette_amount, "-55")
            val dark = frame()
            assertFalse(original.hdr.contentEquals(dark.hdr))
            assertFalse(original.sdr.contentEquals(dark.sdr))
            edit(13, R.string.grain_amount, "40")
            val edited = model.state.value.edits
            assertEquals(5, edited.hdr!!.processingVersion)
            assertEquals(40f, edited.hdr.effectSettings.grainAmount)
            assertEquals(dormant, edited.sdrSnapshot)
            assertFalse(dark.hdr.contentEquals(frame().hdr))
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(source)) }
            ready()
            assertEquals(edited.hdr, model.state.value.edits.hdr)
            openGroup("effects")
            for ((tool, label, amount) in listOf(Triple(22, R.string.clarity, "50"), Triple(23, R.string.dehaze, "-40"))) {
                val before = frame()
                edit(tool, label, amount)
                assertFalse(before.hdr.contentEquals(frame().hdr))
            }
            openGroup("detail")
            val beforeSharpening = frame()
            edit(10, R.string.sharpening, "125")
            assertFalse(beforeSharpening.hdr.contentEquals(frame().hdr))
            val beforeDenoise = frame()
            edit(11, R.string.denoise, "65")
            val detailEdit = model.state.value.edits
            assertEquals(6, detailEdit.hdr!!.processingVersion)
            assertEquals(com.rawlab.android.settings.HDRDetailSettings(1.25f, .5f, -.4f, .65f), detailEdit.hdr.detailSettings)
            assertEquals(dormant, detailEdit.sdrSnapshot)
            assertFalse(beforeDenoise.hdr.contentEquals(frame().hdr))
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(source)) }
            ready()
            assertEquals(detailEdit.hdr, model.state.value.edits.hdr)
        } finally { source.delete() }
    }

    @Test fun hdrRenditionControlsRenderIndependentPlanesAndPersist() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        assumeTrue(instrumentation.context.assets.list("")!!.contains("hdr-sample.jpg"))
        val source = File(compose.activity.cacheDir, "hdr-rendition-${UUID.randomUUID()}.jpg")
        instrumentation.context.assets.open("hdr-sample.jpg").use { input -> source.outputStream().use(input::copyTo) }
        val model = compose.activity.model
        fun ready() = compose.waitUntil(120_000) {
            val state = model.state.value
            if (state.error != null) throw AssertionError(state.error)
            state.canExport
        }
        fun menu() = compose.onNode(hasContentDescription(compose.activity.getString(R.string.more)) and
            hasAnyAncestor(hasTestTag("editor-menu"))).performClick()
        fun settings() {
            menu()
            compose.onNodeWithText(compose.activity.getString(R.string.editor_settings)).performClick()
        }
        fun close() = compose.onNodeWithText(compose.activity.getString(R.string.confirm)).performClick()
        fun commit(label: Int, value: String) {
            compose.onNodeWithTag("adjustment-value-$label").performScrollTo().performClick()
            compose.onNodeWithTag("adjustment-input").performTextReplacement(value)
            compose.onNodeWithTag("adjustment-input-apply").assertIsEnabled().performClick()
            ready()
        }
        fun frame() = model.state.value.preview!!.hdr!!.result
        try {
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(source)) }
            ready()
            val original = frame()
            val dormant = model.state.value.edits.sdrSnapshot
            settings()
            compose.onNodeWithTag("hdr-rendition").performClick()
            commit(R.string.hdr_sdr_exposure, "-1.5")
            val base = frame()
            assertArrayEquals(original.hdr, base.hdr, 0f)
            assertFalse(original.sdr.contentEquals(base.sdr))
            commit(R.string.hdr_peak_limit, "0.3")
            val capped = frame()
            val edited = model.state.value.edits
            assertFalse(base.hdr.contentEquals(capped.hdr))
            assertArrayEquals(base.sdr, capped.sdr, 0f)
            assertEquals(4, edited.hdr!!.processingVersion)
            assertEquals(dormant, edited.sdrSnapshot)
            close()
            menu(); compose.onNodeWithTag("adjustment-menu-undo").performClick(); ready()
            assertEquals(0f, model.state.value.edits.hdr!!.renditionSettings.peakLimitEV)
            assertEquals(-1.5f, model.state.value.edits.hdr!!.renditionSettings.sdrExposureEV)
            menu(); compose.onNodeWithTag("adjustment-menu-redo").performClick(); ready()
            assertEquals(edited.hdr, model.state.value.edits.hdr)
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(source)) }
            ready()
            assertEquals(edited.hdr, model.state.value.edits.hdr)
        } finally { source.delete() }
    }

    @Test fun hdrColorControlsAndTargetDrag() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        assumeTrue(instrumentation.context.assets.list("")!!.contains("hdr-sample.jpg"))
        val source = File(compose.activity.cacheDir, "hdr-color-${UUID.randomUUID()}.jpg")
        instrumentation.context.assets.open("hdr-sample.jpg").use { input -> source.outputStream().use(input::copyTo) }
        val model = compose.activity.model
        fun ready() = compose.waitUntil(120_000) {
            val state = model.state.value
            if (state.error != null) throw AssertionError(state.error)
            state.canExport
        }
        fun tool(id: Int) {
            if (!compose.onAllNodesWithTag("editor-tool-7").fetchSemanticsNodes().any())
                compose.onNodeWithTag("editor-group-color").performClick()
            compose.onNodeWithTag("editor-tools").performScrollToNode(hasTestTag("editor-tool-$id"))
            compose.onNodeWithTag("editor-tool-$id").assertIsEnabled().performClick()
        }
        fun menu() {
            compose.onNode(hasContentDescription(compose.activity.getString(R.string.more)) and
                hasAnyAncestor(hasTestTag("editor-menu"))).performClick()
        }
        fun history(action: String) {
            menu()
            compose.onNodeWithTag("adjustment-menu-$action").assertIsEnabled().performClick()
            ready()
        }
        fun switchMode() {
            menu()
            compose.onNodeWithText(compose.activity.getString(R.string.editor_settings)).performClick()
            compose.onNodeWithTag("hdr-editing").assertIsEnabled().performClick()
            compose.onNodeWithText(compose.activity.getString(R.string.confirm)).performClick()
            ready()
        }
        try {
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(source)) }
            ready()
            tool(20)
            compose.onNodeWithTag("adjustment-value-${R.string.vibrance}").performClick()
            compose.onNodeWithTag("adjustment-input").performTextReplacement("35")
            compose.onNodeWithTag("adjustment-input-apply").assertIsEnabled().performClick()
            ready()
            assertEquals(35f, model.state.value.edits.hdr!!.colorSettings.vibrance)
            val original = model.state.value.edits.hdr!!.colorSettings.hsl
            tool(14)
            compose.onNodeWithTag("hsl-target").performClick()
            ready()
            val canvas = compose.onNodeWithTag("photo-canvas")
            for (fraction in listOf(.53f, .42f, .58f)) {
                canvas.performTouchInput {
                    down(Offset(width * fraction, center.y))
                    moveBy(Offset(0f, -35f))
                    up()
                }
                compose.waitUntil(10_000) { !model.hslTarget.value.waiting }
                if (model.state.value.edits.hdr!!.colorSettings.hsl != original) break
            }
            ready()
            val mixed = model.state.value.edits.hdr!!.colorSettings.hsl
            assertTrue("HDR target sample unavailable: ${model.hslTarget.value.notice}", model.hslTarget.value.sample?.usable == true)
            assertNotEquals(original, mixed)
            history("undo")
            assertEquals(original, model.state.value.edits.hdr!!.colorSettings.hsl)
            history("redo")
            assertEquals(mixed, model.state.value.edits.hdr!!.colorSettings.hsl)

            tool(21)
            compose.onNodeWithTag("grading-zone-highlights").performClick()
            compose.onNodeWithTag("grading-wheel").performTouchInput {
                down(center); moveBy(Offset(20f, -24f)); up()
            }
            ready()
            val edited = model.state.value.edits.hdr!!
            assertEquals(3, edited.processingVersion)
            assertTrue(edited.colorSettings.grading.highlights.saturation > 0f)
            switchMode()
            assertFalse(model.state.value.edits.isHDREditing)
            assertEquals(0f, model.state.value.edits.vibrance)
            assertTrue(model.state.value.edits.hsl.isIdentity)
            switchMode()
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(source)) }
            ready()
            assertEquals(edited, model.state.value.edits.hdr)
        } finally { source.delete() }
    }

    @Test fun hdrToneControlsCommitPersistAndRender() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        assumeTrue(instrumentation.context.assets.list("")!!.contains("hdr-sample.jpg"))
        val source = File(compose.activity.cacheDir, "hdr-tone-${UUID.randomUUID()}.jpg")
        instrumentation.context.assets.open("hdr-sample.jpg").use { input -> source.outputStream().use(input::copyTo) }
        val model = compose.activity.model
        fun ready() = compose.waitUntil(120_000) {
            val state = model.state.value
            if (state.error != null) throw AssertionError(state.error)
            state.canExport
        }
        fun tool(id: Int) {
            compose.onNodeWithTag("editor-tools").performScrollToNode(hasTestTag("editor-tool-$id"))
            compose.onNodeWithTag("editor-tool-$id").assertIsEnabled().performClick()
        }
        fun commit(label: Int, value: String) {
            compose.onNodeWithTag("adjustment-value-$label").performClick()
            compose.onNodeWithTag("adjustment-input").performTextReplacement(value)
            compose.onNodeWithTag("adjustment-input-apply").assertIsEnabled().performClick()
            ready()
        }
        fun history(action: String) {
            compose.onNode(hasContentDescription(compose.activity.getString(R.string.more)) and
                hasAnyAncestor(hasTestTag("editor-menu"))).performClick()
            compose.onNodeWithTag("adjustment-menu-$action").assertIsEnabled().performClick()
            ready()
        }
        try {
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(source)) }
            ready()
            val original = model.state.value.edits
            assertTrue(original.isHDREditing)
            tool(18); commit(R.string.black_point, "-25")
            tool(19); commit(R.string.white_point, "50")
            assertEquals(-25f, model.state.value.edits.hdr!!.toneSettings.blackPoint)
            assertEquals(50f, model.state.value.edits.hdr!!.toneSettings.whitePoint)
            tool(6)
            compose.onNodeWithTag("curve-switch").performClick()
            compose.onNodeWithTag("curve-switch-confirm").performClick()
            ready()
            compose.onNodeWithTag("curve-hdr-ev-axis").assertExists()
            val canvas = compose.onNodeWithTag("curve-canvas")
            canvas.performTouchInput { click(center) }
            ready()
            val before = model.state.value.edits.hdr!!.toneSettings.curve
            assertEquals(3, before.points.size)
            canvas.performTouchInput { down(center); moveBy(Offset(26f, -30f)); up() }
            ready()
            val edited = model.state.value.edits
            val curve = edited.hdr!!.toneSettings.curve
            assertNotEquals(before, curve)
            assertEquals(2, edited.hdr.processingVersion)
            assertEquals(original.sdrSnapshot, edited.sdrSnapshot)
            assertTrue(edited.curve.isDefault)
            history("undo")
            assertEquals(before, model.state.value.edits.hdr!!.toneSettings.curve)
            history("redo")
            assertEquals(curve, model.state.value.edits.hdr!!.toneSettings.curve)
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(source)) }
            ready()
            assertEquals(edited.hdr, model.state.value.edits.hdr)
        } finally { source.delete() }
    }

    @Test fun automaticExposureUpdatesAndRestoresHDR() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        assumeTrue(instrumentation.context.assets.list("")!!.contains("hdr-sample.jpg"))
        val source = File(compose.activity.cacheDir, "hdr-meter-${UUID.randomUUID()}.jpg")
        instrumentation.context.assets.open("hdr-sample.jpg").use { input ->
            source.outputStream().use { input.copyTo(it) }
        }
        val model = compose.activity.model
        fun ready() = compose.waitUntil(120_000) {
            val state = model.state.value
            if (state.error != null) throw AssertionError(state.error)
            state.canExport
        }
        fun history(action: String, exposure: Float) {
            compose.onNode(hasContentDescription(compose.activity.getString(R.string.more)) and
                hasAnyAncestor(hasTestTag("editor-menu"))).performClick()
            compose.onNodeWithTag("adjustment-menu-$action").assertIsEnabled().performClick()
            ready()
            assertEquals(exposure, model.state.value.edits.hdr!!.exposure)
        }
        try {
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(source)) }
            ready()
            assertTrue(model.state.value.edits.isHDREditing)
            compose.runOnUiThread { model.edit(model.state.value.edits.copy(exposure = 3.75f)) }
            ready()
            val button = compose.onNodeWithTag("exposure.auto")
            button.assertIsEnabled().performClick()
            ready()
            val exposure = model.state.value.edits.exposure
            assertTrue(exposure in -4f..4f && exposure != 3.75f)
            assertEquals(exposure, model.state.value.edits.hdr!!.exposure)
            val acceptedPreview = model.state.value.preview
            button.assertIsEnabled().performClick()
            ready()
            assertEquals(exposure, model.state.value.edits.exposure)
            assertSame(acceptedPreview, model.state.value.preview)
            history("undo", 3.75f)
            history("redo", exposure)
            compose.runOnUiThread { model.importPhoto(Uri.fromFile(source)) }
            ready()
            assertTrue(model.state.value.edits.isHDREditing)
            assertEquals(exposure, model.state.value.edits.hdr!!.exposure)
        } finally { source.delete() }
    }

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
        fun cameraDenoise(level: Int) {
            val before = model.state.value.preview!!.hdr!!.result
            compose.onNode(hasContentDescription(compose.activity.getString(R.string.more)) and
                hasAnyAncestor(hasTestTag("editor-menu"))).performClick()
            compose.onNodeWithText(compose.activity.getString(R.string.editor_settings)).performClick()
            compose.onNodeWithTag("hdr-camera").performScrollTo().performClick()
            compose.onNodeWithTag("hdr-camera-fbdd-$level").performScrollTo().performClick()
            compose.onNodeWithTag("hdr-camera-apply").performScrollTo().performClick()
            compose.waitUntil(30_000) { model.state.value.edits.hdr?.cameraSettings?.fbddLevel == level || model.state.value.error != null }
            compose.onNodeWithText(compose.activity.getString(R.string.confirm)).performClick()
            ready()
            assertEquals(8, model.state.value.edits.hdr!!.recordVersion)
            if (level == 2) assertFalse(before.hdr.contentEquals(model.state.value.preview!!.hdr!!.result.hdr))
        }
        fun cameraTransfer() {
            fun adjustmentMenu(tag: String) {
                compose.onNode(hasContentDescription(compose.activity.getString(R.string.more)) and
                    hasAnyAncestor(hasTestTag("editor-menu"))).performClick()
                compose.onNodeWithTag(tag).performScrollTo().performClick()
            }
            adjustmentMenu("adjustment-menu-copy")
            compose.onNodeWithTag("adjustment-copy-clear").performScrollTo().performClick()
            compose.onNodeWithTag("adjustment-group-detail").performScrollTo().performClick()
            compose.onNodeWithTag("adjustment-field-hdr.camera_development").performScrollTo().performClick()
            compose.onNodeWithTag("adjustment-copy-confirm").performScrollTo().assertIsEnabled().performClick()
            compose.runOnIdle { assertEquals(setOf("hdr.camera_development"), model.adjustmentClipboard!!.fields.map { it.id }.toSet()) }
            cameraDenoise(1)
            adjustmentMenu("adjustment-menu-paste")
            compose.waitUntil(30_000) { model.adjustmentTransfer.value.prepared != null }
            compose.onNodeWithTag("adjustment-paste-apply").performScrollTo().assertIsEnabled().performClick()
            compose.waitUntil(30_000) { model.state.value.edits.hdr?.cameraSettings?.fbddLevel == 2 }
            ready()
            compose.onNodeWithTag("adjustment-transfer-close").performClick()
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
            if (fixture == "bayer-demosaic.dng") { cameraDenoise(2); cameraTransfer() }
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
            if (fixture == "bayer-demosaic.dng") assertEquals(2, model.state.value.edits.hdr!!.cameraSettings.fbddLevel)
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
