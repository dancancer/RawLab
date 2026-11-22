package com.rawlab.android.editor.inspection

import com.rawlab.android.geometry.GeometrySettings
import java.util.Locale
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

enum class InspectionOverlayMode {
    NONE,
    SKETCH_LUMINANCE,
    WARM_COOL_BW,
    OVERSATURATION_HEATMAP,
    SKIN_HUE_AMPLIFICATION,
    NEUTRAL_GRAY_50;

    val isActive: Boolean get() = this != NONE
}

data class InspectionColorSample(
    val r: Int,
    val g: Int,
    val b: Int,
    val hueDeg: Double,
    val saturationPct: Double,
    val brightnessPct: Double,
    val luminance: Double,
) {
    val rgbText: String get() = "$r $g $b"
    val hsbText: String
        get() = String.format(
            Locale.US,
            "%.0f° %.0f%% %.0f%%",
            hueDeg,
            saturationPct,
            brightnessPct
        )
}

data class InspectionAnchor(
    val id: Long,
    val sourceX: Float,
    val sourceY: Float,
) {
    companion object {
        const val MAX_COUNT = 4
    }
}

data class InspectionSessionState(
    val monitorEnabled: Boolean = false,
    val liveOutputX: Float? = null,
    val liveOutputY: Float? = null,
    val anchors: List<InspectionAnchor> = emptyList(),
    val selectedAnchorId: Long? = null,
    val overlay: InspectionOverlayMode = InspectionOverlayMode.NONE,
    val lastNonGrayOverlay: InspectionOverlayMode = InspectionOverlayMode.NONE,
    val nextAnchorId: Long = 1L,
) {
    val canPinMore: Boolean get() = anchors.size < InspectionAnchor.MAX_COUNT

    fun selectOverlay(mode: InspectionOverlayMode): InspectionSessionState = copy(
        overlay = mode,
        lastNonGrayOverlay = if (mode != InspectionOverlayMode.NEUTRAL_GRAY_50) mode else lastNonGrayOverlay
    )

    fun toggleNeutralGray50(): InspectionSessionState =
        if (overlay == InspectionOverlayMode.NEUTRAL_GRAY_50) {
            val restored = if (lastNonGrayOverlay == InspectionOverlayMode.NEUTRAL_GRAY_50) {
                InspectionOverlayMode.NONE
            } else {
                lastNonGrayOverlay
            }
            copy(overlay = restored)
        } else {
            copy(lastNonGrayOverlay = overlay, overlay = InspectionOverlayMode.NEUTRAL_GRAY_50)
        }

    fun pinAnchor(sourceX: Float, sourceY: Float): InspectionSessionState {
        if (!canPinMore) return this
        val anchor = InspectionAnchor(
            id = nextAnchorId,
            sourceX = sourceX.coerceIn(0f, 1f),
            sourceY = sourceY.coerceIn(0f, 1f)
        )
        return copy(
            anchors = anchors + anchor,
            selectedAnchorId = anchor.id,
            nextAnchorId = nextAnchorId + 1L
        )
    }

    fun removeAnchor(id: Long): InspectionSessionState {
        val next = anchors.filterNot { it.id == id }
        val nextSelected = if (selectedAnchorId == id) next.lastOrNull()?.id else selectedAnchorId
        return copy(anchors = next, selectedAnchorId = nextSelected)
    }

    fun clearAnchors(): InspectionSessionState = copy(anchors = emptyList(), selectedAnchorId = null)

    fun resetForNewSource(): InspectionSessionState = InspectionSessionState()

    fun saveToList(): List<Any?> = buildList {
        add(monitorEnabled)
        add(liveOutputX)
        add(liveOutputY)
        add(selectedAnchorId)
        add(overlay.ordinal)
        add(lastNonGrayOverlay.ordinal)
        add(nextAnchorId)
        add(anchors.size)
        for (anchor in anchors) {
            add(anchor.id)
            add(anchor.sourceX)
            add(anchor.sourceY)
        }
    }

    companion object {
        fun restoreFromList(raw: List<Any?>): InspectionSessionState {
            if (raw.size < 8) return InspectionSessionState()
            val monitor = raw[0] as? Boolean ?: false
            val liveX = (raw[1] as? Number)?.toFloat()
            val liveY = (raw[2] as? Number)?.toFloat()
            val selectedId = (raw[3] as? Number)?.toLong()
            val overlayOrdinal = (raw[4] as? Number)?.toInt() ?: 0
            val lastOrdinal = (raw[5] as? Number)?.toInt() ?: 0
            val nextId = (raw[6] as? Number)?.toLong() ?: 1L
            val anchorCount = (raw[7] as? Number)?.toInt() ?: 0
            val entries = InspectionOverlayMode.entries
            val overlayMode = entries.getOrElse(overlayOrdinal) { InspectionOverlayMode.NONE }
            val lastMode = entries.getOrElse(lastOrdinal) { InspectionOverlayMode.NONE }
            val restoredAnchors = buildList {
                var idx = 8
                for (i in 0 until anchorCount) {
                    if (idx + 2 >= raw.size) break
                    val id = (raw[idx] as? Number)?.toLong() ?: break
                    val sx = (raw[idx + 1] as? Number)?.toFloat() ?: break
                    val sy = (raw[idx + 2] as? Number)?.toFloat() ?: break
                    add(InspectionAnchor(id = id, sourceX = sx, sourceY = sy))
                    idx += 3
                }
            }
            return InspectionSessionState(
                monitorEnabled = monitor,
                liveOutputX = liveX,
                liveOutputY = liveY,
                anchors = restoredAnchors,
                selectedAnchorId = selectedId,
                overlay = overlayMode,
                lastNonGrayOverlay = lastMode,
                nextAnchorId = nextId,
            )
        }
    }
}

object InspectionColorMath {
    fun fromRgb(r: Int, g: Int, b: Int): InspectionColorSample {
        val cr = r.coerceIn(0, 255)
        val cg = g.coerceIn(0, 255)
        val cb = b.coerceIn(0, 255)
        val rf = cr / 255.0
        val gf = cg / 255.0
        val bf = cb / 255.0
        val maxC = max(rf, max(gf, bf))
        val minC = min(rf, min(gf, bf))
        val delta = maxC - minC

        val brightnessPct = maxC * 100.0
        val saturationPct = if (maxC <= 0.0) 0.0 else (delta / maxC) * 100.0

        var hue = 0.0
        if (delta > 1e-6) {
            val seg = when (maxC) {
                rf -> (gf - bf) / delta + (if (gf < bf) 6.0 else 0.0)
                gf -> (bf - rf) / delta + 2.0
                else -> (rf - gf) / delta + 4.0
            }
            hue = seg * 60.0
            if (hue < 0.0) hue += 360.0
            if (hue >= 360.0) hue -= 360.0
        }
        val luminance = ((0.2126 * cr + 0.7152 * cg + 0.0722 * cb) / 255.0).coerceIn(0.0, 1.0)
        return InspectionColorSample(cr, cg, cb, hue, saturationPct, brightnessPct, luminance)
    }

    fun hsbToRgb(hueDeg: Double, saturation: Double, brightness: Double): Triple<Double, Double, Double> {
        var h = hueDeg % 360.0
        if (h < 0.0) h += 360.0
        val s = saturation.coerceIn(0.0, 1.0)
        val v = brightness.coerceIn(0.0, 1.0)
        val c = v * s
        val hp = h / 60.0
        val x = c * (1.0 - abs(hp % 2.0 - 1.0))
        val m = v - c
        val (r1, g1, b1) = when (floor(hp).toInt() % 6) {
            0 -> Triple(c, x, 0.0)
            1 -> Triple(x, c, 0.0)
            2 -> Triple(0.0, c, x)
            3 -> Triple(0.0, x, c)
            4 -> Triple(x, 0.0, c)
            else -> Triple(c, 0.0, x)
        }
        return Triple(
            (r1 + m).coerceIn(0.0, 1.0),
            (g1 + m).coerceIn(0.0, 1.0),
            (b1 + m).coerceIn(0.0, 1.0)
        )
    }

    fun sampleArgbPatch(
        pixels: IntArray,
        width: Int,
        height: Int,
        normX: Float,
        normY: Float,
        radiusPx: Int = 1,
    ): InspectionColorSample? {
        if (width <= 0 || height <= 0 || pixels.size < width * height) return null
        if (!normX.isFinite() || !normY.isFinite()) return null
        val nx = normX.coerceIn(0f, 1f).toDouble()
        val ny = normY.coerceIn(0f, 1f).toDouble()
        val cx = if (width == 1) 0 else (nx * (width - 1)).roundToInt().coerceIn(0, width - 1)
        val cy = if (height == 1) 0 else (ny * (height - 1)).roundToInt().coerceIn(0, height - 1)
        val r = max(0, radiusPx)
        val x0 = max(0, cx - r)
        val x1 = min(width - 1, cx + r)
        val y0 = max(0, cy - r)
        val y1 = min(height - 1, cy + r)

        var sumR = 0L
        var sumG = 0L
        var sumB = 0L
        var count = 0
        for (y in y0..y1) {
            val row = y * width
            for (x in x0..x1) {
                val argb = pixels[row + x]
                sumR += (argb ushr 16) and 0xff
                sumG += (argb ushr 8) and 0xff
                sumB += argb and 0xff
                count++
            }
        }
        if (count <= 0) return null
        return fromRgb(
            (sumR.toDouble() / count).roundToInt().coerceIn(0, 255),
            (sumG.toDouble() / count).roundToInt().coerceIn(0, 255),
            (sumB.toDouble() / count).roundToInt().coerceIn(0, 255)
        )
    }

    fun applyOverlayPixel(r: Int, g: Int, b: Int, mode: InspectionOverlayMode): Int {
        val (or, og, ob) = when (mode) {
            InspectionOverlayMode.NONE -> Triple(r, g, b)
            InspectionOverlayMode.NEUTRAL_GRAY_50 -> Triple(128, 128, 128)
            InspectionOverlayMode.SKETCH_LUMINANCE -> {
                val rf = r / 255.0
                val gf = g / 255.0
                val bf = b / 255.0
                val y = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf
                val t = ((y - 0.5) * 2.4 + 0.5).coerceIn(0.0, 1.0)
                val v = t * t * (3.0 - 2.0 * t)
                val out = toByte(v)
                Triple(out, out, out)
            }
            InspectionOverlayMode.WARM_COOL_BW -> {
                val rf = r / 255.0
                val gf = g / 255.0
                val bf = b / 255.0
                val y = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf
                val warmth = (rf - bf) + 0.35 * (gf - bf)
                val v = (y + 0.55 * warmth).coerceIn(0.0, 1.0)
                val out = toByte(v)
                Triple(out, out, out)
            }
            InspectionOverlayMode.OVERSATURATION_HEATMAP -> {
                val rf = r / 255.0
                val gf = g / 255.0
                val bf = b / 255.0
                val maxC = max(rf, max(gf, bf))
                val minC = min(rf, min(gf, bf))
                val delta = maxC - minC
                val bright = maxC
                val sat = if (maxC <= 0.0) 0.0 else delta / maxC
                val y = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf
                val baseVal = 0.28 * y

                val outTriple = when {
                    minC >= 0.996 -> Triple(1.0, 0.25, 0.25)
                    maxC >= 0.996 && minC < 0.96 -> Triple(1.0, 0.10, 0.55)
                    sat > 0.85 && bright > 0.35 -> {
                        val sev = (((sat - 0.85) / 0.15) * 0.7 + ((bright - 0.35) / 0.65) * 0.3).coerceIn(0.0, 1.0)
                        if (sev < 0.5) {
                            val u = sev * 2.0
                            Triple(1.0, 0.90 + (0.45 - 0.90) * u, 0.0)
                        } else {
                            val u = (sev - 0.5) * 2.0
                            Triple(1.0, 0.45 + (0.08 - 0.45) * u, 0.12 * u)
                        }
                    }
                    sat > 0.75 && bright > 0.35 -> {
                        val t = ((sat - 0.75) / 0.10).coerceIn(0.0, 1.0) * 0.65
                        Triple(
                            baseVal + (1.0 - baseVal) * t,
                            baseVal + (0.72 - baseVal) * t,
                            baseVal + (0.12 - baseVal) * t
                        )
                    }
                    else -> Triple(baseVal, baseVal, baseVal)
                }
                Triple(toByte(outTriple.first), toByte(outTriple.second), toByte(outTriple.third))
            }
            InspectionOverlayMode.SKIN_HUE_AMPLIFICATION -> {
                val rf = r / 255.0
                val gf = g / 255.0
                val bf = b / 255.0
                val maxC = max(rf, max(gf, bf))
                val minC = min(rf, min(gf, bf))
                val delta = maxC - minC
                val bright = maxC
                val sat = if (maxC <= 0.0) 0.0 else delta / maxC
                var hue = 0.0
                if (delta > 1e-6) {
                    val seg = when (maxC) {
                        rf -> (gf - bf) / delta + (if (gf < bf) 6.0 else 0.0)
                        gf -> (bf - rf) / delta + 2.0
                        else -> (rf - gf) / delta + 4.0
                    }
                    hue = seg * 60.0
                    if (hue < 0.0) hue += 360.0
                    if (hue >= 360.0) hue -= 360.0
                }
                if (hue in 0.0..50.0 && sat >= 0.05 && bright >= 0.08) {
                    val stretchedHue = if (hue <= 22.0) {
                        (330.0 + 65.0 * (hue / 22.0)) % 360.0
                    } else {
                        35.0 + 115.0 * ((hue - 22.0) / 28.0)
                    }
                    val sPrime = max(0.55, sat * 1.8).coerceIn(0.0, 1.0)
                    val bPrime = (0.35 + 0.65 * bright).coerceIn(0.0, 1.0)
                    val (nr, ng, nb) = hsbToRgb(stretchedHue, sPrime, bPrime)
                    Triple(toByte(nr), toByte(ng), toByte(nb))
                } else {
                    val y = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf
                    val muted = toByte(0.35 * y)
                    Triple(muted, muted, muted)
                }
            }
        }
        return (0xff shl 24) or ((or and 0xff) shl 16) or ((og and 0xff) shl 8) or (ob and 0xff)
    }

    fun applyOverlayArgb(src: IntArray, dst: IntArray, mode: InspectionOverlayMode) {
        val count = min(src.size, dst.size)
        for (i in 0 until count) {
            val c = src[i]
            dst[i] = applyOverlayPixel((c ushr 16) and 0xff, (c ushr 8) and 0xff, c and 0xff, mode)
        }
    }

    private fun toByte(value: Double): Int = (value * 255.0).roundToInt().coerceIn(0, 255)
}

object InspectionGeometryMapper {
    data class CanvasSpec(
        val rotatedWidth: Int,
        val rotatedHeight: Int,
        val width: Int,
        val height: Int,
        val left: Int,
        val top: Int,
        val right: Int,
        val bottom: Int,
        val cosine: Double,
        val sine: Double,
    ) {
        val outputWidth: Int get() = right - left
        val outputHeight: Int get() = bottom - top
    }

    fun inferSourceSize(outputWidth: Int, outputHeight: Int, options: GeometrySettings): Pair<Int, Int> {
        val safeW = max(1, outputWidth)
        val safeH = max(1, outputHeight)
        if (options.isIdentity) return safeW to safeH
        val radians = options.straightenDegrees.toDouble() * Math.PI / 180.0
        val cosine = cos(radians)
        val absSine = abs(sin(radians))
        val perspScale = 1.0 / (1.0 + 0.25 * abs(options.perspectiveHorizontal) + 0.25 * abs(options.perspectiveVertical))
        val cw = safeW / max(0.0001, options.cropWidth.toDouble())
        val ch = safeH / max(0.0001, options.cropHeight.toDouble())
        val straightenScale = min(cw / (cw * cosine + ch * absSine), ch / (cw * absSine + ch * cosine))
        val rw = max(1, (cw / max(1e-4, perspScale * straightenScale)).roundToInt())
        val rh = max(1, (ch / max(1e-4, perspScale * straightenScale)).roundToInt())
        val turns = ((options.quarterTurns % 4) + 4) % 4
        return if (turns % 2 != 0) rh to rw else rw to rh
    }

    fun canvasFor(width: Int, height: Int, options: GeometrySettings): CanvasSpec {
        val safeW = max(1, width)
        val safeH = max(1, height)
        val turns = ((options.quarterTurns % 4) + 4) % 4
        val rotatedWidth = if (turns % 2 != 0) safeH else safeW
        val rotatedHeight = if (turns % 2 != 0) safeW else safeH
        val radians = options.straightenDegrees.toDouble() * Math.PI / 180.0
        val cosine = cos(radians)
        val sine = sin(radians)
        val absSine = abs(sine)
        val perspScale = 1.0 / (1.0 + 0.25 * abs(options.perspectiveHorizontal) + 0.25 * abs(options.perspectiveVertical))
        val w = max(1, floor(rotatedWidth * perspScale).toInt())
        val h = max(1, floor(rotatedHeight * perspScale).toInt())
        val scale = min(w.toDouble() / (w * cosine + h * absSine), h.toDouble() / (w * absSine + h * cosine))
        val canvasW = max(1, floor(w * scale).toInt())
        val canvasH = max(1, floor(h * scale).toInt())
        val left = floor(options.cropX.toDouble() * canvasW).toInt().coerceIn(0, canvasW - 1)
        val top = floor(options.cropY.toDouble() * canvasH).toInt().coerceIn(0, canvasH - 1)
        val right = min(canvasW, max(left + 1, ceil(min(1.0, options.cropX.toDouble() + options.cropWidth) * canvasW).toInt()))
        val bottom = min(canvasH, max(top + 1, ceil(min(1.0, options.cropY.toDouble() + options.cropHeight) * canvasH).toInt()))
        return CanvasSpec(rotatedWidth, rotatedHeight, canvasW, canvasH, left, top, right, bottom, cosine, sine)
    }

    fun outputNormToSourceNorm(
        outX: Float,
        outY: Float,
        sourceWidth: Int,
        sourceHeight: Int,
        geometry: GeometrySettings,
    ): Pair<Float, Float>? {
        if (!outX.isFinite() || !outY.isFinite() ||
            outX < -1e-4f || outX > 1f + 1e-4f || outY < -1e-4f || outY > 1f + 1e-4f ||
            sourceWidth < 1 || sourceHeight < 1
        ) return null

        val clampedOutX = outX.coerceIn(0f, 1f).toDouble()
        val clampedOutY = outY.coerceIn(0f, 1f).toDouble()
        if (geometry.isIdentity) return clampedOutX.toFloat() to clampedOutY.toFloat()

        val canvas = canvasFor(sourceWidth, sourceHeight, geometry)
        val x = clampedOutX * canvas.outputWidth - 0.5
        val y = clampedOutY * canvas.outputHeight - 0.5
        val dy = canvas.top + y - (canvas.height - 1) * 0.5
        val dx = canvas.left + x - (canvas.width - 1) * 0.5
        val rotatedX = canvas.cosine * dx + canvas.sine * dy
        val rotatedY = -canvas.sine * dx + canvas.cosine * dy
        val denominator = 1.0 +
            0.25 * geometry.perspectiveHorizontal * (2.0 * rotatedX / canvas.rotatedWidth) +
            0.25 * geometry.perspectiveVertical * (2.0 * rotatedY / canvas.rotatedHeight)
        if (abs(denominator) <= 1e-6) return null

        var px = (canvas.rotatedWidth - 1) * 0.5 + rotatedX / denominator
        var py = (canvas.rotatedHeight - 1) * 0.5 + rotatedY / denominator
        if (geometry.flipHorizontal) px = (canvas.rotatedWidth - 1) - px
        if (geometry.flipVertical) py = (canvas.rotatedHeight - 1) - py

        val turns = ((geometry.quarterTurns % 4) + 4) % 4
        val (sx, sy) = when (turns) {
            1 -> py to (sourceHeight - 1).toDouble() - px
            2 -> (sourceWidth - 1).toDouble() - px to (sourceHeight - 1).toDouble() - py
            3 -> (sourceWidth - 1).toDouble() - py to px
            else -> px to py
        }
        val uSrc = (sx + 0.5) / sourceWidth
        val vSrc = (sy + 0.5) / sourceHeight
        if (uSrc < -1e-3 || uSrc > 1.0 + 1e-3 || vSrc < -1e-3 || vSrc > 1.0 + 1e-3) return null
        return uSrc.coerceIn(0.0, 1.0).toFloat() to vSrc.coerceIn(0.0, 1.0).toFloat()
    }

    fun sourceNormToOutputNorm(
        srcX: Float,
        srcY: Float,
        sourceWidth: Int,
        sourceHeight: Int,
        geometry: GeometrySettings,
    ): Pair<Float, Float>? {
        if (!srcX.isFinite() || !srcY.isFinite() ||
            srcX < -1e-4f || srcX > 1f + 1e-4f || srcY < -1e-4f || srcY > 1f + 1e-4f ||
            sourceWidth < 1 || sourceHeight < 1
        ) return null

        val clampedSrcX = srcX.coerceIn(0f, 1f).toDouble()
        val clampedSrcY = srcY.coerceIn(0f, 1f).toDouble()
        if (geometry.isIdentity) return clampedSrcX.toFloat() to clampedSrcY.toFloat()

        val canvas = canvasFor(sourceWidth, sourceHeight, geometry)
        val sx = clampedSrcX * sourceWidth - 0.5
        val sy = clampedSrcY * sourceHeight - 0.5
        val turns = ((geometry.quarterTurns % 4) + 4) % 4
        var (px, py) = when (turns) {
            1 -> (sourceHeight - 1).toDouble() - sy to sx
            2 -> (sourceWidth - 1).toDouble() - sx to (sourceHeight - 1).toDouble() - sy
            3 -> sy to (sourceWidth - 1).toDouble() - sx
            else -> sx to sy
        }
        if (geometry.flipHorizontal) px = (canvas.rotatedWidth - 1) - px
        if (geometry.flipVertical) py = (canvas.rotatedHeight - 1) - py

        val ax = px - (canvas.rotatedWidth - 1) * 0.5
        val ay = py - (canvas.rotatedHeight - 1) * 0.5
        val ch = 0.5 * geometry.perspectiveHorizontal / canvas.rotatedWidth
        val cv = 0.5 * geometry.perspectiveVertical / canvas.rotatedHeight
        val denom = 1.0 - ch * ax - cv * ay
        if (denom <= 1e-6) return null

        val rx = ax / denom
        val ry = ay / denom
        val dx = canvas.cosine * rx - canvas.sine * ry
        val dy = canvas.sine * rx + canvas.cosine * ry
        val cx = dx + (canvas.width - 1) * 0.5
        val cy = dy + (canvas.height - 1) * 0.5
        val x = cx - canvas.left
        val y = cy - canvas.top

        val uOut = (x + 0.5) / canvas.outputWidth
        val vOut = (y + 0.5) / canvas.outputHeight
        if (uOut < -1e-4 || uOut > 1.0 + 1e-4 || vOut < -1e-4 || vOut > 1.0 + 1e-4) return null
        return uOut.coerceIn(0.0, 1.0).toFloat() to vOut.coerceIn(0.0, 1.0).toFloat()
    }
}
