package com.rawlab.android.editor.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.rawlab.android.R
import com.rawlab.android.editor.*
import com.rawlab.android.settings.ColorGradingZone

internal val hslChannelTitles = listOf(R.string.hsl_red, R.string.hsl_orange, R.string.hsl_yellow,
    R.string.hsl_green, R.string.hsl_aqua, R.string.hsl_blue, R.string.hsl_purple, R.string.hsl_magenta)

internal fun gradingZoneTitle(zone: ColorGradingZone): Int = when (zone) {
    ColorGradingZone.SHADOWS -> R.string.shadows; ColorGradingZone.MIDTONES -> R.string.grading_midtones
    ColorGradingZone.HIGHLIGHTS -> R.string.highlights
}

@Composable
internal fun resetScopeTitle(scope: EditorResetScope): String = when (scope) {
    is EditorResetScope.Tool -> stringResource(R.string.editor_reset_tool, stringResource(editorToolTitles[scope.id]))
    is EditorResetScope.Group -> stringResource(R.string.editor_reset_group, stringResource(groupTitle(scope.group)))
    is EditorResetScope.HslChannel -> stringResource(R.string.editor_reset_hsl_color, stringResource(hslChannelTitles[scope.channel]))
    is EditorResetScope.GradingZone -> stringResource(R.string.grading_reset_zone)
    EditorResetScope.AllGrading -> stringResource(R.string.grading_reset_all)
    EditorResetScope.AllHsl -> stringResource(R.string.editor_reset_hsl_all)
    EditorResetScope.All -> stringResource(R.string.editor_reset_all)
}

@Composable
internal fun EditorResetMenu(
    presentation: EditorWorkspaceResetPresentation,
    onDismiss: () -> Unit,
    onSelect: (EditorResetScope) -> Unit,
) {
    val menu = presentation.style as? EditorWorkspaceResetStyle.Menu ?: return
    DropdownMenu(expanded = true, onDismissRequest = onDismiss) {
        menu.items.forEach { item ->
            DropdownMenuItem(
                text = { Text(resetScopeTitle(item.scope)) },
                modifier = Modifier.testTag(item.id),
                enabled = item.isEnabled,
                onClick = { onSelect(item.scope) },
            )
        }
    }
}

@Composable
internal fun EditorResetConfirmation(prepared: PreparedEditorReset, onDismiss: () -> Unit, onConfirm: () -> Unit) {
    val scope = prepared.scope
    val description = when (scope) {
        is EditorResetScope.Group -> stringResource(R.string.editor_reset_group_message, stringResource(groupTitle(scope.group)))
        EditorResetScope.AllGrading, EditorResetScope.Tool(21) -> stringResource(R.string.grading_reset_message)
        EditorResetScope.All -> stringResource(R.string.editor_reset_all_message)
        else -> stringResource(R.string.editor_reset_hsl_all_message)
    }
    val converted = prepared.result.convertedFields.map { key -> stringResource(when (key) {
        "exposure" -> R.string.exposure
        "highlights" -> R.string.highlights
        "shadows" -> R.string.shadows
        "contrast" -> R.string.contrast
        "saturation" -> R.string.saturation
        "hsl" -> R.string.hsl
        "temperature" -> R.string.temperature
        "tint" -> R.string.tint
        "blackPoint" -> R.string.black_point
        "whitePoint" -> R.string.white_point
        "vibrance" -> R.string.vibrance
        "clarity" -> R.string.clarity
        "dehaze" -> R.string.dehaze
        "curve" -> R.string.curve_title
        "colorGrading" -> R.string.color_grading
        else -> R.string.white_balance
    }) }.distinct().joinToString(", ")
    AlertDialog(onDismissRequest = onDismiss, title = { Text(resetScopeTitle(scope)) },
        text = { Column {
            if (converted.isEmpty()) Text(description)
            else Text(stringResource(R.string.editor_reset_conversion_message, converted))
        } },
        confirmButton = { TextButton(onClick = onConfirm, modifier = Modifier.testTag("editor-reset-confirm")) {
            Text(stringResource(R.string.editor_reset_confirm))
        } }, dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } })
}
