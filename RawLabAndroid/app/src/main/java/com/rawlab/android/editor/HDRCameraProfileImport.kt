package com.rawlab.android.editor

import com.rawlab.android.settings.HDRCameraProfile
import com.rawlab.android.settings.EditPersistenceConflict
import com.rawlab.android.settings.HDRCameraDevelopmentSettings
import com.rawlab.android.settings.PhotoIdentity
import kotlinx.coroutines.CancellationException

// 草稿随 ViewModel 保留，文件选择器期间重建界面也不会丢失导入结果。
data class HDRCameraPanelDraft(val source: PhotoIdentity, val baseline: HDRCameraDevelopmentSettings,
    val settings: HDRCameraDevelopmentSettings) {
    fun valueFor(source: PhotoIdentity, committed: HDRCameraDevelopmentSettings) =
        if (this.source == source && baseline == committed) settings else committed
    fun withProfile(profile: HDRCameraProfile) = copy(settings = settings.copy(cameraProfile = profile))
    fun retainedFor(committed: HDRCameraDevelopmentSettings?) = takeIf { baseline == committed }
}

internal suspend fun readHDRCameraProfile(load: suspend () -> HDRCameraProfile,
    isCurrent: () -> Boolean): Result<HDRCameraProfile> = try {
    val profile = load()
    if (!isCurrent()) throw EditPersistenceConflict()
    Result.success(profile)
} catch (error: CancellationException) {
    throw error
} catch (error: Exception) {
    Result.failure(error)
}
