#include "test_harness.h"
#include "core/hdr_half.h"
#include "sony2fuji/ffi/sony2fuji_hdr.h"

#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <limits>
#include <string>
#include <vector>

namespace {
using rawlab::test::check;

constexpr float kNaN = std::numeric_limits<float>::quiet_NaN();

sony2fuji_hdr_buffer_v1 plane(std::vector<float>& values, uint32_t width, uint32_t height, uint64_t strideFloats = 0) {
    sony2fuji_hdr_buffer_v1 buffer{};
    buffer.version = SONY2FUJI_HDR_VERSION;
    buffer.struct_size = sizeof(buffer);
    buffer.data = values.data();
    buffer.size_bytes = values.size() * sizeof(float);
    buffer.width = width;
    buffer.height = height;
    buffer.stride_bytes = (strideFloats ? strideFloats : uint64_t(width) * 3) * sizeof(float);
    buffer.pixel_format = SONY2FUJI_HDR_RGB32F_LINEAR;
    buffer.color_encoding = SONY2FUJI_HDR_LINEAR_SRGB;
    buffer.content_headroom = 1;
    buffer.headroom_kind = SONY2FUJI_HDR_HEADROOM_MEASURED;
    return buffer;
}

struct Stats {
    sony2fuji_status status;
    std::array<uint32_t, SONY2FUJI_HDR_LUMINANCE_BINS> bins;
    uint32_t above;
    float peak;
};

Stats analyze(const sony2fuji_hdr_buffer_v1& buffer) {
    Stats s{};
    s.bins.fill(0xdeadbeef);
    s.above = 0xdeadbeef;
    s.peak = -1;
    s.status = sony2fuji_hdr_analyze_luminance(&buffer, s.bins.data(), &s.above, &s.peak);
    return s;
}

uint32_t total(const Stats& s) {
    uint32_t sum = 0;
    for (auto bin : s.bins) sum += bin;
    return sum;
}

void testLuminanceStatistics() {
    // 灰阶 0、1、2、4：EV 依次落在 -8 截断档、0 EV、+1 EV、+2 EV。
    std::vector<float> gray{0, 0, 0, 1, 1, 1, 2, 2, 2, 4, 4, 4};
    auto s = analyze(plane(gray, 4, 1));
    check(s.status == SONY2FUJI_STATUS_OK, "analyze succeeds on finite gray ramp");
    check(s.bins[0] == 1 && s.bins[144] == 1 && s.bins[160] == 1 && total(s) == 4,
          "zero luminance counts in bin 0 and 2/4 land at +1/+2 EV (16 bins per EV)");
    check(s.bins[127] + s.bins[128] == 1, "reference white lands at the 0 EV edge");
    check(s.above == 2, "above_white counts luminance strictly greater than 1");
    check(s.peak == 4.0f, "peak luminance is the brightest pixel");

    // 负亮度与极暗值落在 0 档，>= 2^8 落在 255 档；全暗时峰值保持 1。
    std::vector<float> extremes{-1, 0, 0, 0.001f, 0.001f, 0.001f, 256, 256, 256, 3000, 3000, 3000};
    s = analyze(plane(extremes, 4, 1));
    check(s.status == SONY2FUJI_STATUS_OK && s.bins[0] == 2 && s.bins[255] == 2 && total(s) == 4,
          "out-of-range luminance clamps into the first and last bins");
    std::vector<float> dark(3 * 6, 0.1f);
    s = analyze(plane(dark, 3, 2));
    check(s.status == SONY2FUJI_STATUS_OK && s.peak == 1.0f && s.above == 0, "peak never drops below 1");

    // 行尾填充（含 NaN）不参与统计，证明按 stride 取行。
    std::vector<float> padded{2, 2, 2, kNaN, 8, 8, 8, kNaN};
    s = analyze(plane(padded, 1, 2, 4));
    check(s.status == SONY2FUJI_STATUS_OK && s.bins[144] == 1 && s.bins[176] == 1 && s.peak == 8.0f,
          "row padding is skipped by stride");

    std::vector<float> nonfinite{1, 1, 1, 2, kNaN, 2};
    s = analyze(plane(nonfinite, 2, 1));
    check(s.status == SONY2FUJI_STATUS_INVALID_ARGUMENT, "non-finite sample is rejected");
    check(s.bins[0] == 0xdeadbeef && s.above == 0xdeadbeef && s.peak == -1, "outputs untouched on failure");
    std::vector<float> infinite{std::numeric_limits<float>::infinity(), 0, 0};
    check(analyze(plane(infinite, 1, 1)).status == SONY2FUJI_STATUS_INVALID_ARGUMENT, "infinite sample is rejected");
}

void testStatisticsRejectsInvalidBuffers() {
    std::vector<float> values(12, 1);
    auto base = plane(values, 2, 2);
    std::array<uint32_t, SONY2FUJI_HDR_LUMINANCE_BINS> bins{};
    uint32_t above = 0;
    float peak = 0;
    check(sony2fuji_hdr_analyze_luminance(nullptr, bins.data(), &above, &peak) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "null image rejected");
    check(sony2fuji_hdr_analyze_luminance(&base, nullptr, &above, &peak) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "null bins rejected");
    check(sony2fuji_hdr_analyze_luminance(&base, bins.data(), nullptr, &peak) == SONY2FUJI_STATUS_INVALID_ARGUMENT &&
          sony2fuji_hdr_analyze_luminance(&base, bins.data(), &above, nullptr) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "null scalar outputs rejected");
    auto bad = base; bad.width = 0;
    check(analyze(bad).status == SONY2FUJI_STATUS_INVALID_ARGUMENT, "zero width rejected");
    bad = base; bad.height = 0;
    check(analyze(bad).status == SONY2FUJI_STATUS_INVALID_ARGUMENT, "zero height rejected");
    bad = base; bad.size_bytes -= 4;
    check(analyze(bad).status == SONY2FUJI_STATUS_INVALID_ARGUMENT, "truncated buffer rejected");
    bad = base; bad.stride_bytes = 13;
    check(analyze(bad).status == SONY2FUJI_STATUS_INVALID_ARGUMENT, "stride shorter than a row rejected");
    bad = base; bad.stride_bytes = 26; bad.size_bytes = 64;
    check(analyze(bad).status == SONY2FUJI_STATUS_INVALID_ARGUMENT, "stride that is not a float multiple rejected");
    bad = base; bad.height = 3; bad.stride_bytes = std::numeric_limits<uint64_t>::max() / 2;
    bad.size_bytes = std::numeric_limits<uint64_t>::max();
    check(analyze(bad).status == SONY2FUJI_STATUS_INVALID_ARGUMENT, "overflowing stride arithmetic rejected");
    // 128MP 上限在读像素之前拒绝；size_bytes 虚报也不会越界读取。
    bad = base; bad.width = 16000; bad.height = 8001; bad.stride_bytes = 16000ull * 12;
    bad.size_bytes = bad.stride_bytes * bad.height;
    check(analyze(bad).status == SONY2FUJI_STATUS_INVALID_ARGUMENT, "more than 128,000,000 pixels rejected");
    bad = base; bad.pixel_format = SONY2FUJI_HDR_RGB8_SRGB;
    check(analyze(bad).status == SONY2FUJI_STATUS_INVALID_ARGUMENT, "non-float pixel format rejected");
    bad = base; bad.color_encoding = SONY2FUJI_HDR_DISPLAY_SRGB;
    check(analyze(bad).status == SONY2FUJI_STATUS_INVALID_ARGUMENT, "display-encoded buffer rejected");
    bad = base; bad.version = 2;
    check(analyze(bad).status == SONY2FUJI_STATUS_UNSUPPORTED, "unknown buffer version unsupported");
    bad = base; bad.struct_size = sizeof(bad) - 4;
    check(analyze(bad).status == SONY2FUJI_STATUS_INVALID_ARGUMENT, "truncated buffer struct rejected");
}

std::vector<uint16_t> display16(sony2fuji_hdr_buffer_v1 hdr, sony2fuji_hdr_buffer_v1* sdr, float displayHeadroom,
                                float contentHeadroom, uint32_t flags, sony2fuji_status& status) {
    std::vector<uint16_t> out(size_t(hdr.width) * hdr.height * 4, 0xffff);
    status = sony2fuji_hdr_display_into(&hdr, sdr, displayHeadroom, contentHeadroom, flags, out.data(),
        out.size() * 2, uint64_t(hdr.width) * 8);
    return out;
}

uint16_t half(float value) { return sony2fuji::hdr::floatToHalf(value); }

bool pixelIs(const std::vector<uint16_t>& out, size_t pixel, float r, float g, float b) {
    return out[pixel * 4] == half(r) && out[pixel * 4 + 1] == half(g) && out[pixel * 4 + 2] == half(b) &&
           out[pixel * 4 + 3] == 0x3c00;
}

void testDisplayMapping() {
    std::vector<float> hdrValues{4, 4, 4};
    std::vector<float> sdrValues{0.5f, 0.5f, 0.5f};
    auto hdr = plane(hdrValues, 1, 1);
    auto sdr = plane(sdrValues, 1, 1);
    sony2fuji_status status;

    auto out = display16(hdr, &sdr, 8, 4, SONY2FUJI_HDR_DISPLAY_SDR, status);
    check(status == SONY2FUJI_STATUS_OK && pixelIs(out, 0, 0.5f, 0.5f, 0.5f), "SDR mode shows the SDR rendition");
    out = display16(hdr, &sdr, 1, 4, 0, status);
    check(status == SONY2FUJI_STATUS_OK && pixelIs(out, 0, 0.5f, 0.5f, 0.5f), "display headroom 1 falls back to SDR");
    out = display16(hdr, &sdr, kNaN, 4, 0, status);
    check(status == SONY2FUJI_STATUS_OK && pixelIs(out, 0, 0.5f, 0.5f, 0.5f), "non-finite display headroom acts as 1");
    out = display16(hdr, &sdr, 8, 4, 0, status);
    check(status == SONY2FUJI_STATUS_OK && pixelIs(out, 0, 4, 4, 4), "content within display headroom is unchanged");
    out = display16(hdr, &sdr, 2, 4, 0, status);
    check(status == SONY2FUJI_STATUS_OK && pixelIs(out, 0, 2, 2, 2), "shoulder maps content peak onto display headroom");

    // 参考白以下不受肩部影响；肩部把内容峰值 8 压到屏幕容量 4。
    std::vector<float> ramp{0.5f, 0.5f, 0.5f, 8, 8, 8};
    std::vector<float> ramSdr(6, 0.25f);
    auto rampHdr = plane(ramp, 2, 1);
    auto rampSdr = plane(ramSdr, 2, 1);
    out = display16(rampHdr, &rampSdr, 4, 8, 0, status);
    check(status == SONY2FUJI_STATUS_OK && pixelIs(out, 0, 0.5f, 0.5f, 0.5f) && pixelIs(out, 1, 4, 4, 4),
          "shoulder keeps values below white and lands the peak on the display");

    // SDR 默认不夹取（Android 现有行为）；CLAMP_SDR 与 P3 复现 Apple 的显示约定。
    std::vector<float> wide{1.5f, -0.25f, 0.5f};
    auto wideSdr = plane(wide, 1, 1);
    out = display16(hdr, &wideSdr, 4, 4, SONY2FUJI_HDR_DISPLAY_SDR, status);
    check(status == SONY2FUJI_STATUS_OK && pixelIs(out, 0, 1.5f, -0.25f, 0.5f), "SDR plane passes through unclamped");
    out = display16(hdr, &wideSdr, 4, 4, SONY2FUJI_HDR_DISPLAY_SDR | SONY2FUJI_HDR_DISPLAY_CLAMP_SDR, status);
    check(status == SONY2FUJI_STATUS_OK && pixelIs(out, 0, 1, 0, 0.5f), "CLAMP_SDR clamps the SDR plane to [0, 1]");
    std::vector<float> red{1, 0, 0};
    auto redSdr = plane(red, 1, 1);
    out = display16(hdr, &redSdr, 4, 4,
        SONY2FUJI_HDR_DISPLAY_SDR | SONY2FUJI_HDR_DISPLAY_P3 | SONY2FUJI_HDR_DISPLAY_CLAMP_SDR, status);
    check(status == SONY2FUJI_STATUS_OK && pixelIs(out, 0, 0.8224619687143623f, 0.03319419885096156f, 0.01708263072112004f),
          "P3 converts linear sRGB primaries to linear Display P3");
    out = display16(hdr, &sdr, 4, 4, SONY2FUJI_HDR_DISPLAY_SDR | SONY2FUJI_HDR_DISPLAY_P3, status);
    check(status == SONY2FUJI_STATUS_OK && pixelIs(out, 0, 0.5f, 0.5f, 0.5f), "P3 conversion keeps the gray axis");
    out = display16(hdr, &sdr, 8, 4, SONY2FUJI_HDR_DISPLAY_P3 | SONY2FUJI_HDR_DISPLAY_CLAMP_SDR, status);
    check(status == SONY2FUJI_STATUS_OK && pixelIs(out, 0, 4, 4, 4), "CLAMP_SDR leaves the HDR presentation extended");
}

void testFalseColor() {
    // 亮度 0（阴影）、0.5（中间调）、1.5（参考白以上）、3（超出屏幕容量 2）。
    std::vector<float> bands{0, 0, 0, 0.5f, 0.5f, 0.5f, 1.5f, 1.5f, 1.5f, 3, 3, 3};
    auto hdr = plane(bands, 4, 1);
    sony2fuji_status status;
    auto out = display16(hdr, nullptr, 2, 3, SONY2FUJI_HDR_DISPLAY_FALSE_COLOR | SONY2FUJI_HDR_DISPLAY_P3, status);
    check(status == SONY2FUJI_STATUS_OK && pixelIs(out, 0, 0.02f, 0.15f, 0.7f) && pixelIs(out, 1, 0.35f, 0.35f, 0.35f) &&
          pixelIs(out, 2, 1, 0.6f, 0) && pixelIs(out, 3, 1, 0, 0.35f),
          "false-color bands ignore P3 and SDR and need no SDR plane");

    // Windows WPF 回退：sRGB 编码的不透明 BGRA8，与原 C# 常量逐字节一致。
    std::vector<uint8_t> bgra(4 * 4 + 8, 0x5a);
    status = sony2fuji_hdr_display_into(&hdr, nullptr, 2, 1,
        SONY2FUJI_HDR_DISPLAY_FALSE_COLOR | SONY2FUJI_HDR_DISPLAY_BGRA8_SRGB, bgra.data(), bgra.size(), 16);
    const std::vector<uint8_t> expected{218, 108, 39, 255, 160, 160, 160, 255, 0, 203, 255, 255, 160, 0, 255, 255};
    check(status == SONY2FUJI_STATUS_OK && std::equal(expected.begin(), expected.end(), bgra.begin()),
          "BGRA8 false color matches the Windows palette bytes");
    check(bgra[16] == 0x5a && bgra[23] == 0x5a, "bytes past the written rows stay untouched");
}

void testDisplayOutputLimitsAndLayout() {
    sony2fuji_status status;
    std::vector<float> limit{65504, 1, 1, -65504, 1, 1};
    std::vector<float> limitSdr(6, 0);
    auto hdr = plane(limit, 2, 1);
    auto sdr = plane(limitSdr, 2, 1);
    auto out = display16(hdr, &sdr, 2, 1, 0, status);
    check(status == SONY2FUJI_STATUS_OK && out[0] == 0x7bff && out[4] == 0xfbff, "+-65504 is the largest packable half");
    std::vector<float> over{65505, 1, 1};
    std::vector<float> overSdr(3, 0);
    auto overHdr = plane(over, 1, 1);
    auto overSdrPlane = plane(overSdr, 1, 1);
    display16(overHdr, &overSdrPlane, 2, 1, 0, status);
    check(status == SONY2FUJI_STATUS_PROCESSING_ERROR, "RGBA16F channel beyond 65504 is unrepresentable");
    std::vector<uint8_t> bgra(4);
    status = sony2fuji_hdr_display_into(&overHdr, &overHdr, 2, 1,
        SONY2FUJI_HDR_DISPLAY_SDR | SONY2FUJI_HDR_DISPLAY_BGRA8_SRGB, bgra.data(), 4, 4);
    check(status == SONY2FUJI_STATUS_OK && bgra[2] == 255 && bgra[0] == 255 && bgra[3] == 255,
          "BGRA8 encodes out-of-range SDR values by clamping");

    // 输出行距大于一行时，行尾填充保持原样。
    std::vector<float> two(12, 0.5f);
    auto twoHdr = plane(two, 2, 2);
    std::vector<uint16_t> strided(2 * 10, 0x1234);
    status = sony2fuji_hdr_display_into(&twoHdr, &twoHdr, 4, 4, SONY2FUJI_HDR_DISPLAY_SDR, strided.data(),
        strided.size() * 2, 20);
    check(status == SONY2FUJI_STATUS_OK && strided[0] == half(0.5f) && strided[8] == 0x1234 && strided[9] == 0x1234 &&
          strided[10] == half(0.5f) && strided[17] == 0x3c00 && strided[18] == 0x1234,
          "destination stride leaves row padding untouched");
}

void testDisplayRejectsInvalidInput() {
    std::vector<float> hdrValues(12, 2);
    std::vector<float> sdrValues(12, 0.5f);
    auto hdr = plane(hdrValues, 2, 2);
    auto sdr = plane(sdrValues, 2, 2);
    std::vector<uint16_t> out(16);
    const auto call = [&](const sony2fuji_hdr_buffer_v1* h, const sony2fuji_hdr_buffer_v1* s, float display, float content,
                          uint32_t flags, void* dst, uint64_t size, uint64_t stride) {
        return sony2fuji_hdr_display_into(h, s, display, content, flags, dst, size, stride);
    };
    check(call(&hdr, &sdr, 2, 4, 0, out.data(), 32, 16) == SONY2FUJI_STATUS_OK, "valid baseline call succeeds");
    check(call(nullptr, &sdr, 2, 4, 0, out.data(), 32, 16) == SONY2FUJI_STATUS_INVALID_ARGUMENT, "null HDR plane rejected");
    check(call(&hdr, nullptr, 2, 4, 0, out.data(), 32, 16) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "SDR plane required outside false color");
    check(call(&hdr, &sdr, 2, 4, 0, nullptr, 32, 16) == SONY2FUJI_STATUS_INVALID_ARGUMENT, "null destination rejected");
    check(call(&hdr, &sdr, 2, 4, 32, out.data(), 32, 16) == SONY2FUJI_STATUS_INVALID_ARGUMENT, "unknown flag rejected");
    check(call(&hdr, &sdr, 2, kNaN, 0, out.data(), 32, 16) == SONY2FUJI_STATUS_INVALID_ARGUMENT &&
          call(&hdr, &sdr, 2, 0.5f, 0, out.data(), 32, 16) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "content headroom must be finite and at least 1");
    check(call(&hdr, &sdr, 2, 4, 0, out.data(), 31, 16) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "short destination rejected");
    check(call(&hdr, &sdr, 2, 4, 0, out.data(), 32, 15) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "destination stride shorter than a row rejected");
    std::vector<float> column(9, 0.5f);
    auto tall = plane(column, 1, 3);
    check(call(&tall, &tall, 2, 4, 0, out.data(), std::numeric_limits<uint64_t>::max(),
               std::numeric_limits<uint64_t>::max() / 2 + 1) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "overflowing destination arithmetic rejected");
    check(call(&hdr, &sdr, 2, 4, 0, hdrValues.data(), 32, 16) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "destination aliasing the source rejected");
    std::vector<float> small(3, 0.5f);
    auto smallSdr = plane(small, 1, 1);
    check(call(&hdr, &smallSdr, 2, 4, 0, out.data(), 32, 16) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "mismatched SDR dimensions rejected");
    auto bad = hdr; bad.width = 0;
    check(call(&bad, &sdr, 2, 4, 0, out.data(), 32, 16) == SONY2FUJI_STATUS_INVALID_ARGUMENT, "zero-size plane rejected");
    bad = hdr; bad.width = 16000; bad.height = 8001; bad.stride_bytes = 16000ull * 12; bad.size_bytes = bad.stride_bytes * 8001;
    check(call(&bad, nullptr, 2, 4, SONY2FUJI_HDR_DISPLAY_FALSE_COLOR, out.data(), std::numeric_limits<uint64_t>::max(),
               16000ull * 8) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "more than 128,000,000 pixels rejected");

    std::vector<float> nanSdr{0.5f, 0.5f, 0.5f, 0.5f, kNaN, 0.5f, 0.5f, 0.5f, 0.5f, 0.5f, 0.5f, 0.5f};
    auto nanSdrPlane = plane(nanSdr, 2, 2);
    check(call(&hdr, &nanSdrPlane, 2, 4, 0, out.data(), 32, 16) == SONY2FUJI_STATUS_INVALID_ARGUMENT &&
          call(&hdr, &nanSdrPlane, 2, 4, SONY2FUJI_HDR_DISPLAY_FALSE_COLOR, out.data(), 32, 16) ==
              SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "non-finite SDR sample rejected in every mode, as before");
    std::vector<float> nanHdr = hdrValues;
    nanHdr[7] = std::numeric_limits<float>::infinity();
    auto nanHdrPlane = plane(nanHdr, 2, 2);
    check(call(&nanHdrPlane, nullptr, 2, 4, SONY2FUJI_HDR_DISPLAY_FALSE_COLOR, out.data(), 32, 16) ==
              SONY2FUJI_STATUS_INVALID_ARGUMENT &&
          call(&nanHdrPlane, &sdr, 2, 4, SONY2FUJI_HDR_DISPLAY_SDR, out.data(), 32, 16) ==
              SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "non-finite HDR sample rejected even when SDR is shown");
}

void testFlagCombinations() {
    std::vector<float> hdrValues(12, 2);
    std::vector<float> sdrValues(12, 0.5f);
    auto hdr = plane(hdrValues, 2, 2);
    auto sdr = plane(sdrValues, 2, 2);
    std::vector<uint16_t> out16(16);
    std::vector<uint8_t> out8(16);
    const auto rgba16 = [&](uint32_t flags, const sony2fuji_hdr_buffer_v1* s) {
        return sony2fuji_hdr_display_into(&hdr, s, 2, 4, flags, out16.data(), 32, 16);
    };
    const auto bgra8 = [&](uint32_t flags, const sony2fuji_hdr_buffer_v1* s) {
        return sony2fuji_hdr_display_into(&hdr, s, 2, 4, flags | SONY2FUJI_HDR_DISPLAY_BGRA8_SRGB, out8.data(), 16, 8);
    };
    constexpr uint32_t sdrFlag = SONY2FUJI_HDR_DISPLAY_SDR, falseColor = SONY2FUJI_HDR_DISPLAY_FALSE_COLOR;
    constexpr uint32_t p3 = SONY2FUJI_HDR_DISPLAY_P3, clamp = SONY2FUJI_HDR_DISPLAY_CLAMP_SDR;
    // RGBA16F 下四个呈现标志任意组合都有确定含义（各端现有调用都在其中）。
    bool all = true;
    for (uint32_t flags = 0; flags < 16; ++flags) all = all && rgba16(flags, &sdr) == SONY2FUJI_STATUS_OK;
    check(all, "every RGBA16F combination of SDR, FALSE_COLOR, P3 and CLAMP_SDR is accepted");
    check(bgra8(falseColor, nullptr) == SONY2FUJI_STATUS_OK && bgra8(sdrFlag, &sdr) == SONY2FUJI_STATUS_OK &&
          bgra8(sdrFlag | clamp, &sdr) == SONY2FUJI_STATUS_OK && bgra8(falseColor | sdrFlag, &sdr) == SONY2FUJI_STATUS_OK,
          "BGRA8 is accepted for false color and for the SDR plane");
    check(bgra8(sdrFlag | p3, &sdr) == SONY2FUJI_STATUS_INVALID_ARGUMENT &&
          bgra8(falseColor | p3, nullptr) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "P3 values under sRGB BGRA8 encoding are rejected");
    check(bgra8(0, &sdr) == SONY2FUJI_STATUS_INVALID_ARGUMENT && bgra8(clamp, &sdr) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "BGRA8 without SDR or FALSE_COLOR (extended HDR in 8 bits) is rejected");
    // 假色是 HDR 平面的监看视图：带不带 SDR、P3、CLAMP_SDR 结果相同。
    rgba16(falseColor, &sdr);
    const auto plain = out16;
    rgba16(falseColor | sdrFlag | p3 | clamp, &sdr);
    check(out16 == plain && out16[0] == half(1) && out16[1] == half(0.6f) && out16[2] == 0,
          "false color ignores the presentation flags");
}

// 肩部 y -> 1 + (y - 1) / (1 + a (y - 1))，a = (c - h) / ((h - 1)(c - 1))：除端点外还锁定中间点，
// 换成线性压缩或其他曲线都会失败。
void testShoulderCurve() {
    const double c = 8, h = 4, a = (c - h) / ((h - 1) * (c - 1));
    const std::vector<float> ys{1.25f, 1.5f, 2, 3, 4, 5, 6, 7, 8};
    std::vector<float> gray, sdrValues;
    for (float y : ys) { gray.insert(gray.end(), {y, y, y}); sdrValues.insert(sdrValues.end(), {0.5f, 0.5f, 0.5f}); }
    auto hdr = plane(gray, uint32_t(ys.size()), 1);
    auto sdr = plane(sdrValues, uint32_t(ys.size()), 1);
    sony2fuji_status status;
    const auto out = display16(hdr, &sdr, float(h), float(c), 0, status);
    bool onCurve = status == SONY2FUJI_STATUS_OK;
    double previous = 1, previousSlope = 2;
    for (size_t i = 0; i < ys.size() && onCurve; ++i) {
        const double expected = 1 + (ys[i] - 1) / (1 + a * (ys[i] - 1));
        const double actual = sony2fuji::hdr::halfToFloat(out[i * 4]);
        onCurve = std::fabs(actual - expected) <= expected * 0.001 && out[i * 4] == out[i * 4 + 1] &&
                  out[i * 4] == out[i * 4 + 2];
        const double slope = (actual - previous) / (ys[i] - (i ? ys[i - 1] : 1.0));
        onCurve = onCurve && slope < previousSlope; // 凹函数：斜率随亮度单调下降
        previous = actual; previousSlope = slope;
    }
    check(onCurve, "shoulder follows 1 + (y-1)/(1 + a(y-1)) at intermediate points, gray stays gray");
    check(std::fabs(sony2fuji::hdr::halfToFloat(out[2 * 4]) - 1.84) < 0.002 &&
          std::fabs(sony2fuji::hdr::halfToFloat(out[4 * 4]) - 32.0 / 11.0) < 0.003,
          "shoulder maps 2 -> 1.84 and 4 -> 32/11 for content 8 on a display of 4");
    // 色度比例保持：彩色像素按同一亮度比例缩放。
    std::vector<float> color{6, 3, 1.5f};
    std::vector<float> colorSdr(3, 0.5f);
    auto colorSdrPlane = plane(colorSdr, 1, 1);
    const auto colored = display16(plane(color, 1, 1), &colorSdrPlane, float(h), float(c), 0, status);
    const double r = sony2fuji::hdr::halfToFloat(colored[0]), g = sony2fuji::hdr::halfToFloat(colored[1]),
                 b = sony2fuji::hdr::halfToFloat(colored[2]);
    check(status == SONY2FUJI_STATUS_OK && std::fabs(r / g - 2) < 0.004 && std::fabs(g / b - 2) < 0.004,
          "shoulder scales all channels by the same luminance ratio");
}

struct GoldenCase {
    float headroom;
    uint32_t flags;
    std::vector<uint16_t> halves;
};

// 与 RawLabMac/tests/HDRCanvasTests.swift、RawLab/tests/HDRCanvasTests.swift 的 Metal 对照金标为同一组数：
// 核心逻辑变化会在这里先失败，提醒同步重新生成 Metal 对照期望值。
void checkGolden(const char* name, const std::vector<float>& hdrValues, const std::vector<float>& sdrValues,
                 uint32_t peakBits, const std::vector<GoldenCase>& cases) {
    auto hdrCopy = hdrValues, sdrCopy = sdrValues;
    const auto width = uint32_t(hdrValues.size() / 3);
    auto hdr = plane(hdrCopy, width, 1);
    auto sdr = plane(sdrCopy, width, 1);
    const auto stats = analyze(hdr);
    uint32_t peakActual;
    std::memcpy(&peakActual, &stats.peak, sizeof(peakActual));
    check(stats.status == SONY2FUJI_STATUS_OK && peakActual == peakBits,
          std::string(name) + " Metal parity content headroom matches the core peak");
    float peak;
    std::memcpy(&peak, &peakBits, sizeof(peak));
    for (const auto& golden : cases) {
        sony2fuji_status status;
        const auto out = display16(hdr, &sdr, golden.headroom, peak,
            SONY2FUJI_HDR_DISPLAY_P3 | SONY2FUJI_HDR_DISPLAY_CLAMP_SDR | golden.flags, status);
        bool same = status == SONY2FUJI_STATUS_OK;
        for (uint32_t i = 0; i < width && same; ++i)
            for (int ch = 0; ch < 3; ++ch) same = same && out[i * 4 + ch] == golden.halves[i * 3 + ch];
        check(same, std::string(name) + " Metal parity golden, headroom " + std::to_string(golden.headroom) +
              " flags " + std::to_string(golden.flags));
    }
}

void testMetalParityGoldens() {
    constexpr uint32_t sdrFlag = SONY2FUJI_HDR_DISPLAY_SDR, falseColor = SONY2FUJI_HDR_DISPLAY_FALSE_COLOR;
    checkGolden("Mac",
        {0.002f, 0.005f, 0.001f, 0.5f, 0.4f, 0.3f, 1.5f, 1.4f, 1.2f, 6, 5, 4, 12, 9, 7, 0, 1.2f, 0.3f},
        {0.002f, 0.005f, 0.001f, 0.5f, 0.4f, 0.3f, 1, 0.9f, 0.8f, 1, 1, 1, 1, 1, 1, 0, 1, 0.3f}, 0x4117e4f7, {
        {1.0f, 0, {0x1930, 0x1d05, 0x155a, 0x37b7, 0x3674, 0x34f8, 0x3bdc, 0x3b3a, 0x3a7c,
                   0x3c00, 0x3c00, 0x3c00, 0x3c00, 0x3c00, 0x3c00, 0x31ae, 0x3bbc, 0x3587}},
        {1.005f, 0, {0x1930, 0x1d05, 0x155a, 0x37b7, 0x3674, 0x34f8, 0x3c3c, 0x3c03, 0x3af8,
                     0x3c8e, 0x3bdf, 0x3a6c, 0x3cdb, 0x3bb5, 0x3a20, 0x32d1, 0x3ca4, 0x35c3}},
        {2.0f, 0, {0x1930, 0x1d05, 0x155a, 0x37b7, 0x3674, 0x34f8, 0x3d7a, 0x3d2f, 0x3c81,
                   0x4048, 0x3f67, 0x3e0a, 0x40d5, 0x3fab, 0x3e18, 0x32d1, 0x3ca4, 0x35c3}},
        {4.0f, 0, {0x1930, 0x1d05, 0x155a, 0x37b7, 0x3674, 0x34f8, 0x3dca, 0x3d7b, 0x3cc4,
                   0x4339, 0x423e, 0x4118, 0x44d5, 0x43ab, 0x4218, 0x32d1, 0x3ca4, 0x35c3}},
        {8.0f, 0, {0x1930, 0x1d05, 0x155a, 0x37b7, 0x3674, 0x34f8, 0x3de9, 0x3d99, 0x3cdd,
                   0x4561, 0x44a7, 0x4397, 0x48d5, 0x47ab, 0x4618, 0x32d1, 0x3ca4, 0x35c3}},
        {4.0f, sdrFlag, {0x1930, 0x1d05, 0x155a, 0x37b7, 0x3674, 0x34f8, 0x3bdc, 0x3b3a, 0x3a7c,
                         0x3c00, 0x3c00, 0x3c00, 0x3c00, 0x3c00, 0x3c00, 0x31ae, 0x3bbc, 0x3587}},
        {2.0f, falseColor, {0x251f, 0x30cd, 0x399a, 0x359a, 0x359a, 0x359a, 0x3c00, 0x38cd, 0x0000,
                            0x3c00, 0x0000, 0x359a, 0x3c00, 0x0000, 0x359a, 0x359a, 0x359a, 0x359a}},
    });
    checkGolden("iOS",
        {0.002f, 0.005f, 0.001f, 0.5f, 0.4f, 0.3f, 6, 5, 4},
        {0.002f, 0.005f, 0.001f, 0.5f, 0.4f, 0.3f, 1, 1, 1}, 0x40a47e28, {
        {1.0f, 0, {0x1930, 0x1d05, 0x155a, 0x37b7, 0x3674, 0x34f8, 0x3c00, 0x3c00, 0x3c00}},
        {2.0f, 0, {0x1930, 0x1d05, 0x155a, 0x37b7, 0x3674, 0x34f8, 0x4088, 0x3fd5, 0x3e64}},
        {4.0f, sdrFlag, {0x1930, 0x1d05, 0x155a, 0x37b7, 0x3674, 0x34f8, 0x3c00, 0x3c00, 0x3c00}},
        {2.0f, falseColor, {0x251f, 0x30cd, 0x399a, 0x359a, 0x359a, 0x359a, 0x3c00, 0x0000, 0x359a}},
    });
}

} // namespace

int main() {
    try {
        testLuminanceStatistics();
        testStatisticsRejectsInvalidBuffers();
        testDisplayMapping();
        testFalseColor();
        testDisplayOutputLimitsAndLayout();
        testDisplayRejectsInvalidInput();
        testFlagCombinations();
        testShoulderCurve();
        testMetalParityGoldens();
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
    std::cout << "HDR display tests complete, checks: " << rawlab::test::checkCount()
              << ", failures: " << rawlab::test::failureCount() << '\n';
    return rawlab::test::exitCode();
}
