#include "sony2fuji/sony2fuji.h"
#include "core/photo_rendering.h"
#include <libraw/libraw.h>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <memory>
#include <string>
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_JPEG
#define STBI_NO_STDIO
#include "core/stb_image.h"

using namespace sony2fuji;

int main(int argc, char** argv) {
    bool defaultRaw = false;
    if (argc >= 2 && std::string(argv[1]) == "--default-raw") {
        defaultRaw = true;
        --argc;
        ++argv;
    }
    if (argc != 3) return 2;
    const char* rawPath = argv[1];
    if (defaultRaw) {
        if (!rawPath || !*rawPath || !std::filesystem::is_regular_file(std::filesystem::u8path(rawPath))) {
            std::cout << "SKIP sony_highlights: default RAW sample not present (" << (rawPath ? rawPath : "") << ")\n";
            return 77;
        }
    } else {
        if (!rawPath || !*rawPath) {
            std::cout << "SKIP sony_highlights: RAW sample not configured\n";
            return 77;
        }
        if (!std::filesystem::is_regular_file(std::filesystem::u8path(rawPath))) {
            std::cerr << "FAIL sony_highlights: RAW sample does not exist: " << rawPath << '\n';
            return 1;
        }
    }
    auto metadata = std::make_unique<LibRaw>();
    if (metadata->open_file(rawPath) || metadata->unpack_thumb()) return 1;
    std::unique_ptr<libraw_processed_image_t, decltype(&LibRaw::dcraw_clear_mem)> thumb(
        metadata->dcraw_make_mem_thumb(), LibRaw::dcraw_clear_mem);
    if (!thumb || thumb->type != LIBRAW_IMAGE_JPEG) return 1;
    int width = 0, height = 0, channels = 0;
    std::unique_ptr<unsigned char, decltype(&stbi_image_free)> jpeg(
        stbi_load_from_memory(thumb->data, thumb->data_size, &width, &height, &channels, 3), stbi_image_free);
    if (!jpeg || width != 7008 || height != 4672 || metadata->imgdata.sizes.flip != 5) {
        std::cerr << "Unexpected DSC06251 thumbnail geometry\n";
        return 1;
    }
    RAWProcessor processor;
    RAWProcessOptions options;
    ImageData linear;
    if (processor.loadFile(rawPath) != ErrorCode::Success ||
        processor.process(options, linear) != ErrorCode::Success) return 1;
    if (linear.width != 4672 || linear.height != 7008) return 1;
    auto lut = LUTParser::loadLUTCached(argv[2]);
    if (!lut) return 1;
    LUTApplicator apply(lut);
    const auto matrix = ColorConverter::getConversionMatrix(ColorSpace::sRGB, ColorSpace::FujiFilm_FGamut);
    bool passed = true;
    for (float gain : {.5f, 1.f, 2.f}) {
        size_t measured = 0, filmPink = 0, neutralPink = 0;
        double filmMagenta = 0;
        // Compare only the car-body ROI that the embedded JPEG renders near white.
        for (int y = 0; y < linear.height; y += 8) for (int x = 0; x < linear.width; x += 8) {
            if (x <= linear.width * .70 || y <= linear.height * .19 || y >= linear.height * .36) continue;
            const auto* p = jpeg.get() + (static_cast<size_t>(x) * width + width - 1 - y) * 3;
            if (std::min({p[0], p[1], p[2]}) <= 255 * .90) continue;
            const auto source = linear.at(x, y);
            const RGB rgb(source.r * gain, source.g * gain, source.b * gain);
            const auto fg = ColorConverter::applyMatrix(rgb, matrix);
            const auto film = apply.apply(GammaConverter::applyFLog2ToRGB(fg));
            const RGB neutral(neutralDisplay(rgb.r), neutralDisplay(rgb.g), neutralDisplay(rgb.b));
            const float magenta = (film.r + film.b) / 2 - film.g;
            if (!std::isfinite(magenta)) return 1;
            ++measured;
            filmPink += magenta > .08f;
            neutralPink += (neutral.r + neutral.b) / 2 - neutral.g > .08f;
            filmMagenta += magenta;
        }
        std::cout << "gain=" << gain << " white_samples=" << measured << " film_pink=" << filmPink
                  << " neutral_pink=" << neutralPink << " mean_magenta=" << filmMagenta / measured << '\n';
        if (measured < 1000 || filmPink > measured * .01 || neutralPink > measured * .01 ||
            std::abs(filmMagenta / measured) > .02) passed = false;
    }
    // All four sensor samples are saturated here: suppress false chroma without clipping scene headroom.
    const auto white = linear.at(3984, 1544);
    const float low = std::min({white.r, white.g, white.b}), high = std::max({white.r, white.g, white.b});
    std::cout << "saturated_white=" << white.r << ',' << white.g << ',' << white.b << '\n';
    if (low <= 1 || high - low > .01f) passed = false;
    if (!passed) std::cerr << "Saturated car-body highlights must not render magenta\n";
    return passed ? 0 : 1;
}
