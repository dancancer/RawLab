package com.rawlab.android.adjustments

import com.rawlab.android.editor.AsShotWhiteBalance
import com.rawlab.android.editor.EditorAdjustmentGroup
import com.rawlab.android.editor.EditorAdjustmentRules
import com.rawlab.android.editor.EditorResetContext
import com.rawlab.android.editor.EditorResetResult
import com.rawlab.android.editor.EditorResetScope
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/**
 * P1 第③步：Android 消费共享重置场景向量 `reset-scenarios-v1.json`。
 * 种子经 `AdjustmentTransfer.prepare` 写入，重置走生产入口 [EditorAdjustmentRules.prepareReset]，
 * 观察通道复用 [AdjustmentTransfer.capture]；「重置目标值」以 @spec_default 标记引用
 * `Shared/specs/adjustment-fields-v1.json` 的本端默认值（按 scale_from_protocol 反映射），
 * 不写死平台字面量。与现状的分歧按第①步棘轮模式登记进 [knownResetDivergences]。
 */
class ResetScenarioTest {
    private val fixture = JSONObject(resolveSharedFixture("reset-scenarios-v1.json").readText())

    /** 场景 id -> 已登记的精确 diff-key 集；未登记的分歧与「已修复仍留档」都必红，棘轮只减不增。 */
    private val knownResetDivergences: Map<String, Set<String>> = emptyMap()

    private val specFields: Map<String, JSONObject> by lazy {
        val fields = JSONObject(resolveSharedPath("Shared/specs/adjustment-fields-v1.json").readText())
            .getJSONArray("fields")
        (0 until fields.length()).associate { index ->
            fields.getJSONObject(index).getString("field_id") to fields.getJSONObject(index)
        }
    }

    @Test fun resetScenarioFixturesMatchCurrentAndroidDivergences() {
        assertEquals(1, fixture.getInt("fixture_version"))
        val scenarios = fixture.getJSONArray("scenarios")
        assertTrue("fixture must not be empty", scenarios.length() > 0)
        val seen = HashSet<String>()
        val evaluated = HashSet<String>()
        val skipped = HashSet<String>()
        for (index in 0 until scenarios.length()) {
            val scenario = scenarios.getJSONObject(index)
            val id = scenario.getString("id")
            assertTrue("duplicate scenario id: $id", seen.add(id))
            val platforms = scenario.optJSONArray("platforms")
            if (platforms != null && (0 until platforms.length()).none { platforms.getString(it) == "android" }) {
                skipped.add(id)
                continue
            }
            evaluated.add(id)
            try { evaluate(id, scenario) } catch (error: Exception) { fail("Scenario $id: $error") }
        }
        assertEquals("every scenario is evaluated or platform-skipped", scenarios.length(), evaluated.size + skipped.size)
        assertEquals("stale knownResetDivergences entries", evaluated, evaluated + knownResetDivergences.keys)
    }

    private fun evaluate(id: String, scenario: JSONObject) {
        val target = scenario.getJSONObject("target")
        val kind = target.getString("kind")
        val rawTarget = kind == "sdr_raw"
        val asShot = target.optJSONArray("as_shot_wb")
        val lensValid = target.getBoolean("lens_valid")
        val looksArray = target.getJSONArray("available_looks")
        val looks = (0 until looksArray.length()).map { looksArray.getString(it) }.toSet()
        val builtins = looks.filter { it.startsWith("builtin:") }
            .associate { it.removePrefix("builtin:") to it.removePrefix("builtin:").substringBeforeLast('.') }
        val context = AdjustmentTransferContext(identifier = "scenario-target", isRaw = rawTarget,
            availableLookIDs = looks, builtinLookIDs = builtins,
            cameraTemperature = if (rawTarget) asShot?.getDouble(0)?.toFloat() else null,
            cameraTint = if (rawTarget) asShot?.getDouble(1)?.toFloat() else null,
            defaultExposureMode = if (rawTarget) 1 else 2,
            validateLens = if (lensValid) ({ _ -> }) else null,
            sourceSupportsCameraHDR = kind == "hdr")
        val base = if (kind == "hdr") EditSettings().withHDRMode(true, true) else EditSettings()
        val seeded = AdjustmentTransfer.prepare(
            AdjustmentPayload.decode(target.getJSONObject("seed_payload").toString()), base,
            context.copy(validateLens = { _ -> }))
        val scope = resetScope(scenario.getJSONObject("scope"))
        val resetContext = EditorResetContext(input = if (rawTarget) PhotoInputKind.RAW else PhotoInputKind.RASTER,
            defaults = EditSettings(),
            asShot = asShot?.let { AsShotWhiteBalance(it.getDouble(0).toFloat(), it.getDouble(1).toFloat()) })
        val expect = scenario.getJSONObject("expect")
        val expectValues = expect.getJSONObject("values")
        val untouched = expect.getJSONArray("untouched")
        val observed = linkedSetOf<AdjustmentField>()
        expectValues.keys().forEach { observed += AdjustmentField.fromID(it) ?: error("Scenario $id: unknown field $it") }
        (0 until untouched.length()).forEach { observed += AdjustmentField.fromID(untouched.getString(it)) ?: error("Scenario $id: unknown untouched field") }
        val diffs = linkedSetOf<String>()
        val before = if (observed.isEmpty()) emptyMap() else
            AdjustmentTransfer.capture(AdjustmentScope.Custom(observed), seeded, context).values
        when (val result = EditorAdjustmentRules.prepareReset(scope, seeded, resetContext)) {
            is EditorResetResult.Ready -> {
                val after = if (observed.isEmpty()) emptyMap() else
                    AdjustmentTransfer.capture(AdjustmentScope.Custom(observed), result.candidate, context).values
                expectValues.keys().asSequence().sorted().forEach { key ->
                    val field = AdjustmentField.fromID(key)!!
                    if (!matchesValue(after[field], expectation(expectValues.get(key), key, kind == "hdr"))) diffs += key
                }
                (0 until untouched.length()).forEach { index ->
                    val field = AdjustmentField.fromID(untouched.getString(index))!!
                    if (!matchesValue(before[field], after[field])) diffs += field.id
                }
                if (expect.getString("status") != "changed") diffs += "status"
            }
            is EditorResetResult.NoChange -> if (expect.getString("status") != "unchanged") diffs += "status"
            is EditorResetResult.Blocked -> if (expect.getString("status") != "blocked") diffs += "status"
        }
        assertEquals("Scenario $id: unregistered reset divergence $diffs",
            knownResetDivergences[id] ?: emptySet<String>(), diffs)
    }

    private fun resetScope(scope: JSONObject): EditorResetScope = when (scope.getString("kind")) {
        "tool" -> EditorResetScope.Tool(when (scope.getString("field")) {
            "light.contrast" -> 5
            "detail.sharpening" -> 10
            else -> error("Unsupported single-reset field for Android tool mapping: ${scope.getString("field")}")
        })
        "group" -> EditorResetScope.Group(when (scope.getString("group")) {
            "light" -> EditorAdjustmentGroup.LIGHT
            "color" -> EditorAdjustmentGroup.COLOR
            "geometry" -> EditorAdjustmentGroup.GEOMETRY
            else -> error("Unsupported reset group: ${scope.getString("group")}")
        })
        "all" -> EditorResetScope.All
        else -> error("Unsupported reset scope kind: ${scope.getString("kind")}")
    }

    private fun expectation(marker: Any, fieldId: String, hdr: Boolean): AdjustmentValue = when (marker) {
        "@spec_default" -> specDefault(fieldId, hdr)
        else -> jsonValue(marker)
    }

    /** @spec_default：本端 spec 行的 model.android.default 按 scale_from_protocol 反映射回协议空间。 */
    private fun specDefault(fieldId: String, hdr: Boolean): AdjustmentValue {
        val model = specFields.getValue(fieldId).getJSONObject("model").getJSONObject("android")
        // Q3 裁定：supported=false 表示本端模型不建模该键（default/min/max 的 null 是「无字段」哨兵，
        // 协议本身非空），捕获按协议占位输出 0 即合规；不得把哨兵误读成期望 null。
        if (!model.optBoolean("supported", true)) return AdjustmentValue.Number(0.0)
        val useHdr = hdr && model.has("hdr_default") && !model.isNull("hdr_default")
        val value = model.get(if (useHdr) "hdr_default" else "default")
        if (value !is Number) return jsonValue(value)
        return when (val scale = model.getString(if (useHdr) "hdr_scale_from_protocol" else "scale_from_protocol")) {
            "p" -> AdjustmentValue.Number(value.toDouble())
            "p * 100" -> AdjustmentValue.Number(value.toDouble() / 100)
            "(p - 1) * 100" -> AdjustmentValue.Number(value.toDouble() / 100 + 1)
            "p - 1" -> AdjustmentValue.Number(value.toDouble() + 1)
            "p / 100" -> AdjustmentValue.Number(value.toDouble() * 100)
            "-p * 100" -> AdjustmentValue.Number(-value.toDouble() / 100)
            "-p" -> AdjustmentValue.Number(-value.toDouble())
            else -> error("Unsupported scale_from_protocol: $scale")
        }
    }

    private fun jsonValue(value: Any): AdjustmentValue = when (value) {
        JSONObject.NULL -> AdjustmentValue.Null
        is Number -> AdjustmentValue.Number(value.toDouble())
        is String -> AdjustmentValue.Text(value)
        is Boolean -> AdjustmentValue.Boolean(value)
        is JSONArray -> AdjustmentValue.Array((0 until value.length()).map { jsonValue(value.get(it)) })
        is JSONObject -> AdjustmentValue.Object(value.keys().asSequence().associateWith { jsonValue(value.get(it)) })
        else -> error("Unsupported spec default: $value")
    }

    private fun matchesValue(actual: AdjustmentValue?, expected: AdjustmentValue?, tolerance: Double = 1e-6): Boolean =
        when {
            actual == null || expected == null -> actual == expected
            expected is AdjustmentValue.Number && actual is AdjustmentValue.Number ->
                kotlin.math.abs(actual.value - expected.value) <= tolerance
            expected is AdjustmentValue.Object && actual is AdjustmentValue.Object ->
                actual.value.keys == expected.value.keys &&
                    expected.value.all { (key, value) -> matchesValue(actual.value[key], value, tolerance) }
            expected is AdjustmentValue.Array && actual is AdjustmentValue.Array ->
                actual.value.size == expected.value.size &&
                    actual.value.zip(expected.value).all { (left, right) -> matchesValue(left, right, tolerance) }
            else -> actual == expected
        }
}
