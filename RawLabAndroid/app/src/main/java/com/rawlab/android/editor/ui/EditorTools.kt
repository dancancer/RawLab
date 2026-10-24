package com.rawlab.android.editor.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.selection.selectable
import androidx.compose.material.icons.filled.Circle
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import kotlin.math.abs
import com.rawlab.android.R
import com.rawlab.android.editor.*
import com.rawlab.android.editor.controls.AdjustmentScale
import com.rawlab.android.editor.controls.formatAdjustment
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.DenoiseSettings
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.LensSettings

internal val editorToolOrder = EditorAdjustmentGroup.entries.flatMap(EditorAdjustmentRules::tools)

internal val editorToolTitles = listOf(R.string.film, R.string.strength, R.string.exposure, R.string.highlights,
    R.string.shadows, R.string.contrast, R.string.tone_curve, R.string.saturation, R.string.white_balance,
    R.string.tint, R.string.sharpening, R.string.denoise, R.string.vignette, R.string.grain, R.string.hsl,
    R.string.master_recipes, R.string.info_lens, R.string.geometry, R.string.black_point, R.string.white_point, R.string.vibrance, R.string.color_grading)

internal val editorToolIcons: List<ImageVector> get() = listOf(Icons.Outlined.PhotoFilter, Icons.Outlined.Tune,
    Icons.Outlined.Exposure, Icons.Outlined.WbSunny, Icons.Outlined.DarkMode, Icons.Outlined.Contrast,
    Icons.Outlined.SsidChart, Icons.Outlined.WaterDrop, Icons.Outlined.Thermostat, Icons.Outlined.Palette,
    Icons.Outlined.Deblur, Icons.Outlined.NoiseAware, Icons.Outlined.Circle, Icons.Outlined.Grain,
    Icons.Outlined.ColorLens, Icons.Outlined.Layers, Icons.Outlined.CenterFocusStrong, Icons.Outlined.CropRotate, Icons.Filled.Circle, Icons.Outlined.RadioButtonUnchecked, Icons.Filled.WaterDrop, Icons.Outlined.Palette)

internal fun whiteBalanceChanged(edits: EditSettings, shotTemperature: Float?, shotTint: Float?): Boolean {
    val temperature = shotTemperature ?: edits.temperature
    val tint = if (edits.recipeID != null) 0f else shotTint ?: edits.tint
    return abs(edits.temperature - temperature) > .0001f || abs(edits.tint - tint) > .0001f
}

@Composable
internal fun EditorToolStrip(state: EditorState, selected: Int, tools: List<Int> = editorToolOrder, list: LazyListState = rememberLazyListState(),
    navigationEnabled: Boolean = true, inlineLabels: Boolean = true, modifier: Modifier = Modifier,
    perspective: Boolean = false, onPerspective: (() -> Unit)? = null, select: (Int) -> Unit) {
    val entries = tools.flatMap { if (it == 17 && onPerspective != null) listOf(it, -1) else listOf(it) }
    val active = if (selected == 17 && perspective) -1 else selected
    LaunchedEffect(active) {
        val index = entries.indexOf(active).coerceAtLeast(0)
        if (list.layoutInfo.visibleItemsInfo.none { it.index == index && it.offset >= 0 &&
            it.offset + it.size <= list.layoutInfo.viewportEndOffset }) list.scrollToItem(index)
    }
    LazyRow(modifier.fillMaxWidth().testTag("editor-tools"), state = list, contentPadding = PaddingValues(horizontal = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        items(entries, key = { it }) { index ->
            if (index == -1) TextButton(onClick = { onPerspective?.invoke() }, enabled = navigationEnabled && state.controlsEnabled,
                modifier = Modifier.heightIn(min = 48.dp).testTag("editor-tool-perspective").semantics { this.selected = active == -1 }) {
                Icon(Icons.Outlined.Transform, null, Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp)); Text(stringResource(R.string.geometry_perspective_tool))
            } else EditorTool(state, index, active == index, navigationEnabled, true) { select(index) }
        }
    }

}

@Composable
internal fun EditorTool(state: EditorState, index: Int, selected: Boolean, navigationEnabled: Boolean = true, inlineLabels: Boolean = false, onClick: () -> Unit) {
    val edits = state.visibleEdits
    val rawOnly = state.photo?.inputKind == PhotoInputKind.RAW
    val scalar = when (index) {
        1 -> Triple(edits.strength * 100f, 100f, 0f..200f)
        2 -> Triple(edits.exposure, 0f, -4f..4f)
        3 -> Triple(edits.highlights * 100f, 0f, -100f..100f)
        4 -> Triple(edits.shadows * 100f, 0f, -100f..100f)
        5 -> Triple(edits.contrast * 100f, 0f, -100f..100f)
        6 -> Triple(edits.toneCurve * 100f, 0f, -100f..100f)
        7 -> Triple(edits.saturation * 100f, 0f, -100f..100f)
        // Temperature and tint share one entry; keep the legacy tint slot for restored UI state only.
        9 -> Triple(edits.tint, if (edits.recipeID != null) 0f else state.preview?.tint ?: edits.tint, -150f..150f)
        10 -> Triple(edits.sharpening * 100f, 0f, 0f..200f)
        18 -> Triple(edits.blackPoint, 0f, -100f..100f)
        19 -> Triple(edits.whitePoint, 0f, -100f..100f)
        20 -> Triple(edits.vibrance, 0f, -100f..100f)
        else -> null
    }
    val changed = EditorAdjustmentRules.isModified(EditorResetScope.Tool(index), edits, state.resetContext())
    val primary = MaterialTheme.colorScheme.primary
    val muted = MaterialTheme.colorScheme.onSurfaceVariant
    val color = if (selected) primary else muted
    val number = scalar?.let { formatAdjustment(it.first, if (index == 2) .05f else 1f) }
    val title = stringResource(editorToolTitles[index])
    val status = stringResource(if (changed) R.string.hsl_adjusted else R.string.hsl_unadjusted)
    val valueDescription = if (index == 8) listOf(
        "${formatAdjustment(edits.temperature, 1f)} K", formatAdjustment(edits.tint, 1f)
    ).joinToString(" · ") else number
    val selectable = Modifier.selectable(selected,
        enabled = navigationEnabled && state.controlsEnabled && (index != 8 || rawOnly) && (index != 16 || rawOnly),
        role = Role.Tab, onClick = onClick).testTag("editor-tool-$index").semantics(mergeDescendants = true) {
        contentDescription = title
        stateDescription = listOfNotNull(valueDescription, status).joinToString(" · ")
    }
    Row(selectable.heightIn(min = 48.dp).background(if (selected) primary.copy(alpha = .12f) else Color.Transparent, RoundedCornerShape(5.dp))
        .padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(editorToolIcons[index], null, Modifier.size(18.dp).testTag("editor-tool-ring-$index"), tint = color)
        Text(if (index == 17) stringResource(R.string.geometry_crop_tool) else title,
            Modifier.testTag("editor-tool-label-$index"), style = MaterialTheme.typography.labelMedium, color = color)
        Box(Modifier.size(3.dp).testTag("editor-tool-marker-$index").background(if (changed) primary else Color.Transparent, CircleShape))
    }

}

internal fun groupTitle(group: EditorAdjustmentGroup): Int = when (group) {
    EditorAdjustmentGroup.LOOKS -> R.string.editor_group_looks
    EditorAdjustmentGroup.LIGHT -> R.string.editor_group_light
    EditorAdjustmentGroup.COLOR -> R.string.editor_group_color
    EditorAdjustmentGroup.EFFECTS -> R.string.editor_group_effects
    EditorAdjustmentGroup.DETAIL -> R.string.editor_group_detail
    EditorAdjustmentGroup.GEOMETRY -> R.string.editor_group_geometry
}

@Composable
internal fun EditorGroupStrip(state: EditorState, expanded: Boolean, tool: Int,
    compact: Boolean = false, list: LazyListState = rememberLazyListState(),
    navigationEnabled: Boolean = true, inlineLabels: Boolean = false, modifier: Modifier = Modifier, select: (EditorAdjustmentGroup) -> Unit) {
    LazyRow(modifier.fillMaxWidth().testTag("editor-groups"), state = list, contentPadding = PaddingValues(horizontal = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(0.dp)) {
        items(EditorAdjustmentGroup.entries, key = { it.id }) { group ->
            EditorGroupButton(state, group, expanded && EditorAdjustmentRules.groupFor(tool) == group,
                Modifier.widthIn(min = 48.dp), compact = true, navigationEnabled = navigationEnabled, inlineLabels = true) { select(group) }
        }
    }

}

@Composable
private fun EditorGroupButton(state: EditorState, group: EditorAdjustmentGroup, active: Boolean,
    modifier: Modifier, compact: Boolean, navigationEnabled: Boolean, inlineLabels: Boolean = false, onClick: () -> Unit) {
    val title = stringResource(groupTitle(group))
    val changed = EditorAdjustmentRules.isModified(EditorResetScope.Group(group), state.visibleEdits, state.resetContext())
    val status = stringResource(if (changed) R.string.hsl_adjusted else R.string.hsl_unadjusted)
    val tint = if (active) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant
    val selectable = modifier.selectable(active, enabled = state.controlsEnabled && navigationEnabled, role = Role.Tab, onClick = onClick)
        .testTag("editor-group-${group.id}").semantics(mergeDescendants = true) {
            contentDescription = title; stateDescription = status
        }
    Box(selectable.heightIn(min = 48.dp).background(if (active) tint.copy(alpha = .12f) else Color.Transparent)
        .padding(horizontal = 8.dp, vertical = 4.dp), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, Modifier.testTag("editor-group-label-${group.id}"), style = MaterialTheme.typography.labelMedium, color = tint)
            Box(Modifier.size(3.dp).background(if (changed) MaterialTheme.colorScheme.primary else Color.Transparent, CircleShape))
        }
    }
}
