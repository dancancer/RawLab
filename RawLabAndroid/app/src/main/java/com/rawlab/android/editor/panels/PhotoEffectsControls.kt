package com.rawlab.android.editor.panels

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import kotlin.math.ceil
import kotlin.math.floor
import com.rawlab.android.R
import com.rawlab.android.editor.controls.NumericControl
import com.rawlab.android.settings.FilmOpticsSettings
import com.rawlab.android.settings.GrainFormatPreset
import com.rawlab.android.settings.GrainToneCurve
import com.rawlab.android.settings.PhotoEffectParameter
import com.rawlab.android.settings.PhotoEffectsSettings
import com.rawlab.android.settings.canonicalZero

@Composable
internal fun PhotoEffectsControls(
    value: PhotoEffectsSettings,
    vignette: Boolean,
    enabled: Boolean,
    isHDREditing: Boolean = false,
    filmOptics: FilmOpticsSettings = FilmOpticsSettings(),
    onFilmOpticsChange: (FilmOpticsSettings, Boolean) -> Unit = { _, _ -> },
    onChange: (PhotoEffectsSettings, Boolean) -> Unit,
) {
    val amount = if (vignette) PhotoEffectParameter.VIGNETTE_AMOUNT else PhotoEffectParameter.GRAIN_AMOUNT
    var advanced by rememberSaveable(vignette) { mutableStateOf(!vignette) }
    var halationExpanded by rememberSaveable { mutableStateOf(false) }
    var bloomExpanded by rememberSaveable { mutableStateOf(false) }
    val parameters = PhotoEffectParameter.entries.filter {
        it.isVignette == vignette && (!vignette || advanced || it == amount)
    }
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        if (!vignette && !isHDREditing) {
            FilmGrainOptionsRow(
                value = value,
                enabled = enabled,
                onChange = { next -> onChange(next, false) },
            )
        }
        parameters.forEachIndexed { idx, parameter ->
            val active = enabled && (parameter != PhotoEffectParameter.VIGNETTE_HIGHLIGHTS || value.vignetteAmount < 0f)
            NumericControl(
                label = parameter.label,
                value = value.value(parameter),
                range = parameter.range,
                unit = "",
                enabled = active,
                defaultValue = parameter.defaultValue,
                onValue = { next, dragging ->
                    val updated = if (vignette) value.withEffect(parameter, next) else value.withGrainEffect(parameter, next)
                    onChange(updated, dragging)
                },
                onReset = {
                    val updated = if (vignette) value.withEffect(parameter, parameter.defaultValue)
                    else value.withGrainEffect(parameter, parameter.defaultValue)
                    onChange(updated, false)
                },
                showReset = !vignette || advanced,
            )
            if (vignette && idx == 0) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                    horizontalArrangement = Arrangement.End,
                ) {
                    TextButton(
                        onClick = { advanced = !advanced },
                        modifier = Modifier.testTag("effects.vignette.advanced"),
                    ) {
                        Text(stringResource(if (advanced) R.string.collapse_vignette else R.string.expand_vignette))
                    }
                }
            }
            if (parameter == PhotoEffectParameter.VIGNETTE_HIGHLIGHTS && value.vignetteAmount >= 0f)
                Text(stringResource(R.string.vignette_highlights_unavailable), Modifier.padding(horizontal = 16.dp),
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (!vignette && !isHDREditing) {
            HorizontalDivider(Modifier.padding(vertical = 4.dp))
            FilmOpticsSectionHeader(
                title = stringResource(R.string.halation_amount),
                expanded = halationExpanded,
                modified = !filmOptics.isHalationDefault,
                enabled = enabled,
                tag = "effects.halation.toggle",
                onToggle = { halationExpanded = !halationExpanded },
                onReset = { onFilmOpticsChange(filmOptics.resetHalation(), false) },
            )
            if (halationExpanded) {
                val halActive = enabled && filmOptics.halationAmount > 0f
                NumericControl(
                    label = R.string.halation_amount,
                    value = filmOptics.halationAmount,
                    range = 0f..100f,
                    unit = "",
                    enabled = enabled,
                    defaultValue = 0f,
                    onValue = { v, d -> onFilmOpticsChange(filmOptics.copy(halationAmount = round1(v, 0f..100f)), d) },
                    onReset = { onFilmOpticsChange(filmOptics.copy(halationAmount = 0f), false) },
                )
                NumericControl(
                    label = R.string.halation_threshold,
                    value = filmOptics.halationThreshold,
                    range = 0f..100f,
                    unit = "",
                    enabled = halActive,
                    defaultValue = 75f,
                    onValue = { v, d -> onFilmOpticsChange(filmOptics.copy(halationThreshold = round1(v, 0f..100f)), d) },
                    onReset = { onFilmOpticsChange(filmOptics.copy(halationThreshold = 75f), false) },
                )
                NumericControl(
                    label = R.string.halation_radius,
                    value = filmOptics.halationRadius,
                    range = 0f..100f,
                    unit = "",
                    enabled = halActive,
                    defaultValue = 35f,
                    onValue = { v, d -> onFilmOpticsChange(filmOptics.copy(halationRadius = round1(v, 0f..100f)), d) },
                    onReset = { onFilmOpticsChange(filmOptics.copy(halationRadius = 35f), false) },
                )
                NumericControl(
                    label = R.string.halation_hue,
                    value = filmOptics.halationHue,
                    range = -100f..100f,
                    unit = "",
                    enabled = halActive,
                    defaultValue = 0f,
                    onValue = { v, d -> onFilmOpticsChange(filmOptics.copy(halationHue = round1(v, -100f..100f)), d) },
                    onReset = { onFilmOpticsChange(filmOptics.copy(halationHue = 0f), false) },
                )
            }
            FilmOpticsSectionHeader(
                title = stringResource(R.string.bloom_amount),
                expanded = bloomExpanded,
                modified = !filmOptics.isBloomDefault,
                enabled = enabled,
                tag = "effects.bloom.toggle",
                onToggle = { bloomExpanded = !bloomExpanded },
                onReset = { onFilmOpticsChange(filmOptics.resetBloom(), false) },
            )
            if (bloomExpanded) {
                val bloomActive = enabled && filmOptics.bloomAmount > 0f
                NumericControl(
                    label = R.string.bloom_amount,
                    value = filmOptics.bloomAmount,
                    range = 0f..100f,
                    unit = "",
                    enabled = enabled,
                    defaultValue = 0f,
                    onValue = { v, d -> onFilmOpticsChange(filmOptics.copy(bloomAmount = round1(v, 0f..100f)), d) },
                    onReset = { onFilmOpticsChange(filmOptics.copy(bloomAmount = 0f), false) },
                )
                NumericControl(
                    label = R.string.bloom_threshold,
                    value = filmOptics.bloomThreshold,
                    range = 0f..100f,
                    unit = "",
                    enabled = bloomActive,
                    defaultValue = 70f,
                    onValue = { v, d -> onFilmOpticsChange(filmOptics.copy(bloomThreshold = round1(v, 0f..100f)), d) },
                    onReset = { onFilmOpticsChange(filmOptics.copy(bloomThreshold = 70f), false) },
                )
                NumericControl(
                    label = R.string.bloom_radius,
                    value = filmOptics.bloomRadius,
                    range = 0f..100f,
                    unit = "",
                    enabled = bloomActive,
                    defaultValue = 40f,
                    onValue = { v, d -> onFilmOpticsChange(filmOptics.copy(bloomRadius = round1(v, 0f..100f)), d) },
                    onReset = { onFilmOpticsChange(filmOptics.copy(bloomRadius = 40f), false) },
                )
            }
        }
    }
}

@Composable
private fun FilmGrainOptionsRow(
    value: PhotoEffectsSettings,
    enabled: Boolean,
    onChange: (PhotoEffectsSettings) -> Unit,
) {
    var curveMenu by rememberSaveable { mutableStateOf(false) }
    var presetMenu by rememberSaveable { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 2.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.grain_tone_curve), style = MaterialTheme.typography.labelLarge)
            Spacer(Modifier.weight(1f))
            Box {
                TextButton(
                    onClick = { curveMenu = true },
                    enabled = enabled,
                    modifier = Modifier.testTag("effects.grain.toneCurve"),
                ) {
                    Text(stringResource(value.grainToneCurve.labelRes))
                }
                DropdownMenu(expanded = curveMenu, onDismissRequest = { curveMenu = false }) {
                    GrainToneCurve.entries.forEach { curve ->
                        DropdownMenuItem(
                            text = { Text(stringResource(curve.labelRes)) },
                            onClick = {
                                curveMenu = false
                                onChange(value.copy(grainToneCurve = curve))
                            },
                        )
                    }
                }
            }
        }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.grain_format_preset), style = MaterialTheme.typography.labelLarge)
            Spacer(Modifier.weight(1f))
            Box {
                TextButton(
                    onClick = { presetMenu = true },
                    enabled = enabled,
                    modifier = Modifier.testTag("effects.grain.formatPreset"),
                ) {
                    Text(stringResource(value.grainFormatPreset.labelRes))
                }
                DropdownMenu(expanded = presetMenu, onDismissRequest = { presetMenu = false }) {
                    GrainFormatPreset.entries.forEach { preset ->
                        DropdownMenuItem(
                            text = { Text(stringResource(preset.labelRes)) },
                            onClick = {
                                presetMenu = false
                                onChange(value.applyGrainFormatPreset(preset))
                            },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun FilmOpticsSectionHeader(
    title: String,
    expanded: Boolean,
    modified: Boolean,
    enabled: Boolean,
    tag: String,
    onToggle: () -> Unit,
    onReset: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TextButton(onClick = onToggle, modifier = Modifier.testTag(tag)) {
            val suffix = if (modified) " ·" else ""
            Text("$title$suffix")
        }
        Spacer(Modifier.weight(1f))
        if (expanded) {
            TextButton(onClick = onReset, enabled = enabled && modified) {
                Text(stringResource(R.string.editor_reset_confirm))
            }
        }
    }
}

private fun round1(value: Float, range: ClosedFloatingPointRange<Float>): Float {
    if (!value.isFinite()) return range.start
    val r = if (value >= 0f) floor(value + .5f) else ceil(value - .5f)
    return r.coerceIn(range.start, range.endInclusive).canonicalZero()
}

private val GrainToneCurve.labelRes: Int
    get() = when (this) {
        GrainToneCurve.LEGACY -> R.string.grain_curve_legacy
        GrainToneCurve.NEGATIVE_ASYMMETRIC -> R.string.grain_curve_negative_asymmetric
    }

private val GrainFormatPreset.labelRes: Int
    get() = when (this) {
        GrainFormatPreset.CUSTOM -> R.string.denoise_custom
        GrainFormatPreset.FILM_135 -> R.string.grain_format_135
        GrainFormatPreset.FILM_120 -> R.string.grain_format_120
    }

private val PhotoEffectParameter.label: Int
    get() = when (this) {
        PhotoEffectParameter.VIGNETTE_AMOUNT -> R.string.vignette_amount
        PhotoEffectParameter.VIGNETTE_MIDPOINT -> R.string.vignette_midpoint
        PhotoEffectParameter.VIGNETTE_ROUNDNESS -> R.string.vignette_roundness
        PhotoEffectParameter.VIGNETTE_FEATHER -> R.string.vignette_feather
        PhotoEffectParameter.VIGNETTE_HIGHLIGHTS -> R.string.vignette_highlights
        PhotoEffectParameter.GRAIN_AMOUNT -> R.string.grain_amount
        PhotoEffectParameter.GRAIN_SIZE -> R.string.grain_size
        PhotoEffectParameter.GRAIN_ROUGHNESS -> R.string.grain_roughness
    }
