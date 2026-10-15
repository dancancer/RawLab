package com.rawlab.android

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.selection.selectable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.dp
import kotlin.math.abs

internal val editorToolOrder = listOf(0, 15) + (1..14).toList() + listOf(17, 16)

internal val editorToolTitles = listOf(R.string.film, R.string.strength, R.string.exposure, R.string.highlights,
    R.string.shadows, R.string.contrast, R.string.tone_curve, R.string.saturation, R.string.temperature,
    R.string.tint, R.string.sharpening, R.string.denoise, R.string.vignette, R.string.grain, R.string.hsl,
    R.string.master_recipes, R.string.info_lens, R.string.geometry)

internal val editorToolIcons: List<ImageVector> get() = listOf(Icons.Outlined.PhotoFilter, Icons.Outlined.Tune,
    Icons.Outlined.Exposure, Icons.Outlined.WbSunny, Icons.Outlined.DarkMode, Icons.Outlined.Contrast,
    Icons.Outlined.SsidChart, Icons.Outlined.WaterDrop, Icons.Outlined.Thermostat, Icons.Outlined.Palette,
    Icons.Outlined.Deblur, Icons.Outlined.NoiseAware, Icons.Outlined.Circle, Icons.Outlined.Grain,
    Icons.Outlined.Tune, Icons.Outlined.Layers, Icons.Outlined.CenterFocusStrong, Icons.Outlined.CropRotate)

@Composable
internal fun EditorToolStrip(state: EditorState, selected: Int, select: (Int) -> Unit) {
    val list = rememberLazyListState()
    LaunchedEffect(selected) {
        val index = editorToolOrder.indexOf(selected)
        if (list.layoutInfo.visibleItemsInfo.none { it.index == index && it.offset >= 0 &&
            it.offset + it.size <= list.layoutInfo.viewportEndOffset }) list.scrollToItem((index - 2).coerceAtLeast(0))
    }
    LazyRow(Modifier.fillMaxWidth().testTag("editor-tools"), state = list, contentPadding = PaddingValues(horizontal = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        items(editorToolOrder, key = { it }) { index -> EditorTool(state, index, selected == index) { select(index) } }
    }
}

@Composable
internal fun EditorTool(state: EditorState, index: Int, selected: Boolean, onClick: () -> Unit) {
    val edits = state.visibleEdits
    val scalar = when (index) {
        1 -> Triple(edits.strength * 100f, 100f, 0f..200f)
        2 -> Triple(edits.exposure, 0f, -4f..4f)
        3 -> Triple(edits.highlights * 100f, 0f, -100f..100f)
        4 -> Triple(edits.shadows * 100f, 0f, -100f..100f)
        5 -> Triple(edits.contrast * 100f, 0f, -100f..100f)
        6 -> Triple(edits.toneCurve * 100f, 0f, -100f..100f)
        7 -> Triple(edits.saturation * 100f, 0f, -100f..100f)
        8 -> Triple(edits.temperature, state.preview?.temperature ?: edits.temperature, 2000f..50000f)
        9 -> Triple(edits.tint, if (edits.recipeID != null) 0f else state.preview?.tint ?: edits.tint, -150f..150f)
        10 -> Triple(edits.sharpening * 100f, 0f, 0f..200f)
        else -> null
    }
    val changed = scalar?.let { abs(it.first - it.second) > .0001f } ?: when (index) {
        0 -> edits.film != "neutral"
        15 -> edits.recipeID != null
        11 -> edits.denoise != DenoiseSettings()
        12 -> !edits.effects.isEffectDefault(true)
        13 -> !edits.effects.isEffectDefault(false)
        14 -> !edits.hsl.isIdentity
        16 -> edits.lens != LensSettings()
        17 -> !edits.geometry.isIdentity
        else -> false
    }
    val primary = MaterialTheme.colorScheme.primary
    val muted = MaterialTheme.colorScheme.onSurfaceVariant
    val color = if (selected) primary else muted
    val number = scalar?.let { formatAdjustment(it.first, if (index == 2) .05f else 1f) }
    val title = stringResource(editorToolTitles[index])
    val status = stringResource(if (changed) R.string.hsl_adjusted else R.string.hsl_unadjusted)
    Column(Modifier.width(80.dp).heightIn(min = 88.dp).selectable(selected, enabled = state.controlsEnabled,
        role = Role.Tab, onClick = onClick).testTag("editor-tool-$index").semantics(mergeDescendants = true) {
        contentDescription = title
        stateDescription = listOfNotNull(number, status).joinToString(" · ")
    }.padding(vertical = 8.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) {
            Canvas(Modifier.fillMaxSize()) {
                val inset = 1.dp.toPx()
                drawCircle(if (selected) primary else muted.copy(alpha = .6f), style = Stroke(1.dp.toPx()))
                scalar?.let {
                    val sweep = AdjustmentScale(it.third, 1f, it.second).sweep(it.first)
                    if (sweep != 0f) drawArc(primary, -90f, sweep, false, Offset(inset, inset),
                        Size(size.width - inset * 2, size.height - inset * 2), style = Stroke(2.5.dp.toPx()))
                }
                if (changed) drawCircle(primary, 2.dp.toPx(), Offset(size.width / 2, 3.dp.toPx()))
            }
            if (selected && number != null && number.length <= 5 && LocalDensity.current.fontScale <= 1.3f) {
                Text(number, style = MaterialTheme.typography.labelSmall, color = primary)
            } else Icon(editorToolIcons[index], null, Modifier.size(24.dp), tint = color)
        }
        Text(title, style = MaterialTheme.typography.labelSmall, color = color)
    }
}
