package com.rawlab.android.album

object AlbumAccess {
    enum class Level { NONE, PARTIAL, FULL }
    fun permissions(api: Int): List<String> = when {
        api >= 34 -> listOf("android.permission.READ_MEDIA_IMAGES", "android.permission.READ_MEDIA_VISUAL_USER_SELECTED")
        api >= 33 -> listOf("android.permission.READ_MEDIA_IMAGES")
        else -> listOf("android.permission.READ_EXTERNAL_STORAGE")
    }
    fun level(api: Int, granted: Set<String>): Level = when {
        permissions(api).first() in granted -> Level.FULL
        api >= 34 && "android.permission.READ_MEDIA_VISUAL_USER_SELECTED" in granted -> Level.PARTIAL
        else -> Level.NONE
    }
}
