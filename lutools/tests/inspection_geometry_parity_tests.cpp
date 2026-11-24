#include "test_harness.h"
#include "core/photo_geometry.h"
#include "sony2fuji/ffi/sony2fuji_c.h"

#include <algorithm>
#include <cmath>
#include <iostream>
#include <utility>
#include <vector>

using namespace sony2fuji;

namespace {

using rawlab::test::require;

void toCConfigs(
    const GeometryOptions& opt,
    sony2fuji_geometry_config& geom,
    sony2fuji_perspective_config& persp
) {
    geom = {
        SONY2FUJI_GEOMETRY_CONFIG_VERSION,
        sizeof(sony2fuji_geometry_config),
        opt.crop_x,
        opt.crop_y,
        opt.crop_width,
        opt.crop_height,
        opt.quarter_turns,
        opt.flip_horizontal ? 1 : 0,
        opt.flip_vertical ? 1 : 0,
        opt.straighten_degrees,
    };
    persp = {
        SONY2FUJI_PERSPECTIVE_CONFIG_VERSION,
        sizeof(sony2fuji_perspective_config),
        opt.perspective_horizontal,
        opt.perspective_vertical,
    };
}

} // namespace

int main() {
    const int srcW = 240;
    const int srcH = 180;
    const std::vector<GeometryOptions> cases = {
        GeometryOptions{},
        GeometryOptions{0.f, 0.f, 1.f, 1.f, 1, false, false, 0.f, 0.f, 0.f},
        GeometryOptions{0.f, 0.f, 1.f, 1.f, 2, true, false, 0.f, 0.f, 0.f},
        GeometryOptions{0.f, 0.f, 1.f, 1.f, 3, false, true, 0.f, 0.f, 0.f},
        GeometryOptions{0.1f, 0.2f, 0.6f, 0.5f, 1, true, false, 7.5f, 0.35f, -0.25f},
        GeometryOptions{0.15f, 0.1f, 0.7f, 0.75f, 0, false, true, -12.0f, -0.4f, 0.5f},
    };

    auto reader = [&](int x, int y) -> RGB {
        const int cx = std::clamp(x, 0, srcW - 1);
        const int cy = std::clamp(y, 0, srcH - 1);
        return RGB(float(cx + 0.5) / float(srcW), float(cy + 0.5) / float(srcH), 0.5f);
    };

    for (const auto& opt : cases) {
        sony2fuji_geometry_config geom{};
        sony2fuji_perspective_config persp{};
        toCConfigs(opt, geom, persp);

        const auto [outW, outH] = geometryOutputSize(srcW, srcH, opt);
        uint32_t cOutW = 0;
        uint32_t cOutH = 0;
        require(sony2fuji_geometry_output_size(srcW, srcH, &geom, &persp, &cOutW, &cOutH) == SONY2FUJI_STATUS_OK,
            "sony2fuji_geometry_output_size succeeds");
        require(outW == int(cOutW) && outH == int(cOutH),
            "sony2fuji_geometry_output_size matches geometryOutputSize");

        const auto [inferredCoreW, inferredCoreH] = geometryInferSourceSize(outW, outH, opt);
        uint32_t cInfW = 0;
        uint32_t cInfH = 0;
        require(sony2fuji_geometry_infer_source_size(cOutW, cOutH, &geom, &persp, &cInfW, &cInfH) == SONY2FUJI_STATUS_OK,
            "sony2fuji_geometry_infer_source_size succeeds");
        require(inferredCoreW == int(cInfW) && inferredCoreH == int(cInfH),
            "C ABI infer_source_size matches core geometryInferSourceSize");
        require(std::abs(inferredCoreW - srcW) <= 3 && std::abs(inferredCoreH - srcH) <= 3,
            "geometryInferSourceSize approximates original source dimensions");

        const auto sampler = makeGeometrySampler(srcW, srcH, opt);
        for (const auto& pt : std::vector<std::pair<double, double>>{{0.5, 0.5}, {0.35, 0.6}, {0.68, 0.42}}) {
            const int ox = std::clamp(int(std::floor(pt.first * outW)), 0, outW - 1);
            const int oy = std::clamp(int(std::floor(pt.second * outH)), 0, outH - 1);
            const double exactOutX = (double(ox) + 0.5) / double(outW);
            const double exactOutY = (double(oy) + 0.5) / double(outH);

            const RGB sampled = sampler(ox, oy, reader);
            double coreSrcX = 0.0;
            double coreSrcY = 0.0;
            require(geometryOutputNormToSourceNorm(srcW, srcH, opt, exactOutX, exactOutY, coreSrcX, coreSrcY),
                "geometryOutputNormToSourceNorm succeeds on interior pixel");

            double cSrcX = 0.0;
            double cSrcY = 0.0;
            int32_t cSrcValid = 0;
            require(sony2fuji_geometry_output_norm_to_source_norm(
                        srcW, srcH, &geom, &persp, exactOutX, exactOutY, &cSrcX, &cSrcY, &cSrcValid) == SONY2FUJI_STATUS_OK &&
                    cSrcValid == 1,
                "sony2fuji_geometry_output_norm_to_source_norm succeeds");
            require(std::abs(cSrcX - coreSrcX) < 1e-12 && std::abs(cSrcY - coreSrcY) < 1e-12,
                "C ABI output_norm_to_source_norm matches core");

            require(std::abs(double(sampled.r) - coreSrcX) < 1e-3,
                "X coordinate matches photo_geometry::makeGeometrySampler");
            require(std::abs(double(sampled.g) - coreSrcY) < 1e-3,
                "Y coordinate matches photo_geometry::makeGeometrySampler");

            double coreBackX = 0.0;
            double coreBackY = 0.0;
            require(geometrySourceNormToOutputNorm(srcW, srcH, opt, coreSrcX, coreSrcY, coreBackX, coreBackY),
                "geometrySourceNormToOutputNorm round-trips");

            double cBackX = 0.0;
            double cBackY = 0.0;
            int32_t cBackValid = 0;
            require(sony2fuji_geometry_source_norm_to_output_norm(
                        srcW, srcH, &geom, &persp, cSrcX, cSrcY, &cBackX, &cBackY, &cBackValid) == SONY2FUJI_STATUS_OK &&
                    cBackValid == 1,
                "sony2fuji_geometry_source_norm_to_output_norm succeeds");
            require(std::abs(coreBackX - exactOutX) < 1e-5 &&
                    std::abs(coreBackY - exactOutY) < 1e-5,
                "forward/inverse round-trip closes");
            require(std::abs(cBackX - coreBackX) < 1e-12 && std::abs(cBackY - coreBackY) < 1e-12,
                "C ABI source_norm_to_output_norm matches core");
        }
    }

    GeometryOptions cropped{};
    cropped.crop_x = 0.25f;
    cropped.crop_y = 0.25f;
    cropped.crop_width = 0.5f;
    cropped.crop_height = 0.5f;
    sony2fuji_geometry_config croppedGeom{};
    sony2fuji_perspective_config croppedPersp{};
    toCConfigs(cropped, croppedGeom, croppedPersp);

    double outX = 0.0;
    double outY = 0.0;
    int32_t valid = 1;
    require(!geometrySourceNormToOutputNorm(srcW, srcH, cropped, 0.1, 0.1, outX, outY),
        "source anchor outside crop yields false");
    require(sony2fuji_geometry_source_norm_to_output_norm(
                srcW, srcH, &croppedGeom, &croppedPersp, 0.1, 0.1, &outX, &outY, &valid) == SONY2FUJI_STATUS_OK &&
            valid == 0,
        "C ABI source anchor outside crop returns OK with valid=0");
    require(geometrySourceNormToOutputNorm(srcW, srcH, cropped, 0.5, 0.5, outX, outY),
        "source anchor inside crop remains valid");

    // Validation errors on C ABI
    uint32_t w = 0, h = 0;
    sony2fuji_geometry_config badGeom = croppedGeom;
    badGeom.version = 99;
    require(sony2fuji_geometry_output_size(srcW, srcH, &badGeom, &croppedPersp, &w, &h) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "invalid geometry version returns INVALID_ARGUMENT");
    require(sony2fuji_geometry_output_norm_to_source_norm(
                srcW, srcH, nullptr, nullptr, std::numeric_limits<double>::quiet_NaN(), 0.5, &outX, &outY, &valid) ==
            SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "NaN coordinate returns INVALID_ARGUMENT");

    std::cout << "PASS: inspection_geometry_parity_tests (" << cases.size() << " transforms)\n";
    return 0;
}
