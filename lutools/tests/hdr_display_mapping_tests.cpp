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
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
    std::cout << "HDR display tests complete, checks: " << rawlab::test::checkCount()
              << ", failures: " << rawlab::test::failureCount() << '\n';
    return rawlab::test::exitCode();
}
