package com.rawlab.android.editor.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.rawlab.android.R
import com.rawlab.android.analytics.UsageFilmKind
import com.rawlab.android.editor.*
import com.rawlab.android.editor.Operation
import com.rawlab.android.editor.controls.DenoiseControls
import com.rawlab.android.editor.controls.HslControls
import com.rawlab.android.editor.controls.NumericControl
import com.rawlab.android.editor.geometry.GeometryControls
import com.rawlab.android.editor.panels.LensControls
import com.rawlab.android.editor.panels.PhotoEffectsControls
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.geometry.GeometryRatio
import com.rawlab.android.i18n.AppStrings
import com.rawlab.android.looks.BundledLooks
import com.rawlab.android.looks.MasterRecipe
import com.rawlab.android.looks.filmStripItems
import com.rawlab.android.looks.localizedName
import com.rawlab.android.looks.localizedSubtitle
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.Film
import com.rawlab.android.ui.EditorSheetSystemBars
import com.rawlab.android.ui.ToolIcon
import com.rawlab.android.ui.assetBitmap
import com.rawlab.android.looks.applyRecipe

// ============================================================================
//  调整面板：工具栏、当前工具的控件、胶片与大师配方选择
// ============================================================================

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun AdjustmentDock(state: EditorState, modifier: Modifier, tool: Int, selectTool: (Int) -> Unit,
    expanded: Boolean, toggleExpanded: () -> Unit, compare: Boolean, toggleCompare: () -> Unit,
    onEdit: (EditSettings, Boolean) -> Unit,
    onImportLook: () -> Unit, onRenameLook: (String, String) -> Unit, onDeleteLook: (String) -> Unit,
    onAutoExposure: () -> Unit, onDraftEdit: (EditSettings, Boolean) -> Unit,
    onApplyDraft: () -> Unit, onDiscardDraft: () -> Unit,
    onFilmSelected: (UsageFilmKind) -> Unit, onGeometryRatio: (GeometryRatio, Boolean) -> Unit,
    selectGroup: (EditorAdjustmentGroup) -> Unit, channel: Int, onChannelChange: (Int) -> Unit,
    onResetScope: (EditorResetScope) -> Unit, sideDock: Boolean, navigationEnabled: Boolean, compactNavigation: Boolean) {
    val edits = state.visibleEdits
    val context = LocalContext.current
    val rawInput = state.photo?.inputKind == PhotoInputKind.RAW
    val recipes = remember(context) { MasterRecipe.load(context) }
    val bundledFilms = remember(context) { Film.all + BundledLooks.load(context) }
    val filmItems = remember(state.looks, bundledFilms) { filmStripItems(state.looks, bundledFilms) }
    val calibrated = state.preview?.temperature?.isFinite() == true
    var menuLookId by remember { mutableStateOf<String?>(null) }
    var renameLookId by remember { mutableStateOf<String?>(null) }
    var deleteLookId by remember { mutableStateOf<String?>(null) }
    var renameText by remember { mutableStateOf("") }
    var allTools by rememberSaveable { mutableStateOf(false) }
    var reset by rememberSaveable { mutableStateOf(false) }
    val groupList = rememberLazyListState()
    val toolList = rememberLazyListState()
    val parameterScroll = rememberScrollState()
    val navigationWidths = if (compactNavigation && !sideDock) {
        val measurer = rememberTextMeasurer()
        val density = LocalDensity.current
        val groupStyle = MaterialTheme.typography.labelMedium
        val toolStyle = MaterialTheme.typography.labelSmall
        val groupLabels = EditorAdjustmentGroup.entries.map { stringResource(groupTitle(it)) }
        val toolLabels = editorToolOrder.map { stringResource(editorToolTitles[it]) }
        remember(measurer, density, groupStyle, toolStyle, groupLabels, toolLabels) {
            val ringAndGap = with(density) { 52.dp.toPx() }
            (ringAndGap + groupLabels.maxOf { measurer.measure(AnnotatedString(it), groupStyle).size.width }) to
                (ringAndGap + toolLabels.maxOf { measurer.measure(AnnotatedString(it), toolStyle).size.width })
        }
    } else 1f to 1f
    @Composable fun dockActions() {
            // 全部重置用另一个图标，免得和下方参数行的“重置此项”看成同一个按钮
            Box {
                ToolIcon(Icons.Outlined.SettingsBackupRestore, R.string.reset, state.controlsEnabled && navigationEnabled) { reset = true }
                if (reset) EditorResetMenu(state, tool, channel, onDismiss = { reset = false }) {
                    reset = false; onResetScope(it)
                }
            }
            ToolIcon(Icons.Outlined.GridView, R.string.all_tools, navigationEnabled) { allTools = true }
            ToolIcon(if (expanded) Icons.Outlined.ExpandMore else Icons.Outlined.ExpandLess,
                if (expanded) R.string.collapse_adjustments else R.string.expand_adjustments, enabled = navigationEnabled, onClick = toggleExpanded)
    }
    @Composable fun toolStrip(modifier: Modifier = Modifier) {
        EditorToolStrip(state, tool, EditorAdjustmentRules.tools(EditorAdjustmentRules.groupFor(tool) ?: EditorAdjustmentGroup.LOOKS),
            toolList, navigationEnabled, compactNavigation, modifier, selectTool)
    }
    @Composable fun groupStrip(modifier: Modifier = Modifier) {
        EditorGroupStrip(state, expanded, tool, sideDock, groupList, navigationEnabled,
            compactNavigation && !sideDock, modifier, selectGroup)
    }
    @Composable fun compactNavigationRow() {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            if (sideDock) toolStrip(Modifier.weight(1f))
            else {
                groupStrip(Modifier.weight(navigationWidths.first))
                if (expanded) { VerticalDivider(Modifier.height(48.dp)); toolStrip(Modifier.weight(navigationWidths.second)) }
            }
            dockActions()
        }
    }
    Column(modifier.background(MaterialTheme.colorScheme.surface).testTag("adjustment-dock")) {
        if (!compactNavigation) Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(start = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            if (expanded && tool == 8) {
                TextButton(onClick = { onResetScope(EditorResetScope.Tool(8)) }, enabled = state.controlsEnabled && calibrated,
                    modifier = Modifier.weight(1f)) { Text(stringResource(R.string.as_shot), maxLines = 1) }
            } else {
                val displayLook = recipes.firstOrNull { it.id == edits.recipeID }?.localizedName
                    ?: if (edits.film == "neutral") stringResource(R.string.neutral_look)
                    else state.looks.firstOrNull { it.id == edits.film }?.name ?: edits.film
                Text(displayLook, Modifier.weight(1f),
                    maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.labelLarge)
            }
            if (state.draft != null) Text(stringResource(R.string.adjustment_draft), Modifier.weight(.8f), style = MaterialTheme.typography.labelSmall)
            dockActions()
        }
        if (!expanded) {
            if (compactNavigation && sideDock) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) { dockActions() }
                groupStrip()
            } else if (compactNavigation) compactNavigationRow() else groupStrip()
            return@Column
        }
        if (compactNavigation && sideDock) compactNavigationRow()
        else if (!compactNavigation) toolStrip()
        Box(Modifier.weight(1f).fillMaxWidth().testTag("editor-parameters").verticalScroll(parameterScroll)) {
        when (tool) {
            0 -> LazyRow(contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                item(key = "import-look") {
                    Column(Modifier.width(76.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                        ToolIcon(Icons.Outlined.Add, R.string.import_look, state.operation == Operation.NONE, onImportLook)
                        Text(stringResource(R.string.import_look), Modifier.heightIn(min = 42.dp).padding(top = 4.dp),
                            maxLines = 3, style = MaterialTheme.typography.labelSmall)
                    }
                }
                items(filmItems, key = { it.look.id }) { item ->
                    val look = item.look
                    val builtIn = bundledFilms.firstOrNull { it.id == look.id }
                    val artwork = if (builtIn?.file != null) assetBitmap("artwork/${builtIn.artworkName}.png", 80.dp) else null
                    val additional = builtIn != null && Film.all.none { it.id == builtIn.id }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        if (item.startsGroup) VerticalDivider(Modifier.height(122.dp).padding(horizontal = 12.dp)
                            .testTag("film-group-divider-${look.id}"))
                        Box(Modifier.width(if (additional) 132.dp else 96.dp)) {
                            Column(Modifier.fillMaxWidth().selectable(selected = edits.film == look.id,
                                enabled = state.controlsEnabled && look.available,
                                role = Role.RadioButton, onClick = {
                                    onEdit(edits.selectFilm(look.id, state.preview?.tint), false)
                                    if (filmSelectionChanged(edits, look.id)) onFilmSelected(when {
                                        look.managed -> UsageFilmKind.Custom
                                        look.id == "neutral" -> UsageFilmKind.None
                                        else -> UsageFilmKind.BuiltIn
                                    })
                                }),
                                horizontalAlignment = Alignment.CenterHorizontally) {
                                Box(Modifier.size(80.dp).border(if (edits.film == look.id) 2.dp else 0.dp,
                                    if (edits.film == look.id) MaterialTheme.colorScheme.primary else Color.Transparent).padding(3.dp), contentAlignment = Alignment.Center) {
                                    if (artwork != null) Image(artwork.asImageBitmap(), null, Modifier.fillMaxSize().testTag("film-artwork-${look.id}"))
                                    else Icon(Icons.Outlined.Image, null, Modifier.size(32.dp))
                                }
                                Text(if (look.id == "neutral") stringResource(R.string.neutral_look) else look.name,
                                    Modifier.heightIn(min = 42.dp).padding(top = 4.dp), style = MaterialTheme.typography.labelSmall)
                            }
                            if (look.managed) {
                                Box(Modifier.align(Alignment.TopEnd)) {
                                    ToolIcon(Icons.Outlined.MoreVert, R.string.more, state.operation == Operation.NONE) { menuLookId = look.id }
                                    DropdownMenu(expanded = menuLookId == look.id, onDismissRequest = { menuLookId = null }) {
                                        DropdownMenuItem(text = { Text(stringResource(R.string.rename_look)) },
                                            leadingIcon = { Icon(Icons.Outlined.Edit, null) }, onClick = {
                                                menuLookId = null; renameLookId = look.id; renameText = look.name
                                            })
                                        DropdownMenuItem(text = { Text(stringResource(R.string.delete_look)) },
                                            leadingIcon = { Icon(Icons.Outlined.Delete, null) }, onClick = {
                                                menuLookId = null; deleteLookId = look.id
                                            })
                                    }
                                }
                            }
                        }
                    }
                }
            }
            1 -> NumericControl(R.string.strength, edits.strength * 100, 0f..200f, "%", state.controlsEnabled && (edits.film != "neutral" || edits.recipeID != null),
                { value, dragging -> onEdit(edits.copy(strength = value / 100), dragging) }, { onEdit(edits.copy(strength = 1f), false) })
            2 -> Column {
                NumericControl(R.string.exposure, edits.exposure, -4f..4f, "EV", state.controlsEnabled,
                    { value, dragging -> onEdit(edits.copy(exposure = value), dragging) }, { onEdit(edits.copy(exposure = 0f), false) })
                var modeMenu by remember { mutableStateOf(false) }
                val modes = listOf(R.string.exposure_scene, R.string.exposure_preview, R.string.exposure_sensor)
                Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f)) {
                    TextButton(onClick = { modeMenu = true }, enabled = state.controlsEnabled && rawInput) { Text(stringResource(modes[edits.exposureMode])) }
                    DropdownMenu(expanded = modeMenu, onDismissRequest = { modeMenu = false }) {
                        modes.forEachIndexed { index, title ->
                            DropdownMenuItem(text = { Text(stringResource(title)) }, onClick = {
                                modeMenu = false; onEdit(edits.copy(exposureMode = index), false)
                            })
                        }
                    }
                }
                TextButton(onClick = onAutoExposure, enabled = state.controlsEnabled && !state.rendering,
                    modifier = Modifier.testTag("exposure.auto")) {
                    Icon(Icons.Outlined.AutoFixHigh, null, Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp)); Text(stringResource(R.string.auto_exposure))
                }
                }
            }
            3 -> NumericControl(R.string.highlights, edits.highlights * 100, -100f..100f, "%", state.controlsEnabled,
                { value, dragging -> onEdit(edits.copy(highlights = value / 100), dragging) }, { onEdit(edits.copy(highlights = 0f), false) })
            4 -> NumericControl(R.string.shadows, edits.shadows * 100, -100f..100f, "%", state.controlsEnabled,
                { value, dragging -> onEdit(edits.copy(shadows = value / 100), dragging) }, { onEdit(edits.copy(shadows = 0f), false) })
            5 -> NumericControl(R.string.contrast, edits.contrast * 100, -100f..100f, "%", state.controlsEnabled,
                { value, dragging -> onEdit(edits.copy(contrast = value / 100), dragging) }, { onEdit(edits.copy(contrast = 0f), false) })
            6 -> NumericControl(R.string.tone_curve, edits.toneCurve * 100, -100f..100f, "%", state.controlsEnabled,
                { value, dragging -> onEdit(edits.copy(toneCurve = value / 100), dragging) }, { onEdit(edits.copy(toneCurve = 0f), false) })
            7 -> NumericControl(R.string.saturation, edits.saturation * 100, -100f..100f, "%", state.controlsEnabled,
                { value, dragging -> onEdit(edits.copy(saturation = value / 100), dragging) }, { onEdit(edits.copy(saturation = 0f), false) })
            8 -> {
                if (!calibrated) Text(stringResource(R.string.wb_unavailable), Modifier.padding(12.dp), style = MaterialTheme.typography.bodySmall)
                else Column {
                    NumericControl(R.string.temperature, edits.temperature, 2000f..50000f, "K", state.controlsEnabled,
                        { value, dragging -> onEdit(edits.copy(customWb = true, temperature = value), dragging) },
                        { onEdit(edits.copy(temperature = state.preview?.temperature ?: 6500f,
                            customWb = edits.recipeID == null && edits.tint != state.preview?.tint), false) }, reciprocal = true,
                            defaultValue = state.preview?.temperature ?: edits.temperature)
                    NumericControl(R.string.tint, edits.tint, -150f..150f, "", state.controlsEnabled,
                        { value, dragging -> onEdit(edits.copy(customWb = if (edits.recipeID == null) true else edits.customWb, tint = value), dragging) },
                        { onEdit(edits.copy(tint = if (edits.recipeID == null) state.preview?.tint ?: 0f else 0f,
                            customWb = edits.customWb && edits.temperature != state.preview?.temperature), false) },
                            defaultValue = if (edits.recipeID == null) state.preview?.tint ?: 0f else 0f)
                }
            }
            11 -> DenoiseControls(edits.denoise, state.controlsEnabled, { onResetScope(EditorResetScope.Tool(11)) }) { value, dragging ->
                onEdit(edits.copy(denoise = value), dragging)
            }
            12 -> PhotoEffectsControls(edits.effects, vignette = true, enabled = state.controlsEnabled, onReset = { onResetScope(EditorResetScope.Tool(12)) }) { value, dragging ->
                onEdit(edits.copy(effects = value), dragging)
            }
            13 -> PhotoEffectsControls(edits.effects, vignette = false, enabled = state.controlsEnabled, onReset = { onResetScope(EditorResetScope.Tool(13)) }) { value, dragging ->
                onEdit(edits.copy(effects = value), dragging)
            }
            14 -> HslControls(edits.hsl, state.controlsEnabled, channel, onChannelChange,
                { all -> onResetScope(if (all) EditorResetScope.AllHsl else EditorResetScope.HslChannel(channel)) }) { value, dragging -> onEdit(edits.copy(hsl = value), dragging) }
            16 -> LensControls(edits.lens, state.preview?.lens, rawInput && state.controlsEnabled && state.draft != null, state.rendering, onReset = { onResetScope(EditorResetScope.Tool(16)) }) { value ->
                onDraftEdit(edits.copy(lens = value), false)
            }
            17 -> GeometryControls(edits.geometry, state.controlsEnabled && state.draft != null,
                ratio = state.draft?.geometryRatio ?: GeometryRatio.FREE,
                portrait = state.draft?.geometryPortrait ?: false,
                ratioEnabled = state.draftReady, onRatioChange = onGeometryRatio, onReset = { onResetScope(EditorResetScope.Tool(17)) }) { value, dragging ->
                onDraftEdit(edits.copy(geometry = value), dragging)
            }
            15 -> MasterRecipePicker(recipes, edits.recipeID, state.controlsEnabled) { recipe ->
                onEdit(if (recipe == null) edits.selectFilm("neutral", state.preview?.tint) else edits.applyRecipe(recipe), false)
            }
            10 -> NumericControl(R.string.sharpening, edits.sharpening * 100, 0f..200f, "%", state.controlsEnabled,
                { value, dragging -> onEdit(edits.copy(sharpening = value / 100), dragging) }, { onEdit(edits.copy(sharpening = 0f), false) })
        }
        }
        // 这块空间属于面板预算；非草稿工具也预留，切工具时不挤压参数视口。
        Box(Modifier.fillMaxWidth().height(65.dp)) {
            if (state.draft != null) Column {
                HorizontalDivider()
                Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = onDiscardDraft, modifier = Modifier.weight(1f).heightIn(min = 48.dp).testTag("draft.cancel")) { Text(stringResource(R.string.cancel)) }
                    Button(onClick = onApplyDraft, enabled = state.canApplyDraft, modifier = Modifier.weight(1f).heightIn(min = 48.dp).testTag("draft.apply")) { Text(stringResource(R.string.adjustment_apply)) }
                }
            }
        }
        if (compactNavigation && !sideDock) compactNavigationRow() else groupStrip()

    }
    if (allTools) ModalBottomSheet(onDismissRequest = { allTools = false },
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        EditorSheetSystemBars()
        Text(stringResource(R.string.all_tools), Modifier.padding(16.dp), style = MaterialTheme.typography.titleLarge)
        LazyVerticalGrid(columns = GridCells.Adaptive(96.dp), modifier = Modifier.fillMaxWidth().heightIn(max = 520.dp),
            contentPadding = PaddingValues(16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(editorToolOrder) { index -> EditorTool(state, index, index == tool, navigationEnabled) { allTools = false; selectTool(index) } }
        }
    }
    renameLookId?.let { id ->
        AlertDialog(onDismissRequest = { renameLookId = null }, title = { Text(stringResource(R.string.rename_look)) },
            text = { OutlinedTextField(value = renameText, onValueChange = { renameText = it }, singleLine = true,
                label = { Text(stringResource(R.string.look_name)) }) },
            confirmButton = { TextButton(onClick = { onRenameLook(id, renameText); renameLookId = null },
                enabled = renameText.trim().isNotEmpty()) { Text(stringResource(R.string.confirm)) } },
            dismissButton = { TextButton(onClick = { renameLookId = null }) { Text(stringResource(R.string.cancel)) } })
    }
    deleteLookId?.let { id ->
        val look = state.looks.firstOrNull { it.id == id }
        AlertDialog(onDismissRequest = { deleteLookId = null }, title = { Text(stringResource(R.string.remove_look_confirmation, look?.name.orEmpty())) },
            text = { Text(stringResource(R.string.look_remove_body)) },
            confirmButton = { TextButton(onClick = { onDeleteLook(id); deleteLookId = null }) { Text(stringResource(R.string.confirm)) } },
            dismissButton = { TextButton(onClick = { deleteLookId = null }) { Text(stringResource(R.string.cancel)) } })
    }
}

@Composable
internal fun MasterRecipePicker(recipes: List<MasterRecipe>, selected: String?, enabled: Boolean, onSelect: (MasterRecipe?) -> Unit) {
    val list = rememberLazyListState()
    LazyRow(state = list, modifier = Modifier.fillMaxWidth().testTag("master-recipe-choices"),
        contentPadding = PaddingValues(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        items(listOf<MasterRecipe?>(null) + recipes, key = { it?.id ?: "neutral" }) { recipe ->
            Column(Modifier.width(112.dp).selectable(selected == recipe?.id, enabled = enabled,
                role = Role.RadioButton, onClick = { onSelect(recipe) }), horizontalAlignment = Alignment.CenterHorizontally) {
                Box(Modifier.size(64.dp).border(1.dp, if (selected == recipe?.id) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline), contentAlignment = Alignment.Center) {
                    val artwork = recipe?.let { assetBitmap("MasterRecipeIcons/${it.id}.png", 64.dp) }
                    if (artwork != null) Image(artwork.asImageBitmap(), null, Modifier.fillMaxSize().testTag("recipe-artwork-${recipe?.id}"),
                        contentScale = ContentScale.Crop)
                    else Icon(Icons.Outlined.Layers, null, Modifier.size(32.dp), tint = if (selected == recipe?.id) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Text(recipe?.localizedName ?: stringResource(R.string.no_recipe), Modifier.heightIn(min = 22.dp),
                    style = MaterialTheme.typography.labelMedium,
                    color = if (selected == recipe?.id) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface)
                Text(recipe?.localizedSubtitle ?: AppStrings.text(R.string.neutral_direct_output), Modifier.heightIn(min = 36.dp),
                    style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}
