// 发布包 Java/Kotlin 依赖的声明清单：构建时从 release 运行时依赖解析结果生成，不在仓库里保存副本。
// 许可只取依赖自己的 Maven POM（自身没有就沿 parent POM 继承）。不在下方允许清单里的许可、或无法确定许可的
// 依赖都会让构建失败：新增或升级依赖若带来新的许可，必须在这里显式审核后添加。
import groovy.xml.XmlSlurper
import groovy.xml.slurpersupport.GPathResult
import org.gradle.api.artifacts.component.ModuleComponentIdentifier

// POM 里的许可名称 -> SPDX 标识。只收录已审核、许可原文已随应用打包的许可。
val allowedLicenseNames = mapOf(
    "The Apache Software License, Version 2.0" to "Apache-2.0",
    "The Apache License, Version 2.0" to "Apache-2.0",
    "Apache License, Version 2.0" to "Apache-2.0",
    "Apache-2.0" to "Apache-2.0",
    "Apache 2.0" to "Apache-2.0",
)
// 通用许可的原文位置（assets/licenses 下）。
val licenseTextFiles = mapOf("Apache-2.0" to "OpenCV-LICENSE.txt")
// 个别依赖的许可组合不通用，逐个审核：坐标 -> (POM 许可名称集合, 清单里的许可说明)。
val reviewedLicenseCombinations = mapOf(
    "com.github.mwiede:jsch" to (setOf("Revised BSD", "ISC") to
        "BSD-3-Clause AND ISC (JSch with bundled JZlib and jBCrypt; license text: jsch-LICENSE.txt)"),
    "androidx.camera:camera-core" to (setOf("The Apache Software License, Version 2.0", "BSD License") to
        "Apache-2.0 AND BSD-3-Clause (AndroidX CameraX with bundled libyuv; license texts: OpenCV-LICENSE.txt, libyuv-LICENSE.txt)"),
)

data class PomInfo(val licenses: List<String>, val parent: String?)

fun readPom(file: File): PomInfo {
    val root = XmlSlurper(false, false).parse(file)
    fun child(node: GPathResult, name: String) = node.getProperty(name) as GPathResult
    val licenses = child(child(root, "licenses"), "license").let { list ->
        (0 until list.size()).map { index -> child(list.getAt(index) as GPathResult, "name").text().trim() }
    }.filter { it.isNotEmpty() }
    val parent = child(root, "parent").takeIf { it.size() > 0 }?.let {
        "${child(it, "groupId").text().trim()}:${child(it, "artifactId").text().trim()}:${child(it, "version").text().trim()}"
    }
    return PomInfo(licenses, parent)
}

// AGP 在配置后期才创建变体配置；只在任务执行前解析（不在配置阶段访问网络），Gradle 缓存命中后可离线运行。
val releaseModules = provider {
    configurations.getByName("releaseRuntimeClasspath").incoming.resolutionResult.allComponents
        // BOM 只以 platform 身份参与版本对齐，不带代码进 APK；Kotlin 多平台根模块按库列出。
        .filterNot { component ->
            component.variants.isNotEmpty() && component.variants.all { variant ->
                val category = variant.attributes.keySet().firstOrNull { it.name == "org.gradle.category" }
                variant.attributes.getAttribute(category ?: return@all false).toString() in setOf("platform", "enforced-platform")
            }
        }
        .mapNotNull { it.id as? ModuleComponentIdentifier }
        .sortedWith(compareBy({ it.group }, { it.module }))
        .map { "${it.group}:${it.module}:${it.version}" }
        .distinct()
}

// 用普通依赖解析取 POM 文件本身（artifact-only 记法 `@pom`，不传递），与运行时依赖走同一套仓库和缓存；
// 任何一个取不到都按 Gradle 的解析错误失败，不会悄悄漏掉某个库。
fun resolvePoms(coordinates: Collection<String>): Map<String, File> {
    if (coordinates.isEmpty()) return emptyMap()
    val configuration = configurations.detachedConfiguration(
        *coordinates.map { dependencies.create("$it@pom") }.toTypedArray(),
    ).apply { isTransitive = false }
    val poms = configuration.incoming.artifacts.artifacts.associate { artifact ->
        val id = artifact.id.componentIdentifier as ModuleComponentIdentifier
        "${id.group}:${id.module}:${id.version}" to artifact.file
    }
    val missing = coordinates.filterNot(poms::containsKey)
    if (missing.isNotEmpty()) throw GradleException("No Maven POM resolved for: ${missing.joinToString()}")
    return poms
}

val generateLibraryNotices by tasks.registering {
    description = "Lists the release APK's Java/Kotlin libraries with versions and POM licences."
    // 输出目录交给 AGP 的变体 API 挂到 assets 源（build.gradle.kts），由它决定位置并把任务依赖传给
    // 合并 assets 的任务。
    val outputDirectory = objects.directoryProperty().convention(layout.buildDirectory.dir("generated/libraryNotices"))
    extensions.add("outputDirectory", outputDirectory)
    inputs.property("modules", releaseModules)
    inputs.property("allowedLicenseNames", allowedLicenseNames)
    inputs.property("licenseTextFiles", licenseTextFiles)
    inputs.property("reviewedLicenseCombinations",
        reviewedLicenseCombinations.mapValues { (_, value) -> value.first.sorted() + value.second })
    outputs.dir(outputDirectory)
    doLast {
        val modules = releaseModules.get()
        val poms = mutableMapOf<String, PomInfo>()
        // 按层批量解析：先是所有库，再是自身没有声明许可的那些 POM 的 parent。
        var pending = modules.toSet()
        var depth = 0
        while (pending.isNotEmpty() && depth++ < 8) {
            resolvePoms(pending - poms.keys).forEach { (coordinate, file) -> poms[coordinate] = readPom(file) }
            pending = pending.mapNotNull { poms.getValue(it).takeIf { info -> info.licenses.isEmpty() }?.parent }.toSet()
        }
        fun licensesOf(coordinate: String): List<String> {
            var info = poms.getValue(coordinate)
            while (info.licenses.isEmpty()) info = poms[info.parent ?: break] ?: break
            return info.licenses
        }
        val groups = sortedMapOf<String, MutableList<String>>()
        val problems = mutableListOf<String>()
        for (coordinate in modules) {
            val (group, module, version) = coordinate.split(":")
            val names = licensesOf(coordinate)
            val review = reviewedLicenseCombinations["$group:$module"]
            val heading = when {
                review != null && names.toSet() == review.first -> review.second
                names.isEmpty() -> { problems += "$coordinate: no license in its POM or parent POMs"; continue }
                names.all { it in allowedLicenseNames } -> names.map { allowedLicenseNames.getValue(it) }.distinct()
                    .joinToString(" AND ")
                    .let { spdx -> "$spdx (license text: ${spdx.split(" AND ").joinToString { licenseTextFiles.getValue(it) }})" }
                else -> { problems += "$coordinate: license not on the reviewed list: ${names.joinToString(" | ")}"; continue }
            }
            groups.getOrPut(heading) { mutableListOf() } += "- $group:$module $version"
        }
        if (problems.isNotEmpty()) {
            throw GradleException(
                "Release libraries with unreviewed licenses (edit RawLabAndroid/app/library-notices.gradle.kts " +
                    "after checking the license and packaging its text):\n" + problems.joinToString("\n"),
            )
        }
        val text = buildString {
            appendLine("Java and Kotlin libraries in the release APK")
            appendLine("Generated at build time from the release runtime classpath. Versions are the resolved ones;")
            appendLine("licenses are taken from each library's Maven POM, or its parent POM when it declares none.")
            for ((heading, lines) in groups) {
                appendLine()
                appendLine(heading)
                lines.forEach(::appendLine)
            }
        }
        outputDirectory.get().file("licenses/ThirdPartyLibraries.txt").asFile
            .apply { parentFile.mkdirs() }.writeText(text)
    }
}
