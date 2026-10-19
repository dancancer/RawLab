import com.android.build.api.dsl.AndroidSourceSet
import com.android.build.api.dsl.VariantDimension
import java.security.MessageDigest
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

val repo = rootDir.parentFile
fun flag(name: String, default: Boolean): Boolean = providers.gradleProperty(name).map { value ->
    value.toBooleanStrictOrNull() ?: throw GradleException("$name must be true or false")
}.orElse(default).get()

// ============================================================================
//  使用统计 SDK 的去留
//  正式包默认携带阿里云 RUM SDK（env=PROD）；离线打包才显式 -PrawlabRumRelease=false。
//  Debug 默认不带 SDK；-PrawlabRumLocal=true 是本地验证路径：Debug 带 SDK、env=LOCAL、
//  独立包名与同意存储、默认不开启（只由探针或手动开关发送）。两个开关互不影响。
// ============================================================================
val rawlabRumLocal = flag("rawlabRumLocal", false)
val rawlabRumRelease = flag("rawlabRumRelease", true)

// 版本与 SHA-256 只写在 scripts/rum-sdk.env（下载脚本同读）；AAR 不进 Git，放主工作区共享缓存，
// 位置由仓库的 scripts/rum/shared-cache.sh 决定（worktree 里也指向主工作区）
val rumSdkPin = Properties().apply { rootDir.resolve("scripts/rum-sdk.env").reader().use(::load) }
val rumSdkVersion: String = rumSdkPin.getProperty("RUM_ANDROID_VERSION")
val rumSdkSha256: String = rumSdkPin.getProperty("RUM_ANDROID_SHA256")
val rumCacheRoot = providers.exec {
    commandLine("bash", "-c", "source \"\$0\" && printf %s \"\$RUM_CACHE_ROOT\"", repo.resolve("scripts/rum/shared-cache.sh").path)
}.standardOutput.asText

fun File.sha256(): String = MessageDigest.getInstance("SHA-256").digest(readBytes())
    .joinToString("") { byte -> "%02x".format(byte) }

// 只在真正需要 SDK 的变体解析依赖时才检查，Debug/CI 不受影响；缺失或不符即失败，不悄悄出没统计的包
val verifiedRumSdk = provider {
    val aar = File(rumCacheRoot.get(), "android/$rumSdkVersion/alibabacloud-android-rum-sdk-$rumSdkVersion.aar")
    val fetch = "Fetch it with `bash scripts/fetch-rum-sdk.sh`, or build an offline release with -PrawlabRumRelease=false."
    if (!aar.isFile) throw GradleException("Aliyun RUM Android SDK $rumSdkVersion is missing at $aar. $fetch")
    if (aar.sha256() != rumSdkSha256) throw GradleException("Unexpected SHA-256 for $aar. Delete it. $fetch")
    aar
}

// 统计的构建差异只有两处：BuildConfig 里的存储/环境/默认值，和 UsageTransportFactory 的来源目录
fun VariantDimension.usageProfile(preferences: String, environment: String, defaultEnabled: Boolean) {
    buildConfigField("String", "USAGE_PREFERENCES", "\"$preferences\"")
    buildConfigField("String", "RUM_ENVIRONMENT", "\"$environment\"")
    buildConfigField("boolean", "USAGE_DEFAULT_ENABLED", "$defaultEnabled")
}
fun AndroidSourceSet.usageTransport(withSdk: Boolean) {
    val root = if (withSdk) "src/rum" else "src/nosdk"
    java.srcDir("$root/java")
    assets.srcDir("$root/assets")
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
    from(repo.resolve("Shared/BundledLooks")) { into("films"); include("*.cube") }
    from(repo.resolve("Shared/BundledLooks/catalog.json")) { rename { "bundled-looks.json" } }
    from(repo.resolve("Shared/BundledLooks/Artwork")) { into("artwork"); include("*.png") }
    from(repo.resolve("Shared/BundledLooks/NOTICE.md")) { into("licenses"); rename { "Bundled-Looks.md" } }
    from(repo.resolve("Shared/master-recipes.json"))
    from(repo.resolve("RawLabMac/Resources/MasterRecipes")) { into("MasterRecipes"); include("*.cube") }
    from(repo.resolve("RawLabMac/Resources/MasterRecipeIcons")) { into("MasterRecipeIcons"); include("*.png") }
    from(repo.resolve("RawLabMac/Resources")) { include("AppIcon.png") }
    from(repo.resolve("lutools/third_party/lensfun/version_1")) { into("Lensfun"); include("*.xml") }
    from(repo.resolve("lutools/third_party/lensfun")) { into("licenses/lensfun"); include("*.txt", "*.md") }
    from(repo.resolve("lutools/third_party/lensfun/dependency-licenses")) { into("licenses/lensfun"); include("*.txt") }
    from(repo.resolve("lutools/third_party")) { into("licenses"); include("*LICENSE*") }
    from(repo.resolve("lutools/third_party/nlohmann/LICENSE.MIT")) {
        into("licenses"); rename { "nlohmann-JSON-MIT.txt" }
    }
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
    from(repo.resolve("docs/reference/licensing.md")) { into("licenses"); rename { "RawLab-Licensing.md" } }
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
        versionCode = 13
        versionName = "0.8.1"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        externalNativeBuild { cmake { arguments += listOf("-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON", "-DANDROID_STL=c++_shared") } }
        usageProfile(preferences = "usage_analytics", environment = "PROD", defaultEnabled = true)
    }
    buildFeatures { compose = true; buildConfig = true }
    if (rawlabRumLocal) buildTypes.getByName("debug") {
        applicationIdSuffix = ".rumlocal"
        usageProfile(preferences = "usage_analytics_rumlocal", environment = "LOCAL", defaultEnabled = false)
    }
    sourceSets["debug"].usageTransport(withSdk = rawlabRumLocal)
    sourceSets["release"].usageTransport(withSdk = rawlabRumRelease)
    // 实网验证探针要直接调用 SDK 适配层，只随本地验证构建编译
    if (rawlabRumLocal) sourceSets["androidTest"].java.srcDir("src/localAndroidTest/java")
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    externalNativeBuild { cmake { path = file("src/main/cpp/CMakeLists.txt"); version = "3.22.1" } }
    sourceSets["main"].assets.srcDir(generatedAssets)
    sourceSets["androidTest"].assets.srcDir(testAssets)
    packaging { resources.excludes += "/META-INF/{AL2.0,LGPL2.1}" }
    // SDK 的 webview-sdk.js 只在给 WebView 注入 H5 采集时读取（2.3.2 字节码核实）；本应用没有 WebView，
    // h5 采集也已关闭，不打包。前半段是 aapt 的默认忽略规则，原样保留
    androidResources { ignoreAssetsPattern = "!.svn:!.git:!.ds_store:!*.scc:.*:<dir>_*:!CVS:!thumbs.db:!picasa.ini:!*~:!webview-sdk.js" }
    testOptions { unitTests.isReturnDefaultValues = true }
}

tasks.named("preBuild").configure { dependsOn(prepareAssets) }
tasks.matching {
    it.name.endsWith("AndroidTestAssets") || it.name.endsWith("AndroidTestLintModel") ||
        (it.name.startsWith("lintAnalyze") && it.name.endsWith("AndroidTest"))
}.configureEach { dependsOn(prepareTestAssets) }

dependencies {
    if (rawlabRumLocal) add("debugImplementation", files(verifiedRumSdk))
    if (rawlabRumRelease) add("releaseImplementation", files(verifiedRumSdk))
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
