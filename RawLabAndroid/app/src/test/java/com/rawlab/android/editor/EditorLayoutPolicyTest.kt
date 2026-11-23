package com.rawlab.android.editor

import android.net.TestUri
import com.rawlab.android.R
import com.rawlab.android.editor.controls.EDITOR_SIDE_DOCK_WIDTH
import com.rawlab.android.editor.controls.editorAdaptiveGridHeight
import com.rawlab.android.editor.controls.editorAdaptiveHomeDockHeight
import com.rawlab.android.editor.controls.editorDockLayout
import com.rawlab.android.editor.controls.editorGridColumns
import com.rawlab.android.editor.controls.editorGridHeight
import com.rawlab.android.editor.controls.editorHomeDockHeight
import com.rawlab.android.editor.controls.editorUsesSideDock
import com.rawlab.android.editor.ui.resolveEditorLoadingPresentation
import com.rawlab.android.photo.ImportedPhoto
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class EditorLayoutPolicyTest {
    @Test fun sideDockRequiresWideLandscapeAndNonAccessibilityFontScale() {
        assertFalse(editorUsesSideDock(320f, 720f, 1f))
        assertFalse(editorUsesSideDock(360f, 720f, 1f))
        assertFalse(editorUsesSideDock(412f, 892f, 1f))
        assertFalse(editorUsesSideDock(800f, 1280f, 1f))
        assertFalse(editorUsesSideDock(560f, 360f, 1f))
        assertTrue(editorUsesSideDock(960f, 360f, 1f))
        assertTrue(editorUsesSideDock(960f, 600f, 1f))
        assertFalse(editorUsesSideDock(960f, 600f, 1.3f))
        assertFalse(editorUsesSideDock(960f, 600f, 1.5f))
        assertEquals(336f, EDITOR_SIDE_DOCK_WIDTH, 0f)
    }

    @Test fun bottomDockReservesAtLeastMinimumCanvasHeightAndEnablesCompactNavWhenTight() {
        val portrait = editorDockLayout(availableHeight = 715f, fontScale = 1f, sideDock = false, expanded = true)
        assertEquals(332f, portrait.height, 0f)
        assertFalse(portrait.compactNavigation)

        val shortLandscape = editorDockLayout(availableHeight = 355f, fontScale = 1f, sideDock = false, expanded = true)
        assertEquals(259f, shortLandscape.height, 0f)
        assertTrue(355f - shortLandscape.height >= 96f)
        assertTrue(shortLandscape.compactNavigation)

        val collapsed = editorDockLayout(availableHeight = 715f, fontScale = 1.5f, sideDock = false, expanded = false)
        assertEquals(72f, collapsed.height, 0f)

        val side = editorDockLayout(availableHeight = 596f, fontScale = 1f, sideDock = true, expanded = true)
        assertEquals(596f, side.height, 0f)
        assertFalse(side.compactNavigation)
    }

    @Test fun gridColumnsAndHomeHeightsAdaptForAccessibilityFontScale() {
        assertEquals(4, editorGridColumns(1f))
        assertEquals(4, editorGridColumns(1.3f))
        assertEquals(3, editorGridColumns(1.35f))
        assertEquals(116f, editorGridHeight(1f), 0f)
        assertEquals(148f, editorGridHeight(1.35f), 0f)
        assertEquals(164f, editorHomeDockHeight(1f), 0f)
        assertEquals(196f, editorHomeDockHeight(1.35f), 0f)
    }

    @Test fun adaptiveHomeGridAndDockHeightsShrinkForOneRowGroups() {
        listOf(2, 3, 4).forEach { count ->
            assertEquals(60f, editorAdaptiveGridHeight(count, 1f), 0f)
            assertEquals(108f, editorAdaptiveHomeDockHeight(count, 1f), 0f)
        }
        listOf(5, 7).forEach { count ->
            assertEquals(116f, editorAdaptiveGridHeight(count, 1f), 0f)
            assertEquals(164f, editorAdaptiveHomeDockHeight(count, 1f), 0f)
        }
    }

    @Test fun editorLoadingPresentationCoversInitialOpenSwitchLookMatchAndExport() {
        val preview = TestBitmaps.pair()
        val photo = ImportedPhoto(TestUri.value, "sample.arw", File("sample.arw"))

        val idle = resolveEditorLoadingPresentation(EditorState())
        assertFalse(idle.showsTopProgressLine)
        assertFalse(idle.showsEmptyCanvasLoading)
        assertNull(idle.immediateBannerRes)
        assertNull(idle.delayedBannerRes)

        val pickExportOnly = resolveEditorLoadingPresentation(EditorState(preview = preview, operation = Operation.PICK_EXPORT))
        assertFalse(pickExportOnly.showsTopProgressLine)
        assertFalse(pickExportOnly.showsEmptyCanvasLoading)
        assertNull(pickExportOnly.immediateBannerRes)
        assertNull(pickExportOnly.delayedBannerRes)

        val initialOpen = resolveEditorLoadingPresentation(EditorState(operation = Operation.IMPORT, rendering = true))
        assertTrue(initialOpen.showsTopProgressLine)
        assertTrue(initialOpen.showsEmptyCanvasLoading)
        assertNull(initialOpen.immediateBannerRes)
        assertNull(initialOpen.delayedBannerRes)

        val firstPhotoPrePreview = resolveEditorLoadingPresentation(EditorState(photo = photo, rendering = true))
        assertTrue(firstPhotoPrePreview.showsTopProgressLine)
        assertTrue(firstPhotoPrePreview.showsEmptyCanvasLoading)
        assertNull(firstPhotoPrePreview.immediateBannerRes)
        assertNull(firstPhotoPrePreview.delayedBannerRes)

        val secondOpen = resolveEditorLoadingPresentation(
            EditorState(photo = photo, preview = preview, operation = Operation.IMPORT, rendering = true),
        )
        assertTrue(secondOpen.showsTopProgressLine)
        assertFalse(secondOpen.showsEmptyCanvasLoading)
        assertEquals(R.string.importing, secondOpen.immediateBannerRes)
        assertNull(secondOpen.delayedBannerRes)

        val lookImport = resolveEditorLoadingPresentation(EditorState(preview = preview, operation = Operation.IMPORT_LOOK))
        assertTrue(lookImport.showsTopProgressLine)
        assertEquals(R.string.look_importing, lookImport.immediateBannerRes)
        assertNull(lookImport.delayedBannerRes)

        val hdrProfile = resolveEditorLoadingPresentation(EditorState(preview = preview, importingHDRCameraProfile = true))
        assertTrue(hdrProfile.showsTopProgressLine)
        assertEquals(R.string.look_importing, hdrProfile.immediateBannerRes)

        val lookPreparing = resolveEditorLoadingPresentation(EditorState(preview = preview, lookImportPreparing = true))
        assertTrue(lookPreparing.showsTopProgressLine)
        assertEquals(R.string.look_importing, lookPreparing.immediateBannerRes)

        val matching = resolveEditorLoadingPresentation(EditorState(preview = preview, matchingProcessing = true))
        assertTrue(matching.showsTopProgressLine)
        assertEquals(R.string.processing_migration_matching, matching.immediateBannerRes)
        assertNull(matching.delayedBannerRes)

        val prepareExport = resolveEditorLoadingPresentation(EditorState(preview = preview, operation = Operation.PREPARE_EXPORT))
        assertTrue(prepareExport.showsTopProgressLine)
        assertEquals(R.string.exporting, prepareExport.immediateBannerRes)

        val exporting = resolveEditorLoadingPresentation(
            EditorState(preview = preview, operation = Operation.EXPORT, rendering = true),
        )
        assertTrue(exporting.showsTopProgressLine)
        assertNull(exporting.immediateBannerRes)
        assertNull(exporting.delayedBannerRes)

        val slowRender = resolveEditorLoadingPresentation(EditorState(photo = photo, preview = preview, rendering = true))
        assertTrue(slowRender.showsTopProgressLine)
        assertFalse(slowRender.showsEmptyCanvasLoading)
        assertNull(slowRender.immediateBannerRes)
        assertEquals(R.string.rendering, slowRender.delayedBannerRes)

        val resizePending = resolveEditorLoadingPresentation(
            EditorState(photo = photo, preview = preview, previewResizePending = true),
        )
        assertTrue(resizePending.showsTopProgressLine)
        assertEquals(R.string.rendering, resizePending.delayedBannerRes)
    }
}
