#include "sony2fuji/raw_processor.h"
#include "sony2fuji/color_converter.h"
#include "sony2fuji/lut_applicator.h"
#include <algorithm>
#include <cmath>
#include <fstream>
#include <iostream>
#include <stdexcept>

using namespace sony2fuji;

void check(ErrorCode code) {
    if (code != ErrorCode::Success) throw std::runtime_error("RawLab operation failed");
}

void savePFM(const ImageData& image, const std::string& path) {
    std::ofstream out(path, std::ios::binary);
    out << "PF\n" << image.width << " " << image.height << "\n-1.0\n";
    for (int y = image.height - 1; y >= 0; --y) {
        for (int x = 0; x < image.width; ++x) {
            const auto& p = image.at(x, y);
            const float channels[3] = {p.r, p.g, p.b};
            out.write(reinterpret_cast<const char*>(channels), sizeof(channels));
        }
    }
    if (!out) throw std::runtime_error("Cannot write PFM: " + path);
}

ImageData loadPFM(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    std::string magic;
    int width = 0, height = 0;
    float scale = 0;
    in >> magic >> width >> height >> scale;
    in.get();
    if (magic != "PF" || width <= 0 || height <= 0 || scale != -1.f)
        throw std::runtime_error("Unsupported PFM");
    ImageData image(width, height);
    for (int y = height - 1; y >= 0; --y) {
        for (int x = 0; x < width; ++x) {
            float channels[3];
            in.read(reinterpret_cast<char*>(channels), sizeof(channels));
            if (!in) throw std::runtime_error("Truncated PFM");
            image.at(x, y) = RGB(channels[0], channels[1], channels[2]);
        }
    }
    return image;
}

ImageData reduceLinear(const ImageData& source, int maxEdge) {
    const double factor = std::min(1., double(maxEdge) / std::max(source.width, source.height));
    ImageData output(std::max(1, int(source.width * factor)), std::max(1, int(source.height * factor)));
    for (int y = 0; y < output.height; ++y) {
        const int top = y * source.height / output.height;
        const int bottom = (y + 1) * source.height / output.height;
        for (int x = 0; x < output.width; ++x) {
            const int left = x * source.width / output.width;
            const int right = (x + 1) * source.width / output.width;
            double r = 0, g = 0, b = 0;
            for (int sy = top; sy < bottom; ++sy) {
                for (int sx = left; sx < right; ++sx) {
                    const auto& p = source.at(sx, sy);
                    r += p.r; g += p.g; b += p.b;
                }
            }
            const double n = (bottom - top) * (right - left);
            output.at(x, y) = RGB(r / n, g / n, b / n);
        }
    }
    return output;
}

int main(int argc, char** argv) {
    try {
        if (argc != 5) throw std::runtime_error("raw_probe raw RAW PREFIX MAX_EDGE | apply LOG.pfm LUT.cube OUTPUT.pfm");
        if (std::string(argv[1]) == "raw") {
            const int maxEdge = std::stoi(argv[4]);
            if (maxEdge < 1) throw std::runtime_error("MAX_EDGE must be positive");
            RAWProcessor raw;
            check(raw.loadFile(argv[2]));
            RAWProcessOptions options;
            options.outputLinear = true;
            options.halfSize = false;
            options.matchEmbeddedPreviewExposure = false;
            options.applyBaselineExposure = true;
            ImageData full;
            check(raw.process(options, full));
            ColorConverter converter;
            check(converter.convertImage(full, raw.getNativeColorSpace(), ColorSpace::sRGB));
            auto image = reduceLinear(full, maxEdge);
            savePFM(image, std::string(argv[3]) + ".linear.pfm");
            check(converter.convertImage(image, ColorSpace::sRGB, ColorSpace::FujiFilm_FGamut));
            GammaConverter::FLog2Options logOptions;
            const auto diagnostics = GammaConverter::applyFLog2ToImage(image, logOptions);
            savePFM(image, std::string(argv[3]) + ".log.pfm");
            std::cout << raw.getCameraMake() << " " << raw.getCameraModel()
                      << "\nfull=" << full.width << "x" << full.height
                      << " preview=" << image.width << "x" << image.height
                      << "\nbaseline_ev=" << raw.getBaselineExposureEV()
                      << " user_ev=0 camera_wb=true full_demosaic=true"
                      << "\nfgamut_linear_min=" << diagnostics.min_linear
                      << " max=" << diagnostics.max_linear << "\n";
        } else if (std::string(argv[1]) == "apply") {
            auto image = loadPFM(argv[2]);
            std::shared_ptr<LUT3D> lut = LUTParser::loadLUT(argv[3]);
            if (!lut) throw std::runtime_error("Cannot parse LUT");
            LUTApplicator applicator(lut);
            check(applicator.applyToImage(image));
            savePFM(image, argv[4]);
        } else {
            throw std::runtime_error("Unknown command");
        }
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << "\n";
        return 1;
    }
}
