package com.rawlab.android.testing

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.ComposeTestRule

class AlbumRobot(private val compose: ComposeTestRule) {
    fun openAlbum(albumLabel: String) {
        compose.onNodeWithContentDescription(albumLabel).performClick()
        compose.waitUntil(15_000) {
            compose.onAllNodesWithTag("album-root").fetchSemanticsNodes().isNotEmpty()
        }
    }

    fun selectBucket(name: String) {
        compose.waitUntil(15_000) {
            compose.onAllNodesWithText(name).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithText(name).performClick()
    }

    fun selectFilter(filterKey: String) {
        compose.onNodeWithTag("album-edit-filter-$filterKey").performClick()
    }

    fun openPhoto(uri: String) {
        compose.waitUntil(15_000) {
            compose.onAllNodesWithTag("album-photo-$uri").fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithTag("album-photo-$uri").performClick()
    }
}
