#include "sony2fuji/ffi/sony2fuji_c.h"
#include "sony2fuji/lut_applicator.h"
#include "sony2fuji/color_recipe.h"
#include "sony2fuji/color_converter.h"
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <string>

namespace {
int failures = 0;
void check(bool value, const std::string& name) {
    std::cout << (value ? "PASS " : "FAIL ") << name << '\n';
    if (!value) ++failures;
}
std::array<float, 40> identity() {
    std::array<float, 40> p{};
    for (int i = 0; i < 9; ++i) p[i] = i / 8.f;
    p[9] = 1;
    for (int i = 0; i < 8; ++i) p[11 + i * 3] = 1;
    return p;
}
float difference(const sony2fuji::RGB& a, const sony2fuji::RGB& b) {
    return std::max({std::abs(a.r - b.r), std::abs(a.g - b.g), std::abs(a.b - b.b)});
}
double oklabA(const sony2fuji::RGB& rgb) {
    const double r = sony2fuji::GammaConverter::removeSRGBGamma(rgb.r);
    const double g = sony2fuji::GammaConverter::removeSRGBGamma(rgb.g);
    const double b = sony2fuji::GammaConverter::removeSRGBGamma(rgb.b);
    return 1.9779984951*std::cbrt(.4122214708*r+.5363325363*g+.0514459929*b)
         - 2.4285922050*std::cbrt(.2119034982*r+.6806995451*g+.1073969566*b)
         + .4505937099*std::cbrt(.0883024619*r+.2817188376*g+.6299787005*b);
}
std::string read(const std::filesystem::path& path) {
    std::ifstream file(path);
    return std::string(std::istreambuf_iterator<char>(file), {});
}
}

int main() {
    const auto dir = std::filesystem::temp_directory_path() /
        ("rawlab-recipe-tests-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    std::filesystem::create_directory(dir);
    auto parameters = identity();
    const auto path = (dir / "identity.cube").u8string();
    sony2fuji_color_look_report report{};
    const auto status = sony2fuji_compile_color_look(1, parameters.data(), parameters.size(), path.c_str(), &report);
    check(status == SONY2FUJI_STATUS_OK, "Compile default recipe to display CUBE");
    check(report.grid_size == 65 && report.max_error < 0.00002f, "Default recipe preserves display colors");
    std::array<float, 44> adapted{};
    std::copy(parameters.begin(), parameters.end(), adapted.begin());
    std::copy_n(std::array<float, 4>{.2f, .6f, .4f, .8f}.begin(), 4, adapted.begin()+40);
    auto acceptsRegions = [&](const std::array<float, 44>& values) {
        try { sony2fuji::ColorRecipe::fromParameters(2, values.data(), values.size()); return true; }
        catch (const std::invalid_argument&) { return false; }
    };
    check(acceptsRegions(adapted), "Version 2 accepts separate tone regions");
    if (acceptsRegions(adapted)) {
        adapted[9] = .9f; adapted[34] = -.002f; adapted[37] = .002f; adapted[39] = .003f;
        const auto fixed = sony2fuji::ColorRecipe::fromParameters(1, adapted.data(), 40);
        const auto standard = sony2fuji::ColorRecipe::fromParameters(2, adapted.data(), 44);
        adapted[40] = .1f; adapted[41] = .45f; adapted[42] = .55f; adapted[43] = .95f;
        const auto manual = sony2fuji::ColorRecipe::fromParameters(2, adapted.data(), 44);
        bool same = true, bounded = true; float effect = 0;
        for (int i = 0; i <= 1000; ++i) {
            const sony2fuji::RGB gray(i/1000.f, i/1000.f, i/1000.f);
            same = same && difference(fixed.apply(gray), standard.apply(gray)) < .000002f;
            auto pixel = manual.apply(gray);
            effect = std::max(effect, difference(fixed.apply(gray), pixel));
            bounded = bounded && std::isfinite(pixel.r) && std::isfinite(pixel.g) && std::isfinite(pixel.b) &&
                pixel.r >= 0 && pixel.r <= 1 && pixel.g >= 0 && pixel.g <= 1 && pixel.b >= 0 && pixel.b <= 1;
        }
        check(same && effect > .001f && bounded, "Default regions agree; manual regions change bounded toning");
        const auto adaptedPath = (dir / "adapted.cube").u8string();
        check(sony2fuji_compile_color_look(2, adapted.data(), 44, adaptedPath.c_str(), &report) == SONY2FUJI_STATUS_OK &&
              report.max_error <= .02f, "Adapted toning passes the unchanged bake gate");
        for (auto bounds : {std::array<float,4>{0,.05f,.95f,1}, std::array<float,4>{0,1,0,1},
                            std::array<float,4>{.2f,.7f,.3f,.8f}}) {
            std::copy(parameters.begin(), parameters.end(), adapted.begin());
            std::copy(bounds.begin(), bounds.end(), adapted.begin()+40);
            const auto neutral = sony2fuji::ColorRecipe::fromParameters(2, adapted.data(), 44);
            bool identityPreserved = true;
            for (int i = 0; i <= 1000; ++i) {
                const sony2fuji::RGB pixel(i/1000.f, .4f, .8f);
                identityPreserved = identityPreserved && difference(neutral.apply(pixel), pixel) < .00002f;
            }
            check(identityPreserved, "Regions cannot change a zero-toning style");
            std::array<sony2fuji::ColorRecipe,3> basis;
            for (int band = 0; band < 3; ++band) {
                auto tinted = adapted; tinted[34+band*2] = .001f;
                basis[band] = sony2fuji::ColorRecipe::fromParameters(2, tinted.data(), 44);
            }
            bool normalized = true;
            // 从实际 RGB 变换反推三个基底权重，覆盖重叠、平台及最窄过渡。
            for (int i = 10; i <= 990; ++i) {
                const double l = i/1000.0;
                const float encoded = sony2fuji::GammaConverter::applySRGBGamma(float(l*l*l));
                const sony2fuji::RGB gray(encoded,encoded,encoded);
                const double base = oklabA(neutral.apply(gray));
                double sum = 0;
                for (auto& transform : basis) {
                    const double weight = (oklabA(transform.apply(gray))-base)/(.001*4*l*(1-l));
                    normalized = normalized && weight >= -.01 && weight <= 1.01;
                    sum += weight;
                }
                normalized = normalized && std::abs(sum-1) < .01;
            }
            check(normalized, "Actual toning has nonnegative normalized weights across dense lightness samples");
        }
    }
    for (auto bounds : {std::array<float,4>{NAN,.6f,.4f,.8f}, std::array<float,4>{-.1f,.6f,.4f,.8f},
                        std::array<float,4>{.2f,.21f,.4f,.8f}, std::array<float,4>{.6f,.2f,.4f,.8f},
                        std::array<float,4>{.5f,.6f,.4f,.8f}, std::array<float,4>{.2f,.9f,.4f,.8f},
                        std::array<float,4>{.2f,.6f,.8f,.82f}, std::array<float,4>{.2f,.6f,.4f,1.1f}}) {
        std::copy(bounds.begin(), bounds.end(), adapted.begin()+40);
        check(!acceptsRegions(adapted), "Reject invalid region boundaries");
    }
    check(sony2fuji_validate_look(path.c_str(), nullptr, nullptr) == SONY2FUJI_STATUS_OK, "Generated CUBE is a valid PHOTO look");
    auto table = sony2fuji::LUTParser::loadLUTCached(path);
    if (table) {
        sony2fuji::LUTApplicator apply(table);
        bool same = true;
        for (auto color : {sony2fuji::RGB(0,0,0), sony2fuji::RGB(1,1,1), sony2fuji::RGB(.2f,.5f,.8f),
                           sony2fuji::RGB(1,0,0), sony2fuji::RGB(0,1,0), sony2fuji::RGB(0,0,1)})
            same = same && difference(color, apply.apply(color)) < 0.00002f;
        check(same, "Identity numerical anchors and R-fast order");
    } else check(false, "Load identity for color anchors");
    const auto before = read(path);
    const auto repeated = (dir / "repeated.cube").u8string();
    check(sony2fuji_compile_color_look(1, parameters.data(), 40, repeated.c_str(), &report) == SONY2FUJI_STATUS_OK &&
          read(repeated) == before, "Same recipe produces identical CUBE bytes at a different destination");
    check(sony2fuji_compile_color_look(1, parameters.data(), 40, path.c_str(), &report) == SONY2FUJI_STATUS_INVALID_ARGUMENT &&
          read(path) == before, "Compile never overwrites an existing look");

    auto reject = [&](std::array<float, 40> values, const std::string& label) {
        const auto invalid = (dir / "invalid.cube").u8string();
        check(sony2fuji_compile_color_look(1, values.data(), 40, invalid.c_str(), &report) == SONY2FUJI_STATUS_INVALID_ARGUMENT &&
              !std::filesystem::exists(invalid), label);
    };
    auto invalid = identity(); invalid[4] = .1f; reject(invalid, "Reject nonmonotonic tone");
    invalid = identity(); invalid[9] = 2.01f; reject(invalid, "Reject excessive chroma");
    invalid = identity(); invalid[10] = 30.01f; reject(invalid, "Reject excessive hue rotation");
    invalid = identity(); invalid[12] = -.09f; reject(invalid, "Reject excessive band lightness");
    invalid = identity(); invalid[34] = .04f; reject(invalid, "Reject excessive toning");
    invalid = identity(); invalid[9] = std::numeric_limits<float>::quiet_NaN(); reject(invalid, "Reject nonfinite recipe");
    const auto unknown = (dir / "unknown.cube").u8string();
    check(sony2fuji_compile_color_look(2, parameters.data(), 40, unknown.c_str(), &report) == SONY2FUJI_STATUS_INVALID_ARGUMENT &&
          sony2fuji_compile_color_look(1, parameters.data(), 39, unknown.c_str(), &report) == SONY2FUJI_STATUS_INVALID_ARGUMENT &&
          sony2fuji_compile_color_look(1, nullptr, 40, unknown.c_str(), &report) == SONY2FUJI_STATUS_INVALID_ARGUMENT &&
          !std::filesystem::exists(unknown), "Reject unknown version, wrong shape and null parameters");

    auto mono = identity(); mono[9] = 0;
    const auto monoPath = (dir / "mono.cube").u8string();
    check(sony2fuji_compile_color_look(1, mono.data(), 40, monoPath.c_str(), &report) == SONY2FUJI_STATUS_OK &&
          report.max_error <= .02f, "Monochrome recipe passes the real error gate");
    auto monoTable = sony2fuji::LUTParser::loadLUTCached(monoPath);
    if (monoTable) {
        auto value = sony2fuji::LUTApplicator(monoTable).apply(sony2fuji::RGB(.8f,.3f,.1f));
        check(std::abs(value.r-value.g) < .00002f && std::abs(value.b-value.g) < .00002f,
              "Chroma zero removes color without resetting tone");
    }
    auto creative = identity(); creative[9] = 1.1f; creative[10 + 3 * 5] = -10;
    creative[12 + 3 * 3] = -.015f; creative[34] = -.006f; creative[39] = .007f;
    const auto sharpPath = (dir / "sharp-gamut.cube").u8string();
    const auto sharpStatus = sony2fuji_compile_color_look(1, creative.data(), 40, sharpPath.c_str(), &report);
    check(sharpStatus == SONY2FUJI_STATUS_PROCESSING_ERROR && report.grid_size == 129 && report.max_error > .02f &&
          !std::filesystem::exists(sharpPath), "Valid but sharp gamut recipe fails both grids without installing a look");
    creative = identity(); creative[9] = .9f; creative[10 + 3 * 5] = -5;
    creative[12 + 3 * 3] = -.005f; creative[34] = -.002f; creative[39] = .003f;
    const auto creativePath = (dir / "creative.cube").u8string();
    const auto creativeStatus = sony2fuji_compile_color_look(1, creative.data(), 40, creativePath.c_str(), &report);
    std::cout << "Creative bake status=" << creativeStatus << " grid=" << report.grid_size
              << " max=" << report.max_error << " mean=" << report.mean_error << " p99=" << report.p99_error << '\n';
    check(creativeStatus == SONY2FUJI_STATUS_OK &&
          report.max_error <= .02f && (report.grid_size == 65 || report.grid_size == 129),
          "Representative color recipe compiles below strict error gate");

    if (std::filesystem::exists(path)) {
        { std::ofstream append(path, std::ios::app); append << "#Private: secret-key /private/photo.jpg user instruction\n"; }
        const auto exported = (dir / "export.cube").u8string();
        check(sony2fuji_export_color_look(path.c_str(), exported.c_str()) == SONY2FUJI_STATUS_OK, "Export a self-contained display look");
        const auto text = read(exported);
        check(text.find("secret-key") == std::string::npos && text.find("/private/") == std::string::npos &&
              text.find("instruction") == std::string::npos && text.find("#Gamma:sRGB to sRGB") != std::string::npos,
              "Export strips private metadata and preserves the explicit contract");
        auto result = sony2fuji::LUTParser::loadLUTCached(exported);
        bool identical = result && table && result->getSize() == table->getSize() &&
            difference(result->domainMin(), table->domainMin()) == 0 && difference(result->domainMax(), table->domainMax()) == 0;
        for (int b = 0; identical && b < table->getSize(); ++b)
            for (int g = 0; identical && g < table->getSize(); ++g)
                for (int r = 0; identical && r < table->getSize(); ++r)
                    identical = difference(table->getValue(r,g,b), result->getValue(r,g,b)) == 0;
        check(identical, "Export preserves every stored table value without resampling");
        check(sony2fuji_export_color_look(path.c_str(), path.c_str()) == SONY2FUJI_STATUS_INVALID_ARGUMENT &&
              sony2fuji_export_color_look(path.c_str(), exported.c_str()) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
              "Export does not replace source or existing destination");
    }
    const auto domainSource = (dir / "domain-source.cube").u8string(), domainExport = (dir / "domain-export.cube").u8string();
    {
        std::ofstream file(domainSource);
        file << "#Gamma:sRGB to sRGB\n#Gamut:ITU-R BT.709 to ITU-R BT.709\nLUT_3D_SIZE 2\n"
             << "DOMAIN_MIN 0.125 0.25 0.375\nDOMAIN_MAX 0.875 0.75 0.625\n";
        for (int i = 0; i < 8; ++i) file << (i&1) << ' ' << ((i>>1)&1) << ' ' << ((i>>2)&1) << '\n';
    }
    check(sony2fuji_export_color_look(domainSource.c_str(), domainExport.c_str()) == SONY2FUJI_STATUS_OK,
          "Export accepts a valid non-unit display domain");
    const auto domainLut = sony2fuji::LUTParser::loadLUT(domainExport);
    check(domainLut && difference(domainLut->domainMin(), sony2fuji::RGB(.125f,.25f,.375f)) == 0 &&
          difference(domainLut->domainMax(), sony2fuji::RGB(.875f,.75f,.625f)) == 0,
          "Export preserves non-unit domain values");
    std::filesystem::remove_all(dir);
    return failures ? 1 : 0;
}
