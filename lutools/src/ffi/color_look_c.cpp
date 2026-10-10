#include "sony2fuji/ffi/sony2fuji_c.h"
#include "sony2fuji/color_recipe.h"
#include "sony2fuji/lut_applicator.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <limits>
#include <locale>
#include <random>
#include <stdexcept>
#include <vector>

namespace {
using sony2fuji::RGB;
using sony2fuji::ColorRecipe;

struct Staging {
    std::filesystem::path directory, file;
    explicit Staging(const std::filesystem::path& destination) {
        static std::atomic<uint64_t> sequence{0};
        const auto parent = destination.has_parent_path() ? destination.parent_path() : std::filesystem::path(".");
        for (int attempt = 0; attempt < 10; ++attempt) {
            directory = parent / (".rawlab-look-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()) +
                "-" + std::to_string(sequence++));
            std::error_code error;
            if (std::filesystem::create_directory(directory, error)) { file = directory / "look.cube"; return; }
            if (error) throw std::filesystem::filesystem_error("Cannot create staging directory", directory, error);
        }
        throw std::runtime_error("Cannot reserve staging path");
    }
    ~Staging() { std::error_code error; std::filesystem::remove_all(directory, error); }
    void install(const std::filesystem::path& destination) {
        // 同目录硬链接原子安装，目标若已存在则失败，避免 rename 覆盖用户文件。
        std::filesystem::create_hard_link(file, destination);
    }
};

std::filesystem::path destinationPath(const char* path) {
    if (!path || !*path) throw std::invalid_argument("Missing destination");
    auto destination = std::filesystem::u8path(path);
    if (sony2fuji::LUTParser::detectFormat(path) != "cube" || std::filesystem::exists(destination))
        throw std::invalid_argument("Destination must be a new CUBE");
    return destination;
}

std::ofstream writer(const std::filesystem::path& path, int size, const RGB& lo = RGB(0,0,0), const RGB& hi = RGB(1,1,1)) {
    std::ofstream out(path);
    out.exceptions(std::ios::badbit | std::ios::failbit);
    out.imbue(std::locale::classic());
    out << std::setprecision(std::numeric_limits<float>::max_digits10)
        << "TITLE \"RawLab AI Color Look\"\n#RawLabAI:1\n#Gamma:sRGB to sRGB\n"
        << "#Gamut:ITU-R BT.709 to ITU-R BT.709\n#OutputTransfer:sRGB\n"
        << "# Apply to display-sRGB, not Log or linear RAW. Strength: 100%.\n"
        << "LUT_3D_SIZE " << size << "\nDOMAIN_MIN " << lo.r << ' ' << lo.g << ' ' << lo.b
        << "\nDOMAIN_MAX " << hi.r << ' ' << hi.g << ' ' << hi.b << '\n';
    return out;
}

void sample(const ColorRecipe& recipe, int size, const std::filesystem::path& path) {
    auto out = writer(path, size);
    for (int b = 0; b < size; ++b) for (int g = 0; g < size; ++g) for (int r = 0; r < size; ++r) {
        const auto p = recipe.apply(RGB(float(r)/(size-1), float(g)/(size-1), float(b)/(size-1)));
        if (!std::isfinite(p.r) || !std::isfinite(p.g) || !std::isfinite(p.b))
            throw std::runtime_error("Nonfinite CUBE sample");
        out << p.r << ' ' << p.g << ' ' << p.b << '\n';
    }
    out.close();
}

sony2fuji_color_look_report measure(const ColorRecipe& recipe, const std::filesystem::path& file) {
    auto lut = sony2fuji::LUTParser::loadLUTCached(file.u8string());
    if (!lut) throw std::runtime_error("Cannot reload generated CUBE");
    sony2fuji::LUTApplicator apply(lut);
    std::vector<float> errors;
    auto check = [&](const RGB& p) {
        const auto expected = recipe.apply(p), actual = apply.apply(p);
        for (float error : {std::abs(expected.r-actual.r), std::abs(expected.g-actual.g), std::abs(expected.b-actual.b)}) {
            if (!std::isfinite(error)) throw std::runtime_error("Nonfinite validation sample");
            errors.push_back(error);
        }
    };
    std::mt19937 rng(20261009);
    auto unit = [&]() { return float(double(rng()) / 4294967296.0); };
    for (int i = 0; i < 8192; ++i) {
        const float r = unit(), g = unit(), b = unit();
        check(RGB(r,g,b));
    }
    for (int b = 0; b <= 16; ++b) for (int g = 0; g <= 16; ++g) for (int r = 0; r <= 16; ++r)
        check(RGB(r/16.f,g/16.f,b/16.f));
    for (int i = 0; i <= 512; ++i) {
        const float v = i/512.f;
        check(RGB(v,v,v));
        for (int channel = 0; channel < 3; ++channel) {
            const float p[3] = {v, 1-v, .02f};
            check(RGB(p[channel], p[(channel+1)%3], p[(channel+2)%3]));
        }
    }
    std::sort(errors.begin(), errors.end());
    double total = 0;
    for (float error : errors) total += error;
    return {uint32_t(lut->getSize()), errors.back(), float(total/errors.size()), errors[size_t(.99*(errors.size()-1))]};
}

template<class Work> sony2fuji_status guarded(Work work) {
    try { return work(); }
    catch (const std::invalid_argument&) { return SONY2FUJI_STATUS_INVALID_ARGUMENT; }
    catch (const std::bad_alloc&) { return SONY2FUJI_STATUS_OUT_OF_MEMORY; }
    catch (const std::filesystem::filesystem_error&) { return SONY2FUJI_STATUS_IO_ERROR; }
    catch (const std::ios_base::failure&) { return SONY2FUJI_STATUS_IO_ERROR; }
    catch (...) { return SONY2FUJI_STATUS_PROCESSING_ERROR; }
}
}

extern "C" sony2fuji_status sony2fuji_compile_color_look(
    uint32_t version, const float* parameters, size_t count, const char* destination, sony2fuji_color_look_report* report) {
    if (report) *report = {};
    return guarded([&]() {
        const auto recipe = ColorRecipe::fromParameters(version, parameters, count);
        const auto path = destinationPath(destination);
        Staging staging(path);
        for (int size : {65, 129}) {
            sample(recipe, size, staging.file);
            const auto measurement = measure(recipe, staging.file);
            if (report) *report = measurement;
            if (measurement.max_error <= .02f) { staging.install(path); return SONY2FUJI_STATUS_OK; }
        }
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    });
}

extern "C" sony2fuji_status sony2fuji_export_color_look(const char* source, const char* destination) {
    return guarded([&]() {
        if (!source || !*source) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
        const auto path = destinationPath(destination);
        const auto input = std::filesystem::u8path(source);
        if (!std::filesystem::is_regular_file(input)) return SONY2FUJI_STATUS_IO_ERROR;
        auto lut = sony2fuji::LUTParser::loadLUTCached(source);
        if (!lut || lut->inputTransfer() != sony2fuji::LUTTransfer::SRGB) return SONY2FUJI_STATUS_UNSUPPORTED;
        Staging staging(path);
        auto out = writer(staging.file, lut->getSize(), lut->domainMin(), lut->domainMax());
        for (int b = 0; b < lut->getSize(); ++b) for (int g = 0; g < lut->getSize(); ++g) for (int r = 0; r < lut->getSize(); ++r) {
            const auto p = lut->getValue(r,g,b);
            out << p.r << ' ' << p.g << ' ' << p.b << '\n';
        }
        out.close();
        auto verified = sony2fuji::LUTParser::loadLUT(staging.file.u8string());
        if (!verified || verified->inputTransfer() != sony2fuji::LUTTransfer::SRGB) return SONY2FUJI_STATUS_PROCESSING_ERROR;
        staging.install(path);
        return SONY2FUJI_STATUS_OK;
    });
}
