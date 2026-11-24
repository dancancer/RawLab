#include "test_harness.h"
#include "core/inspection_overlay.h"
#include "sony2fuji/ffi/sony2fuji_c.h"

#include <cmath>
#include <cstdint>
#include <iostream>
#include <limits>
#include <vector>

namespace {

using rawlab::test::require;

sony2fuji_inspection_sample initSample() {
    sony2fuji_inspection_sample s{};
    s.version = SONY2FUJI_INSPECTION_SAMPLE_VERSION;
    s.struct_size = sizeof(sony2fuji_inspection_sample);
    return s;
}

void testColorFromRgb() {
    auto red = initSample();
    require(sony2fuji_inspection_color_from_rgb(255, 0, 0, &red) == SONY2FUJI_STATUS_OK, "red color_from_rgb succeeds");
    require(std::abs(red.hue_deg - 0.0) < 0.01 && std::abs(red.saturation_pct - 100.0) < 0.01 &&
            std::abs(red.brightness_pct - 100.0) < 0.01 && std::abs(red.luminance - 0.2126) < 1e-4,
        "red HSB and Rec.709 luminance match contract");

    auto green = initSample();
    require(sony2fuji_inspection_color_from_rgb(0, 255, 0, &green) == SONY2FUJI_STATUS_OK, "green color_from_rgb succeeds");
    require(std::abs(green.hue_deg - 120.0) < 0.01 && std::abs(green.luminance - 0.7152) < 1e-4,
        "green HSB and luminance match contract");

    auto blue = initSample();
    require(sony2fuji_inspection_color_from_rgb(0, 0, 255, &blue) == SONY2FUJI_STATUS_OK, "blue color_from_rgb succeeds");
    require(std::abs(blue.hue_deg - 240.0) < 0.01 && std::abs(blue.luminance - 0.0722) < 1e-4,
        "blue HSB and luminance match contract");

    auto cyan = initSample();
    require(sony2fuji_inspection_color_from_rgb(0, 255, 255, &cyan) == SONY2FUJI_STATUS_OK, "cyan color_from_rgb succeeds");
    require(std::abs(cyan.hue_deg - 180.0) < 0.01, "cyan hue matches 180");

    auto magenta = initSample();
    require(sony2fuji_inspection_color_from_rgb(255, 0, 255, &magenta) == SONY2FUJI_STATUS_OK, "magenta color_from_rgb succeeds");
    require(std::abs(magenta.hue_deg - 300.0) < 0.01, "magenta hue matches 300");

    auto gray = initSample();
    require(sony2fuji_inspection_color_from_rgb(128, 128, 128, &gray) == SONY2FUJI_STATUS_OK, "gray color_from_rgb succeeds");
    require(std::abs(gray.hue_deg) < 0.01 && std::abs(gray.saturation_pct) < 0.01 &&
            std::abs(gray.luminance - (128.0 / 255.0)) < 1e-4,
        "gray HSB and luminance match contract");
}

void testPatchSamplingAndFormats() {
    // 4x4 patch with padded stride (stride = 20 instead of 16)
    const uint32_t w = 4;
    const uint32_t h = 4;
    const uint32_t rgbaStride = 20;
    std::vector<uint8_t> rgba(rgbaStride * h, 0);
    std::vector<uint8_t> bgra(rgbaStride * h, 0);
    std::vector<uint8_t> rgb(w * h * 3, 0);

    for (uint32_t y = 0; y < h; ++y) {
        for (uint32_t x = 0; x < w; ++x) {
            const uint8_t r = x < 2 ? 100 : 200;
            const uint8_t g = 100;
            const uint8_t b = x < 2 ? 100 : 50;
            const size_t off4 = y * rgbaStride + x * 4;
            rgba[off4 + 0] = r;
            rgba[off4 + 1] = g;
            rgba[off4 + 2] = b;
            rgba[off4 + 3] = 255;

            bgra[off4 + 0] = b;
            bgra[off4 + 1] = g;
            bgra[off4 + 2] = r;
            bgra[off4 + 3] = 255;

            const size_t off3 = (y * w + x) * 3;
            rgb[off3 + 0] = r;
            rgb[off3 + 1] = g;
            rgb[off3 + 2] = b;
        }
    }

    const sony2fuji_buffer rgbaBuf{rgba.data(), rgba.size(), w, h, rgbaStride, SONY2FUJI_PIXEL_RGBA8};
    const sony2fuji_buffer bgraBuf{bgra.data(), bgra.size(), w, h, rgbaStride, SONY2FUJI_PIXEL_BGRA8};
    const sony2fuji_buffer rgbBuf{rgb.data(), rgb.size(), w, h, w * 3, SONY2FUJI_PIXEL_RGB8};

    auto corner = initSample();
    require(sony2fuji_inspection_sample_patch(&rgbaBuf, 0.0, 0.0, 0, &corner) == SONY2FUJI_STATUS_OK, "corner sample succeeds");
    require(corner.r == 100 && corner.g == 100 && corner.b == 100, "corner sample matches (100,100,100)");

    // Straddle (1/3, 0.5): cx=1, cy=2 => x in 0..2 => avg R = (100*6 + 200*3)/9 = 133 (half-away-from-zero parity)
    auto sRgba = initSample();
    auto sBgra = initSample();
    auto sRgb = initSample();
    require(sony2fuji_inspection_sample_patch(&rgbaBuf, 1.0 / 3.0, 0.5, 1, &sRgba) == SONY2FUJI_STATUS_OK, "RGBA8 straddle succeeds");
    require(sony2fuji_inspection_sample_patch(&bgraBuf, 1.0 / 3.0, 0.5, 1, &sBgra) == SONY2FUJI_STATUS_OK, "BGRA8 straddle succeeds");
    require(sony2fuji_inspection_sample_patch(&rgbBuf, 1.0 / 3.0, 0.5, 1, &sRgb) == SONY2FUJI_STATUS_OK, "RGB8 straddle succeeds");
    require(sRgba.r == 133 && sBgra.r == 133 && sRgb.r == 133, "straddle R == 133 across RGBA8/BGRA8/RGB8");
    require(sRgba.g == sBgra.g && sRgba.b == sBgra.b && sRgba.b == sRgb.b, "RGBA8/BGRA8/RGB8 patch parity");

    // 1x1 edge case + huge radius
    const uint8_t singlePx[4] = {42, 84, 126, 255};
    const sony2fuji_buffer singleBuf{const_cast<uint8_t*>(singlePx), sizeof(singlePx), 1, 1, 4, SONY2FUJI_PIXEL_RGBA8};
    auto single = initSample();
    require(sony2fuji_inspection_sample_patch(&singleBuf, 0.5, 0.5, 1000000u, &single) == SONY2FUJI_STATUS_OK, "1x1 huge radius safe");
    require(single.r == 42 && single.g == 84 && single.b == 126, "1x1 sample exact");

    // True .5 midpoint tie-breaking (half-away-from-zero std::llround vs round-half-to-even & truncation)
    const uint8_t horizTiePx[3 * 4] = {
        10, 0, 0, 255,
        11, 0, 0, 255,
        12, 0, 0, 255,
    };
    const sony2fuji_buffer horizTieBuf{const_cast<uint8_t*>(horizTiePx), sizeof(horizTiePx), 3, 1, 12, SONY2FUJI_PIXEL_RGBA8};
    auto horizTie = initSample();
    require(sony2fuji_inspection_sample_patch(&horizTieBuf, 0.25, 0.5, 0, &horizTie) == SONY2FUJI_STATUS_OK,
        "3x1 coordinate 0.5 tie succeeds");
    require(horizTie.r == 11, "0.25 * (3 - 1) = 0.5 rounds half-away-from-zero to pixel 1 (R==11)");

    const uint8_t vertTiePx[3 * 4] = {
        20, 0, 0, 255,
        21, 0, 0, 255,
        22, 0, 0, 255,
    };
    const sony2fuji_buffer vertTieBuf{const_cast<uint8_t*>(vertTiePx), sizeof(vertTiePx), 1, 3, 4, SONY2FUJI_PIXEL_RGBA8};
    auto vertTie = initSample();
    require(sony2fuji_inspection_sample_patch(&vertTieBuf, 0.5, 0.25, 0, &vertTie) == SONY2FUJI_STATUS_OK,
        "1x3 coordinate 0.5 tie succeeds");
    require(vertTie.r == 21, "0.25 * (3 - 1) = 0.5 rounds half-away-from-zero to row 1 (R==21)");

    const uint8_t avgTiePx[2 * 4] = {
        100, 0, 0, 255,
        101, 0, 0, 255,
    };
    const sony2fuji_buffer avgTieBuf{const_cast<uint8_t*>(avgTiePx), sizeof(avgTiePx), 2, 1, 8, SONY2FUJI_PIXEL_RGBA8};
    auto avgTie = initSample();
    require(sony2fuji_inspection_sample_patch(&avgTieBuf, 0.0, 0.0, 1, &avgTie) == SONY2FUJI_STATUS_OK,
        "2x1 average 100.5 tie succeeds");
    require(avgTie.r == 101, "(100 + 101) / 2.0 = 100.5 rounds half-away-from-zero to 101");
}

void testAllFiveObservationOverlaysAndBufferRender() {
    uint8_t r = 0, g = 0, b = 0;

    // 1. Sketch Luminance
    uint8_t dr = 0, dg = 0, db = 0, br = 0, bg = 0, bb = 0;
    require(sony2fuji_inspection_overlay_pixel(80, 80, 80, SONY2FUJI_INSPECTION_OVERLAY_SKETCH_LUMINANCE, &dr, &dg, &db) == SONY2FUJI_STATUS_OK, "sketch dark");
    require(sony2fuji_inspection_overlay_pixel(180, 180, 180, SONY2FUJI_INSPECTION_OVERLAY_SKETCH_LUMINANCE, &br, &bg, &bb) == SONY2FUJI_STATUS_OK, "sketch bright");
    require(dr == dg && dg == db && dr < 80, "sketch dark neutral and darker");
    require(br == bg && bg == bb && br > 180, "sketch bright neutral and brighter");

    // 2. Warm/Cool BW
    uint8_t wr = 0, wg = 0, wb = 0, cr = 0, cg = 0, cb = 0;
    require(sony2fuji_inspection_overlay_pixel(180, 140, 60, SONY2FUJI_INSPECTION_OVERLAY_WARM_COOL_BW, &wr, &wg, &wb) == SONY2FUJI_STATUS_OK, "warm bw");
    require(sony2fuji_inspection_overlay_pixel(60, 140, 220, SONY2FUJI_INSPECTION_OVERLAY_WARM_COOL_BW, &cr, &cg, &cb) == SONY2FUJI_STATUS_OK, "cool bw");
    require(wr == wg && wg == wb && cr == cg && cg == cb && wr > cr, "warm lifts above cool");

    // 3. Oversaturation Heatmap
    require(sony2fuji_inspection_overlay_pixel(128, 128, 128, SONY2FUJI_INSPECTION_OVERLAY_OVERSATURATION_HEATMAP, &r, &g, &b) == SONY2FUJI_STATUS_OK, "heat neutral");
    require(r == g && g == b && r < 50, "neutral heatmap muted");
    require(sony2fuji_inspection_overlay_pixel(255, 100, 100, SONY2FUJI_INSPECTION_OVERLAY_OVERSATURATION_HEATMAP, &r, &g, &b) == SONY2FUJI_STATUS_OK, "heat single clip");
    require(r == 255 && b > 100, "single-channel clip magenta highlight");
    require(sony2fuji_inspection_overlay_pixel(230, 20, 10, SONY2FUJI_INSPECTION_OVERLAY_OVERSATURATION_HEATMAP, &r, &g, &b) == SONY2FUJI_STATUS_OK, "heat melt");
    require(r == 255 && b < 50, "melting saturation highlight");

    // 4. Skin Hue Amplification
    uint8_t sr = 0, sg = 0, sb = 0, yr = 0, yg = 0, yb = 0;
    require(sony2fuji_inspection_overlay_pixel(210, 130, 120, SONY2FUJI_INSPECTION_OVERLAY_SKIN_HUE_AMPLIFICATION, &sr, &sg, &sb) == SONY2FUJI_STATUS_OK, "red skin");
    require(sony2fuji_inspection_overlay_pixel(210, 195, 120, SONY2FUJI_INSPECTION_OVERLAY_SKIN_HUE_AMPLIFICATION, &yr, &yg, &yb) == SONY2FUJI_STATUS_OK, "yellow skin");
    require(sr != sb && yg > sg, "skin hue amplification separates hues");
    require(sony2fuji_inspection_overlay_pixel(80, 120, 200, SONY2FUJI_INSPECTION_OVERLAY_SKIN_HUE_AMPLIFICATION, &r, &g, &b) == SONY2FUJI_STATUS_OK, "non-skin muted");
    require(r == g && g == b, "non-skin muted to gray");

    // 5. Neutral Gray 50
    require(sony2fuji_inspection_overlay_pixel(20, 200, 250, SONY2FUJI_INSPECTION_OVERLAY_NEUTRAL_GRAY_50, &r, &g, &b) == SONY2FUJI_STATUS_OK, "gray50");
    require(r == 128 && g == 128 && b == 128, "gray50 exact (128,128,128)");

    // Buffer render parity across RGBA8 and BGRA8 (large enough to exercise parallelRowRanges path)
    const uint32_t w = 320;
    const uint32_t h = 256;
    const uint32_t srcStride = w * 4 + 16;
    const uint32_t dstStride = w * 4 + 8;
    std::vector<uint8_t> srcRgba(srcStride * h, 0);
    std::vector<uint8_t> srcBgra(srcStride * h, 0);
    std::vector<uint8_t> dstRgba(dstStride * h, 0);
    std::vector<uint8_t> dstBgra(dstStride * h, 0);

    for (uint32_t y = 0; y < h; ++y) {
        for (uint32_t x = 0; x < w; ++x) {
            const uint8_t pr = static_cast<uint8_t>((x * 3 + y) & 0xff);
            const uint8_t pg = static_cast<uint8_t>((x + y * 2) & 0xff);
            const uint8_t pb = static_cast<uint8_t>((255 - x) & 0xff);
            const size_t off = y * srcStride + x * 4;
            srcRgba[off + 0] = pr;
            srcRgba[off + 1] = pg;
            srcRgba[off + 2] = pb;
            srcRgba[off + 3] = 200;

            srcBgra[off + 0] = pb;
            srcBgra[off + 1] = pg;
            srcBgra[off + 2] = pr;
            srcBgra[off + 3] = 200;
        }
    }

    const sony2fuji_buffer sRgba{srcRgba.data(), srcRgba.size(), w, h, srcStride, SONY2FUJI_PIXEL_RGBA8};
    const sony2fuji_buffer sBgra{srcBgra.data(), srcBgra.size(), w, h, srcStride, SONY2FUJI_PIXEL_BGRA8};
    sony2fuji_buffer dRgba{dstRgba.data(), dstRgba.size(), w, h, dstStride, SONY2FUJI_PIXEL_RGBA8};
    sony2fuji_buffer dBgra{dstBgra.data(), dstBgra.size(), w, h, dstStride, SONY2FUJI_PIXEL_BGRA8};

    for (int m = SONY2FUJI_INSPECTION_OVERLAY_NONE; m <= SONY2FUJI_INSPECTION_OVERLAY_NEUTRAL_GRAY_50; ++m) {
        const auto mode = static_cast<sony2fuji_inspection_overlay_mode>(m);
        require(sony2fuji_inspection_render_overlay(&sRgba, mode, &dRgba) == SONY2FUJI_STATUS_OK, "RGBA8 render overlay succeeds");
        require(sony2fuji_inspection_render_overlay(&sBgra, mode, &dBgra) == SONY2FUJI_STATUS_OK, "BGRA8 render overlay succeeds");

        for (uint32_t y = 0; y < h; y += 17) {
            for (uint32_t x = 0; x < w; x += 19) {
                const size_t off = y * dstStride + x * 4;
                require(dstRgba[off + 0] == dstBgra[off + 2] &&
                        dstRgba[off + 1] == dstBgra[off + 1] &&
                        dstRgba[off + 2] == dstBgra[off + 0] &&
                        dstRgba[off + 3] == 255 && dstBgra[off + 3] == 255,
                    "RGBA8 and BGRA8 rendered pixels match channel-for-channel with opaque alpha");
            }
        }
    }
}

void testValidationErrors() {
    auto badVer = initSample();
    badVer.version = 2;
    require(sony2fuji_inspection_color_from_rgb(10, 20, 30, &badVer) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "rejects invalid sample version");

    auto badSize = initSample();
    badSize.struct_size = 16;
    require(sony2fuji_inspection_color_from_rgb(10, 20, 30, &badSize) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "rejects invalid sample struct_size");

    auto badRes0 = initSample();
    badRes0.reserved0 = 1;
    require(sony2fuji_inspection_color_from_rgb(10, 20, 30, &badRes0) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "rejects non-zero reserved0");

    auto badRes1 = initSample();
    badRes1.reserved1 = 1;
    require(sony2fuji_inspection_color_from_rgb(10, 20, 30, &badRes1) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "rejects non-zero reserved1");

    uint8_t px[16]{};
    auto okOut = initSample();
    const sony2fuji_buffer shortBuf{px, 8, 2, 2, 8, SONY2FUJI_PIXEL_RGBA8};
    require(sony2fuji_inspection_sample_patch(&shortBuf, 0.5, 0.5, 1, &okOut) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "rejects truncated buffer size_bytes");

    const sony2fuji_buffer validBuf{px, sizeof(px), 2, 2, 8, SONY2FUJI_PIXEL_RGBA8};
    require(sony2fuji_inspection_sample_patch(&validBuf, std::numeric_limits<double>::quiet_NaN(), 0.5, 1, &okOut) ==
            SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "rejects NaN norm_x");

    const sony2fuji_buffer rgba16Buf{px, sizeof(px), 1, 1, 8, SONY2FUJI_PIXEL_RGBA16};
    require(sony2fuji_inspection_sample_patch(&rgba16Buf, 0.5, 0.5, 1, &okOut) == SONY2FUJI_STATUS_UNSUPPORTED,
        "rejects RGBA16 format in sample_patch");

    sony2fuji_buffer mismatchDst{px, sizeof(px), 2, 2, 8, SONY2FUJI_PIXEL_BGRA8};
    require(sony2fuji_inspection_render_overlay(&validBuf, SONY2FUJI_INSPECTION_OVERLAY_NONE, &mismatchDst) ==
            SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "rejects src/dst format mismatch");

    uint8_t r = 0, g = 0, b = 0;
    require(sony2fuji_inspection_overlay_pixel(10, 20, 30, static_cast<sony2fuji_inspection_overlay_mode>(99), &r, &g, &b) ==
            SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "rejects invalid overlay mode enum");

    // Aliasing, overlap, and INT_MAX dimension bounds regression tests
    std::vector<uint8_t> aliasArena(32, 0x33);
    for (size_t i = 0; i < aliasArena.size(); ++i) {
        aliasArena[i] = static_cast<uint8_t>(10 + i);
    }
    const std::vector<uint8_t> aliasBaseline = aliasArena;

    sony2fuji_buffer selfBuf{aliasArena.data(), 16, 2, 2, 8, SONY2FUJI_PIXEL_RGBA8};
    require(sony2fuji_inspection_render_overlay(&selfBuf, SONY2FUJI_INSPECTION_OVERLAY_SKETCH_LUMINANCE, &selfBuf) ==
            SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "rejects &buf == &buf aliasing");
    require(aliasArena == aliasBaseline, "&buf == &buf leaves buffer unmodified");

    const sony2fuji_buffer sameDataSrc{aliasArena.data(), 16, 2, 2, 8, SONY2FUJI_PIXEL_RGBA8};
    sony2fuji_buffer sameDataDst{aliasArena.data(), 16, 2, 2, 8, SONY2FUJI_PIXEL_RGBA8};
    require(sony2fuji_inspection_render_overlay(&sameDataSrc, SONY2FUJI_INSPECTION_OVERLAY_SKETCH_LUMINANCE, &sameDataDst) ==
            SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "rejects src.data == dst.data aliasing");
    require(aliasArena == aliasBaseline, "src.data == dst.data leaves buffer unmodified");

    sony2fuji_buffer shiftedDst{aliasArena.data() + 4, 16, 2, 2, 8, SONY2FUJI_PIXEL_RGBA8};
    require(sony2fuji_inspection_render_overlay(&sameDataSrc, SONY2FUJI_INSPECTION_OVERLAY_SKETCH_LUMINANCE, &shiftedDst) ==
            SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "rejects overlapping dst = src + 4");
    require(aliasArena == aliasBaseline, "overlapping dst = src + 4 leaves buffer unmodified");

    sony2fuji_buffer reverseSrc{aliasArena.data() + 4, 16, 2, 2, 8, SONY2FUJI_PIXEL_RGBA8};
    require(sony2fuji_inspection_render_overlay(&reverseSrc, SONY2FUJI_INSPECTION_OVERLAY_SKETCH_LUMINANCE, &selfBuf) ==
            SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "rejects overlapping src = dst + 4");
    require(aliasArena == aliasBaseline, "overlapping src = dst + 4 leaves buffer unmodified");

    sony2fuji_buffer adjacentDst{aliasArena.data() + 16, 16, 2, 2, 8, SONY2FUJI_PIXEL_RGBA8};
    require(sony2fuji_inspection_render_overlay(&sameDataSrc, SONY2FUJI_INSPECTION_OVERLAY_NEUTRAL_GRAY_50, &adjacentDst) ==
            SONY2FUJI_STATUS_OK,
        "allows adjacent non-overlapping slice in same backing allocation");

    const uint32_t overIntMax = static_cast<uint32_t>(std::numeric_limits<int>::max()) + 1u;
    const sony2fuji_buffer hugeHeightSrc{px, std::numeric_limits<size_t>::max(), 1, overIntMax, 4, SONY2FUJI_PIXEL_RGBA8};
    sony2fuji_buffer hugeHeightDst{aliasArena.data(), std::numeric_limits<size_t>::max(), 1, overIntMax, 4, SONY2FUJI_PIXEL_RGBA8};
    require(sony2fuji_inspection_sample_patch(&hugeHeightSrc, 0.5, 0.5, 0, &okOut) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "rejects height > INT_MAX in sample_patch");
    require(sony2fuji_inspection_render_overlay(&hugeHeightSrc, SONY2FUJI_INSPECTION_OVERLAY_NONE, &hugeHeightDst) ==
            SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "rejects height > INT_MAX in render_overlay");
}

} // namespace

int main() {
    testColorFromRgb();
    testPatchSamplingAndFormats();
    testAllFiveObservationOverlaysAndBufferRender();
    testValidationErrors();
    std::cout << "PASS: inspection_overlay_tests\n";
    return 0;
}
