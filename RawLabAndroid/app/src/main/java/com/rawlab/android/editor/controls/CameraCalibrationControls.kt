package com.rawlab.android.editor.controls

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.rawlab.android.R
import com.rawlab.android.settings.CameraCalibrationSettings

private data class CalibrationPrimaryDescriptor(
    val headerRes: Int,
    val hueRes: Int,
    val saturationRes: Int,
    val getHue: (CameraCalibrationSettings) -> Float,
    val setHue: (CameraCalibrationSettings, Float) -> CameraCalibrationSettings,
    val getSaturation: (CameraCalibrationSettings) -> Float,
    val setSaturation: (CameraCalibrationSettings, Float) -> CameraCalibrationSettings,
)

private val calibrationPrimaries = listOf(
    CalibrationPrimaryDescriptor(
        R.string.calibration_red_primary, R.string.calibration_red_hue, R.string.calibration_red_saturation,
        { it.redHue }, { s, v -> s.copy(redHue = v) }, { it.redSaturation }, { s, v -> s.copy(redSaturation = v) },
    ),
    CalibrationPrimaryDescriptor(
        R.string.calibration_green_primary, R.string.calibration_green_hue, R.string.calibration_green_saturation,
        { it.greenHue }, { s, v -> s.copy(greenHue = v) }, { it.greenSaturation }, { s, v -> s.copy(greenSaturation = v) },
    ),
    CalibrationPrimaryDescriptor(
        R.string.calibration_blue_primary, R.string.calibration_blue_hue, R.string.calibration_blue_saturation,
        { it.blueHue }, { s, v -> s.copy(blueHue = v) }, { it.blueSaturation }, { s, v -> s.copy(blueSaturation = v) },
    ),
)

@Composable
internal fun CameraCalibrationControls(
    settings: CameraCalibrationSettings,
    enabled: Boolean,
    onEdit: (CameraCalibrationSettings, Boolean) -> Unit,
) {
    Column(Modifier.fillMaxWidth()) {
        NumericControl(
            R.string.calibration_shadow_tint,
            settings.shadowTint,
            -100f..100f,
            "",
            enabled,
            { value, dragging -> onEdit(settings.copy(shadowTint = value.coerceIn(-100f, 100f)), dragging) },
            { onEdit(settings.copy(shadowTint = 0f), false) },
        )
        calibrationPrimaries.forEach { primary ->
            Text(
                text = stringResource(primary.headerRes),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )
            NumericControl(
                primary.hueRes,
                primary.getHue(settings),
                -100f..100f,
                "",
                enabled,
                { value, dragging -> onEdit(primary.setHue(settings, value.coerceIn(-100f, 100f)), dragging) },
                { onEdit(primary.setHue(settings, 0f), false) },
            )
            NumericControl(
                primary.saturationRes,
                primary.getSaturation(settings),
                -100f..100f,
                "",
                enabled,
                { value, dragging -> onEdit(primary.setSaturation(settings, value.coerceIn(-100f, 100f)), dragging) },
                { onEdit(primary.setSaturation(settings, 0f), false) },
            )
        }
    }
}
