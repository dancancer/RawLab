package com.rawlab.android.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class AssetArtworkTest {
    @Test fun filmCoverKeepsQuarterSampleAtTileSize() {
        // 1254 px 胶片封面放进 80dp（3x 屏约 240 px）格子：与原先固定 1/4 一致
        assertEquals(4, artworkSampleSize(1254, 1254, 240))
    }

    @Test fun recipeArtworkIsNotDownsampledBelowTileSize() {
        // 256 px 配方插图放进 64dp（3x 屏 192 px）格子：不能再缩
        assertEquals(1, artworkSampleSize(256, 256, 192))
        assertEquals(2, artworkSampleSize(256, 256, 96))
    }

    @Test fun unknownTargetOrEmptyImageDecodesAtFullResolution() {
        assertEquals(1, artworkSampleSize(256, 256, 0))
        assertEquals(1, artworkSampleSize(0, 0, 192))
    }
}
