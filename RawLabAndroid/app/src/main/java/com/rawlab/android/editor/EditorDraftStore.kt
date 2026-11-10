package com.rawlab.android.editor

import com.rawlab.android.geometry.GeometryRatio
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.settings.StructuredSettingsCodec
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.Properties

/** 未应用草稿独立于照片历史；原始 URI、内容指纹和已提交快照均匹配才可恢复。 */
internal class EditorDraftStore(private val directory: File) {
    private val file get() = File(directory, "active.properties")

    fun save(identity: PhotoIdentity, fingerprint: String, draft: AdjustmentDraft) {
        require(fingerprint.isNotEmpty())
        val values = Properties().apply {
            setProperty("version", "1"); setProperty("identity", identity.value); setProperty("fingerprint", fingerprint)
            setProperty("group", draft.group.name)
            setProperty("original", encode(draft.original)); setProperty("value", encode(draft.value))
            setProperty("ratio", draft.geometryRatio.name); setProperty("portrait", draft.geometryPortrait.toString())
            setProperty("originalAspect", draft.geometryOriginalAspect.toString())
            setProperty("canvasAspect", draft.geometryCanvasAspect.toString())
            draft.geometryLockedRatio?.let { setProperty("lockedRatio", it.toString()) }
            setProperty("grid", draft.geometryGrid.toString()); setProperty("pair", draft.includesPair.toString())
            setProperty("interacting", draft.interacting.toString())
            listOf("undo" to draft.undoSteps, "redo" to draft.redoSteps).forEach { (prefix, steps) ->
                setProperty("$prefix.count", steps.size.toString())
                steps.forEachIndexed { index, step ->
                    val key = "$prefix.$index"
                    setProperty("$key.value", encode(step.value)); setProperty("$key.ratio", step.ratio.name)
                    setProperty("$key.portrait", step.portrait.toString()); setProperty("$key.grid", step.grid.toString())
                    setProperty("$key.pair", step.includesPair.toString())
                    step.lockedRatio?.let { setProperty("$key.lockedRatio", it.toString()) }
                }
            }
        }
        check(directory.isDirectory || directory.mkdirs())
        val pending = File(directory, "active.pending")
        try {
            FileOutputStream(pending).use { output -> values.store(output, null); output.fd.sync() }
            Files.move(pending.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } finally { pending.delete() }
    }

    fun load(identity: PhotoIdentity, fingerprint: String, committed: EditSettings): AdjustmentDraft? {
        val values = read() ?: return null
        require(values.getProperty("version") == "1")
        if (values.getProperty("identity") != identity.value || values.getProperty("fingerprint") != fingerprint) return null
        fun required(key: String) = requireNotNull(values.getProperty(key))
        fun flag(key: String) = required(key).toBooleanStrict()
        fun aspect(key: String) = required(key).toFloat().also { require(it.isFinite() && it > 0) }
        fun lock(key: String) = values.getProperty(key)?.toFloat()?.also { require(it.isFinite() && it > 0) }
        val original = decode(required("original"))
        if (original != committed) return null
        fun history(prefix: String): List<AdjustmentDraftStep> {
            val count = required("$prefix.count").toInt().also { require(it in 0..100) }
            return List(count) { index ->
                val key = "$prefix.$index"
                AdjustmentDraftStep(decode(required("$key.value")), GeometryRatio.valueOf(required("$key.ratio")),
                    flag("$key.portrait"), lock("$key.lockedRatio"), flag("$key.grid"), flag("$key.pair"))
            }
        }
        return AdjustmentDraft(AdjustmentGroup.valueOf(required("group")), original, decode(required("value")),
            GeometryRatio.valueOf(required("ratio")), flag("portrait"), aspect("originalAspect"), aspect("canvasAspect"),
            lock("lockedRatio"), flag("grid"), flag("pair"), history("undo"), history("redo"), flag("interacting"))
    }

    fun clear(identity: PhotoIdentity) {
        if (read()?.getProperty("identity") == identity.value && file.exists()) check(file.delete())
    }

    private fun read(): Properties? {
        if (!file.exists()) return null
        require(file.length() <= 4 * 1024 * 1024)
        return Properties().apply { file.inputStream().use(::load) }
    }
    private fun encode(value: EditSettings) = StructuredSettingsCodec.encode(value, "photo_edit")
    private fun decode(value: String) = StructuredSettingsCodec.decode(value, "photo_edit")
}
