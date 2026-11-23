package com.rawlab.android.editor.ui

import com.rawlab.android.ui.AppIcons

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.*
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
import com.rawlab.android.settings.canonicalZeros
import com.rawlab.android.settings.synchronizeHDR
import com.rawlab.android.settings.X3fMode
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.settings.ColorGradingZone
import com.rawlab.android.editor.controls.ColorGradingControls
import com.rawlab.android.editor.controls.ToneCurveControls
import com.rawlab.android.editor.controls.HslTargetControls
import com.rawlab.android.editor.controls.HslTargetActions
import com.rawlab.android.editor.controls.WbProbeActions
import com.rawlab.android.editor.controls.WbProbeControls
import com.rawlab.android.settings.Film
import com.rawlab.android.settings.editingBlackPoint
import com.rawlab.android.settings.editingWhitePoint
import com.rawlab.android.settings.editingGrading
import com.rawlab.android.settings.editingHsl
import com.rawlab.android.settings.editingVibrance
import com.rawlab.android.settings.withEditingGrading
import com.rawlab.android.settings.withEditingHsl
import com.rawlab.android.settings.withEditingVibrance
import com.rawlab.android.settings.editingCurve
import com.rawlab.android.settings.editingCurveStrength
import com.rawlab.android.settings.withEditingBlackPoint
import com.rawlab.android.settings.withEditingWhitePoint
import com.rawlab.android.settings.withEditingCurve
import com.rawlab.android.settings.withEditingCurveStrength
import com.rawlab.android.settings.editingEffects
import com.rawlab.android.settings.withEditingEffects
import com.rawlab.android.settings.editingSharpening
import com.rawlab.android.settings.editingClarity
import com.rawlab.android.settings.editingDehaze
import com.rawlab.android.settings.withEditingSharpening
import com.rawlab.android.settings.withEditingClarity
import com.rawlab.android.settings.withEditingDehaze
import com.rawlab.android.settings.withHDRDenoise
import com.rawlab.android.ui.ToolIcon
import com.rawlab.android.ui.assetBitmap
import com.rawlab.android.looks.applyRecipe
import com.rawlab.android.looks.LookBrowserCategory
import com.rawlab.android.looks.browseLooks
import com.rawlab.android.settings.HDRLookSettings

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
    onGeometryLock: () -> Unit = {}, onGeometrySwap: () -> Unit = {}, onGeometryGrid: () -> Unit = {},
    onPresets: () -> Unit = {}, quickPresetsVisible: Boolean = false, quickPresetContent: @Composable () -> Unit = {}, gradingZone: ColorGradingZone = ColorGradingZone.SHADOWS,
    onGradingZoneChange: (ColorGradingZone) -> Unit = {}, gradingGlobal: Boolean = false, onGradingGlobalChange: (Boolean) -> Unit = {},
    hslTarget: HslTargetActions = HslTargetActions(), wbProbe: WbProbeActions = WbProbeActions(),
    onSelectFilm: (String) -> Boolean = { false }, onImportHDRLook: () -> Unit = {}, onApplyHDRSilver: (Boolean) -> Unit = {},
    onDeleteUnreadableLook: (com.rawlab.android.looks.UnreadableLook) -> Unit = {},
    onRollbackProcessing: () -> Unit = {}, toolOpen: Boolean = true, fine: Boolean = false,
    processingContext: Boolean = false, onDismissProcessingContext: () -> Unit = {},
    onToolUnavailable: (String) -> Unit = {},
    hdrProcessingContent: @Composable () -> Unit = {},
    workspaceIsCurrent: () -> Boolean = { true }) {
    val edits = state.visibleEdits
    val workspaceGroup = AdjustmentGroup.forTool(tool)
    val parameterEnabled = state.controlsEnabled && toolOpen && !quickPresetsVisible && state.draft?.group == workspaceGroup
    val liveState by rememberUpdatedState(state)
    val liveGroup by rememberUpdatedState(workspaceGroup)
    val liveWorkspace by rememberUpdatedState(toolOpen && !quickPresetsVisible)
    fun ownsDraft(): Boolean = workspaceIsCurrent() && liveWorkspace && liveState.controlsEnabled && liveGroup == workspaceGroup &&
        liveState.photo?.identity == state.photo?.identity && liveState.photo?.file == state.photo?.file &&
        liveState.draft?.group == workspaceGroup
    // Parameter callbacks never fall back to committed edits while a workspace opens/closes.
    // Draft presence, not preview readiness, keeps continuous rendering-time edits available.
    val editParameter: (EditSettings, Boolean) -> Unit = { next, dragging ->
        if (ownsDraft()) {
            hslTarget.cancel()
            onDraftEdit(next.canonicalZeros().synchronizeHDR(), dragging)
        }
    }
    val selectFilm: (String) -> Boolean = { id -> ownsDraft() && onSelectFilm(id) }
    val autoExposure = { if (ownsDraft()) onAutoExposure() }
    val importLook = { if (ownsDraft()) onImportLook() }
    val importHDRLook = { if (ownsDraft()) onImportHDRLook() }
    val applyHDRSilver: (Boolean) -> Unit = { master -> if (ownsDraft()) onApplyHDRSilver(master) }
    val resetParameter: (EditorResetScope) -> Unit = { scope -> if (ownsDraft()) onResetScope(scope) }
    val context = LocalContext.current
    val rawInput = state.photo?.inputKind == PhotoInputKind.RAW
    val x3fInput = state.photo?.isX3f == true
    val normalX3f = x3fInput && edits.x3fMode == X3fMode.NORMAL
    val recipes = remember(context) { MasterRecipe.load(context) }
    val bundledFilms = remember(context) { Film.all + BundledLooks.load(context) }
    var lookCategory by rememberSaveable { mutableStateOf(LookBrowserCategory.ALL) }
    var lookQuery by rememberSaveable { mutableStateOf("") }
    var lookSearchExpanded by rememberSaveable { mutableStateOf(false) }
    val filmItems = remember(state.looks, bundledFilms, lookCategory, lookQuery, state.recentLookIds) {
        browseLooks(state.looks, bundledFilms, lookCategory, lookQuery, state.recentLookIds)
    }
    val calibrated = edits.isHDREditing || !rawInput || state.preview?.temperature?.isFinite() == true
    val neutralTemperature = if (edits.isHDREditing || !rawInput) 6500f else state.preview?.temperature?.takeIf { it.isFinite() } ?: 6500f
    val neutralTint = if (edits.isHDREditing || !rawInput) 0f else state.preview?.tint?.takeIf { it.isFinite() } ?: 0f
    var menuLookId by remember { mutableStateOf<String?>(null) }
    var renameLookId by remember { mutableStateOf<String?>(null) }
    var deleteLookId by remember { mutableStateOf<String?>(null) }
    var renameText by remember { mutableStateOf("") }
    var confirmProcessingRollback by remember { mutableStateOf(false) }
    var perspective by rememberSaveable(state.photo?.identity) { mutableStateOf(false) }
    var rotation by rememberSaveable(state.photo?.identity) { mutableStateOf(false) }
    val groupList = rememberLazyListState()
    val parameterScroll = rememberScrollState()
    val parameterSession = listOf(state.photo?.identity, state.photo?.file?.absolutePath, tool, tool == 17 && perspective, tool == 17 && rotation,
        quickPresetsVisible, edits.isHDREditing)
    LaunchedEffect(quickPresetsVisible) { parameterScroll.scrollTo(0) }
    // 仅实际导航后的工具身份变化会复位；离开草稿的 Stay 不改变这个 key。
    val displayLook = if (edits.isHDREditing) edits.hdr!!.lookSettings.name ?: stringResource(R.string.neutral_look)
    else recipes.firstOrNull { it.id == edits.recipeID }?.localizedName
        ?: if (edits.film == "neutral") stringResource(R.string.neutral_look)
        else state.looks.firstOrNull { it.id == edits.film }?.name ?: edits.film
    @Composable fun groupStrip() {
        EditorGroupStrip(state, expanded, if (quickPresetsVisible) 0 else tool, sideDock, groupList, navigationEnabled, true, select = selectGroup)
    }
    Column(modifier.background(MaterialTheme.colorScheme.surface).testTag("adjustment-dock")) {
        if (!toolOpen && !quickPresetsVisible) {
            val fontScale = androidx.compose.ui.platform.LocalDensity.current.fontScale
            val columns = com.rawlab.android.editor.controls.editorGridColumns(fontScale)
            val group = EditorAdjustmentRules.groupFor(tool) ?: EditorAdjustmentGroup.LOOKS
            val gridItems = mobileEditorTools(group) + if (group == EditorAdjustmentGroup.LOOKS) listOf(-2) else emptyList()
            val gridHeight by animateDpAsState(
                com.rawlab.android.editor.controls.editorAdaptiveGridHeight(gridItems.size, fontScale).dp,
                tween(160),
                label = "home-grid-height",
            )
            Column(Modifier.fillMaxWidth().height(gridHeight).verticalScroll(parameterScroll).padding(vertical = 4.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp)) {
                gridItems.chunked(columns).forEach { row ->
                    Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        row.forEach { index ->
                            Box(Modifier.weight(1f)) {
                                if (index == -2) {
                                    val presetEnabled = navigationEnabled && state.controlsEnabled
                                    val presetColor = MaterialTheme.colorScheme.onSurfaceVariant
                                    Column(
                                        Modifier.fillMaxWidth()
                                            .heightIn(min = if (fontScale > 1.3f) 68.dp else 52.dp)
                                            .clickable(enabled = presetEnabled, role = Role.Button, onClick = onPresets)
                                            .alpha(if (presetEnabled) 1f else 0.38f)
                                            .padding(horizontal = 1.dp, vertical = 2.dp)
                                            .testTag("editor-tool-presets"),
                                        horizontalAlignment = Alignment.CenterHorizontally,
                                        verticalArrangement = Arrangement.spacedBy(3.dp),
                                    ) {
                                        Icon(AppIcons.Outlined.Bookmarks, null, Modifier.size(22.dp), tint = presetColor)
                                        Text(
                                            stringResource(R.string.preset_library),
                                            style = MaterialTheme.typography.labelSmall,
                                            color = presetColor,
                                            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                                        )
                                        Box(Modifier.size(3.dp).background(Color.Transparent, CircleShape))
                                    }
                                } else {
                                    EditorTool(state, index, false, navigationEnabled, false, onUnavailableClick = onToolUnavailable) {
                                        selectTool(index)
                                    }
                                }
                            }
                        }
                        repeat(columns - row.size) { Spacer(Modifier.weight(1f)) }
                    }
                }
            }
            groupStrip()
            return@Column
        }
        // 底栏按内容收紧；复杂工具仍受外层高度上限约束，侧栏保持填满。
        Box(Modifier.weight(1f, fill = sideDock).fillMaxWidth().testTag("editor-parameters").verticalScroll(parameterScroll)) {
        CompositionLocalProvider(LocalAdjustmentSession provides parameterSession, LocalAdjustmentFine provides fine,
            com.rawlab.android.editor.controls.LocalCompactAdjustmentRows provides (tool in listOf(8, 9, 11, 12, 13, 14, 21))) {
        Column(Modifier.fillMaxWidth()) {
        if (quickPresetsVisible) quickPresetContent() else when (tool) {
            0 -> if (edits.isHDREditing) {
                val hdr = requireNotNull(edits.hdr)
                val look = hdr.lookSettings
                val enabled = parameterEnabled && navigationEnabled
                Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp).testTag("hdr-look")) {
                    Text(look.name ?: "HDR LUT", style = MaterialTheme.typography.titleSmall)
                    Row {
                        TextButton(onClick = importHDRLook, enabled = enabled, modifier = Modifier.testTag("hdr-look-import")) {
                            Text(stringResource(R.string.import_look))
                        }
                        TextButton(onClick = { editParameter(edits.copy(hdr = hdr.withLook(HDRLookSettings())), false) },
                            enabled = enabled && !look.isDefault, modifier = Modifier.testTag("hdr-look-clear")) {
                            Text(stringResource(R.string.neutral_look))
                        }
                    }
                    Row {
                        TextButton(onClick = { applyHDRSilver(false) }, enabled = enabled, modifier = Modifier.testTag("hdr-look-silver")) {
                            Text("HDR Silver")
                        }
                        TextButton(onClick = { applyHDRSilver(true) }, enabled = enabled, modifier = Modifier.testTag("hdr-look-silver-master")) {
                            Text("HDR Silver Master")
                        }
                    }
                    if (!look.isDefault) NumericControl(R.string.transfer_field_strength, look.strength * 100, 0f..200f, "%",
                        enabled, { value, dragging -> editParameter(edits.copy(hdr = hdr.withLook(look.copy(strength = value / 100))), dragging) },
                        { editParameter(edits.copy(hdr = hdr.withLook(look.copy(strength = 1f))), false) }, defaultValue = 100f, stepOverride = 1f)
                }
            } else Column {
                LookBrowserControls(lookCategory, { lookCategory = it }, lookQuery, { lookQuery = it },
                    lookSearchExpanded, { lookSearchExpanded = it }, parameterEnabled, importLook)
                if (filmItems.isEmpty()) {
                    Column(Modifier.fillMaxWidth().testTag("looks.empty"), horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(stringResource(R.string.look_search_empty))
                        TextButton({ if (lookQuery.isEmpty()) lookCategory = LookBrowserCategory.ALL else { lookQuery = ""; lookSearchExpanded = false } }) {
                            Text(stringResource(if (lookQuery.isEmpty()) R.string.look_category_all else R.string.look_search_clear))
                        }
                    }
                }
                LazyRow(contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                items(filmItems, key = { it.look.id }) { item ->
                    val look = item.look
                    val builtIn = bundledFilms.firstOrNull { it.id == look.id }
                    val artwork = if (builtIn?.file != null) assetBitmap("artwork/${builtIn.artworkName}.png", 80.dp) else null
                    val additional = builtIn != null && Film.all.none { it.id == builtIn.id }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        if (item.startsGroup) VerticalDivider(Modifier.height(106.dp).padding(horizontal = 12.dp)
                            .testTag("film-group-divider-${look.id}"))
                        Box(Modifier.width(if (additional) 132.dp else 96.dp)) {
                            Column(Modifier.fillMaxWidth().selectable(selected = edits.film == look.id,
                                enabled = parameterEnabled && look.available,
                                role = Role.RadioButton, onClick = {
                                    if (selectFilm(look.id) && filmSelectionChanged(edits, look.id)) onFilmSelected(when {
                                        look.managed -> UsageFilmKind.Custom
                                        look.id == "neutral" -> UsageFilmKind.None
                                        else -> UsageFilmKind.BuiltIn
                                    })
                                }),
                                horizontalAlignment = Alignment.CenterHorizontally) {
                                Box(Modifier.size(64.dp).border(if (edits.film == look.id) 2.dp else 0.dp,
                                    if (edits.film == look.id) MaterialTheme.colorScheme.primary else Color.Transparent).padding(3.dp), contentAlignment = Alignment.Center) {
                                    if (artwork != null) Image(artwork.asImageBitmap(), null, Modifier.fillMaxSize().testTag("film-artwork-${look.id}"))
                                    else Icon(AppIcons.Outlined.Image, null, Modifier.size(32.dp))
                                    if (look.compatibilityMode != 0) Icon(Icons.Outlined.Warning,
                                        stringResource(R.string.lut_compatibility_title), Modifier.align(Alignment.TopStart).size(20.dp)
                                            .testTag("film-compatibility-${look.id}"), tint = MaterialTheme.colorScheme.primary)
                                }
                                Text(if (look.id == "neutral") stringResource(R.string.neutral_look) else
                                    look.name + when (look.compatibilityMode) {
                                        7 -> " · " + stringResource(R.string.lut_compatibility_notice)
                                        8 -> " · " + stringResource(R.string.lut_approximate_badge)
                                        else -> if (look.appearanceUnverified) " · " + stringResource(R.string.lut_appearance_unverified) else ""
                                    },
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
                UnreadableLookRows(state.unreadableLooks, state.operation == Operation.NONE && !state.committingAdjustments &&
                    (state.draft == null || state.draft.group == AdjustmentGroup.LOOK),
                    onDeleteUnreadableLook)
            }
            1 -> NumericControl(R.string.strength, edits.strength * 100, 0f..200f, "%", parameterEnabled && (edits.film != "neutral" || edits.recipeID != null),
                { value, dragging -> editParameter(edits.copy(strength = value / 100), dragging) }, { editParameter(edits.copy(strength = 1f), false) })
            2 -> Column {
                NumericControl(R.string.exposure, edits.exposure, if (edits.isHDREditing) -4f..4f else -5f..5f, "EV", parameterEnabled,
                    { value, dragging -> editParameter(edits.copy(exposure = value), dragging) }, { editParameter(edits.copy(exposure = 0f), false) })
                var modeMenu by remember { mutableStateOf(false) }
                val modes = listOf(R.string.exposure_scene, R.string.exposure_preview, R.string.exposure_sensor)
                Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f)) {
                    TextButton(onClick = { modeMenu = true }, enabled = parameterEnabled && rawInput && !normalX3f,
                        colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.onSurfaceVariant)) {
                        Text(stringResource(modes[edits.exposureMode]), style = MaterialTheme.typography.labelMedium)
                    }
                    DropdownMenu(expanded = modeMenu, onDismissRequest = { modeMenu = false }) {
                        modes.forEachIndexed { index, title ->
                            DropdownMenuItem(text = { Text(stringResource(title)) }, onClick = {
                                modeMenu = false; editParameter(edits.copy(exposureMode = index), false)
                            })
                        }
                    }
                }
                TextButton(onClick = autoExposure, enabled = parameterEnabled && !state.rendering,
                    colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.onSurfaceVariant),
                    modifier = Modifier.testTag("exposure.auto")) {
                    Icon(AppIcons.Outlined.AutoFixHigh, null, Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp)); Text(stringResource(R.string.auto_exposure), style = MaterialTheme.typography.labelMedium)
                }
                }
            }
            3 -> NumericControl(R.string.highlights, edits.highlights * 100, -100f..100f, "%", parameterEnabled,
                { value, dragging -> editParameter(edits.copy(highlights = value / 100), dragging) }, { editParameter(edits.copy(highlights = 0f), false) })
            4 -> NumericControl(R.string.shadows, edits.shadows * 100, -100f..100f, "%", parameterEnabled,
                { value, dragging -> editParameter(edits.copy(shadows = value / 100), dragging) }, { editParameter(edits.copy(shadows = 0f), false) })
            5 -> NumericControl(R.string.contrast, edits.contrast * 100, -100f..100f, "%", parameterEnabled,
                { value, dragging -> editParameter(edits.copy(contrast = value / 100), dragging) }, { editParameter(edits.copy(contrast = 0f), false) })
            6 -> ToneCurveControls(edits.editingCurve, edits.editingCurveStrength, parameterEnabled,
                { value, dragging -> editParameter(edits.withEditingCurve(value), dragging) },
                { value, dragging -> editParameter(edits.withEditingCurveStrength(value), dragging) },
                edits.isHDREditing, hslTarget = hslTarget)
            7 -> NumericControl(R.string.saturation, edits.saturation * 100, -100f..100f, "%", parameterEnabled,
                { value, dragging -> editParameter(edits.copy(saturation = value / 100), dragging) }, { editParameter(edits.copy(saturation = 0f), false) })
            8 -> {
                if (!calibrated) Text(stringResource(R.string.wb_unavailable), Modifier.padding(12.dp), style = MaterialTheme.typography.bodySmall)
                else Column {
                    if (!rawInput && !edits.isHDREditing) {
                        Text(
                            stringResource(R.string.adjustment_summary_relative_white_balance),
                            Modifier.padding(horizontal = 16.dp, vertical = 4.dp).testTag("wb-relative-note"),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    if (!edits.isHDREditing) {
                        WbProbeControls(wbProbe, parameterEnabled)
                    }
                    NumericControl(R.string.temperature, edits.temperature, 2000f..50000f, "K", parameterEnabled,
                        { value, dragging ->
                            val nextCustomWb = if (rawInput || edits.isHDREditing) true else false
                            editParameter(edits.copy(customWb = nextCustomWb, temperature = value), dragging)
                        },
                        {
                            val nextCustomWb = if (rawInput || edits.isHDREditing) edits.recipeID == null && edits.tint != neutralTint else false
                            editParameter(edits.copy(temperature = neutralTemperature, customWb = nextCustomWb), false)
                        }, reciprocal = true, defaultValue = neutralTemperature)
                    NumericControl(R.string.tint, edits.tint, -150f..150f, "", parameterEnabled,
                        { value, dragging ->
                            val nextCustomWb = if (rawInput || edits.isHDREditing) {
                                if (edits.recipeID == null) true else edits.customWb
                            } else false
                            editParameter(edits.copy(customWb = nextCustomWb, tint = value), dragging)
                        },
                        {
                            val nextTint = if (edits.recipeID == null || !rawInput) neutralTint else 0f
                            val nextCustomWb = if (rawInput || edits.isHDREditing) edits.customWb && edits.temperature != neutralTemperature else false
                            editParameter(edits.copy(tint = nextTint, customWb = nextCustomWb), false)
                        }, defaultValue = if (edits.recipeID == null || !rawInput) neutralTint else 0f)
                }
            }
            11 -> if (edits.isHDREditing) {
                NumericControl(R.string.denoise, requireNotNull(edits.hdr).detailSettings.denoise * 100, 0f..100f, "%", parameterEnabled,
                    { value, dragging -> editParameter(edits.withHDRDenoise(value / 100), dragging) }, { resetParameter(EditorResetScope.Tool(11)) })
            } else {
                DenoiseControls(edits.denoise, parameterEnabled) { value, dragging ->
                    editParameter(edits.copy(denoise = value), dragging)
                }
            }
            12 -> PhotoEffectsControls(edits.editingEffects, vignette = true, enabled = parameterEnabled) { value, dragging ->
                editParameter(edits.withEditingEffects(value), dragging)
            }
            13 -> PhotoEffectsControls(edits.editingEffects, vignette = false, enabled = parameterEnabled) { value, dragging ->
                editParameter(edits.withEditingEffects(value), dragging)
            }
            21 -> ColorGradingControls(edits.editingGrading, parameterEnabled, gradingZone, onGradingZoneChange,
                globalSelected = gradingGlobal, onGlobalSelectedChange = onGradingGlobalChange) { value, dragging ->
                editParameter(edits.withEditingGrading(value), dragging)
            }
            14 -> Column {
                if (hslTarget.state.enabled) HslTargetControls(hslTarget, parameterEnabled)
                HslControls(edits.editingHsl, parameterEnabled, channel, onChannelChange,
                    { all -> resetParameter(if (all) EditorResetScope.AllHsl else EditorResetScope.HslChannel(channel)) }) { value, dragging -> editParameter(edits.withEditingHsl(value), dragging) }
            }
            16 -> LensControls(edits.lens, state.preview?.lens, !normalX3f && parameterEnabled && state.draft != null, state.rendering, onReset = { resetParameter(EditorResetScope.Tool(16)) }) { value ->
                if (ownsDraft()) onDraftEdit(edits.copy(lens = value), false)
            }
            17 -> Column {
                Row(Modifier.fillMaxWidth()) {
                    listOf(R.string.geometry_crop_tool, R.string.geometry_rotation_tool, R.string.geometry_perspective_tool).forEachIndexed { index, title ->
                        val selected = (if (perspective) 2 else if (rotation) 1 else 0) == index
                        TextButton(onClick = { perspective = index == 2; rotation = index == 1 },
                            modifier = Modifier.weight(1f).heightIn(min = 48.dp).testTag(when (index) { 0 -> "geometry-crop-tab"; 1 -> "geometry-rotation-tab"; else -> "editor-tool-perspective" })) {
                            Text(stringResource(title), color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
                GeometryControls(edits.geometry, parameterEnabled && state.draft != null,
                ratio = state.draft?.geometryRatio ?: GeometryRatio.FREE,
                portrait = state.draft?.geometryPortrait ?: false,
                ratioEnabled = state.draftReady, onRatioChange = onGeometryRatio, onReset = { resetParameter(EditorResetScope.Tool(17)) },
                lockedRatio = state.draft?.geometryLockedRatio, physicalAspect = state.draft?.geometryAspect,
                canvasAspect = state.draft?.geometryCanvasAspect ?: 1f, onLock = onGeometryLock, onSwap = onGeometrySwap,
                showsGrid = state.draft?.geometryGrid ?: true, onGrid = onGeometryGrid, perspective = perspective, rotation = rotation) { value, dragging ->
                if (ownsDraft()) onDraftEdit(edits.copy(geometry = value), dragging)
            }
            }
            15 -> MasterRecipePicker(recipes, edits.recipeID, parameterEnabled) { recipe ->
                if (recipe == null) selectFilm("neutral") else editParameter(edits.applyRecipe(recipe), false)
            }
            18 -> NumericControl(R.string.black_point, edits.editingBlackPoint, -100f..100f, "%", parameterEnabled,
                { value, dragging -> editParameter(edits.withEditingBlackPoint(value), dragging) }, { editParameter(edits.withEditingBlackPoint(0f), false) })
            19 -> NumericControl(R.string.white_point, edits.editingWhitePoint, -100f..100f, "%", parameterEnabled,
                { value, dragging -> editParameter(edits.withEditingWhitePoint(value), dragging) }, { editParameter(edits.withEditingWhitePoint(0f), false) })
            20 -> NumericControl(R.string.vibrance, edits.editingVibrance, -100f..100f, "%", parameterEnabled,
                { value, dragging -> editParameter(edits.withEditingVibrance(value), dragging) }, { editParameter(edits.withEditingVibrance(0f), false) })
            22 -> NumericControl(R.string.clarity, edits.editingClarity, -100f..100f, "%", parameterEnabled,
                { value, dragging -> editParameter(edits.withEditingClarity(value), dragging) }, { editParameter(edits.withEditingClarity(0f), false) })
            23 -> NumericControl(R.string.dehaze, edits.editingDehaze, -100f..100f, "%", parameterEnabled,
                { value, dragging -> editParameter(edits.withEditingDehaze(value), dragging) }, { editParameter(edits.withEditingDehaze(0f), false) })
            10 -> NumericControl(R.string.sharpening, edits.editingSharpening * 100, 0f..200f, "%", parameterEnabled,
                { value, dragging -> editParameter(edits.withEditingSharpening(value / 100), dragging) }, { editParameter(edits.withEditingSharpening(0f), false) })
            24 -> if (edits.isHDREditing) NumericControl(R.string.hdr_peak_limit, edits.hdr!!.renditionSettings.peakLimitEV, 0f..6f, "EV", parameterEnabled,
                { value, dragging -> editParameter(edits.copy(hdr = edits.hdr.withRendition(edits.hdr.renditionSettings.copy(peakLimitEV = value))), dragging) },
                { editParameter(edits.copy(hdr = edits.hdr.withRendition(edits.hdr.renditionSettings.copy(peakLimitEV = 0f))), false) }, stepOverride = .1f)
            25 -> if (edits.isHDREditing) NumericControl(R.string.hdr_sdr_exposure, edits.hdr!!.renditionSettings.sdrExposureEV, -4f..4f, "EV", parameterEnabled,
                { value, dragging -> editParameter(edits.copy(hdr = edits.hdr.withRendition(edits.hdr.renditionSettings.copy(sdrExposureEV = value))), dragging) },
                { editParameter(edits.copy(hdr = edits.hdr.withRendition(edits.hdr.renditionSettings.copy(sdrExposureEV = 0f))), false) }, stepOverride = .1f)
            26 -> if (edits.isHDREditing) NumericControl(R.string.hdr_sdr_contrast, edits.hdr!!.renditionSettings.sdrContrast, -100f..100f, "%", parameterEnabled,
                { value, dragging -> editParameter(edits.copy(hdr = edits.hdr.withRendition(edits.hdr.renditionSettings.copy(sdrContrast = value))), dragging) },
                { editParameter(edits.copy(hdr = edits.hdr.withRendition(edits.hdr.renditionSettings.copy(sdrContrast = 0f))), false) })
            27 -> if (edits.isHDREditing) NumericControl(R.string.hdr_sdr_saturation, edits.hdr!!.renditionSettings.sdrSaturation, -100f..100f, "%", parameterEnabled,
                { value, dragging -> editParameter(edits.copy(hdr = edits.hdr.withRendition(edits.hdr.renditionSettings.copy(sdrSaturation = value))), dragging) },
                { editParameter(edits.copy(hdr = edits.hdr.withRendition(edits.hdr.renditionSettings.copy(sdrSaturation = 0f))), false) })
        }
        if (tool in listOf(0, 15) && !edits.isHDREditing) CompositionLocalProvider(
            com.rawlab.android.editor.controls.LocalCompactAdjustmentRows provides true) { NumericControl(R.string.strength, edits.strength * 100, 0f..200f, "%",
            parameterEnabled && (edits.film != "neutral" || edits.recipeID != null),
            { value, dragging -> editParameter(edits.copy(strength = value / 100), dragging) },
            { editParameter(edits.copy(strength = 1f), false) }, defaultValue = 100f) }
        }
        }
        }
        if (state.draft != null && !quickPresetsVisible) {
            Column {
                HorizontalDivider()
                Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = onDiscardDraft, enabled = !state.committingAdjustments,
                        modifier = Modifier.size(48.dp).testTag("draft.cancel")) {
                        Icon(Icons.Outlined.Close, stringResource(R.string.cancel), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Text(stringResource(editorToolTitles[tool]), Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                        style = MaterialTheme.typography.titleSmall)
                    IconButton(onClick = onApplyDraft, enabled = state.draftReady,
                        modifier = Modifier.size(48.dp).testTag("draft.apply")) {
                        Icon(
                            Icons.Outlined.Check,
                            stringResource(R.string.adjustment_apply),
                            tint = if (state.draft?.changed == true) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
        }


    }
    if (processingContext) AlertDialog(onDismissRequest = onDismissProcessingContext,
        title = { Text(stringResource(R.string.photo_processing_settings)) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(displayLook)
                val migrationText = if (state.matchingProcessing) R.string.processing_migration_matching else when (state.processingMigration?.status) {
                    com.rawlab.android.settings.ProcessingMigrationStatus.MIGRATED -> R.string.processing_migration_completed
                    com.rawlab.android.settings.ProcessingMigrationStatus.KEPT -> R.string.processing_migration_kept
                    com.rawlab.android.settings.ProcessingMigrationStatus.ROLLED_BACK -> R.string.processing_migration_rolled_back
                    null -> null
                }
                migrationText?.let { Text(stringResource(it), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.testTag("processing.migration.status")) }
                if (state.processingMigration?.status == com.rawlab.android.settings.ProcessingMigrationStatus.MIGRATED) {
                    TextButton(onClick = { confirmProcessingRollback = true },
                        enabled = state.controlsEnabled && state.draft == null && !state.matchingProcessing,
                        modifier = Modifier.testTag("processing.migration.rollback")) {
                        Text(stringResource(R.string.processing_migration_rollback))
                    }
                }
                hdrProcessingContent()
                if (x3fInput) {
                    val available = remember { NativeProcessor.nativeX3fAvailable() }
                    Text(stringResource(R.string.x3f_rendering), style = MaterialTheme.typography.titleSmall)
                    X3fMode.entries.forEach { mode ->
                        val enabled = state.controlsEnabled && state.draft == null && (mode != X3fMode.NORMAL || available)
                        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp)
                            .testTag("x3f.mode.${mode.id}")
                            .selectable(selected = edits.x3fMode == mode, enabled = enabled, role = Role.RadioButton,
                                onClick = { onEdit(edits.selectX3fMode(mode), false) }),
                            verticalAlignment = Alignment.CenterVertically) {
                            RadioButton(selected = edits.x3fMode == mode, onClick = null, enabled = enabled)
                            Text(stringResource(if (mode == X3fMode.NORMAL) R.string.x3f_normal else R.string.x3f_legacy), Modifier.padding(start = 8.dp))
                        }
                    }
                    Text(stringResource(if (normalX3f) R.string.x3f_relative_wb else R.string.x3f_legacy_description),
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }, confirmButton = { TextButton(onClick = onDismissProcessingContext) { Text(stringResource(R.string.confirm)) } })
    if (confirmProcessingRollback) AlertDialog(onDismissRequest = { confirmProcessingRollback = false },
        title = { Text(stringResource(R.string.processing_migration_rollback)) },
        text = { Text(stringResource(R.string.processing_migration_rollback_warning)) },
        confirmButton = { TextButton(onClick = { confirmProcessingRollback = false; onDismissProcessingContext(); onRollbackProcessing() }) {
            Text(stringResource(R.string.processing_migration_rollback))
        } }, dismissButton = { TextButton(onClick = { confirmProcessingRollback = false }) { Text(stringResource(R.string.cancel)) } })
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
                    else Icon(AppIcons.Outlined.Layers, null, Modifier.size(32.dp), tint = if (selected == recipe?.id) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                    if (selected == recipe?.id) Icon(Icons.Outlined.CheckCircle, null,
                        Modifier.align(Alignment.TopEnd).size(20.dp).background(MaterialTheme.colorScheme.surface, CircleShape)
                            .testTag("recipe-selected-${recipe?.id ?: "neutral"}"), tint = MaterialTheme.colorScheme.primary)
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

@Composable
internal fun UnreadableLookRows(entries: List<com.rawlab.android.looks.UnreadableLook>, enabled: Boolean,
    onDelete: (com.rawlab.android.looks.UnreadableLook) -> Unit) {
    if (entries.isEmpty()) return
    var deleting by remember { mutableStateOf<com.rawlab.android.looks.UnreadableLook?>(null) }
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp).testTag("looks.unreadable")) {
        Text(stringResource(R.string.look_unreadable_title), style = MaterialTheme.typography.titleSmall)
        entries.forEach { entry ->
            Row(Modifier.fillMaxWidth().padding(vertical = 8.dp).testTag("looks.rowUnreadable"), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(entry.name?.takeIf { it.isNotBlank() } ?: entry.path?.takeIf { it.isNotBlank() }
                        ?: stringResource(R.string.look_unreadable_name))
                    Text(stringResource(R.string.look_unreadable_reason), style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                TextButton(onClick = { deleting = entry }, enabled = enabled, modifier = Modifier.testTag("looks.deleteUnreadable")) {
                    Text(stringResource(R.string.message_remove))
                }
            }
        }
    }
    deleting?.let { entry ->
        AlertDialog(onDismissRequest = { deleting = null },
            title = { Text(stringResource(R.string.remove_look_confirmation,
                entry.name?.takeIf { it.isNotBlank() } ?: entry.path?.takeIf { it.isNotBlank() } ?: stringResource(R.string.look_unreadable_name))) },
            text = { Text(stringResource(R.string.look_remove_body)) },
            confirmButton = { TextButton(onClick = { deleting = null; onDelete(entry) }, enabled = enabled,
                modifier = Modifier.testTag("looks.deleteUnreadable.confirm")) { Text(stringResource(R.string.confirm)) } },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text(stringResource(R.string.cancel)) } })
    }
}
