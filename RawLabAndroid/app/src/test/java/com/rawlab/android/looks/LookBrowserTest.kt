package com.rawlab.android.looks

import com.rawlab.android.settings.Film
import com.rawlab.android.settings.LookChoice
import org.junit.Assert.*
import org.junit.Test

class LookBrowserTest {
    @Test fun categoriesAndSearchPreserveStableIdentities() {
        val looks = listOf(LookChoice("provia", "Été doux", false), LookChoice("managed:1", "My winter", true))
        assertEquals(listOf("provia"), browseLooks(looks, Film.all, LookBrowserCategory.ALL, "ETE", emptyList()).map { it.look.id })
        assertEquals(listOf("managed:1"), browseLooks(looks, Film.all, LookBrowserCategory.CUSTOM, "", emptyList()).map { it.look.id })
        assertTrue(browseLooks(looks, Film.all, LookBrowserCategory.ALL, "missing", emptyList()).isEmpty())
        assertEquals(listOf("managed:1", "provia"), browseLooks(looks, Film.all, LookBrowserCategory.RECENT, "", listOf("managed:1", "deleted", "provia")).map { it.look.id })
        assertEquals("Été doux", looks.first().name)
    }
    @Test fun recentKeepsTwelveUniqueValidLookIds() {
        val ids = (0..13).map { "look:$it" }; val available = ids.toSet()
        val recent = RecentLooks()
        ids.forEach { recent.record(it, available) }
        assertEquals(12, recent.ids.size); assertEquals("look:13", recent.ids.first()); assertFalse("look:0" in recent.ids)
        recent.record("look:8", available)
        assertEquals("look:8", recent.ids.first()); assertEquals(1, recent.ids.count { it == "look:8" })
        recent.prune(setOf("look:5", "look:8"))
        assertEquals(listOf("look:8", "look:5"), recent.ids)
        assertEquals(listOf("a", "b"), RecentLooks(listOf("a", "a", "b")).ids)
    }
}
