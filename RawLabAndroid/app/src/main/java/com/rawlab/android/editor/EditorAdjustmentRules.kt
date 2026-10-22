package com.rawlab.android.editor

import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.HslSettings
import com.rawlab.android.settings.independentForReset

/** 工作区导航 ID 不进入持久化，也不替代几何/镜头草稿的 AdjustmentGroup。 */
enum class EditorAdjustmentGroup(val id: String) {
    LOOKS("looks"), LIGHT("light"), COLOR("color"), EFFECTS("effects"), DETAIL("detail"), GEOMETRY("geometry")
}

sealed interface EditorResetScope {
    data class Tool(val id: Int) : EditorResetScope
    data class Group(val group: EditorAdjustmentGroup) : EditorResetScope
    data class HslChannel(val channel: Int) : EditorResetScope
    data object AllHsl : EditorResetScope
    data object All : EditorResetScope
}

data class AsShotWhiteBalance(val temperature: Float, val tint: Float)

/**
 * defaults 保留目标照片既有的曝光基准及其他默认；显式 asShot 是 RAW 白平衡默认权威。
 * asShot 缺失时沿用 defaults 已解析的 WB；knownRecipeIds 来自 MasterRecipe.load 的 catalog。
 */
data class EditorResetContext(
    val input: PhotoInputKind,
    val defaults: EditSettings,
    val asShot: AsShotWhiteBalance? = null,
    val knownRecipeIds: Set<String> = emptySet(),
)

sealed interface EditorResetResult {
    data object NoChange : EditorResetResult
    data class Blocked(val reason: String) : EditorResetResult
    data class Ready(
        val candidate: EditSettings,
        val requiresConfirmation: Boolean,
        val convertedFields: Set<String>,
    ) : EditorResetResult
}

object EditorAdjustmentRules {
    private val toolGroups = mapOf(
        EditorAdjustmentGroup.LOOKS to listOf(0, 15, 1),
        EditorAdjustmentGroup.LIGHT to listOf(2, 3, 4, 5, 6),
        EditorAdjustmentGroup.COLOR to listOf(8, 7, 14),
        EditorAdjustmentGroup.EFFECTS to listOf(12, 13),
        EditorAdjustmentGroup.DETAIL to listOf(11, 10),
        EditorAdjustmentGroup.GEOMETRY to listOf(17, 16),
    )
    fun defaultTool(group: EditorAdjustmentGroup): Int = tools(group).first()
    fun tools(group: EditorAdjustmentGroup): List<Int> = toolGroups.getValue(group)
    fun groupFor(tool: Int): EditorAdjustmentGroup? = if (tool == 9) EditorAdjustmentGroup.COLOR
        else toolGroups.entries.firstOrNull { tool in it.value }?.key

    fun isModified(scope: EditorResetScope, snapshot: EditSettings, context: EditorResetContext): Boolean =
        valid(scope, snapshot, context) && markerSnapshot(snapshot, context) !=
            markerSnapshot(resetStored(scope, snapshot, defaults(scope, snapshot, context)), context)

    fun prepareReset(scope: EditorResetScope, snapshot: EditSettings, context: EditorResetContext): EditorResetResult {
        if (scope != EditorResetScope.All && snapshot.recipeID != null && snapshot.recipeID !in context.knownRecipeIds)
            return EditorResetResult.Blocked("Unknown recipe")
        if (!valid(scope, snapshot, context)) return EditorResetResult.Blocked("Invalid scope, recipe or white balance defaults")
        if (!isModified(scope, snapshot, context)) return EditorResetResult.NoChange
        val clearsRecipe = snapshot.recipeID != null && (scope == EditorResetScope.Group(EditorAdjustmentGroup.LOOKS) ||
            scope == EditorResetScope.Tool(15) || scope == EditorResetScope.Tool(0))
        val independent = if (clearsRecipe) snapshot.independentForReset(context.input,
            context.asShot?.temperature, context.asShot?.tint)
            ?: return EditorResetResult.Blocked(if (context.input == PhotoInputKind.RAW && context.asShot == null &&
                (snapshot.customWb || snapshot.tint != 0f)) "Missing white balance calibration"
                else "Recipe values cannot be represented without loss")
        else snapshot
        val candidate = if (clearsRecipe) independent else resetStored(scope, snapshot, defaults(scope, snapshot, context))
        val converted = if (clearsRecipe) changedFields(snapshot, candidate) else emptySet()
        return EditorResetResult.Ready(candidate,
            scope is EditorResetScope.Group || scope == EditorResetScope.All || scope == EditorResetScope.AllHsl || scope == EditorResetScope.Tool(14) ||
                converted.isNotEmpty(), converted)
    }

    private fun valid(scope: EditorResetScope, snapshot: EditSettings, context: EditorResetContext): Boolean =
        (scope == EditorResetScope.All || snapshot.recipeID == null || snapshot.recipeID in context.knownRecipeIds) &&
            (context.input != PhotoInputKind.RAW || !includesWhiteBalance(scope) || context.asShot == null ||
                (context.asShot.temperature.isFinite() && context.asShot.temperature in 2000f..50000f &&
                    context.asShot.tint.isFinite() && context.asShot.tint in -150f..150f)) &&
            when (scope) {
                is EditorResetScope.Tool -> groupFor(scope.id) != null
                is EditorResetScope.HslChannel -> scope.channel in 0..7
                else -> true
            }

    /** 忽略不生效的相机元数据；保留自定义 WB 模式、配方 tint 与所有关闭的辅助对象。 */
    private fun markerSnapshot(snapshot: EditSettings, context: EditorResetContext): EditSettings = when {
        context.input == PhotoInputKind.RASTER -> snapshot.copy(exposureMode = 2, customWb = false,
            temperature = 6500f, tint = if (snapshot.recipeID != null) snapshot.tint else 0f)
        !snapshot.customWb -> snapshot.copy(temperature = 6500f,
            tint = if (snapshot.recipeID != null) snapshot.tint else 0f)
        else -> snapshot
    }

    private fun includesWhiteBalance(scope: EditorResetScope): Boolean = scope == EditorResetScope.All ||
        scope == EditorResetScope.Group(EditorAdjustmentGroup.COLOR) ||
        scope == EditorResetScope.Tool(8) || scope == EditorResetScope.Tool(9)

    private fun defaults(scope: EditorResetScope, snapshot: EditSettings, context: EditorResetContext): EditSettings {
        val defaults = context.defaults.effectiveFor(context.input).copy(processing = snapshot.processing)
        if (context.input == PhotoInputKind.RAW && includesWhiteBalance(scope) && context.asShot != null) {
            val source = if (scope == EditorResetScope.All) snapshot.copy(recipeID = null) else snapshot
            val wb = source.resetWhiteBalance(context.asShot.temperature, context.asShot.tint)
            return defaults.copy(customWb = wb.customWb, temperature = wb.temperature, tint = wb.tint)
        }
        return if (scope != EditorResetScope.All && snapshot.recipeID != null) defaults.copy(tint = 0f) else defaults
    }

    private fun resetStored(scope: EditorResetScope, s: EditSettings, d: EditSettings): EditSettings = when (scope) {
        EditorResetScope.All -> d.copy(film = "neutral", recipeID = null, strength = 1f)
        EditorResetScope.AllHsl -> s.copy(hsl = d.hsl)
        is EditorResetScope.HslChannel -> s.copy(hsl = HslSettings(s.hsl.packed().mapIndexed { index, value ->
            if (index % 8 == scope.channel) d.hsl.packed()[index] else value
        }))
        is EditorResetScope.Group -> tools(scope.group).fold(s) { state, id -> resetTool(id, state, d) }
        is EditorResetScope.Tool -> resetTool(scope.id, s, d)
    }

    private fun resetTool(id: Int, s: EditSettings, d: EditSettings): EditSettings = when (id) {
        0 -> s.copy(film = "neutral")
        15 -> s.copy(recipeID = null)
        1 -> s.copy(strength = d.strength)
        2 -> s.copy(exposure = d.exposure, exposureMode = d.exposureMode)
        3 -> s.copy(highlights = d.highlights)
        4 -> s.copy(shadows = d.shadows)
        5 -> s.copy(contrast = d.contrast)
        6 -> s.copy(toneCurve = d.toneCurve)
        7 -> s.copy(saturation = d.saturation)
        8, 9 -> s.copy(customWb = d.customWb, temperature = d.temperature, tint = d.tint)
        10 -> s.copy(sharpening = d.sharpening)
        11 -> s.copy(denoise = d.denoise, displayChromaDenoise = d.displayChromaDenoise)
        12 -> s.copy(effects = s.effects.copy(vignetteAmount = d.effects.vignetteAmount,
            vignetteMidpoint = d.effects.vignetteMidpoint, vignetteRoundness = d.effects.vignetteRoundness,
            vignetteFeather = d.effects.vignetteFeather, vignetteHighlights = d.effects.vignetteHighlights))
        13 -> s.copy(effects = s.effects.copy(grainAmount = d.effects.grainAmount,
            grainSize = d.effects.grainSize, grainRoughness = d.effects.grainRoughness))
        14 -> s.copy(hsl = d.hsl)
        16 -> s.copy(lens = d.lens)
        17 -> s.copy(geometry = d.geometry)
        else -> s
    }

    private fun changedFields(before: EditSettings, after: EditSettings): Set<String> = buildSet {
        if (before.exposure != after.exposure) add("exposure")
        if (before.highlights != after.highlights) add("highlights")
        if (before.shadows != after.shadows) add("shadows")
        if (before.contrast != after.contrast) add("contrast")
        if (before.saturation != after.saturation) add("saturation")
        if (before.hsl != after.hsl) add("hsl")
        if (before.customWb != after.customWb) add("whiteBalanceMode")
        if (before.temperature != after.temperature) add("temperature")
        if (before.tint != after.tint) add("tint")
    }
}
