#include "ai/network_graph.h"
#include <nlohmann/json.hpp>
#include <algorithm>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>

using namespace sony2fuji::ai;
using Json = nlohmann::json;

std::vector<float> readFloats(const std::filesystem::path& path) {
    std::ifstream stream(path, std::ios::binary | std::ios::ate);
    if (!stream || stream.tellg() < 0 || stream.tellg() % 4)
        throw std::runtime_error("invalid fixture: " + path.string());
    std::vector<float> result(static_cast<size_t>(stream.tellg()) / 4);
    stream.seekg(0);
    stream.read(reinterpret_cast<char*>(result.data()), result.size() * 4);
    if (!stream) throw std::runtime_error("truncated fixture");
    return result;
}

int main(int argc, char** argv) {
    try {
        if (argc < 2 || argc > 5) throw std::runtime_error("usage: dualdn_onnx_tests FIXTURE_DIR [auto|coreml|directml] [--diagnostic [MODEL_DIR]]");
        const bool diagnostic = argc >= 4 && std::string(argv[3]) == "--diagnostic";
        if (argc >= 4 && !diagnostic) throw std::invalid_argument("unknown diagnostic flag");
        const std::filesystem::path root = std::filesystem::u8path(argv[1]);
        const std::string requested = argc >= 3 ? argv[2] : "auto";
        const auto backend = requested == "auto" ? Backend::Auto :
            requested == "coreml" ? Backend::CoreML : requested == "directml" ? Backend::DirectML : throw std::invalid_argument("unknown backend");
        std::ifstream stream(root / "manifest.json");
        Json manifest; stream >> manifest;
        const int size = manifest.at("tile_size");
        ModelPackage package;
        package.tileSize = size;
        for (size_t i = 0; i < 3; ++i) {
            const char* name = i == 0 ? "raw" : i == 1 ? "isp" : "rgb";
            package.paths[i] = (root / manifest.at("graphs").at(name).at("file").get<std::string>()).string();
        }
        if (argc == 5) {
            package = loadModelPackage(argv[4]);
            if (package.tileSize != size) throw std::invalid_argument("replay/model tile size mismatch");
        }
        Json report;
        const bool pipelineReplay = std::filesystem::exists(root / "pipeline-noisy_mosaic.f32");
        std::vector<float> rawPrediction, nativeSkip, nativeNoise;
        const std::pair<const char*, GraphKind> graphs[] = {
            {"raw", GraphKind::Raw}, {"isp", GraphKind::ISP}, {"rgb", GraphKind::RGB}};
        for (const auto& [name, kind] : graphs) {
            const auto graph = manifest.at("graphs").at(name);
            NetworkGraph model(package, kind, backend);
            std::vector<std::vector<float>> inputs;
            for (const auto& input : graph.at("inputs"))
                inputs.push_back(readFloats(root / (std::string(name) + "-" + input.at("name").get<std::string>() + ".f32")));
            const auto expected = readFloats(root / (std::string(name) + "-expected.f32"));
            const auto actual = model.run(inputs);
            if (pipelineReplay && kind == GraphKind::Raw) rawPrediction = actual;
            if (pipelineReplay && kind == GraphKind::ISP) {
                const size_t plane = size_t(size) * size;
                std::vector<float> clean(plane);
                for (int y = 0; y < size; ++y) for (int x = 0; x < size; ++x) {
                    const int row = y + size / 2, col = x + size / 2;
                    clean[size_t(y)*size+x] = rawPrediction[size_t((row%2)*2+col%2)*plane+size_t(row/2)*size+col/2];
                }
                auto noise = readFloats(root / "pipeline-noisy_mosaic.f32");
                const float k = readFloats(root / "raw-k.f32").at(0), b = readFloats(root / "raw-b.f32").at(0);
                for (auto& value : noise) value = std::sqrt(std::max(k*value+b,1e-7f));
                nativeSkip = model.run({clean, inputs[1], inputs[2]});
                nativeNoise = model.run({noise, inputs[1], inputs[2]});
            }
            if (actual.size() != expected.size()) throw std::runtime_error("output size mismatch");
            double maximum = 0, mean = 0;
            size_t exceeding = 0;
            for (size_t i = 0; i < actual.size(); ++i) {
                if (!std::isfinite(actual[i])) throw std::runtime_error("nonfinite model output");
                const double error = std::abs(double(actual[i]) - expected[i]);
                maximum = std::max(maximum, error); mean += error / actual.size();
                if (error > 1e-4) ++exceeding;
            }
            const bool parityPass = maximum <= 3e-4 && mean <= 2e-5;
            if (!parityPass && !diagnostic)
                throw std::runtime_error(std::string(name) + " parity failed: " + std::to_string(maximum));
            bool rejected = false;
            auto invalid = inputs;
            invalid.front().pop_back();
            try { model.run(invalid); } catch (const std::invalid_argument&) { rejected = true; }
            if (!rejected) throw std::runtime_error("wrong input size accepted");
            invalid = inputs; invalid.front()[0] = std::numeric_limits<float>::quiet_NaN(); rejected = false;
            try { model.run(invalid); } catch (const std::invalid_argument&) { rejected = true; }
            if (!rejected) throw std::runtime_error("NaN input accepted");
            report[name] = {{"backend", model.backend()}, {"fallback", model.fallbackReason()},
                            {"max_abs", maximum}, {"mean_abs", mean}, {"over_1e-4", exceeding},
                            {"strict_parity", parityPass}, {"runtime", NetworkGraph::runtimeVersion(backend)}};
            if (diagnostic) {
                std::ofstream output(root / (std::string(name) + "-actual.f32"), std::ios::binary);
                output.write(reinterpret_cast<const char*>(actual.data()), actual.size() * sizeof(float));
            }
            std::cout << report[name].dump() << std::endl;
            if (pipelineReplay && kind == GraphKind::RGB) {
                const auto combined = model.run({nativeSkip, nativeNoise});
                double combinedMax = 0, combinedMean = 0;
                size_t combinedExceeding = 0;
                for (size_t i = 0; i < expected.size(); ++i) {
                    const double error = std::abs(double(combined[i])-expected[i]);
                    combinedMax = std::max(combinedMax,error); combinedMean += error/expected.size();
                    if (error > 1e-4) ++combinedExceeding;
                }
                const bool combinedPass = combinedMax <= 1e-4 && combinedMean <= 1e-5;
                report["pipeline"] = {{"max_abs",combinedMax},{"mean_abs",combinedMean},
                    {"over_1e-4",combinedExceeding},{"strict_parity",combinedPass}};
                if (diagnostic) {
                    std::ofstream output(root / "pipeline-actual.f32",std::ios::binary);
                    output.write(reinterpret_cast<const char*>(combined.data()),combined.size()*sizeof(float));
                } else if (!combinedPass) throw std::runtime_error("combined pipeline parity failed");
            }
        }
        std::cout << report.dump(2) << '\n';
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n'; return 1;
    }
}
