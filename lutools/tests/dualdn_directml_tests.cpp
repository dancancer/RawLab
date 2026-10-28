#include "ai/directml_device.h"
#include "ai/network_graph.h"
#include "ai/model_package.h"
#include <algorithm>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>

using namespace sony2fuji::ai;
void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
std::vector<float> read(const std::filesystem::path& path) {
    const auto bytes = std::filesystem::file_size(path);
    require(bytes % 4 == 0, "invalid replay tensor");
    std::vector<float> values(bytes / 4);
    std::ifstream stream(path, std::ios::binary); stream.read(reinterpret_cast<char*>(values.data()), bytes);
    require(bool(stream), "cannot read replay tensor"); return values;
}
int main(int argc, char** argv) {
    try {
        require(argc == 2, "requires model package");
        require(!isDirectMLHardware(2, 0x10de, 1), "software adapter accepted");
        require(!isDirectMLHardware(0, 0x1414, 0x8c), "WARP accepted without software flag");
        require(isDirectMLHardware(0, 0x8086, 1), "hardware candidate rejected before D3D12 check");
        const auto package = loadModelPackage(argv[1]);
        bool hardware = false;
        try { const auto device = findDirectMLAdapter(); hardware = true; std::cout << device.identity << '\n'; }
        catch (const std::runtime_error& error) { std::cout << "NO HARDWARE: " << error.what() << '\n'; }
        for (const auto kind : {GraphKind::Raw, GraphKind::RGB, GraphKind::BlindRGB}) {
            if (kind == GraphKind::BlindRGB && package.blindRGBPath.empty()) continue;
            bool rejected = false;
            try {
                NetworkGraph force(package, kind, Backend::DirectML);
                require(hardware && force.backend() == "DirectML", "forced DirectML disguised a CPU/software backend");
                const std::string name = kind == GraphKind::Raw ? "raw" : kind == GraphKind::RGB ? "rgb" : "blind_rgb";
                std::vector<std::vector<float>> inputs;
                for (const auto& input : graphSignature(kind, package.tileSize).inputNames)
                    inputs.push_back(read(std::filesystem::u8path(argv[1]) / (name + "-" + input + ".f32")));
                const auto actual = force.run(inputs), expected = read(std::filesystem::u8path(argv[1]) / (name + "-expected.f32"));
                require(actual.size() == expected.size(), "DirectML output size changed");
                double maximum = 0, sum = 0;
                for (size_t i = 0; i < actual.size(); ++i) {
                    require(std::isfinite(actual[i]), "DirectML returned nonfinite output");
                    const double delta = std::abs(double(actual[i]) - expected[i]); maximum = std::max(maximum, delta); sum += delta;
                }
                require(maximum <= 3e-4 && sum / actual.size() <= 2e-5, "DirectML parity exceeded fixed gate");
                std::cout << name << " max_abs=" << maximum << " mean_abs=" << sum / actual.size() << '\n';
            } catch (const std::runtime_error&) { if (hardware) throw; rejected = true; }
            require(hardware || rejected, "Force accepted missing DirectML hardware");
#ifdef _WIN32
            bool autoRejected = false;
            try { NetworkGraph automatic(package, kind, Backend::Auto);
                require(hardware && automatic.backend() == "DirectML", "Auto accepted a CPU backend"); }
            catch (const std::runtime_error&) { if (hardware) throw; autoRejected = true; }
            require(hardware || autoRejected, "Auto accepted missing GPU hardware");
#endif
        }
        NetworkGraph isp(package, GraphKind::ISP, Backend::DirectML);
        require(isp.backend() == "CPU", "ISP left CPU");
        std::cout << (hardware ? "PASS hardware DirectML parity" : "PASS DirectML unavailable/Force rejection; hardware inference NOT REACHED") << '\n';
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
