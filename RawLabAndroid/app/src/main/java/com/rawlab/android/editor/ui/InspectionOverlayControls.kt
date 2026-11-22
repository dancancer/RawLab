package com.rawlab.android.editor.ui

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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rawlab.android.R
import com.rawlab.android.editor.inspection.InspectionColorSample
import com.rawlab.android.editor.inspection.InspectionGeometryMapper
import com.rawlab.android.editor.inspection.InspectionOverlayMode
import com.rawlab.android.editor.inspection.InspectionSessionState
import com.rawlab.android.editor.inspection.InspectionBitmap
import com.rawlab.android.editor.render.PreviewDetailOverlay
import com.rawlab.android.editor.render.PreviewPair

internal fun inspectionOverlayLabelRes(mode: InspectionOverlayMode): Int = when (mode) {
    InspectionOverlayMode.NONE -> R.string.overlay_none
    InspectionOverlayMode.SKETCH_LUMINANCE -> R.string.overlay_sketch_luminance
    InspectionOverlayMode.WARM_COOL_BW -> R.string.overlay_warm_cool_bw
    InspectionOverlayMode.OVERSATURATION_HEATMAP -> R.string.overlay_oversaturation_heatmap
    InspectionOverlayMode.SKIN_HUE_AMPLIFICATION -> R.string.overlay_skin_hue_boost
    InspectionOverlayMode.NEUTRAL_GRAY_50 -> R.string.overlay_gray_50
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
    modifier: Modifier = Modifier,
) {
    val show = inspection.monitorEnabled || inspection.anchors.isNotEmpty() || inspection.overlay.isActive
    if (!show) return

    val liveX = inspection.liveOutputX ?: if (inspection.monitorEnabled) 0.5f else null
    val liveY = inspection.liveOutputY ?: if (inspection.monitorEnabled) 0.5f else null
    val liveSample: InspectionColorSample? = if (liveX != null && liveY != null) {
        InspectionBitmap.samplePreview(
            base = if (holdingBefore) pair.neutral else pair.result,
            detailTiles = detailTiles,
            detailOverlay = detailOverlay,
            useNeutral = holdingBefore,
            normX = liveX,
            normY = liveY
        )
    } else null

    val srcSize = InspectionGeometryMapper.inferSourceSize(pair.nativeWidth, pair.nativeHeight, pair.renderedGeometry)

    Surface(
        modifier = modifier.testTag("inspection-sampling-hud"),
        shape = RoundedCornerShape(10.dp),
        color = Color.Black.copy(alpha = 0.76f),
        contentColor = Color.White,
        tonalElevation = 4.dp
    ) {
        Column(Modifier.padding(horizontal = 10.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            if (inspection.overlay.isActive) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.testTag("inspection-overlay-pill")
                ) {
                    Text(
                        stringResource(inspectionOverlayLabelRes(inspection.overlay)),
                        style = MaterialTheme.typography.labelMedium,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    TextButton(
                        onClick = { onSelectOverlay(InspectionOverlayMode.NONE) },
                        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 2.dp),
                        modifier = Modifier.testTag("inspection-overlay-clear")
                    ) {
                        Text(stringResource(R.string.overlay_none), fontSize = 11.sp)
                    }
                }
            }
            if (inspection.monitorEnabled || inspection.anchors.isNotEmpty()) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Box(
                        Modifier
                            .size(10.dp)
                            .background(
                                liveSample?.let { Color(it.r, it.g, it.b) } ?: Color.Transparent,
                                CircleShape
                            )
                            .border(1.dp, Color.White.copy(alpha = 0.5f), CircleShape)
                    )
                    Text(
                        liveSample?.let { "RGB ${it.rgbText} · ${it.hsbText}" } ?: "RGB -- · --° --% --%",
                        fontFamily = FontFamily.Monospace,
                        fontSize = 11.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false)
                    )
                    IconButton(
                        onClick = onPinAnchor,
                        enabled = inspection.canPinMore,
                        modifier = Modifier.size(32.dp).testTag("inspection-pin-anchor")
                    ) {
                        Icon(Icons.Outlined.Place, stringResource(R.string.sampling_pin_anchor), modifier = Modifier.size(16.dp))
                    }
                    if (inspection.anchors.isNotEmpty()) {
                        IconButton(
                            onClick = onClearAnchors,
                            modifier = Modifier.size(32.dp).testTag("inspection-clear-anchors")
                        ) {
                            Icon(Icons.Outlined.Delete, stringResource(R.string.sampling_clear_anchors), modifier = Modifier.size(16.dp))
                        }
                    }
                    TextButton(
                        onClick = onToggleGray50,
                        contentPadding = PaddingValues(horizontal = 6.dp, vertical = 2.dp),
                        modifier = Modifier.testTag("inspection-gray50-toggle")
                    ) {
                        Text(
                            stringResource(R.string.overlay_gray_50),
                            fontSize = 10.sp,
                            color = if (inspection.overlay == InspectionOverlayMode.NEUTRAL_GRAY_50) Color.Yellow else Color.White
                        )
                    }
                }

                val beforeLabel = stringResource(R.string.editor_compare_before)
                val afterLabel = stringResource(R.string.result)
                inspection.anchors.forEachIndexed { idx, anchor ->
                    val outPt = InspectionGeometryMapper.sourceNormToOutputNorm(
                        anchor.sourceX,
                        anchor.sourceY,
                        srcSize.first,
                        srcSize.second,
                        pair.renderedGeometry
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
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                        modifier = Modifier
                            .clickable { onSelectAnchor(anchor.id) }
                            .background(if (selected) Color.White.copy(alpha = 0.12f) else Color.Transparent, RoundedCornerShape(4.dp))
                            .padding(horizontal = 4.dp, vertical = 2.dp)
                    ) {
                        Text(
                            "#${idx + 1}",
                            fontFamily = FontFamily.Monospace,
                            fontSize = 10.sp,
                            color = if (selected) Color.Yellow else Color.White
                        )
                        Text(
                            "$beforeLabel ${before?.let { "${it.rgbText} ${it.hsbText}" } ?: "--"} | $afterLabel ${after?.let { "${it.rgbText} ${it.hsbText}" } ?: "--"}",
                            fontFamily = FontFamily.Monospace,
                            fontSize = 10.sp,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f, fill = false)
                        )
                        IconButton(
                            onClick = { onRemoveAnchor(anchor.id) },
                            modifier = Modifier.size(24.dp)
                        ) {
                            Icon(Icons.Outlined.Close, stringResource(R.string.message_remove), modifier = Modifier.size(12.dp))
                        }
                    }
                }
            }
        }
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
            onClick = { onSelect(mode) }
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
