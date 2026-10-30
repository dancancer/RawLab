package com.rawlab.android.looks

import com.rawlab.android.settings.Film
import com.rawlab.android.settings.LookChoice
import java.text.Normalizer
import java.util.Locale

internal enum class LookBrowserCategory { ALL, FUJI, KODAK, OTHER, CUSTOM, RECENT }

private val accentMarks = Regex("\\p{M}+")
private fun normalizedLookName(value: String) = Normalizer.normalize(value, Normalizer.Form.NFD)
    .replace(accentMarks, "").lowercase(Locale.ROOT)

internal fun browseLooks(looks: List<LookChoice>, builtIns: List<Film>, category: LookBrowserCategory,
    query: String, recent: List<String>): List<FilmStripItem> {
    val term = normalizedLookName(query.trim())
    val matching = looks.filter { look ->
        (look.id != "neutral" || category == LookBrowserCategory.ALL && term.isEmpty()) &&
            (term.isEmpty() || normalizedLookName(look.name).contains(term)) && when (category) {
                LookBrowserCategory.ALL, LookBrowserCategory.RECENT -> true
                LookBrowserCategory.CUSTOM -> look.managed
                LookBrowserCategory.FUJI -> !look.managed && look.group(builtIns) == FilmGroup.FUJI
                LookBrowserCategory.KODAK -> !look.managed && look.group(builtIns) == FilmGroup.KODAK
                LookBrowserCategory.OTHER -> look.group(builtIns) == FilmGroup.OTHER
            }
    }
    if (category == LookBrowserCategory.RECENT) {
        val byId = matching.associateBy { it.id }
        return recent.mapNotNull { byId[it]?.let { look -> FilmStripItem(look, false) } }
    }
    return filmStripItems(matching, builtIns)
}

internal class RecentLooks(ids: List<String> = emptyList()) {
    var ids = ids.filter { it.isNotEmpty() && it != "neutral" }.distinct().take(12)
        private set

    fun record(id: String, available: Set<String>) {
        if (id.isEmpty() || id == "neutral" || id !in available) return
        ids = (listOf(id) + ids.filter { it != id && it in available }).take(12)
    }
    fun prune(available: Set<String>) { ids = ids.filter(available::contains) }
}
