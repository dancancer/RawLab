package com.rawlab.android

import java.io.File
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.Base64
import java.util.Properties

/** Stable source identity. A picker URI is preferred; content:<digest> is used only when no URI exists. */
@JvmInline
value class PhotoIdentity(val value: String) {
    init { require(value.isNotBlank()) }
}

class EditStore(private val directory: File) {
    private val file = File(directory, "edits.properties")
    private val records = linkedMapOf<PhotoIdentity, EditSettings>()

    init {
        if (directory.exists() && !directory.isDirectory) throw IOException("Edit store path is not a directory")
        if (!directory.exists() && !directory.mkdirs()) throw IOException("Cannot create edit store")
        load()
    }

    @Synchronized fun load(identity: PhotoIdentity): EditSettings? = records[identity]

    @Synchronized
    fun save(identity: PhotoIdentity, settings: EditSettings) {
        val updated = records.toMutableMap().apply { put(identity, settings) }
        write(updated)
        records[identity] = settings
    }

    @Synchronized
    fun reset(identity: PhotoIdentity) {
        write(records.filterKeys { it != identity })
        records.remove(identity)
    }

    private fun load() {
        if (!file.isFile) return
        val properties = Properties()
        file.inputStream().use(properties::load)
        properties.stringPropertyNames().filter { it.startsWith("record.") && it.endsWith(".values") }.forEach { key ->
            val encoded = key.removePrefix("record.").removeSuffix(".values")
            val identity = PhotoIdentity(String(Base64.getUrlDecoder().decode(encoded), StandardCharsets.UTF_8))
            val storedFilm = properties.getProperty("record.$encoded.film", "neutral")
            val film = runCatching { String(Base64.getUrlDecoder().decode(storedFilm), StandardCharsets.UTF_8) }
                .getOrDefault(storedFilm)
            records[identity] = decode(properties.getProperty(key), film)
        }
    }

    private fun write(updated: Map<PhotoIdentity, EditSettings>) {
        val properties = Properties()
        updated.forEach { (identity, settings) ->
            val encoded = Base64.getUrlEncoder().withoutPadding()
                .encodeToString(identity.value.toByteArray(StandardCharsets.UTF_8))
            properties.setProperty("record.$encoded.values", encode(settings))
            properties.setProperty("record.$encoded.film", Base64.getUrlEncoder().withoutPadding()
                .encodeToString(settings.film.toByteArray(StandardCharsets.UTF_8)))
        }
        val temporary = File(directory, "edits-${System.nanoTime()}.tmp")
        try {
            temporary.outputStream().use { properties.store(it, null) }
            moveAtomically(temporary, file)
        } catch (error: Throwable) {
            temporary.delete()
            throw if (error is IOException) error else IOException("Cannot save edit store", error)
        }
    }

    private fun encode(settings: EditSettings): String = listOf(
        settings.strength, settings.exposure, settings.highlights, settings.shadows,
        settings.contrast, settings.toneCurve, settings.saturation,
        if (settings.customWb) 1f else 0f, settings.temperature, settings.tint, settings.sharpening,
        if (settings.denoise.enabled) 1f else 0f, settings.denoise.luma, settings.denoise.chroma, settings.denoise.coarse,
        settings.displayChromaDenoise,
        settings.effects.vignetteAmount, settings.effects.vignetteMidpoint, settings.effects.vignetteRoundness,
        settings.effects.vignetteFeather, settings.effects.vignetteHighlights,
        settings.effects.grainAmount, settings.effects.grainSize, settings.effects.grainRoughness,
    ).joinToString(",")

    private fun decode(values: String, film: String): EditSettings {
        val fields = values.split(',').map(String::toFloat)
        require(fields.size == 11 || fields.size == 15 || fields.size == 24)
        return EditSettings(film = film, strength = fields[0], exposure = fields[1],
            highlights = fields[2], shadows = fields[3], contrast = fields[4], toneCurve = fields[5],
            saturation = fields[6], customWb = fields[7] != 0f, temperature = fields[8], tint = fields[9],
            sharpening = fields[10], denoise = if (fields.size == 15)
                DenoiseSettings(fields[11] != 0f, fields[12], fields[13], fields[14])
            else if (fields.size == 24)
                DenoiseSettings(fields[11] != 0f, fields[12], fields[13], fields[14])
            else DenoiseSettings(),
            displayChromaDenoise = if (fields.size == 24) parseChromaMode(fields[15]) else 0,
            effects = if (fields.size == 24) PhotoEffectsSettings(
                vignetteAmount = fields[16], vignetteMidpoint = fields[17], vignetteRoundness = fields[18],
                vignetteFeather = fields[19], vignetteHighlights = fields[20], grainAmount = fields[21],
                grainSize = fields[22], grainRoughness = fields[23],
            ) else PhotoEffectsSettings())
    }

    private fun parseChromaMode(value: Float): Int {
        require(value.isFinite() && value == value.toInt().toFloat())
        return value.toInt()
    }

    private fun moveAtomically(from: File, to: File) {
        try {
            Files.move(from.toPath(), to.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
        } catch (_: java.nio.file.AtomicMoveNotSupportedException) {
            Files.move(from.toPath(), to.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
    }
}
