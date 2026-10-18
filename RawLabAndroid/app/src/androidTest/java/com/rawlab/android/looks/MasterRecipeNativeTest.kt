package com.rawlab.android.looks

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import com.rawlab.android.engine.NativeProcessor
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.SettingsCodec

@RunWith(AndroidJUnit4::class)
class MasterRecipeNativeTest {
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
