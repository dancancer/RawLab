package com.rawlab.android

import android.app.Application
import android.os.Process
import com.rawlab.android.i18n.AppStrings
import java.io.File
import java.util.concurrent.Executor

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
        AppStrings.initialize(this)
        scheduleStartupCleanup(filesDir, cacheDir)
    }
}

internal fun runStartupCleanup(filesDir: File, cacheDir: File) {
    // Q6 保留回收：批量产物 30 天/100 条、联机记录 90 天；相机原件只留手动入口。
    // 先于 WorkingCopyCleanup 执行，使被回收条目释放的工作副本在同一启动中一并清理。
    com.rawlab.android.photo.RetentionPolicy.reclaimBatchArtifacts(File(filesDir, "RawLab/BatchJobs"))
    com.rawlab.android.photo.RetentionPolicy.reclaimTetherRecords(File(filesDir, "camera-tether-runs"))
    com.rawlab.android.photo.WorkingCopyCleanup.atProcessStart(
        cacheDir,
        File(filesDir, "RawLab/BatchJobs"),
        listOf(cacheDir, filesDir),
    )
    com.rawlab.android.photo.SystemPhotoStore.cleanupTemporary(File(cacheDir, "system-photo-imports"), File(filesDir, "system-photos"))
}

internal fun scheduleStartupCleanup(
    filesDir: File,
    cacheDir: File,
    executor: Executor = Executor { task ->
        Thread({
            Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
            task.run()
        }, "rawlab-startup-cleanup").start()
    },
) {
    executor.execute { runStartupCleanup(filesDir, cacheDir) }
}
