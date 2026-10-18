package com.rawlab.android.looks

import org.junit.Assert.*
import org.junit.Test
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.Film
import com.rawlab.android.settings.LookChoice

class FilmGroupingTest {
    @Test fun flatGroupsKeepNeutralFirstAndImportedNamesIndependent() {
        val ektar = "EKTAR_100_Phuket_v2_Strong_FLog2_FGamut_65"
        val camera = "RawLab_camera_contax_nd_std_sRGB_v1"
        val print = "RawLab_look_2383_sRGB_v1"
        val builtIns = Film.all + listOf(Film(ektar, "EKTAR 100 RawLab edition", "$ektar.cube"),
            Film(camera, "Contax", "$camera.cube"), Film(print, "2383", "$print.cube"))
        val imported = LookChoice("custom:fuji", "PROVIA", managed = true)
        val input = listOf(imported, LookChoice(camera, "Contax", false), LookChoice(print, "2383", false),
            LookChoice("neutral", "Neutral", false), LookChoice("provia", "PROVIA", false), LookChoice(ektar, "Ektar", false))
        val items = filmStripItems(input, builtIns)
        assertEquals(listOf("neutral", "provia", print, ektar, "custom:fuji", camera), items.map { it.look.id })
        assertEquals(listOf(print, "custom:fuji"), items.filter { it.startsGroup }.map { it.look.id })
        assertEquals(input.toSet(), items.map { it.look }.toSet())
        val settings = EditSettings(exposure = 1.25f).selectFilm(ektar)
        filmStripItems(input, builtIns)
        assertEquals(ektar, settings.film)
        assertEquals(1.25f, settings.exposure, 0f)
    }

    @Test fun missingGroupsDoNotProduceLeadingOrRepeatedSeparators() {
        assertTrue(filmStripItems(emptyList(), Film.all).isEmpty())
        val other = LookChoice("custom:one", "Same name", true)
        val other2 = LookChoice("custom:two", "Same name", true, available = false)
        val items = filmStripItems(listOf(other, other2), Film.all)
        assertEquals(listOf(other, other2), items.map { it.look })
        assertTrue(items.none { it.startsGroup })
    }
}
