#include "denoise_experiment_buffers.h"
#include "gpu/photo_gpu.h"
#include "sony2fuji/lut_parser.h"

#include <iostream>
#include <set>

using namespace sony2fuji;
using Json = nlohmann::json;

namespace {
float setting(const Json& scenario, const char* name, float fallback, float low, float high) {
    const float value = scenario.value(name, fallback);
    if (!std::isfinite(value) || value < low || value > high)
        throw std::runtime_error(std::string("invalid display setting: ") + name);
    return value;
}

ImageData readInput(const Json& input) {
    const int width = input.at("width"), height = input.at("height");
    if (width < 1 || height < 1 || static_cast<uint64_t>(width) * height > 64000000)
        throw std::runtime_error("invalid input dimensions");
    const std::filesystem::path path = input.at("path").get<std::string>();
    ImageData image(width, height);
    const size_t bytes = image.pixels.size() * sizeof(RGB);
    if (std::filesystem::file_size(path) != bytes) throw std::runtime_error("input byte count mismatch");
    std::ifstream stream(path, std::ios::binary);
    stream.read(reinterpret_cast<char*>(image.pixels.data()), static_cast<std::streamsize>(bytes));
    if (!stream) throw std::runtime_error("input read failed");
    for (const auto& pixel : image.pixels)
        if (!std::isfinite(pixel.r) || !std::isfinite(pixel.g) || !std::isfinite(pixel.b))
            throw std::runtime_error("input must be finite");
    return image;
}

Json renderScenario(const ImageData& input, const Json& scenario, const std::filesystem::path& directory) {
    static const std::set<std::string> fields = {"id", "lut", "lut_strength", "exposure_ev", "brightness",
        "contrast", "saturation", "highlights", "shadows", "tone_curve"};
    for (auto it = scenario.begin(); it != scenario.end(); ++it)
        if (!fields.count(it.key())) throw std::runtime_error("unknown display setting: " + it.key());
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION;
    request.struct_size = sizeof(request);
    request.intent = SONY2FUJI_INTENT_FINAL;
    request.input_type = SONY2FUJI_INPUT_BUFFER;
    request.input_color_space = SONY2FUJI_COLOR_SRGB;
    request.input_is_linear = 1;
    request.wb_mode = SONY2FUJI_WB_CAMERA;
    request.temperature = 6500;
    request.exposure_ev = setting(scenario, "exposure_ev", 0, -10, 10);
    request.brightness = setting(scenario, "brightness", 1, 0, 2);
    request.contrast = setting(scenario, "contrast", 1, 0, 2);
    request.saturation = setting(scenario, "saturation", 1, 0, 2);
    request.highlights = setting(scenario, "highlights", 0, -1, 1);
    request.shadows = setting(scenario, "shadows", 0, -1, 1);
    request.tone_curve = setting(scenario, "tone_curve", 0, -1, 1);
    request.lut_strength = setting(scenario, "lut_strength", 1, 0, 2);
    request.size_mode = SONY2FUJI_SIZE_EXACT;
    request.target_width = input.width;
    request.target_height = input.height;
    request.output_target = SONY2FUJI_TARGET_BUFFER;
    request.output_format = SONY2FUJI_OUTPUT_RGB8;
    std::shared_ptr<LUT3D> lut;
    if (scenario.contains("lut") && request.lut_strength > 0) {
        lut = LUTParser::loadLUTCached(scenario.at("lut").get<std::string>());
        if (!lut || !lut->isPhotoLUT()) throw std::runtime_error("incompatible display LUT");
    }
    Json result = {{"settings", scenario}, {"buffers", Json::object()}};
    for (const auto& item : std::vector<std::pair<std::string, float>>{
             {"off", 0}, {"ordinary_0.5", .5f}, {"ordinary_1", 1}, {"ordinary_2", 2}}) {
        request.sharpening = item.second;
        ImageData output;
        if (!renderPhotoMetal(input, ColorSpace::sRGB, request, lut, RGB(1, 1, 1),
                              input.width, input.height, output))
            throw std::runtime_error("actual Metal display render failed; no CPU substitution");
        result["buffers"][item.first] = denoise_experiment::writeImage(
            directory, item.first, output, "display_RGB", item.second == 0 ? "before_sharpen" : "ordinary_sharpen");
    }
    return result;
}
} // namespace

int main(int argc, char** argv) {
    try {
        if (argc != 2) throw std::runtime_error("usage: denoise_display_probe request.json");
        std::ifstream stream(argv[1]);
        Json request;
        stream >> request;
        const ImageData input = readInput(request.at("input"));
        const auto directory = std::filesystem::path(request.at("output").get<std::string>());
        if (!std::filesystem::create_directory(directory)) throw std::runtime_error("output must not exist");
        Json result = {{"backend", "Metal"}, {"input", request.at("input")}, {"scenarios", Json::array()}};
        for (const auto& scenario : request.at("scenarios")) {
            const auto id = scenario.at("id").get<std::string>();
            if (id.empty() || id.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789-") != std::string::npos)
                throw std::runtime_error("invalid scenario id");
            const auto scenarioDirectory = directory / id;
            if (!std::filesystem::create_directory(scenarioDirectory)) throw std::runtime_error("duplicate scenario");
            result["scenarios"].push_back(renderScenario(input, scenario, scenarioDirectory));
        }
        std::ofstream report(directory / "result.json");
        report << result.dump(2) << '\n';
        report.close();
        if (!report) throw std::runtime_error("report write failed");
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
