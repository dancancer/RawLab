#include "core/photo_geometry.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <iomanip>
#include <iostream>
#include <stdexcept>

using namespace sony2fuji;

namespace {

struct Case {
    const char* name;
    GeometryOptions options;
};

std::array<Case, 6> cases() {
    std::array<Case, 6> result{{{"crop", {}}, {"turn90", {}}, {"flip", {}},
        {"crop+turn90", {}}, {"straighten3", {}}, {"perspective-h0.2+straighten3", {}}}};
    for (int index : {0, 3}) {
        auto& options = result[index].options;
        options.crop_x = .1f; options.crop_y = .1f;
        options.crop_width = .8f; options.crop_height = .8f;
    }
    result[1].options.quarter_turns = result[3].options.quarter_turns = 1;
    result[2].options.flip_horizontal = true;
    result[4].options.straighten_degrees = result[5].options.straighten_degrees = 3;
    result[5].options.perspective_horizontal = .2f;
    return result;
}

ImageData gradient(int width, int height) {
    ImageData image(width, height);
    for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x)
        image.at(x, y) = RGB(float(x) / width, float(y) / height, float(x + y) / (width + height));
    return image;
}

void measure(const ImageData& source, const Case& entry) {
    std::array<double, 5> samples{};
    double checksum = 0;
    for (int run = -1; run < 5; ++run) {
        auto image = source;
        const auto start = std::chrono::steady_clock::now();
        const auto status = applyGeometry(image, entry.options);
        const auto stop = std::chrono::steady_clock::now();
        if (status != ErrorCode::Success) throw std::runtime_error("applyGeometry failed");
        if (run >= 0) samples[run] = std::chrono::duration<double, std::milli>(stop - start).count();
        checksum += image.pixels.front().r + image.pixels.back().b;
    }
    std::sort(samples.begin(), samples.end());
    std::cout << source.width << 'x' << source.height << ',' << entry.name << ','
              << samples[2] << ',' << samples.front() << ',' << samples.back() << ',' << checksum << std::endl;
}

} // namespace

int main() {
    try {
        std::cout << "Single thread; 1 warm-up + 5 timed runs; input copy outside timer\n"
                  << "size,case,median_ms,min_ms,max_ms,checksum\n" << std::fixed << std::setprecision(3);
        for (auto size : {std::pair<int, int>{1600, 1067}, {7008, 4672}}) {
            const auto source = gradient(size.first, size.second);
            for (const auto& entry : cases()) measure(source, entry);
        }
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
