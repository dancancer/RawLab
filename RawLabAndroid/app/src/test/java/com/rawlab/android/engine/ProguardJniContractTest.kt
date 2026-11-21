package com.rawlab.android.engine

import org.junit.Assert.*
import org.junit.Test
import java.io.File

class ProguardJniContractTest {
    private fun moduleRoot(): File {
        val candidates = listOf(
            File("."),
            File("app"),
            File("RawLabAndroid/app"),
        )
        return candidates.first { File(it, "build.gradle.kts").isFile && File(it, "src/main/cpp/rawlab_jni.cpp").isFile }
    }

    @Test
    fun releaseBuildEnablesR8AndDropsMaterialIconsExtended() {
        val root = moduleRoot()
        val gradle = File(root, "build.gradle.kts").readText()
        assertTrue("Release buildType must enable R8 minification", gradle.contains("isMinifyEnabled = true"))
        assertTrue("Release buildType must enable resource shrinking", gradle.contains("isShrinkResources = true"))
        assertTrue("Release buildType must reference proguard-rules.pro", gradle.contains("\"proguard-rules.pro\""))
        assertFalse("material-icons-extended must be replaced with material-icons-core", gradle.contains("material-icons-extended"))
        assertTrue("material-icons-core must be declared", gradle.contains("material-icons-core"))
    }

    @Test
    fun proguardRulesCoverEveryInitJniCacheClassAndNativeBridge() {
        val root = moduleRoot()
        val cpp = File(root, "src/main/cpp/rawlab_jni.cpp").readText()
        val proguard = File(root, "proguard-rules.pro").readText()

        val classPattern = Regex("""cacheGlobalClass\s*\(\s*env\s*,\s*"([^"]+)"\s*\)""")
        val jniClasses = classPattern.findAll(cpp)
            .map { it.groupValues[1].replace('/', '.') }
            .filter { it.startsWith("com.rawlab.android.") }
            .toSet()

        assertTrue("Expected at least 22 app classes in initJniCache", jniClasses.size >= 22)
        for (cls in jniClasses) {
            assertTrue(
                "proguard-rules.pro must explicitly keep JNI-reflected class $cls",
                proguard.contains("-keep class $cls"),
            )
        }

        // Verify NativeFrame keeps both ctor and allocateBitmap
        val nativeFrameBlock: String = Regex("""-keep\s+class\s+com\.rawlab\.android\.engine\.NativeFrame\s*\{([^}]*)\}""")
            .find(proguard)?.groupValues?.get(1)
            ?: error("Missing NativeFrame keep block in proguard-rules.pro")
        assertTrue(nativeFrameBlock.contains("allocateBitmap"))
        assertTrue(nativeFrameBlock.contains("android.graphics.Bitmap"))

        // Verify external fun host classes are preserved
        assertTrue(proguard.contains("native <methods>;"))
        for (host in listOf(
            "com.rawlab.android.engine.NativeProcessor",
            "com.rawlab.android.engine.NativeLookBridge",
            "com.rawlab.android.engine.NativeDcpBridge",
            "com.rawlab.android.engine.NativeHDRBridge",
            "com.rawlab.android.engine.ToneCurveSampling",
            "com.rawlab.android.raster.NativeMpf",
            "com.rawlab.android.raster.NativePng16",
        )) {
            assertTrue("proguard-rules.pro must keep native host $host", proguard.contains(host))
        }
    }
}
