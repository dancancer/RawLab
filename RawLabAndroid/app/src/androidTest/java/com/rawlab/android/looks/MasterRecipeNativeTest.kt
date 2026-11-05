package com.rawlab.android.looks

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.SettingsCodec

@RunWith(AndroidJUnit4::class)
class MasterRecipeNativeTest {
    @Test fun recipeSkipsTintWhenAsShotWhiteBalanceIsUnavailable() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val input = File.createTempFile("recipe-unavailable-wb-", ".dng", context.cacheDir)
        val expectedOutput = File.createTempFile("recipe-camera-wb-", ".jpg", context.cacheDir)
        val actualOutput = File.createTempFile("recipe-fallback-wb-", ".jpg", context.cacheDir)
        try {
            val dng = instrumentation.context.assets.open("bayer-demosaic.dng").use { it.readBytes() }
            val tags = ByteBuffer.wrap(dng).order(ByteOrder.LITTLE_ENDIAN)
            val ifd = tags.getInt(4)
            val asShotNeutral = (0 until tags.getShort(ifd).toInt())
                .map { ifd + 2 + it * 12 }
                .first { (tags.getShort(it).toInt() and 0xffff) == 50728 }
            assertEquals(5, tags.getShort(asShotNeutral + 2).toInt()) // TIFF RATIONAL
            assertEquals(3, tags.getInt(asShotNeutral + 4))
            tags.position(tags.getInt(asShotNeutral + 8))
            for (value in intArrayOf(1, 1, 1, 100, 1, 1)) tags.putInt(value)
            input.writeBytes(dng)

            PhotoStorage(context).use { storage ->
                NativeProcessor(NativeProcessor.CPU).use { cpu ->
                    val neutral = cpu.preview(input, null, EditSettings(), 160, false)
                    assertTrue(neutral.temperature.isNaN())
                    val recipe = MasterRecipe.load(context).first { it.id == "takashi_yasui_zen" }
                    val edits = EditSettings().applyRecipe(recipe)
                    assertEquals(2f, edits.tint, 0f)
                    val lut = storage.lookPath(edits)!!
                    val cameraWb = edits.copy(tint = 0f)
                    val expected = cpu.preview(input, lut, cameraWb, 160, false)
                    assertFalse("Recipe must still change pixels", neutral.pixels.contentEquals(expected.pixels))
                    val actual = cpu.preview(input, lut, edits, 160, false)
                    assertArrayEquals(expected.pixels, actual.pixels)
                    assertEquals(cpu.autoExposure(input, cameraWb), cpu.autoExposure(input, edits), 0f)
                    cpu.export(input, lut, cameraWb, expectedOutput, ExportFormat.JPEG)
                    cpu.export(input, lut, edits, actualOutput, ExportFormat.JPEG)
                    assertTrue(actualOutput.length() > 0)
                    assertArrayEquals(expectedOutput.readBytes(), actualOutput.readBytes())
                }
            }
        } finally {
            input.delete()
            expectedOutput.delete()
            actualOutput.delete()
        }
    }

    @Test fun allFourteenRecipesMatchExplicitControlsOnRaw() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val input = File(context.cacheDir, "recipe-native.dng")
        instrumentation.context.assets.open("sample.RAW").use { from -> input.outputStream().use { from.copyTo(it) } }
        val storage = PhotoStorage(context)
        try {
            NativeProcessor(NativeProcessor.CPU).use { cpu ->
                NativeProcessor(NativeProcessor.AUTO).use { auto ->
                    val neutral = cpu.preview(input, null, EditSettings(), 160, false)
                    val recipes = MasterRecipe.load(context)
                    assertEquals(14, recipes.size)
                    for (recipe in recipes) {
                        assertTrue(context.assets.open("MasterRecipeIcons/${recipe.id}.png").use { it.read() } >= 0)
                        val preset = EditSettings().applyRecipe(recipe).copy(hsl = recipe.hsl.withValue(0, 7, 37f))
                        val lut = storage.lookPath(preset)!!
                        for (strength in listOf(0f, .5f, 1f, 2f)) {
                            val current = preset.copy(strength = strength)
                            val manual = EditSettings(strength = strength, exposure = current.exposure * strength,
                                shadows = current.shadows * strength, highlights = current.highlights * strength,
                                contrast = current.contrast * strength, saturation = current.saturation * strength,
                                customWb = strength != 0f, temperature = neutral.temperature,
                                tint = (neutral.tint + current.tint * strength).coerceIn(-150f, 150f), hsl = current.renderHsl)
                            val actual = cpu.preview(input, lut, current, 160, false)
                            assertArrayEquals("${recipe.id} strength $strength", cpu.preview(input, lut, manual, 160, false).pixels, actual.pixels)
                            val automatic = auto.preview(input, lut, current, 160, false)
                            val maximum = actual.pixels.indices.maxOf { index ->
                                kotlin.math.abs((actual.pixels[index].toInt() and 255) - (automatic.pixels[index].toInt() and 255))
                            }
                            assertTrue("${recipe.id} Auto/CPU max $maximum", maximum <= 2)
                            if (strength == 0f) assertArrayEquals(neutral.pixels, actual.pixels)
                            assertEquals(current, SettingsCodec.decode(SettingsCodec.encode(current)))
                        }
                    }
                    assertArrayEquals(neutral.pixels, cpu.preview(input, null, EditSettings(), 160, false).pixels)
                }
            }
        } finally { storage.close(); input.delete() }
    }
}
