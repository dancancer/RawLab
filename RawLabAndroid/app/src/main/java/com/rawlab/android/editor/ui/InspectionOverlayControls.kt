package com.rawlab.android.editor.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Place
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rawlab.android.R
import com.rawlab.android.editor.inspection.InspectionBitmap
import com.rawlab.android.editor.inspection.InspectionColorSample
import com.rawlab.android.editor.inspection.InspectionGeometryMapper
import com.rawlab.android.editor.inspection.InspectionOverlayMode
import com.rawlab.android.editor.inspection.InspectionSessionState
import com.rawlab.android.editor.render.PreviewDetailOverlay
import com.rawlab.android.editor.render.PreviewPair
import com.rawlab.android.ui.AppIcons

internal fun inspectionOverlayLabelRes(mode: InspectionOverlayMode): Int = when (mode) {
    InspectionOverlayMode.NONE -> R.string.overlay_none
    InspectionOverlayMode.SKETCH_LUMINANCE -> R.string.overlay_sketch_luminance
    InspectionOverlayMode.WARM_COOL_BW -> R.string.overlay_warm_cool_bw
    InspectionOverlayMode.OVERSATURATION_HEATMAP -> R.string.overlay_oversaturation_heatmap
    InspectionOverlayMode.SKIN_HUE_AMPLIFICATION -> R.string.overlay_skin_hue_boost
    InspectionOverlayMode.NEUTRAL_GRAY_50 -> R.string.overlay_gray_50
}

@Composable
internal fun InspectionOverlayPill(
    overlay: InspectionOverlayMode,
    onSelectOverlay: (InspectionOverlayMode) -> Unit,
    modifier: Modifier = Modifier,
) {
    var menuExpanded by remember { mutableStateOf(false) }
    LaunchedEffect(overlay.isActive) {
        if (!overlay.isActive) menuExpanded = false
    }
    if (!overlay.isActive) return

    val accent = MaterialTheme.colorScheme.primary
    val leadingIcon = if (overlay == InspectionOverlayMode.NEUTRAL_GRAY_50) {
        AppIcons.Outlined.Contrast
    } else {
        AppIcons.Outlined.Layers
    }

    val pillBg = Color.Black.copy(alpha = 0.68f)
    val pillBorder = accent.copy(alpha = 0.42f)

    Box(modifier = modifier.testTag("inspection-overlay-pill")) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .height(48.dp)
                .drawBehind {
                    val vPad = 5.dp.toPx()
                    val strokePx = 1.dp.toPx()
                    val h = (size.height - vPad * 2f).coerceAtLeast(1f)
                    val radius = CornerRadius(h / 2f, h / 2f)
                    drawRoundRect(
                        color = pillBg,
                        topLeft = Offset(0f, vPad),
                        size = Size(size.width, h),
                        cornerRadius = radius,
                    )
                    drawRoundRect(
                        color = pillBorder,
                        topLeft = Offset(strokePx / 2f, vPad + strokePx / 2f),
                        size = Size((size.width - strokePx).coerceAtLeast(1f), (h - strokePx).coerceAtLeast(1f)),
                        cornerRadius = radius,
                        style = Stroke(width = strokePx),
                    )
                },
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                modifier = Modifier
                    .fillMaxHeight()
                    .widthIn(min = 48.dp)
                    .clip(RoundedCornerShape(topStart = 24.dp, bottomStart = 24.dp))
                    .clickable(
                        role = Role.DropdownList,
                        onClickLabel = stringResource(R.string.overlay_section),
                    ) { menuExpanded = true }
                    .padding(start = 12.dp, end = 8.dp)
                    .testTag("inspection-overlay-switcher"),
            ) {
                Icon(
                    imageVector = leadingIcon,
                    contentDescription = null,
                    tint = accent,
                    modifier = Modifier.size(16.dp),
                )
                Text(
                    text = stringResource(inspectionOverlayLabelRes(overlay)),
                    style = MaterialTheme.typography.labelMedium,
                    color = Color.White,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.widthIn(max = 200.dp),
                )
                Icon(
                    imageVector = if (menuExpanded) AppIcons.Outlined.ExpandLess else AppIcons.Outlined.ExpandMore,
                    contentDescription = stringResource(R.string.overlay_section),
                    tint = Color.White.copy(alpha = 0.72f),
                    modifier = Modifier.size(16.dp),
                )
            }
            Box(
                Modifier
                    .width(1.dp)
                    .height(16.dp)
                    .background(Color.White.copy(alpha = 0.16f)),
            )
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .fillMaxHeight()
                    .widthIn(min = 48.dp)
                    .clip(RoundedCornerShape(topEnd = 24.dp, bottomEnd = 24.dp))
                    .clickable(
                        role = Role.Button,
                        onClickLabel = stringResource(R.string.overlay_none),
                    ) {
                        menuExpanded = false
                        onSelectOverlay(InspectionOverlayMode.NONE)
                    }
                    .padding(horizontal = 12.dp)
                    .testTag("inspection-overlay-clear"),
            ) {
                Icon(
                    imageVector = Icons.Outlined.Close,
                    contentDescription = stringResource(R.string.overlay_none),
                    tint = Color.White.copy(alpha = 0.86f),
                    modifier = Modifier.size(16.dp),
                )
            }
        }

        InspectionOverlayDropdownMenu(
            expanded = menuExpanded,
            selected = overlay,
            onDismissRequest = { menuExpanded = false },
        ) { mode ->
            menuExpanded = false
            onSelectOverlay(mode)
        }
    }
}

@Composable
internal fun InspectionSamplingHud(
    inspection: InspectionSessionState,
    pair: PreviewPair,
    detailTiles: List<PreviewDetailOverlay>,
    detailOverlay: PreviewDetailOverlay?,
    holdingBefore: Boolean,
    onPinAnchor: () -> Unit,
    onSelectAnchor: (Long) -> Unit,
    onRemoveAnchor: (Long) -> Unit,
    onClearAnchors: () -> Unit,
    onSelectOverlay: (InspectionOverlayMode) -> Unit,
    onToggleGray50: () -> Unit,
    onCloseMonitor: () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    val showSamplingCard = inspection.monitorEnabled || inspection.anchors.isNotEmpty()
    val show = showSamplingCard || inspection.overlay.isActive
    if (!show) return

    var anchorsExpanded by rememberSaveable { mutableStateOf(true) }
    val accent = MaterialTheme.colorScheme.primary

    Column(
        modifier = modifier.testTag("inspection-sampling-hud"),
        verticalArrangement = Arrangement.spacedBy(8.dp),
        horizontalAlignment = Alignment.Start,
    ) {
        if (inspection.overlay.isActive) {
            InspectionOverlayPill(
                overlay = inspection.overlay,
                onSelectOverlay = onSelectOverlay,
            )
        }

        if (showSamplingCard) {
            val liveX = inspection.liveOutputX ?: if (inspection.monitorEnabled) 0.5f else null
            val liveY = inspection.liveOutputY ?: if (inspection.monitorEnabled) 0.5f else null
            val liveSample: InspectionColorSample? = if (liveX != null && liveY != null) {
                InspectionBitmap.samplePreview(
                    base = if (holdingBefore) pair.neutral else pair.result,
                    detailTiles = detailTiles,
                    detailOverlay = detailOverlay,
                    useNeutral = holdingBefore,
                    normX = liveX,
                    normY = liveY,
                )
            } else null

            val srcSize = InspectionGeometryMapper.inferSourceSize(
                pair.nativeWidth,
                pair.nativeHeight,
                pair.renderedGeometry,
            )

            Surface(
                modifier = Modifier
                    .widthIn(max = 420.dp)
                    .testTag("inspection-sampling-card"),
                shape = RoundedCornerShape(12.dp),
                color = Color.Black.copy(alpha = 0.68f),
                contentColor = Color.White,
                border = BorderStroke(1.dp, Color.White.copy(alpha = 0.14f)),
            ) {
                Column(
                    modifier = Modifier.padding(
                        start = 12.dp,
                        end = 4.dp,
                        top = 2.dp,
                        bottom = if (anchorsExpanded && inspection.anchors.isNotEmpty()) 8.dp else 2.dp,
                    ),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Box(
                            Modifier
                                .size(11.dp)
                                .background(
                                    liveSample?.let { Color(it.r, it.g, it.b) } ?: Color.Transparent,
                                    CircleShape,
                                )
                                .border(1.dp, Color.White.copy(alpha = 0.5f), CircleShape),
                        )
                        Text(
                            text = liveSample?.let { "${it.rgbText} · ${it.hsbText}" } ?: "-- · --° --% --%",
                            fontFamily = FontFamily.Monospace,
                            fontSize = 11.sp,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(0.dp),
                        ) {
                            IconButton(
                                onClick = onPinAnchor,
                                enabled = inspection.canPinMore,
                                modifier = Modifier.size(36.dp).testTag("inspection-pin-anchor"),
                            ) {
                                Icon(
                                    Icons.Outlined.Place,
                                    stringResource(R.string.sampling_pin_anchor),
                                    modifier = Modifier.size(16.dp),
                                )
                            }
                            if (inspection.anchors.isNotEmpty()) {
                                IconButton(
                                    onClick = onClearAnchors,
                                    modifier = Modifier.size(36.dp).testTag("inspection-clear-anchors"),
                                ) {
                                    Icon(
                                        Icons.Outlined.Delete,
                                        stringResource(R.string.sampling_clear_anchors),
                                        modifier = Modifier.size(16.dp),
                                    )
                                }
                            }
                            val gray50Active = inspection.overlay == InspectionOverlayMode.NEUTRAL_GRAY_50
                            IconButton(
                                onClick = onToggleGray50,
                                modifier = Modifier.size(36.dp).testTag("inspection-gray50-toggle"),
                            ) {
                                Box(
                                    contentAlignment = Alignment.Center,
                                    modifier = Modifier
                                        .size(26.dp)
                                        .background(
                                            if (gray50Active) accent.copy(alpha = 0.18f) else Color.Transparent,
                                            CircleShape,
                                        ),
                                ) {
                                    Icon(
                                        imageVector = AppIcons.Outlined.Contrast,
                                        contentDescription = stringResource(R.string.overlay_gray_50),
                                        tint = if (gray50Active) accent else Color.White,
                                        modifier = Modifier.size(16.dp),
                                    )
                                }
                            }
                            if (inspection.anchors.isNotEmpty()) {
                                IconButton(
                                    onClick = { anchorsExpanded = !anchorsExpanded },
                                    modifier = Modifier.size(36.dp).testTag("inspection-anchors-collapse"),
                                ) {
                                    Icon(
                                        imageVector = if (anchorsExpanded) AppIcons.Outlined.ExpandLess else AppIcons.Outlined.ExpandMore,
                                        contentDescription = stringResource(R.string.sampling_monitor),
                                        modifier = Modifier.size(18.dp),
                                    )
                                }
                            } else if (inspection.monitorEnabled) {
                                IconButton(
                                    onClick = onCloseMonitor,
                                    modifier = Modifier.size(36.dp).testTag("inspection-monitor-close"),
                                ) {
                                    Icon(
                                        imageVector = Icons.Outlined.Close,
                                        contentDescription = stringResource(R.string.sampling_monitor),
                                        modifier = Modifier.size(16.dp),
                                    )
                                }
                            }
                        }
                    }

                    if (anchorsExpanded && inspection.anchors.isNotEmpty()) {
                        val beforeLabel = stringResource(R.string.editor_compare_before)
                        val afterLabel = stringResource(R.string.result)
                        Column(
                            modifier = Modifier.padding(end = 6.dp),
                            verticalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            inspection.anchors.forEachIndexed { idx, anchor ->
                                val outPt = InspectionGeometryMapper.sourceNormToOutputNorm(
                                    anchor.sourceX,
                                    anchor.sourceY,
                                    srcSize.first,
                                    srcSize.second,
                                    pair.renderedGeometry,
                                )
                                val before = outPt?.let {
                                    InspectionBitmap.samplePreview(pair.neutral, detailTiles, detailOverlay, true, it.first, it.second)
                                }
                                val after = outPt?.let {
                                    InspectionBitmap.samplePreview(pair.result, detailTiles, detailOverlay, false, it.first, it.second)
                                }
                                val selected = inspection.selectedAnchorId == anchor.id
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clip(RoundedCornerShape(6.dp))
                                        .clickable { onSelectAnchor(anchor.id) }
                                        .background(
                                            if (selected) accent.copy(alpha = 0.14f) else Color.White.copy(alpha = 0.05f),
                                            RoundedCornerShape(6.dp),
                                        )
                                        .border(
                                            1.dp,
                                            if (selected) accent.copy(alpha = 0.45f) else Color.Transparent,
                                            RoundedCornerShape(6.dp),
                                        )
                                        .padding(start = 8.dp, end = 2.dp, top = 4.dp, bottom = 4.dp)
                                        .testTag("inspection-anchor-row-${idx + 1}"),
                                ) {
                                    Text(
                                        text = "#${idx + 1}",
                                        fontFamily = FontFamily.Monospace,
                                        fontSize = 11.sp,
                                        color = if (selected) accent else Color.White,
                                    )
                                    Column(
                                        modifier = Modifier.weight(1f),
                                        verticalArrangement = Arrangement.spacedBy(1.dp),
                                    ) {
                                        Text(
                                            text = "$beforeLabel  ${before?.let { "${it.rgbText} · ${it.hsbText}" } ?: "--"}",
                                            fontFamily = FontFamily.Monospace,
                                            fontSize = 10.sp,
                                            color = Color.White.copy(alpha = 0.72f),
                                            maxLines = 1,
                                            overflow = TextOverflow.Ellipsis,
                                        )
                                        Text(
                                            text = "$afterLabel  ${after?.let { "${it.rgbText} · ${it.hsbText}" } ?: "--"}",
                                            fontFamily = FontFamily.Monospace,
                                            fontSize = 10.sp,
                                            color = Color.White,
                                            maxLines = 1,
                                            overflow = TextOverflow.Ellipsis,
                                        )
                                    }
                                    IconButton(
                                        onClick = { onRemoveAnchor(anchor.id) },
                                        modifier = Modifier.size(32.dp).testTag("inspection-anchor-remove-${idx + 1}"),
                                    ) {
                                        Icon(
                                            Icons.Outlined.Close,
                                            stringResource(R.string.message_remove),
                                            modifier = Modifier.size(14.dp),
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
internal fun EditorCanvasBottomStack(
    visible: Boolean,
    showInspection: Boolean,
    inspection: InspectionSessionState,
    pair: PreviewPair?,
    detailTiles: List<PreviewDetailOverlay>,
    detailOverlay: PreviewDetailOverlay?,
    holdingBefore: Boolean,
    onPinAnchor: () -> Unit,
    onSelectAnchor: (Long) -> Unit,
    onRemoveAnchor: (Long) -> Unit,
    onClearAnchors: () -> Unit,
    onSelectOverlay: (InspectionOverlayMode) -> Unit,
    onToggleGray50: () -> Unit,
    onCloseMonitor: () -> Unit,
    onHeightChanged: (Int) -> Unit = {},
    modifier: Modifier = Modifier,
    workspaceActions: @Composable () -> Unit,
) {
    LaunchedEffect(visible) {
        if (!visible) onHeightChanged(0)
    }
    if (!visible) return
    Column(
        modifier = modifier
            .fillMaxWidth()
            .onSizeChanged { onHeightChanged(it.height) }
            .padding(horizontal = 8.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
        horizontalAlignment = Alignment.Start,
    ) {
        if (showInspection && pair != null) {
            InspectionSamplingHud(
                inspection = inspection,
                pair = pair,
                detailTiles = detailTiles,
                detailOverlay = detailOverlay,
                holdingBefore = holdingBefore,
                onPinAnchor = onPinAnchor,
                onSelectAnchor = onSelectAnchor,
                onRemoveAnchor = onRemoveAnchor,
                onClearAnchors = onClearAnchors,
                onSelectOverlay = onSelectOverlay,
                onToggleGray50 = onToggleGray50,
                onCloseMonitor = onCloseMonitor,
            )
        }
        workspaceActions()
    }
}

@Composable
internal fun InspectionOverlayDropdownItems(
    selected: InspectionOverlayMode,
    onSelect: (InspectionOverlayMode) -> Unit,
) {
    InspectionOverlayMode.entries.forEach { mode ->
        DropdownMenuItem(
            text = { Text(stringResource(inspectionOverlayLabelRes(mode))) },
            leadingIcon = { if (selected == mode) Icon(Icons.Outlined.Check, null) },
            modifier = Modifier.testTag("inspection-overlay-item-${mode.name.lowercase()}"),
            onClick = { onSelect(mode) },
        )
    }
}

@Composable
internal fun InspectionOverlayDropdownMenu(
    expanded: Boolean,
    selected: InspectionOverlayMode,
    onDismissRequest: () -> Unit,
    onSelect: (InspectionOverlayMode) -> Unit,
) {
    DropdownMenu(expanded = expanded, onDismissRequest = onDismissRequest) {
        InspectionOverlayDropdownItems(selected = selected, onSelect = onSelect)
    }
}
