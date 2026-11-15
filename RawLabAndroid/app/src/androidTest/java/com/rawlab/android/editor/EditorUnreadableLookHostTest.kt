package com.rawlab.android.editor

import android.app.Application
import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.rawlab.android.R
import com.rawlab.android.RawLabTheme
import com.rawlab.android.editor.render.PreviewPair
import com.rawlab.android.editor.ui.EditorScreen
import com.rawlab.android.looks.LookLibrary
import com.rawlab.android.looks.MasterRecipe
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.LookChoice
import com.rawlab.android.testing.ForegroundTestRule
import com.rawlab.android.testing.LanguageTestRule
import kotlinx.coroutines.flow.MutableStateFlow
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File
import java.util.Properties
import java.util.UUID

class EditorUnreadableLookHostTest {
    private val compose = createComposeRule()
    @get:Rule val rule = RuleChain.outerRule(LanguageTestRule()).around(ForegroundTestRule()).around(compose)

    @Test fun lookPanelDeletesThroughViewModelWhileItsLookDraftIsOpen() = withEditor { model, root, active, recent ->
        compose.setContent {
            val state by model.state.collectAsState()
            RawLabTheme {
                EditorScreen(state = state, onAlbum = {}, onFile = {}, onEdit = { _, _ -> }, onRetry = {},
                    onExport = {}, onMessageDismiss = {}, onLicenses = {}, onGpuChange = {},
                    onBeginDraft = model::beginDraft, onDeleteUnreadableLook = model::deleteUnreadableLook)
            }
        }
        compose.onNodeWithTag("editor-group-looks").performClick()
        compose.onNodeWithTag("editor-tool-0").performClick()
        compose.waitUntil(10_000) { model.state.value.draft?.group == AdjustmentGroup.LOOK }
        compose.onAllNodesWithTag("looks.deleteUnreadable")[0].assertIsEnabled().performClick()
        compose.onNodeWithText(InstrumentationRegistry.getInstrumentation().targetContext.getString(R.string.cancel)).performClick()
        assertEquals(2, LookLibrary(root).listUnreadable().size)
        compose.onAllNodesWithTag("looks.deleteUnreadable")[0].performClick()
        compose.onNodeWithTag("looks.deleteUnreadable.confirm").performClick()
        compose.waitUntil(10_000) { model.state.value.unreadableLooks.size == 1 }
        compose.onNodeWithText("Future look").assertDoesNotExist()
        compose.onNodeWithText("Sibling look").assertIsDisplayed()
        assertDeletedAndRecipeLooksPreserved(model, root, active, recent)
    }

    @Test fun viewModelDeletesUnreadableLookAfterBeginLookDraft() = withEditor { model, root, active, recent ->
        compose.runOnIdle {
            model.beginDraft(AdjustmentGroup.LOOK)
            assertEquals(AdjustmentGroup.LOOK, model.state.value.draft?.group)
            model.deleteUnreadableLook(model.state.value.unreadableLooks.first())
            assertEquals(Operation.IMPORT_LOOK, model.state.value.operation)
        }
        compose.waitUntil(10_000) { model.state.value.operation == Operation.NONE && model.state.value.unreadableLooks.size == 1 }
        assertDeletedAndRecipeLooksPreserved(model, root, active, recent)
    }

    @Test fun viewModelStillRejectsDeletionDuringAnotherDraftOrCommit() = withEditor { model, root, _, _ ->
        compose.runOnIdle {
            model.beginDraft(AdjustmentGroup.EXPOSURE)
            model.deleteUnreadableLook(model.state.value.unreadableLooks.first())
            assertEquals(Operation.NONE, model.state.value.operation)
            state(model).value = model.state.value.copy(draft = null, committingAdjustments = true)
            model.deleteUnreadableLook(model.state.value.unreadableLooks.first())
            assertEquals(Operation.NONE, model.state.value.operation)
            state(model).value = model.state.value.copy(committingAdjustments = false, operation = Operation.EXPORT)
            model.deleteUnreadableLook(model.state.value.unreadableLooks.first())
            assertEquals(Operation.EXPORT, model.state.value.operation)
            state(model).value = model.state.value.copy(operation = Operation.NONE)
        }
        assertEquals(2, LookLibrary(root).listUnreadable().size)
        assertTrue(File(root, "00000000-0000-0000-0000-000000000001.cube").isFile)
    }

    private fun assertDeletedAndRecipeLooksPreserved(model: EditorViewModel, root: File, active: String, recent: String) {
        val current = compose.runOnIdle { model.state.value }
        assertEquals(listOf("Sibling look"), LookLibrary(root).listUnreadable().map { it.name })
        assertFalse(File(root, "00000000-0000-0000-0000-000000000001.cube").exists())
        assertEquals(AdjustmentGroup.LOOK, current.draft?.group)
        assertEquals(active, current.visibleEdits.film)
        assertTrue("Active recipe LUT must survive unreadable deletion", current.looks.any { it.id == active })
        assertTrue("Recent recipe LUT must survive unreadable deletion", current.looks.any { it.id == recent })
        assertEquals(listOf(recent), current.recentLookIds)
    }

    private fun withEditor(test: (EditorViewModel, File, String, String) -> Unit) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.cacheDir, "editor-unreadable-${UUID.randomUUID()}").apply { mkdirs() }
        val application = object : Application() {
            init { attachBaseContext(context) }
            override fun getFilesDir() = File(directory, "files").apply { mkdirs() }
            override fun getCacheDir() = File(directory, "cache").apply { mkdirs() }
            override fun getSharedPreferences(name: String, mode: Int) =
                super.getSharedPreferences("${directory.name}-$name", mode)
        }
        val root = File(application.filesDir, "looks").apply { mkdirs() }
        val recipes = MasterRecipe.load(context).take(2).map { "recipe-lut:${it.id}" }
        application.getSharedPreferences("look-browser", Context.MODE_PRIVATE).edit()
            .putString("recent", JSONArray(listOf(recipes[1])).toString()).commit()
        Properties().apply {
            setProperty("version", "1")
            setProperty("count", "2")
            setProperty("item.0.name", "Future look")
            setProperty("item.0.path", "00000000-0000-0000-0000-000000000001.cube")
            setProperty("item.0.version", "99")
            setProperty("item.1.name", "Sibling look")
            File(root, "registry.properties").outputStream().use { store(it, null) }
        }
        File(root, "00000000-0000-0000-0000-000000000001.cube").writeText("unreadable source")
        val store = ViewModelStore()
        val bitmap = Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888)
        lateinit var model: EditorViewModel
        try {
            compose.runOnIdle { model = EditorViewModel(application); store.put("editor", model) }
            compose.waitUntil(10_000) { model.state.value.unreadableLooks.size == 2 }
            compose.runOnIdle {
                // 只预置已就绪的照片；草稿、宿主按钮、工作队列和持久化删除均走真实代码。
                state(model).value = model.state.value.copy(
                    photo = ImportedPhoto(Uri.parse("content://rawlab.test/unreadable"), "fixture", File(directory, "fixture")),
                    preview = PreviewPair(bitmap, bitmap, 6500f, 0f), exact = true,
                    edits = EditSettings(film = recipes[0]),
                    looks = model.state.value.looks + LookChoice(recipes[0], "Active recipe LUT", managed = false))
            }
            test(model, root, recipes[0], recipes[1])
        } finally {
            compose.runOnIdle { state(model).value = model.state.value.copy(photo = null, draft = null); store.clear() }
            bitmap.recycle()
            listOf("look-browser", "system-photo-requests").forEach { context.deleteSharedPreferences("${directory.name}-$it") }
            directory.deleteRecursively()
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun state(model: EditorViewModel) = EditorViewModel::class.java.getDeclaredField("mutable")
        .apply { isAccessible = true }.get(model) as MutableStateFlow<EditorState>
}
