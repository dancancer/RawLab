package com.rawlab.android.editor.canvas

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.BarChart
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.*
import androidx.compose.ui.unit.*
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupPositionProvider
import androidx.compose.ui.window.PopupProperties
import com.rawlab.android.R
import com.rawlab.android.engine.RgbHistogram

@Composable
internal fun RgbHistogramOverlay(histogram: RgbHistogram?, before: Boolean, visible: Boolean, modifier: Modifier = Modifier) {
    var expanded by rememberSaveable { mutableStateOf(false) }
    val title = stringResource(R.string.editor_rgb_histogram)
    val source = stringResource(if (before) R.string.editor_compare_before else R.string.result)
    val unavailable = stringResource(R.string.editor_statistics_unavailable)
    val action = stringResource(if (expanded) R.string.editor_collapse_histogram else R.string.editor_expand_histogram)
    val close = stringResource(R.string.editor_collapse_histogram)
    val configuration = LocalConfiguration.current
    val margin = with(LocalDensity.current) { 8.dp.roundToPx() }
    val position = remember(margin) { object : PopupPositionProvider {
        override fun calculatePosition(anchorBounds: IntRect, windowSize: IntSize, layoutDirection: LayoutDirection, popupContentSize: IntSize) =
            IntOffset((anchorBounds.right - popupContentSize.width).coerceIn(margin, maxOf(margin, windowSize.width - popupContentSize.width - margin)),
                (anchorBounds.bottom + margin).coerceIn(margin, maxOf(margin, windowSize.height - popupContentSize.height - margin)))
    } }
    // 折叠状态属于查看选项；纯预览暂时移除浮层，不改变该选项。
    if (visible) Box(modifier) {
        IconButton(onClick = { expanded = !expanded }, modifier = Modifier.size(48.dp)
            .background(Color.Black.copy(alpha = .65f), CircleShape).testTag("rgb-histogram-toggle")
            .semantics {
                contentDescription = title
                stateDescription = "$source · $action" + if (histogram == null) " · $unavailable" else ""
            }) { Icon(Icons.Outlined.BarChart, null, tint = Color.White) }
        if (expanded) Popup(popupPositionProvider = position,
            properties = PopupProperties(focusable = false, dismissOnClickOutside = false)) {
            Surface(Modifier.width(minOf(320.dp, (configuration.screenWidthDp - 24).coerceAtLeast(1).dp))
                .heightIn(max = (configuration.screenHeightDp - 48).coerceAtLeast(96).dp)
                .testTag("rgb-histogram-popup"), shape = MaterialTheme.shapes.medium,
                color = Color(0xff202020), contentColor = Color.White, shadowElevation = 6.dp) {
                Column {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                        IconButton(onClick = { expanded = false }, Modifier.size(48.dp).testTag("rgb-histogram-close")) {
                            Icon(Icons.Outlined.Close, close)
                        }
                    }
                    Column(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState())
                        .padding(start = 16.dp, end = 16.dp, bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(title, style = MaterialTheme.typography.titleMedium)
                        Text(source, Modifier.testTag("rgb-histogram-source"), style = MaterialTheme.typography.labelMedium)
                        if (histogram == null) Text(unavailable, Modifier.testTag("rgb-histogram-unavailable"), style = MaterialTheme.typography.bodyMedium)
                        else RgbHistogramPlot(histogram, Modifier.fillMaxWidth().height(80.dp).semantics {
                            contentDescription = "$title · $source"
                        })
                    }
                }
            }
        }
    }
}

@Composable
internal fun RgbHistogramPlot(histogram: RgbHistogram, modifier: Modifier = Modifier) {
    val segments = remember(histogram) { (0..255).map(histogram::segments) }
    Canvas(modifier.background(Color.Black).testTag("rgb-histogram-plot")) {
        val binWidth = size.width / 256
        for (bin in 0..255) for (segment in segments[bin]) {
            val color = when (segment.channels) {
                1 -> Color.Red; 2 -> Color.Green; 4 -> Color.Blue
                3 -> Color.Yellow; 5 -> Color.Magenta; 6 -> Color.Cyan
                else -> Color(0xffbfbfbf)
            }
            drawRect(color, Offset(bin * binWidth, size.height * (1 - segment.upper)),
                Size(binWidth, size.height * (segment.upper - segment.lower)))
        }
    }
}
