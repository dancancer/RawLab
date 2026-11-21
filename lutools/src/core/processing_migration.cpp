#include "processing_migration.h"
#include "processing_cancellation.h"
#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>

namespace sony2fuji {
namespace {
constexpr MigrationParameters lower{-5, 0, -1, -1, 0, -1, -1, -1, -1, -1};
constexpr MigrationParameters upper{5, 2, 1, 1, 2, 1, 1, 1, 1, 1};

RGB displayPixel(const RGB& p) {
    if (!std::isfinite(p.r) || !std::isfinite(p.g) || !std::isfinite(p.b))
        throw std::runtime_error("Nonfinite migration render");
    return RGB(std::clamp(p.r, 0.f, 1.f), std::clamp(p.g, 0.f, 1.f), std::clamp(p.b, 0.f, 1.f));
}

double squaredError(const RGB& a, const RGB& b) {
    const double r = a.r - b.r, g = a.g - b.g, blue = a.b - b.b;
    return (r * r + g * g + blue * blue) / 3;
}

void requireSameFrame(const MigrationFrame& a, const MigrationFrame& b) {
    if (a.width != b.width || a.height != b.height || a.sourceWidth != b.sourceWidth ||
        a.sourceHeight != b.sourceHeight || a.overview.empty() || a.overview.size() != b.overview.size() ||
        a.detail.size() != a.overview.size() * 3 || a.detail.size() != b.detail.size())
        throw std::runtime_error("Migration render dimensions changed");
}

double fittingError(const MigrationFrame& a, const MigrationFrame& b) {
    requireSameFrame(a, b);
    double sum = 0;
    for (size_t i = 0; i < a.overview.size(); ++i) sum += squaredError(a.overview[i], b.overview[i]);
    return sum / a.overview.size();
}
template <typename Channel>
MigrationQuality fullResolutionQuality(const MigrationFrame& reference, const Channel& candidateChannel) {
    const size_t count = size_t(reference.sourceWidth) * reference.sourceHeight;
    if (reference.nativePixels.size() != count * 3)
        throw std::runtime_error("Missing native migration pixels");
    const auto& a = reference.nativePixels;
    constexpr double scale = 1. / 65535;
    const int columns = (reference.sourceWidth + 63) / 64;
    const int rows = (reference.sourceHeight + 63) / 64;
    std::vector<double> tiles(size_t(columns) * rows);
    std::vector<size_t> tileCounts(tiles.size());
    std::vector<size_t> histogram(65536);
    double sum = 0, detail = 0;
    size_t gradients = 0;
    for (int y = 0; y < reference.sourceHeight; ++y) {
        checkProcessingCancellation();
        for (int x = 0; x < reference.sourceWidth; ++x) {
            const size_t pixel = size_t(y) * reference.sourceWidth + x;
            const size_t tile = size_t(y / 64) * columns + x / 64;
            double squared = 0;
            int maximum = 0;
            for (size_t channel = 0; channel < 3; ++channel) {
                const size_t i = pixel * 3 + channel;
                const int difference = int(a[i]) - candidateChannel(i);
                squared += double(difference) * difference * scale * scale / 3;
                maximum = std::max(maximum, std::abs(difference));
                for (size_t neighbor : {x + 1 < reference.sourceWidth ? i + 3 : i,
                     y + 1 < reference.sourceHeight ? i + size_t(reference.sourceWidth) * 3 : i}) {
                    if (neighbor == i) continue;
                    const double delta = (int(a[neighbor]) - candidateChannel(neighbor) - difference) * scale;
                    detail += delta * delta; ++gradients;
                }
            }
            sum += squared; tiles[tile] += squared; ++tileCounts[tile]; ++histogram[maximum];
        }
    }
    double worst = 0;
    for (size_t i = 0; i < tiles.size(); ++i) worst = std::max(worst, tiles[i] / tileCounts[i]);
    const size_t percentile = size_t(std::ceil(count * .99));
    size_t cumulative = 0, p99 = 0;
    for (; p99 < histogram.size() - 1; ++p99) {
        cumulative += histogram[p99];
        if (cumulative >= percentile) break;
    }
    return {float(std::sqrt(sum / count)), float(p99 * scale), float(std::sqrt(worst)),
        float(gradients == 0 ? 0 : std::sqrt(detail / gradients))};
}

}

bool MigrationQuality::accepted() const {
    return std::isfinite(rgbRMSE) && std::isfinite(p99Error) && std::isfinite(worstTileRMSE) &&
        std::isfinite(detailRMSE) && rgbRMSE <= 2.f / 255 && p99Error <= 6.f / 255 &&
        worstTileRMSE <= 4.f / 255 && detailRMSE <= 2.f / 255;
}

bool validMigrationParameters(const MigrationParameters& values) {
    for (size_t i = 0; i < values.size(); ++i)
        if (!std::isfinite(values[i]) || values[i] < lower[i] || values[i] > upper[i]) return false;
    return true;
}

MigrationFrame captureMigrationFrame(const ImageData& image, bool retainNativePixels,
    const MigrationFrame* validationReference) {
    if (image.width <= 0 || image.height <= 0 ||
        image.pixels.size() != size_t(image.width) * image.height)
        throw std::runtime_error("Empty migration render");
    if (validationReference && (validationReference->sourceWidth != image.width || validationReference->sourceHeight != image.height))
        throw std::runtime_error("Migration render dimensions changed");
    retainNativePixels = retainNativePixels && validationReference == nullptr;
    MigrationFrame result;
    result.sourceWidth = image.width; result.sourceHeight = image.height;
    result.retainNativePixels = retainNativePixels;
    if (retainNativePixels) result.nativePixels.reserve(image.pixels.size() * 3);
    const double scale = std::min(1., 128. / std::max(image.width, image.height));
    result.width = std::max(1, int(std::lround(image.width * scale)));
    result.height = std::max(1, int(std::lround(image.height * scale)));
    const size_t count = size_t(result.width) * result.height;
    std::vector<std::array<double, 3>> sums(count);
    std::vector<uint32_t> counts(count);
    for (int y = 0; y < image.height; ++y) {
        checkProcessingCancellation();
        for (int x = 0; x < image.width; ++x) {
            const size_t cell = size_t(int64_t(y) * result.height / image.height) * result.width +
                int64_t(x) * result.width / image.width;
            const auto p = displayPixel(image.at(x, y));
            if (retainNativePixels) {
                result.nativePixels.push_back(uint16_t(std::lround(p.r * 65535)));
                result.nativePixels.push_back(uint16_t(std::lround(p.g * 65535)));
                result.nativePixels.push_back(uint16_t(std::lround(p.b * 65535)));
            }
            sums[cell][0] += p.r; sums[cell][1] += p.g; sums[cell][2] += p.b; ++counts[cell];
        }
    }
    result.overview.reserve(count); result.detail.reserve(count * 3);
    for (int y = 0; y < result.height; ++y) for (int x = 0; x < result.width; ++x) {
        const size_t i = size_t(y) * result.width + x;
        result.overview.emplace_back(sums[i][0] / counts[i], sums[i][1] / counts[i], sums[i][2] / counts[i]);
        const int sx = std::min(image.width - 1, int((x + .5) * image.width / result.width));
        const int sy = std::min(image.height - 1, int((y + .5) * image.height / result.height));
        result.detail.push_back(displayPixel(image.at(sx, sy)));
        result.detail.push_back(displayPixel(image.at(std::min(sx + 1, image.width - 1), sy)));
        result.detail.push_back(displayPixel(image.at(sx, std::min(sy + 1, image.height - 1))));
    }
    if (validationReference) {
        result.nativeQuality = fullResolutionQuality(*validationReference, [&](size_t index) {
            const auto p = displayPixel(image.pixels[index / 3]);
            const float value = index % 3 == 0 ? p.r : index % 3 == 1 ? p.g : p.b;
            return uint16_t(std::lround(value * 65535));
        });
        result.validationReference = validationReference;
    }
    return result;
}

MigrationQuality migrationQuality(const MigrationFrame& reference, const MigrationFrame& candidate) {
    requireSameFrame(reference, candidate);
    if (candidate.validationReference == &reference) return candidate.nativeQuality;
    if (reference.retainNativePixels || candidate.retainNativePixels) {
        if (candidate.nativePixels.size() != size_t(candidate.sourceWidth) * candidate.sourceHeight * 3)
            throw std::runtime_error("Missing native migration pixels");
        return fullResolutionQuality(reference, [&](size_t index) { return candidate.nativePixels[index]; });
    }
    double sum = 0, detail = 0;
    std::vector<float> errors;
    errors.reserve(reference.overview.size() + reference.detail.size());
    auto addError = [&](const RGB& a, const RGB& b) {
        errors.push_back(std::max({std::abs(a.r - b.r), std::abs(a.g - b.g), std::abs(a.b - b.b)}));
    };
    for (size_t i = 0; i < reference.overview.size(); ++i) {
        sum += squaredError(reference.overview[i], candidate.overview[i]);
        addError(reference.overview[i], candidate.overview[i]);
        for (size_t offset = 0; offset < 3; ++offset)
            addError(reference.detail[3 * i + offset], candidate.detail[3 * i + offset]);
        for (size_t offset = 1; offset < 3; ++offset) {
            const auto a = reference.detail[3 * i], b = reference.detail[3 * i + offset];
            const auto c = candidate.detail[3 * i], d = candidate.detail[3 * i + offset];
            detail += squaredError(RGB(b.r - a.r, b.g - a.g, b.b - a.b), RGB(d.r - c.r, d.g - c.g, d.b - c.b));
        }
    }
    double worst = 0;
    for (int top = 0; top < reference.height; top += 8) for (int left = 0; left < reference.width; left += 8) {
        double tile = 0; int count = 0;
        for (int y = top; y < std::min(top + 8, reference.height); ++y)
            for (int x = left; x < std::min(left + 8, reference.width); ++x) {
                const size_t i = size_t(y) * reference.width + x;
                tile += squaredError(reference.overview[i], candidate.overview[i]); ++count;
            }
        worst = std::max(worst, tile / count);
    }
    const size_t p99 = std::min(errors.size() - 1, size_t(std::ceil(errors.size() * .99)) - 1);
    std::nth_element(errors.begin(), errors.begin() + p99, errors.end());
    return {float(std::sqrt(sum / reference.overview.size())), errors[p99], float(std::sqrt(worst)),
        float(std::sqrt(detail / (reference.overview.size() * 2)))};
}

MigrationParameters fitMigrationParameters(const MigrationParameters& initial, const MigrationFrame& reference,
    const std::function<MigrationFrame(const MigrationParameters&)>& render) {
    if (!validMigrationParameters(initial)) throw std::invalid_argument("Unsupported source migration parameters");
    auto best = initial;
    auto frame = render(best);
    int evaluations = 1;
    double error = fittingError(reference, frame);
    if (migrationQuality(reference, frame).accepted()) return best;
    for (float step : {.3f, .15f, .07f, .03f, .012f, .005f}) {
        for (int pass = 0; pass < 2 && evaluations < 161; ++pass) {
            bool improved = false;
            for (size_t index = 0; index < best.size() && evaluations < 161; ++index) {
                checkProcessingCancellation();
                const auto start = best;
                for (float direction : {-1.f, 1.f}) {
                    if (evaluations >= 161) break;
                    auto values = start;
                    values[index] = std::clamp(values[index] + direction * step * (index == 0 ? 2 : 1), lower[index], upper[index]);
                    if (values[index] == start[index]) continue;
                    auto candidate = render(values); ++evaluations;
                    const double measured = fittingError(reference, candidate);
                    if (measured + 1e-10 < error) {
                        best = values; frame = std::move(candidate); error = measured; improved = true;
                    }
                }
            }
            if (error < 1. / (255 * 255) && migrationQuality(reference, frame).accepted()) return best;
            if (!improved) break;
        }
    }
    return best;
}

} // namespace sony2fuji
