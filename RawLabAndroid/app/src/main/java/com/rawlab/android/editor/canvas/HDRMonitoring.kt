package com.rawlab.android.editor.canvas

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.rawlab.android.R
import com.rawlab.android.engine.HDRDisplayState
import com.rawlab.android.engine.HDRPreviewMode
import com.rawlab.android.engine.HDRStatistics
import kotlin.math.log2

@Composable
internal fun HDRMonitoring(statistics: HDRStatistics, display: HDRDisplayState, mode: HDRPreviewMode,
    falseColor: Boolean, onMode: (HDRPreviewMode) -> Unit, onFalseColor: (Boolean) -> Unit, modifier: Modifier = Modifier) {
    var expanded by remember { mutableStateOf(false) }
    Surface(modifier.widthIn(max = 224.dp), shape = MaterialTheme.shapes.small,
        color = MaterialTheme.colorScheme.surface) {
        Column(Modifier.padding(8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            TextButton(onClick = { expanded = !expanded }, modifier = Modifier.testTag("hdr-monitoring")) {
                Text(stringResource(if (mode == HDRPreviewMode.AUTOMATIC) R.string.hdr_preview_auto else R.string.hdr_preview_sdr))
            }
            if (!display.available && mode == HDRPreviewMode.AUTOMATIC)
                Text(stringResource(R.string.hdr_display_unavailable), style = MaterialTheme.typography.labelSmall)
            if (expanded) {
                Row {
                    FilterChip(mode == HDRPreviewMode.AUTOMATIC, { onMode(HDRPreviewMode.AUTOMATIC) },
                        label = { Text(stringResource(R.string.hdr_preview_auto)) }, modifier = Modifier.testTag("hdr-preview-auto"))
                    Spacer(Modifier.width(6.dp))
                    FilterChip(mode == HDRPreviewMode.SDR, { onMode(HDRPreviewMode.SDR) },
                        label = { Text("SDR") }, modifier = Modifier.testTag("hdr-preview-sdr"))
                }
                Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                    Checkbox(falseColor, onFalseColor, modifier = Modifier.testTag("hdr-false-color"))
                    Text(stringResource(R.string.hdr_false_color), style = MaterialTheme.typography.labelMedium)
                }
                Text(stringResource(R.string.hdr_histogram), style = MaterialTheme.typography.labelMedium)
                Canvas(Modifier.fillMaxWidth().height(72.dp).testTag("hdr-histogram")) {
                    val maximum = statistics.bins.maxOrNull()?.coerceAtLeast(1) ?: 1
                    statistics.bins.forEachIndexed { index, count ->
                        val x = (index + .5f) * size.width / 256
                        drawLine(Color.LightGray, Offset(x, size.height), Offset(x, size.height * (1f - count.toFloat() / maximum)), size.width / 256)
                    }
                    val reference = size.width / 2
                    drawLine(Color.Black, Offset(reference, 0f), Offset(reference, size.height), 5f)
                    drawLine(Color.White, Offset(reference, 0f), Offset(reference, size.height), 2f)
                    val screen = ((log2(display.headroom.coerceAtLeast(1f)) + 8) / 16 * size.width).coerceIn(0f, size.width)
                    drawLine(Color.Black, Offset(screen, 0f), Offset(screen, size.height), 5f)
                    drawLine(Color.Yellow, Offset(screen, 0f), Offset(screen, size.height), 2f, pathEffect = PathEffect.dashPathEffect(floatArrayOf(5f, 5f)))
                }
                val locale = LocalConfiguration.current.locales[0]
                val percentage = java.text.NumberFormat.getPercentInstance(locale).apply { maximumFractionDigits = 1 }
                    .format(statistics.aboveWhite.toDouble() / statistics.pixels.coerceAtLeast(1))
                Text(stringResource(R.string.hdr_above_white, percentage), style = MaterialTheme.typography.labelSmall)
            }
        }
    }
}
