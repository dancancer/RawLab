#include "sony2fuji/raw_processor.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

using namespace sony2fuji;

namespace {

int failures = 0;

void check(bool condition, const std::string& name) {
    std::cout << (condition ? "PASS " : "FAIL ") << name << '\n';
    if (!condition) ++failures;
}

bool equalPixels(const ImageData& expected, const ImageData& actual, const std::string& name) {
    if (expected.width != actual.width || expected.height != actual.height) {
        std::cerr << name << ": dimensions " << actual.width << 'x' << actual.height
                  << ", expected " << expected.width << 'x' << expected.height << '\n';
        return false;
    }
    if (expected.pixels.size() != actual.pixels.size()) return false;
    float maximum = 0;
    size_t mismatch = expected.pixels.size();
    for (size_t i = 0; i < expected.pixels.size(); ++i) {
        const auto& a = expected.pixels[i];
        const auto& b = actual.pixels[i];
        maximum = std::max(maximum, std::max({std::abs(a.r - b.r), std::abs(a.g - b.g),
                                              std::abs(a.b - b.b)}));
        if (mismatch == expected.pixels.size() &&
            (a.r != b.r || a.g != b.g || a.b != b.b)) mismatch = i;
    }
    if (mismatch != expected.pixels.size()) {
        std::cerr << name << ": first pixel mismatch at " << mismatch
                  << ", max error " << maximum << '\n';
        return false;
    }
    return true;
}

ImageData renderFresh(const std::string& filepath, const RAWProcessOptions& options) {
    RAWProcessor processor;
    ImageData output;
    if (processor.loadFile(filepath) != ErrorCode::Success ||
        processor.process(options, output) != ErrorCode::Success) {
        output = {};
    }
    return output;
}

RAWProcessOptions temperatureOptions(float temperature) {
    RAWProcessOptions options;
    options.useCameraWhiteBalance = false;
    options.useTemperatureWhiteBalance = true;
    options.temperature = temperature;
    options.tint = 0;
    return options;
}

void checkWhiteBalanceReuse(const std::string& filepath) {
    const std::vector<RAWProcessOptions> options = {
        RAWProcessOptions(),
        temperatureOptions(4000),
        temperatureOptions(8500),
        RAWProcessOptions(),
    };
    RAWProcessor reused;
    check(reused.loadFile(filepath) == ErrorCode::Success, "reuse fixture loads");
    for (size_t i = 0; i < options.size(); ++i) {
        const auto expected = renderFresh(filepath, options[i]);
        ImageData actual;
        const auto status = reused.process(options[i], actual);
        check(status == ErrorCode::Success && !expected.pixels.empty(),
              "fresh and reused WB render succeed " + std::to_string(i));
        if (status == ErrorCode::Success && !expected.pixels.empty())
            check(equalPixels(expected, actual, "WB sequence " + std::to_string(i)),
                  "reused WB render is pixel-identical " + std::to_string(i));
    }
}

void checkTemperatureDoesNotReopen(const std::string& filepath) {
    const auto temporary = std::filesystem::temp_directory_path() /
        ("rawtools-reuse-" + std::to_string(static_cast<unsigned long long>(std::hash<std::string>{}(filepath))) + ".raw");
    std::filesystem::copy_file(filepath, temporary, std::filesystem::copy_options::overwrite_existing);
    auto processorOwner = std::make_unique<RAWProcessor>();
    auto& processor = *processorOwner;
    const auto options4000 = temperatureOptions(4000);
    const auto options8500 = temperatureOptions(8500);
    ImageData first, second;
    const bool loaded = processor.loadFile(temporary.string()) == ErrorCode::Success;
    const bool firstOk = loaded && processor.process(options4000, first) == ErrorCode::Success;
    std::error_code error;
    std::filesystem::remove(temporary.string() + ".moved");
    std::filesystem::rename(temporary, temporary.string() + ".moved", error);
#ifdef _WIN32
    // Windows fopen denies rename while the decoder owns the file handle.
    // Still compare reused WB; the source-removal proof runs on POSIX.
    const bool secondOk = firstOk &&
        processor.process(options8500, second) == ErrorCode::Success;
    check(secondOk && equalPixels(renderFresh(filepath, options8500), second, "Windows WB reuse"),
        "temperature WB reuses the Windows decoder and matches a fresh render");
#else
    const bool secondOk = firstOk && !error &&
        processor.process(options8500, second) == ErrorCode::Success;
    check(secondOk, "temperature WB reuses unpacked RAW after source rename");
#endif
    processorOwner.reset();
    std::filesystem::remove(temporary.string() + ".moved");
    std::filesystem::remove(temporary);
}

void checkHalfSizeReuse(const std::string& filepath, bool requireReduction) {
    RAWProcessOptions fullOptions;
    RAWProcessOptions halfOptions = fullOptions;
    halfOptions.halfSize = true;

    RAWProcessor processor;
    check(processor.loadFile(filepath) == ErrorCode::Success, "half-size fixture loads");
    ImageData fullBefore, half, fullAfter;
    const auto fullBeforeStatus = processor.process(fullOptions, fullBefore);
    const auto halfStatus = processor.process(halfOptions, half);
    const auto fullAfterStatus = processor.process(fullOptions, fullAfter);
    const auto expectedFull = renderFresh(filepath, fullOptions);
    const auto expectedHalf = renderFresh(filepath, halfOptions);

    check(fullBeforeStatus == ErrorCode::Success && halfStatus == ErrorCode::Success &&
              fullAfterStatus == ErrorCode::Success && !expectedFull.pixels.empty() &&
              !expectedHalf.pixels.empty(),
          "full-half-full sequence succeeds");
    if (fullBeforeStatus == ErrorCode::Success && halfStatus == ErrorCode::Success &&
        fullAfterStatus == ErrorCode::Success) {
        check(equalPixels(expectedFull, fullBefore, "full before half"),
              "full render matches fresh before half-size preview");
        check(equalPixels(expectedHalf, half, "half-size"),
              "half-size render matches fresh processor");
        check(equalPixels(expectedFull, fullAfter, "full after half"),
              "full render remains pixel-identical after half-size preview");
        check(half.width <= fullBefore.width && half.height <= fullBefore.height &&
                  (!requireReduction || half.width < fullBefore.width || half.height < fullBefore.height),
              "half-size dimensions are isolated from full-size output");
    }
}

void checkInvalidLoadClearsState(const std::string& filepath) {
    const auto temporary = std::filesystem::temp_directory_path() / "rawtools-corrupt-reuse.raw";
    {
        std::ofstream stream(temporary, std::ios::binary | std::ios::trunc);
        stream << "not a RAW file";
    }
    RAWProcessor processor;
    RAWProcessOptions options;
    ImageData good;
    const bool loaded = processor.loadFile(filepath) == ErrorCode::Success;
    const bool rendered = loaded && processor.process(options, good) == ErrorCode::Success;
    const bool rejected = processor.loadFile(temporary.string()) != ErrorCode::Success;
    ImageData stale = good;
    const bool noStaleOutput = processor.process(options, stale) != ErrorCode::Success &&
        stale.width == 0 && stale.height == 0 && stale.pixels.empty();
    check(rendered && rejected && noStaleOutput, "corrupt new file cannot expose stale output");
    std::filesystem::remove(temporary);
}

} // namespace

int main(int argc, char** argv) {
    std::cout << std::unitbuf;
    if (argc < 1 || argc > 3) {
        std::cerr << "usage: raw_reuse_tests SONY_RAW [DNG_RAW]\n";
        return 2;
    }
    const char* argRaw = (argc >= 2 && *argv[1]) ? argv[1] : nullptr;
    const char* envRaw = std::getenv("RAWLAB_TEST_RAW");
    if (envRaw && !*envRaw) envRaw = nullptr;
    const char* rawArg = argRaw ? argRaw : envRaw;
    if (!rawArg) {
        std::cout << "SKIP raw_reuse: supply SONY2FUJI_TEST_RAW or RAWLAB_TEST_RAW\n";
        return 77;
    }
    if (!std::filesystem::is_regular_file(std::filesystem::u8path(rawArg))) {
        std::cerr << "FAIL raw_reuse: RAW sample does not exist: " << rawArg << '\n';
        return 1;
    }
    if (argc == 3 && *argv[2] && !std::filesystem::is_regular_file(std::filesystem::u8path(argv[2]))) {
        std::cerr << "FAIL raw_reuse: second RAW sample does not exist: " << argv[2] << '\n';
        return 1;
    }
    const std::string sonyRaw = rawArg;
    try {
        checkWhiteBalanceReuse(sonyRaw);
        checkTemperatureDoesNotReopen(sonyRaw);
        checkHalfSizeReuse(sonyRaw, true);
        checkInvalidLoadClearsState(sonyRaw);
        if (argc == 3 && *argv[2])
            checkHalfSizeReuse(argv[2], true);
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
    return failures == 0 ? 0 : 1;
}
