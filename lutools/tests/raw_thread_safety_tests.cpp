#include "sony2fuji/raw_processor.h"
#include "sony2fuji/ffi/sony2fuji_c.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

using namespace sony2fuji;

namespace {

void require(bool ok, const std::string& message) {
    if (!ok) throw std::runtime_error(message);
}

class Barrier {
public:
    explicit Barrier(size_t count) : threshold_(count), remaining_(count) {}

    void arriveAndWait() {
        std::unique_lock<std::mutex> lock(mutex_);
        const size_t generation = generation_;
        if (--remaining_ == 0) {
            ++generation_;
            remaining_ = threshold_;
            cv_.notify_all();
            return;
        }
        cv_.wait(lock, [&] { return generation_ != generation; });
    }

private:
    std::mutex mutex_;
    std::condition_variable cv_;
    size_t threshold_;
    size_t remaining_;
    size_t generation_ = 0;
};

struct TempDir {
    std::filesystem::path path;
    explicit TempDir(const std::string& prefix) {
        const auto stamp = std::chrono::steady_clock::now().time_since_epoch().count();
        path = std::filesystem::temp_directory_path() / (prefix + "-" + std::to_string(stamp));
        std::filesystem::create_directories(path);
    }
    ~TempDir() {
        std::error_code ec;
        std::filesystem::remove_all(path, ec);
    }
};

// Writes an uncompressed 12-bit packed Bayer DNG so LibRaw unpacks via
// packed_dng_load_raw() -> getbits(12) -> getbithuff() and Legacy demosaic
// exercises ahd_interpolate() -> cielab(). Both paths use function-local
// statics when LibRaw is compiled with LIBRAW_NOTHREADS.
void writePacked12BitBayerDng(const std::filesystem::path& filepath,
                              const std::string& model,
                              const int32_t colorMatrixNum[9],
                              const uint32_t asShotNeutralNum[3],
                              int patternVariant) {
    constexpr uint32_t width = 256;
    constexpr uint32_t height = 192;
    constexpr uint32_t rowBytes = (width * 12) / 8;
    constexpr uint32_t headerBytes = 2048;
    constexpr uint32_t stripBytes = rowBytes * height;

    std::vector<uint8_t> bytes(headerBytes + stripBytes, 0);
    auto word = [&](size_t offset, uint16_t value) {
        bytes.at(offset) = static_cast<uint8_t>(value & 0xffu);
        bytes.at(offset + 1) = static_cast<uint8_t>((value >> 8) & 0xffu);
    };
    auto dword = [&](size_t offset, uint32_t value) {
        word(offset, static_cast<uint16_t>(value & 0xffffu));
        word(offset + 2, static_cast<uint16_t>((value >> 16) & 0xffffu));
    };

    bytes[0] = 'I';
    bytes[1] = 'I';
    word(2, 42);
    dword(4, 8);

    size_t entry = 10;
    uint16_t tagCount = 0;
    auto tag = [&](uint16_t id, uint16_t type, uint32_t count, uint32_t value) {
        word(entry, id);
        word(entry + 2, type);
        dword(entry + 4, count);
        dword(entry + 8, value);
        entry += 12;
        ++tagCount;
    };

    const uint32_t modelLen = static_cast<uint32_t>(model.size() + 1);
    tag(254, 4, 1, 0);
    tag(256, 4, 1, width);
    tag(257, 4, 1, height);
    tag(258, 3, 1, 12);
    tag(259, 3, 1, 1);
    tag(262, 3, 1, 32803);
    tag(271, 2, 7, 512);
    tag(272, 2, modelLen, 528);
    tag(273, 4, 1, headerBytes);
    tag(277, 3, 1, 1);
    tag(278, 4, 1, height);
    tag(279, 4, 1, stripBytes);
    tag(284, 3, 1, 1);
    tag(33421, 3, 2, 0x00020002u);
    tag(33422, 1, 4, 0x02010100u); // RGGB
    tag(50706, 1, 4, 0x00000401u); // DNG 1.4.0.0
    tag(50707, 1, 4, 0x00000101u); // DNG backward 1.1.0.0
    tag(50708, 2, modelLen, 528);
    tag(50714, 3, 1, 64);
    tag(50717, 3, 1, 4095);
    tag(50721, 10, 9, 600);
    tag(50728, 5, 3, 680);
    tag(50778, 3, 1, 21);
    word(8, tagCount);

    std::memcpy(bytes.data() + 512, "RawLab", 7);
    std::memcpy(bytes.data() + 528, model.c_str(), modelLen);
    for (size_t i = 0; i < 9; ++i) {
        dword(600 + i * 8, static_cast<uint32_t>(colorMatrixNum[i]));
        dword(604 + i * 8, 10000u);
    }
    for (size_t c = 0; c < 3; ++c) {
        dword(680 + c * 8, asShotNeutralNum[c]);
        dword(684 + c * 8, 1000u);
    }

    auto sampleAt = [&](uint32_t x, uint32_t y) -> uint16_t {
        const bool redRow = (y & 1u) == 0u;
        const bool evenCol = (x & 1u) == 0u;
        uint32_t v = 128;
        if (patternVariant == 0) {
            const uint32_t gx = (x * 13u + y * 3u) % 3200u;
            const uint32_t gy = (y * 17u + ((x ^ y) & 31u) * 29u) % 3000u;
            if (redRow && evenCol) v = 220u + gx;
            else if (!redRow && !evenCol) v = 300u + gy;
            else v = 260u + (gx + gy) / 2u;
        } else {
            const int dx = static_cast<int>(x) - 128;
            const int dy = static_cast<int>(y) - 96;
            const uint32_t ring = static_cast<uint32_t>((dx * dx + dy * dy) % 3100);
            const uint32_t stripe = ((x * 7u + y * 23u) % 2800u);
            if (redRow && evenCol) v = 3400u - stripe;
            else if (!redRow && !evenCol) v = 240u + ring;
            else v = 400u + (ring + stripe) / 2u;
        }
        return static_cast<uint16_t>(v > 3950u ? 3950u : v);
    };

    for (uint32_t y = 0; y < height; ++y) {
        uint8_t* dst = bytes.data() + headerBytes + y * rowBytes;
        for (uint32_t x = 0; x < width; x += 2) {
            const uint16_t s0 = sampleAt(x, y);
            const uint16_t s1 = sampleAt(x + 1, y);
            dst[0] = static_cast<uint8_t>((s0 >> 4) & 0xffu);
            dst[1] = static_cast<uint8_t>(((s0 & 0x0fu) << 4) | ((s1 >> 8) & 0x0fu));
            dst[2] = static_cast<uint8_t>(s1 & 0xffu);
            dst += 3;
        }
    }

    std::ofstream out(filepath, std::ios::binary | std::ios::trunc);
    out.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
    require(out.good(), "Write synthetic 12-bit DNG: " + filepath.string());
}

ImageData decodeRawSingle(const std::string& path) {
    RAWProcessOptions options;
    options.bayerDemosaic = BayerDemosaicMethod::Legacy;
    RAWProcessor processor;
    ImageData output;
    require(processor.loadFile(path) == ErrorCode::Success, "Single-thread loadFile failed: " + path);
    require(processor.process(options, output) == ErrorCode::Success, "Single-thread process failed: " + path);
    require(output.width > 0 && output.height > 0 && !output.pixels.empty(), "Empty decoded output: " + path);
    return output;
}

struct SessionRender {
    uint32_t width = 0;
    uint32_t height = 0;
    std::vector<uint8_t> bytes;
};

SessionRender renderSessionOnce(sony2fuji_session* session, const std::string& path, uint32_t longEdgeLimit) {
    sony2fuji_request req{};
    req.version = SONY2FUJI_REQUEST_VERSION;
    req.struct_size = sizeof(req);
    req.input_path = path.c_str();
    req.input_type = SONY2FUJI_INPUT_RAW;
    req.wb_mode = SONY2FUJI_WB_CAMERA;
    req.brightness = 1.0f;
    req.contrast = 1.0f;
    req.saturation = 1.0f;
    req.output_target = SONY2FUJI_TARGET_BUFFER;
    req.output_format = SONY2FUJI_OUTPUT_RGB8;
    req.intent = SONY2FUJI_INTENT_FINAL;
    if (longEdgeLimit > 0) {
        req.size_mode = SONY2FUJI_SIZE_LIMIT_LONG_EDGE;
        req.long_edge = longEdgeLimit;
    } else {
        req.size_mode = SONY2FUJI_SIZE_NATIVE;
    }

    sony2fuji_buffer buf{};
    const sony2fuji_status status = sony2fuji_process(session, &req, &buf);
    SessionRender result;
    if (status == SONY2FUJI_STATUS_OK && buf.data && buf.size_bytes > 0) {
        result.width = buf.width;
        result.height = buf.height;
        const auto* ptr = static_cast<const uint8_t*>(buf.data);
        result.bytes.assign(ptr, ptr + buf.size_bytes);
    }
    sony2fuji_release_buffer(&buf);
    require(status == SONY2FUJI_STATUS_OK && !result.bytes.empty(),
            "sony2fuji_process failed with status " + std::to_string(status) + " for " + path);
    return result;
}

SessionRender renderFreshSession(const std::string& path, uint32_t longEdgeLimit) {
    sony2fuji_session* rawHandle = nullptr;
    require(sony2fuji_session_create(&rawHandle) == SONY2FUJI_STATUS_OK, "Create C API session");
    std::unique_ptr<sony2fuji_session, decltype(&sony2fuji_session_destroy)> session(
        rawHandle, sony2fuji_session_destroy);
    const sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpu), SONY2FUJI_GPU_OFF};
    require(sony2fuji_session_set_gpu_config(rawHandle, &gpu) == SONY2FUJI_STATUS_OK, "Disable GPU for CPU thread check");
    return renderSessionOnce(rawHandle, path, longEdgeLimit);
}

bool identicalImage(const ImageData& a, const ImageData& b) {
    if (a.width != b.width || a.height != b.height || a.pixels.size() != b.pixels.size()) {
        return false;
    }
    return std::memcmp(a.pixels.data(), b.pixels.data(), a.pixels.size() * sizeof(RGB)) == 0;
}

void verifyConcurrentDecode(const std::string& label,
                            const std::string& pathA,
                            const std::string& pathB,
                            int iterations,
                            uint32_t sessionLongEdgeLimit) {
    const ImageData expectedRawA = decodeRawSingle(pathA);
    const ImageData expectedRawB = decodeRawSingle(pathB);
    require(!identicalImage(expectedRawA, expectedRawB), label + ": fixtures A and B must decode to distinct pixels");

    constexpr size_t threadCount = 4;
    {
        Barrier barrier(threadCount);
        std::atomic<int> mismatches{0};
        std::atomic<int> errors{0};
        std::vector<std::thread> workers;
        workers.reserve(threadCount);
        for (size_t t = 0; t < threadCount; ++t) {
            workers.emplace_back([&, t] {
                const bool useB = (t % 2) == 1;
                const std::string& path = useB ? pathB : pathA;
                const ImageData& expected = useB ? expectedRawB : expectedRawA;
                RAWProcessOptions options;
                options.bayerDemosaic = BayerDemosaicMethod::Legacy;
                for (int i = 0; i < iterations; ++i) {
                    RAWProcessor processor;
                    ImageData actual;
                    barrier.arriveAndWait();
                    if (processor.loadFile(path) != ErrorCode::Success ||
                        processor.process(options, actual) != ErrorCode::Success) {
                        ++errors;
                        continue;
                    }
                    if (!identicalImage(expected, actual)) {
                        ++mismatches;
                    }
                }
            });
        }
        for (auto& w : workers) w.join();
        require(errors.load() == 0 && mismatches.load() == 0,
                label + " concurrent RAWProcessor failed (errors=" + std::to_string(errors.load()) +
                    ", mismatches=" + std::to_string(mismatches.load()) + ")");
        std::cout << "PASS " << label << " concurrent RAWProcessor (" << threadCount << " threads x "
                  << iterations << " iterations, bit-identical)\n";
    }

    const SessionRender expectedSessionA = renderFreshSession(pathA, sessionLongEdgeLimit);
    const SessionRender expectedSessionB = renderFreshSession(pathB, sessionLongEdgeLimit);
    {
        Barrier barrier(threadCount);
        std::atomic<int> mismatches{0};
        std::atomic<int> errors{0};
        std::vector<std::thread> workers;
        workers.reserve(threadCount);
        for (size_t t = 0; t < threadCount; ++t) {
            workers.emplace_back([&, t] {
                const bool useB = (t % 2) == 1;
                const std::string& path = useB ? pathB : pathA;
                const SessionRender& expected = useB ? expectedSessionB : expectedSessionA;

                sony2fuji_session* rawHandle = nullptr;
                if (sony2fuji_session_create(&rawHandle) != SONY2FUJI_STATUS_OK) {
                    ++errors;
                    for (int i = 0; i < iterations; ++i) barrier.arriveAndWait();
                    return;
                }
                std::unique_ptr<sony2fuji_session, decltype(&sony2fuji_session_destroy)> session(
                    rawHandle, sony2fuji_session_destroy);
                const sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpu), SONY2FUJI_GPU_OFF};
                if (sony2fuji_session_set_gpu_config(rawHandle, &gpu) != SONY2FUJI_STATUS_OK) {
                    ++errors;
                    for (int i = 0; i < iterations; ++i) barrier.arriveAndWait();
                    return;
                }

                for (int i = 0; i < iterations; ++i) {
                    barrier.arriveAndWait();
                    try {
                        const SessionRender actual = renderSessionOnce(rawHandle, path, sessionLongEdgeLimit);
                        if (actual.width != expected.width || actual.height != expected.height ||
                            actual.bytes.size() != expected.bytes.size() ||
                            std::memcmp(actual.bytes.data(), expected.bytes.data(), expected.bytes.size()) != 0) {
                            ++mismatches;
                        }
                    } catch (...) {
                        ++errors;
                    }
                }
            });
        }
        for (auto& w : workers) w.join();
        require(errors.load() == 0 && mismatches.load() == 0,
                label + " concurrent sony2fuji_session failed (errors=" + std::to_string(errors.load()) +
                    ", mismatches=" + std::to_string(mismatches.load()) + ")");
        std::cout << "PASS " << label << " concurrent sony2fuji_session (" << threadCount << " threads x "
                  << iterations << " iterations, bit-identical)\n";
    }
}

} // namespace

int main(int argc, char** argv) {
    std::cout << std::unitbuf;
    try {
        TempDir temp("rawlab-thread-safety");
        const auto dngA = temp.path / "synthetic_a.dng";
        const auto dngB = temp.path / "synthetic_b.dng";

        const int32_t matrixA[9] = {6722, -635, -963, -4287, 12460, 2028, -908, 2162, 5668};
        const uint32_t neutralA[3] = {470, 1000, 620};
        const int32_t matrixB[9] = {11240, -4810, -720, -1950, 10680, 1540, -320, 1290, 7410};
        const uint32_t neutralB[3] = {780, 1000, 430};

        writePacked12BitBayerDng(dngA, "RawLab Thread Camera A", matrixA, neutralA, 0);
        writePacked12BitBayerDng(dngB, "RawLab Thread Camera B", matrixB, neutralB, 1);

        verifyConcurrentDecode("synthetic 12-bit packed DNG", dngA.string(), dngB.string(), 20, 0);

        if (argc == 3) {
            verifyConcurrentDecode("external RAW pair", argv[1], argv[2], 4, 1024);
        } else if (argc != 1) {
            std::cerr << "usage: raw_thread_safety_tests [RAW_A RAW_B]\n";
            return 2;
        }
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n';
        return 1;
    }
    return 0;
}
