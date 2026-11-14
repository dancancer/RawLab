package com.rawlab.android.editor

import com.rawlab.android.settings.ColorGradingZone

sealed interface EditorWorkspaceResetStyle {
    data class Menu(val items: List<EditorWorkspaceResetMenuItem>) : EditorWorkspaceResetStyle
}

data class EditorWorkspaceResetMenuItem(
    val id: String,
    val scope: EditorResetScope,
    val isEnabled: Boolean,
    val isDestructive: Boolean = false,
) {
    companion object {
        fun testTag(scope: EditorResetScope): String = "editor-reset-${when (scope) {
            is EditorResetScope.Tool -> "tool"
            is EditorResetScope.Group -> "group"
            is EditorResetScope.HslChannel -> "channel"
            is EditorResetScope.GradingZone -> "grading-zone"
            EditorResetScope.AllGrading -> "grading"
            EditorResetScope.AllHsl -> "hsl"
            EditorResetScope.All -> "all"
        }}"
    }
}

data class EditorWorkspaceResetPresentation(
    val isEnabled: Boolean,
    val style: EditorWorkspaceResetStyle,
) {
    companion object {
        fun make(
            state: EditorState,
            toolOpen: Boolean,
            quickPresetsVisible: Boolean,
            tool: Int,
            channel: Int = 0,
            gradingZone: ColorGradingZone = ColorGradingZone.SHADOWS,
            pendingAll: Boolean = false,
        ): EditorWorkspaceResetPresentation? {
            if (state.photo == null || quickPresetsVisible) return null
            val group = EditorAdjustmentRules.groupFor(tool) ?: EditorAdjustmentGroup.LOOKS
            val context = state.resetContext()
            val ready = state.controlsEnabled && !pendingAll && state.exact &&
                !state.rendering && !state.previewResizePending && (!toolOpen || state.draftReady)

            fun item(scope: EditorResetScope, allowed: Boolean = true): EditorWorkspaceResetMenuItem {
                val changed = EditorAdjustmentRules.isModified(scope, state.visibleEdits, context)
                val enabled = ready && allowed && (changed || (scope == EditorResetScope.All && state.draft != null))
                return EditorWorkspaceResetMenuItem(
                    id = EditorWorkspaceResetMenuItem.testTag(scope),
                    scope = scope,
                    isEnabled = enabled,
                    isDestructive = scope == EditorResetScope.All,
                )
            }

            val items = if (!toolOpen) {
                listOf(
                    item(EditorResetScope.Group(group), allowed = group != EditorAdjustmentGroup.GEOMETRY),
                    item(EditorResetScope.All),
                )
            } else {
                when (tool) {
                    14 -> listOf(
                        EditorResetScope.HslChannel(channel),
                        EditorResetScope.AllHsl,
                        EditorResetScope.All,
                    )
                    21 -> listOf(
                        EditorResetScope.GradingZone(gradingZone),
                        EditorResetScope.AllGrading,
                        EditorResetScope.All,
                    )
                    16, 17 -> listOf(
                        EditorResetScope.Tool(tool),
                        EditorResetScope.Group(EditorAdjustmentGroup.GEOMETRY),
                        EditorResetScope.All,
                    )
                    else -> listOf(
                        EditorResetScope.Tool(tool),
                        EditorResetScope.All,
                    )
                }.map { item(it) }
            }

            return EditorWorkspaceResetPresentation(
                isEnabled = items.any { it.isEnabled },
                style = EditorWorkspaceResetStyle.Menu(items),
            )
        }
    }
}
