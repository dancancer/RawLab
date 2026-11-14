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
 * V-RESET：Android 消费共享重置场景向量 `reset-scenarios-v1.json`。
 * 种子经 `AdjustmentTransfer.prepare` 写入，重置走生产入口 [EditorAdjustmentRules.prepareReset]，
 * 观察通道复用 [AdjustmentTransfer.capture] 编码后的 wire JSON 载荷；不再在测试层本地解析
 * `@spec_default`，真实现状分歧显式登记进 [knownResetDivergences]。
 */
class ResetScenarioTest {
    private val fixture = JSONObject(resolveSharedFixture("reset-scenarios-v1.json").readText())

    private data class ResetDiff(val key: String, val summary: String)
    private data class ResetDivergence(val ledgerId: String, val fieldReasons: Map<String, String>) {
        val expectedKeys: Set<String> get() = fieldReasons.keys
    }

    /**
     * 棘轮上限按 `(scenario, field)` 计数，只减不增；Android 基线为 0（0 scenario / 0 field divergences），严禁上调。
     * 收口口径（P2-23 / S1）：仅 Mac 存在 4 条 SDR `detail.denoise` null 序列化分歧，Android 已与规范字面量对齐。
     */
    private val maxKnownFieldDivergences = 0

    /** 显式例外清单（逐条精确到 `(scenario, field)`）：未登记的分歧或清单外字段差异必红；已修复仍留档也必红。 */
    private val knownResetDivergences: Map<String, ResetDivergence> = emptyMap()

    @Test fun resetScenarioFixturesMatchCurrentAndroidDivergences() {
        verifyWirePresenceContract()
        knownResetDivergences.forEach { (id, div) ->
            assertTrue("Reset divergence $id: non-blank ledgerId", div.ledgerId.isNotBlank())
            assertTrue("Reset divergence $id: per-field reasons required", div.fieldReasons.isNotEmpty())
            div.fieldReasons.forEach { (field, reason) ->
                assertTrue("Reset divergence $id.$field: non-blank reason", reason.isNotBlank())
            }
        }
        val totalFieldDivergences = knownResetDivergences.values.sumOf { it.fieldReasons.size }
        assertTrue(
            "Reset field divergences ($totalFieldDivergences) must not exceed monotonic ratchet cap ($maxKnownFieldDivergences)",
            totalFieldDivergences <= maxKnownFieldDivergences,
        )
        assertEquals(1, fixture.getInt("fixture_version"))
        val scenarios = fixture.getJSONArray("scenarios")
        assertTrue("fixture must not be empty", scenarios.length() > 0)
        val seen = HashSet<String>()
        val evaluated = HashSet<String>()
        val skipped = HashSet<String>()
        val problems = mutableListOf<String>()
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
            val diffs = try { evaluate(id, scenario) } catch (error: Exception) { fail("Scenario $id: $error"); emptyList() }
            val actualKeys = diffs.map { it.key }.toSet()
            val summary = diffs.joinToString("; ") { it.summary }
            val known = knownResetDivergences[id]
            when {
                diffs.isNotEmpty() && known == null ->
                    problems += "Scenario $id diverged: $summary"
                diffs.isEmpty() && known != null ->
                    problems += "Scenario $id now matches fixture; remove stale divergence (${known.ledgerId})"
                known != null && actualKeys != known.expectedKeys ->
                    problems += "Scenario $id divergence keys changed (expected=${known.expectedKeys.sorted()}, actual=${actualKeys.sorted()}): $summary"
                known != null ->
                    diffs.forEach { diff ->
                        val reason = known.fieldReasons.getValue(diff.key)
                        println("KNOWN DIVERGENCE [$id.${diff.key}] (${known.ledgerId} - $reason): ${diff.summary}")
                    }
            }
        }
        assertEquals("every scenario is evaluated or platform-skipped", scenarios.length(), evaluated.size + skipped.size)
        assertEquals("stale knownResetDivergences entries", evaluated, evaluated + knownResetDivergences.keys)
        if (problems.isNotEmpty()) fail(problems.joinToString("\n"))
        println("PASS: ${evaluated.size} Android reset scenarios evaluated (${skipped.size} platform-scoped skipped, ${knownResetDivergences.size} scenario / $totalFieldDivergences field divergences; ratchet cap $maxKnownFieldDivergences)")
    }

    private fun evaluate(id: String, scenario: JSONObject): List<ResetDiff> {
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
        val diffs = mutableListOf<ResetDiff>()
        val before = if (observed.isEmpty()) emptyMap() else
            wireValues(AdjustmentTransfer.capture(AdjustmentScope.Custom(observed), seeded, context))
        when (val result = EditorAdjustmentRules.prepareReset(scope, seeded, resetContext)) {
            is EditorResetResult.Ready -> {
                val after = if (observed.isEmpty()) emptyMap() else
                    wireValues(AdjustmentTransfer.capture(AdjustmentScope.Custom(observed), result.candidate, context))
                diffs += diffWireValues(before, after, expectValues, (0 until untouched.length()).map { untouched.getString(it) })
                if (expect.getString("status") != "changed") {
                    diffs += ResetDiff("status", "status expected=${expect.getString("status")}, actual=changed")
                }
            }
            is EditorResetResult.NoChange -> if (expect.getString("status") != "unchanged") {
                diffs += ResetDiff("status", "status expected=${expect.getString("status")}, actual=unchanged")
            }
            is EditorResetResult.Blocked -> if (expect.getString("status") != "blocked") {
                diffs += ResetDiff("status", "status expected=${expect.getString("status")}, actual=blocked")
            }
        }
        return diffs
    }

    private fun diffWireValues(
        before: Map<String, AdjustmentValue>,
        after: Map<String, AdjustmentValue>,
        expectValues: JSONObject,
        untouched: List<String>,
    ): List<ResetDiff> {
        val diffs = mutableListOf<ResetDiff>()
        expectValues.keys().asSequence().sorted().forEach { key ->
            val expected = jsonValue(expectValues.get(key))
            val actual = after[key]
            if (!matchesValue(actual, expected)) {
                diffs += ResetDiff(key, "$key expected=${renderValue(expected)}, actual=${renderValue(actual)}")
            }
        }
        untouched.forEach { key ->
            val from = before[key]; val to = after[key]
            if (!matchesValue(from, to)) {
                diffs += ResetDiff(key, "$key untouched ${renderValue(from)} -> ${renderValue(to)}")
            }
        }
        return diffs
    }

    private fun verifyWirePresenceContract() {
        assertFalse("missing key must not equal explicit null", matchesValue(null, AdjustmentValue.Null))
        assertFalse("explicit null must not equal missing key", matchesValue(AdjustmentValue.Null, null))
        assertTrue("explicit null equals explicit null", matchesValue(AdjustmentValue.Null, AdjustmentValue.Null))
        assertTrue("missing equals missing", matchesValue(null, null))
        val diffs = diffWireValues(
            before = mapOf("geometry.lens.profile_id" to AdjustmentValue.Null),
            after = emptyMap(),
            expectValues = JSONObject().put("color.white_balance.temperature_kelvin", JSONObject.NULL),
            untouched = listOf("geometry.lens.profile_id"),
        )
        assertTrue(
            "omitted expect key must fail against explicit null",
            diffs.any { it.key == "color.white_balance.temperature_kelvin" && it.summary.contains("expected=null, actual=<missing>") },
        )
        assertTrue(
            "dropped untouched null key must fail",
            diffs.any { it.key == "geometry.lens.profile_id" && it.summary.contains("null -> <missing>") },
        )
    }

    private fun wireValues(payload: AdjustmentPayload): Map<String, AdjustmentValue> {
        val values = JSONObject(payload.encode()).getJSONObject("values")
        return values.keys().asSequence().associateWith { jsonValue(values.get(it)) }
    }

    private fun renderValue(value: AdjustmentValue?): String = when (value) {
        null -> "<missing>"
        AdjustmentValue.Null -> "null"
        is AdjustmentValue.Number -> value.value.toString()
        is AdjustmentValue.Boolean -> value.value.toString()
        is AdjustmentValue.Text -> JSONObject.quote(value.value)
        is AdjustmentValue.Array -> value.value.joinToString(",", "[", "]") { renderValue(it) }
        is AdjustmentValue.Object -> value.value.entries.sortedBy { it.key }
            .joinToString(",", "{", "}") { "${JSONObject.quote(it.key)}:${renderValue(it.value)}" }
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
            "detail" -> EditorAdjustmentGroup.DETAIL
            "geometry" -> EditorAdjustmentGroup.GEOMETRY
            else -> error("Unsupported reset group: ${scope.getString("group")}")
        })
        "all" -> EditorResetScope.All
        else -> error("Unsupported reset scope kind: ${scope.getString("kind")}")
    }

    private fun jsonValue(value: Any): AdjustmentValue = when (value) {
        JSONObject.NULL -> AdjustmentValue.Null
        is Number -> AdjustmentValue.Number(value.toDouble())
        is String -> AdjustmentValue.Text(value)
        is Boolean -> AdjustmentValue.Boolean(value)
        is JSONArray -> AdjustmentValue.Array((0 until value.length()).map { jsonValue(value.get(it)) })
        is JSONObject -> AdjustmentValue.Object(value.keys().asSequence().associateWith { jsonValue(value.get(it)) })
        else -> error("Unsupported JSON value: $value")
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
