package com.rawlab.android

import android.content.Context
import org.json.JSONArray

object BundledLooks {
    fun load(context: Context): List<Film> {
        val rows = JSONArray(context.assets.open("bundled-looks.json").bufferedReader().use { it.readText() })
        val films = (0 until rows.length()).map { index ->
            val row = rows.getJSONObject(index)
            Film(row.getString("id"), row.getString("name"), row.getString("fileName"), row.getString("artworkName"))
        }
        require(films.map { it.id }.distinct().size == films.size)
        require(films.map { it.fileName }.distinct().size == films.size)
        require(films.none { film -> Film.all.any { it.id == film.id } })
        return films
    }
}
