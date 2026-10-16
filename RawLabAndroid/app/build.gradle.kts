import java.security.MessageDigest
import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

val repo = rootDir.parentFile
val rawlabRumLocalProperty = providers.gradleProperty("rawlabRumLocal")
val rawlabRumLocal = rawlabRumLocalProperty.map { value ->
    value.toBooleanStrictOrNull() ?: throw GradleException("rawlabRumLocal must be true or false")
}.orElse(false).get()
val localRumAar = repo.resolve(".cache/shared/aliyun-rum/android/2.3.2/alibabacloud-android-rum-sdk-2.3.2.aar")
val localRumAarSha256 = "681592df6727230a4ff7aef951636afb7d566fbcf486b15b25294b29154c5b1f"

fun java.io.File.sha256(): String = MessageDigest.getInstance("SHA-256").digest(readBytes())
    .joinToString("") { byte -> "%02x".format(byte) }

fun invokesReleaseTask(task: String): Boolean {
    val name = task.substringAfterLast(':')
    return name.equals("assemble", ignoreCase = true) ||
        name.equals("build", ignoreCase = true) ||
        name.contains("release", ignoreCase = true)
}

if (rawlabRumLocal && gradle.startParameter.taskNames.any(::invokesReleaseTask)) {
    throw GradleException("rawlabRumLocal is a Debug-only local validation flag; Release tasks are rejected")
}
if (rawlabRumLocal && (!localRumAar.isFile || localRumAar.sha256() != localRumAarSha256)) {
    throw GradleException("Missing or unexpected Aliyun RUM 2.3.2 AAR at ${localRumAar.path}")
}

val testRaw = providers.gradleProperty("rawlabTestRaw").orElse(providers.environmentVariable("RAWLAB_TEST_RAW"))
val testAssets = layout.buildDirectory.dir("generated/rawlabTestAssets")
val prepareTestAssets by tasks.registering(Sync::class) {
    into(testAssets)
    if (testRaw.isPresent) from(testRaw.get()) { rename { "sample.RAW" } }
}
val generatedAssets = layout.buildDirectory.dir("generated/rawlabAssets")
val prepareAssets by tasks.registering(Sync::class) {
    into(generatedAssets)
    from(repo.resolve("lutools/flog-2-new")) {
        into("films")
        include("*.cube")
        exclude("*FLog2-709*", "*WDR*")
    }
    from(repo.resolve("RawLabMac/Resources/FilmIcons")) { into("artwork"); include("*.png") }
    from(repo.resolve("Shared/master-recipes.json"))
    from(repo.resolve("RawLabMac/Resources/MasterRecipes")) { into("MasterRecipes"); include("*.cube") }
    from(repo.resolve("RawLabMac/Resources/MasterRecipeIcons")) { into("MasterRecipeIcons"); include("*.png") }
    from(repo.resolve("RawLabMac/Resources")) { include("AppIcon.png") }
    from(repo.resolve("lutools/third_party/lensfun/version_1")) { into("Lensfun"); include("*.xml") }
    from(repo.resolve("lutools/third_party/lensfun")) { into("licenses/lensfun"); include("*.txt", "*.md") }
    from(repo.resolve("lutools/third_party/lensfun/dependency-licenses")) { into("licenses/lensfun"); include("*.txt") }
    from(repo.resolve("lutools/third_party")) { into("licenses"); include("*LICENSE*") }
    from(repo.resolve("lutools/third_party/dng-sdk")) {
        into("licenses")
        include("*.txt")
        rename { if (it == "Adobe-DNG-SDK-LICENSE.txt") "Adobe-DNG-SDK-1.7.1-LICENSE.txt" else it }
    }
    from(repo.resolve("RawLabMac/Resources/Licenses")) {
        into("licenses"); include("LibRaw-COPYRIGHT", "LibRaw-LICENSE.*", "stb-MIT-LICENSE.txt")
    }
    from("src/main/notices") { into("licenses") }
    from(repo.resolve("LICENSE")) { into("licenses"); rename { "RawLab-GPL-3.0.txt" } }
    from(repo.resolve("LICENSE-ALIYUN-RUM-EXCEPTION")) { into("licenses"); rename { "RawLab-Aliyun-RUM-Exception.txt" } }
    from(repo.resolve("docs/licensing.md")) { into("licenses"); rename { "RawLab-Licensing.md" } }
    from(androidComponents.sdkComponents.ndkDirectory) {
        include("toolchains/llvm/prebuilt/*/sysroot/NOTICE")
        eachFile { path = "licenses/NDK-libcxx-NOTICE" }
        includeEmptyDirs = false
    }
}
android {
    namespace = "com.rawlab.android"
    compileSdk = 35
    ndkVersion = "27.2.12479018"
    defaultConfig {
        applicationId = "com.rawlab.android"
        minSdk = 26
        targetSdk = 35
        versionCode = 11
        versionName = "0.7.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        externalNativeBuild { cmake { arguments += listOf("-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON", "-DANDROID_STL=c++_shared") } }
    }
    buildFeatures { compose = true }
    if (rawlabRumLocal) {
        sourceSets["main"].java.exclude("**/DefaultUsageAnalyticsRegistry.kt")
        sourceSets["main"].java.exclude("**/DefaultRumLocalConfigurationProvider.kt")
        sourceSets["debug"].java.srcDir("src/local/java")
        sourceSets["debug"].assets.srcDir("src/local/assets")
        sourceSets["debug"].manifest.srcFile("src/local/AndroidManifest.xml")
        sourceSets["androidTest"].java.srcDir("src/localAndroidTest/java")
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    externalNativeBuild { cmake { path = file("src/main/cpp/CMakeLists.txt"); version = "3.22.1" } }
    sourceSets["main"].assets.srcDir(generatedAssets)
    sourceSets["androidTest"].assets.srcDir(testAssets)
    packaging { resources.excludes += "/META-INF/{AL2.0,LGPL2.1}" }
    testOptions { unitTests.isReturnDefaultValues = true }
    if (rawlabRumLocal) buildTypes.getByName("debug").applicationIdSuffix = ".rumlocal"
}

if (rawlabRumLocal) {
    tasks.withType<KotlinCompile>().configureEach {
        if (name == "compileDebugKotlin") {
            exclude("**/DefaultUsageAnalyticsRegistry.kt")
            exclude("**/DefaultRumLocalConfigurationProvider.kt")
        }
    }
}

tasks.named("preBuild").configure { dependsOn(prepareAssets) }
tasks.matching {
    it.name.endsWith("AndroidTestAssets") || it.name.endsWith("AndroidTestLintModel") ||
        (it.name.startsWith("lintAnalyze") && it.name.endsWith("AndroidTest"))
}.configureEach { dependsOn(prepareTestAssets) }

dependencies {
    if (rawlabRumLocal) add("debugImplementation", files(localRumAar))
    implementation(platform("androidx.compose:compose-bom:2025.04.01"))
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.exifinterface:exifinterface:1.4.2")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.0")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    debugImplementation("androidx.compose.ui:ui-tooling")
    // Keep ActivityScenario helpers in the debug app instead of launching another package.
    debugImplementation("androidx.test:core:1.6.1")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation(platform("androidx.compose:compose-bom:2025.04.01"))
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
