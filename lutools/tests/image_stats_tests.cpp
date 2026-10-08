#include "gpu/image_stats.h"
#include "sony2fuji/ffi/sony2fuji_c.h"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <iterator>
#include <limits>
#include <numeric>
#include <string>
#include <vector>

namespace {

int failures = 0;

void check(bool condition, const std::string& name) {
    std::cout << (condition ? "PASS " : "FAIL ") << name << '\n';
    if (!condition) {
        ++failures;
    }
}

struct Fixture {
    std::vector<uint8_t> bytes;
    sony2fuji_buffer buffer{};
    uint32_t channels = 0;

    Fixture(uint32_t width, uint32_t height, uint32_t channelCount, uint32_t padding)
        : channels(channelCount) {
        const size_t rowBytes = static_cast<size_t>(width) * channelCount;
        const size_t stride = rowBytes + padding;
        bytes.assign(stride * height, 0xcd);
        buffer.width = width;
        buffer.height = height;
        buffer.stride_bytes = static_cast<uint32_t>(stride);
        buffer.size_bytes = bytes.size();
        buffer.pixel_format = channelCount == 4 ? SONY2FUJI_PIXEL_RGBA8 : SONY2FUJI_PIXEL_RGB8;
    }

    void bind() {
        buffer.data = bytes.data();
    }

    uint8_t* pixel(uint32_t x, uint32_t y) {
        return bytes.data() + static_cast<size_t>(y) * buffer.stride_bytes +
            static_cast<size_t>(x) * channels;
    }
};

sony2fuji::ImageStats expectedStats(const sony2fuji_buffer& buffer) {
    sony2fuji::ImageStats result;
    const uint32_t channels = buffer.pixel_format == SONY2FUJI_PIXEL_RGBA8 ? 4 : 3;
    result.clipping.assign(static_cast<size_t>(buffer.width) * buffer.height * 4, 0);
    const auto* data = static_cast<const uint8_t*>(buffer.data);
    for (uint32_t y = 0; y < buffer.height; ++y) {
        const auto* row = data + static_cast<size_t>(y) * buffer.stride_bytes;
        for (uint32_t x = 0; x < buffer.width; ++x) {
            const size_t offset = static_cast<size_t>(x) * channels;
            const uint8_t r = row[offset];
            const uint8_t g = row[offset + 1];
            const uint8_t b = row[offset + 2];
            ++result.histogram[r];
            ++result.histogram[256 + g];
            ++result.histogram[512 + b];
            auto* mask = result.clipping.data() +
                (static_cast<size_t>(y) * buffer.width + x) * 4;
            if (r == 255 || g == 255 || b == 255) {
                ++result.highlights;
                mask[0] = 255;
                mask[3] = 160;
            } else if (r == 0 && g == 0 && b == 0) {
                ++result.shadows;
                mask[1] = 130;
                mask[2] = 255;
                mask[3] = 160;
            }
        }
    }
    return result;
}

bool sameStats(const sony2fuji::ImageStats& left, const sony2fuji::ImageStats& right) {
    return left.histogram == right.histogram &&
        left.shadows == right.shadows &&
        left.highlights == right.highlights &&
        left.clipping == right.clipping;
}

uint64_t checksumBytes(const std::vector<uint8_t>& bytes) {
    uint64_t hash = 1469598103934665603ull;
    for (uint8_t byte : bytes) {
        hash ^= byte;
        hash *= 1099511628211ull;
    }
    return hash;
}

bool samePublicStats(const sony2fuji::ImageStats& expected,
                     const uint32_t* bins, uint32_t shadows, uint32_t highlights,
                     const sony2fuji_buffer* clipping) {
    if (!bins || !std::equal(expected.histogram.begin(), expected.histogram.end(), bins) ||
        shadows != expected.shadows || highlights != expected.highlights) {
        return false;
    }
    if (!clipping) {
        return true;
    }
    if (!clipping->data || clipping->size_bytes != expected.clipping.size() ||
        clipping->width == 0 || clipping->height == 0 ||
        static_cast<uint64_t>(clipping->width) * 4 != clipping->stride_bytes ||
        clipping->pixel_format != SONY2FUJI_PIXEL_RGBA8) {
        return false;
    }
    const auto* mask = static_cast<const uint8_t*>(clipping->data);
    return std::equal(expected.clipping.begin(), expected.clipping.end(), mask);
}

void fillSynthetic(Fixture& fixture) {
    for (uint32_t x = 0; x < fixture.buffer.width; ++x) {
        auto* pixel = fixture.pixel(x, 0);
        if (x < 256) {
            pixel[0] = static_cast<uint8_t>(x);
            pixel[1] = static_cast<uint8_t>(255 - x);
            pixel[2] = static_cast<uint8_t>(x ^ 0x5a);
        } else if (x == 256) {
            pixel[0] = 0;
            pixel[1] = 0;
            pixel[2] = 0;
        } else {
            pixel[0] = 42;
            pixel[1] = 43;
            pixel[2] = 44;
        }
        if (fixture.channels == 4) {
            pixel[3] = static_cast<uint8_t>(x * 17 + 3);
        }
    }
}

void testSynthetic(uint32_t channels, const std::string& label) {
    Fixture fixture(258, 1, channels, 7);
    fixture.bind();
    fillSynthetic(fixture);
    const size_t rowBytes = static_cast<size_t>(fixture.buffer.width) * channels;
    std::fill(fixture.bytes.begin() + rowBytes, fixture.bytes.end(), 255);
    const std::vector<uint8_t> before = fixture.bytes;

    sony2fuji::ImageStats actual;
    check(sony2fuji::computeImageStatsCPU(fixture.buffer, actual), label + " CPU computes");
    const auto expected = expectedStats(fixture.buffer);
    check(sameStats(actual, expected), label + " exact bins/counters/mask");
    check(actual.clipping.size() == static_cast<size_t>(fixture.buffer.width) * fixture.buffer.height * 4,
          label + " packed mask size");
    check(actual.histogram[0] == 2 && actual.histogram[255] == 1,
          label + " red all-bin counts");
    check(actual.histogram[256 + 0] == 2 && actual.histogram[256 + 255] == 1,
          label + " green all-bin counts");
    check(actual.histogram[512 + 0] == 2 && actual.histogram[512 + 255] == 1,
          label + " blue all-bin counts");
    bool allBinsPresent = true;
    for (size_t channel = 0; channel < 3; ++channel) {
        for (size_t bin = 0; bin < 256; ++bin) {
            allBinsPresent = allBinsPresent && actual.histogram[channel * 256 + bin] != 0;
        }
    }
    check(allBinsPresent, label + " all 256 bins populated");
    check(actual.shadows == 1 && actual.highlights == 3,
          label + " clipping counters");
    check(actual.clipping == expected.clipping, label + " clipping colors");
    check(std::all_of(actual.clipping.begin() + 257 * 4, actual.clipping.end(),
                      [](uint8_t value) { return value == 0; }),
          label + " ordinary pixels remain transparent");
    check(fixture.bytes == before, label + " leaves source colors unchanged");

    sony2fuji::ImageStats withoutMask;
    check(sony2fuji::computeImageStatsCPU(fixture.buffer, withoutMask, false) &&
          withoutMask.clipping.empty() && withoutMask.histogram == actual.histogram &&
          withoutMask.shadows == actual.shadows && withoutMask.highlights == actual.highlights,
          label + " optional mask preserves exact counts without allocating pixels");

    sony2fuji::ImageStats gpu;
    if (sony2fuji::computeImageStatsMetal(fixture.buffer, gpu)) {
        check(sameStats(gpu, actual), label + " Metal/CPU exact parity");
        check(fixture.bytes == before, label + " Metal leaves source colors unchanged");
    } else {
        std::cout << "SKIP " << label << " Metal parity (no usable Metal device)\n";
    }
}

void testOneByOne() {
    Fixture highlight(1, 1, 3, 0);
    highlight.bind();
    highlight.bytes = {255, 1, 2};
    highlight.bind();
    sony2fuji::ImageStats stats;
    check(sony2fuji::computeImageStatsCPU(highlight.buffer, stats), "1x1 highlight computes");
    check(stats.highlights == 1 && stats.shadows == 0 &&
          stats.clipping == std::vector<uint8_t>({255, 0, 0, 160}),
          "1x1 highlight mask");

    Fixture shadow(1, 1, 4, 0);
    shadow.bind();
    shadow.bytes = {0, 0, 0, 255};
    shadow.bind();
    check(sony2fuji::computeImageStatsCPU(shadow.buffer, stats), "1x1 RGBA shadow computes");
    check(stats.shadows == 1 && stats.highlights == 0 &&
          stats.clipping == std::vector<uint8_t>({0, 130, 255, 160}),
          "1x1 RGBA shadow mask");
}

void testInvalidBuffers() {
    Fixture fixture(4, 2, 3, 5);
    fixture.bind();
    sony2fuji::ImageStats sentinel;
    sentinel.histogram[17] = 91;
    sentinel.shadows = 7;
    sentinel.highlights = 8;
    sentinel.clipping = {1, 2, 3, 4};
    const auto original = sentinel;

    auto invalid = fixture.buffer;
    invalid.size_bytes = static_cast<size_t>(invalid.stride_bytes) + 4;
    check(!sony2fuji::computeImageStatsCPU(invalid, sentinel) && sameStats(sentinel, original),
          "short size_bytes rejected without output mutation");

    invalid = fixture.buffer;
    invalid.stride_bytes = 1;
    check(!sony2fuji::computeImageStatsCPU(invalid, sentinel) && sameStats(sentinel, original),
          "short stride rejected without output mutation");

    invalid = fixture.buffer;
    invalid.width = std::numeric_limits<uint32_t>::max();
    invalid.stride_bytes = std::numeric_limits<uint32_t>::max();
    invalid.size_bytes = std::numeric_limits<size_t>::max();
    check(!sony2fuji::computeImageStatsCPU(invalid, sentinel) && sameStats(sentinel, original),
          "overflowing dimensions rejected without output mutation");

    check(!sony2fuji::computeImageStatsMetal(invalid, sentinel) && sameStats(sentinel, original),
          "Metal invalid buffer leaves output unchanged");
}

void testPublicCAPI() {
    Fixture fixture(7, 3, 4, 9);
    fixture.bind();
    for (uint32_t y = 0; y < fixture.buffer.height; ++y) {
        for (uint32_t x = 0; x < fixture.buffer.width; ++x) {
            auto* pixel = fixture.pixel(x, y);
            pixel[0] = static_cast<uint8_t>(x * 31 + y * 17);
            pixel[1] = static_cast<uint8_t>(x * 13 + y * 47);
            pixel[2] = static_cast<uint8_t>(x * 7 + y * 59);
            pixel[3] = static_cast<uint8_t>(x * 19 + y * 23);
        }
        const size_t rowBytes = static_cast<size_t>(fixture.buffer.width) * fixture.channels;
        std::fill(fixture.bytes.begin() + static_cast<size_t>(y) * fixture.buffer.stride_bytes + rowBytes,
                  fixture.bytes.begin() + static_cast<size_t>(y + 1) * fixture.buffer.stride_bytes,
                  255);
    }
    const uint64_t before = checksumBytes(fixture.bytes);

    sony2fuji::ImageStats expected;
    check(sony2fuji::computeImageStatsCPU(fixture.buffer, expected),
          "public C API RGBA reference computes");
    sony2fuji::ImageStats metalReference;
    const bool metalAvailable = sony2fuji::computeImageStatsMetal(fixture.buffer, metalReference);

    const auto runMode = [&](sony2fuji_gpu_mode mode, const char* label, bool withMask) {
        uint32_t bins[768];
        std::fill(std::begin(bins), std::end(bins), 0xa5a5a5a5u);
        uint32_t shadows = 0xa5a5a5a5u;
        uint32_t highlights = 0x5a5a5a5au;
        sony2fuji_buffer mask{};
        sony2fuji_buffer* maskOutput = withMask ? &mask : nullptr;
        const auto status = sony2fuji_analyze_image(
            &fixture.buffer, mode, bins, &shadows, &highlights, maskOutput);
        check(status == SONY2FUJI_STATUS_OK, std::string(label) + " returns OK");
        if (status == SONY2FUJI_STATUS_OK) {
            check(samePublicStats(expected, bins, shadows, highlights,
                                  withMask ? &mask : nullptr),
                  std::string(label) + (withMask ?
                      " matches CPU bins/counters/mask" :
                      " matches CPU bins/counters"));
            if (withMask) {
                sony2fuji_release_buffer(&mask);
            }
        }
        check(checksumBytes(fixture.bytes) == before,
              std::string(label) + " leaves RGBA source unchanged");
    };

    runMode(SONY2FUJI_GPU_OFF, "public C API CPU mode", true);
    runMode(SONY2FUJI_GPU_AUTO, "public C API Auto mode", true);
    runMode(SONY2FUJI_GPU_AUTO, "public C API Auto mode without mask", false);

    uint32_t forceBins[768];
    std::fill(std::begin(forceBins), std::end(forceBins), 0x13579bdfu);
    uint32_t forceShadows = 0x2468ace0u;
    uint32_t forceHighlights = 0xdeadbeefu;
    sony2fuji_buffer forceMask{};
    const auto forceStatus = sony2fuji_analyze_image(
        &fixture.buffer, SONY2FUJI_GPU_FORCE, forceBins, &forceShadows,
        &forceHighlights, &forceMask);
    if (metalAvailable) {
        check(forceStatus == SONY2FUJI_STATUS_OK, "public C API Force uses Metal");
        if (forceStatus == SONY2FUJI_STATUS_OK) {
            check(samePublicStats(metalReference, forceBins, forceShadows,
                                  forceHighlights, &forceMask),
                  "public C API Force matches direct Metal");
            sony2fuji_release_buffer(&forceMask);
        }
    } else {
        check(forceStatus == SONY2FUJI_STATUS_PROCESSING_ERROR,
              "public C API Force rejects unavailable Metal");
        check(forceMask.data == nullptr && forceMask.size_bytes == 0 &&
              forceShadows == 0x2468ace0u && forceHighlights == 0xdeadbeefu &&
              forceBins[0] == 0x13579bdfu && forceBins[767] == 0x13579bdfu,
              "public C API Force leaves outputs unchanged on failure");
    }
    check(checksumBytes(fixture.bytes) == before,
          "public C API Force leaves RGBA source unchanged");
}

void testPublicCAPIInvalidBounds() {
    Fixture fixture(4, 2, 4, 5);
    fixture.bind();
    uint32_t bins[768];
    std::fill(std::begin(bins), std::end(bins), 0xaaaaaaaa);
    uint32_t shadows = 11;
    uint32_t highlights = 22;
    const auto originalBins = bins[0];
    const auto originalShadows = shadows;
    const auto originalHighlights = highlights;

    auto invalid = fixture.buffer;
    invalid.size_bytes = invalid.stride_bytes + 1;
    sony2fuji_buffer mask{};
    const auto status = sony2fuji_analyze_image(
        &invalid, SONY2FUJI_GPU_AUTO, bins, &shadows, &highlights, &mask);
    check(status == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "public C API rejects short size_bytes");
    check(bins[0] == originalBins && bins[767] == originalBins &&
          shadows == originalShadows && highlights == originalHighlights &&
          mask.data == nullptr && mask.size_bytes == 0,
          "public C API invalid bounds leave outputs unchanged");

    invalid = fixture.buffer;
    invalid.stride_bytes = 1;
    const auto strideStatus = sony2fuji_analyze_image(
        &invalid, SONY2FUJI_GPU_OFF, bins, &shadows, &highlights, nullptr);
    check(strideStatus == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "public C API rejects short stride");
}

void benchmarkStats(uint32_t width, uint32_t height, uint32_t channels,
                    const std::string& label) {
    Fixture fixture(width, height, channels, 13);
    fixture.bind();
    for (uint32_t y = 0; y < height; ++y) {
        for (uint32_t x = 0; x < width; ++x) {
            auto* pixel = fixture.pixel(x, y);
            pixel[0] = static_cast<uint8_t>(x + y);
            pixel[1] = static_cast<uint8_t>(x * 3 + y * 5);
            pixel[2] = static_cast<uint8_t>(x * 7 + y * 11);
            if (channels == 4) {
                pixel[3] = 255;
            }
        }
        const size_t rowBytes = static_cast<size_t>(width) * channels;
        std::fill(fixture.bytes.begin() + static_cast<size_t>(y) * fixture.buffer.stride_bytes + rowBytes,
                  fixture.bytes.begin() + static_cast<size_t>(y + 1) * fixture.buffer.stride_bytes,
                  255);
    }
    const uint64_t before = checksumBytes(fixture.bytes);

    constexpr size_t warmupRuns = 5;
    constexpr size_t measuredRuns = 10;
    sony2fuji::ImageStats cpu;
    bool cpuOk = true;
    for (size_t run = 0; run < warmupRuns; ++run) {
        cpuOk = sony2fuji::computeImageStatsCPU(fixture.buffer, cpu);
        if (!cpuOk) {
            break;
        }
    }
    check(cpuOk, label + " CPU warmup computes");
    if (!cpuOk) {
        return;
    }
    std::vector<double> cpuTimes;
    for (size_t run = 0; run < measuredRuns; ++run) {
        const auto start = std::chrono::steady_clock::now();
        cpuOk = sony2fuji::computeImageStatsCPU(fixture.buffer, cpu);
        const auto end = std::chrono::steady_clock::now();
        if (!cpuOk) {
            break;
        }
        cpuTimes.push_back(std::chrono::duration<double, std::milli>(end - start).count());
    }
    check(cpuOk && cpuTimes.size() == measuredRuns, label + " CPU measured computes");
    if (!cpuOk || cpuTimes.size() != measuredRuns) {
        return;
    }
    const double cpuAverage = std::accumulate(cpuTimes.begin(), cpuTimes.end(), 0.0) /
        static_cast<double>(cpuTimes.size());
    std::cout << "BENCH image_stats " << label << " CPU warmup=5 measured=10 avg="
              << cpuAverage << " ms min="
              << *std::min_element(cpuTimes.begin(), cpuTimes.end()) << " ms\n";
    check(checksumBytes(fixture.bytes) == before, label + " CPU leaves source colors unchanged");

    sony2fuji::ImageStats gpu;
    bool gpuOk = true;
    for (size_t run = 0; run < warmupRuns; ++run) {
        gpuOk = sony2fuji::computeImageStatsMetal(fixture.buffer, gpu);
        if (!gpuOk) {
            break;
        }
    }
    if (gpuOk) {
        std::vector<double> gpuTimes;
        for (size_t run = 0; run < measuredRuns; ++run) {
            const auto start = std::chrono::steady_clock::now();
            gpuOk = sony2fuji::computeImageStatsMetal(fixture.buffer, gpu);
            const auto end = std::chrono::steady_clock::now();
            if (!gpuOk) {
                break;
            }
            gpuTimes.push_back(std::chrono::duration<double, std::milli>(end - start).count());
        }
        check(gpuOk && gpuTimes.size() == measuredRuns, label + " Metal measured computes");
        if (!gpuOk || gpuTimes.size() != measuredRuns) {
            return;
        }
        const double gpuAverage = std::accumulate(gpuTimes.begin(), gpuTimes.end(), 0.0) /
            static_cast<double>(gpuTimes.size());
        std::cout << "BENCH image_stats " << label << " Metal warmup=5 measured=10 avg="
                  << gpuAverage << " ms min="
                  << *std::min_element(gpuTimes.begin(), gpuTimes.end()) << " ms\n";
        check(sameStats(gpu, cpu), label + " Metal/CPU exact parity");
        check(checksumBytes(fixture.bytes) == before,
              label + " Metal leaves source colors unchanged");
    } else {
        std::cout << "SKIP " << label << " Metal benchmark (no usable Metal device)\n";
    }
}

void testLargeBenchmark() {
    benchmarkStats(1920, 1080, 4, "2MP RGBA8");
    benchmarkStats(8256, 4000, 3, "33MP RGB8");
}

} // namespace

int main() {
    testSynthetic(3, "RGB8 padded");
    testSynthetic(4, "RGBA8 padded");
    testOneByOne();
    testInvalidBuffers();
    testPublicCAPI();
    testPublicCAPIInvalidBounds();
    testLargeBenchmark();
    return failures == 0 ? 0 : 1;
}
