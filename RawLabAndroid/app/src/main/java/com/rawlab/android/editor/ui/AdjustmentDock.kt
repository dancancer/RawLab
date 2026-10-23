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
import androidx.compose.foundation.horizontalScroll
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
import com.rawlab.android.editor.controls.LocalAdjustmentSession
import com.rawlab.android.editor.controls.LocalAdjustmentFine
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
    onResetScope: (EditorResetScope) -> Unit, sideDock: Boolean, navigationEnabled: Boolean, compactNavigation: Boolean,
    onGeometryLock: () -> Unit = {}, onGeometrySwap: () -> Unit = {}, onGeometryGrid: () -> Unit = {}) {
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
    var more by remember { mutableStateOf(false) }
    var processingContext by remember { mutableStateOf(false) }
    var perspective by rememberSaveable(state.photo?.identity) { mutableStateOf(false) }
    val groupList = rememberLazyListState()
    val toolList = rememberLazyListState()
    val parameterScroll = rememberScrollState()
    val parameterSession = listOf(state.photo?.identity, state.photo?.file?.absolutePath, tool, tool == 17 && perspective)
    // 仅实际导航后的工具身份变化会复位；离开草稿的 Stay 不改变这个 key。
    var fine by rememberSaveable(state.photo?.identity, state.photo?.file?.absolutePath, tool) { mutableStateOf(false) }
    val displayLook = recipes.firstOrNull { it.id == edits.recipeID }?.localizedName
        ?: if (edits.film == "neutral") stringResource(R.string.neutral_look)
        else state.looks.firstOrNull { it.id == edits.film }?.name ?: edits.film
    @Composable fun dockActions() {
        Box {
            ToolIcon(Icons.Outlined.SettingsBackupRestore, R.string.reset, state.controlsEnabled && navigationEnabled) { reset = true }
            if (reset) EditorResetMenu(state, tool, channel, onDismiss = { reset = false }) { reset = false; onResetScope(it) }
        }
        Box {
            ToolIcon(Icons.Outlined.MoreHoriz, R.string.more, navigationEnabled) { more = true }
            DropdownMenu(more, { more = false }) {
                DropdownMenuItem(text = { Text(stringResource(R.string.photo_processing_settings)) }, onClick = { more = false; processingContext = true })
                DropdownMenuItem(text = { Text(stringResource(R.string.all_tools)) }, onClick = { more = false; allTools = true })
                DropdownMenuItem(text = { Text(stringResource(if (expanded) R.string.collapse_adjustments else R.string.expand_adjustments)) },
                    onClick = { more = false; toggleExpanded() })
            }
        }
    }
    @Composable fun toolStrip(modifier: Modifier = Modifier) {
        EditorToolStrip(state, tool, EditorAdjustmentRules.tools(EditorAdjustmentRules.groupFor(tool) ?: EditorAdjustmentGroup.LOOKS),
            toolList, navigationEnabled, true, modifier, perspective = perspective,
            onPerspective = { perspective = true; selectTool(17) }, select = { if (it == 17) perspective = false; selectTool(it) })
    }
    @Composable fun groupStrip() {
        EditorGroupStrip(state, expanded, tool, sideDock, groupList, navigationEnabled, true, select = selectGroup)
    }
    @Composable fun toolRow() {
        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
            toolStrip(Modifier.weight(1f))
            if (tool !in listOf(0, 9, 15, 16)) {
                val fineHint = stringResource(R.string.editor_fine_hint)
                Text(stringResource(R.string.adjustment_fine), style = MaterialTheme.typography.labelSmall)
                Switch(checked = fine, onCheckedChange = { fine = it }, enabled = state.controlsEnabled,
                    modifier = Modifier.minimumInteractiveComponentSize().testTag("adjustment-fine").semantics { contentDescription = fineHint })
            }
            dockActions()
        }
    }
    val scrollTools = compactNavigation && !sideDock
    Column(modifier.background(MaterialTheme.colorScheme.surface).testTag("adjustment-dock")) {
        if (sideDock) groupStrip()
        if (!expanded) { if (!sideDock) groupStrip(); return@Column }
        if (!scrollTools) toolRow()
        Box(Modifier.weight(1f).fillMaxWidth().testTag("editor-parameters").verticalScroll(parameterScroll)) {
        CompositionLocalProvider(LocalAdjustmentSession provides parameterSession, LocalAdjustmentFine provides fine) {
        Column(Modifier.fillMaxWidth()) {
            if (scrollTools) toolRow()
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
                ratioEnabled = state.draftReady, onRatioChange = onGeometryRatio, onReset = { onResetScope(EditorResetScope.Tool(17)) },
                lockedRatio = state.draft?.geometryLockedRatio, physicalAspect = state.draft?.geometryAspect,
                canvasAspect = state.draft?.geometryCanvasAspect ?: 1f, onLock = onGeometryLock, onSwap = onGeometrySwap,
                showsGrid = state.draft?.geometryGrid ?: true, onGrid = onGeometryGrid, perspective = perspective) { value, dragging ->
                onDraftEdit(edits.copy(geometry = value), dragging)
            }
            15 -> MasterRecipePicker(recipes, edits.recipeID, state.controlsEnabled) { recipe ->
                onEdit(if (recipe == null) edits.selectFilm("neutral", state.preview?.tint) else edits.applyRecipe(recipe), false)
            }
            10 -> NumericControl(R.string.sharpening, edits.sharpening * 100, 0f..200f, "%", state.controlsEnabled,
                { value, dragging -> onEdit(edits.copy(sharpening = value / 100), dragging) }, { onEdit(edits.copy(sharpening = 0f), false) })
        }
        }
        }
        }
        if (state.draft != null) {
            Column {
                HorizontalDivider()
                Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = onDiscardDraft, contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp), modifier = Modifier.weight(1f).heightIn(min = 48.dp).testTag("draft.cancel")) { Text(stringResource(R.string.cancel)) }
                    Button(onClick = onApplyDraft, enabled = state.canApplyDraft, contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp), modifier = Modifier.weight(1f).heightIn(min = 48.dp).testTag("draft.apply")) { Text(stringResource(R.string.adjustment_apply)) }
                }
            }
        }
        if (!sideDock) groupStrip()

    }
    if (processingContext) AlertDialog(onDismissRequest = { processingContext = false },
        title = { Text(stringResource(R.string.photo_processing_settings)) },
        text = { Text(displayLook) }, confirmButton = { TextButton(onClick = { processingContext = false }) { Text(stringResource(R.string.confirm)) } })
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
