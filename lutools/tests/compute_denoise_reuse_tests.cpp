#define SONY2FUJI_GLES_VM_IMPLEMENT
#include "gles_spirv_vm.h"

#include "gpu/compute_denoise.h"
#include "gpu/filter_buffer_pool.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <limits>
#include <memory>
#include <new>
#include <vector>

namespace {

thread_local struct {
    bool active = false;
    size_t minBytes = 0;
    size_t count = 0;
    size_t maxBytes = 0;
} gAllocProbe;

struct ScopedAllocProbe {
    explicit ScopedAllocProbe(size_t threshold) {
        gAllocProbe = {true, threshold, 0, 0};
    }
    ~ScopedAllocProbe() { gAllocProbe.active = false; }
    size_t count() const { return gAllocProbe.count; }
    size_t maxBytes() const { return gAllocProbe.maxBytes; }
};

} // namespace

void* operator new(std::size_t size) {
    if (gAllocProbe.active && size >= gAllocProbe.minBytes) {
        ++gAllocProbe.count;
        gAllocProbe.maxBytes = std::max(gAllocProbe.maxBytes, size);
    }
    void* ptr = std::malloc(size ? size : 1);
    if (!ptr) throw std::bad_alloc();
    return ptr;
}

void* operator new[](std::size_t size) { return ::operator new(size); }
void operator delete(void* ptr) noexcept { std::free(ptr); }
void operator delete(void* ptr, std::size_t) noexcept { std::free(ptr); }
void operator delete[](void* ptr) noexcept { std::free(ptr); }
void operator delete[](void* ptr, std::size_t) noexcept { std::free(ptr); }

namespace {

int gFailures = 0;

void check(bool ok, const std::string& label) {
    std::cout << (ok ? "PASS " : "FAIL ") << label << '\n';
    if (!ok) ++gFailures;
}

struct MockBuffer : sony2fuji::FilterBuffer {
    std::vector<float> data;
};

sony2fuji::FilterBufferPtr createMockBuffer(size_t n, const float* input) {
    auto b = std::make_unique<MockBuffer>();
    b->data.resize(n, 0.f);
    if (input) std::memcpy(b->data.data(), input, n * sizeof(float));
    return b;
}

void writeMockBuffer(sony2fuji::FilterBuffer& buf, size_t n, const float* input) {
    auto& mock = static_cast<MockBuffer&>(buf);
    if (input) std::memcpy(mock.data.data(), input, n * sizeof(float));
}

struct MockContext : sony2fuji::FilterContext {};

class MockFilterDevice : public sony2fuji::FilterDevice {
public:
    size_t allocateCalls = 0;
    size_t writeCalls = 0;
    size_t dispatchCalls = 0;
    size_t readCalls = 0;
    bool injectNaNOnSecondDirection = false;

    std::unique_ptr<sony2fuji::FilterContext> activate() {
        return std::make_unique<MockContext>();
    }

    sony2fuji::FilterBufferPtr allocate(size_t count, const float* input = nullptr) {
        const bool wasProbing = gAllocProbe.active;
        gAllocProbe.active = false;
        ++allocateCalls;
        auto buf = std::make_unique<MockBuffer>();
        buf->data.assign(count, 0.f);
        if (input && count > 0) std::memcpy(buf->data.data(), input, count * sizeof(float));
        gAllocProbe.active = wasProbing;
        return buf;
    }

    void write(sony2fuji::FilterBuffer& buffer, size_t count, const float* input) {
        ++writeCalls;
        auto& dst = static_cast<MockBuffer&>(buffer);
        assert(count <= dst.data.size());
        if (input && count > 0) std::memcpy(dst.data.data(), input, count * sizeof(float));
    }

    void dispatch(sony2fuji::FilterParams params, sony2fuji::FilterBuffer& source, sony2fuji::FilterBuffer*,
                  sony2fuji::FilterBuffer& output, sony2fuji::FilterBuffer*) {
        ++dispatchCalls;
        auto& src = static_cast<MockBuffer&>(source);
        auto& dst = static_cast<MockBuffer&>(output);
        const size_t srcOffset = size_t(params.outputRow - params.sourceRow) * params.width * 3;
        const size_t n = size_t(params.count) * 3;
        assert(srcOffset + n <= src.data.size());
        assert(n <= dst.data.size());
        const float bias = params.stage == static_cast<uint32_t>(sony2fuji::FilterStage::Detail)
            ? (params.direction == 0 ? 0.01f : 0.02f)
            : 0.005f;
        for (size_t i = 0; i < n; ++i) {
            dst.data[i] = src.data[srcOffset + i] + bias;
        }
        if (injectNaNOnSecondDirection && params.direction == 1 && n > 0) {
            dst.data[0] = std::numeric_limits<float>::quiet_NaN();
        }
    }

    void read(sony2fuji::FilterBuffer& buffer, size_t count, float* output) {
        ++readCalls;
        const auto& src = static_cast<MockBuffer&>(buffer);
        assert(count <= src.data.size());
        if (count > 0) std::memcpy(output, src.data.data(), count * sizeof(float));
    }
};

void testImageFilterBandAndScratchReuse() {
    // width=4096 -> maxRows = 8 MiB / (4096*12) = 170, band rows = 168 -> 510 rows yields 4 bands.
    sony2fuji::ImageData image(4096, 510);
    for (size_t i = 0; i < image.pixels.size(); ++i) {
        image.pixels[i] = {0.2f, 0.35f, 0.5f};
    }

    sony2fuji::PhotoEffectsOptions fx;
    fx.vignetteAmount = -25.f;

    MockFilterDevice dev;
    size_t largeAllocs = 0;
    bool ok = false;
    {
        // Each ImageData(4096,510) is 25.07 MB; each of the first 3 band readbacks is ~8.26 MB (>4 MB).
        ScopedAllocProbe probe(4 * 1024 * 1024);
        ok = sony2fuji::computePhotoEffects(dev, image, fx);
        largeAllocs = probe.count();
    }
    check(ok, "computePhotoEffects multi-band succeeds");
    check(dev.allocateCalls == 2,
          "imageFilter allocates input/output SSBO once outside band loop (got " +
          std::to_string(dev.allocateCalls) + ")");
    check(dev.writeCalls == 4,
          "imageFilter reuploads each band into reused buffer via write() (got " +
          std::to_string(dev.writeCalls) + ")");
    check(dev.dispatchCalls == 4 && dev.readCalls == 4, "imageFilter dispatches and reads all 4 bands");
    check(largeAllocs <= 2,
          "imageFilter + finiteOutput reuse host scratch across multi-band readback (got " +
          std::to_string(largeAllocs) + " allocs >= 4 MiB)");
    check(std::fabs(image.pixels.front().r - 0.205f) < 1e-6f &&
          std::fabs(image.pixels.back().b - 0.505f) < 1e-6f,
          "imageFilter preserves pixel exactness across reused bands");
}

void testDetailFilterCopiesAndAtomicity() {
    // 4096 x 200: image = 9,830,400 B (~9.38 MiB); max band = 168*4096*12 = 8,257,536 B (< 9 MB).
    constexpr size_t kFullImageThreshold = 9000000;
    sony2fuji::ImageData base(4096, 200);
    for (size_t i = 0; i < base.pixels.size(); ++i) {
        base.pixels[i] = {0.3f, 0.4f, 0.6f};
    }

    {
        sony2fuji::ImageData zero = base;
        MockFilterDevice dev;
        size_t fullCopies = 0;
        bool ok = false;
        {
            ScopedAllocProbe probe(kFullImageThreshold);
            ok = sony2fuji::computeDetailFilter(dev, zero, 0.f, 0.f);
            fullCopies = probe.count();
        }
        check(ok && dev.allocateCalls == 0, "computeDetailFilter 0/0 performs no GPU work");
        check(fullCopies == 0,
              "computeDetailFilter 0/0 performs zero full-image allocations (got " +
              std::to_string(fullCopies) + ")");
    }

    {
        sony2fuji::ImageData onePass = base;
        MockFilterDevice dev;
        size_t fullCopies = 0;
        bool ok = false;
        {
            ScopedAllocProbe probe(kFullImageThreshold);
            ok = sony2fuji::computeDetailFilter(dev, onePass, 0.5f, 0.f);
            fullCopies = probe.count();
        }
        check(ok && dev.allocateCalls == 2 && dev.writeCalls == 2,
              "computeDetailFilter 1-pass reuses band SSBOs across halo bands");
        check(fullCopies == 1,
              "computeDetailFilter 1-pass allocates only 1 full result buffer instead of 2 (got " +
              std::to_string(fullCopies) + ")");
        check(std::fabs(onePass.pixels.front().r - 0.31f) < 1e-6f,
              "computeDetailFilter 1-pass output is accurate");
    }

    {
        sony2fuji::ImageData twoPassFail = base;
        MockFilterDevice dev;
        dev.injectNaNOnSecondDirection = true;
        const bool ok = sony2fuji::computeDetailFilter(dev, twoPassFail, 0.5f, 0.6f);
        check(!ok, "computeDetailFilter 2-pass rejects non-finite pass 2 output");
        check(twoPassFail.pixels[0].r == base.pixels[0].r &&
              twoPassFail.pixels.back().b == base.pixels.back().b,
              "computeDetailFilter 2-pass failure preserves caller image atomically");
    }
}

void testGlesDenoiseBufferPooling() {
#ifndef RAWLAB_GLSLANG_PATH
    std::cout << "SKIP gles_denoise pooling (glslangValidator unavailable)\n";
#else
    rawlabtest::resetGlesVmState();
    auto device = sony2fuji::createGlesFilterDevice();
    check(device != nullptr, "createGlesFilterDevice returns non-null");
    if (!device) return;

    auto makePattern = [](int w, int h) {
        std::vector<float> guide(size_t(w) * h * 3);
        std::vector<float> src(size_t(w) * h * 2);
        for (int y = 0; y < h; ++y) {
            for (int x = 0; x < w; ++x) {
                const size_t i = size_t(y) * w + x;
                guide[i * 3 + 0] = 50.f + 0.1f * float(x % 16);
                guide[i * 3 + 1] = 0.05f * std::sin(float(x) * 0.2f);
                guide[i * 3 + 2] = -0.05f * std::cos(float(y) * 0.2f);
                src[i * 2 + 0] = 2.f * std::sin(float(x + y) * 0.3f);
                src[i * 2 + 1] = -2.f * std::cos(float(x - y) * 0.3f);
            }
        }
        return std::make_pair(guide, src);
    };

    auto [guide64, src64] = makePattern(64, 64);
    std::vector<float> out1(64 * 64 * 2, 0.f);
    std::vector<float> out2(64 * 64 * 2, 0.f);
    std::vector<float> outEdge(64 * 48 * 2, 0.f);
    {
        auto scope = device->activate();
        check(sony2fuji::computeGuidedFilter(*device, guide64.data(), src64.data(), 64, 64, 2, 0.01f, out1.data()),
              "computeGuidedFilter warmup 64x64 succeeds on GLES SPIR-V VM");
    }

    // Also warm up a 32x32 depth-4 wavelet tile (24 buffers per tile).
    sony2fuji::WaveletFilterSettings wav;
    wav.depth = 4;
    for (int s = 0; s < 4; ++s) wav.thresholdScale[s] = 1.f;
    for (int i = 0; i < 12; ++i) wav.sigma[i] = 0.02f;
    std::vector<float> wavIn(32 * 32, 0.3f);
    for (size_t i = 0; i < wavIn.size(); ++i) wavIn[i] += 0.02f * std::sin(float(i));
    std::vector<float> wavOut1(32 * 32, 0.f);
    std::vector<float> wavOut2(32 * 32, 0.f);
    {
        auto scope = device->activate();
        check(sony2fuji::computeWaveletFilter(*device, wavIn.data(), 32, 32, wav, wavOut1.data()),
              "computeWaveletFilter warmup 32x32 succeeds on GLES SPIR-V VM");
    }

    // Reset GL counters after warmup; repeat identical & smaller edge-band calls must reuse pooled SSBOs.
    rawlabtest::glesVmStats().resetCounters();
    auto [guideEdge, srcEdge] = makePattern(64, 48);
    {
        auto scope = device->activate();
        check(sony2fuji::computeGuidedFilter(*device, guide64.data(), src64.data(), 64, 64, 2, 0.01f, out2.data()),
              "computeGuidedFilter repeat 64x64 succeeds");
        check(sony2fuji::computeGuidedFilter(*device, guideEdge.data(), srcEdge.data(), 64, 48, 2, 0.01f, outEdge.data()),
              "computeGuidedFilter trailing band 64x48 succeeds");
        check(sony2fuji::computeWaveletFilter(*device, wavIn.data(), 32, 32, wav, wavOut2.data()),
              "computeWaveletFilter repeat tile 32x32 succeeds");
    }

    const auto stats = rawlabtest::glesVmStats();
    check(stats.genBufferCalls == 0,
          "gles_denoise reuses pooled SSBOs without glGenBuffers (got " +
          std::to_string(stats.genBufferCalls) + ")");
    check(stats.bufferDataCalls == 0,
          "gles_denoise reuses pooled SSBOs without glBufferData reallocation (got " +
          std::to_string(stats.bufferDataCalls) + ")");
    check(stats.deleteBufferCalls == 0,
          "gles_denoise retains pooled SSBOs without glDeleteBuffers churn (got " +
          std::to_string(stats.deleteBufferCalls) + ")");
    check(stats.ssboBufferSubDataCalls == 5,
          "gles_denoise uploads new data into pooled SSBOs via GL_SHADER_STORAGE_BUFFER glBufferSubData (got " +
          std::to_string(stats.ssboBufferSubDataCalls) + ")");
    check(out1 == out2 && wavOut1 == wavOut2,
          "pooled SSBO execution is bit-identical to unpooled warmup results");

    auto refDevice = sony2fuji::createGlesFilterDevice();
    std::vector<float> outEdgeRef(64 * 48 * 2, 0.f);
    {
        auto scope = refDevice->activate();
        check(sony2fuji::computeGuidedFilter(*refDevice, guideEdge.data(), srcEdge.data(), 64, 48, 2, 0.01f, outEdgeRef.data()),
              "unpooled fresh device computes 64x48 guided filter reference");
    }
    bool edgeFinite = std::all_of(outEdge.begin(), outEdge.end(), [](float v) { return std::isfinite(v); });
    check(edgeFinite && outEdge == outEdgeRef,
          "trailing 64x48 band produces exact unpooled output when reusing 64x64 buffers");
#endif
}

void testFilterBufferPoolBudgetAndGlesContextTrim() {
    constexpr size_t kNineMiBFloats = 9 * 1024 * 1024 / sizeof(float); // 2,359,296 floats = 9 MiB
    constexpr size_t kBudgetFloats = 16 * 1024 * 1024;                  // 64 MiB
    {
        sony2fuji::FilterBufferPool pool(kBudgetFloats);
        size_t created = 0;
        std::vector<sony2fuji::FilterBufferPtr> peak;
        peak.reserve(24);
        for (int i = 0; i < 24; ++i) {
            peak.push_back(pool.acquire(kNineMiBFloats, nullptr,
                [&](size_t n, const float*) {
                    ++created;
                    auto b = std::make_unique<MockBuffer>();
                    b->data.resize(n, 0.f);
                    return b;
                },
                [](sony2fuji::FilterBuffer&, size_t, const float*) {}));
        }
        check(created == 24 && pool.idleFloats() == 0,
              "FilterBufferPool holds 24x9 MiB active buffers during wavelet peak without premature eviction");
        peak.clear();
        check(pool.idleFloats() == 24 * kNineMiBFloats,
              "dropping peak leases turns 216 MiB into idle pool entries before trim");
        {
            // Pool-hit branch for a subsequent small 512x512 request must trim excess idle buffers too.
            auto small = pool.acquire(512 * 512, nullptr,
                [&](size_t n, const float*) {
                    ++created;
                    auto b = std::make_unique<MockBuffer>();
                    b->data.resize(n, 0.f);
                    return b;
                },
                [](sony2fuji::FilterBuffer&, size_t, const float*) {});
            check(created == 24 && pool.idleFloats() <= kBudgetFloats,
                  "FilterBufferPool acquire() hit trims idle pool entries to <= 64 MiB");
        }
        pool.trimIdleToBudget();
        check(pool.idleFloats() <= kBudgetFloats && pool.entryCount() <= 7,
              "FilterBufferPool trimIdleToBudget() caps idle memory at <= 64 MiB after peak");
    }

    {
        // Regression Case (a): mixed-size hit where bestIndex > 0 has > 64 MiB idle buffers ahead of it
        // and an active inUse buffer right behind it; vector erase during trim must not alias inUse.
        constexpr size_t kOneMiBFloats = 1024 * 1024 / sizeof(float);
        sony2fuji::FilterBufferPool pool(kBudgetFloats);

        std::vector<sony2fuji::FilterBufferPtr> prefixLarge;
        prefixLarge.reserve(8);
        for (int i = 0; i < 8; ++i) {
            prefixLarge.push_back(pool.acquire(kNineMiBFloats, nullptr, createMockBuffer, writeMockBuffer)); // 8 * 9 MiB = 72 MiB > 64 MiB
        }
        std::vector<float> midInit(kOneMiBFloats, 1.25f);
        auto midSmall = pool.acquire(kOneMiBFloats, midInit.data(), createMockBuffer, writeMockBuffer);
        const sony2fuji::FilterBuffer* midRaw = &midSmall->underlying();

        std::vector<float> tailInit(kNineMiBFloats, 7.5f);
        auto inFlight = pool.acquire(kNineMiBFloats, tailInit.data(), createMockBuffer, writeMockBuffer);
        const sony2fuji::FilterBuffer* inFlightRaw = &inFlight->underlying();

        prefixLarge.clear();
        midSmall.reset();

        std::vector<float> reusedWrite(kOneMiBFloats, 3.75f);
        auto reused = pool.acquire(kOneMiBFloats, reusedWrite.data(), createMockBuffer, writeMockBuffer);
        const bool distinctFromInFlight = (&reused->underlying() == midRaw) &&
                                          (&reused->underlying() != inFlightRaw);
        auto& reusedMock = static_cast<MockBuffer&>(reused->underlying());
        auto& inFlightMock = static_cast<MockBuffer&>(inFlight->underlying());
        const bool readsMatch = reusedMock.data.size() == kOneMiBFloats &&
                                reusedMock.data[0] == 3.75f &&
                                inFlightMock.data.size() == kNineMiBFloats &&
                                inFlightMock.data[0] == 7.5f;
        // Write through reused Lease after acquire() and ensure dropping reused leaves inFlight intact.
        reusedMock.data[123] = 9.25f;
        reused.reset();
        pool.trimIdleToBudget();
        const bool writeIsolated = inFlightMock.data[123] == 7.5f && reusedMock.data[123] == 9.25f;
        check(distinctFromInFlight && readsMatch && writeIsolated,
              "FilterBufferPool mixed-size hit (bestIndex > 0 before inUse tail) avoids aliasing in-flight buffer");
    }

    {
        // Regression Case (b): mixed-size hit where bestIndex is at the tail after > 64 MiB idle buffers;
        // vector erase during trim shifts the tail slot left and must not leave Lease pointing past end.
        constexpr size_t kOneMiBFloats = 1024 * 1024 / sizeof(float);
        sony2fuji::FilterBufferPool pool(kBudgetFloats);

        std::vector<sony2fuji::FilterBufferPtr> prefixLarge;
        prefixLarge.reserve(8);
        for (int i = 0; i < 8; ++i) {
            prefixLarge.push_back(pool.acquire(kNineMiBFloats, nullptr, createMockBuffer, writeMockBuffer)); // 72 MiB > 64 MiB
        }
        auto tailSmall = pool.acquire(kOneMiBFloats, nullptr, createMockBuffer, writeMockBuffer);
        const sony2fuji::FilterBuffer* tailRaw = &tailSmall->underlying();
        prefixLarge.clear();
        tailSmall.reset();

        std::vector<float> tailData(kOneMiBFloats, 4.5f);
        auto hit = pool.acquire(kOneMiBFloats, tailData.data(), createMockBuffer, writeMockBuffer);
        auto& hitMock = static_cast<MockBuffer&>(hit->underlying());
        const bool hitValid = (&hit->underlying() == tailRaw) && hitMock.data.size() == kOneMiBFloats &&
                              hitMock.data[0] == 4.5f && hitMock.data[kOneMiBFloats - 1] == 4.5f;
        const size_t idleWhileHeld = pool.idleFloats();
        hit.reset();
        const bool leaseReleased = pool.idleFloats() == idleWhileHeld + kOneMiBFloats;
        check(hitValid && leaseReleased,
              "FilterBufferPool mixed-size hit at tail slot preserves valid Lease across trim");
    }

#ifdef RAWLAB_GLSLANG_PATH
    rawlabtest::resetGlesVmState();
    auto device = sony2fuji::createGlesFilterDevice();
    check(device != nullptr, "createGlesFilterDevice succeeds for budget trim probe");
    if (!device) return;
    {
        auto scope = device->activate();
        std::vector<sony2fuji::FilterBufferPtr> peak;
        peak.reserve(24);
        for (int i = 0; i < 24; ++i) {
            peak.push_back(device->allocate(kNineMiBFloats));
        }
        check(rawlabtest::glesVmLiveBufferBytes() >= 216ULL * 1024 * 1024,
              "GLES VM tracks 24x9 MiB = 216 MiB peak SSBO allocations");
        peak.clear();
        {
            auto small = device->allocate(512 * 512);
            check(rawlabtest::glesVmLiveBufferBytes() <= 72ULL * 1024 * 1024 + 4096,
                  "GLES pool-hit acquire(512x512) trims excess idle SSBOs while context is bound");
        }
        device->trimPool();
        check(rawlabtest::glesVmLiveBufferBytes() <= 64ULL * 1024 * 1024 + 4096,
              "GLES device->trimPool() caps idle SSBO memory at <= 64 MiB (got " +
              std::to_string(rawlabtest::glesVmLiveBufferBytes()) + " bytes)");
    }
    {
        auto scope = device->activate();
        std::vector<sony2fuji::FilterBufferPtr> peak;
        peak.reserve(24);
        for (int i = 0; i < 24; ++i) {
            peak.push_back(device->allocate(kNineMiBFloats));
        }
        peak.clear();
    }
    check(rawlabtest::glesVmLiveBufferBytes() <= 64ULL * 1024 * 1024 + 4096,
          "GLES FilterContext Binding destructor trims idle SSBOs to <= 64 MiB on exit");
    check(rawlabtest::glesVmStats().deleteBuffersWithoutContextCalls == 0,
          "GLES pool glDeleteBuffers only runs while EGL context is active");
    {
        // Mixed-size tail hit on real GLES FilterDevice within single activate() scope.
        constexpr size_t kOneMiBFloats = 1024 * 1024 / sizeof(float);
        auto mixedDevice = sony2fuji::createGlesFilterDevice();
        check(mixedDevice != nullptr, "createGlesFilterDevice succeeds for mixed-size tail probe");
        if (mixedDevice) {
            auto scope = mixedDevice->activate();
            std::vector<sony2fuji::FilterBufferPtr> prefixLarge;
            prefixLarge.reserve(8);
            for (int i = 0; i < 8; ++i) {
                prefixLarge.push_back(mixedDevice->allocate(kNineMiBFloats));
            }
            auto tailSmall = mixedDevice->allocate(kOneMiBFloats);
            prefixLarge.clear();
            tailSmall.reset();
            std::vector<float> pattern(kOneMiBFloats, 6.25f);
            std::vector<float> readback(kOneMiBFloats, 0.f);
            auto hit = mixedDevice->allocate(kOneMiBFloats);
            mixedDevice->write(*hit, kOneMiBFloats, pattern.data());
            mixedDevice->read(*hit, kOneMiBFloats, readback.data());
            check(readback == pattern,
                  "GLES mixed-size tail allocate/write/read succeeds after prefix trim");
        }
    }
#endif
}

} // namespace

int main() {
    testImageFilterBandAndScratchReuse();
    testDetailFilterCopiesAndAtomicity();
    testGlesDenoiseBufferPooling();
    testFilterBufferPoolBudgetAndGlesContextTrim();
    if (gFailures != 0) {
        std::cerr << gFailures << " check(s) failed\n";
        return 1;
    }
    return 0;
}
