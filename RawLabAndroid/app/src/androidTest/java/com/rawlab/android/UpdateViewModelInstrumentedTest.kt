package com.rawlab.android

import android.app.Application
import android.content.Context
import android.os.SystemClock
import androidx.lifecycle.ViewModelStore
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.CompletableDeferred
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.IOException
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class UpdateViewModelInstrumentedTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val application get() = instrumentation.targetContext.applicationContext as Application
    private val payload = """{"tag_name":"v9.0.0","draft":false,"prerelease":false,"body":"Notes","assets":[{"name":"RawLab-Android-9.0.0.apk"}]}"""

    @Test fun manualChecksPersistenceCacheAndFailure() {
        val name = "update-test-${UUID.randomUUID()}"
        val prefs = application.getSharedPreferences(name, Context.MODE_PRIVATE)
        val store = ViewModelStore()
        val calls = AtomicInteger()
        val fail = AtomicBoolean()
        val response = AtomicReference(payload)
        lateinit var model: UpdateViewModel
        try {
            instrumentation.runOnMainSync {
                model = UpdateViewModel(application, {
                    calls.incrementAndGet()
                    if (fail.get()) throw IOException("offline")
                    response.get()
                }, prefs)
                store.put("updates", model)
                model.setAutomatic(false)
                model.check(false)
            }
            assertEquals(0, calls.get())
            assertFalse(prefs.getBoolean("automatic", true))
            instrumentation.runOnMainSync { model.check(true) }
            awaitState(model, UpdateStatus.AVAILABLE)
            assertEquals("9.0.0", model.state.value.available?.version)
            assertEquals(1, calls.get())
            instrumentation.runOnMainSync { model.setAutomatic(true); model.check(false) }
            assertEquals(1, calls.get())
            val restored = UpdateViewModel(application, { payload }, prefs)
            store.put("restored", restored)
            assertEquals("9.0.0", restored.state.value.available?.version)
            fail.set(true)
            instrumentation.runOnMainSync { model.check(true) }
            awaitState(model, UpdateStatus.FAILED)
            assertEquals(2, calls.get())
            assertNotNull(model.state.value.available)
            // 通过公开行为验证，避免仪器测试依赖 Debug/Release 不同的 internal 符号。
            fail.set(false)
            response.set("not JSON")
            instrumentation.runOnMainSync { model.check(true) }
            awaitState(model, UpdateStatus.FAILED)
            assertEquals(3, calls.get())
            assertNotNull(model.state.value.available)
            prefs.edit().putString("cachedRelease", payload.replace("v9.0.0", "v${model.state.value.version}")).commit()
            val upToDate = UpdateViewModel(application, { payload }, prefs)
            store.put("upToDate", upToDate)
            assertNull(upToDate.state.value.available)
        } finally {
            instrumentation.runOnMainSync { store.clear() }
            application.deleteSharedPreferences(name)
        }
    }

    @Test fun concurrentChecksShareOneRequest() {
        val name = "update-test-${UUID.randomUUID()}"
        val prefs = application.getSharedPreferences(name, Context.MODE_PRIVATE)
        val response = CompletableDeferred<String>()
        val calls = AtomicInteger()
        val store = ViewModelStore()
        lateinit var model: UpdateViewModel
        try {
            instrumentation.runOnMainSync {
                model = UpdateViewModel(application, { calls.incrementAndGet(); response.await() }, prefs)
                store.put("updates", model)
                model.check(true)
                model.check(true)
            }
            assertEquals(UpdateStatus.CHECKING, model.state.value.status)
            response.complete(payload)
            awaitState(model, UpdateStatus.AVAILABLE)
            assertEquals(1, calls.get())
        } finally {
            instrumentation.runOnMainSync { store.clear() }
            application.deleteSharedPreferences(name)
        }
    }

    private fun awaitState(model: UpdateViewModel, expected: UpdateStatus) {
        val deadline = SystemClock.elapsedRealtime() + 5000
        while (model.state.value.status != expected && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(20)
        assertEquals(expected, model.state.value.status)
    }
}
