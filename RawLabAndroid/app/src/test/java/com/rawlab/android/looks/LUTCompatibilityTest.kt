package com.rawlab.android.looks

import org.junit.Assert.*
import org.junit.Test
import org.json.JSONObject

class LUTCompatibilityTest {
    private val info = """{"eligible":true,"source_sha256":"abc","fixed_contract":false,"photo_style":"std","extreme_values":false,"hints":[],"contract":{"version":1,"input":{"space":"","reference":"display","range":"full"},"output":{"space":"","reference":"display","range":"full"},"interpolation":"linear","base_rendering":"rawlab-neutral-v1"}}"""
    @Test fun confirmationRequiresCompleteColorsAndPreservesSourceIdentity() {
        val draft = LUTCompatibility.parse(info)!!
        assertFalse(draft.canImport)
        val chosen = draft.withInput("srgb").withOutput("rec709-gamma24")
        assertTrue(chosen.canImport)
        val request = JSONObject(chosen.request())
        assertEquals("abc", request.getString("source_sha256"))
        assertTrue(request.getBoolean("confirmed"))
        assertFalse(request.getJSONObject("contract").has("evidence"))
        assertEquals("rawlab-neutral-v1", request.getJSONObject("contract").getString("base_rendering"))
        assertFalse(chosen.withInput("vlog-vgamut").canImport)
    }
    @Test fun extremeValuesNeedSeparateAcknowledgement() {
        val draft = LUTCompatibility.parse(info)!!.withInput("srgb").withOutput("srgb").copy(extremeValues = true)
        assertFalse(draft.canImport)
        assertTrue(draft.copy(confirmedExtremeValues = true).canImport)
    }
    @Test fun unavailableCompatibilityDoesNotCreateADraft() {
        assertNull(LUTCompatibility.parse("""{"eligible":false}"""))
    }
    @Test fun candidatesRemainUnselectedAndAdaptToDisplayPhotos() {
        val supplied = JSONObject(info)
        val configured = LUTCompatibility.parse(info)!!.withInput("srgb").withOutput("srgb")
        val candidate = JSONObject().put("id", "candidate-1").put("basis", "assumed")
            .put("assumptions", org.json.JSONArray(listOf("input-space", "output-space")))
            .put("contract", JSONObject(configured.previewRequest()).getJSONObject("contract"))
        supplied.put("candidates", org.json.JSONArray().put(candidate))
        val draft = LUTCompatibility.parse(supplied.toString())!!
        assertFalse(draft.canImport)
        assertEquals(1, draft.candidates.size)
        val display = draft.applying(draft.candidates.single(), displayInput = true)!!
        assertEquals("source-display", display.base)
        assertFalse(JSONObject(display.previewRequest()).has("confirmed"))
        assertFalse(draft.withInput("vlog-vgamut").supportsPreview(true))
    }
    @Test fun referenceMetricsRequireAllConditionsAndProvenance() {
        assertFalse(LUTReferenceConditions().canCompare)
        assertFalse(LUTReferenceConditions(true, true, true, true, " ").canCompare)
        val confirmed = LUTReferenceConditions(true, true, true, true, "Same image, independent renderer, sRGB")
        assertTrue(confirmed.canCompare)
        assertFalse(confirmed.copy(sameSource = false).canCompare)
        assertEquals("Same image, independent renderer, sRGB", JSONObject(confirmed.json()).getString("reference_source"))
    }
}
