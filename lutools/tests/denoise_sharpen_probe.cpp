#include "core/noise_aware_sharpen.h"
#include "denoise_experiment_buffers.h"

#include <iostream>

using namespace sony2fuji;
using Json = nlohmann::json;

int main(int argc, char** argv) {
    try {
        if (argc != 2) throw std::runtime_error("usage: denoise_sharpen_probe request.json");
        Json request;
        std::ifstream(argv[1]) >> request;
        const std::filesystem::path directory = request.at("output").get<std::string>();
        if (!std::filesystem::create_directory(directory)) throw std::runtime_error("output must not exist");
        Json report = {{"candidate", kNoiseAwareSharpenCandidate}, {"runs", Json::array()}};
        for (const auto& item : request.at("inputs")) {
            const int width = item.at("width"), height = item.at("height");
            if (width < 1 || height < 1 || static_cast<uint64_t>(width) * height > 64000000)
                throw std::runtime_error("invalid input dimensions");
            const std::string id = item.at("id");
            if (id.empty() || id.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789-_") != std::string::npos)
                throw std::runtime_error("invalid input id");
            const auto caseDirectory = directory / id;
            if (!std::filesystem::create_directory(caseDirectory)) throw std::runtime_error("duplicate input id");
            ImageData source(width, height);
            const auto path = item.at("path").get<std::string>();
            const size_t bytes = source.pixels.size() * sizeof(RGB);
            if (std::filesystem::file_size(path) != bytes) throw std::runtime_error("input byte count mismatch");
            std::ifstream stream(path, std::ios::binary);
            stream.read(reinterpret_cast<char*>(source.pixels.data()), static_cast<std::streamsize>(bytes));
            if (!stream) throw std::runtime_error("input read failed");
            for (const std::string mode : request.at("modes")) for (float amount : request.at("amounts")) {
                if (mode != "cpu" && mode != "metal" && mode != "auto") throw std::runtime_error("invalid mode");
                auto result = source;
                NoiseAwareSharpenDiagnostics info;
                const auto start = std::chrono::steady_clock::now();
                const auto status = applyNoiseAwareSharpen(result, amount, &info,
                    mode == "cpu" ? GpuMode::Off : mode == "metal" ? GpuMode::Force : GpuMode::Auto);
                const double elapsed = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
                if (status != ErrorCode::Success || (amount > 0 && mode == "metal" && !info.gpuUsed))
                    throw std::runtime_error("native sharpen failed: " + id + "/" + mode);
                const std::string name = mode + "-" + std::to_string(amount);
                report["runs"].push_back({{"id", id}, {"mode", mode}, {"amount", amount},
                    {"elapsed_ms", elapsed}, {"gpu_used", info.gpuUsed}, {"applied", info.applied},
                    {"noise_sigma_median", info.noiseSigmaMedian}, {"noise_sigma_max", info.noiseSigmaMax},
                    {"buffer", denoise_experiment::writeImage(caseDirectory, name, result, "display_RGB", "p3_sharpen")}});
            }
        }
        std::ofstream output(directory / "result.json");
        output << report.dump(2) << '\n';
        output.close();
        if (!output) throw std::runtime_error("report write failed");
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
