package com.rawlab.android.batch.state

import android.graphics.Bitmap
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.R
import com.rawlab.android.batch.BatchPhase
import com.rawlab.android.batch.BatchRowStatus
import com.rawlab.android.batch.ui.BatchExportScreen
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.testing.ForegroundTestRule
import com.rawlab.android.testing.LanguageTestRule
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain

class BatchResultActionsTest {
    private val compose = createComposeRule()
    @get:Rule val rules: RuleChain = RuleChain.outerRule(LanguageTestRule())
        .around(ForegroundTestRule()).around(compose)

    @Test fun cancelledBatchOffersContinueAndPreservesTheSuccessfulOutput() {
        BatchStateTestFixture().use { fixture ->
            fixture.addTargets(2)
            val stop = AtomicBoolean(true)
            fixture.gate(after = { next ->
                if (next.job.rows.first().status == BatchRowStatus.SUCCESS && stop.compareAndSet(true, false))
                    fixture.main { fixture.model.cancel() }
            })
            fixture.main { fixture.model.start(ExportFormat.JPEG, null) }
            fixture.joinWorker()
            val stopped = fixture.model.state.value
            assertEquals(BatchPhase.CANCELLED, stopped.phase)
            assertEquals(listOf(BatchRowStatus.SUCCESS, BatchRowStatus.CANCELLED), stopped.job.rows.map { it.status })
            fixture.assertOutputs(stopped.job, 1)
            compose.setContent { MaterialTheme { BatchExportScreen(fixture.model, fixture.storage, onBack = {}) } }
            val continueText = AppStrings.format(R.string.message_continue_unfinished_items, "1")
            compose.onNodeWithText(AppStrings.text(R.string.message_retry_failed_items)).assertDoesNotExist()
            compose.onNodeWithText(continueText).assertIsDisplayed().assertIsEnabled()
            capture("cancelled-actions")
            compose.onNodeWithText(continueText).performClick()
            compose.waitUntil(30_000) { fixture.model.state.value.phase in setOf(BatchPhase.COMPLETE, BatchPhase.FAILED) }
            fixture.joinWorker()
            val completed = fixture.model.state.value
            assertEquals(BatchPhase.COMPLETE, completed.phase)
            assertNull(completed.error)
            assertEquals(stopped.job.rows.first(), completed.job.rows.first())
            assertEquals(listOf(BatchRowStatus.SUCCESS, BatchRowStatus.SUCCESS), completed.job.rows.map { it.status })
            fixture.assertOutputs(completed.job, 2)
            fixture.assertOriginals()
            compose.onNodeWithText(continueText).assertDoesNotExist()
            compose.onNodeWithText(AppStrings.text(R.string.message_export_complete)).assertIsDisplayed()
            capture("continued-result")
        }
    }

    private fun capture(name: String) {
        compose.waitForIdle()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val file = File(instrumentation.targetContext.getExternalFilesDir(null), "batch-tests/$name.png")
        file.parentFile!!.mkdirs()
        instrumentation.uiAutomation.takeScreenshot()!!.let { image ->
            file.outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
            image.recycle()
        }
    }
}
