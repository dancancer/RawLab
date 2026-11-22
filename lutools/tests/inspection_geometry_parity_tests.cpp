#include "test_harness.h"
#include "core/photo_geometry.h"

#include <algorithm>
#include <cmath>
#include <iostream>
#include <optional>
#include <utility>
#include <vector>

using namespace sony2fuji;

namespace {

using rawlab::test::require;

struct CanvasSpec {
    int rotatedWidth = 1;
    int rotatedHeight = 1;
    int width = 1;
    int height = 1;
    int left = 0;
    int top = 0;
    int right = 1;
    int bottom = 1;
    double cosine = 1.0;
    double sine = 0.0;

    int outputWidth() const { return right - left; }
    int outputHeight() const { return bottom - top; }
};

CanvasSpec canvasFor(int w, int h, const GeometryOptions& opt) {
    const int safeW = std::max(1, w);
    const int safeH = std::max(1, h);
    const int turns = ((opt.quarter_turns % 4) + 4) % 4;
    const int rotW = (turns % 2 != 0) ? safeH : safeW;
    const int rotH = (turns % 2 != 0) ? safeW : safeH;
    const double rad = double(opt.straighten_degrees) * 3.14159265358979323846 / 180.0;
    const double c = std::cos(rad);
    const double s = std::sin(rad);
    const double absS = std::abs(s);
    const double perspScale = 1.0 / (1.0 + 0.25 * std::abs(double(opt.perspective_horizontal)) + 0.25 * std::abs(double(opt.perspective_vertical)));
    const double pw = double(std::max(1, int(std::floor(double(rotW) * perspScale))));
    const double ph = double(std::max(1, int(std::floor(double(rotH) * perspScale))));
    const double scale = std::min(pw / (pw * c + ph * absS), ph / (pw * absS + ph * c));
    const int cw = std::max(1, int(std::floor(pw * scale)));
    const int ch = std::max(1, int(std::floor(ph * scale)));
    const int left = std::max(0, std::min(cw - 1, int(std::floor(double(opt.crop_x) * cw))));
    const int top = std::max(0, std::min(ch - 1, int(std::floor(double(opt.crop_y) * ch))));
    const int right = std::min(cw, std::max(left + 1, int(std::ceil(std::min(1.0, double(opt.crop_x) + double(opt.crop_width)) * cw))));
    const int bottom = std::min(ch, std::max(top + 1, int(std::ceil(std::min(1.0, double(opt.crop_y) + double(opt.crop_height)) * ch))));
    return { rotW, rotH, cw, ch, left, top, right, bottom, c, s };
}

std::optional<std::pair<double, double>> outputNormToSourceNorm(
    double outX, double outY, int w, int h, const GeometryOptions& opt)
{
    const CanvasSpec cv = canvasFor(w, h, opt);
    const double x = outX * double(cv.outputWidth()) - 0.5;
    const double y = outY * double(cv.outputHeight()) - 0.5;
    const double dy = double(cv.top) + y - double(cv.height - 1) * 0.5;
    const double dx = double(cv.left) + x - double(cv.width - 1) * 0.5;
    const double rx = cv.cosine * dx + cv.sine * dy;
    const double ry = -cv.sine * dx + cv.cosine * dy;
    const double denom = 1.0
        + 0.25 * double(opt.perspective_horizontal) * (2.0 * rx / double(cv.rotatedWidth))
        + 0.25 * double(opt.perspective_vertical) * (2.0 * ry / double(cv.rotatedHeight));
    if (std::abs(denom) <= 1e-6) return std::nullopt;
    double px = double(cv.rotatedWidth - 1) * 0.5 + rx / denom;
    double py = double(cv.rotatedHeight - 1) * 0.5 + ry / denom;
    if (opt.flip_horizontal) px = double(cv.rotatedWidth - 1) - px;
    if (opt.flip_vertical) py = double(cv.rotatedHeight - 1) - py;
    const int turns = ((opt.quarter_turns % 4) + 4) % 4;
    double sx = px, sy = py;
    if (turns == 1) { sx = py; sy = double(h - 1) - px; }
    else if (turns == 2) { sx = double(w - 1) - px; sy = double(h - 1) - py; }
    else if (turns == 3) { sx = double(w - 1) - py; sy = px; }
    return std::make_pair((sx + 0.5) / double(w), (sy + 0.5) / double(h));
}

std::optional<std::pair<double, double>> sourceNormToOutputNorm(
    double srcX, double srcY, int w, int h, const GeometryOptions& opt)
{
    const CanvasSpec cv = canvasFor(w, h, opt);
    const double sx = srcX * double(w) - 0.5;
    const double sy = srcY * double(h) - 0.5;
    const int turns = ((opt.quarter_turns % 4) + 4) % 4;
    double px = sx, py = sy;
    if (turns == 1) { px = double(h - 1) - sy; py = sx; }
    else if (turns == 2) { px = double(w - 1) - sx; py = double(h - 1) - sy; }
    else if (turns == 3) { px = sy; py = double(w - 1) - sx; }
    if (opt.flip_horizontal) px = double(cv.rotatedWidth - 1) - px;
    if (opt.flip_vertical) py = double(cv.rotatedHeight - 1) - py;

    const double u = px - double(cv.rotatedWidth - 1) * 0.5;
    const double v = py - double(cv.rotatedHeight - 1) * 0.5;
    const double a = 0.25 * double(opt.perspective_horizontal) * (2.0 / double(cv.rotatedWidth));
    const double b = 0.25 * double(opt.perspective_vertical) * (2.0 / double(cv.rotatedHeight));
    const double k = 1.0 - a * u - b * v;
    if (std::abs(k) <= 1e-6) return std::nullopt;
    const double rx = u / k;
    const double ry = v / k;
    const double dx = cv.cosine * rx - cv.sine * ry;
    const double dy = cv.sine * rx + cv.cosine * ry;
    const double x = dx + double(cv.width - 1) * 0.5 - double(cv.left);
    const double y = dy + double(cv.height - 1) * 0.5 - double(cv.top);
    const double outW = double(cv.outputWidth());
    const double outH = double(cv.outputHeight());
    const double uOut = (x + 0.5) / outW;
    const double vOut = (y + 0.5) / outH;
    if (uOut < 0.0 || uOut > 1.0 || vOut < 0.0 || vOut > 1.0) return std::nullopt;
    return std::make_pair(uOut, vOut);
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
        const auto [outW, outH] = geometryOutputSize(srcW, srcH, opt);
        const CanvasSpec cv = canvasFor(srcW, srcH, opt);
        require(outW == cv.outputWidth() && outH == cv.outputHeight(),
            "geometryOutputSize matches GeometryCoordinateMapper::canvasFor");

        const auto sampler = makeGeometrySampler(srcW, srcH, opt);
        for (const auto& pt : std::vector<std::pair<double, double>>{{0.5, 0.5}, {0.35, 0.6}, {0.68, 0.42}}) {
            const int ox = std::clamp(int(std::floor(pt.first * outW)), 0, outW - 1);
            const int oy = std::clamp(int(std::floor(pt.second * outH)), 0, outH - 1);
            const double exactOutX = (double(ox) + 0.5) / double(outW);
            const double exactOutY = (double(oy) + 0.5) / double(outH);

            const RGB sampled = sampler(ox, oy, reader);
            const auto mapped = outputNormToSourceNorm(exactOutX, exactOutY, srcW, srcH, opt);
            require(mapped.has_value(), "outputNormToSourceNorm succeeds on interior pixel");
            require(std::abs(double(sampled.r) - mapped->first) < 1e-3,
                "X coordinate matches photo_geometry::makeGeometrySampler");
            require(std::abs(double(sampled.g) - mapped->second) < 1e-3,
                "Y coordinate matches photo_geometry::makeGeometrySampler");

            const auto roundTrip = sourceNormToOutputNorm(mapped->first, mapped->second, srcW, srcH, opt);
            require(roundTrip.has_value(), "sourceNormToOutputNorm round-trips");
            require(std::abs(roundTrip->first - exactOutX) < 1e-5 &&
                    std::abs(roundTrip->second - exactOutY) < 1e-5,
                "forward/inverse round-trip closes");
        }
    }

    GeometryOptions cropped{};
    cropped.crop_x = 0.25f;
    cropped.crop_y = 0.25f;
    cropped.crop_width = 0.5f;
    cropped.crop_height = 0.5f;
    require(!sourceNormToOutputNorm(0.1, 0.1, srcW, srcH, cropped).has_value(),
        "source anchor outside crop yields nullopt");
    require(sourceNormToOutputNorm(0.5, 0.5, srcW, srcH, cropped).has_value(),
        "source anchor inside crop remains valid");

    std::cout << "PASS: inspection_geometry_parity_tests (" << cases.size() << " transforms)\n";
    return 0;
}
