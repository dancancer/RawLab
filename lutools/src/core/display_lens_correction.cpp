#include "display_lens_correction.h"
#include "processing_cancellation.h"
#include <algorithm>
#include <cmath>
#include <utility>

namespace sony2fuji {
namespace {

std::pair<float, float> orientedPoint(float x, float y, int width, int height, int orientation) {
    switch (orientation) {
    case 2: return {width - 1.f - x, y};
    case 3: return {width - 1.f - x, height - 1.f - y};
    case 4: return {x, height - 1.f - y};
    case 5: return {y, x};
    case 6: return {height - 1.f - y, x};
    case 7: return {height - 1.f - y, width - 1.f - x};
    case 8: return {y, width - 1.f - x};
    default: return {x, y};
    }
}

float sample(const ImageData& image, int channel, float x, float y) {
    if (!std::isfinite(x) || !std::isfinite(y) || x < -1e-4f || y < -1e-4f ||
        x > image.width - 1 + 1e-4f || y > image.height - 1 + 1e-4f) return 0;
    x = std::clamp(x, 0.f, float(image.width - 1));
    y = std::clamp(y, 0.f, float(image.height - 1));
    const int x0 = int(std::floor(x)), y0 = int(std::floor(y));
    const int x1 = std::min(x0 + 1, image.width - 1), y1 = std::min(y0 + 1, image.height - 1);
    const auto at = [&](int col, int row) {
        const auto& pixel = image.at(col, row);
        return channel == 0 ? pixel.r : channel == 1 ? pixel.g : pixel.b;
    };
    const float dx = x - x0, dy = y - y0;
    return ((1 - dx) * at(x0, y0) + dx * at(x1, y0)) * (1 - dy) +
        ((1 - dx) * at(x0, y1) + dx * at(x1, y1)) * dy;
}
}

LensCorrectionReport applyDisplayLensCorrection(ImageData& image,
    std::shared_ptr<const LensCorrectionDatabase> database, const LensMetadata& metadata,
    const LensCorrectionOptions& options, int sourceOrientation) {
    const int width = sourceOrientation >= 5 ? image.height : image.width;
    const int height = sourceOrientation >= 5 ? image.width : image.height;
    LensCorrectionTransform transform(std::move(database), metadata, options, width, height, 3);
    if (!transform.active()) return transform.report();
    checkProcessingCancellation();
    std::vector<RGB> output(image.pixels.size());
    std::vector<float> coordinates(static_cast<size_t>(width) * 6);
    for (int y = 0; y < height; ++y) {
        checkProcessingCancellation();
        transform.map(0, y, width, 1, coordinates.data());
        for (int x = 0; x < width; ++x) {
            const auto destination = orientedPoint(float(x), float(y), width, height, sourceOrientation);
            float channels[3];
            for (int channel = 0; channel < 3; ++channel) {
                const size_t offset = static_cast<size_t>(x) * 6 + channel * 2;
                const auto source = orientedPoint(coordinates[offset], coordinates[offset + 1], width, height, sourceOrientation);
                channels[channel] = sample(image, channel, source.first, source.second) *
                    transform.gainAt(coordinates[offset], coordinates[offset + 1]);
            }
            output[static_cast<size_t>(destination.second) * image.width + static_cast<size_t>(destination.first)] =
                RGB(channels[0], channels[1], channels[2]);
        }
    }
    image.pixels.swap(output);
    return transform.report();
}

}
