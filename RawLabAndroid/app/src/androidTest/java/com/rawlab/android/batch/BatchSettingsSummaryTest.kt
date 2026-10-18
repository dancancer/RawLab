package com.rawlab.android.batch

import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import com.rawlab.android.R
import com.rawlab.android.batch.ui.BatchExportScreen
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.testing.LanguageTestRule

class BatchSettingsSummaryTest {
    private val compose = createComposeRule()
    @get:Rule val rule: RuleChain = RuleChain.outerRule(LanguageTestRule()).around(compose)

    @Test fun allAdjustmentsShowsBothFrozenPerspectiveAxes() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val root = File(context.cacheDir, "batch-summary-${UUID.randomUUID()}").apply { mkdirs() }
        val source = File(root, "source.raw").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        val storage = PhotoStorage(context)
        val settings = EditSettings(geometry = GeometrySettings(perspectiveHorizontal = .35f, perspectiveVertical = -.25f))
        var model: BatchExportModel? = null
        try {
            compose.runOnUiThread {
                model = BatchExportModel(context, storage,
                    BatchSourceSnapshot(PhotoIdentity(source.path), source, settings))
            }
            val batch = checkNotNull(model)
            compose.waitUntil(10_000) { batch.state.value.phase != BatchPhase.PREPARING }
            assertEquals(BatchPhase.SELECTING, batch.state.value.phase)
            compose.setContent { MaterialTheme { BatchExportScreen(batch, storage, onBack = {}) } }
            compose.onNodeWithText(AppStrings.text(R.string.message_expand)).performScrollTo().performClick()
            for ((label, value) in listOf(
                R.string.geometry_perspective_horizontal to "+35%",
                R.string.geometry_perspective_vertical to "-25%",
            )) {
                compose.onNode(hasText(value) and hasAnySibling(hasText(AppStrings.text(label))))
                    .performScrollTo().assertIsDisplayed()
            }
        } finally {
            model?.let { batch ->
                compose.runOnUiThread { batch.close() }
                BatchJournal(File(context.filesDir, "RawLab/BatchJobs")).discard(batch.state.value.job.id)
            }
            storage.close()
            root.deleteRecursively()
        }
    }
}
