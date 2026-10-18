package com.rawlab.android.testing

import android.app.Activity
import android.app.Application
import android.app.KeyguardManager
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.view.WindowManager
import androidx.test.platform.app.InstrumentationRegistry
import java.util.IdentityHashMap
import org.junit.rules.ExternalResource

/** 保持本次测试窗口前台可见，不修改设备全局的息屏或锁屏设置。 */
class ForegroundTestRule : ExternalResource() {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val application get() = context.applicationContext as Application
    private val flags = IdentityHashMap<Activity, Int>()
    private val keepOn = WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
    private val callbacks = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityCreated(activity: Activity, state: Bundle?) {
            flags[activity] = activity.window.attributes.flags
            activity.window.addFlags(keepOn)
        }
        override fun onActivityDestroyed(activity: Activity) { flags.remove(activity) }
        override fun onActivityStarted(activity: Activity) {}
        override fun onActivityResumed(activity: Activity) {}
        override fun onActivityPaused(activity: Activity) {}
        override fun onActivityStopped(activity: Activity) {}
        override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) {}
    }

    override fun before() {
        val keyguard = context.getSystemService(KeyguardManager::class.java)
        val commands = listOf("input keyevent KEYCODE_WAKEUP") + if (keyguard.isKeyguardSecure) emptyList() else listOf("wm dismiss-keyguard")
        for (command in commands) {
            ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(command)).use { it.readBytes() }
        }
        check(context.getSystemService(PowerManager::class.java).isInteractive) { "Device must be awake for UI verification" }
        check(!keyguard.isKeyguardLocked) { "Unlock the device before UI verification" }
        instrumentation.runOnMainSync { application.registerActivityLifecycleCallbacks(callbacks) }
    }

    override fun after() {
        instrumentation.runOnMainSync {
            application.unregisterActivityLifecycleCallbacks(callbacks)
            flags.forEach { (activity, previous) -> if (previous and keepOn == 0) activity.window.clearFlags(keepOn) }
            flags.clear()
        }
    }
}
