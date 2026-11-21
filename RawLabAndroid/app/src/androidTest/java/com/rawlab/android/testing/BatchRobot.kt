package com.rawlab.android.testing

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.ComposeTestRule
import com.rawlab.android.R
import com.rawlab.android.batch.BatchPhase
import com.rawlab.android.editor.EditorViewModel
import com.rawlab.android.i18n.AppStrings

class BatchRobot(private val compose: ComposeTestRule) {
    fun toggleCollectionFromMenu(model: EditorViewModel) {
        compose.onNode(
            hasContentDescription(AppStrings.text(R.string.more)) and
                !hasAnyAncestor(hasTestTag("adjustment-dock"))
        ).performClick()
        compose.onNodeWithTag("collection-menu").performClick()
        compose.waitUntil(60_000) { !model.collection.value.busy }
    }

    fun openCollectionAndAssertDisplayed(model: EditorViewModel) {
        toggleCollectionFromMenu(model)
        compose.onNodeWithTag("batch-selection-root").assertIsDisplayed()
    }

    fun editPhotoFromCollection(model: EditorViewModel, uri: String) {
        compose.onNodeWithTag("collection-edit-$uri").performClick()
        compose.waitUntil(60_000) {
            model.collection.value.currentID == uri && model.state.value.controlsEnabled
        }
    }

    fun openBatchExportConfig() {
        compose.onNodeWithTag("collection-export").performClick()
        compose.onNodeWithTag("collection-export-start").assertIsDisplayed().assertIsEnabled()
    }

    fun startAndAwaitComplete(model: EditorViewModel) {
        compose.onNodeWithTag("collection-export-start").performClick()
        compose.waitUntil(60_000) {
            model.batch.value?.state?.value?.phase == BatchPhase.COMPLETE
        }
    }
}
