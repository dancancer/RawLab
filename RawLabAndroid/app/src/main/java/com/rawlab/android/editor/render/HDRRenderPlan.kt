package com.rawlab.android.editor.render

import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.HDRCameraDevelopmentSettings
import com.rawlab.android.settings.HDRMode
import com.rawlab.android.settings.HDRSettings

internal data class HDRReferenceKey<Stamp : Any>(
    val source: Stamp,
    val photo: ImportedPhoto,
    val settings: HDRSettings,
    val edge: Int,
    val decodeVersion: Int?,
    val cameraProcessingVersion: Int,
)

internal data class HDRRenderPlan<Stamp : Any>(
    val resultSettings: HDRSettings,
    val neutralSettings: HDRSettings,
    val neutralCameraSettings: HDRCameraDevelopmentSettings,
    val resultCameraSettings: HDRCameraDevelopmentSettings,
    val referenceKey: HDRReferenceKey<Stamp>?,
)

internal fun <Stamp : Any> buildHDRRenderPlan(
    stamp: Stamp?,
    photo: ImportedPhoto,
    edits: EditSettings,
    geometry: GeometrySettings,
    edge: Int,
    cameraProcessingVersion: Int,
): HDRRenderPlan<Stamp> {
    val resultSettings = (edits.hdr ?: HDRSettings(mode = HDRMode.SDR)).copy(geometry = geometry)
    val neutralSettings = resultSettings.neutralGeometrySettings
    val referenceKey = stamp?.let {
        HDRReferenceKey(it, photo, neutralSettings, edge, edits.proRAWDecodeVersion, cameraProcessingVersion)
    }
    return HDRRenderPlan(
        resultSettings = resultSettings,
        neutralSettings = neutralSettings,
        neutralCameraSettings = neutralSettings.cameraSettings,
        resultCameraSettings = resultSettings.cameraSettings,
        referenceKey = referenceKey,
    )
}

internal class HDRReferenceCoordinator<Stamp : Any, Ref> {
    private var cached: Pair<HDRReferenceKey<Stamp>, Ref>? = null

    fun clear() {
        cached = null
    }

    inline fun resolveReference(
        plan: HDRRenderPlan<Stamp>,
        render: (HDRCameraDevelopmentSettings, HDRSettings) -> Ref,
    ): Ref {
        val key = plan.referenceKey
        if (key != null) {
            cached?.takeIf { it.first == key }?.let { return it.second }
        }
        return render(plan.neutralCameraSettings, plan.neutralSettings).also { created ->
            cached = key?.let { it to created }
        }
    }
}
