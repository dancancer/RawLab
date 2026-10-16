package com.rawlab.android

import org.junit.Assert.*
import org.junit.Test

class BundledLookTest {
    @Test fun projectEktarHasItsOwnStableIdentityAndResources() {
        val id = "EKTAR_100_Phuket_v2_Strong_FLog2_FGamut_65"
        val film = Film(id, "EKTAR 100 Phuket v2 Strong", "$id.cube", "ektar-100-phuket")
        assertEquals("EKTAR 100 Phuket v2 Strong", film.name)
        assertEquals("$id.cube", film.fileName)
        assertEquals("ektar-100-phuket", film.artworkName)
        val settings = EditSettings().selectFilm(id)
        assertEquals(id, SettingsCodec.decode(SettingsCodec.encode(settings)).film)
        assertEquals("FLog2_to_PROVIA_65grid_V.1.00.cube", Film.all.single { it.id == "provia" }.fileName)
        assertNull(Film.all.single { it.id == "neutral" }.fileName)
    }
}
