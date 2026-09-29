plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

val repo = rootDir.parentFile
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
    from(repo.resolve("RawLabMac/Resources")) { include("AppIcon.png") }
    from(repo.resolve("lutools/third_party")) { into("licenses"); include("*LICENSE*") }
    from(repo.resolve("RawLabMac/Resources/Licenses")) {
        into("licenses"); include("LibRaw-COPYRIGHT", "LibRaw-LICENSE.*", "stb-MIT-LICENSE.txt")
    }
    from("src/main/notices") { into("licenses") }
    from(androidComponents.sdkComponents.ndkDirectory) {
        include("toolchains/llvm/prebuilt/*/sysroot/NOTICE")
        eachFile { path = "licenses/NDK-libcxx-NOTICE" }
        includeEmptyDirs = false
    }
}
val generatedResources = layout.buildDirectory.dir("generated/rawlabResources")
val prepareIcon by tasks.registering(Sync::class) {
    into(generatedResources)
    from(repo.resolve("RawLabMac/Resources/AppIcon.png")) {
        into("drawable-nodpi")
        rename { "rawlab_icon.png" }
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
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        externalNativeBuild { cmake { arguments += listOf("-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON", "-DANDROID_STL=c++_shared") } }
    }
    buildFeatures { compose = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    externalNativeBuild { cmake { path = file("src/main/cpp/CMakeLists.txt"); version = "3.22.1" } }
    sourceSets["main"].assets.srcDir(generatedAssets)
    sourceSets["main"].res.srcDir(generatedResources)
    sourceSets["androidTest"].assets.srcDir(testAssets)
    packaging { resources.excludes += "/META-INF/{AL2.0,LGPL2.1}" }
    testOptions { unitTests.isReturnDefaultValues = true }
}

tasks.named("preBuild").configure { dependsOn(prepareAssets, prepareIcon) }
tasks.matching {
    it.name.endsWith("AndroidTestAssets") || it.name.endsWith("AndroidTestLintModel") ||
        (it.name.startsWith("lintAnalyze") && it.name.endsWith("AndroidTest"))
}.configureEach { dependsOn(prepareTestAssets) }

dependencies {
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
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation(platform("androidx.compose:compose-bom:2025.04.01"))
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
