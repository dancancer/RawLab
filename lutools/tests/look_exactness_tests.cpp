#include "look_photo_oracle.h"
#include "core/photo_lut.h"
#include "core/lut_interpolation.h"
#include "sony2fuji/lut_applicator.h"
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <chrono>

using namespace sony2fuji;
namespace oracle = sony2fuji::look_oracle;

namespace {
uint32_t state = 0x917ac35d;
size_t comparisons = 0;
bool inject = false;

uint32_t randomBits() {
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    return state;
}

float unit() { return float(randomBits() >> 8) / 16777216.f; }

void equal(const ImageData& actual, const ImageData& expected, const char* stage) {
    ++comparisons;
    auto pixels = actual.pixels;
    if (inject && !pixels.empty()) pixels.front().r = std::nextafter(pixels.front().r, INFINITY);
    if (actual.width != expected.width || actual.height != expected.height ||
        pixels.size() != expected.pixels.size() ||
        std::memcmp(pixels.data(), expected.pixels.data(), pixels.size() * sizeof(RGB)))
        throw std::runtime_error(std::string(stage) + " differs bit-for-bit from df4dc03 oracle #" +
            std::to_string(comparisons));
}

void sameFloat(float actual, float expected, const char* stage) {
    ++comparisons;
    if (std::memcmp(&actual, &expected, sizeof(float)))
        throw std::runtime_error(std::string(stage) + " scalar differs from df4dc03 oracle");
}

ImageData input(int width, int height) {
    ImageData image(width, height);
    const float edges[] = {-0.f, 0, -1, 1, .1845f, .0031308f, .00089f, .00088899597f,
        std::numeric_limits<float>::denorm_min(), std::numeric_limits<float>::max()};
    for (size_t i = 0; i < image.pixels.size(); ++i) {
        const float r = 3 * unit() - .01f, g = 3 * unit() - .01f, b = 3 * unit() - .01f;
        image.pixels[i] = RGB(r, g, b);
        if (i < std::size(edges)) image.pixels[i] = RGB(edges[i], edges[i], edges[i]);
    }
    return image;
}

void gammaMatrix() {
    for (const auto& size : {std::pair<int, int>{1, 1}, {1, 17}, {19, 1}, {7, 5}, {65, 33}})
        for (int flags = 0; flags < 8; ++flags) {
            auto actual = input(size.first, size.second), expected = actual;
            GammaConverter::FLog2Options options;
            options.normalizeToRange = flags & 1;
            options.clampOnly = flags & 2;
            options.enableDiagnostics = flags & 4;
            const auto got = GammaConverter::applyFLog2ToImage(actual, options);
            const auto reference = oracle::GammaConverter::applyFLog2ToImage(expected, options);
            equal(actual, expected, "F-Log2");
            if (options.enableDiagnostics) {
                sameFloat(got.min_linear, reference.min_linear, "diagnostic minimum");
                sameFloat(got.max_linear, reference.max_linear, "diagnostic maximum");
                sameFloat(got.scale, reference.scale, "diagnostic scale");
                sameFloat(got.offset, reference.offset, "diagnostic offset");
                if (got.negative_pixels != reference.negative_pixels || got.over_pixels != reference.over_pixels)
                    throw std::runtime_error("diagnostic counts differ");
            } else if (got.min_linear != 0 || got.max_linear != 0 || got.scale != 1 ||
                got.offset != 0 || got.negative_pixels || got.over_pixels) {
                throw std::runtime_error("Disabled diagnostics must return default statistics");
            }
        }
    /* 曲线保留 NaN 的位级比较；LUT 的 NaN 传播单独按分类比较。 */
    const uint32_t edges[] = {0, 0x80000000, 1, 0x80000001, 0x7f800000, 0xff800000,
        0x7fc12345, 0xffc54321, 0x7f7fffff, 0xff7fffff};
    for (int i = 0; i < 100000; ++i) {
        const uint32_t bits = i < int(std::size(edges)) ? edges[i] : randomBits();
        float value;
        std::memcpy(&value, &bits, sizeof(value));
        sameFloat(GammaConverter::applyFLog2(value), oracle::GammaConverter::applyFLog2(value), "F-Log2");
        sameFloat(GammaConverter::applySRGBGamma(value), oracle::GammaConverter::applySRGBGamma(value), "sRGB");
        sameFloat(neutralDisplay(value), oracle::neutralDisplay(value), "neutral display");
    }
    ImageData empty;
    GammaConverter::FLog2Options options;
    const auto got = GammaConverter::applyFLog2ToImage(empty, options);
    const auto expected = oracle::GammaConverter::applyFLog2ToImage(empty, options);
    sameFloat(got.min_linear, expected.min_linear, "empty diagnostic");
    auto exceptional = input(10, 1);
    for (size_t i = 0; i < std::size(edges); ++i) {
        float value;
        std::memcpy(&value, &edges[i], sizeof(value));
        exceptional.pixels[i] = RGB(value, value, value);
    }
    auto reference = exceptional;
    options.enableDiagnostics = true;
    const auto actualStats = GammaConverter::applyFLog2ToImage(exceptional, options);
    const auto referenceStats = oracle::GammaConverter::applyFLog2ToImage(reference, options);
    equal(exceptional, reference, "exceptional F-Log2 image");
    sameFloat(actualStats.min_linear, referenceStats.min_linear, "exceptional minimum");
    sameFloat(actualStats.max_linear, referenceStats.max_linear, "exceptional maximum");
    if (actualStats.negative_pixels != referenceStats.negative_pixels ||
        actualStats.over_pixels != referenceStats.over_pixels) throw std::runtime_error("Exceptional counts differ");
}

struct Temp {
    std::filesystem::path path = std::filesystem::temp_directory_path() /
        ("rawlab-look-exactness-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    Temp() { std::filesystem::create_directory(path); }
    ~Temp() { std::error_code error; std::filesystem::remove_all(path, error); }
};

std::shared_ptr<LUT3D> table(const std::filesystem::path& path, int size, const std::vector<RGB>& data,
    RGB low, RGB high) {
    {
        std::ofstream file(path);
        file << std::setprecision(std::numeric_limits<float>::max_digits10)
             << "LUT_3D_SIZE " << size << "\nDOMAIN_MIN " << low.r << ' ' << low.g << ' ' << low.b
             << "\nDOMAIN_MAX " << high.r << ' ' << high.g << ' ' << high.b << '\n';
        for (const auto& p : data) file << p.r << ' ' << p.g << ' ' << p.b << '\n';
        if (!file) throw std::runtime_error("Cannot write fixture");
    }
    auto result = std::make_shared<LUT3D>();
    if (result->loadFromFile(path.string()) != ErrorCode::Success) throw std::runtime_error("Cannot parse fixture");
    return result;
}

void look(ImageData& image, const LUTApplicator& lut, LUTTransfer in, LUTTransfer out, float strength, bool display) {
    auto base = image;
    for (auto& p : base.pixels) {
        const auto encode = display ? GammaConverter::applySRGBGamma : neutralDisplay;
        p = RGB(encode(p.r), encode(p.g), encode(p.b));
    }
    if (strength == 0) { image = std::move(base); return; }
    if (in == LUTTransfer::SRGB) image = base;
    else if (in == LUTTransfer::FLog2) {
        ColorConverter().convertImage(image, ColorSpace::sRGB, ColorSpace::FujiFilm_FGamut);
        GammaConverter::applyFLog2ToImage(image, {});
    } else encodePhotoLUTInput(image, in);
    for (const auto& p : image.pixels) if (!std::isfinite(p.r) || !std::isfinite(p.g) || !std::isfinite(p.b))
        throw std::runtime_error("Full Look bit-exact fixture must enter LUT with finite pixels");
    if (lut.applyToImage(image) != ErrorCode::Success) throw std::runtime_error("LUT failed");
    renderPhotoLUTOutput(image, out);
    for (size_t i = 0; i < image.pixels.size(); ++i) {
        auto& b = image.pixels[i];
        const auto& a = base.pixels[i];
        b = RGB(a.r+(b.r-a.r)*strength, a.g+(b.g-a.g)*strength, a.b+(b.b-a.b)*strength);
    }
}

void referenceLook(ImageData& image, const oracle::LUTApplicator& lut, LUTTransfer in, LUTTransfer out,
    float strength, bool display) {
    auto base = image;
    for (auto& p : base.pixels) {
        const auto encode = display ? oracle::GammaConverter::applySRGBGamma : oracle::neutralDisplay;
        p = RGB(encode(p.r), encode(p.g), encode(p.b));
    }
    if (strength == 0) { image = std::move(base); return; }
    if (in == LUTTransfer::SRGB) image = base;
    else if (in == LUTTransfer::FLog2) {
        ColorConverter().convertImage(image, ColorSpace::sRGB, ColorSpace::FujiFilm_FGamut);
        oracle::GammaConverter::applyFLog2ToImage(image, {});
    } else oracle::encodePhotoLUTInput(image, in);
    for (const auto& p : image.pixels) if (!std::isfinite(p.r) || !std::isfinite(p.g) || !std::isfinite(p.b))
        throw std::runtime_error("Full Look oracle fixture must enter LUT with finite pixels");
    if (lut.applyToImage(image) != ErrorCode::Success) throw std::runtime_error("Oracle LUT failed");
    oracle::renderPhotoLUTOutput(image, out);
    for (size_t i = 0; i < image.pixels.size(); ++i) {
        auto& b = image.pixels[i];
        const auto& a = base.pixels[i];
        b = RGB(a.r+(b.r-a.r)*strength, a.g+(b.g-a.g)*strength, a.b+(b.b-a.b)*strength);
    }
}

void everyGrid() {
    /* 所有受支持的 2..256 网格都测核心插值，避免写出数十亿行临时 CUBE。 */
    for (int grid = 2; grid <= 256; ++grid) {
        std::vector<RGB> data(size_t(grid)*grid*grid);
        for (size_t i = 0; i < data.size(); ++i)
            data[i] = RGB(float(i%97)/31-.5f, float(i%71)/17, float(i%53)/19);
        data[0] = RGB(std::numeric_limits<float>::max(), std::numeric_limits<float>::lowest(), -0.f);
        data[1] = RGB(std::numeric_limits<float>::lowest(), std::numeric_limits<float>::max(),
            std::numeric_limits<float>::denorm_min());
        oracle::LUTApplicator reference(std::make_shared<oracle::LUT3D>(grid, data));
        ImageData actual(521, 1), expected(521, 1);
        for (size_t i = 0; i < actual.pixels.size(); ++i) {
            float r = unit(), g = unit(), b = unit();
            if (i < 8) { r = i&1 ? 1.f : 0.f; g = i&2 ? 1.f : 0.f; b = i&4 ? 1.f : 0.f; }
            if (i >= 8 && i < 20) {
                const float point = float((i-8)*(grid-1)/11)/float(grid-1);
                r = std::nextafter(point, i&1 ? 1.f : 0.f); g = point; b = point;
            }
            actual.pixels[i] = detail::interpolateLUT(data.data(), grid, r, g, b);
            expected.pixels[i] = reference.apply(RGB(r,g,b));
        }
        equal(actual, expected, "all CUBE grid sizes");
    }
}

void lutMatrix() {
    Temp temporary;
    for (int grid : {2, 3, 17, 33, 65}) for (bool domain : {false, true}) {
        std::vector<RGB> data(size_t(grid)*grid*grid);
        for (auto& p : data) {
            const float r = 1.5f*unit()-.25f, g = 1.5f*unit()-.25f, b = 1.5f*unit()-.25f;
            p = RGB(r, g, b);
        }
        const RGB low = domain ? RGB(-.125f, .15f, -.25f) : RGB(0, 0, 0);
        const RGB high = domain ? RGB(1.125f, .85f, 1.25f) : RGB(1, 1, 1);
        const auto lut = table(temporary.path / "fixture.cube", grid, data, low, high);
        LUTApplicator actualLut(lut);
        oracle::LUTApplicator referenceLut(std::make_shared<oracle::LUT3D>(grid, data, low, high));
        const float special[] = {-0.f, .375f, INFINITY, -INFINITY,
            std::numeric_limits<float>::quiet_NaN(), -std::numeric_limits<float>::quiet_NaN()};
        for (float r : special) for (float g : special) for (float b : special) {
            const auto actual = actualLut.apply(RGB(r, g, b));
            const auto expected = referenceLut.apply(RGB(r, g, b));
            const float got[] = {actual.r, actual.g, actual.b};
            const float reference[] = {expected.r, expected.g, expected.b};
            for (int channel = 0; channel < 3; ++channel) {
                if (std::isnan(reference[channel])) {
                    ++comparisons;
                    if (!std::isnan(got[channel])) throw std::runtime_error("LUT NaN propagation differs");
                } else sameFloat(got[channel], reference[channel], "LUT nonfinite input");
            }
        }
        ImageData endpoints(4, 1);
        endpoints.pixels = {RGB(INFINITY, -INFINITY, -0.f), low, high,
            RGB(std::numeric_limits<float>::lowest(), std::numeric_limits<float>::max(),
                std::numeric_limits<float>::denorm_min())};
        auto referenceEndpoints = endpoints;
        if (actualLut.applyToImage(endpoints) != ErrorCode::Success ||
            referenceLut.applyToImage(referenceEndpoints) != ErrorCode::Success)
            throw std::runtime_error("Endpoint LUT status differs");
        equal(endpoints, referenceEndpoints, "CUBE domain endpoints and infinities");
        for (const auto& size : {std::pair<int, int>{1, 1}, {1, 17}, {19, 1}, {7, 5}, {65, 33}}) {
            auto source = input(size.first, size.second);
            auto actual = source, expected = source;
            if (actualLut.applyToImage(actual) != ErrorCode::Success ||
                referenceLut.applyToImage(expected) != ErrorCode::Success)
                throw std::runtime_error("In-place LUT status differs");
            equal(actual, expected, "CUBE in-place");
            actual = {}; expected = {};
            if (actualLut.applyToImage(source, actual) != ErrorCode::Success ||
                referenceLut.applyToImage(source, expected) != ErrorCode::Success)
                throw std::runtime_error("Out-of-place LUT status differs");
            equal(actual, expected, "CUBE out-of-place");
            actual = source; expected = source;
            if (actualLut.applyToImage(actual, actual) != ErrorCode::Success ||
                referenceLut.applyToImage(expected, expected) != ErrorCode::Success)
                throw std::runtime_error("Aliased LUT status differs");
            equal(actual, expected, "CUBE aliased");
            for (auto in : {LUTTransfer::FLog, LUTTransfer::FLog2, LUTTransfer::FLog2C, LUTTransfer::SRGB})
                for (auto out : {LUTTransfer::Display, LUTTransfer::FLog, LUTTransfer::FLog2, LUTTransfer::FLog2C})
                    for (float strength : {0.f, .375f, 1.f, 1.6f, 2.f}) for (bool display : {false, true}) {
                        if (in == LUTTransfer::SRGB && out != LUTTransfer::Display) continue;
                        actual = source; expected = source;
                        look(actual, actualLut, in, out, strength, display);
                        referenceLook(expected, referenceLut, in, out, strength, display);
                        equal(actual, expected, "complete Look");
                    }
        }
        ImageData empty;
        if (actualLut.applyToImage(empty) != referenceLut.applyToImage(empty))
            throw std::runtime_error("Empty LUT status differs");
    }
    /* 低角为负零，其余顶点为正数，让原始权重的零符号可观测。 */
    std::vector<RGB> zeroData(8, RGB(1, 1, 1));
    zeroData[0] = RGB(-0.f, -0.f, -0.f);
    LUTApplicator zeroLut(table(temporary.path / "signed-zero.cube", 2, zeroData, RGB(), RGB(1, 1, 1)));
    oracle::LUTApplicator referenceZero(std::make_shared<oracle::LUT3D>(2, zeroData));
    for (const auto p : {RGB(-0.f, -0.f, -0.f), RGB(), RGB(-0.f, 0, -0.f), RGB(0, -0.f, 0)}) {
        const auto got = zeroLut.apply(p), expected = referenceZero.apply(p);
        sameFloat(got.r, expected.r, "LUT signed zero red");
        sameFloat(got.g, expected.g, "LUT signed zero green");
        sameFloat(got.b, expected.b, "LUT signed zero blue");
    }
    const auto negativeZero = zeroLut.apply(RGB(-0.f, -0.f, -0.f));
    if (!std::signbit(negativeZero.r) || !std::signbit(negativeZero.g) || !std::signbit(negativeZero.b))
        throw std::runtime_error("LUT must preserve negative-zero weights");
    LUTApplicator invalid(nullptr);
    oracle::LUTApplicator referenceInvalid(nullptr);
    auto image = input(1, 1);
    if (invalid.applyToImage(image) != referenceInvalid.applyToImage(image))
        throw std::runtime_error("Invalid LUT status differs");
}
} // namespace

int main(int argc, char** argv) {
    try {
        inject = argc == 2 && std::string(argv[1]) == "--inject-ulp";
        gammaMatrix();
        lutMatrix();
        everyGrid();
        std::cout << "PASS " << comparisons << " bit-exact Look comparisons (seed 0x917ac35d)\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n';
        return 1;
    }
}
