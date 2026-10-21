#include "denoise_quality_metrics.h"
#include "denoise_experiment_buffers.h"
#include "core/wavelet_denoise.h"
#include "cli/raw_info.h"
#include "sony2fuji/raw_processor.h"
#include <chrono>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <random>
#include <sstream>
#if defined(SONY2FUJI_ENABLE_CHROMA_DENOISE) || defined(SONY2FUJI_ENABLE_WAVELET_DENOISE)
#include <opencv2/imgproc.hpp>
#endif
#if !defined(_WIN32)
#include <sys/resource.h>
#endif

using namespace sony2fuji;
using Json = nlohmann::json;
using Clock = std::chrono::steady_clock;

namespace {
const char* compiledBackend() {
#if defined(SONY2FUJI_ENABLE_METAL)
    return "Metal";
#elif defined(SONY2FUJI_ENABLE_GLES)
    return "GLES";
#elif defined(SONY2FUJI_ENABLE_D3D11)
    return "D3D11";
#else
    return "none";
#endif
}

double milliseconds(Clock::time_point start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}

std::string fingerprint(const ImageData& image) {
    uint64_t hash = 14695981039346656037ULL;
    for (const auto& pixel : image.pixels) for (float value : {pixel.r, pixel.g, pixel.b}) {
        uint32_t bits;
        std::memcpy(&bits, &value, sizeof(bits));
        for (int byte = 0; byte < 4; ++byte) {
            hash ^= (bits >> (byte * 8)) & 255;
            hash *= 1099511628211ULL;
        }
    }
    std::ostringstream stream;
    stream << "fnv1a64-f32le:" << std::hex << std::setw(16) << std::setfill('0') << hash;
    return stream.str();
}

ImageData synthetic(const Json& spec, ImageData& truth) {
    const int width = spec.at("width"), height = spec.at("height");
    if (width <= 0 || height <= 0 || width > 4096 || height > 4096)
        throw std::runtime_error("invalid synthetic dimensions");
    const std::string pattern = spec.at("pattern");
    const double shot = spec.at("shot"), read = spec.at("read");
    if (!std::isfinite(shot) || !std::isfinite(read) || shot < 0 || read < 0 || shot > .1 || read > .1 ||
        (shot > 0 && shot < 1e-8))
        throw std::runtime_error("invalid noise parameters");
    truth = ImageData(width, height);
    for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
        const double u = double(x) / width, v = double(y) / height;
        RGB value{.18f, .18f, .18f};
        if (pattern == "levels") {
            const float level = .02f + .12f * ((x / 128 + y / 128) % 6);
            value = {level, level * .8f, level * 1.2f};
        } else if (pattern == "texture") {
            if (u > .25 && u < .75 && v > .25 && v < .75) {
                const float detail = .025f * std::sin(x * 1.1f) * std::cos(y * .8f);
                value = {.18f + detail, .18f + detail, .18f + detail};
            }
        } else if (pattern == "color_edge") {
            value = u < .5 ? RGB{.28f, .08f, .18f} : RGB{.08f, .28f, .18f};
        } else if (pattern == "gradient") {
            value = {float(.02 + .65 * u), float(.02 + .65 * u), float(.02 + .65 * u)};
        } else if (pattern == "periodic") {
            const float level = .18f + .01f * std::sin(x * 1.7f);
            value = {level, level, level};
        } else if (pattern == "extended") {
            const float level = u < .5 ? -.02f : 1.2f;
            value = {level, level * .9f, level * 1.1f};
        } else if (pattern != "flat") throw std::runtime_error("unknown pattern");
        truth.at(x, y) = value;
    }
    ImageData source = truth;
    std::mt19937 random(spec.at("seed").get<uint32_t>());
    std::normal_distribution<double> gaussian(0, 1);
    for (auto& pixel : source.pixels) for (float* channel : {&pixel.r, &pixel.g, &pixel.b}) {
        const double positive = std::max(0., double(*channel));
        const double shotNoise = shot > 0 && positive > 0 ?
            shot * std::poisson_distribution<int>(positive / shot)(random) - positive : 0;
        *channel = static_cast<float>(*channel + shotNoise + read * gaussian(random));
    }
    return source;
}

ImageData decodeQualityRaw(const std::string& path, Json& metadata,
                 BayerDemosaicMethod method = BayerDemosaicMethod::VNG, std::string* demosaic = nullptr) {
    const auto info = inspectRawInfo(path);
    if (info.status != SONY2FUJI_STATUS_OK) throw std::runtime_error("RAW identification failed: " + info.message);
    metadata = info.result;
    RAWProcessor processor;
    if (processor.loadFile(path) != ErrorCode::Success) throw std::runtime_error("RAW load failed");
    RAWProcessOptions options;
    options.applyBaselineExposure = false;
    options.matchEmbeddedPreviewExposure = false;
    options.halfSize = false;
    options.rawNoiseReduction = 0;
    options.bayerDemosaic = method;
    options.outputLinear = true;
    if (demosaic) *demosaic = processor.supportsNoiseReduction() ?
        (method == BayerDemosaicMethod::VNG ? "vng" : "dht") : "libraw_default";
    ImageData image;
    if (processor.process(options, image) != ErrorCode::Success) throw std::runtime_error("RAW decode failed");
    return image;
}

ImageData registeredReference(const ImageData& reference, const ImageData& source, const Json& registration) {
#if defined(SONY2FUJI_ENABLE_CHROMA_DENOISE) || defined(SONY2FUJI_ENABLE_WAVELET_DENOISE)
    const auto affine = registration.at("input_to_reference_affine").get<std::array<std::array<double, 3>, 2>>();
    const double gain = registration.at("reference_to_input_gain").get<double>();
    for (const auto& row : affine) for (double value : row)
        if (!std::isfinite(value)) throw std::runtime_error("nonfinite reference registration");
    const double determinant = affine[0][0] * affine[1][1] - affine[0][1] * affine[1][0];
    if (!std::isfinite(determinant) || std::abs(determinant) < 1e-12 ||
        !std::isfinite(gain) || gain <= 0 || gain > 1000 ||
        registration.value("estimated_from", "") != "input_and_reference" ||
        !registration.at("candidate_output_used").is_boolean() ||
        registration.at("candidate_output_used").get<bool>() ||
        registration.value("method", "").find_first_not_of(" \t\r\n") == std::string::npos)
        throw std::runtime_error("invalid input-only reference registration");
    static_assert(sizeof(RGB) == 3 * sizeof(float));
    const cv::Mat pixels(reference.height, reference.width, CV_32FC3,
                         const_cast<RGB*>(reference.pixels.data()));
    ImageData result(source.width, source.height);
    cv::Mat aligned(result.height, result.width, CV_32FC3, result.pixels.data());
    const cv::Matx23d transform(affine[0][0], affine[0][1], affine[0][2],
                               affine[1][0], affine[1][1], affine[1][2]);
    // 矩阵从输入坐标映射到参考坐标；无效边界用 NaN，禁止外推像素进入评测。
    cv::warpAffine(pixels, aligned, transform, aligned.size(), cv::INTER_LINEAR | cv::WARP_INVERSE_MAP,
                   cv::BORDER_CONSTANT, cv::Scalar::all(std::numeric_limits<float>::quiet_NaN()));
    aligned *= gain;
    return result;
#else
    (void)reference; (void)source; (void)registration;
    throw std::runtime_error("reference registration requires OpenCV");
#endif
}

Json metrics(const denoise_quality::Metrics& value) {
    return {{"luma_mean", value.lumaMean}, {"luma_stddev", value.lumaStddev}, {"chroma_stddev", value.chromaStddev}};
}

Json errors(const denoise_quality::Metrics& value) {
    if (!value.referenceError) return nullptr;
    const auto& error = *value.referenceError;
    return {{"rgb_rmse", error.rgbRmse}, {"luma_rmse", error.lumaRmse}, {"chroma_rmse", error.chromaRmse},
            {"mean_rgb_error", error.meanRgbError},
            {"luma_contrast_gain", error.lumaContrastGain ? Json(*error.lumaContrastGain) : Json(nullptr)},
            {"luma_laplacian_gain", error.lumaLaplacianGain ? Json(*error.lumaLaplacianGain) : Json(nullptr)},
            {"reference_laplacian_rms", error.referenceLaplacianRms ? Json(*error.referenceLaplacianRms) : Json(nullptr)}};
}

Json diagnostics(const WaveletDenoiseDiagnostics& value) {
    const auto& estimate = value.estimate;
    return {{"outcome", waveletDenoiseOutcomeName(value.outcome)},
            {"flat_tiles", value.flatTiles}, {"applied", value.applied}, {"gpu_filter_used", value.gpuUsed},
            {"analysis_reused", value.analysisReused}, {"coarse_analysis_reused", value.coarseAnalysisReused},
            {"a", estimate.fitAvailable ? Json(value.a) : Json(nullptr)},
            {"b", estimate.fitAvailable ? Json(value.b) : Json(nullptr)},
            {"estimate", {{"candidate_tiles", estimate.candidateTiles}, {"rejected_small", estimate.rejectedSmall},
                {"rejected_structure", estimate.rejectedStructure}, {"rejected_low_noise", estimate.rejectedLowNoise},
                {"rejected_periodic", estimate.rejectedPeriodic}, {"fit_available", estimate.fitAvailable},
                {"sample_mean_min", value.flatTiles ? Json(estimate.sampleMeanMin) : Json(nullptr)},
                {"sample_mean_max", value.flatTiles ? Json(estimate.sampleMeanMax) : Json(nullptr)},
                {"relative_fit_rmse", estimate.fitAvailable ? Json(estimate.relativeFitRmse) : Json(nullptr)},
                {"sample_variance_median", estimate.fitAvailable ? Json(estimate.sampleVarianceMedian) : Json(nullptr)},
                {"fit_rmse", estimate.fitAvailable ? Json(estimate.fitRmse) : Json(nullptr)},
                {"relative_fit_median_abs_residual", estimate.fitAvailable ? Json(estimate.relativeFitMedianAbsResidual) : Json(nullptr)},
                {"fit_top_decile_error_fraction", estimate.fitAvailable ? Json(estimate.fitTopDecileErrorFraction) : Json(nullptr)},
                {"constant_variance_fallback", estimate.fitAvailable ? Json(estimate.constantVarianceFallback) : Json(nullptr)}}}};
}

Json crop(const ImageData& image, denoise_quality::Region region, const std::string& path, double ev) {
    const int width = std::min(512, region.width), height = std::min(512, region.height);
    region.x += (region.width - width) / 2;
    region.y += (region.height - height) / 2;
    ImageData result(width, height);
    for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
        auto pixel = image.at(region.x + x, region.y + y);
        for (float* channel : {&pixel.r, &pixel.g, &pixel.b}) {
            const double linear = std::clamp(*channel * std::exp2(ev), 0., 1.);
            *channel = static_cast<float>(linear <= .0031308 ? linear * 12.92 : 1.055 * std::pow(linear, 1 / 2.4) - .055);
        }
        result.at(x, y) = pixel;
    }
    if (ImageEncoder::savePNG(result, path) != ErrorCode::Success) throw std::runtime_error("crop encoding failed");
    return {{"path", path}, {"rect_pixels", {region.x, region.y, width, height}},
            {"scale", "1:1"}, {"transfer", "sRGB"}, {"view_ev", ev}, {"clip", {0, 1}}};
}

Json peakRssBytes() {
#if !defined(_WIN32)
    rusage usage{};
    if (getrusage(RUSAGE_SELF, &usage) == 0) {
#if defined(__APPLE__)
        return usage.ru_maxrss;
#else
        return uint64_t(usage.ru_maxrss) * 1024;
#endif
    }
#endif
    return nullptr;
}
} // namespace

int main(int argc, char** argv) {
    if (argc != 3) return 2;
    Json report;
    int code = 0;
    try {
        std::ifstream stream(argv[1]);
        const auto request = Json::parse(stream);
        const auto& spec = request.at("case");
        const std::string bayerDemosaic = request.value("bayer_demosaic", "vng");
        if (bayerDemosaic != "vng" && bayerDemosaic != "dht")
            throw std::runtime_error("invalid Bayer demosaic method");
        const auto method = bayerDemosaic == "vng" ? BayerDemosaicMethod::VNG : BayerDemosaicMethod::DHT;
        const auto start = Clock::now();
        ImageData reference, source;
        Json metadata = nullptr;
        std::string referenceKind = "none";
        Json registration = nullptr;
        std::string demosaic = "not_applicable", referenceDemosaic = "not_applicable";
        const bool isSynthetic = spec.at("input").at("kind") == "synthetic";
        if (isSynthetic) {
            source = synthetic(spec.at("input"), reference);
            referenceKind = "synthetic_truth";
        } else {
            source = decodeQualityRaw(request.at("assets").at("input"), metadata, method, &demosaic);
            if (request.at("assets").contains("reference")) {
                Json unused;
                reference = decodeQualityRaw(request.at("assets").at("reference"), unused, method, &referenceDemosaic);
                referenceKind = "declared_registered_low_noise_reference";
                if (spec.at("reference").contains("registration")) {
                    registration = spec.at("reference").at("registration");
                    reference = registeredReference(reference, source, registration);
                }
            }
        }
        const double decodeMs = milliseconds(start);
        const ImageData* truth = reference.pixels.empty() ? nullptr : &reference;
        const auto& settings = request.at("options");
        WaveletDenoiseOptions options{settings.at("enabled"), settings.at("luma"), settings.at("chroma"), settings.at("coarse")};
        options.processingVersion = static_cast<ProcessingVersion>(request.value("processing_version", 2));
        if (!validProcessingVersion(options.processingVersion)) throw std::runtime_error("invalid processing version");
        const std::string backend = request.at("backend");
        if (backend != "cpu" && backend != "auto" && backend != "force") throw std::runtime_error("invalid backend");
        const GpuMode gpu = backend == "cpu" ? GpuMode::Off : backend == "auto" ? GpuMode::Auto : GpuMode::Force;
        ImageData output = source;
        WaveletDenoiseAnalysisCache cache;
        WaveletDenoiseDiagnostics details;
        const auto filterStart = Clock::now();
        const auto status = applyWaveletDenoise(output, options, &details, gpu, &cache, "quality-input");
        const double filterMs = milliseconds(filterStart);
        report = {{"version", 1}, {"request_id", request.at("request_id")},
                  {"case_id", spec.at("id")}, {"split", spec.at("split")},
                  {"status", status == ErrorCode::Success ? "MEASURED" : "PROCESSING_FAILED"},
                  {"error_code", static_cast<int>(status)}, {"options", settings}, {"backend_requested", backend},
                  {"bayer_demosaic_requested", bayerDemosaic},
                  {"processing", {{"family", "rawlab"}, {"version", static_cast<int>(options.processingVersion)},
                                   {"quality", "standard"}, {"denoiser", options.processingVersion == ProcessingVersion::Legacy ? "swt_legacy" : "c5_eaw"}}},
                  {"diagnostics", diagnostics(details)}, {"wavelet_available", waveletDenoiseAvailable()},
                  {"metadata", metadata}, {"width", source.width}, {"height", source.height},
                  {"source_fingerprint", fingerprint(source)}, {"reference_kind", referenceKind},
                  {"reference_registration", registration},
                  {"decode_ms", decodeMs}, {"filter_ms", filterMs},
                  {"build", {{"compiler", QUALITY_COMPILER}, {"configuration", QUALITY_BUILD_TYPE},
                             {"gpu_backend", compiledBackend()}, {"compiled", std::string(__DATE__) + " " + __TIME__}}},
                  {"pipeline", {{"space", "linear_sRGB"}, {"white_balance", isSynthetic ? "not_applicable" : "camera_before_demosaic"},
                    {"demosaic", demosaic}, {"reference_demosaic", referenceDemosaic},
                    {"baseline_exposure", false}, {"embedded_exposure_match", false}, {"lens", false},
                    {"fbdd", 0}, {"sharpen", 0}, {"lut", nullptr}, {"half_size", false},
                    {"synthetic_noise", isSynthetic ? Json("independent_poisson_shot_plus_gaussian_read_in_linear_RGB_not_CFA") : Json(nullptr)}}}};
        if (status != ErrorCode::Success) throw std::runtime_error("denoise failed");
        report["output_fingerprint"] = fingerprint(output);
        if (request.value("cache_check", false)) {
            ImageData cached = source;
            WaveletDenoiseDiagnostics cachedDetails;
            const auto cachedStart = Clock::now();
            if (applyWaveletDenoise(cached, options, &cachedDetails, gpu, &cache, "quality-input") != ErrorCode::Success)
                throw std::runtime_error("cached denoise failed");
            report["cache"] = {{"filter_ms", milliseconds(cachedStart)}, {"diagnostics", diagnostics(cachedDetails)},
                               {"output_fingerprint", fingerprint(cached)}};
            if (fingerprint(cached) != fingerprint(output)) throw std::runtime_error("cached pixels changed");
        }
        report["regions"] = Json::array();
        for (const auto& region : spec.at("regions")) {
            const auto rect = denoise_quality::pixelRegion(source.width, source.height, region.at("rect").get<std::array<double, 4>>());
            const auto before = denoise_quality::measure(source, truth, rect);
            const auto after = denoise_quality::measure(output, truth, rect);
            Json row = {{"id", region.at("id")}, {"kind", region.value("kind", "unspecified")},
                        {"rect_pixels", {rect.x, rect.y, rect.width, rect.height}},
                        {"source_variation", metrics(before)}, {"output_variation", metrics(after)},
                        {"source_vs_reference", errors(before)}, {"output_vs_reference", errors(after)},
                        {"output_vs_source", errors(denoise_quality::measure(output, &source, rect))}};
            if (!request.at("crop_prefix").is_null()) {
                const auto prefix = request.at("crop_prefix").get<std::string>() + "-" + region.at("id").get<std::string>();
                row["source_crop"] = crop(source, rect, prefix + "-source.png", spec.value("view_ev", 0.));
                row["output_crop"] = crop(output, rect, prefix + "-output.png", spec.value("view_ev", 0.));
            }
            report["regions"].push_back(std::move(row));
        }
        if (request.contains("experiment_dir")) {
            const auto exportStart = Clock::now();
            report["experiment"] = denoise_experiment::exportBuffers(request.at("experiment_dir").get<std::string>(),
                source, output, truth, isSynthetic ? "" : request.at("assets").at("input").get<std::string>(),
                bayerDemosaic == "vng", request.value("experiment_display", false), options.processingVersion);
            report["experiment"]["export_ms_including_io"] = milliseconds(exportStart);
        }
        report["peak_rss_bytes"] = peakRssBytes();
        report["total_ms"] = milliseconds(start);
    } catch (const std::exception& error) {
        report["status"] = "ERROR";
        report["message"] = error.what();
        code = 1;
    }
    std::ofstream output(argv[2]);
    output << report.dump(2) << '\n';
    if (!output) return 2;
    return code;
}
