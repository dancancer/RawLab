#include "core/bsh_diagnostics.h"
#include "sony2fuji/ffi/sony2fuji_c.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <limits>
#include <vector>

#define REQUIRE(cond) \
    do { \
        if (!(cond)) { \
            std::cerr << "FAIL at " << __FILE__ << ":" << __LINE__ << ": " #cond "\n"; \
            return 1; \
        } \
    } while (0)

namespace {

sony2fuji_buffer makeRgb8Buffer(std::vector<uint8_t>& storage, uint32_t w, uint32_t h, uint32_t stride) {
    sony2fuji_buffer b{};
    b.data = storage.data();
    b.size_bytes = storage.size();
    b.width = w;
    b.height = h;
    b.stride_bytes = stride;
    b.pixel_format = SONY2FUJI_PIXEL_RGB8;
    return b;
}

sony2fuji_buffer makeRgba8Buffer(std::vector<uint8_t>& storage, uint32_t w, uint32_t h, uint32_t stride) {
    sony2fuji_buffer b{};
    b.data = storage.data();
    b.size_bytes = storage.size();
    b.width = w;
    b.height = h;
    b.stride_bytes = stride;
    b.pixel_format = SONY2FUJI_PIXEL_RGBA8;
    return b;
}

sony2fuji_buffer makeRgba16Buffer(std::vector<uint8_t>& storage, uint32_t w, uint32_t h, uint32_t stride) {
    sony2fuji_buffer b{};
    b.data = storage.data();
    b.size_bytes = storage.size();
    b.width = w;
    b.height = h;
    b.stride_bytes = stride;
    b.pixel_format = SONY2FUJI_PIXEL_RGBA16;
    return b;
}

void writeRgba16Pixel(std::vector<uint8_t>& dst, size_t offset, uint16_t r, uint16_t g, uint16_t b) {
    dst[offset + 0] = static_cast<uint8_t>(r & 0xFFu);
    dst[offset + 1] = static_cast<uint8_t>((r >> 8) & 0xFFu);
    dst[offset + 2] = static_cast<uint8_t>(g & 0xFFu);
    dst[offset + 3] = static_cast<uint8_t>((g >> 8) & 0xFFu);
    dst[offset + 4] = static_cast<uint8_t>(b & 0xFFu);
    dst[offset + 5] = static_cast<uint8_t>((b >> 8) & 0xFFu);
    dst[offset + 6] = 0xFFu;
    dst[offset + 7] = 0xFFu;
}

sony2fuji_bsh_diagnosis initDiag() {
    sony2fuji_bsh_diagnosis d{};
    d.version = SONY2FUJI_BSH_DIAGNOSIS_VERSION;
    d.struct_size = sizeof(d);
    return d;
}

sony2fuji_bsh_sample_result initSampleResult() {
    sony2fuji_bsh_sample_result r{};
    r.version = SONY2FUJI_BSH_SAMPLE_VERSION;
    r.struct_size = sizeof(r);
    return r;
}

} // namespace

int main() {
    // 1. Validation & error guards
    {
        std::vector<uint8_t> px(4 * 4 * 4, 128);
        auto buf = makeRgba8Buffer(px, 4, 4, 16);
        auto diag = initDiag();
        REQUIRE(sony2fuji_diagnose_image(nullptr, nullptr, &diag) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
        REQUIRE(sony2fuji_diagnose_image(&buf, nullptr, nullptr) == SONY2FUJI_STATUS_INVALID_ARGUMENT);

        auto badDiag = initDiag();
        badDiag.version = 99;
        REQUIRE(sony2fuji_diagnose_image(&buf, nullptr, &badDiag) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
        badDiag = initDiag();
        badDiag.struct_size -= 4;
        REQUIRE(sony2fuji_diagnose_image(&buf, nullptr, &badDiag) == SONY2FUJI_STATUS_INVALID_ARGUMENT);

        sony2fuji_bsh_diagnose_options opts{SONY2FUJI_BSH_DIAGNOSIS_VERSION, sizeof(opts), 0, 1};
        REQUIRE(sony2fuji_diagnose_image(&buf, &opts, &diag) == SONY2FUJI_STATUS_INVALID_ARGUMENT);

        sony2fuji_bsh_sample_query q{SONY2FUJI_BSH_SAMPLE_VERSION, sizeof(q), -0.01f, 0.5f, 0.0f, 0};
        auto res = initSampleResult();
        REQUIRE(sony2fuji_sample_region_bsh(&buf, &q, &res) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
        q = {SONY2FUJI_BSH_SAMPLE_VERSION, sizeof(q), 0.5f, 1.01f, 0.0f, 0};
        REQUIRE(sony2fuji_sample_region_bsh(&buf, &q, &res) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
        q = {SONY2FUJI_BSH_SAMPLE_VERSION, sizeof(q), 0.5f, 0.5f, -0.01f, 0};
        REQUIRE(sony2fuji_sample_region_bsh(&buf, &q, &res) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
    }

    // 2. RGB8 with non-tight stride & balanced neutrals
    {
        const uint32_t w = 24, h = 24, stride = w * 3 + 5;
        std::vector<uint8_t> px(static_cast<size_t>(stride) * h, 0xAA);
        for (uint32_t y = 0; y < h; ++y) {
            for (uint32_t x = 0; x < w; ++x) {
                const size_t off = static_cast<size_t>(y) * stride + x * 3;
                px[off + 0] = 128;
                px[off + 1] = 128;
                px[off + 2] = 128;
            }
        }
        auto buf = makeRgb8Buffer(px, w, h, stride);
        auto diag = initDiag();
        REQUIRE(sony2fuji_diagnose_image(&buf, nullptr, &diag) == SONY2FUJI_STATUS_OK);
        REQUIRE(diag.width == w && diag.height == h && diag.bit_depth == 8 && diag.channels == 3);
        REQUIRE(diag.sampled_pixels == w * h);
        REQUIRE(diag.cast_hint == SONY2FUJI_BSH_CAST_BALANCED);
        REQUIRE(std::abs(diag.r_over_g - 1.0f) < 1e-4f);
        REQUIRE(std::abs(diag.b_over_g - 1.0f) < 1e-4f);
        REQUIRE(std::abs(diag.midtones_35_65_pct - 100.0f) < 1e-3f);
        REQUIRE(std::abs(diag.low_sat_pct - 100.0f) < 1e-3f);
        for (int c = 0; c < SONY2FUJI_HSL_CHANNELS; ++c) {
            REQUIRE(diag.hsl_channels[c].active == 0);
        }
    }

    // 3. Cast hint regimes across RGBA8 & RGBA16
    {
        struct CastCase {
            uint8_t r, g, b;
            sony2fuji_bsh_cast_hint expected;
        };
        const CastCase cases[] = {
            {145, 128, 110, SONY2FUJI_BSH_CAST_WARM_YELLOW_AMBER},
            {110, 128, 145, SONY2FUJI_BSH_CAST_COOL_BLUE},
            {110, 128, 110, SONY2FUJI_BSH_CAST_GREEN},
            {140, 120, 140, SONY2FUJI_BSH_CAST_MAGENTA},
        };
        for (const auto& tc : cases) {
            const uint32_t w = 20, h = 20;
            std::vector<uint8_t> px(w * h * 4, 255);
            for (size_t i = 0; i < w * h; ++i) {
                px[i * 4 + 0] = tc.r;
                px[i * 4 + 1] = tc.g;
                px[i * 4 + 2] = tc.b;
            }
            auto buf = makeRgba8Buffer(px, w, h, w * 4);
            auto diag = initDiag();
            REQUIRE(sony2fuji_diagnose_image(&buf, nullptr, &diag) == SONY2FUJI_STATUS_OK);
            REQUIRE(diag.cast_hint == tc.expected);
        }
    }

    // 4. Insufficient neutrals (< 20 pixels) & melting saturation & clipping
    {
        const uint32_t w = 4, h = 4; // 16 pixels < 20
        std::vector<uint8_t> px(w * h * 8, 0);
        for (size_t i = 0; i < w * h; ++i) {
            if (i < 4) {
                writeRgba16Pixel(px, i * 8, 0, 0, 0); // shadow crush
            } else if (i < 8) {
                writeRgba16Pixel(px, i * 8, 65535, 65535, 65535); // white blowout
            } else {
                writeRgba16Pixel(px, i * 8, 65535, 1000, 1000); // melting saturation red
            }
        }
        auto buf = makeRgba16Buffer(px, w, h, w * 8);
        auto diag = initDiag();
        REQUIRE(sony2fuji_diagnose_image(&buf, nullptr, &diag) == SONY2FUJI_STATUS_OK);
        REQUIRE(diag.bit_depth == 16 && diag.channels == 4);
        REQUIRE(diag.cast_hint == SONY2FUJI_BSH_CAST_INSUFFICIENT_NEUTRALS);
        REQUIRE(diag.melting_warning == 1);
        REQUIRE(std::abs(diag.shadow_crush_pct - 25.0f) < 0.05f);
        REQUIRE(std::abs(diag.white_blowout_pct - 25.0f) < 0.05f);
        REQUIRE(std::abs(diag.channel_clip_high_r_pct - 75.0f) < 0.05f);
        REQUIRE(diag.hsl_channels[SONY2FUJI_HSL_CHANNEL_RED].active == 1);
        REQUIRE(std::abs(diag.hsl_channels[SONY2FUJI_HSL_CHANNEL_RED].coverage_pct - 50.0f) < 0.05f);
    }

    // 5. Circular hue wrap-around (355 deg + 5 deg -> 0 deg mean)
    {
        const uint32_t w = 20, h = 20;
        std::vector<uint8_t> px(w * h * 4, 255);
        // Half at 355 deg: (255, 0, 21), half at 5 deg: (255, 21, 0)
        for (uint32_t y = 0; y < h; ++y) {
            for (uint32_t x = 0; x < w; ++x) {
                const size_t off = (static_cast<size_t>(y) * w + x) * 4;
                if (x < w / 2) {
                    px[off + 0] = 255; px[off + 1] = 0; px[off + 2] = 21;
                } else {
                    px[off + 0] = 255; px[off + 1] = 21; px[off + 2] = 0;
                }
            }
        }
        auto buf = makeRgba8Buffer(px, w, h, w * 4);
        auto diag = initDiag();
        REQUIRE(sony2fuji_diagnose_image(&buf, nullptr, &diag) == SONY2FUJI_STATUS_OK);
        REQUIRE(diag.hsl_channels[SONY2FUJI_HSL_CHANNEL_RED].active == 1);
        const float mh = diag.hsl_channels[SONY2FUJI_HSL_CHANNEL_RED].mean_hue_deg;
        REQUIRE(mh < 1.0f || mh > 359.0f);
    }

    // 6. Region sampling: 1x1 vs 9x9 box
    {
        const uint32_t w = 31, h = 31;
        std::vector<uint8_t> px(w * h * 4, 255);
        for (uint32_t y = 0; y < h; ++y) {
            for (uint32_t x = 0; x < w; ++x) {
                const size_t off = (static_cast<size_t>(y) * w + x) * 4;
                // Center pixel (15,15) is pure green, neighbors are pure blue -> 1x1 vs 9x9 differ sharply.
                if (x == 15 && y == 15) {
                    px[off + 0] = 0; px[off + 1] = 255; px[off + 2] = 0;
                } else {
                    px[off + 0] = 0; px[off + 1] = 0; px[off + 2] = 255;
                }
            }
        }
        auto buf = makeRgba8Buffer(px, w, h, w * 4);
        sony2fuji_bsh_sample_query q1{SONY2FUJI_BSH_SAMPLE_VERSION, sizeof(q1), 0.5f, 0.5f, 0.0f, 0};
        auto r1 = initSampleResult();
        REQUIRE(sony2fuji_sample_region_bsh(&buf, &q1, &r1) == SONY2FUJI_STATUS_OK);
        REQUIRE(r1.pixel_x == 15 && r1.pixel_y == 15);
        REQUIRE(r1.sample_count == 1);
        REQUIRE(r1.rgb_8bit[0] == 0 && r1.rgb_8bit[1] == 255 && r1.rgb_8bit[2] == 0);
        REQUIRE(r1.nearest_hsl_channel == SONY2FUJI_HSL_CHANNEL_GREEN);

        sony2fuji_bsh_sample_query q9{
            SONY2FUJI_BSH_SAMPLE_VERSION, sizeof(q9), 0.5f, 0.5f, 4.0f / 31.0f, 0
        };
        auto r9 = initSampleResult();
        REQUIRE(sony2fuji_sample_region_bsh(&buf, &q9, &r9) == SONY2FUJI_STATUS_OK);
        REQUIRE(r9.sample_count == 81);
        REQUIRE(r9.nearest_hsl_channel == SONY2FUJI_HSL_CHANNEL_BLUE);
        REQUIRE(r9.linear_rgb[2] > 0.9f);
    }

    // 7. Sample stride override
    {
        const uint32_t w = 20, h = 20;
        std::vector<uint8_t> px(w * h * 4, 255);
        auto buf = makeRgba8Buffer(px, w, h, w * 4);
        sony2fuji_bsh_diagnose_options opts{SONY2FUJI_BSH_DIAGNOSIS_VERSION, sizeof(opts), 2, 0};
        auto diag = initDiag();
        REQUIRE(sony2fuji_diagnose_image(&buf, &opts, &diag) == SONY2FUJI_STATUS_OK);
        REQUIRE(diag.sampled_pixels == 100);
    }

    // 8. Extreme finite radius_norm must clamp cleanly without int64 overflow
    {
        const uint32_t w = 12, h = 10;
        std::vector<uint8_t> px(w * h * 4, 180);
        auto buf = makeRgba8Buffer(px, w, h, w * 4);
        sony2fuji_bsh_sample_query q{SONY2FUJI_BSH_SAMPLE_VERSION, sizeof(q), 0.5f, 0.5f, 1e30f, 0};
        auto res = initSampleResult();
        REQUIRE(sony2fuji_sample_region_bsh(&buf, &q, &res) == SONY2FUJI_STATUS_OK);
        REQUIRE(res.sample_count == w * h);
    }

    // 9. NaN-safe clamp in encodeRgba16BufferFromImageData for both linearToSrgb=false and linearToSrgb=true
    {
        const float qnan = std::numeric_limits<float>::quiet_NaN();
        const float inf = std::numeric_limits<float>::infinity();
        sony2fuji::ImageData img(4, 1);
        img.pixels[0] = {qnan, -qnan, -inf};
        img.pixels[1] = {inf, -0.5f, 1.5f};
        img.pixels[2] = {0.0f, 0.5f, 1.0f};
        img.pixels[3] = {-0.0f, 0.002f, 0.999f};

        auto readChan16 = [](const sony2fuji::OwnedPixelBuffer& buf, size_t pxIdx, size_t chanIdx) -> uint16_t {
            const uint8_t* p = static_cast<const uint8_t*>(buf.data) + pxIdx * 8u + chanIdx * 2u;
            return static_cast<uint16_t>(p[0]) | (static_cast<uint16_t>(p[1]) << 8);
        };

        for (bool linearToSrgb : {false, true}) {
            auto encoded = sony2fuji::encodeRgba16BufferFromImageData(img, linearToSrgb);
            REQUIRE(encoded.data != nullptr);
            REQUIRE(encoded.width == 4 && encoded.height == 1);
            REQUIRE(encoded.format == sony2fuji::PixelBufferFormat::RGBA16);

            // {qnan, -qnan, -inf} -> {0, 0, 0}
            REQUIRE(readChan16(encoded, 0, 0) == 0);
            REQUIRE(readChan16(encoded, 0, 1) == 0);
            REQUIRE(readChan16(encoded, 0, 2) == 0);
            // {+inf, -0.5f, 1.5f} -> {65535, 0, 65535}
            REQUIRE(readChan16(encoded, 1, 0) == 65535);
            REQUIRE(readChan16(encoded, 1, 1) == 0);
            REQUIRE(readChan16(encoded, 1, 2) == 65535);
            // {0.0f, 0.5f, 1.0f}
            REQUIRE(readChan16(encoded, 2, 0) == 0);
            REQUIRE(readChan16(encoded, 2, 2) == 65535);
            if (linearToSrgb) {
                REQUIRE(readChan16(encoded, 2, 1) > 48000);
            } else {
                REQUIRE(readChan16(encoded, 2, 1) == 32768);
            }
            // {-0.0f, ...}
            REQUIRE(readChan16(encoded, 3, 0) == 0);

            sony2fuji_buffer view{};
            view.data = encoded.data;
            view.size_bytes = encoded.sizeBytes;
            view.width = encoded.width;
            view.height = encoded.height;
            view.stride_bytes = encoded.strideBytes;
            view.pixel_format = SONY2FUJI_PIXEL_RGBA16;
            auto diag = initDiag();
            REQUIRE(sony2fuji_diagnose_image(&view, nullptr, &diag) == SONY2FUJI_STATUS_OK);
            REQUIRE(std::isfinite(diag.mean_luma_0_1));
            REQUIRE(diag.mean_luma_0_1 >= 0.0f && diag.mean_luma_0_1 <= 1.0f);
        }
    }

    std::cout << "bsh_diagnostics_tests passed\n";
    return 0;
}
