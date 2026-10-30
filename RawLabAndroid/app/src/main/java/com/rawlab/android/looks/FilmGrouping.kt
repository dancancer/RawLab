package com.rawlab.android.looks

import com.rawlab.android.settings.Film
import com.rawlab.android.settings.LookChoice

internal enum class FilmGroup { FUJI, KODAK, OTHER }

internal data class FilmStripItem(val look: LookChoice, val startsGroup: Boolean)

internal fun LookChoice.group(builtIns: List<Film>): FilmGroup = when {
    managed -> FilmGroup.OTHER
    builtIns.none { it.id == id } -> FilmGroup.OTHER
    Film.all.any { it.id == id && it.file != null } -> FilmGroup.FUJI
    id.startsWith("RawLab_look_") || id == "EKTAR_100_Phuket_v2_Strong_FLog2_FGamut_65" -> FilmGroup.KODAK
    else -> FilmGroup.OTHER
}

internal fun filmStripItems(looks: List<LookChoice>, builtIns: List<Film>): List<FilmStripItem> {
    val neutral = looks.filter { it.id == "neutral" && !it.managed }
    val groups = FilmGroup.entries.map { group ->
        looks.filter { it !in neutral && it.group(builtIns) == group }
    }.filter { it.isNotEmpty() }
    return neutral.map { FilmStripItem(it, false) } + groups.flatMapIndexed { index, group ->
        group.mapIndexed { item, look -> FilmStripItem(look, index > 0 && item == 0) }
    }
}
