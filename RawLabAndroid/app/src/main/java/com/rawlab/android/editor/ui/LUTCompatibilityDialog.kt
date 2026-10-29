package com.rawlab.android.editor.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.rawlab.android.R
import com.rawlab.android.editor.PendingLookCompatibility
import com.rawlab.android.looks.*
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.album.AlbumScreen
import java.util.Locale

@Composable
internal fun LUTCompatibilityDialog(pending: PendingLookCompatibility, photo: ImportedPhoto?, storage: PhotoStorage,
    finish: (LUTCompatibility?) -> Unit) {
    var draft by rememberSaveable(pending.uri.toString(), pending.draft.sourceHash) { mutableStateOf(pending.draft) }
    var conditions by rememberSaveable(pending.uri.toString()) { mutableStateOf(LUTReferenceConditions()) }
    var advanced by rememberSaveable { mutableStateOf(false) }
    var showAll by rememberSaveable { mutableStateOf(false) }
    var referenceExpanded by rememberSaveable { mutableStateOf(false) }
    var choosingPhoto by rememberSaveable { mutableStateOf(false) }
    var selectedPhoto by rememberSaveable { mutableStateOf<String?>(null) }
    val context = LocalContext.current.applicationContext
    val preview = remember(pending.uri.toString(), pending.draft.sourceHash) { LUTCompatibilityPreview(context, pending) }
    val state = preview.state
    DisposableEffect(preview) { preview.loadInitial(photo); onDispose { preview.close() } }
    LaunchedEffect(draft.previewKey()) { preview.preview(draft) }
    LaunchedEffect(draft.previewKey()) { conditions = conditions.copy(sameProcessing = false) }
    LaunchedEffect(conditions) { preview.clearComparison() }
    val chooseReference = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) { conditions = LUTReferenceConditions(); preview.loadReference(uri) }
    }
    val choices = pending.draft.candidates.mapNotNull { candidate -> pending.draft.applying(candidate, state.displayInput)?.let { candidate to it } }
    val spaces = LUTCompatibility.spaces.associateWith { spaceName(it) }
    val ranges = mapOf("full" to stringResource(R.string.lut_range_full), "legal10" to stringResource(R.string.lut_range_legal))
    val references = mapOf("scene" to stringResource(R.string.lut_reference_scene), "display" to stringResource(R.string.lut_reference_display))
    val selected = state.frames[draft.previewKey()]
    val contentScroll = rememberScrollState()
    Dialog(onDismissRequest = { if (choosingPhoto) choosingPhoto = false else finish(null) },
        properties = DialogProperties(usePlatformDefaultWidth = false)) {
        if (choosingPhoto) {
            Surface(Modifier.fillMaxSize().testTag("lut-photo-library")) {
                AlbumScreen(storage, onBack = { choosingPhoto = false }, onFile = null,
                    onPhoto = { selectedPhoto = it.toString() },
                    selectedPhotos = selectedPhoto?.let { setOf(it) } ?: emptySet(),
                    doneLabel = stringResource(R.string.lut_use_library_photo), doneEnabled = selectedPhoto != null,
                    onDone = {
                        selectedPhoto?.let { uri ->
                            draft = pending.draft; conditions = LUTReferenceConditions()
                            preview.loadPhoto(android.net.Uri.parse(uri)); choosingPhoto = false; selectedPhoto = null
                        }
                    })
            }
        } else Surface(Modifier.fillMaxWidth(.96f).widthIn(max = 980.dp).fillMaxHeight(.94f).testTag("lut-compatibility-dialog"), shape = MaterialTheme.shapes.large) {
            Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(stringResource(R.string.lut_compatibility_title), style = MaterialTheme.typography.titleLarge)
                Column(Modifier.weight(1f).verticalScroll(contentScroll), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Text(pending.name, style = MaterialTheme.typography.titleSmall)
                    Text(stringResource(R.string.lut_guided_description))
                    OutlinedButton(onClick = { selectedPhoto = null; choosingPhoto = true }, modifier = Modifier.testTag("lut-preview-photo")) {
                        Text(stringResource(R.string.lut_choose_library_photo))
                    }
                    state.sourceName?.let { Text(it, style = MaterialTheme.typography.labelMedium) }
                    Text(stringResource(if (state.displayInput) R.string.lut_preview_conditions_display else R.string.lut_preview_conditions_raw), style = MaterialTheme.typography.bodySmall)
                    if (state.sourceName == null) Text(stringResource(R.string.lut_preview_choose_help), style = MaterialTheme.typography.bodySmall)
                    if (draft.fixedContract) Text(stringResource(R.string.lut_compatibility_fixed))
                    state.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                    Text(stringResource(R.string.lut_candidates), style = MaterialTheme.typography.titleMedium)
                    if (state.loading) LinearProgressIndicator(Modifier.fillMaxWidth())
                    Text(stringResource(R.string.lut_candidate_order), style = MaterialTheme.typography.bodySmall)
                    BoxWithConstraints {
                        val columns = if (maxWidth > 650.dp) 4 else if (maxWidth > 340.dp) 2 else 1
                        val shown = if (showAll) choices else choices.take(4)
                        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            shown.chunked(columns).forEachIndexed { row, chunk ->
                                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                    chunk.forEachIndexed { column, (candidate, configured) ->
                                        val image = state.frames[configured.previewKey()]
                                        val isSelected = configured.previewKey() == draft.previewKey()
                                        val label = stringResource(R.string.lut_candidate_option, (row * columns + column + 1).toString())
                                        val basis = stringResource(when (candidate.basis) {
                                            "file-parameters" -> R.string.lut_basis_file
                                            "partial-metadata" -> R.string.lut_basis_partial
                                            else -> R.string.lut_basis_assumed
                                        })
                                        OutlinedButton(onClick = { draft = configured }, enabled = image != null,
                                            modifier = Modifier.weight(1f).testTag("lut-${candidate.id}"),
                                            shape = MaterialTheme.shapes.medium,
                                            border = BorderStroke(if (isSelected) 2.dp else 1.dp, if (isSelected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline)) {
                                            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                                if (image != null) Image(image.bitmap.asImageBitmap(), null, Modifier.fillMaxWidth().height(110.dp), contentScale = ContentScale.Fit)
                                                else Box(Modifier.fillMaxWidth().height(110.dp))
                                                Row { Text(label); if (isSelected) Icon(Icons.Outlined.CheckCircle, null, Modifier.padding(start = 4.dp).size(18.dp)) }
                                                Text(basis, style = MaterialTheme.typography.bodySmall)
                                                state.errors[configured.previewKey()]?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
                                            }
                                        }
                                    }
                                    repeat(columns - chunk.size) { Spacer(Modifier.weight(1f)) }
                                }
                            }
                        }
                    }
                    if (choices.size > 4) TextButton(onClick = { showAll = !showAll }) { Text(stringResource(if (showAll) R.string.lut_candidates_less else R.string.lut_candidates_more)) }
                    if (choices.isEmpty()) Text(stringResource(R.string.lut_candidates_none))
                    choices.firstOrNull { it.second.previewKey() == draft.previewKey() }?.first?.let { candidate ->
                        val labels = candidate.assumptions.mapNotNull { assumption -> when (assumption) {
                            "input-space" -> stringResource(R.string.lut_input_color)
                            "output-space" -> stringResource(R.string.lut_output_color)
                            "ranges-and-interpolation" -> stringResource(R.string.lut_ranges_interpolation)
                            "neutral-base" -> if (draft.base == "rawlab-neutral-v1") stringResource(R.string.lut_base_neutral) else null
                            else -> null
                        } }
                        if (labels.isNotEmpty()) Text(stringResource(R.string.lut_candidate_assumptions, labels.joinToString(" · ")), style = MaterialTheme.typography.bodySmall)
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        PreviewPane(state.reference ?: state.baseline, stringResource(if (state.reference == null) R.string.lut_preview_without else R.string.lut_reference_image), Modifier.weight(1f))
                        PreviewPane(selected, stringResource(R.string.lut_preview_selected), Modifier.weight(1f))
                    }
                    state.errors[draft.previewKey()]?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                    TextButton(onClick = { referenceExpanded = !referenceExpanded }, modifier = Modifier.testTag("lut-reference-section")) { Text(stringResource(R.string.lut_reference_section)) }
                    if (referenceExpanded) {
                        OutlinedButton(onClick = { chooseReference.launch(arrayOf("image/jpeg", "image/png")) }, modifier = Modifier.testTag("lut-reference-picker")) { Text(stringResource(R.string.lut_reference_choose)) }
                        state.referenceName?.let { Text(it, style = MaterialTheme.typography.labelMedium) }
                        Text(stringResource(R.string.lut_reference_help), style = MaterialTheme.typography.bodySmall)
                        ReferenceCheck(stringResource(R.string.lut_reference_same_source), conditions.sameSource) { conditions = conditions.copy(sameSource = it) }
                        ReferenceCheck(stringResource(R.string.lut_reference_same_geometry), conditions.sameGeometry) { conditions = conditions.copy(sameGeometry = it) }
                        ReferenceCheck(stringResource(R.string.lut_reference_same_processing), conditions.sameProcessing) { conditions = conditions.copy(sameProcessing = it) }
                        ReferenceCheck(stringResource(R.string.lut_reference_known_srgb), conditions.knownSRGB) { conditions = conditions.copy(knownSRGB = it) }
                        OutlinedTextField(conditions.referenceSource, { conditions = conditions.copy(referenceSource = it) },
                            label = { Text(stringResource(R.string.lut_reference_notes)) }, modifier = Modifier.fillMaxWidth().testTag("lut-reference-notes"), minLines = 2)
                        OutlinedButton(onClick = { preview.compare(draft, conditions) }, enabled = conditions.canCompare && state.reference != null && selected != null,
                            modifier = Modifier.testTag("lut-reference-compare")) { Text(stringResource(R.string.lut_reference_compare)) }
                        state.comparison?.let { result ->
                            Text(stringResource(R.string.lut_reference_result, String.format(Locale.ROOT, "%.2f", result.mean * 255), String.format(Locale.ROOT, "%.2f", result.maximum * 255)))
                            Text(stringResource(R.string.lut_reference_boundary, String.format(Locale.ROOT, "%.1f", result.candidateBoundary * 100), String.format(Locale.ROOT, "%.1f", result.referenceBoundary * 100)))
                            Text(stringResource(R.string.lut_reference_boundary_help), style = MaterialTheme.typography.bodySmall)
                            Text(stringResource(R.string.lut_reference_result_help), style = MaterialTheme.typography.bodySmall)
                        }
                        state.comparisonError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                    }
                    TextButton(onClick = { advanced = !advanced }, modifier = Modifier.testTag("lut-advanced-settings")) { Text(stringResource(R.string.lut_advanced_settings)) }
                    if (advanced) {
                CompatibilityChoice(stringResource(R.string.lut_input_color), draft.inputSpace, spaces, !draft.fixedContract) { draft = draft.withInput(it) }
                if (draft.inputSpace == "linear-srgb") CompatibilityChoice(stringResource(R.string.lut_input_reference), draft.inputReference, references, !draft.fixedContract) {
                    draft = draft.copy(inputReference = it, base = if (it == "scene") "none" else "rawlab-neutral-v1")
                }
                CompatibilityChoice(stringResource(R.string.lut_input_range), draft.inputRange, ranges, !draft.fixedContract) { draft = draft.copy(inputRange = it) }
                CompatibilityChoice(stringResource(R.string.lut_output_color), draft.outputSpace, spaces, !draft.fixedContract) { draft = draft.withOutput(it) }
                if (draft.outputSpace == "linear-srgb") CompatibilityChoice(stringResource(R.string.lut_output_reference), draft.outputReference, references, !draft.fixedContract) { draft = draft.copy(outputReference = it) }
                CompatibilityChoice(stringResource(R.string.lut_output_range), draft.outputRange, ranges, !draft.fixedContract) { draft = draft.copy(outputRange = it) }
                CompatibilityChoice(stringResource(R.string.lut_interpolation), draft.interpolation,
                    mapOf("linear" to stringResource(R.string.lut_trilinear), "tetrahedral" to stringResource(R.string.lut_tetrahedral)), !draft.fixedContract) { draft = draft.copy(interpolation = it) }
                if (draft.inputReference == "display") CompatibilityChoice(stringResource(R.string.lut_base_image), draft.base,
                    mapOf("rawlab-neutral-v1" to stringResource(R.string.lut_base_neutral), "source-display" to stringResource(R.string.lut_base_display)), !draft.fixedContract) { draft = draft.copy(base = it) }

                    }
                    if (draft.base == "rawlab-neutral-v1") Text(stringResource(R.string.lut_approximate_notice))
                    if (draft.base == "source-display") Text(stringResource(R.string.lut_display_notice))
                    if (draft.extremeValues) ReferenceCheck(stringResource(R.string.lut_extreme_values), draft.confirmedExtremeValues) { draft = draft.copy(confirmedExtremeValues = it) }
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    TextButton(onClick = { finish(null) }) { Text(stringResource(R.string.cancel)) }
                    Button(onClick = { finish(draft) }, enabled = draft.canImport && (state.sourceName == null || selected != null),
                        modifier = Modifier.testTag("lut-compatibility-confirm")) { Text(stringResource(R.string.lut_compatibility_confirm)) }
                }
            }
        }
    }
}

@Composable
private fun PreviewPane(image: LUTPreviewImage?, title: String, modifier: Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title, style = MaterialTheme.typography.labelLarge)
        if (image != null) Image(image.bitmap.asImageBitmap(), title, Modifier.fillMaxWidth().height(180.dp), contentScale = ContentScale.Fit)
        else Box(Modifier.fillMaxWidth().height(180.dp)) { Text(stringResource(R.string.lut_preview_placeholder), style = MaterialTheme.typography.bodySmall) }
    }
}
@Composable
private fun ReferenceCheck(label: String, checked: Boolean, change: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth()) { Checkbox(checked, change); Text(label, Modifier.padding(top = 12.dp), style = MaterialTheme.typography.bodyMedium) }
}

@Composable
private fun CompatibilityChoice(label: String, value: String, choices: Map<String, String>, enabled: Boolean, select: (String) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Column {
        Text(label, style = MaterialTheme.typography.labelLarge)
        if (!enabled) Text(choices[value] ?: stringResource(R.string.lut_choose), style = MaterialTheme.typography.bodyLarge)
        else Box {
            OutlinedButton(onClick = { expanded = true }, enabled = enabled, modifier = Modifier.fillMaxWidth()) {
                Text(choices[value] ?: stringResource(R.string.lut_choose))
            }
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                choices.forEach { (key, title) -> DropdownMenuItem(text = { Text(title) }, onClick = { select(key); expanded = false }) }
            }
        }
    }
}

@Composable
private fun spaceName(space: String): String = when (space) {
    "srgb" -> "sRGB"
    "rec709-gamma24" -> "Rec.709 Gamma 2.4"
    "vlog-vgamut" -> "V-Log / V-Gamut"
    "slog3-sgamut3" -> "S-Log3 / S-Gamut3"
    "slog3-sgamut3-cine" -> "S-Log3 / S-Gamut3.Cine"
    else -> stringResource(R.string.lut_linear_srgb)
}
