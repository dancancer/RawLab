#include "ai/dualdn_runtime.h"
#include "ai/dualdn_bridge.h"
#include "ai/dualdn_cache.h"
#include "ai/ai_session.h"
#include "core/photo_rendering.h"
#include <nlohmann/json.hpp>
#include <filesystem>
#include <fstream>
#include <iostream>

using namespace sony2fuji;
using namespace sony2fuji::ai;
using Json = nlohmann::json;

void writeBytes(const std::filesystem::path& path, const void* data, size_t bytes) {
    std::ofstream stream(path, std::ios::binary);
    stream.write(static_cast<const char*>(data), bytes);
    if (!stream) throw std::runtime_error("failed to write probe result");
}

void saveImage(const std::filesystem::path& root, const std::string& name, ImageData image) {
    static_assert(sizeof(RGB) == 3 * sizeof(float));
    writeBytes(root / (name + ".f32"), image.pixels.data(), image.pixels.size() * sizeof(RGB));
    for (auto& pixel : image.pixels) pixel = RGB(neutralDisplay(pixel.r), neutralDisplay(pixel.g), neutralDisplay(pixel.b));
    if (ImageEncoder::savePNG(image, (root / (name + ".png")).string()) != ErrorCode::Success)
        throw std::runtime_error("failed to save probe PNG");
}

void probePipeline(const std::string& input, const std::string& model, const std::filesystem::path& root, Backend backend) {
    if (!std::filesystem::create_directory(root)) throw std::runtime_error("new output directory required");
    RAWProcessOptions options;
    options.bayerDemosaic = BayerDemosaicMethod::VNG; options.applyBaselineExposure = false;
    AISession session;
    session.configure(model,(root/"cache").u8string(),backend);
    const auto report = session.prepare(input,options,[](Phase phase,size_t done,size_t total) {
        if (done == 0 || done == total || done % 10 == 0) std::cerr << "phase=" << int(phase) << ' ' << done << '/' << total << '\n';
        return true;
    });
    RAWProcessor processor; RAWBayerSource metadata;
    if (processor.loadFile(input) != ErrorCode::Success) throw std::runtime_error("RAW load failed");
    const bool bayer = processor.getBayerMetadata(metadata);
    ImageData image;
    if (processor.process(options,image) != ErrorCode::Success) throw std::runtime_error("native render failed");
    const int width = image.width, height = image.height;
    saveImage(root,"native",std::move(image));
    const auto& result = session.result(input,options,bayer ? &metadata : nullptr);
    if (!result.isSceneRGB()) options.bayerOverride = &result.bayer;
    if (processor.process(options,image) != ErrorCode::Success) throw std::runtime_error("AI render failed");
    if (result.isSceneRGB()) applySceneRGBCorrection(image,result.scene,ColorSpace::sRGB,1);
    saveImage(root,"full",std::move(image));
    const auto second = session.prepare(input,options,{});
    if (!second.rgbCacheHit || (report.route == "Bayer" && !second.rawCacheHit)) throw std::runtime_error("pipeline cache reuse failed");
    const Json diagnostics = {{"camera",processor.getCameraModel()}, {"width",width}, {"height",height},
        {"route",report.route}, {"route_reason",report.routeReason}, {"producer",session.lastBackend},
        {"noise_profile",report.noise.calibrationID}, {"k",report.noise.k}, {"b",report.noise.b},
        {"noise_samples",report.noise.samples}, {"noise_span",report.noise.signalSpan}, {"noise_fit_error",report.noise.relativeError},
        {"raw_seconds",report.raw.seconds}, {"rgb_seconds",report.rgb.seconds},
        {"raw_fallback",report.raw.fallbackReason}, {"rgb_fallback",report.rgb.fallbackReason},
        {"raw_cache_hit",second.rawCacheHit}, {"rgb_cache_hit",second.rgbCacheHit}};
    std::ofstream(root/"pipeline.json") << diagnostics.dump(2) << '\n';
    std::cout << diagnostics.dump(2) << '\n';
}

int main(int argc, char** argv) {
    try {
        if (argc == 3 && std::string(argv[1]) == "--validate") {
            const auto package = loadModelPackage(argv[2]);
            if (package.tileSize != 640) throw std::runtime_error("production package requires 640-pixel tiles");
            std::cout << "Validated DualDn package " << package.digest << '\n';
            return 0;
        }
        if (argc != 6 && argc != 8)
            throw std::runtime_error("usage: dualdn_probe RAW MODEL_DIR NEW_OUTPUT raw|full|pipeline cpu|auto|coreml|directml [EXPERIMENT_K EXPERIMENT_B | --raw-result PREVIOUS_OUTPUT]");
        const std::string mode = argv[4], requested = argv[5];
        const auto backend = requested == "cpu" ? Backend::Cpu : requested == "auto" ? Backend::Auto :
            requested == "coreml" ? Backend::CoreML : requested == "directml" ? Backend::DirectML : throw std::invalid_argument("invalid backend");
        if (mode == "pipeline" && argc == 6) { probePipeline(argv[1],argv[2],std::filesystem::u8path(argv[3]),backend); return 0; }
        if (mode != "raw" && mode != "full") throw std::invalid_argument("invalid output mode");
        const auto package = loadModelPackage(argv[2]);
        RAWProcessor processor;
        if (processor.loadFile(argv[1]) != ErrorCode::Success) throw std::runtime_error("RAW load failed");
        RAWProcessOptions options;
        options.bayerDemosaic = BayerDemosaicMethod::VNG; options.applyBaselineExposure = false;
        RAWBayerSource source;
        if (processor.readBayerSource(options, source) != ErrorCode::Success) throw std::runtime_error("Bayer extraction failed");
        NoiseParameters noise;
        const bool resumeRaw = argc == 8 && std::string(argv[6]) == "--raw-result";
        if (argc == 8 && !resumeRaw) { noise.k = std::stof(argv[6]); noise.b = std::stof(argv[7]); noise.calibrationID = "explicit-probe-override"; }
        else noise = selectNoiseProfile(source);
        const auto root = std::filesystem::u8path(argv[3]);
        if (!std::filesystem::create_directory(root)) throw std::runtime_error("new output directory required");
        Json report = {{"camera", source.cameraModel}, {"iso", source.iso}, {"width", source.width}, {"height", source.height},
            {"flip", source.flip}, {"raw_bits", source.rawBits}, {"sony_raw_type", source.sonyRawType},
            {"black", source.black}, {"white", source.white}, {"pattern", source.pattern}, {"wb", source.whiteBalance},
            {"camera_calibration", source.cameraCalibration}, {"camera_to_srgb", source.cameraToSrgb},
            {"official_camera_to_xyz", officialCameraToXYZ(source)}, {"k", noise.k}, {"b", noise.b},
            {"calibration", noise.calibrationID}, {"model_digest", package.digest}};
        std::ofstream(root / "source.json") << report.dump(2) << '\n';
        writeBytes(root / "original.u16", source.pixels.data(), source.pixels.size() * sizeof(uint16_t));
        ImageData native;
        if (processor.process(options, native) != ErrorCode::Success) throw std::runtime_error("native render failed");
        saveImage(root, "native", std::move(native));
        auto progress = [](const char* phase) { return [phase](size_t done, size_t total) {
            if (done == 0 || done == total || done % 10 == 0) std::cerr << phase << ' ' << done << '/' << total << '\n';
            return true;
        }; };
        RuntimeReport rawReport, rgbReport;
        RAWBayerOverride denoised;
        if (resumeRaw) {
            const auto previous = std::filesystem::u8path(argv[7]);
            const auto metadata = Json::parse(std::ifstream(previous / "source.json"));
            for (const auto* field : {"model_digest", "width", "height", "pattern", "black", "white", "k", "b"})
                if (metadata.at(field) != report.at(field)) throw std::runtime_error("RAW checkpoint identity mismatch");
            if (sha256File((previous / "original.u16").string()) !=
                sha256Bytes(source.pixels.data(), source.pixels.size() * sizeof(uint16_t)))
                throw std::runtime_error("RAW checkpoint source pixels mismatch");
            const auto path = previous / "denoised.f32";
            if (std::filesystem::file_size(path) != source.pixels.size() * sizeof(float))
                throw std::runtime_error("RAW checkpoint dimensions mismatch");
            denoised = {source.width, source.height, std::vector<float>(source.pixels.size()), {}};
            std::ifstream stream(path, std::ios::binary);
            stream.read(reinterpret_cast<char*>(denoised.normalizedMosaic.data()), source.pixels.size() * sizeof(float));
            if (!stream) throw std::runtime_error("Cannot read RAW checkpoint");
            validateTensor({source.width, source.height, 1, denoised.normalizedMosaic});
            rawReport.backend = "validated-checkpoint";
        } else denoised = denoiseRaw(source, package, noise, backend, rawReport, progress("RAW"));
        writeBytes(root / "denoised.f32", denoised.normalizedMosaic.data(), denoised.normalizedMosaic.size() * sizeof(float));
        options.bayerOverride = &denoised;
        ImageData rawOnly;
        if (processor.process(options, rawOnly) != ErrorCode::Success) throw std::runtime_error("RAW-only render failed");
        saveImage(root, "raw-only", std::move(rawOnly));
        report["raw"] = {{"seconds", rawReport.seconds}, {"backend", rawReport.backend}, {"fallback", rawReport.fallbackReason}};
        std::cerr << "RAW done in " << rawReport.seconds << " s\n";
        if (mode == "full") {
            const auto rgb = denoiseRgb(source, denoised, package, noise, backend, RGBOutput::BothForValidation, rgbReport, progress("RGB"));
            const size_t pixels = source.pixels.size();
            const auto runtimeIdentity = package.digest + ":" + NetworkGraph::runtimeVersion(backend);
            const auto rawKey = rawCacheKey(argv[1], sha256Bytes(runtimeIdentity.data(), runtimeIdentity.size()), static_cast<int>(backend));
            const auto rgbKey = rgbCacheKey(rawKey, options);
            DenoiseCache cache((root / "cache").string());
            cache.store(rawKey, CacheKind::Raw, source.width, source.height, denoised.normalizedMosaic.data(), pixels, {}, rawReport.backend);
            cache.store(rgbKey, CacheKind::RGB, source.width, source.height, rgb.values.data(), 3 * pixels,
                        sha256Bytes(denoised.normalizedMosaic.data(), pixels * sizeof(float)), rgbReport.backend);
            report["cache_keys"] = {rawKey, rgbKey};
            denoised.cameraCorrection.resize(pixels);
            for (size_t i = 0; i < pixels; ++i)
                denoised.cameraCorrection[i] = RGB(rgb.values[i], rgb.values[pixels+i], rgb.values[2*pixels+i]);
            ImageData bridged;
            if (processor.process(options, bridged) != ErrorCode::Success) throw std::runtime_error("bridge render failed");
            saveImage(root, "bridged", std::move(bridged));
            ImageData official((source.flip & 4) ? source.height : source.width, (source.flip & 4) ? source.width : source.height);
            for (int y = 0; y < official.height; ++y) for (int x = 0; x < official.width; ++x) {
                int row = y, col = x;
                if (source.flip & 4) std::swap(row, col);
                if (source.flip & 2) row = source.height - 1 - row;
                if (source.flip & 1) col = source.width - 1 - col;
                const size_t i = size_t(row) * source.width + col;
                official.at(x,y) = RGB(rgb.values[3*pixels+i], rgb.values[4*pixels+i], rgb.values[5*pixels+i]);
            }
            saveImage(root, "official", std::move(official));
            report["rgb"] = {{"seconds", rgbReport.seconds}, {"backend", rgbReport.backend}, {"fallback", rgbReport.fallbackReason}};
        }
        std::ofstream(root / "report.json") << report.dump(2) << '\n';
        std::cout << report.dump(2) << '\n';
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
