#include "photo_lut.h"
#include "sony2fuji/lut_applicator.h"
#include <algorithm>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <random>
#include <stdexcept>
#include <vector>

using namespace sony2fuji;

namespace {
const auto toSrgb = ColorConverter::getConversionMatrix(ColorSpace::FujiFilm_FGamut, ColorSpace::sRGB);
const auto toGamut = ColorConverter::getConversionMatrix(ColorSpace::sRGB, ColorSpace::FujiFilm_FGamut);

RGB scene(const RGB& log) {
    return ColorConverter::applyMatrix(RGB(decodePhotoLog(log.r, LUTTransfer::FLog2),
        decodePhotoLog(log.g, LUTTransfer::FLog2), decodePhotoLog(log.b, LUTTransfer::FLog2)), toSrgb);
}

RGB neutral(const RGB& log) {
    const auto p = scene(log);
    return RGB(neutralDisplay(p.r), neutralDisplay(p.g), neutralDisplay(p.b));
}

void writeCube(const std::filesystem::path& file, int size) {
    std::ofstream out(file);
    out << "TITLE \"AI bake feasibility probe\"\n#Gamma:F-Log2 to RawLab Neutral Probe\n"
        << "#Gamut:F-Gamut to ITU-R BT.709\n#OutputTransfer:sRGB\nLUT_3D_SIZE " << size
        << "\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n" << std::setprecision(9);
    for (int b = 0; b < size; ++b) for (int g = 0; g < size; ++g) for (int r = 0; r < size; ++r) {
        const auto p = neutral(RGB(float(r) / (size - 1), float(g) / (size - 1), float(b) / (size - 1)));
        out << p.r << ' ' << p.g << ' ' << p.b << '\n';
    }
    out.close();
    if (!out) throw std::runtime_error("Cannot write probe CUBE");
}

void printRGB(const RGB& p) { std::cout << '[' << p.r << ',' << p.g << ',' << p.b << ']'; }

double measure(const char* label, const std::vector<RGB>& points, const LUTApplicator& lut) {
    std::vector<double> errors;
    double max = -1, total = 0;
    RGB witness, expected, actual;
    for (const auto& p : points) {
        const auto direct = neutral(p), sampled = lut.apply(p);
        for (double error : {std::abs(double(direct.r) - sampled.r),
                             std::abs(double(direct.g) - sampled.g),
                             std::abs(double(direct.b) - sampled.b)}) {
            if (!std::isfinite(error)) throw std::runtime_error("Nonfinite error");
            errors.push_back(error);
            total += error;
            if (error > max) { max = error; witness = p; expected = direct; actual = sampled; }
        }
    }
    std::sort(errors.begin(), errors.end());
    std::cout << "{\"cohort\":\"" << label << "\",\"samples\":" << points.size()
        << ",\"max\":" << max << ",\"mean\":" << total / errors.size()
        << ",\"p99\":" << errors[size_t(.99 * (errors.size() - 1))] << ",\"log\":";
    printRGB(witness);
    std::cout << ",\"scene\":"; printRGB(scene(witness));
    std::cout << ",\"direct\":"; printRGB(expected);
    std::cout << ",\"sampled\":"; printRGB(actual);
    std::cout << "}\n";
    return max;
}
}

int main(int argc, char** argv) {
    if (argc != 3) { std::cerr << "Usage: bake_gate_probe SIZE NEW_OUTPUT.cube\n"; return 1; }
    try {
        const int size = std::stoi(argv[1]);
        if ((size != 65 && size != 129) || std::filesystem::exists(argv[2]))
            throw std::runtime_error("Use size 65/129 and a new output path");
        std::vector<RGB> domain, gray, photographic;
        std::mt19937 rng(20261009);
        auto unit = [&]() { return float(double(rng()) / 4294967296.0); };
        for (int i = 0; i < 4096; ++i) {
            const float r = unit(), g = unit(), b = unit();
            domain.emplace_back(r, g, b);
        }
        for (int b = 0; b <= 16; ++b) for (int g = 0; g <= 16; ++g) for (int r = 0; r <= 16; ++r)
            domain.emplace_back(r / 16.f, g / 16.f, b / 16.f);
        for (int i = 0; i <= 512; ++i) gray.emplace_back(i / 512.f, i / 512.f, i / 512.f);
        for (int i = 0; i < 4096; ++i) {
            const float r = unit(), g = unit(), b = unit(), ev = -10 + 16 * unit();
            const float scale = std::exp2(ev);
            const auto p = ColorConverter::applyMatrix(RGB(r * scale, g * scale, b * scale), toGamut);
            photographic.emplace_back(GammaConverter::applyFLog2(p.r),
                GammaConverter::applyFLog2(p.g), GammaConverter::applyFLog2(p.b));
        }
        writeCube(argv[2], size);
        std::shared_ptr<LUT3D> table = LUTParser::loadLUT(argv[2]);
        if (!table || !table->isPhotoLUT() || table->getSize() != size)
            throw std::runtime_error("Native LUT reload failed");
        LUTApplicator lut(table);
        std::cout << std::setprecision(9) << "{\"size\":" << size << ",\"max_error_gate\":0.02}\n";
        const double maximum = std::max({measure("domain", domain, lut), measure("gray", gray, lut),
                                         measure("scene", photographic, lut)});
        std::cout << (maximum <= .02 ? "PASS" : "FAIL") << ": native neutral bake maximum=" << maximum << '\n';
        return maximum <= .02 ? 0 : 2;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
