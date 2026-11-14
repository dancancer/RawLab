package com.rawlab.android

import android.app.Application
import com.rawlab.android.i18n.AppStrings

/** 进程入口：在任何界面、ViewModel 或测试运行之前，把界面文字所需的 Application 交给 AppStrings */
class RawLabApplication : Application() {
    @Suppress("DEPRECATION")
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        if(level>=android.content.ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW)
            com.rawlab.android.engine.HDRSourceCache.clearAsync()
    }
    override fun onCreate() {
        super.onCreate()
        // Q6 保留回收：批量产物 30 天/100 条、联机记录 90 天；相机原件只留手动入口。
        // 与 WorkingCopyCleanup 同一进程入口时机，此刻无批量任务与联机会话在跑；
        // 先于它执行，使被回收条目释放的工作副本在同一启动中一并清理。
        com.rawlab.android.photo.RetentionPolicy.reclaimBatchArtifacts(java.io.File(filesDir, "RawLab/BatchJobs"))
        com.rawlab.android.photo.RetentionPolicy.reclaimTetherRecords(java.io.File(filesDir, "camera-tether-runs"))
        com.rawlab.android.photo.WorkingCopyCleanup.atProcessStart(
            cacheDir,
            java.io.File(filesDir, "RawLab/BatchJobs"),
            listOf(cacheDir, filesDir),
        )
        com.rawlab.android.photo.SystemPhotoStore.cleanupTemporary(java.io.File(cacheDir, "system-photo-imports"), java.io.File(filesDir, "system-photos"))
        AppStrings.initialize(this)
    }
}
