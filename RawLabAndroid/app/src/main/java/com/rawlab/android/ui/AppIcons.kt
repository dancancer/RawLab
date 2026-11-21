package com.rawlab.android.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.unit.dp

/**
 * Local Material vector definitions for the 64 extended-only icons used by RawLab,
 * allowing the release and debug builds to depend only on `material-icons-core`
 * instead of the 34 MB `material-icons-extended` AAR.
 */
internal object AppIcons {
    object Outlined {
        private var _aspectRatio: ImageVector? = null
        val AspectRatio: ImageVector
            get() = _aspectRatio ?: materialIcon("Outlined.AspectRatio", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(19.0f, 12.0f)
                    horizontalLineToRelative(-2.0f)
                    verticalLineToRelative(3.0f)
                    horizontalLineToRelative(-3.0f)
                    verticalLineToRelative(2.0f)
                    horizontalLineToRelative(5.0f)
                    verticalLineToRelative(-5.0f)
                    close()
                    moveTo(7.0f, 9.0f)
                    horizontalLineToRelative(3.0f)
                    lineTo(10.0f, 7.0f)
                    lineTo(5.0f, 7.0f)
                    verticalLineToRelative(5.0f)
                    horizontalLineToRelative(2.0f)
                    lineTo(7.0f, 9.0f)
                    close()
                    moveTo(21.0f, 3.0f)
                    lineTo(3.0f, 3.0f)
                    curveToRelative(-1.1f, 0.0f, -2.0f, 0.9f, -2.0f, 2.0f)
                    verticalLineToRelative(14.0f)
                    curveToRelative(0.0f, 1.1f, 0.9f, 2.0f, 2.0f, 2.0f)
                    horizontalLineToRelative(18.0f)
                    curveToRelative(1.1f, 0.0f, 2.0f, -0.9f, 2.0f, -2.0f)
                    lineTo(23.0f, 5.0f)
                    curveToRelative(0.0f, -1.1f, -0.9f, -2.0f, -2.0f, -2.0f)
                    close()
                    moveTo(21.0f, 19.01f)
                    lineTo(3.0f, 19.01f)
                    lineTo(3.0f, 4.99f)
                    horizontalLineToRelative(18.0f)
                    verticalLineToRelative(14.02f)
                    close()
                }
            }.also { _aspectRatio = it }
        private var _autoFixHigh: ImageVector? = null
        val AutoFixHigh: ImageVector
            get() = _autoFixHigh ?: materialIcon("Outlined.AutoFixHigh", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(20.0f, 7.0f)
                    lineToRelative(0.94f, -2.06f)
                    lineToRelative(2.06f, -0.94f)
                    lineToRelative(-2.06f, -0.94f)
                    lineToRelative(-0.94f, -2.06f)
                    lineToRelative(-0.94f, 2.06f)
                    lineToRelative(-2.06f, 0.94f)
                    lineToRelative(2.06f, 0.94f)
                    close()
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(8.5f, 7.0f)
                    lineToRelative(0.94f, -2.06f)
                    lineToRelative(2.06f, -0.94f)
                    lineToRelative(-2.06f, -0.94f)
                    lineToRelative(-0.94f, -2.06f)
                    lineToRelative(-0.94f, 2.06f)
                    lineToRelative(-2.06f, 0.94f)
                    lineToRelative(2.06f, 0.94f)
                    close()
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(20.0f, 12.5f)
                    lineToRelative(-0.94f, 2.06f)
                    lineToRelative(-2.06f, 0.94f)
                    lineToRelative(2.06f, 0.94f)
                    lineToRelative(0.94f, 2.06f)
                    lineToRelative(0.94f, -2.06f)
                    lineToRelative(2.06f, -0.94f)
                    lineToRelative(-2.06f, -0.94f)
                    close()
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(17.71f, 9.12f)
                    lineToRelative(-2.83f, -2.83f)
                    curveTo(14.68f, 6.1f, 14.43f, 6.0f, 14.17f, 6.0f)
                    curveToRelative(-0.26f, 0.0f, -0.51f, 0.1f, -0.71f, 0.29f)
                    lineTo(2.29f, 17.46f)
                    curveToRelative(-0.39f, 0.39f, -0.39f, 1.02f, 0.0f, 1.41f)
                    lineToRelative(2.83f, 2.83f)
                    curveTo(5.32f, 21.9f, 5.57f, 22.0f, 5.83f, 22.0f)
                    reflectiveCurveToRelative(0.51f, -0.1f, 0.71f, -0.29f)
                    lineToRelative(11.17f, -11.17f)
                    curveTo(18.1f, 10.15f, 18.1f, 9.51f, 17.71f, 9.12f)
                    close()
                    moveTo(14.17f, 8.42f)
                    lineToRelative(1.41f, 1.41f)
                    lineTo(14.41f, 11.0f)
                    lineTo(13.0f, 9.59f)
                    lineTo(14.17f, 8.42f)
                    close()
                    moveTo(5.83f, 19.59f)
                    lineToRelative(-1.41f, -1.41f)
                    lineTo(11.59f, 11.0f)
                    lineTo(13.0f, 12.41f)
                    lineTo(5.83f, 19.59f)
                    close()
                }
            }.also { _autoFixHigh = it }
        private var _barChart: ImageVector? = null
        val BarChart: ImageVector
            get() = _barChart ?: materialIcon("Outlined.BarChart", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(4.0f, 9.0f)
                    horizontalLineToRelative(4.0f)
                    verticalLineToRelative(11.0f)
                    horizontalLineToRelative(-4.0f)
                    close()
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(16.0f, 13.0f)
                    horizontalLineToRelative(4.0f)
                    verticalLineToRelative(7.0f)
                    horizontalLineToRelative(-4.0f)
                    close()
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(10.0f, 4.0f)
                    horizontalLineToRelative(4.0f)
                    verticalLineToRelative(16.0f)
                    horizontalLineToRelative(-4.0f)
                    close()
                }
            }.also { _barChart = it }
        private var _blurOff: ImageVector? = null
        val BlurOff: ImageVector
            get() = _blurOff ?: materialIcon("Outlined.BlurOff", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(14.0f, 6.0f)
                    moveToRelative(-1.0f, 0.0f)
                    arcToRelative(1.0f, 1.0f, 0.0f, true, true, 2.0f, 0.0f)
                    arcToRelative(1.0f, 1.0f, 0.0f, true, true, -2.0f, 0.0f)
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(13.8f, 11.48f)
                    lineToRelative(0.2f, 0.02f)
                    curveToRelative(0.83f, 0.0f, 1.5f, -0.67f, 1.5f, -1.5f)
                    reflectiveCurveToRelative(-0.67f, -1.5f, -1.5f, -1.5f)
                    reflectiveCurveToRelative(-1.5f, 0.67f, -1.5f, 1.5f)
                    lineToRelative(0.02f, 0.2f)
                    curveToRelative(0.09f, 0.67f, 0.61f, 1.19f, 1.28f, 1.28f)
                    close()
                    moveTo(14.0f, 3.5f)
                    curveToRelative(0.28f, 0.0f, 0.5f, -0.22f, 0.5f, -0.5f)
                    reflectiveCurveToRelative(-0.22f, -0.5f, -0.5f, -0.5f)
                    reflectiveCurveToRelative(-0.5f, 0.22f, -0.5f, 0.5f)
                    reflectiveCurveToRelative(0.22f, 0.5f, 0.5f, 0.5f)
                    close()
                    moveTo(10.0f, 3.5f)
                    curveToRelative(0.28f, 0.0f, 0.5f, -0.22f, 0.5f, -0.5f)
                    reflectiveCurveToRelative(-0.22f, -0.5f, -0.5f, -0.5f)
                    reflectiveCurveToRelative(-0.5f, 0.22f, -0.5f, 0.5f)
                    reflectiveCurveToRelative(0.22f, 0.5f, 0.5f, 0.5f)
                    close()
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(18.0f, 10.0f)
                    moveToRelative(-1.0f, 0.0f)
                    arcToRelative(1.0f, 1.0f, 0.0f, true, true, 2.0f, 0.0f)
                    arcToRelative(1.0f, 1.0f, 0.0f, true, true, -2.0f, 0.0f)
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(18.0f, 6.0f)
                    moveToRelative(-1.0f, 0.0f)
                    arcToRelative(1.0f, 1.0f, 0.0f, true, true, 2.0f, 0.0f)
                    arcToRelative(1.0f, 1.0f, 0.0f, true, true, -2.0f, 0.0f)
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(21.0f, 10.5f)
                    curveToRelative(0.28f, 0.0f, 0.5f, -0.22f, 0.5f, -0.5f)
                    reflectiveCurveToRelative(-0.22f, -0.5f, -0.5f, -0.5f)
                    reflectiveCurveToRelative(-0.5f, 0.22f, -0.5f, 0.5f)
                    reflectiveCurveToRelative(0.22f, 0.5f, 0.5f, 0.5f)
                    close()
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(10.0f, 6.0f)
                    moveToRelative(-1.0f, 0.0f)
                    arcToRelative(1.0f, 1.0f, 0.0f, true, true, 2.0f, 0.0f)
                    arcToRelative(1.0f, 1.0f, 0.0f, true, true, -2.0f, 0.0f)
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(18.0f, 14.0f)
                    moveToRelative(-1.0f, 0.0f)
                    arcToRelative(1.0f, 1.0f, 0.0f, true, true, 2.0f, 0.0f)
                    arcToRelative(1.0f, 1.0f, 0.0f, true, true, -2.0f, 0.0f)
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(6.0f, 18.0f)
                    moveToRelative(-1.0f, 0.0f)
                    arcToRelative(1.0f, 1.0f, 0.0f, true, true, 2.0f, 0.0f)
                    arcToRelative(1.0f, 1.0f, 0.0f, true, true, -2.0f, 0.0f)
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(14.0f, 20.5f)
                    curveToRelative(-0.28f, 0.0f, -0.5f, 0.22f, -0.5f, 0.5f)
                    reflectiveCurveToRelative(0.22f, 0.5f, 0.5f, 0.5f)
                    reflectiveCurveToRelative(0.5f, -0.22f, 0.5f, -0.5f)
                    reflectiveCurveToRelative(-0.22f, -0.5f, -0.5f, -0.5f)
                    close()
                    moveTo(21.0f, 13.5f)
                    curveToRelative(-0.28f, 0.0f, -0.5f, 0.22f, -0.5f, 0.5f)
                    reflectiveCurveToRelative(0.22f, 0.5f, 0.5f, 0.5f)
                    reflectiveCurveToRelative(0.5f, -0.22f, 0.5f, -0.5f)
                    reflectiveCurveToRelative(-0.22f, -0.5f, -0.5f, -0.5f)
                    close()
                    moveTo(3.0f, 13.5f)
                    curveToRelative(-0.28f, 0.0f, -0.5f, 0.22f, -0.5f, 0.5f)
                    reflectiveCurveToRelative(0.22f, 0.5f, 0.5f, 0.5f)
                    reflectiveCurveToRelative(0.5f, -0.22f, 0.5f, -0.5f)
                    reflectiveCurveToRelative(-0.22f, -0.5f, -0.5f, -0.5f)
                    close()
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(10.0f, 18.0f)
                    moveToRelative(-1.0f, 0.0f)
                    arcToRelative(1.0f, 1.0f, 0.0f, true, true, 2.0f, 0.0f)
                    arcToRelative(1.0f, 1.0f, 0.0f, true, true, -2.0f, 0.0f)
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(3.0f, 9.5f)
                    curveToRelative(-0.28f, 0.0f, -0.5f, 0.22f, -0.5f, 0.5f)
                    reflectiveCurveToRelative(0.22f, 0.5f, 0.5f, 0.5f)
                    reflectiveCurveToRelative(0.5f, -0.22f, 0.5f, -0.5f)
                    reflectiveCurveToRelative(-0.22f, -0.5f, -0.5f, -0.5f)
                    close()
                    moveTo(10.0f, 20.5f)
                    curveToRelative(-0.28f, 0.0f, -0.5f, 0.22f, -0.5f, 0.5f)
                    reflectiveCurveToRelative(0.22f, 0.5f, 0.5f, 0.5f)
                    reflectiveCurveToRelative(0.5f, -0.22f, 0.5f, -0.5f)
                    reflectiveCurveToRelative(-0.22f, -0.5f, -0.5f, -0.5f)
                    close()
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(6.0f, 14.0f)
                    moveToRelative(-1.0f, 0.0f)
                    arcToRelative(1.0f, 1.0f, 0.0f, true, true, 2.0f, 0.0f)
                    arcToRelative(1.0f, 1.0f, 0.0f, true, true, -2.0f, 0.0f)
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(2.5f, 5.27f)
                    lineTo(6.0f, 8.77f)
                    lineToRelative(0.28f, 0.28f)
                    lineTo(6.0f, 9.0f)
                    curveToRelative(-0.55f, 0.0f, -1.0f, 0.45f, -1.0f, 1.0f)
                    reflectiveCurveToRelative(0.45f, 1.0f, 1.0f, 1.0f)
                    reflectiveCurveToRelative(1.0f, -0.45f, 1.0f, -1.0f)
                    curveToRelative(0.0f, -0.1f, -0.03f, -0.19f, -0.06f, -0.28f)
                    lineToRelative(2.81f, 2.81f)
                    curveToRelative(-0.71f, 0.11f, -1.25f, 0.73f, -1.25f, 1.47f)
                    curveToRelative(0.0f, 0.83f, 0.67f, 1.5f, 1.5f, 1.5f)
                    curveToRelative(0.74f, 0.0f, 1.36f, -0.54f, 1.47f, -1.25f)
                    lineToRelative(2.81f, 2.81f)
                    curveToRelative(-0.09f, -0.03f, -0.18f, -0.06f, -0.28f, -0.06f)
                    curveToRelative(-0.55f, 0.0f, -1.0f, 0.45f, -1.0f, 1.0f)
                    reflectiveCurveToRelative(0.45f, 1.0f, 1.0f, 1.0f)
                    reflectiveCurveToRelative(1.0f, -0.45f, 1.0f, -1.0f)
                    curveToRelative(0.0f, -0.1f, -0.03f, -0.19f, -0.06f, -0.28f)
                    lineToRelative(3.78f, 3.78f)
                    horizontalLineToRelative(0.01f)
                    lineToRelative(1.41f, -1.41f)
                    lineTo(3.91f, 3.86f)
                    lineTo(2.5f, 5.27f)
                    close()
                }
            }.also { _blurOff = it }
        private var _bookmarks: ImageVector? = null
        val Bookmarks: ImageVector
            get() = _bookmarks ?: materialIcon("Outlined.Bookmarks", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(15.0f, 7.0f)
                    verticalLineToRelative(12.97f)
                    lineToRelative(-4.21f, -1.81f)
                    lineToRelative(-0.79f, -0.34f)
                    lineToRelative(-0.79f, 0.34f)
                    lineTo(5.0f, 19.97f)
                    lineTo(5.0f, 7.0f)
                    horizontalLineToRelative(10.0f)
                    moveToRelative(4.0f, -6.0f)
                    lineTo(8.99f, 1.0f)
                    curveTo(7.89f, 1.0f, 7.0f, 1.9f, 7.0f, 3.0f)
                    horizontalLineToRelative(10.0f)
                    curveToRelative(1.1f, 0.0f, 2.0f, 0.9f, 2.0f, 2.0f)
                    verticalLineToRelative(13.0f)
                    lineToRelative(2.0f, 1.0f)
                    lineTo(21.0f, 3.0f)
                    curveToRelative(0.0f, -1.1f, -0.9f, -2.0f, -2.0f, -2.0f)
                    close()
                    moveTo(15.0f, 5.0f)
                    lineTo(5.0f, 5.0f)
                    curveToRelative(-1.1f, 0.0f, -2.0f, 0.9f, -2.0f, 2.0f)
                    verticalLineToRelative(16.0f)
                    lineToRelative(7.0f, -3.0f)
                    lineToRelative(7.0f, 3.0f)
                    lineTo(17.0f, 7.0f)
                    curveToRelative(0.0f, -1.1f, -0.9f, -2.0f, -2.0f, -2.0f)
                    close()
                }
            }.also { _bookmarks = it }
        private var _brightness6: ImageVector? = null
        val Brightness6: ImageVector
            get() = _brightness6 ?: materialIcon("Outlined.Brightness6", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(20.0f, 8.69f)
                    lineTo(20.0f, 4.0f)
                    horizontalLineToRelative(-4.69f)
                    lineTo(12.0f, 0.69f)
                    lineTo(8.69f, 4.0f)
                    lineTo(4.0f, 4.0f)
                    verticalLineToRelative(4.69f)
                    lineTo(0.69f, 12.0f)
                    lineTo(4.0f, 15.31f)
                    lineTo(4.0f, 20.0f)
                    horizontalLineToRelative(4.69f)
                    lineTo(12.0f, 23.31f)
                    lineTo(15.31f, 20.0f)
                    lineTo(20.0f, 20.0f)
                    verticalLineToRelative(-4.69f)
                    lineTo(23.31f, 12.0f)
                    lineTo(20.0f, 8.69f)
                    close()
                    moveTo(18.0f, 14.48f)
                    lineTo(18.0f, 18.0f)
                    horizontalLineToRelative(-3.52f)
                    lineTo(12.0f, 20.48f)
                    lineTo(9.52f, 18.0f)
                    lineTo(6.0f, 18.0f)
                    verticalLineToRelative(-3.52f)
                    lineTo(3.52f, 12.0f)
                    lineTo(6.0f, 9.52f)
                    lineTo(6.0f, 6.0f)
                    horizontalLineToRelative(3.52f)
                    lineTo(12.0f, 3.52f)
                    lineTo(14.48f, 6.0f)
                    lineTo(18.0f, 6.0f)
                    verticalLineToRelative(3.52f)
                    lineTo(20.48f, 12.0f)
                    lineTo(18.0f, 14.48f)
                    close()
                    moveTo(12.0f, 6.5f)
                    verticalLineToRelative(11.0f)
                    curveToRelative(3.03f, 0.0f, 5.5f, -2.47f, 5.5f, -5.5f)
                    reflectiveCurveTo(15.03f, 6.5f, 12.0f, 6.5f)
                    close()
                }
            }.also { _brightness6 = it }
        private var _brightnessHigh: ImageVector? = null
        val BrightnessHigh: ImageVector
            get() = _brightnessHigh ?: materialIcon("Outlined.BrightnessHigh", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(20.0f, 8.69f)
                    lineTo(20.0f, 4.0f)
                    horizontalLineToRelative(-4.69f)
                    lineTo(12.0f, 0.69f)
                    lineTo(8.69f, 4.0f)
                    lineTo(4.0f, 4.0f)
                    verticalLineToRelative(4.69f)
                    lineTo(0.69f, 12.0f)
                    lineTo(4.0f, 15.31f)
                    lineTo(4.0f, 20.0f)
                    horizontalLineToRelative(4.69f)
                    lineTo(12.0f, 23.31f)
                    lineTo(15.31f, 20.0f)
                    lineTo(20.0f, 20.0f)
                    verticalLineToRelative(-4.69f)
                    lineTo(23.31f, 12.0f)
                    lineTo(20.0f, 8.69f)
                    close()
                    moveTo(18.0f, 14.48f)
                    lineTo(18.0f, 18.0f)
                    horizontalLineToRelative(-3.52f)
                    lineTo(12.0f, 20.48f)
                    lineTo(9.52f, 18.0f)
                    lineTo(6.0f, 18.0f)
                    verticalLineToRelative(-3.52f)
                    lineTo(3.52f, 12.0f)
                    lineTo(6.0f, 9.52f)
                    lineTo(6.0f, 6.0f)
                    horizontalLineToRelative(3.52f)
                    lineTo(12.0f, 3.52f)
                    lineTo(14.48f, 6.0f)
                    lineTo(18.0f, 6.0f)
                    verticalLineToRelative(3.52f)
                    lineTo(20.48f, 12.0f)
                    lineTo(18.0f, 14.48f)
                    close()
                    moveTo(12.0f, 6.0f)
                    curveToRelative(-3.31f, 0.0f, -6.0f, 2.69f, -6.0f, 6.0f)
                    reflectiveCurveToRelative(2.69f, 6.0f, 6.0f, 6.0f)
                    reflectiveCurveToRelative(6.0f, -2.69f, 6.0f, -6.0f)
                    reflectiveCurveToRelative(-2.69f, -6.0f, -6.0f, -6.0f)
                    close()
                    moveTo(12.0f, 16.0f)
                    curveToRelative(-2.21f, 0.0f, -4.0f, -1.79f, -4.0f, -4.0f)
                    reflectiveCurveToRelative(1.79f, -4.0f, 4.0f, -4.0f)
                    reflectiveCurveToRelative(4.0f, 1.79f, 4.0f, 4.0f)
                    reflectiveCurveToRelative(-1.79f, 4.0f, -4.0f, 4.0f)
                    close()
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(12.0f, 12.0f)
                    moveToRelative(-2.5f, 0.0f)
                    arcToRelative(2.5f, 2.5f, 0.0f, true, true, 5.0f, 0.0f)
                    arcToRelative(2.5f, 2.5f, 0.0f, true, true, -5.0f, 0.0f)
                }
            }.also { _brightnessHigh = it }
        private var _brightnessMedium: ImageVector? = null
        val BrightnessMedium: ImageVector
            get() = _brightnessMedium ?: materialIcon("Outlined.BrightnessMedium", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(20.0f, 8.69f)
                    lineTo(20.0f, 4.0f)
                    horizontalLineToRelative(-4.69f)
                    lineTo(12.0f, 0.69f)
                    lineTo(8.69f, 4.0f)
                    lineTo(4.0f, 4.0f)
                    verticalLineToRelative(4.69f)
                    lineTo(0.69f, 12.0f)
                    lineTo(4.0f, 15.31f)
                    lineTo(4.0f, 20.0f)
                    horizontalLineToRelative(4.69f)
                    lineTo(12.0f, 23.31f)
                    lineTo(15.31f, 20.0f)
                    lineTo(20.0f, 20.0f)
                    verticalLineToRelative(-4.69f)
                    lineTo(23.31f, 12.0f)
                    lineTo(20.0f, 8.69f)
                    close()
                    moveTo(18.0f, 14.48f)
                    lineTo(18.0f, 18.0f)
                    horizontalLineToRelative(-3.52f)
                    lineTo(12.0f, 20.48f)
                    lineTo(9.52f, 18.0f)
                    lineTo(6.0f, 18.0f)
                    verticalLineToRelative(-3.52f)
                    lineTo(3.52f, 12.0f)
                    lineTo(6.0f, 9.52f)
                    lineTo(6.0f, 6.0f)
                    horizontalLineToRelative(3.52f)
                    lineTo(12.0f, 3.52f)
                    lineTo(14.48f, 6.0f)
                    lineTo(18.0f, 6.0f)
                    verticalLineToRelative(3.52f)
                    lineTo(20.48f, 12.0f)
                    lineTo(18.0f, 14.48f)
                    close()
                    moveTo(12.0f, 6.0f)
                    verticalLineToRelative(12.0f)
                    curveToRelative(3.31f, 0.0f, 6.0f, -2.69f, 6.0f, -6.0f)
                    reflectiveCurveToRelative(-2.69f, -6.0f, -6.0f, -6.0f)
                    close()
                }
            }.also { _brightnessMedium = it }
        private var _cameraAlt: ImageVector? = null
        val CameraAlt: ImageVector
            get() = _cameraAlt ?: materialIcon("Outlined.CameraAlt", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(20.0f, 4.0f)
                    horizontalLineToRelative(-3.17f)
                    lineTo(15.0f, 2.0f)
                    lineTo(9.0f, 2.0f)
                    lineTo(7.17f, 4.0f)
                    lineTo(4.0f, 4.0f)
                    curveToRelative(-1.1f, 0.0f, -2.0f, 0.9f, -2.0f, 2.0f)
                    verticalLineToRelative(12.0f)
                    curveToRelative(0.0f, 1.1f, 0.9f, 2.0f, 2.0f, 2.0f)
                    horizontalLineToRelative(16.0f)
                    curveToRelative(1.1f, 0.0f, 2.0f, -0.9f, 2.0f, -2.0f)
                    lineTo(22.0f, 6.0f)
                    curveToRelative(0.0f, -1.1f, -0.9f, -2.0f, -2.0f, -2.0f)
                    close()
                    moveTo(20.0f, 18.0f)
                    lineTo(4.0f, 18.0f)
                    lineTo(4.0f, 6.0f)
                    horizontalLineToRelative(4.05f)
                    lineToRelative(1.83f, -2.0f)
                    horizontalLineToRelative(4.24f)
                    lineToRelative(1.83f, 2.0f)
                    lineTo(20.0f, 6.0f)
                    verticalLineToRelative(12.0f)
                    close()
                    moveTo(12.0f, 7.0f)
                    curveToRelative(-2.76f, 0.0f, -5.0f, 2.24f, -5.0f, 5.0f)
                    reflectiveCurveToRelative(2.24f, 5.0f, 5.0f, 5.0f)
                    reflectiveCurveToRelative(5.0f, -2.24f, 5.0f, -5.0f)
                    reflectiveCurveToRelative(-2.24f, -5.0f, -5.0f, -5.0f)
                    close()
                    moveTo(12.0f, 15.0f)
                    curveToRelative(-1.65f, 0.0f, -3.0f, -1.35f, -3.0f, -3.0f)
                    reflectiveCurveToRelative(1.35f, -3.0f, 3.0f, -3.0f)
                    reflectiveCurveToRelative(3.0f, 1.35f, 3.0f, 3.0f)
                    reflectiveCurveToRelative(-1.35f, 3.0f, -3.0f, 3.0f)
                    close()
                }
            }.also { _cameraAlt = it }
        private var _centerFocusStrong: ImageVector? = null
        val CenterFocusStrong: ImageVector
            get() = _centerFocusStrong ?: materialIcon("Outlined.CenterFocusStrong", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(17.0f, 12.0f)
                    curveToRelative(0.0f, -2.76f, -2.24f, -5.0f, -5.0f, -5.0f)
                    reflectiveCurveToRelative(-5.0f, 2.24f, -5.0f, 5.0f)
                    reflectiveCurveToRelative(2.24f, 5.0f, 5.0f, 5.0f)
                    reflectiveCurveToRelative(5.0f, -2.24f, 5.0f, -5.0f)
                    close()
                    moveTo(12.0f, 15.0f)
                    curveToRelative(-1.65f, 0.0f, -3.0f, -1.35f, -3.0f, -3.0f)
                    reflectiveCurveToRelative(1.35f, -3.0f, 3.0f, -3.0f)
                    reflectiveCurveToRelative(3.0f, 1.35f, 3.0f, 3.0f)
                    reflectiveCurveToRelative(-1.35f, 3.0f, -3.0f, 3.0f)
                    close()
                    moveTo(5.0f, 15.0f)
                    lineTo(3.0f, 15.0f)
                    verticalLineToRelative(4.0f)
                    curveToRelative(0.0f, 1.1f, 0.9f, 2.0f, 2.0f, 2.0f)
                    horizontalLineToRelative(4.0f)
                    verticalLineToRelative(-2.0f)
                    lineTo(5.0f, 19.0f)
                    verticalLineToRelative(-4.0f)
                    close()
                    moveTo(5.0f, 5.0f)
                    horizontalLineToRelative(4.0f)
                    lineTo(9.0f, 3.0f)
                    lineTo(5.0f, 3.0f)
                    curveToRelative(-1.1f, 0.0f, -2.0f, 0.9f, -2.0f, 2.0f)
                    verticalLineToRelative(4.0f)
                    horizontalLineToRelative(2.0f)
                    lineTo(5.0f, 5.0f)
                    close()
                    moveTo(19.0f, 3.0f)
                    horizontalLineToRelative(-4.0f)
                    verticalLineToRelative(2.0f)
                    horizontalLineToRelative(4.0f)
                    verticalLineToRelative(4.0f)
                    horizontalLineToRelative(2.0f)
                    lineTo(21.0f, 5.0f)
                    curveToRelative(0.0f, -1.1f, -0.9f, -2.0f, -2.0f, -2.0f)
                    close()
                    moveTo(19.0f, 19.0f)
                    horizontalLineToRelative(-4.0f)
                    verticalLineToRelative(2.0f)
                    horizontalLineToRelative(4.0f)
                    curveToRelative(1.1f, 0.0f, 2.0f, -0.9f, 2.0f, -2.0f)
                    verticalLineToRelative(-4.0f)
                    horizontalLineToRelative(-2.0f)
                    verticalLineToRelative(4.0f)
                    close()
                }
            }.also { _centerFocusStrong = it }
        private var _circle: ImageVector? = null
        val Circle: ImageVector
            get() = _circle ?: materialIcon("Outlined.Circle", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(12.0f, 2.0f)
                    curveTo(6.47f, 2.0f, 2.0f, 6.47f, 2.0f, 12.0f)
                    curveToRelative(0.0f, 5.53f, 4.47f, 10.0f, 10.0f, 10.0f)
                    reflectiveCurveToRelative(10.0f, -4.47f, 10.0f, -10.0f)
                    curveTo(22.0f, 6.47f, 17.53f, 2.0f, 12.0f, 2.0f)
                    close()
                    moveTo(12.0f, 20.0f)
                    curveToRelative(-4.42f, 0.0f, -8.0f, -3.58f, -8.0f, -8.0f)
                    curveToRelative(0.0f, -4.42f, 3.58f, -8.0f, 8.0f, -8.0f)
                    reflectiveCurveToRelative(8.0f, 3.58f, 8.0f, 8.0f)
                    curveTo(20.0f, 16.42f, 16.42f, 20.0f, 12.0f, 20.0f)
                    close()
                }
            }.also { _circle = it }
        private var _cloud: ImageVector? = null
        val Cloud: ImageVector
            get() = _cloud ?: materialIcon("Outlined.Cloud", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(12.0f, 6.0f)
                    curveToRelative(2.62f, 0.0f, 4.88f, 1.86f, 5.39f, 4.43f)
                    lineToRelative(0.3f, 1.5f)
                    lineToRelative(1.53f, 0.11f)
                    curveToRelative(1.56f, 0.1f, 2.78f, 1.41f, 2.78f, 2.96f)
                    curveToRelative(0.0f, 1.65f, -1.35f, 3.0f, -3.0f, 3.0f)
                    horizontalLineTo(6.0f)
                    curveToRelative(-2.21f, 0.0f, -4.0f, -1.79f, -4.0f, -4.0f)
                    curveToRelative(0.0f, -2.05f, 1.53f, -3.76f, 3.56f, -3.97f)
                    lineToRelative(1.07f, -0.11f)
                    lineToRelative(0.5f, -0.95f)
                    curveTo(8.08f, 7.14f, 9.94f, 6.0f, 12.0f, 6.0f)
                    moveToRelative(0.0f, -2.0f)
                    curveTo(9.11f, 4.0f, 6.6f, 5.64f, 5.35f, 8.04f)
                    curveTo(2.34f, 8.36f, 0.0f, 10.91f, 0.0f, 14.0f)
                    curveToRelative(0.0f, 3.31f, 2.69f, 6.0f, 6.0f, 6.0f)
                    horizontalLineToRelative(13.0f)
                    curveToRelative(2.76f, 0.0f, 5.0f, -2.24f, 5.0f, -5.0f)
                    curveToRelative(0.0f, -2.64f, -2.05f, -4.78f, -4.65f, -4.96f)
                    curveTo(18.67f, 6.59f, 15.64f, 4.0f, 12.0f, 4.0f)
                    close()
                }
            }.also { _cloud = it }
        private var _collections: ImageVector? = null
        val Collections: ImageVector
            get() = _collections ?: materialIcon("Outlined.Collections", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(20.0f, 4.0f)
                    verticalLineToRelative(12.0f)
                    lineTo(8.0f, 16.0f)
                    lineTo(8.0f, 4.0f)
                    horizontalLineToRelative(12.0f)
                    moveToRelative(0.0f, -2.0f)
                    lineTo(8.0f, 2.0f)
                    curveToRelative(-1.1f, 0.0f, -2.0f, 0.9f, -2.0f, 2.0f)
                    verticalLineToRelative(12.0f)
                    curveToRelative(0.0f, 1.1f, 0.9f, 2.0f, 2.0f, 2.0f)
                    horizontalLineToRelative(12.0f)
                    curveToRelative(1.1f, 0.0f, 2.0f, -0.9f, 2.0f, -2.0f)
                    lineTo(22.0f, 4.0f)
                    curveToRelative(0.0f, -1.1f, -0.9f, -2.0f, -2.0f, -2.0f)
                    close()
                    moveTo(11.5f, 11.67f)
                    lineToRelative(1.69f, 2.26f)
                    lineToRelative(2.48f, -3.1f)
                    lineTo(19.0f, 15.0f)
                    lineTo(9.0f, 15.0f)
                    close()
                    moveTo(2.0f, 6.0f)
                    verticalLineToRelative(14.0f)
                    curveToRelative(0.0f, 1.1f, 0.9f, 2.0f, 2.0f, 2.0f)
                    horizontalLineToRelative(14.0f)
                    verticalLineToRelative(-2.0f)
                    lineTo(4.0f, 20.0f)
                    lineTo(4.0f, 6.0f)
                    lineTo(2.0f, 6.0f)
                    close()
                }
            }.also { _collections = it }
        private var _colorLens: ImageVector? = null
        val ColorLens: ImageVector
            get() = _colorLens ?: materialIcon("Outlined.ColorLens", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(12.0f, 22.0f)
                    curveTo(6.49f, 22.0f, 2.0f, 17.51f, 2.0f, 12.0f)
                    reflectiveCurveTo(6.49f, 2.0f, 12.0f, 2.0f)
                    reflectiveCurveToRelative(10.0f, 4.04f, 10.0f, 9.0f)
                    curveToRelative(0.0f, 3.31f, -2.69f, 6.0f, -6.0f, 6.0f)
                    horizontalLineToRelative(-1.77f)
                    curveToRelative(-0.28f, 0.0f, -0.5f, 0.22f, -0.5f, 0.5f)
                    curveToRelative(0.0f, 0.12f, 0.05f, 0.23f, 0.13f, 0.33f)
                    curveToRelative(0.41f, 0.47f, 0.64f, 1.06f, 0.64f, 1.67f)
                    curveToRelative(0.0f, 1.38f, -1.12f, 2.5f, -2.5f, 2.5f)
                    close()
                    moveTo(12.0f, 4.0f)
                    curveToRelative(-4.41f, 0.0f, -8.0f, 3.59f, -8.0f, 8.0f)
                    reflectiveCurveToRelative(3.59f, 8.0f, 8.0f, 8.0f)
                    curveToRelative(0.28f, 0.0f, 0.5f, -0.22f, 0.5f, -0.5f)
                    curveToRelative(0.0f, -0.16f, -0.08f, -0.28f, -0.14f, -0.35f)
                    curveToRelative(-0.41f, -0.46f, -0.63f, -1.05f, -0.63f, -1.65f)
                    curveToRelative(0.0f, -1.38f, 1.12f, -2.5f, 2.5f, -2.5f)
                    lineTo(16.0f, 15.0f)
                    curveToRelative(2.21f, 0.0f, 4.0f, -1.79f, 4.0f, -4.0f)
                    curveToRelative(0.0f, -3.86f, -3.59f, -7.0f, -8.0f, -7.0f)
                    close()
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(6.5f, 11.5f)
                    moveToRelative(-1.5f, 0.0f)
                    arcToRelative(1.5f, 1.5f, 0.0f, true, true, 3.0f, 0.0f)
                    arcToRelative(1.5f, 1.5f, 0.0f, true, true, -3.0f, 0.0f)
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(9.5f, 7.5f)
                    moveToRelative(-1.5f, 0.0f)
                    arcToRelative(1.5f, 1.5f, 0.0f, true, true, 3.0f, 0.0f)
                    arcToRelative(1.5f, 1.5f, 0.0f, true, true, -3.0f, 0.0f)
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(14.5f, 7.5f)
                    moveToRelative(-1.5f, 0.0f)
                    arcToRelative(1.5f, 1.5f, 0.0f, true, true, 3.0f, 0.0f)
                    arcToRelative(1.5f, 1.5f, 0.0f, true, true, -3.0f, 0.0f)
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(17.5f, 11.5f)
                    moveToRelative(-1.5f, 0.0f)
                    arcToRelative(1.5f, 1.5f, 0.0f, true, true, 3.0f, 0.0f)
                    arcToRelative(1.5f, 1.5f, 0.0f, true, true, -3.0f, 0.0f)
                }
            }.also { _colorLens = it }
        private var _compare: ImageVector? = null
        val Compare: ImageVector
            get() = _compare ?: materialIcon("Outlined.Compare", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(10.0f, 3.0f)
                    lineTo(5.0f, 3.0f)
                    curveToRelative(-1.1f, 0.0f, -2.0f, 0.9f, -2.0f, 2.0f)
                    verticalLineToRelative(14.0f)
                    curveToRelative(0.0f, 1.1f, 0.9f, 2.0f, 2.0f, 2.0f)
                    horizontalLineToRelative(5.0f)
                    verticalLineToRelative(2.0f)
                    horizontalLineToRelative(2.0f)
                    lineTo(12.0f, 1.0f)
                    horizontalLineToRelative(-2.0f)
                    verticalLineToRelative(2.0f)
                    close()
                    moveTo(10.0f, 18.0f)
                    lineTo(5.0f, 18.0f)
                    lineToRelative(5.0f, -6.0f)
                    verticalLineToRelative(6.0f)
                    close()
                    moveTo(19.0f, 3.0f)
                    horizontalLineToRelative(-5.0f)
                    verticalLineToRelative(2.0f)
                    horizontalLineToRelative(5.0f)
                    verticalLineToRelative(13.0f)
                    lineToRelative(-5.0f, -6.0f)
                    verticalLineToRelative(9.0f)
                    horizontalLineToRelative(5.0f)
                    curveToRelative(1.1f, 0.0f, 2.0f, -0.9f, 2.0f, -2.0f)
                    lineTo(21.0f, 5.0f)
                    curveToRelative(0.0f, -1.1f, -0.9f, -2.0f, -2.0f, -2.0f)
                    close()
                }
            }.also { _compare = it }
        private var _contentCopy: ImageVector? = null
        val ContentCopy: ImageVector
            get() = _contentCopy ?: materialIcon("Outlined.ContentCopy", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(16.0f, 1.0f)
                    lineTo(4.0f, 1.0f)
                    curveToRelative(-1.1f, 0.0f, -2.0f, 0.9f, -2.0f, 2.0f)
                    verticalLineToRelative(14.0f)
                    horizontalLineToRelative(2.0f)
                    lineTo(4.0f, 3.0f)
                    horizontalLineToRelative(12.0f)
                    lineTo(16.0f, 1.0f)
                    close()
                    moveTo(19.0f, 5.0f)
                    lineTo(8.0f, 5.0f)
                    curveToRelative(-1.1f, 0.0f, -2.0f, 0.9f, -2.0f, 2.0f)
                    verticalLineToRelative(14.0f)
                    curveToRelative(0.0f, 1.1f, 0.9f, 2.0f, 2.0f, 2.0f)
                    horizontalLineToRelative(11.0f)
                    curveToRelative(1.1f, 0.0f, 2.0f, -0.9f, 2.0f, -2.0f)
                    lineTo(21.0f, 7.0f)
                    curveToRelative(0.0f, -1.1f, -0.9f, -2.0f, -2.0f, -2.0f)
                    close()
                    moveTo(19.0f, 21.0f)
                    lineTo(8.0f, 21.0f)
                    lineTo(8.0f, 7.0f)
                    horizontalLineToRelative(11.0f)
                    verticalLineToRelative(14.0f)
                    close()
                }
            }.also { _contentCopy = it }
        private var _contentPaste: ImageVector? = null
        val ContentPaste: ImageVector
            get() = _contentPaste ?: materialIcon("Outlined.ContentPaste", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(19.0f, 2.0f)
                    horizontalLineToRelative(-4.18f)
                    curveTo(14.4f, 0.84f, 13.3f, 0.0f, 12.0f, 0.0f)
                    reflectiveCurveTo(9.6f, 0.84f, 9.18f, 2.0f)
                    lineTo(5.0f, 2.0f)
                    curveToRelative(-1.1f, 0.0f, -2.0f, 0.9f, -2.0f, 2.0f)
                    verticalLineToRelative(16.0f)
                    curveToRelative(0.0f, 1.1f, 0.9f, 2.0f, 2.0f, 2.0f)
                    horizontalLineToRelative(14.0f)
                    curveToRelative(1.1f, 0.0f, 2.0f, -0.9f, 2.0f, -2.0f)
                    lineTo(21.0f, 4.0f)
                    curveToRelative(0.0f, -1.1f, -0.9f, -2.0f, -2.0f, -2.0f)
                    close()
                    moveTo(12.0f, 2.0f)
                    curveToRelative(0.55f, 0.0f, 1.0f, 0.45f, 1.0f, 1.0f)
                    reflectiveCurveToRelative(-0.45f, 1.0f, -1.0f, 1.0f)
                    reflectiveCurveToRelative(-1.0f, -0.45f, -1.0f, -1.0f)
                    reflectiveCurveToRelative(0.45f, -1.0f, 1.0f, -1.0f)
                    close()
                    moveTo(19.0f, 20.0f)
                    lineTo(5.0f, 20.0f)
                    lineTo(5.0f, 4.0f)
                    horizontalLineToRelative(2.0f)
                    verticalLineToRelative(3.0f)
                    horizontalLineToRelative(10.0f)
                    lineTo(17.0f, 4.0f)
                    horizontalLineToRelative(2.0f)
                    verticalLineToRelative(16.0f)
                    close()
                }
            }.also { _contentPaste = it }
        private var _contrast: ImageVector? = null
        val Contrast: ImageVector
            get() = _contrast ?: materialIcon("Outlined.Contrast", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(12.0f, 22.0f)
                    curveToRelative(5.52f, 0.0f, 10.0f, -4.48f, 10.0f, -10.0f)
                    reflectiveCurveTo(17.52f, 2.0f, 12.0f, 2.0f)
                    reflectiveCurveTo(2.0f, 6.48f, 2.0f, 12.0f)
                    reflectiveCurveTo(6.48f, 22.0f, 12.0f, 22.0f)
                    close()
                    moveTo(13.0f, 4.07f)
                    curveToRelative(3.94f, 0.49f, 7.0f, 3.85f, 7.0f, 7.93f)
                    reflectiveCurveToRelative(-3.05f, 7.44f, -7.0f, 7.93f)
                    verticalLineTo(4.07f)
                    close()
                }
            }.also { _contrast = it }
        private var _cropRotate: ImageVector? = null
        val CropRotate: ImageVector
            get() = _cropRotate ?: materialIcon("Outlined.CropRotate", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(7.47f, 21.49f)
                    curveTo(4.2f, 19.93f, 1.86f, 16.76f, 1.5f, 13.0f)
                    lineTo(0.0f, 13.0f)
                    curveToRelative(0.51f, 6.16f, 5.66f, 11.0f, 11.95f, 11.0f)
                    curveToRelative(0.23f, 0.0f, 0.44f, -0.02f, 0.66f, -0.03f)
                    lineTo(8.8f, 20.15f)
                    lineToRelative(-1.33f, 1.34f)
                    close()
                    moveTo(12.05f, 0.0f)
                    curveToRelative(-0.23f, 0.0f, -0.44f, 0.02f, -0.66f, 0.04f)
                    lineToRelative(3.81f, 3.81f)
                    lineToRelative(1.33f, -1.33f)
                    curveTo(19.8f, 4.07f, 22.14f, 7.24f, 22.5f, 11.0f)
                    lineTo(24.0f, 11.0f)
                    curveToRelative(-0.51f, -6.16f, -5.66f, -11.0f, -11.95f, -11.0f)
                    close()
                    moveTo(16.0f, 14.0f)
                    horizontalLineToRelative(2.0f)
                    lineTo(18.0f, 8.0f)
                    curveToRelative(0.0f, -1.11f, -0.9f, -2.0f, -2.0f, -2.0f)
                    horizontalLineToRelative(-6.0f)
                    verticalLineToRelative(2.0f)
                    horizontalLineToRelative(6.0f)
                    verticalLineToRelative(6.0f)
                    close()
                    moveTo(8.0f, 16.0f)
                    lineTo(8.0f, 4.0f)
                    lineTo(6.0f, 4.0f)
                    verticalLineToRelative(2.0f)
                    lineTo(4.0f, 6.0f)
                    verticalLineToRelative(2.0f)
                    horizontalLineToRelative(2.0f)
                    verticalLineToRelative(8.0f)
                    curveToRelative(0.0f, 1.1f, 0.89f, 2.0f, 2.0f, 2.0f)
                    horizontalLineToRelative(8.0f)
                    verticalLineToRelative(2.0f)
                    horizontalLineToRelative(2.0f)
                    verticalLineToRelative(-2.0f)
                    horizontalLineToRelative(2.0f)
                    verticalLineToRelative(-2.0f)
                    lineTo(8.0f, 16.0f)
                    close()
                }
            }.also { _cropRotate = it }
        private var _cropSquare: ImageVector? = null
        val CropSquare: ImageVector
            get() = _cropSquare ?: materialIcon("Outlined.CropSquare", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(18.0f, 4.0f)
                    lineTo(6.0f, 4.0f)
                    curveToRelative(-1.1f, 0.0f, -2.0f, 0.9f, -2.0f, 2.0f)
                    verticalLineToRelative(12.0f)
                    curveToRelative(0.0f, 1.1f, 0.9f, 2.0f, 2.0f, 2.0f)
                    horizontalLineToRelative(12.0f)
                    curveToRelative(1.1f, 0.0f, 2.0f, -0.9f, 2.0f, -2.0f)
                    lineTo(20.0f, 6.0f)
                    curveToRelative(0.0f, -1.1f, -0.9f, -2.0f, -2.0f, -2.0f)
                    close()
                    moveTo(18.0f, 18.0f)
                    lineTo(6.0f, 18.0f)
                    lineTo(6.0f, 6.0f)
                    horizontalLineToRelative(12.0f)
                    verticalLineToRelative(12.0f)
                    close()
                }
            }.also { _cropSquare = it }
        private var _darkMode: ImageVector? = null
        val DarkMode: ImageVector
            get() = _darkMode ?: materialIcon("Outlined.DarkMode", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(9.37f, 5.51f)
                    curveTo(9.19f, 6.15f, 9.1f, 6.82f, 9.1f, 7.5f)
                    curveToRelative(0.0f, 4.08f, 3.32f, 7.4f, 7.4f, 7.4f)
                    curveToRelative(0.68f, 0.0f, 1.35f, -0.09f, 1.99f, -0.27f)
                    curveTo(17.45f, 17.19f, 14.93f, 19.0f, 12.0f, 19.0f)
                    curveToRelative(-3.86f, 0.0f, -7.0f, -3.14f, -7.0f, -7.0f)
                    curveTo(5.0f, 9.07f, 6.81f, 6.55f, 9.37f, 5.51f)
                    close()
                    moveTo(12.0f, 3.0f)
                    curveToRelative(-4.97f, 0.0f, -9.0f, 4.03f, -9.0f, 9.0f)
                    reflectiveCurveToRelative(4.03f, 9.0f, 9.0f, 9.0f)
                    reflectiveCurveToRelative(9.0f, -4.03f, 9.0f, -9.0f)
                    curveToRelative(0.0f, -0.46f, -0.04f, -0.92f, -0.1f, -1.36f)
                    curveToRelative(-0.98f, 1.37f, -2.58f, 2.26f, -4.4f, 2.26f)
                    curveToRelative(-2.98f, 0.0f, -5.4f, -2.42f, -5.4f, -5.4f)
                    curveToRelative(0.0f, -1.81f, 0.89f, -3.42f, 2.26f, -4.4f)
                    curveTo(12.92f, 3.04f, 12.46f, 3.0f, 12.0f, 3.0f)
                    lineTo(12.0f, 3.0f)
                    close()
                }
            }.also { _darkMode = it }
        private var _deblur: ImageVector? = null
        val Deblur: ImageVector
            get() = _deblur ?: materialIcon("Outlined.Deblur", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(6.0f, 14.0f)
                    moveToRelative(-1.0f, 0.0f)
                    arcToRelative(1.0f, 1.0f, 0.0f, true, true, 2.0f, 0.0f)
                    arcToRelative(1.0f, 1.0f, 0.0f, true, true, -2.0f, 0.0f)
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(6.0f, 18.0f)
                    moveToRelative(-1.0f, 0.0f)
                    arcToRelative(1.0f, 1.0f, 0.0f, true, true, 2.0f, 0.0f)
                    arcToRelative(1.0f, 1.0f, 0.0f, true, true, -2.0f, 0.0f)
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(6.0f, 10.0f)
                    moveToRelative(-1.0f, 0.0f)
                    arcToRelative(1.0f, 1.0f, 0.0f, true, true, 2.0f, 0.0f)
                    arcToRelative(1.0f, 1.0f, 0.0f, true, true, -2.0f, 0.0f)
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(3.0f, 10.0f)
                    moveToRelative(-0.5f, 0.0f)
                    arcToRelative(0.5f, 0.5f, 0.0f, true, true, 1.0f, 0.0f)
                    arcToRelative(0.5f, 0.5f, 0.0f, true, true, -1.0f, 0.0f)
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(6.0f, 6.0f)
                    moveToRelative(-1.0f, 0.0f)
                    arcToRelative(1.0f, 1.0f, 0.0f, true, true, 2.0f, 0.0f)
                    arcToRelative(1.0f, 1.0f, 0.0f, true, true, -2.0f, 0.0f)
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(3.0f, 14.0f)
                    moveToRelative(-0.5f, 0.0f)
                    arcToRelative(0.5f, 0.5f, 0.0f, true, true, 1.0f, 0.0f)
                    arcToRelative(0.5f, 0.5f, 0.0f, true, true, -1.0f, 0.0f)
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(10.0f, 21.0f)
                    moveToRelative(-0.5f, 0.0f)
                    arcToRelative(0.5f, 0.5f, 0.0f, true, true, 1.0f, 0.0f)
                    arcToRelative(0.5f, 0.5f, 0.0f, true, true, -1.0f, 0.0f)
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(10.0f, 3.0f)
                    moveToRelative(-0.5f, 0.0f)
                    arcToRelative(0.5f, 0.5f, 0.0f, true, true, 1.0f, 0.0f)
                    arcToRelative(0.5f, 0.5f, 0.0f, true, true, -1.0f, 0.0f)
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(10.0f, 6.0f)
                    moveToRelative(-1.0f, 0.0f)
                    arcToRelative(1.0f, 1.0f, 0.0f, true, true, 2.0f, 0.0f)
                    arcToRelative(1.0f, 1.0f, 0.0f, true, true, -2.0f, 0.0f)
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(10.0f, 14.0f)
                    moveToRelative(-1.5f, 0.0f)
                    arcToRelative(1.5f, 1.5f, 0.0f, true, true, 3.0f, 0.0f)
                    arcToRelative(1.5f, 1.5f, 0.0f, true, true, -3.0f, 0.0f)
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(10.0f, 10.0f)
                    moveToRelative(-1.5f, 0.0f)
                    arcToRelative(1.5f, 1.5f, 0.0f, true, true, 3.0f, 0.0f)
                    arcToRelative(1.5f, 1.5f, 0.0f, true, true, -3.0f, 0.0f)
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(10.0f, 18.0f)
                    moveToRelative(-1.0f, 0.0f)
                    arcToRelative(1.0f, 1.0f, 0.0f, true, true, 2.0f, 0.0f)
                    arcToRelative(1.0f, 1.0f, 0.0f, true, true, -2.0f, 0.0f)
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(12.0f, 3.0f)
                    verticalLineToRelative(2.0f)
                    curveToRelative(3.86f, 0.0f, 7.0f, 3.14f, 7.0f, 7.0f)
                    reflectiveCurveToRelative(-3.14f, 7.0f, -7.0f, 7.0f)
                    verticalLineToRelative(2.0f)
                    curveToRelative(4.96f, 0.0f, 9.0f, -4.04f, 9.0f, -9.0f)
                    reflectiveCurveTo(16.96f, 3.0f, 12.0f, 3.0f)
                    close()
                }
            }.also { _deblur = it }
        private var _description: ImageVector? = null
        val Description: ImageVector
            get() = _description ?: materialIcon("Outlined.Description", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(8.0f, 16.0f)
                    horizontalLineToRelative(8.0f)
                    verticalLineToRelative(2.0f)
                    lineTo(8.0f, 18.0f)
                    close()
                    moveTo(8.0f, 12.0f)
                    horizontalLineToRelative(8.0f)
                    verticalLineToRelative(2.0f)
                    lineTo(8.0f, 14.0f)
                    close()
                    moveTo(14.0f, 2.0f)
                    lineTo(6.0f, 2.0f)
                    curveToRelative(-1.1f, 0.0f, -2.0f, 0.9f, -2.0f, 2.0f)
                    verticalLineToRelative(16.0f)
                    curveToRelative(0.0f, 1.1f, 0.89f, 2.0f, 1.99f, 2.0f)
                    lineTo(18.0f, 22.0f)
                    curveToRelative(1.1f, 0.0f, 2.0f, -0.9f, 2.0f, -2.0f)
                    lineTo(20.0f, 8.0f)
                    lineToRelative(-6.0f, -6.0f)
                    close()
                    moveTo(18.0f, 20.0f)
                    lineTo(6.0f, 20.0f)
                    lineTo(6.0f, 4.0f)
                    horizontalLineToRelative(7.0f)
                    verticalLineToRelative(5.0f)
                    horizontalLineToRelative(5.0f)
                    verticalLineToRelative(11.0f)
                    close()
                }
            }.also { _description = it }
        private var _expandLess: ImageVector? = null
        val ExpandLess: ImageVector
            get() = _expandLess ?: materialIcon("Outlined.ExpandLess", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(12.0f, 8.0f)
                    lineToRelative(-6.0f, 6.0f)
                    lineToRelative(1.41f, 1.41f)
                    lineTo(12.0f, 10.83f)
                    lineToRelative(4.59f, 4.58f)
                    lineTo(18.0f, 14.0f)
                    lineToRelative(-6.0f, -6.0f)
                    close()
                }
            }.also { _expandLess = it }
        private var _expandMore: ImageVector? = null
        val ExpandMore: ImageVector
            get() = _expandMore ?: materialIcon("Outlined.ExpandMore", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(16.59f, 8.59f)
                    lineTo(12.0f, 13.17f)
                    lineTo(7.41f, 8.59f)
                    lineTo(6.0f, 10.0f)
                    lineToRelative(6.0f, 6.0f)
                    lineToRelative(6.0f, -6.0f)
                    lineToRelative(-1.41f, -1.41f)
                    close()
                }
            }.also { _expandMore = it }
        private var _exposure: ImageVector? = null
        val Exposure: ImageVector
            get() = _exposure ?: materialIcon("Outlined.Exposure", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(19.0f, 3.0f)
                    lineTo(5.0f, 3.0f)
                    curveToRelative(-1.1f, 0.0f, -2.0f, 0.9f, -2.0f, 2.0f)
                    verticalLineToRelative(14.0f)
                    curveToRelative(0.0f, 1.1f, 0.9f, 2.0f, 2.0f, 2.0f)
                    horizontalLineToRelative(14.0f)
                    curveToRelative(1.1f, 0.0f, 2.0f, -0.9f, 2.0f, -2.0f)
                    lineTo(21.0f, 5.0f)
                    curveToRelative(0.0f, -1.1f, -0.9f, -2.0f, -2.0f, -2.0f)
                    close()
                    moveTo(17.59f, 5.0f)
                    lineTo(5.0f, 17.59f)
                    lineTo(5.0f, 5.0f)
                    horizontalLineToRelative(12.59f)
                    close()
                    moveTo(6.41f, 19.0f)
                    lineTo(19.0f, 6.41f)
                    lineTo(19.0f, 19.0f)
                    lineTo(6.41f, 19.0f)
                    close()
                    moveTo(6.0f, 7.0f)
                    horizontalLineToRelative(5.0f)
                    verticalLineToRelative(1.5f)
                    lineTo(6.0f, 8.5f)
                    close()
                    moveTo(16.0f, 12.5f)
                    horizontalLineToRelative(-1.5f)
                    verticalLineToRelative(2.0f)
                    horizontalLineToRelative(-2.0f)
                    lineTo(12.5f, 16.0f)
                    horizontalLineToRelative(2.0f)
                    verticalLineToRelative(2.0f)
                    lineTo(16.0f, 18.0f)
                    verticalLineToRelative(-2.0f)
                    horizontalLineToRelative(2.0f)
                    verticalLineToRelative(-1.5f)
                    horizontalLineToRelative(-2.0f)
                    close()
                }
            }.also { _exposure = it }
        private var _filterList: ImageVector? = null
        val FilterList: ImageVector
            get() = _filterList ?: materialIcon("Outlined.FilterList", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(10.0f, 18.0f)
                    horizontalLineToRelative(4.0f)
                    verticalLineToRelative(-2.0f)
                    horizontalLineToRelative(-4.0f)
                    verticalLineToRelative(2.0f)
                    close()
                    moveTo(3.0f, 6.0f)
                    verticalLineToRelative(2.0f)
                    horizontalLineToRelative(18.0f)
                    lineTo(21.0f, 6.0f)
                    lineTo(3.0f, 6.0f)
                    close()
                    moveTo(6.0f, 13.0f)
                    horizontalLineToRelative(12.0f)
                    verticalLineToRelative(-2.0f)
                    lineTo(6.0f, 11.0f)
                    verticalLineToRelative(2.0f)
                    close()
                }
            }.also { _filterList = it }
        private var _flip: ImageVector? = null
        val Flip: ImageVector
            get() = _flip ?: materialIcon("Outlined.Flip", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(15.0f, 21.0f)
                    horizontalLineToRelative(2.0f)
                    verticalLineToRelative(-2.0f)
                    horizontalLineToRelative(-2.0f)
                    verticalLineToRelative(2.0f)
                    close()
                    moveTo(19.0f, 9.0f)
                    horizontalLineToRelative(2.0f)
                    lineTo(21.0f, 7.0f)
                    horizontalLineToRelative(-2.0f)
                    verticalLineToRelative(2.0f)
                    close()
                    moveTo(3.0f, 5.0f)
                    verticalLineToRelative(14.0f)
                    curveToRelative(0.0f, 1.1f, 0.9f, 2.0f, 2.0f, 2.0f)
                    horizontalLineToRelative(4.0f)
                    verticalLineToRelative(-2.0f)
                    lineTo(5.0f, 19.0f)
                    lineTo(5.0f, 5.0f)
                    horizontalLineToRelative(4.0f)
                    lineTo(9.0f, 3.0f)
                    lineTo(5.0f, 3.0f)
                    curveToRelative(-1.1f, 0.0f, -2.0f, 0.9f, -2.0f, 2.0f)
                    close()
                    moveTo(19.0f, 3.0f)
                    verticalLineToRelative(2.0f)
                    horizontalLineToRelative(2.0f)
                    curveToRelative(0.0f, -1.1f, -0.9f, -2.0f, -2.0f, -2.0f)
                    close()
                    moveTo(11.0f, 23.0f)
                    horizontalLineToRelative(2.0f)
                    lineTo(13.0f, 1.0f)
                    horizontalLineToRelative(-2.0f)
                    verticalLineToRelative(22.0f)
                    close()
                    moveTo(19.0f, 17.0f)
                    horizontalLineToRelative(2.0f)
                    verticalLineToRelative(-2.0f)
                    horizontalLineToRelative(-2.0f)
                    verticalLineToRelative(2.0f)
                    close()
                    moveTo(15.0f, 5.0f)
                    horizontalLineToRelative(2.0f)
                    lineTo(17.0f, 3.0f)
                    horizontalLineToRelative(-2.0f)
                    verticalLineToRelative(2.0f)
                    close()
                    moveTo(19.0f, 13.0f)
                    horizontalLineToRelative(2.0f)
                    verticalLineToRelative(-2.0f)
                    horizontalLineToRelative(-2.0f)
                    verticalLineToRelative(2.0f)
                    close()
                    moveTo(19.0f, 21.0f)
                    curveToRelative(1.1f, 0.0f, 2.0f, -0.9f, 2.0f, -2.0f)
                    horizontalLineToRelative(-2.0f)
                    verticalLineToRelative(2.0f)
                    close()
                }
            }.also { _flip = it }
        private var _flipCameraAndroid: ImageVector? = null
        val FlipCameraAndroid: ImageVector
            get() = _flipCameraAndroid ?: materialIcon("Outlined.FlipCameraAndroid", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(9.0f, 12.0f)
                    curveToRelative(0.0f, 1.66f, 1.34f, 3.0f, 3.0f, 3.0f)
                    reflectiveCurveToRelative(3.0f, -1.34f, 3.0f, -3.0f)
                    reflectiveCurveToRelative(-1.34f, -3.0f, -3.0f, -3.0f)
                    reflectiveCurveTo(9.0f, 10.34f, 9.0f, 12.0f)
                    close()
                    moveTo(13.0f, 12.0f)
                    curveToRelative(0.0f, 0.55f, -0.45f, 1.0f, -1.0f, 1.0f)
                    reflectiveCurveToRelative(-1.0f, -0.45f, -1.0f, -1.0f)
                    reflectiveCurveToRelative(0.45f, -1.0f, 1.0f, -1.0f)
                    reflectiveCurveTo(13.0f, 11.45f, 13.0f, 12.0f)
                    close()
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(8.0f, 10.0f)
                    verticalLineTo(8.0f)
                    horizontalLineTo(5.09f)
                    curveTo(6.47f, 5.61f, 9.05f, 4.0f, 12.0f, 4.0f)
                    curveToRelative(3.72f, 0.0f, 6.85f, 2.56f, 7.74f, 6.0f)
                    horizontalLineToRelative(2.06f)
                    curveToRelative(-0.93f, -4.56f, -4.96f, -8.0f, -9.8f, -8.0f)
                    curveTo(8.73f, 2.0f, 5.82f, 3.58f, 4.0f, 6.01f)
                    verticalLineTo(4.0f)
                    horizontalLineTo(2.0f)
                    verticalLineToRelative(6.0f)
                    horizontalLineTo(8.0f)
                    close()
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(16.0f, 14.0f)
                    verticalLineToRelative(2.0f)
                    horizontalLineToRelative(2.91f)
                    curveToRelative(-1.38f, 2.39f, -3.96f, 4.0f, -6.91f, 4.0f)
                    curveToRelative(-3.72f, 0.0f, -6.85f, -2.56f, -7.74f, -6.0f)
                    horizontalLineTo(2.2f)
                    curveToRelative(0.93f, 4.56f, 4.96f, 8.0f, 9.8f, 8.0f)
                    curveToRelative(3.27f, 0.0f, 6.18f, -1.58f, 8.0f, -4.01f)
                    verticalLineTo(20.0f)
                    horizontalLineToRelative(2.0f)
                    verticalLineToRelative(-6.0f)
                    horizontalLineTo(16.0f)
                    close()
                }
            }.also { _flipCameraAndroid = it }
        private var _folderOpen: ImageVector? = null
        val FolderOpen: ImageVector
            get() = _folderOpen ?: materialIcon("Outlined.FolderOpen", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(20.0f, 6.0f)
                    horizontalLineToRelative(-8.0f)
                    lineToRelative(-2.0f, -2.0f)
                    lineTo(4.0f, 4.0f)
                    curveToRelative(-1.1f, 0.0f, -1.99f, 0.9f, -1.99f, 2.0f)
                    lineTo(2.0f, 18.0f)
                    curveToRelative(0.0f, 1.1f, 0.9f, 2.0f, 2.0f, 2.0f)
                    horizontalLineToRelative(16.0f)
                    curveToRelative(1.1f, 0.0f, 2.0f, -0.9f, 2.0f, -2.0f)
                    lineTo(22.0f, 8.0f)
                    curveToRelative(0.0f, -1.1f, -0.9f, -2.0f, -2.0f, -2.0f)
                    close()
                    moveTo(20.0f, 18.0f)
                    lineTo(4.0f, 18.0f)
                    lineTo(4.0f, 8.0f)
                    horizontalLineToRelative(16.0f)
                    verticalLineToRelative(10.0f)
                    close()
                }
            }.also { _folderOpen = it }
        private var _grain: ImageVector? = null
        val Grain: ImageVector
            get() = _grain ?: materialIcon("Outlined.Grain", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(10.0f, 12.0f)
                    curveToRelative(-1.1f, 0.0f, -2.0f, 0.9f, -2.0f, 2.0f)
                    reflectiveCurveToRelative(0.9f, 2.0f, 2.0f, 2.0f)
                    reflectiveCurveToRelative(2.0f, -0.9f, 2.0f, -2.0f)
                    reflectiveCurveToRelative(-0.9f, -2.0f, -2.0f, -2.0f)
                    close()
                    moveTo(6.0f, 8.0f)
                    curveToRelative(-1.1f, 0.0f, -2.0f, 0.9f, -2.0f, 2.0f)
                    reflectiveCurveToRelative(0.9f, 2.0f, 2.0f, 2.0f)
                    reflectiveCurveToRelative(2.0f, -0.9f, 2.0f, -2.0f)
                    reflectiveCurveToRelative(-0.9f, -2.0f, -2.0f, -2.0f)
                    close()
                    moveTo(6.0f, 16.0f)
                    curveToRelative(-1.1f, 0.0f, -2.0f, 0.9f, -2.0f, 2.0f)
                    reflectiveCurveToRelative(0.9f, 2.0f, 2.0f, 2.0f)
                    reflectiveCurveToRelative(2.0f, -0.9f, 2.0f, -2.0f)
                    reflectiveCurveToRelative(-0.9f, -2.0f, -2.0f, -2.0f)
                    close()
                    moveTo(18.0f, 8.0f)
                    curveToRelative(1.1f, 0.0f, 2.0f, -0.9f, 2.0f, -2.0f)
                    reflectiveCurveToRelative(-0.9f, -2.0f, -2.0f, -2.0f)
                    reflectiveCurveToRelative(-2.0f, 0.9f, -2.0f, 2.0f)
                    reflectiveCurveToRelative(0.9f, 2.0f, 2.0f, 2.0f)
                    close()
                    moveTo(14.0f, 16.0f)
                    curveToRelative(-1.1f, 0.0f, -2.0f, 0.9f, -2.0f, 2.0f)
                    reflectiveCurveToRelative(0.9f, 2.0f, 2.0f, 2.0f)
                    reflectiveCurveToRelative(2.0f, -0.9f, 2.0f, -2.0f)
                    reflectiveCurveToRelative(-0.9f, -2.0f, -2.0f, -2.0f)
                    close()
                    moveTo(18.0f, 12.0f)
                    curveToRelative(-1.1f, 0.0f, -2.0f, 0.9f, -2.0f, 2.0f)
                    reflectiveCurveToRelative(0.9f, 2.0f, 2.0f, 2.0f)
                    reflectiveCurveToRelative(2.0f, -0.9f, 2.0f, -2.0f)
                    reflectiveCurveToRelative(-0.9f, -2.0f, -2.0f, -2.0f)
                    close()
                    moveTo(14.0f, 8.0f)
                    curveToRelative(-1.1f, 0.0f, -2.0f, 0.9f, -2.0f, 2.0f)
                    reflectiveCurveToRelative(0.9f, 2.0f, 2.0f, 2.0f)
                    reflectiveCurveToRelative(2.0f, -0.9f, 2.0f, -2.0f)
                    reflectiveCurveToRelative(-0.9f, -2.0f, -2.0f, -2.0f)
                    close()
                    moveTo(10.0f, 4.0f)
                    curveToRelative(-1.1f, 0.0f, -2.0f, 0.9f, -2.0f, 2.0f)
                    reflectiveCurveToRelative(0.9f, 2.0f, 2.0f, 2.0f)
                    reflectiveCurveToRelative(2.0f, -0.9f, 2.0f, -2.0f)
                    reflectiveCurveToRelative(-0.9f, -2.0f, -2.0f, -2.0f)
                    close()
                }
            }.also { _grain = it }
        private var _gridView: ImageVector? = null
        val GridView: ImageVector
            get() = _gridView ?: materialIcon("Outlined.GridView", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(3.0f, 3.0f)
                    verticalLineToRelative(8.0f)
                    horizontalLineToRelative(8.0f)
                    verticalLineTo(3.0f)
                    horizontalLineTo(3.0f)
                    close()
                    moveTo(9.0f, 9.0f)
                    horizontalLineTo(5.0f)
                    verticalLineTo(5.0f)
                    horizontalLineToRelative(4.0f)
                    verticalLineTo(9.0f)
                    close()
                    moveTo(3.0f, 13.0f)
                    verticalLineToRelative(8.0f)
                    horizontalLineToRelative(8.0f)
                    verticalLineToRelative(-8.0f)
                    horizontalLineTo(3.0f)
                    close()
                    moveTo(9.0f, 19.0f)
                    horizontalLineTo(5.0f)
                    verticalLineToRelative(-4.0f)
                    horizontalLineToRelative(4.0f)
                    verticalLineTo(19.0f)
                    close()
                    moveTo(13.0f, 3.0f)
                    verticalLineToRelative(8.0f)
                    horizontalLineToRelative(8.0f)
                    verticalLineTo(3.0f)
                    horizontalLineTo(13.0f)
                    close()
                    moveTo(19.0f, 9.0f)
                    horizontalLineToRelative(-4.0f)
                    verticalLineTo(5.0f)
                    horizontalLineToRelative(4.0f)
                    verticalLineTo(9.0f)
                    close()
                    moveTo(13.0f, 13.0f)
                    verticalLineToRelative(8.0f)
                    horizontalLineToRelative(8.0f)
                    verticalLineToRelative(-8.0f)
                    horizontalLineTo(13.0f)
                    close()
                    moveTo(19.0f, 19.0f)
                    horizontalLineToRelative(-4.0f)
                    verticalLineToRelative(-4.0f)
                    horizontalLineToRelative(4.0f)
                    verticalLineTo(19.0f)
                    close()
                }
            }.also { _gridView = it }
        private var _history: ImageVector? = null
        val History: ImageVector
            get() = _history ?: materialIcon("Outlined.History", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(13.0f, 3.0f)
                    curveToRelative(-4.97f, 0.0f, -9.0f, 4.03f, -9.0f, 9.0f)
                    lineTo(1.0f, 12.0f)
                    lineToRelative(3.89f, 3.89f)
                    lineToRelative(0.07f, 0.14f)
                    lineTo(9.0f, 12.0f)
                    lineTo(6.0f, 12.0f)
                    curveToRelative(0.0f, -3.87f, 3.13f, -7.0f, 7.0f, -7.0f)
                    reflectiveCurveToRelative(7.0f, 3.13f, 7.0f, 7.0f)
                    reflectiveCurveToRelative(-3.13f, 7.0f, -7.0f, 7.0f)
                    curveToRelative(-1.93f, 0.0f, -3.68f, -0.79f, -4.94f, -2.06f)
                    lineToRelative(-1.42f, 1.42f)
                    curveTo(8.27f, 19.99f, 10.51f, 21.0f, 13.0f, 21.0f)
                    curveToRelative(4.97f, 0.0f, 9.0f, -4.03f, 9.0f, -9.0f)
                    reflectiveCurveToRelative(-4.03f, -9.0f, -9.0f, -9.0f)
                    close()
                    moveTo(12.0f, 8.0f)
                    verticalLineToRelative(5.0f)
                    lineToRelative(4.25f, 2.52f)
                    lineToRelative(0.77f, -1.28f)
                    lineToRelative(-3.52f, -2.09f)
                    lineTo(13.5f, 8.0f)
                    close()
                }
            }.also { _history = it }
        private var _image: ImageVector? = null
        val Image: ImageVector
            get() = _image ?: materialIcon("Outlined.Image", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(19.0f, 5.0f)
                    verticalLineToRelative(14.0f)
                    lineTo(5.0f, 19.0f)
                    lineTo(5.0f, 5.0f)
                    horizontalLineToRelative(14.0f)
                    moveToRelative(0.0f, -2.0f)
                    lineTo(5.0f, 3.0f)
                    curveToRelative(-1.1f, 0.0f, -2.0f, 0.9f, -2.0f, 2.0f)
                    verticalLineToRelative(14.0f)
                    curveToRelative(0.0f, 1.1f, 0.9f, 2.0f, 2.0f, 2.0f)
                    horizontalLineToRelative(14.0f)
                    curveToRelative(1.1f, 0.0f, 2.0f, -0.9f, 2.0f, -2.0f)
                    lineTo(21.0f, 5.0f)
                    curveToRelative(0.0f, -1.1f, -0.9f, -2.0f, -2.0f, -2.0f)
                    close()
                    moveTo(14.14f, 11.86f)
                    lineToRelative(-3.0f, 3.87f)
                    lineTo(9.0f, 13.14f)
                    lineTo(6.0f, 17.0f)
                    horizontalLineToRelative(12.0f)
                    lineToRelative(-3.86f, -5.14f)
                    close()
                }
            }.also { _image = it }
        private var _layers: ImageVector? = null
        val Layers: ImageVector
            get() = _layers ?: materialIcon("Outlined.Layers", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(11.99f, 18.54f)
                    lineToRelative(-7.37f, -5.73f)
                    lineTo(3.0f, 14.07f)
                    lineToRelative(9.0f, 7.0f)
                    lineToRelative(9.0f, -7.0f)
                    lineToRelative(-1.63f, -1.27f)
                    close()
                    moveTo(12.0f, 16.0f)
                    lineToRelative(7.36f, -5.73f)
                    lineTo(21.0f, 9.0f)
                    lineToRelative(-9.0f, -7.0f)
                    lineToRelative(-9.0f, 7.0f)
                    lineToRelative(1.63f, 1.27f)
                    lineTo(12.0f, 16.0f)
                    close()
                    moveTo(12.0f, 4.53f)
                    lineTo(17.74f, 9.0f)
                    lineTo(12.0f, 13.47f)
                    lineTo(6.26f, 9.0f)
                    lineTo(12.0f, 4.53f)
                    close()
                }
            }.also { _layers = it }
        private var _moreHoriz: ImageVector? = null
        val MoreHoriz: ImageVector
            get() = _moreHoriz ?: materialIcon("Outlined.MoreHoriz", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(6.0f, 10.0f)
                    curveToRelative(-1.1f, 0.0f, -2.0f, 0.9f, -2.0f, 2.0f)
                    reflectiveCurveToRelative(0.9f, 2.0f, 2.0f, 2.0f)
                    reflectiveCurveToRelative(2.0f, -0.9f, 2.0f, -2.0f)
                    reflectiveCurveToRelative(-0.9f, -2.0f, -2.0f, -2.0f)
                    close()
                    moveTo(18.0f, 10.0f)
                    curveToRelative(-1.1f, 0.0f, -2.0f, 0.9f, -2.0f, 2.0f)
                    reflectiveCurveToRelative(0.9f, 2.0f, 2.0f, 2.0f)
                    reflectiveCurveToRelative(2.0f, -0.9f, 2.0f, -2.0f)
                    reflectiveCurveToRelative(-0.9f, -2.0f, -2.0f, -2.0f)
                    close()
                    moveTo(12.0f, 10.0f)
                    curveToRelative(-1.1f, 0.0f, -2.0f, 0.9f, -2.0f, 2.0f)
                    reflectiveCurveToRelative(0.9f, 2.0f, 2.0f, 2.0f)
                    reflectiveCurveToRelative(2.0f, -0.9f, 2.0f, -2.0f)
                    reflectiveCurveToRelative(-0.9f, -2.0f, -2.0f, -2.0f)
                    close()
                }
            }.also { _moreHoriz = it }
        private var _opacity: ImageVector? = null
        val Opacity: ImageVector
            get() = _opacity ?: materialIcon("Outlined.Opacity", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(17.66f, 8.0f)
                    lineTo(12.0f, 2.35f)
                    lineTo(6.34f, 8.0f)
                    curveTo(4.78f, 9.56f, 4.0f, 11.64f, 4.0f, 13.64f)
                    reflectiveCurveToRelative(0.78f, 4.11f, 2.34f, 5.67f)
                    reflectiveCurveToRelative(3.61f, 2.35f, 5.66f, 2.35f)
                    reflectiveCurveToRelative(4.1f, -0.79f, 5.66f, -2.35f)
                    reflectiveCurveTo(20.0f, 15.64f, 20.0f, 13.64f)
                    reflectiveCurveTo(19.22f, 9.56f, 17.66f, 8.0f)
                    close()
                    moveTo(6.0f, 14.0f)
                    curveToRelative(0.01f, -2.0f, 0.62f, -3.27f, 1.76f, -4.4f)
                    lineTo(12.0f, 5.27f)
                    lineToRelative(4.24f, 4.38f)
                    curveTo(17.38f, 10.77f, 17.99f, 12.0f, 18.0f, 14.0f)
                    horizontalLineTo(6.0f)
                    close()
                }
            }.also { _opacity = it }
        private var _palette: ImageVector? = null
        val Palette: ImageVector
            get() = _palette ?: materialIcon("Outlined.Palette", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(12.0f, 22.0f)
                    curveTo(6.49f, 22.0f, 2.0f, 17.51f, 2.0f, 12.0f)
                    reflectiveCurveTo(6.49f, 2.0f, 12.0f, 2.0f)
                    reflectiveCurveToRelative(10.0f, 4.04f, 10.0f, 9.0f)
                    curveToRelative(0.0f, 3.31f, -2.69f, 6.0f, -6.0f, 6.0f)
                    horizontalLineToRelative(-1.77f)
                    curveToRelative(-0.28f, 0.0f, -0.5f, 0.22f, -0.5f, 0.5f)
                    curveToRelative(0.0f, 0.12f, 0.05f, 0.23f, 0.13f, 0.33f)
                    curveToRelative(0.41f, 0.47f, 0.64f, 1.06f, 0.64f, 1.67f)
                    curveTo(14.5f, 20.88f, 13.38f, 22.0f, 12.0f, 22.0f)
                    close()
                    moveTo(12.0f, 4.0f)
                    curveToRelative(-4.41f, 0.0f, -8.0f, 3.59f, -8.0f, 8.0f)
                    reflectiveCurveToRelative(3.59f, 8.0f, 8.0f, 8.0f)
                    curveToRelative(0.28f, 0.0f, 0.5f, -0.22f, 0.5f, -0.5f)
                    curveToRelative(0.0f, -0.16f, -0.08f, -0.28f, -0.14f, -0.35f)
                    curveToRelative(-0.41f, -0.46f, -0.63f, -1.05f, -0.63f, -1.65f)
                    curveToRelative(0.0f, -1.38f, 1.12f, -2.5f, 2.5f, -2.5f)
                    horizontalLineTo(16.0f)
                    curveToRelative(2.21f, 0.0f, 4.0f, -1.79f, 4.0f, -4.0f)
                    curveTo(20.0f, 7.14f, 16.41f, 4.0f, 12.0f, 4.0f)
                    close()
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(6.5f, 11.5f)
                    moveToRelative(-1.5f, 0.0f)
                    arcToRelative(1.5f, 1.5f, 0.0f, true, true, 3.0f, 0.0f)
                    arcToRelative(1.5f, 1.5f, 0.0f, true, true, -3.0f, 0.0f)
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(9.5f, 7.5f)
                    moveToRelative(-1.5f, 0.0f)
                    arcToRelative(1.5f, 1.5f, 0.0f, true, true, 3.0f, 0.0f)
                    arcToRelative(1.5f, 1.5f, 0.0f, true, true, -3.0f, 0.0f)
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(14.5f, 7.5f)
                    moveToRelative(-1.5f, 0.0f)
                    arcToRelative(1.5f, 1.5f, 0.0f, true, true, 3.0f, 0.0f)
                    arcToRelative(1.5f, 1.5f, 0.0f, true, true, -3.0f, 0.0f)
                }
                path(fill = SolidColor(Color.Black)) {
                    moveTo(17.5f, 11.5f)
                    moveToRelative(-1.5f, 0.0f)
                    arcToRelative(1.5f, 1.5f, 0.0f, true, true, 3.0f, 0.0f)
                    arcToRelative(1.5f, 1.5f, 0.0f, true, true, -3.0f, 0.0f)
                }
            }.also { _palette = it }
        private var _photoCamera: ImageVector? = null
        val PhotoCamera: ImageVector
            get() = _photoCamera ?: materialIcon("Outlined.PhotoCamera", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(14.12f, 4.0f)
                    lineToRelative(1.83f, 2.0f)
                    lineTo(20.0f, 6.0f)
                    verticalLineToRelative(12.0f)
                    lineTo(4.0f, 18.0f)
                    lineTo(4.0f, 6.0f)
                    horizontalLineToRelative(4.05f)
                    lineToRelative(1.83f, -2.0f)
                    horizontalLineToRelative(4.24f)
                    moveTo(15.0f, 2.0f)
                    lineTo(9.0f, 2.0f)
                    lineTo(7.17f, 4.0f)
                    lineTo(4.0f, 4.0f)
                    curveToRelative(-1.1f, 0.0f, -2.0f, 0.9f, -2.0f, 2.0f)
                    verticalLineToRelative(12.0f)
                    curveToRelative(0.0f, 1.1f, 0.9f, 2.0f, 2.0f, 2.0f)
                    horizontalLineToRelative(16.0f)
                    curveToRelative(1.1f, 0.0f, 2.0f, -0.9f, 2.0f, -2.0f)
                    lineTo(22.0f, 6.0f)
                    curveToRelative(0.0f, -1.1f, -0.9f, -2.0f, -2.0f, -2.0f)
                    horizontalLineToRelative(-3.17f)
                    lineTo(15.0f, 2.0f)
                    close()
                    moveTo(12.0f, 9.0f)
                    curveToRelative(1.65f, 0.0f, 3.0f, 1.35f, 3.0f, 3.0f)
                    reflectiveCurveToRelative(-1.35f, 3.0f, -3.0f, 3.0f)
                    reflectiveCurveToRelative(-3.0f, -1.35f, -3.0f, -3.0f)
                    reflectiveCurveToRelative(1.35f, -3.0f, 3.0f, -3.0f)
                    moveToRelative(0.0f, -2.0f)
                    curveToRelative(-2.76f, 0.0f, -5.0f, 2.24f, -5.0f, 5.0f)
                    reflectiveCurveToRelative(2.24f, 5.0f, 5.0f, 5.0f)
                    reflectiveCurveToRelative(5.0f, -2.24f, 5.0f, -5.0f)
                    reflectiveCurveToRelative(-2.24f, -5.0f, -5.0f, -5.0f)
                    close()
                }
            }.also { _photoCamera = it }
        private var _photoFilter: ImageVector? = null
        val PhotoFilter: ImageVector
            get() = _photoFilter ?: materialIcon("Outlined.PhotoFilter", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(19.0f, 10.0f)
                    verticalLineToRelative(9.0f)
                    lineTo(4.98f, 19.0f)
                    lineTo(4.98f, 5.0f)
                    horizontalLineToRelative(9.0f)
                    lineTo(13.98f, 3.0f)
                    lineTo(5.0f, 3.0f)
                    curveToRelative(-1.1f, 0.0f, -2.0f, 0.9f, -2.0f, 2.0f)
                    verticalLineToRelative(14.0f)
                    curveToRelative(0.0f, 1.1f, 0.9f, 2.0f, 2.0f, 2.0f)
                    horizontalLineToRelative(14.0f)
                    curveToRelative(1.1f, 0.0f, 2.0f, -0.9f, 2.0f, -2.0f)
                    verticalLineToRelative(-9.0f)
                    horizontalLineToRelative(-2.0f)
                    close()
                    moveTo(16.06f, 7.94f)
                    lineTo(17.0f, 10.0f)
                    lineToRelative(0.94f, -2.06f)
                    lineTo(20.0f, 7.0f)
                    lineToRelative(-2.06f, -0.94f)
                    lineTo(17.0f, 4.0f)
                    lineToRelative(-0.94f, 2.06f)
                    lineTo(14.0f, 7.0f)
                    close()
                    moveTo(12.0f, 8.0f)
                    lineToRelative(-1.25f, 2.75f)
                    lineTo(8.0f, 12.0f)
                    lineToRelative(2.75f, 1.25f)
                    lineTo(12.0f, 16.0f)
                    lineToRelative(1.25f, -2.75f)
                    lineTo(16.0f, 12.0f)
                    lineToRelative(-2.75f, -1.25f)
                    close()
                }
            }.also { _photoFilter = it }
        private var _photoLibrary: ImageVector? = null
        val PhotoLibrary: ImageVector
            get() = _photoLibrary ?: materialIcon("Outlined.PhotoLibrary", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(20.0f, 4.0f)
                    verticalLineToRelative(12.0f)
                    lineTo(8.0f, 16.0f)
                    lineTo(8.0f, 4.0f)
                    horizontalLineToRelative(12.0f)
                    moveToRelative(0.0f, -2.0f)
                    lineTo(8.0f, 2.0f)
                    curveToRelative(-1.1f, 0.0f, -2.0f, 0.9f, -2.0f, 2.0f)
                    verticalLineToRelative(12.0f)
                    curveToRelative(0.0f, 1.1f, 0.9f, 2.0f, 2.0f, 2.0f)
                    horizontalLineToRelative(12.0f)
                    curveToRelative(1.1f, 0.0f, 2.0f, -0.9f, 2.0f, -2.0f)
                    lineTo(22.0f, 4.0f)
                    curveToRelative(0.0f, -1.1f, -0.9f, -2.0f, -2.0f, -2.0f)
                    close()
                    moveTo(11.5f, 11.67f)
                    lineToRelative(1.69f, 2.26f)
                    lineToRelative(2.48f, -3.1f)
                    lineTo(19.0f, 15.0f)
                    lineTo(9.0f, 15.0f)
                    close()
                    moveTo(2.0f, 6.0f)
                    verticalLineToRelative(14.0f)
                    curveToRelative(0.0f, 1.1f, 0.9f, 2.0f, 2.0f, 2.0f)
                    horizontalLineToRelative(14.0f)
                    verticalLineToRelative(-2.0f)
                    lineTo(4.0f, 20.0f)
                    lineTo(4.0f, 6.0f)
                    lineTo(2.0f, 6.0f)
                    close()
                }
            }.also { _photoLibrary = it }
        private var _radioButtonUnchecked: ImageVector? = null
        val RadioButtonUnchecked: ImageVector
            get() = _radioButtonUnchecked ?: materialIcon("Outlined.RadioButtonUnchecked", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(12.0f, 2.0f)
                    curveTo(6.48f, 2.0f, 2.0f, 6.48f, 2.0f, 12.0f)
                    reflectiveCurveToRelative(4.48f, 10.0f, 10.0f, 10.0f)
                    reflectiveCurveToRelative(10.0f, -4.48f, 10.0f, -10.0f)
                    reflectiveCurveTo(17.52f, 2.0f, 12.0f, 2.0f)
                    close()
                    moveTo(12.0f, 20.0f)
                    curveToRelative(-4.42f, 0.0f, -8.0f, -3.58f, -8.0f, -8.0f)
                    reflectiveCurveToRelative(3.58f, -8.0f, 8.0f, -8.0f)
                    reflectiveCurveToRelative(8.0f, 3.58f, 8.0f, 8.0f)
                    reflectiveCurveToRelative(-3.58f, 8.0f, -8.0f, 8.0f)
                    close()
                }
            }.also { _radioButtonUnchecked = it }
        private var _redo: ImageVector? = null
        val Redo: ImageVector
            get() = _redo ?: materialIcon("Outlined.Redo", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(18.4f, 10.6f)
                    curveTo(16.55f, 8.99f, 14.15f, 8.0f, 11.5f, 8.0f)
                    curveToRelative(-4.65f, 0.0f, -8.58f, 3.03f, -9.96f, 7.22f)
                    lineTo(3.9f, 16.0f)
                    curveToRelative(1.05f, -3.19f, 4.05f, -5.5f, 7.6f, -5.5f)
                    curveToRelative(1.95f, 0.0f, 3.73f, 0.72f, 5.12f, 1.88f)
                    lineTo(13.0f, 16.0f)
                    horizontalLineToRelative(9.0f)
                    verticalLineTo(7.0f)
                    lineToRelative(-3.6f, 3.6f)
                    close()
                }
            }.also { _redo = it }
        private var _restartAlt: ImageVector? = null
        val RestartAlt: ImageVector
            get() = _restartAlt ?: materialIcon("Outlined.RestartAlt", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(6.0f, 13.0f)
                    curveToRelative(0.0f, -1.65f, 0.67f, -3.15f, 1.76f, -4.24f)
                    lineTo(6.34f, 7.34f)
                    curveTo(4.9f, 8.79f, 4.0f, 10.79f, 4.0f, 13.0f)
                    curveToRelative(0.0f, 4.08f, 3.05f, 7.44f, 7.0f, 7.93f)
                    verticalLineToRelative(-2.02f)
                    curveTo(8.17f, 18.43f, 6.0f, 15.97f, 6.0f, 13.0f)
                    close()
                    moveTo(20.0f, 13.0f)
                    curveToRelative(0.0f, -4.42f, -3.58f, -8.0f, -8.0f, -8.0f)
                    curveToRelative(-0.06f, 0.0f, -0.12f, 0.01f, -0.18f, 0.01f)
                    lineToRelative(1.09f, -1.09f)
                    lineTo(11.5f, 2.5f)
                    lineTo(8.0f, 6.0f)
                    lineToRelative(3.5f, 3.5f)
                    lineToRelative(1.41f, -1.41f)
                    lineToRelative(-1.08f, -1.08f)
                    curveTo(11.89f, 7.01f, 11.95f, 7.0f, 12.0f, 7.0f)
                    curveToRelative(3.31f, 0.0f, 6.0f, 2.69f, 6.0f, 6.0f)
                    curveToRelative(0.0f, 2.97f, -2.17f, 5.43f, -5.0f, 5.91f)
                    verticalLineToRelative(2.02f)
                    curveTo(16.95f, 20.44f, 20.0f, 17.08f, 20.0f, 13.0f)
                    close()
                }
            }.also { _restartAlt = it }
        private var _rotateLeft: ImageVector? = null
        val RotateLeft: ImageVector
            get() = _rotateLeft ?: materialIcon("Outlined.RotateLeft", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(7.11f, 8.53f)
                    lineTo(5.7f, 7.11f)
                    curveTo(4.8f, 8.27f, 4.24f, 9.61f, 4.07f, 11.0f)
                    horizontalLineToRelative(2.02f)
                    curveToRelative(0.14f, -0.87f, 0.49f, -1.72f, 1.02f, -2.47f)
                    close()
                    moveTo(6.09f, 13.0f)
                    lineTo(4.07f, 13.0f)
                    curveToRelative(0.17f, 1.39f, 0.72f, 2.73f, 1.62f, 3.89f)
                    lineToRelative(1.41f, -1.42f)
                    curveToRelative(-0.52f, -0.75f, -0.87f, -1.59f, -1.01f, -2.47f)
                    close()
                    moveTo(7.1f, 18.32f)
                    curveToRelative(1.16f, 0.9f, 2.51f, 1.44f, 3.9f, 1.61f)
                    lineTo(11.0f, 17.9f)
                    curveToRelative(-0.87f, -0.15f, -1.71f, -0.49f, -2.46f, -1.03f)
                    lineTo(7.1f, 18.32f)
                    close()
                    moveTo(13.0f, 4.07f)
                    lineTo(13.0f, 1.0f)
                    lineTo(8.45f, 5.55f)
                    lineTo(13.0f, 10.0f)
                    lineTo(13.0f, 6.09f)
                    curveToRelative(2.84f, 0.48f, 5.0f, 2.94f, 5.0f, 5.91f)
                    reflectiveCurveToRelative(-2.16f, 5.43f, -5.0f, 5.91f)
                    verticalLineToRelative(2.02f)
                    curveToRelative(3.95f, -0.49f, 7.0f, -3.85f, 7.0f, -7.93f)
                    reflectiveCurveToRelative(-3.05f, -7.44f, -7.0f, -7.93f)
                    close()
                }
            }.also { _rotateLeft = it }
        private var _rotateRight: ImageVector? = null
        val RotateRight: ImageVector
            get() = _rotateRight ?: materialIcon("Outlined.RotateRight", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(15.55f, 5.55f)
                    lineTo(11.0f, 1.0f)
                    verticalLineToRelative(3.07f)
                    curveTo(7.06f, 4.56f, 4.0f, 7.92f, 4.0f, 12.0f)
                    reflectiveCurveToRelative(3.05f, 7.44f, 7.0f, 7.93f)
                    verticalLineToRelative(-2.02f)
                    curveToRelative(-2.84f, -0.48f, -5.0f, -2.94f, -5.0f, -5.91f)
                    reflectiveCurveToRelative(2.16f, -5.43f, 5.0f, -5.91f)
                    lineTo(11.0f, 10.0f)
                    lineToRelative(4.55f, -4.45f)
                    close()
                    moveTo(19.93f, 11.0f)
                    curveToRelative(-0.17f, -1.39f, -0.72f, -2.73f, -1.62f, -3.89f)
                    lineToRelative(-1.42f, 1.42f)
                    curveToRelative(0.54f, 0.75f, 0.88f, 1.6f, 1.02f, 2.47f)
                    horizontalLineToRelative(2.02f)
                    close()
                    moveTo(13.0f, 17.9f)
                    verticalLineToRelative(2.02f)
                    curveToRelative(1.39f, -0.17f, 2.74f, -0.71f, 3.9f, -1.61f)
                    lineToRelative(-1.44f, -1.44f)
                    curveToRelative(-0.75f, 0.54f, -1.59f, 0.89f, -2.46f, 1.03f)
                    close()
                    moveTo(16.89f, 15.48f)
                    lineToRelative(1.42f, 1.41f)
                    curveToRelative(0.9f, -1.16f, 1.45f, -2.5f, 1.62f, -3.89f)
                    horizontalLineToRelative(-2.02f)
                    curveToRelative(-0.14f, 0.87f, -0.48f, 1.72f, -1.02f, 2.48f)
                    close()
                }
            }.also { _rotateRight = it }
        private var _saveAlt: ImageVector? = null
        val SaveAlt: ImageVector
            get() = _saveAlt ?: materialIcon("Outlined.SaveAlt", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(19.0f, 12.0f)
                    verticalLineToRelative(7.0f)
                    lineTo(5.0f, 19.0f)
                    verticalLineToRelative(-7.0f)
                    lineTo(3.0f, 12.0f)
                    verticalLineToRelative(7.0f)
                    curveToRelative(0.0f, 1.1f, 0.9f, 2.0f, 2.0f, 2.0f)
                    horizontalLineToRelative(14.0f)
                    curveToRelative(1.1f, 0.0f, 2.0f, -0.9f, 2.0f, -2.0f)
                    verticalLineToRelative(-7.0f)
                    horizontalLineToRelative(-2.0f)
                    close()
                    moveTo(13.0f, 12.67f)
                    lineToRelative(2.59f, -2.58f)
                    lineTo(17.0f, 11.5f)
                    lineToRelative(-5.0f, 5.0f)
                    lineToRelative(-5.0f, -5.0f)
                    lineToRelative(1.41f, -1.41f)
                    lineTo(11.0f, 12.67f)
                    lineTo(11.0f, 3.0f)
                    horizontalLineToRelative(2.0f)
                    verticalLineToRelative(9.67f)
                    close()
                }
            }.also { _saveAlt = it }
        private var _settingsBackupRestore: ImageVector? = null
        val SettingsBackupRestore: ImageVector
            get() = _settingsBackupRestore ?: materialIcon("Outlined.SettingsBackupRestore", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(14.0f, 12.0f)
                    curveToRelative(0.0f, -1.1f, -0.9f, -2.0f, -2.0f, -2.0f)
                    reflectiveCurveToRelative(-2.0f, 0.9f, -2.0f, 2.0f)
                    reflectiveCurveToRelative(0.9f, 2.0f, 2.0f, 2.0f)
                    reflectiveCurveToRelative(2.0f, -0.9f, 2.0f, -2.0f)
                    close()
                    moveTo(12.0f, 3.0f)
                    curveToRelative(-4.97f, 0.0f, -9.0f, 4.03f, -9.0f, 9.0f)
                    lineTo(0.0f, 12.0f)
                    lineToRelative(4.0f, 4.0f)
                    lineToRelative(4.0f, -4.0f)
                    lineTo(5.0f, 12.0f)
                    curveToRelative(0.0f, -3.87f, 3.13f, -7.0f, 7.0f, -7.0f)
                    reflectiveCurveToRelative(7.0f, 3.13f, 7.0f, 7.0f)
                    reflectiveCurveToRelative(-3.13f, 7.0f, -7.0f, 7.0f)
                    curveToRelative(-1.51f, 0.0f, -2.91f, -0.49f, -4.06f, -1.3f)
                    lineToRelative(-1.42f, 1.44f)
                    curveTo(8.04f, 20.3f, 9.94f, 21.0f, 12.0f, 21.0f)
                    curveToRelative(4.97f, 0.0f, 9.0f, -4.03f, 9.0f, -9.0f)
                    reflectiveCurveToRelative(-4.03f, -9.0f, -9.0f, -9.0f)
                    close()
                }
            }.also { _settingsBackupRestore = it }
        private var _ssidChart: ImageVector? = null
        val SsidChart: ImageVector
            get() = _ssidChart ?: materialIcon("Outlined.SsidChart", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(21.0f, 5.47f)
                    lineTo(12.0f, 12.0f)
                    lineTo(7.62f, 7.62f)
                    lineTo(3.0f, 11.0f)
                    verticalLineTo(8.52f)
                    lineTo(7.83f, 5.0f)
                    lineToRelative(4.38f, 4.38f)
                    lineTo(21.0f, 3.0f)
                    lineTo(21.0f, 5.47f)
                    close()
                    moveTo(21.0f, 15.0f)
                    horizontalLineToRelative(-4.7f)
                    lineToRelative(-4.17f, 3.34f)
                    lineTo(6.0f, 12.41f)
                    lineToRelative(-3.0f, 2.13f)
                    lineTo(3.0f, 17.0f)
                    lineToRelative(2.8f, -2.0f)
                    lineToRelative(6.2f, 6.0f)
                    lineToRelative(5.0f, -4.0f)
                    horizontalLineToRelative(4.0f)
                    verticalLineTo(15.0f)
                    close()
                }
            }.also { _ssidChart = it }
        private var _swapHoriz: ImageVector? = null
        val SwapHoriz: ImageVector
            get() = _swapHoriz ?: materialIcon("Outlined.SwapHoriz", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(6.99f, 11.0f)
                    lineTo(3.0f, 15.0f)
                    lineToRelative(3.99f, 4.0f)
                    verticalLineToRelative(-3.0f)
                    horizontalLineTo(14.0f)
                    verticalLineToRelative(-2.0f)
                    horizontalLineTo(6.99f)
                    verticalLineToRelative(-3.0f)
                    close()
                    moveTo(21.0f, 9.0f)
                    lineToRelative(-3.99f, -4.0f)
                    verticalLineToRelative(3.0f)
                    horizontalLineTo(10.0f)
                    verticalLineToRelative(2.0f)
                    horizontalLineToRelative(7.01f)
                    verticalLineToRelative(3.0f)
                    lineTo(21.0f, 9.0f)
                    close()
                }
            }.also { _swapHoriz = it }
        private var _systemUpdate: ImageVector? = null
        val SystemUpdate: ImageVector
            get() = _systemUpdate ?: materialIcon("Outlined.SystemUpdate", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(17.0f, 1.01f)
                    lineTo(7.0f, 1.0f)
                    curveToRelative(-1.1f, 0.0f, -2.0f, 0.9f, -2.0f, 2.0f)
                    verticalLineToRelative(18.0f)
                    curveToRelative(0.0f, 1.1f, 0.9f, 2.0f, 2.0f, 2.0f)
                    horizontalLineToRelative(10.0f)
                    curveToRelative(1.1f, 0.0f, 2.0f, -0.9f, 2.0f, -2.0f)
                    lineTo(19.0f, 3.0f)
                    curveToRelative(0.0f, -1.1f, -0.9f, -1.99f, -2.0f, -1.99f)
                    close()
                    moveTo(17.0f, 19.0f)
                    lineTo(7.0f, 19.0f)
                    lineTo(7.0f, 5.0f)
                    horizontalLineToRelative(10.0f)
                    verticalLineToRelative(14.0f)
                    close()
                    moveTo(16.0f, 13.0f)
                    horizontalLineToRelative(-3.0f)
                    lineTo(13.0f, 8.0f)
                    horizontalLineToRelative(-2.0f)
                    verticalLineToRelative(5.0f)
                    lineTo(8.0f, 13.0f)
                    lineToRelative(4.0f, 4.0f)
                    lineToRelative(4.0f, -4.0f)
                    close()
                }
            }.also { _systemUpdate = it }
        private var _thermostat: ImageVector? = null
        val Thermostat: ImageVector
            get() = _thermostat ?: materialIcon("Outlined.Thermostat", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(15.0f, 13.0f)
                    lineTo(15.0f, 5.0f)
                    curveToRelative(0.0f, -1.66f, -1.34f, -3.0f, -3.0f, -3.0f)
                    reflectiveCurveTo(9.0f, 3.34f, 9.0f, 5.0f)
                    verticalLineToRelative(8.0f)
                    curveToRelative(-1.21f, 0.91f, -2.0f, 2.37f, -2.0f, 4.0f)
                    curveToRelative(0.0f, 2.76f, 2.24f, 5.0f, 5.0f, 5.0f)
                    reflectiveCurveToRelative(5.0f, -2.24f, 5.0f, -5.0f)
                    curveToRelative(0.0f, -1.63f, -0.79f, -3.09f, -2.0f, -4.0f)
                    close()
                    moveTo(11.0f, 5.0f)
                    curveToRelative(0.0f, -0.55f, 0.45f, -1.0f, 1.0f, -1.0f)
                    reflectiveCurveToRelative(1.0f, 0.45f, 1.0f, 1.0f)
                    horizontalLineToRelative(-1.0f)
                    verticalLineToRelative(1.0f)
                    horizontalLineToRelative(1.0f)
                    verticalLineToRelative(2.0f)
                    horizontalLineToRelative(-1.0f)
                    verticalLineToRelative(1.0f)
                    horizontalLineToRelative(1.0f)
                    verticalLineToRelative(2.0f)
                    horizontalLineToRelative(-2.0f)
                    lineTo(11.0f, 5.0f)
                    close()
                }
            }.also { _thermostat = it }
        private var _tonality: ImageVector? = null
        val Tonality: ImageVector
            get() = _tonality ?: materialIcon("Outlined.Tonality", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(12.0f, 2.0f)
                    curveTo(6.48f, 2.0f, 2.0f, 6.48f, 2.0f, 12.0f)
                    reflectiveCurveToRelative(4.48f, 10.0f, 10.0f, 10.0f)
                    reflectiveCurveToRelative(10.0f, -4.48f, 10.0f, -10.0f)
                    reflectiveCurveTo(17.52f, 2.0f, 12.0f, 2.0f)
                    close()
                    moveTo(11.0f, 19.93f)
                    curveToRelative(-3.94f, -0.49f, -7.0f, -3.85f, -7.0f, -7.93f)
                    reflectiveCurveToRelative(3.05f, -7.44f, 7.0f, -7.93f)
                    verticalLineToRelative(15.86f)
                    close()
                    moveTo(13.0f, 4.07f)
                    curveToRelative(1.03f, 0.13f, 2.0f, 0.45f, 2.87f, 0.93f)
                    lineTo(13.0f, 5.0f)
                    verticalLineToRelative(-0.93f)
                    close()
                    moveTo(13.0f, 7.0f)
                    horizontalLineToRelative(5.24f)
                    curveToRelative(0.25f, 0.31f, 0.48f, 0.65f, 0.68f, 1.0f)
                    lineTo(13.0f, 8.0f)
                    lineTo(13.0f, 7.0f)
                    close()
                    moveTo(13.0f, 10.0f)
                    horizontalLineToRelative(6.74f)
                    curveToRelative(0.08f, 0.33f, 0.15f, 0.66f, 0.19f, 1.0f)
                    lineTo(13.0f, 11.0f)
                    verticalLineToRelative(-1.0f)
                    close()
                    moveTo(13.0f, 19.93f)
                    lineTo(13.0f, 19.0f)
                    horizontalLineToRelative(2.87f)
                    curveToRelative(-0.87f, 0.48f, -1.84f, 0.8f, -2.87f, 0.93f)
                    close()
                    moveTo(18.24f, 17.0f)
                    lineTo(13.0f, 17.0f)
                    verticalLineToRelative(-1.0f)
                    horizontalLineToRelative(5.92f)
                    curveToRelative(-0.2f, 0.35f, -0.43f, 0.69f, -0.68f, 1.0f)
                    close()
                    moveTo(19.74f, 14.0f)
                    lineTo(13.0f, 14.0f)
                    verticalLineToRelative(-1.0f)
                    horizontalLineToRelative(6.93f)
                    curveToRelative(-0.04f, 0.34f, -0.11f, 0.67f, -0.19f, 1.0f)
                    close()
                }
            }.also { _tonality = it }
        private var _transform: ImageVector? = null
        val Transform: ImageVector
            get() = _transform ?: materialIcon("Outlined.Transform", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(22.0f, 18.0f)
                    verticalLineToRelative(-2.0f)
                    horizontalLineTo(8.0f)
                    verticalLineTo(4.0f)
                    horizontalLineToRelative(2.0f)
                    lineTo(7.0f, 1.0f)
                    lineTo(4.0f, 4.0f)
                    horizontalLineToRelative(2.0f)
                    verticalLineToRelative(2.0f)
                    horizontalLineTo(2.0f)
                    verticalLineToRelative(2.0f)
                    horizontalLineToRelative(4.0f)
                    verticalLineToRelative(8.0f)
                    curveToRelative(0.0f, 1.1f, 0.9f, 2.0f, 2.0f, 2.0f)
                    horizontalLineToRelative(8.0f)
                    verticalLineToRelative(2.0f)
                    horizontalLineToRelative(-2.0f)
                    lineToRelative(3.0f, 3.0f)
                    lineToRelative(3.0f, -3.0f)
                    horizontalLineToRelative(-2.0f)
                    verticalLineToRelative(-2.0f)
                    horizontalLineToRelative(4.0f)
                    close()
                    moveTo(10.0f, 8.0f)
                    horizontalLineToRelative(6.0f)
                    verticalLineToRelative(6.0f)
                    horizontalLineToRelative(2.0f)
                    verticalLineTo(8.0f)
                    curveToRelative(0.0f, -1.1f, -0.9f, -2.0f, -2.0f, -2.0f)
                    horizontalLineToRelative(-6.0f)
                    verticalLineToRelative(2.0f)
                    close()
                }
            }.also { _transform = it }
        private var _tune: ImageVector? = null
        val Tune: ImageVector
            get() = _tune ?: materialIcon("Outlined.Tune", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(3.0f, 17.0f)
                    verticalLineToRelative(2.0f)
                    horizontalLineToRelative(6.0f)
                    verticalLineToRelative(-2.0f)
                    lineTo(3.0f, 17.0f)
                    close()
                    moveTo(3.0f, 5.0f)
                    verticalLineToRelative(2.0f)
                    horizontalLineToRelative(10.0f)
                    lineTo(13.0f, 5.0f)
                    lineTo(3.0f, 5.0f)
                    close()
                    moveTo(13.0f, 21.0f)
                    verticalLineToRelative(-2.0f)
                    horizontalLineToRelative(8.0f)
                    verticalLineToRelative(-2.0f)
                    horizontalLineToRelative(-8.0f)
                    verticalLineToRelative(-2.0f)
                    horizontalLineToRelative(-2.0f)
                    verticalLineToRelative(6.0f)
                    horizontalLineToRelative(2.0f)
                    close()
                    moveTo(7.0f, 9.0f)
                    verticalLineToRelative(2.0f)
                    lineTo(3.0f, 11.0f)
                    verticalLineToRelative(2.0f)
                    horizontalLineToRelative(4.0f)
                    verticalLineToRelative(2.0f)
                    horizontalLineToRelative(2.0f)
                    lineTo(9.0f, 9.0f)
                    lineTo(7.0f, 9.0f)
                    close()
                    moveTo(21.0f, 13.0f)
                    verticalLineToRelative(-2.0f)
                    lineTo(11.0f, 11.0f)
                    verticalLineToRelative(2.0f)
                    horizontalLineToRelative(10.0f)
                    close()
                    moveTo(15.0f, 9.0f)
                    horizontalLineToRelative(2.0f)
                    lineTo(17.0f, 7.0f)
                    horizontalLineToRelative(4.0f)
                    lineTo(21.0f, 5.0f)
                    horizontalLineToRelative(-4.0f)
                    lineTo(17.0f, 3.0f)
                    horizontalLineToRelative(-2.0f)
                    verticalLineToRelative(6.0f)
                    close()
                }
            }.also { _tune = it }
        private var _undo: ImageVector? = null
        val Undo: ImageVector
            get() = _undo ?: materialIcon("Outlined.Undo", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(12.5f, 8.0f)
                    curveToRelative(-2.65f, 0.0f, -5.05f, 0.99f, -6.9f, 2.6f)
                    lineTo(2.0f, 7.0f)
                    verticalLineToRelative(9.0f)
                    horizontalLineToRelative(9.0f)
                    lineToRelative(-3.62f, -3.62f)
                    curveToRelative(1.39f, -1.16f, 3.16f, -1.88f, 5.12f, -1.88f)
                    curveToRelative(3.54f, 0.0f, 6.55f, 2.31f, 7.6f, 5.5f)
                    lineToRelative(2.37f, -0.78f)
                    curveTo(21.08f, 11.03f, 17.15f, 8.0f, 12.5f, 8.0f)
                    close()
                }
            }.also { _undo = it }
        private var _waterDrop: ImageVector? = null
        val WaterDrop: ImageVector
            get() = _waterDrop ?: materialIcon("Outlined.WaterDrop", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(12.0f, 2.0f)
                    curveToRelative(-5.33f, 4.55f, -8.0f, 8.48f, -8.0f, 11.8f)
                    curveToRelative(0.0f, 4.98f, 3.8f, 8.2f, 8.0f, 8.2f)
                    reflectiveCurveToRelative(8.0f, -3.22f, 8.0f, -8.2f)
                    curveTo(20.0f, 10.48f, 17.33f, 6.55f, 12.0f, 2.0f)
                    close()
                    moveTo(12.0f, 20.0f)
                    curveToRelative(-3.35f, 0.0f, -6.0f, -2.57f, -6.0f, -6.2f)
                    curveToRelative(0.0f, -2.34f, 1.95f, -5.44f, 6.0f, -9.14f)
                    curveToRelative(4.05f, 3.7f, 6.0f, 6.79f, 6.0f, 9.14f)
                    curveTo(18.0f, 17.43f, 15.35f, 20.0f, 12.0f, 20.0f)
                    close()
                    moveTo(7.83f, 14.0f)
                    curveToRelative(0.37f, 0.0f, 0.67f, 0.26f, 0.74f, 0.62f)
                    curveToRelative(0.41f, 2.22f, 2.28f, 2.98f, 3.64f, 2.87f)
                    curveToRelative(0.43f, -0.02f, 0.79f, 0.32f, 0.79f, 0.75f)
                    curveToRelative(0.0f, 0.4f, -0.32f, 0.73f, -0.72f, 0.75f)
                    curveToRelative(-2.13f, 0.13f, -4.62f, -1.09f, -5.19f, -4.12f)
                    curveTo(7.01f, 14.42f, 7.37f, 14.0f, 7.83f, 14.0f)
                    close()
                }
            }.also { _waterDrop = it }
        private var _wbSunny: ImageVector? = null
        val WbSunny: ImageVector
            get() = _wbSunny ?: materialIcon("Outlined.WbSunny", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(6.76f, 4.84f)
                    lineToRelative(-1.8f, -1.79f)
                    lineToRelative(-1.41f, 1.41f)
                    lineToRelative(1.79f, 1.79f)
                    close()
                    moveTo(1.0f, 10.5f)
                    horizontalLineToRelative(3.0f)
                    verticalLineToRelative(2.0f)
                    lineTo(1.0f, 12.5f)
                    close()
                    moveTo(11.0f, 0.55f)
                    horizontalLineToRelative(2.0f)
                    lineTo(13.0f, 3.5f)
                    horizontalLineToRelative(-2.0f)
                    close()
                    moveTo(19.04f, 3.045f)
                    lineToRelative(1.408f, 1.407f)
                    lineToRelative(-1.79f, 1.79f)
                    lineToRelative(-1.407f, -1.408f)
                    close()
                    moveTo(17.24f, 18.16f)
                    lineToRelative(1.79f, 1.8f)
                    lineToRelative(1.41f, -1.41f)
                    lineToRelative(-1.8f, -1.79f)
                    close()
                    moveTo(20.0f, 10.5f)
                    horizontalLineToRelative(3.0f)
                    verticalLineToRelative(2.0f)
                    horizontalLineToRelative(-3.0f)
                    close()
                    moveTo(12.0f, 5.5f)
                    curveToRelative(-3.31f, 0.0f, -6.0f, 2.69f, -6.0f, 6.0f)
                    reflectiveCurveToRelative(2.69f, 6.0f, 6.0f, 6.0f)
                    reflectiveCurveToRelative(6.0f, -2.69f, 6.0f, -6.0f)
                    reflectiveCurveToRelative(-2.69f, -6.0f, -6.0f, -6.0f)
                    close()
                    moveTo(12.0f, 15.5f)
                    curveToRelative(-2.21f, 0.0f, -4.0f, -1.79f, -4.0f, -4.0f)
                    reflectiveCurveToRelative(1.79f, -4.0f, 4.0f, -4.0f)
                    reflectiveCurveToRelative(4.0f, 1.79f, 4.0f, 4.0f)
                    reflectiveCurveToRelative(-1.79f, 4.0f, -4.0f, 4.0f)
                    close()
                    moveTo(11.0f, 19.5f)
                    horizontalLineToRelative(2.0f)
                    verticalLineToRelative(2.95f)
                    horizontalLineToRelative(-2.0f)
                    close()
                    moveTo(3.55f, 18.54f)
                    lineToRelative(1.41f, 1.41f)
                    lineToRelative(1.79f, -1.8f)
                    lineToRelative(-1.41f, -1.41f)
                    close()
                }
            }.also { _wbSunny = it }
        private var _zoomIn: ImageVector? = null
        val ZoomIn: ImageVector
            get() = _zoomIn ?: materialIcon("Outlined.ZoomIn", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(15.5f, 14.0f)
                    horizontalLineToRelative(-0.79f)
                    lineToRelative(-0.28f, -0.27f)
                    curveTo(15.41f, 12.59f, 16.0f, 11.11f, 16.0f, 9.5f)
                    curveTo(16.0f, 5.91f, 13.09f, 3.0f, 9.5f, 3.0f)
                    reflectiveCurveTo(3.0f, 5.91f, 3.0f, 9.5f)
                    reflectiveCurveTo(5.91f, 16.0f, 9.5f, 16.0f)
                    curveToRelative(1.61f, 0.0f, 3.09f, -0.59f, 4.23f, -1.57f)
                    lineToRelative(0.27f, 0.28f)
                    verticalLineToRelative(0.79f)
                    lineToRelative(5.0f, 4.99f)
                    lineTo(20.49f, 19.0f)
                    lineToRelative(-4.99f, -5.0f)
                    close()
                    moveTo(9.5f, 14.0f)
                    curveTo(7.01f, 14.0f, 5.0f, 11.99f, 5.0f, 9.5f)
                    reflectiveCurveTo(7.01f, 5.0f, 9.5f, 5.0f)
                    reflectiveCurveTo(14.0f, 7.01f, 14.0f, 9.5f)
                    reflectiveCurveTo(11.99f, 14.0f, 9.5f, 14.0f)
                    close()
                    moveTo(10.0f, 7.0f)
                    lineTo(9.0f, 7.0f)
                    verticalLineToRelative(2.0f)
                    lineTo(7.0f, 9.0f)
                    verticalLineToRelative(1.0f)
                    horizontalLineToRelative(2.0f)
                    verticalLineToRelative(2.0f)
                    horizontalLineToRelative(1.0f)
                    verticalLineToRelative(-2.0f)
                    horizontalLineToRelative(2.0f)
                    lineTo(12.0f, 9.0f)
                    horizontalLineToRelative(-2.0f)
                    close()
                }
            }.also { _zoomIn = it }
    }

    object Filled {
        private var _circle: ImageVector? = null
        val Circle: ImageVector
            get() = _circle ?: materialIcon("Filled.Circle", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(12.0f, 2.0f)
                    curveTo(6.47f, 2.0f, 2.0f, 6.47f, 2.0f, 12.0f)
                    reflectiveCurveToRelative(4.47f, 10.0f, 10.0f, 10.0f)
                    reflectiveCurveToRelative(10.0f, -4.47f, 10.0f, -10.0f)
                    reflectiveCurveTo(17.53f, 2.0f, 12.0f, 2.0f)
                    close()
                }
            }.also { _circle = it }
        private var _waterDrop: ImageVector? = null
        val WaterDrop: ImageVector
            get() = _waterDrop ?: materialIcon("Filled.WaterDrop", autoMirrored = false) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(12.0f, 2.0f)
                    curveToRelative(-5.33f, 4.55f, -8.0f, 8.48f, -8.0f, 11.8f)
                    curveToRelative(0.0f, 4.98f, 3.8f, 8.2f, 8.0f, 8.2f)
                    reflectiveCurveToRelative(8.0f, -3.22f, 8.0f, -8.2f)
                    curveTo(20.0f, 10.48f, 17.33f, 6.55f, 12.0f, 2.0f)
                    close()
                    moveTo(7.83f, 14.0f)
                    curveToRelative(0.37f, 0.0f, 0.67f, 0.26f, 0.74f, 0.62f)
                    curveToRelative(0.41f, 2.22f, 2.28f, 2.98f, 3.64f, 2.87f)
                    curveToRelative(0.43f, -0.02f, 0.79f, 0.32f, 0.79f, 0.75f)
                    curveToRelative(0.0f, 0.4f, -0.32f, 0.73f, -0.72f, 0.75f)
                    curveToRelative(-2.13f, 0.13f, -4.62f, -1.09f, -5.19f, -4.12f)
                    curveTo(7.01f, 14.42f, 7.37f, 14.0f, 7.83f, 14.0f)
                    close()
                }
            }.also { _waterDrop = it }
    }

    object AutoMirrored {
        object Outlined {
        private var _navigateBefore: ImageVector? = null
        val NavigateBefore: ImageVector
            get() = _navigateBefore ?: materialIcon("AutoMirrored.Outlined.NavigateBefore", autoMirrored = true) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(15.61f, 7.41f)
                    lineTo(14.2f, 6.0f)
                    lineToRelative(-6.0f, 6.0f)
                    lineToRelative(6.0f, 6.0f)
                    lineToRelative(1.41f, -1.41f)
                    lineTo(11.03f, 12.0f)
                    lineToRelative(4.58f, -4.59f)
                    close()
                }
            }.also { _navigateBefore = it }
        private var _navigateNext: ImageVector? = null
        val NavigateNext: ImageVector
            get() = _navigateNext ?: materialIcon("AutoMirrored.Outlined.NavigateNext", autoMirrored = true) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(10.02f, 6.0f)
                    lineTo(8.61f, 7.41f)
                    lineTo(13.19f, 12.0f)
                    lineToRelative(-4.58f, 4.59f)
                    lineTo(10.02f, 18.0f)
                    lineToRelative(6.0f, -6.0f)
                    lineToRelative(-6.0f, -6.0f)
                    close()
                }
            }.also { _navigateNext = it }
        private var _openInNew: ImageVector? = null
        val OpenInNew: ImageVector
            get() = _openInNew ?: materialIcon("AutoMirrored.Outlined.OpenInNew", autoMirrored = true) {
                path(fill = SolidColor(Color.Black)) {
                    moveTo(19.0f, 19.0f)
                    horizontalLineTo(5.0f)
                    verticalLineTo(5.0f)
                    horizontalLineToRelative(7.0f)
                    verticalLineTo(3.0f)
                    horizontalLineTo(5.0f)
                    curveToRelative(-1.11f, 0.0f, -2.0f, 0.9f, -2.0f, 2.0f)
                    verticalLineToRelative(14.0f)
                    curveToRelative(0.0f, 1.1f, 0.89f, 2.0f, 2.0f, 2.0f)
                    horizontalLineToRelative(14.0f)
                    curveToRelative(1.1f, 0.0f, 2.0f, -0.9f, 2.0f, -2.0f)
                    verticalLineToRelative(-7.0f)
                    horizontalLineToRelative(-2.0f)
                    verticalLineToRelative(7.0f)
                    close()
                    moveTo(14.0f, 3.0f)
                    verticalLineToRelative(2.0f)
                    horizontalLineToRelative(3.59f)
                    lineToRelative(-9.83f, 9.83f)
                    lineToRelative(1.41f, 1.41f)
                    lineTo(19.0f, 6.41f)
                    verticalLineTo(10.0f)
                    horizontalLineToRelative(2.0f)
                    verticalLineTo(3.0f)
                    horizontalLineToRelative(-7.0f)
                    close()
                }
            }.also { _openInNew = it }
        }
    }

    private inline fun materialIcon(
        name: String,
        autoMirrored: Boolean = false,
        block: ImageVector.Builder.() -> ImageVector.Builder,
    ): ImageVector = ImageVector.Builder(
        name = name,
        defaultWidth = 24.dp,
        defaultHeight = 24.dp,
        viewportWidth = 24f,
        viewportHeight = 24f,
        autoMirror = autoMirrored,
    ).block().build()
}
