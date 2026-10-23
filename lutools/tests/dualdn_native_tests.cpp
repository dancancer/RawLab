#include "ai/coreml_graph.h"
#include "ai/network_graph.h"
#include "ai/model_package.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>

using namespace sony2fuji::ai;
void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
std::vector<float> read(const std::filesystem::path& path) {
    const auto bytes = std::filesystem::file_size(path);
    require(bytes % sizeof(float) == 0, "invalid replay size");
    std::vector<float> values(bytes / sizeof(float));
    std::ifstream stream(path, std::ios::binary); stream.read(reinterpret_cast<char*>(values.data()), bytes);
    require(bool(stream), "cannot read replay tensor"); return values;
}
void compare(const std::vector<float>& actual, const std::vector<float>& expected) {
    require(actual.size() == expected.size(), "native shape changed");
    double sum = 0; float maximum = 0;
    for (size_t i = 0; i < actual.size(); ++i) {
        require(std::isfinite(actual[i]), "native output nonfinite");
        const float delta = std::abs(actual[i] - expected[i]); maximum = std::max(maximum, delta); sum += delta;
    }
    require(maximum <= 3e-4f && sum / actual.size() <= 2e-5, "native parity exceeded the fixed gate");
    std::cout << "max_abs=" << maximum << " mean_abs=" << sum / actual.size() << '\n';
}

int main(int argc, char** argv) {
    try {
        require(argc == 2, "requires a native model package with replay fixtures");
        const auto package = loadModelPackage(argv[1]);
        if (package.coreMLPaths[0].empty() || !CoreMLGraph::available()) {
            std::cout << "SKIP native Core ML resources or Apple Silicon GPU unavailable\n"; return 77;
        }
        for (const auto backend : {Backend::CoreML, Backend::Auto}) {
            NetworkGraph isp(package, GraphKind::ISP, backend);
            require(isp.backend() == "CPU" && isp.fallbackReason().empty(), "official ISP must remain on CPU");
        }
        for (const auto kind : {GraphKind::Raw, GraphKind::RGB}) {
            const std::string name = kind == GraphKind::Raw ? "raw" : "rgb";
            const auto signature = graphSignature(kind, 640);
            std::vector<std::vector<float>> inputs;
            for (const auto& input : signature.inputNames)
                inputs.push_back(read(std::filesystem::u8path(argv[1]) / (name + "-" + input + ".f32")));
            const auto expected = read(std::filesystem::u8path(argv[1]) / (name + "-expected.f32"));
            NetworkGraph graph(package, kind, Backend::CoreML);
            require(graph.backend() == "CoreML", "forced native model silently fell back");
            for (int iteration = 0; iteration < 2; ++iteration) {
                const auto start = std::chrono::steady_clock::now(); const auto actual = graph.run(inputs);
                std::cout << name << " iteration=" << iteration << " seconds=" <<
                    std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count() << ' ';
                compare(actual, expected);
            }
            auto invalid = inputs; invalid[0][0] = std::numeric_limits<float>::quiet_NaN();
            bool rejected = false; try { graph.run(invalid); } catch (const std::invalid_argument&) { rejected = true; }
            require(rejected, "native graph accepted nonfinite input");
            invalid = inputs; invalid[0].pop_back(); rejected = false;
            try { graph.run(invalid); } catch (const std::invalid_argument&) { rejected = true; }
            require(rejected, "native graph accepted wrong tensor size");
            auto legacy = package; legacy.coreMLPaths = {};
            NetworkGraph fallback(legacy, kind, Backend::Auto);
            require(fallback.backend() == "CPU" && !fallback.fallbackReason().empty(), "Auto did not report missing native model fallback");
            compare(fallback.run(inputs), expected);
            rejected = false; try { NetworkGraph forced(legacy, kind, Backend::CoreML); }
            catch (const std::runtime_error&) { rejected = true; }
            require(rejected, "forced Core ML accepted a missing native model");
        }
        std::cout << "PASS native float32 Core ML, tensor validation, Auto fallback and Force failure\n"; return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
