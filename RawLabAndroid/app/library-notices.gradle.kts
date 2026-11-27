// 发布包 Java/Kotlin 依赖的声明清单：构建时从 release 运行时依赖解析结果生成，不在仓库里保存副本。
// 许可只取依赖自己的 Maven POM（自身没有就沿 parent POM 继承）。不在下方允许清单里的许可、或无法确定许可的
// 依赖都会让构建失败：新增或升级依赖若带来新的许可，必须在这里显式审核后添加。
import groovy.xml.XmlSlurper
import groovy.xml.slurpersupport.GPathResult
import org.gradle.api.artifacts.component.ModuleComponentIdentifier
import org.gradle.api.artifacts.result.ResolvedArtifactResult
import org.gradle.maven.MavenModule
import org.gradle.maven.MavenPomArtifact

// POM 里的许可名称 -> SPDX 标识。只收录已审核、许可原文已随应用打包的许可。
val allowedPomLicenses = mapOf(
    "The Apache Software License, Version 2.0" to "Apache-2.0",
    "The Apache License, Version 2.0" to "Apache-2.0",
    "Apache License, Version 2.0" to "Apache-2.0",
    "Apache-2.0" to "Apache-2.0",
)
// 通用许可的原文位置（assets/licenses 下）。
val licenseTexts = mapOf("Apache-2.0" to "OpenCV-LICENSE.txt")
// 个别依赖的许可组合不通用，逐个审核：坐标 -> (POM 许可名称集合, 清单里的许可说明)。
val reviewedModules = mapOf(
    "com.github.mwiede:jsch" to (setOf("Revised BSD", "ISC") to
        "BSD-3-Clause AND ISC (JSch with bundled JZlib and jBCrypt; license text: jsch-LICENSE.txt)"),
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

fun pomFile(coordinate: String): File {
    val (group, module, version) = coordinate.split(":")
    val result = dependencies.createArtifactResolutionQuery()
        .forModule(group, module, version)
        .withArtifacts(MavenModule::class.java, MavenPomArtifact::class.java)
        .execute()
    return result.resolvedComponents.flatMap { it.getArtifacts(MavenPomArtifact::class.java) }
        .filterIsInstance<ResolvedArtifactResult>().singleOrNull()?.file
        ?: throw GradleException("Cannot resolve the Maven POM of $coordinate for the library notices")
}

val generateLibraryNotices by tasks.registering {
    description = "Lists the release APK's Java/Kotlin libraries with versions and POM licences."
    val output = layout.buildDirectory.file("generated/libraryNotices/ThirdPartyLibraries.txt")
    inputs.property("modules", releaseModules)
    inputs.property("allowedPomLicenses", allowedPomLicenses)
    inputs.property("licenseTexts", licenseTexts)
    inputs.property("reviewedModules", reviewedModules.mapValues { (_, value) -> value.first.sorted() + value.second })
    outputs.file(output)
    doLast {
        val poms = mutableMapOf<String, PomInfo>()
        fun pom(coordinate: String) = poms.getOrPut(coordinate) { readPom(pomFile(coordinate)) }
        fun licensesOf(coordinate: String, depth: Int = 0): List<String> {
            val info = pom(coordinate)
            if (info.licenses.isNotEmpty() || info.parent == null || depth > 8) return info.licenses
            return licensesOf(info.parent, depth + 1)
        }
        val groups = sortedMapOf<String, MutableList<String>>()
        val problems = mutableListOf<String>()
        for (coordinate in releaseModules.get()) {
            val (group, module, version) = coordinate.split(":")
            val names = licensesOf(coordinate)
            val reviewed = reviewedModules["$group:$module"]
            val heading = when {
                reviewed != null && names.toSet() == reviewed.first -> reviewed.second
                names.isEmpty() -> { problems += "$coordinate: no license in its POM or parent POMs"; continue }
                names.all { it in allowedPomLicenses } -> names.map { allowedPomLicenses.getValue(it) }.distinct()
                    .joinToString(" AND ").let { spdx -> "$spdx (license text: ${spdx.split(" AND ").joinToString { licenseTexts.getValue(it) }})" }
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
        output.get().asFile.apply { parentFile.mkdirs() }.writeText(text)
    }
}
