package com.rawlab.android.presets

import com.rawlab.android.json.validateStrictJSON

internal fun validatePresetJSON(text: String) {
    try { validateStrictJSON(text, setOf("registry_version", "created_at", "updated_at")) }
    catch (_: IllegalArgumentException) { throw AdjustmentPresetException(PresetFailure.CORRUPT_LIBRARY) }
}
