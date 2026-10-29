#include "agent_commands.h"
#include "raw_info.h"
#include "sony2fuji/edit_recipe.h"
#include "nlohmann/json.hpp"
#include <filesystem>
#include <charconv>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <algorithm>
#include <cctype>

namespace sony2fuji {
namespace {
using Json = nlohmann::json;

const char* statusCode(sony2fuji_status status) {
    switch (status) {
        case SONY2FUJI_STATUS_OK: return "ok";
        case SONY2FUJI_STATUS_INVALID_ARGUMENT: return "invalid_argument";
        case SONY2FUJI_STATUS_UNSUPPORTED: return "unsupported";
        case SONY2FUJI_STATUS_IO_ERROR: return "io_error";
        case SONY2FUJI_STATUS_PROCESSING_ERROR: return "processing_error";
        case SONY2FUJI_STATUS_OUT_OF_MEMORY: return "out_of_memory";
        case SONY2FUJI_STATUS_OUTPUT_IO_ERROR: return "output_io_error";
    }
    return "processing_error";
}

const char* formatName(sony2fuji_output_format format) {
    return format == SONY2FUJI_OUTPUT_PNG ? "png" : format == SONY2FUJI_OUTPUT_DNG ? "dng" : "jpeg";
}

Json envelope(const std::string& command, const Json& result, const Json& error = nullptr) {
    return {{"protocol_version", 1}, {"command", command}, {"ok", error.is_null()},
            {"result", result}, {"error", error}};
}

std::string machineJson(const Json& value) {
    // Invalid bytes in an argv/OS diagnostic still produce a valid JSON error.
    return value.dump(-1, ' ', false, Json::error_handler_t::replace);
}

Json optionalFeatures() {
    sony2fuji_session* session = nullptr;
    if (sony2fuji_session_create(&session) != SONY2FUJI_STATUS_OK) throw std::bad_alloc();
    const auto destroy = [](sony2fuji_session* value) { sony2fuji_session_destroy(value); };
    const std::unique_ptr<sony2fuji_session, decltype(destroy)> owned(session, destroy);
    sony2fuji_wavelet_denoise_config wavelet{SONY2FUJI_WAVELET_DENOISE_CONFIG_VERSION, sizeof(wavelet), 1, 0, 46, 50};
    sony2fuji_lens_correction_config lens{SONY2FUJI_LENS_CORRECTION_CONFIG_VERSION, sizeof(lens), 1, 0, 1, nullptr};
    return {{"wavelet_denoise", sony2fuji_session_set_wavelet_denoise(session, &wavelet) == SONY2FUJI_STATUS_OK},
        {"chroma_denoise", sony2fuji_session_set_chroma_denoise(session, 1) == SONY2FUJI_STATUS_OK},
        {"lens_correction", sony2fuji_session_set_lens_correction(session, &lens) == SONY2FUJI_STATUS_OK}};
}

bool rasterPath(const std::string& path) {
    auto extension = std::filesystem::u8path(path).extension().u8string();
    std::transform(extension.begin(), extension.end(), extension.begin(), [](unsigned char c) { return std::tolower(c); });
    return extension == ".jpg" || extension == ".jpeg" || extension == ".png" || extension == ".tif" ||
        extension == ".tiff" || extension == ".heif" || extension == ".heic";
}

bool hdrAvailable() {
#if defined(__APPLE__)
    if (__builtin_available(macOS 15.0,iOS 18.0,*)) return true;
#else
    return true;
#endif
    return false;
}

bool hdrCandidatePath(const std::string& path) {
    auto extension=std::filesystem::u8path(path).extension().u8string();
    std::transform(extension.begin(),extension.end(),extension.begin(),[](unsigned char c) { return std::tolower(c); });
    return extension==".jpg" || extension==".jpeg" || extension==".heif" || extension==".heic";
}

template<class T> T hdrInitial() { T value{}; value.version=1; value.struct_size=sizeof(value); return value; }
struct HDRPair {
    sony2fuji_hdr_image_pair_v1 value=hdrInitial<sony2fuji_hdr_image_pair_v1>();
    ~HDRPair() { sony2fuji_hdr_release_pair(&value); }
};
struct HDRCommandResult {
    sony2fuji_status status=SONY2FUJI_STATUS_OK;
    sony2fuji_hdr_diagnostic_v1 diagnostic=hdrInitial<sony2fuji_hdr_diagnostic_v1>();
    float sourceHeadroom=0,editedHeadroom=0;
};

HDRCommandResult renderHDR(const EditRecipe& recipe,bool preview) {
    HDRCommandResult result;
    HDRPair source,edited;
    auto options=hdrInitial<sony2fuji_hdr_decode_options_v1>(); options.intent=SONY2FUJI_INTENT_FINAL;
    result.status=sony2fuji_hdr_decode(recipe.inputPath.c_str(),&options,&source.value,&result.diagnostic);
    sony2fuji_session* pointer=nullptr;
    if (result.status==SONY2FUJI_STATUS_OK) result.status=sony2fuji_session_create(&pointer);
    const std::unique_ptr<sony2fuji_session,decltype(&sony2fuji_session_destroy)> session(pointer,sony2fuji_session_destroy);
    const auto request=recipe.toHDRRequest();
    if (result.status==SONY2FUJI_STATUS_OK)
        result.status=sony2fuji_hdr_render(session.get(),&source.value,&request,&edited.value,&result.diagnostic);
    if (result.status!=SONY2FUJI_STATUS_OK) return result;
    result.sourceHeadroom=edited.value.source_headroom; result.editedHeadroom=edited.value.hdr.content_headroom;
    if (preview) {
        auto config=hdrInitial<sony2fuji_hdr_sdr_export_config_v1>();
        config.output_format=SONY2FUJI_OUTPUT_PNG; config.quality=recipe.jpegQuality;
        config.metadata_source_path=recipe.inputPath.c_str();
        std::copy_n(source.value.source_sha256,32,config.source_sha256);
        result.status=sony2fuji_hdr_export_sdr(&edited.value,&config,recipe.outputPath.c_str(),&result.diagnostic);
    } else {
        auto config=hdrInitial<sony2fuji_hdr_export_config_v1>();
        config.jpeg_quality=recipe.jpegQuality; config.base_color=recipe.hdr->baseColor;
        config.metadata_policy=SONY2FUJI_HDR_METADATA_ISO_XMP; config.metadata_source_path=recipe.inputPath.c_str();
        std::copy_n(source.value.source_sha256,32,config.source_sha256);
        result.status=sony2fuji_hdr_export_jpeg(&edited.value,&config,recipe.outputPath.c_str(),&result.diagnostic);
    }
    return result;
}

// Core diagnostics must not contaminate the machine-readable stdout document.
class DiagnosticsToStderr {
public:
    DiagnosticsToStderr() : previous_(std::cout.rdbuf(std::cerr.rdbuf())) {}
    ~DiagnosticsToStderr() { std::cout.rdbuf(previous_); }
private:
    std::streambuf* previous_;
};

} // namespace

int runAgentCommands(int argc, char* argv[]) {
    bool jsonOutput = false, capabilities = false, printRecipe = false, info = false, preview = false;
    std::string recipeFile, infoFile, previewFile, lensDatabase;
    uint32_t previewEdge = 1280;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        jsonOutput |= arg == "--json";
        capabilities |= arg == "--capabilities";
        printRecipe |= arg == "--print-recipe";
        info |= arg == "--info";
        preview |= arg == "--preview";
    }
    const std::string command = capabilities ? "capabilities" : info ? "info" : printRecipe ? "validate_recipe" : preview ? "preview" : "export";
    auto fail = [&](const std::string& code, const std::string& message, const Json& status = nullptr) {
        if (jsonOutput || capabilities || info)
            std::cout << machineJson(envelope(command, nullptr, {{"code", code}, {"message", message}, {"status", status}})) << '\n';
        else std::cerr << message << '\n';
        return 1;
    };
    try {
        bool seenJson = false, seenCapabilities = false, seenPrint = false, seenEdge = false;
        for (int i = 1; i < argc; ++i) {
            const std::string arg = argv[i];
            if (arg == "--json" && !seenJson) seenJson = true;
            else if (arg == "--capabilities" && !seenCapabilities) seenCapabilities = true;
            else if (arg == "--print-recipe" && !seenPrint) seenPrint = true;
            else if (arg == "--recipe" && recipeFile.empty() && i + 1 < argc && argv[i + 1][0] != '-')
                recipeFile = argv[++i];
            else if (arg == "--info" && infoFile.empty() && i + 1 < argc && argv[i + 1][0] != '-')
                infoFile = argv[++i];
            else if (arg == "--preview" && previewFile.empty() && i + 1 < argc && argv[i + 1][0] != '-')
                previewFile = argv[++i];
            else if (arg == "--lens-database" && lensDatabase.empty() && i + 1 < argc && argv[i + 1][0] != '-')
                lensDatabase = argv[++i];
            else if (arg == "--long-edge" && !seenEdge && i + 1 < argc) {
                const std::string value = argv[++i];
                const auto parsed = std::from_chars(value.data(), value.data() + value.size(), previewEdge);
                if (parsed.ec != std::errc() || parsed.ptr != value.data() + value.size() || previewEdge == 0)
                    return fail("invalid_argument", "--long-edge must be a positive uint32 integer");
                seenEdge = true;
            }
            else return fail("invalid_argument", "Unexpected, duplicate or incomplete argument: " + arg);
        }
        if (capabilities) {
            if (!recipeFile.empty() || printRecipe || info || preview || seenEdge || !lensDatabase.empty()) return fail("invalid_argument", "Capabilities cannot be combined with another command");
            Json inputs = {"raw"};
            Json raster = nullptr;
            Json versions={1,2,3,4,5},formats={"jpeg","png","dng"},hdr=nullptr;
            if (hdrAvailable()) {
                versions.push_back(6); formats.push_back("hdr_jpeg");
                hdr={{"processing_version",1},{"recipe_min_version",6},{"probe",true},{"decode",true},
                    {"minimum_system",{{"macos","15.0"},{"ios","18.0"},{"android","26"},{"windows","10"}}},
                    {"protocols",{"apple_gain_map","iso_21496","ultra_hdr"}},
                    {"working_format","rgb32f_extended_linear_srgb"},{"backend","cpu"},{"gpu_force","unsupported"},
                    {"adjustments",{"exposure","relative_white_balance","contrast","highlights","shadows","saturation","geometry"}},
                    {"jpeg_export",{{"metadata",{"iso","xmp"}},{"base_colors",{"srgb","display_p3"}}}},
                    {"display",false},{"preview_rendition","sdr"}};
            }
#if defined(__APPLE__) || defined(_WIN32)
            inputs.push_back("raster");
#if defined(_WIN32)
            raster = {{"formats", {"jpeg", "png", "tiff"}}, {"bits_per_component", 8},
#else
            raster = {{"formats", {"jpeg", "png", "tiff", "heif"}}, {"bits_per_component", 8},
#endif
                {"alpha", "opaque_only"}, {"dynamic_range", "sdr"}, {"color_space", "srgb"},
                {"backend", "cpu"}, {"max_pixels", 128000000}};
#endif
            if (hdrAvailable()) inputs.push_back("hdr_raster");
            std::cout << machineJson(envelope(command, {{"recipe_versions", versions},
                {"commands", {"capabilities", "validate_recipe", "info", "preview", "export"}}, {"input_types", inputs},
                {"raster_input", raster},
                {"hdr",hdr},
                {"output_formats", formats}, {"exposure_modes", {"scene", "preview", "sensor"}},
                {"geometry_operations", {"crop", "quarter_turns", "flip_horizontal", "flip_vertical", "straighten", "perspective"}},
                {"edit_groups", {"exposure", "white_balance", "look", "geometry", "tone", "color", "color_grading", "detail", "hsl", "effects", "denoise", "lens_correction"}},
                {"tone_controls", {{"version", 1}, {"recipe_min_version", 5}, {"range", {-1,1}},
                    {"fields", {"tone.black_point","tone.white_point","color.vibrance"}}}},
                {"color_grading", {{"version",1},{"recipe_min_version",5},{"zones",{"shadows","midtones","highlights"}},
                    {"hue_degrees",{{"minimum",0},{"exclusive_maximum",360}}},{"saturation_range",{0,100}}}},
                {"tone_curve", {{"version",1},{"recipe_min_version",5},{"modes",{"legacy","custom"}},
                    {"max_points",33},{"interpolation","pchip"},{"fixed_endpoints",true},{"monotone",true}}},
                {"atmosphere", {{"version",1},{"recipe_min_version",5},{"range",{-1,1}},
                    {"fields",{"effects.clarity","effects.dehaze"}},{"backend","cpu"},
                    {"gpu_force","unsupported"},{"preview","complete_source"}}},
                {"optional_features", optionalFeatures()}})) << '\n';
            return 0;
        }
        if (info) {
            if (infoFile.empty() || !recipeFile.empty() || printRecipe || preview || seenEdge || !lensDatabase.empty())
                return fail("invalid_argument", "--info <image> requires one input and no recipe");
            const auto absolute = std::filesystem::absolute(std::filesystem::u8path(infoFile)).lexically_normal().u8string();
            if (rasterPath(absolute)) {
                if (hdrCandidatePath(absolute)) {
                    auto hdr=hdrInitial<sony2fuji_hdr_source_info_v1>();
                    auto diagnostic=hdrInitial<sony2fuji_hdr_diagnostic_v1>();
                    const auto status=sony2fuji_hdr_probe(absolute.c_str(),&hdr,&diagnostic);
                    if (status==SONY2FUJI_STATUS_OK) {
                        static const char hex[]="0123456789abcdef";
                        std::string sha; sha.reserve(64);
                        for (uint8_t byte:hdr.source_sha256) { sha.push_back(hex[byte>>4]); sha.push_back(hex[byte&15]); }
                        Json result={{"input_path",absolute},{"input_type","hdr_raster"},
                            {"identified_size",{{"width",hdr.width},{"height",hdr.height},{"orientation",hdr.orientation}}},
                            {"rendered_size",nullptr},{"color_space","extended_linear_srgb"},{"bits_per_component",32},
                            {"hdr_protocol",hdr.protocol},{"content_headroom",hdr.content_headroom},
                            {"headroom_kind",hdr.headroom_kind},{"source_sha256",sha},
                            {"camera",nullptr},{"lens",nullptr},{"capture",nullptr},{"as_shot_white_balance",nullptr}};
                        std::cout<<machineJson(envelope(command,result))<<'\n'; return 0;
                    }
                    if (diagnostic.reason!=SONY2FUJI_HDR_REASON_NOT_HDR)
                        return fail(statusCode(status),"HDR input rejected; diagnostic reason="+std::to_string(diagnostic.reason),status);
                }
                sony2fuji_buffer image{};
                const auto status = sony2fuji_load_display_image(absolute.c_str(), &image);
                if (status != SONY2FUJI_STATUS_OK)
                    return fail(statusCode(status), "Raster input requires a supported single-frame opaque 8-bit SDR image", status);
                const Json result = {{"input_path", absolute}, {"input_type", "raster"},
                    {"identified_size", {{"width", image.width}, {"height", image.height}, {"orientation", 1}}},
                    {"rendered_size", nullptr}, {"color_space", "srgb"}, {"bits_per_component", 8},
                    {"camera", nullptr}, {"lens", nullptr}, {"capture", nullptr}, {"as_shot_white_balance", nullptr}};
                sony2fuji_release_buffer(&image);
                std::cout << machineJson(envelope(command, result)) << '\n';
                return 0;
            }
            RawInfoResult inspected;
            {
                DiagnosticsToStderr diagnostics;
                inspected = inspectRawInfo(absolute);
            }
            if (inspected.status != SONY2FUJI_STATUS_OK)
                return fail(statusCode(inspected.status), inspected.message, inspected.status);
            std::cout << machineJson(envelope(command, inspected.result)) << '\n';
            return 0;
        }
        if ((preview && (previewFile.empty() || printRecipe)) || (seenEdge && !preview))
            return fail("invalid_argument", "Preview requires --preview <file> and cannot be combined with validation");
        if (recipeFile.empty()) return fail("invalid_argument", "--recipe <file> is required");
        const auto path = std::filesystem::u8path(recipeFile);
        std::ifstream file(path, std::ios::binary);
        if (!file) return fail("io_error", "Cannot read recipe: " + recipeFile, SONY2FUJI_STATUS_IO_ERROR);
        std::string document(1024 * 1024 + 1, '\0');
        file.read(document.data(), static_cast<std::streamsize>(document.size()));
        document.resize(static_cast<size_t>(file.gcount()));
        if (file.bad()) return fail("io_error", "Cannot read recipe: " + recipeFile, SONY2FUJI_STATUS_IO_ERROR);
        EditRecipe recipe;
        std::string error;
        if (!parseEditRecipe(document, recipe, error)) return fail("invalid_recipe", error);
        if (recipe.hdr && !hdrAvailable()) return fail("unsupported","HDR requires macOS15/iOS18",SONY2FUJI_STATUS_UNSUPPORTED);
        if (recipe.hdr && !lensDatabase.empty()) return fail("invalid_argument","HDR recipes do not support --lens-database");
        if (printRecipe) {
            const auto normalized = serializeEditRecipe(recipe);
            std::cout << (jsonOutput ? machineJson(envelope(command, Json::parse(normalized))) + "\n" : normalized);
            return 0;
        }
        const auto directory = std::filesystem::absolute(path).parent_path();
        auto resolve = [&](std::string& value) {
            if (!value.empty()) value = (directory / std::filesystem::u8path(value)).lexically_normal().u8string();
        };
        resolve(recipe.inputPath);
        resolve(recipe.outputPath);
        resolve(recipe.lookPath);
        if (preview) {
            recipe.outputPath = std::filesystem::absolute(std::filesystem::u8path(previewFile)).lexically_normal().u8string();
            recipe.outputFormat = SONY2FUJI_OUTPUT_PNG;
            recipe.outputLongEdge = previewEdge;
        }
        const auto output = std::filesystem::u8path(recipe.outputPath);
        const auto overwrites = [&](const std::filesystem::path& source) {
            std::error_code identityError;
            return std::filesystem::equivalent(source, output, identityError) ||
                std::filesystem::weakly_canonical(source) == std::filesystem::weakly_canonical(output);
        };
        if (overwrites(path))
            return fail("invalid_argument", "Output must not overwrite the recipe", SONY2FUJI_STATUS_INVALID_ARGUMENT);
        if (overwrites(std::filesystem::u8path(recipe.inputPath)))
            return fail("invalid_argument", "Output must not overwrite the input", SONY2FUJI_STATUS_INVALID_ARGUMENT);
        if (!recipe.lookPath.empty() && overwrites(std::filesystem::u8path(recipe.lookPath)))
            return fail("invalid_argument", "Output must not overwrite the look", SONY2FUJI_STATUS_INVALID_ARGUMENT);
        sony2fuji_status status;
        Json lensResult = nullptr;
        HDRCommandResult hdrResult;
        if (recipe.hdr) {
            DiagnosticsToStderr diagnostics;
            hdrResult=renderHDR(recipe,preview); status=hdrResult.status;
        } else {
            DiagnosticsToStderr diagnostics;
            sony2fuji_session* pointer = nullptr;
            status = sony2fuji_session_create(&pointer);
            auto destroy = [](sony2fuji_session* session) { sony2fuji_session_destroy(session); };
            const std::unique_ptr<sony2fuji_session, decltype(destroy)> session(pointer, destroy);
            if (status == SONY2FUJI_STATUS_OK)
                status = sony2fuji_session_set_processing_version(session.get(), recipe.processingVersion);
            if (status == SONY2FUJI_STATUS_OK && !lensDatabase.empty())
                status = sony2fuji_session_set_lens_database(session.get(), lensDatabase.c_str());
            if (status == SONY2FUJI_STATUS_OK)
                status = sony2fuji_session_set_raw_exposure_mode(session.get(), recipe.exposureMode);
            if (status == SONY2FUJI_STATUS_OK)
                status = sony2fuji_session_set_hsl(session.get(), &recipe.hsl);
            if (status == SONY2FUJI_STATUS_OK)
                status = sony2fuji_session_set_tone_controls(session.get(), &recipe.toneControls);
            if (status == SONY2FUJI_STATUS_OK)
                status = sony2fuji_session_set_atmosphere(session.get(), &recipe.atmosphere);
            if (status == SONY2FUJI_STATUS_OK)
                status = sony2fuji_session_set_color_grading(session.get(), &recipe.colorGrading);
            if (status == SONY2FUJI_STATUS_OK)
                status = sony2fuji_session_set_tone_curve(session.get(), &recipe.toneCurve);
            if (status == SONY2FUJI_STATUS_OK)
                status = sony2fuji_session_set_photo_effects(session.get(), &recipe.effects);
            if (status == SONY2FUJI_STATUS_OK)
                status = sony2fuji_session_set_wavelet_denoise(session.get(), &recipe.wavelet);
            if (status == SONY2FUJI_STATUS_OK)
                status = sony2fuji_session_set_chroma_denoise(session.get(), recipe.chromaDenoise);
            if (status == SONY2FUJI_STATUS_OK)
                status = sony2fuji_session_set_raw_noise_reduction(session.get(), recipe.rawNoiseReduction);
            sony2fuji_lens_correction_config lens{SONY2FUJI_LENS_CORRECTION_CONFIG_VERSION,
                sizeof(sony2fuji_lens_correction_config), recipe.lensDistortion, recipe.lensTca,
                recipe.lensAutoCrop, recipe.lensProfileId.empty() ? nullptr : recipe.lensProfileId.c_str()};
            if (status == SONY2FUJI_STATUS_OK)
                status = sony2fuji_session_set_lens_correction(session.get(), &lens);
            if (status == SONY2FUJI_STATUS_OK)
                status = sony2fuji_session_set_geometry(session.get(), &recipe.geometry);
            if (status == SONY2FUJI_STATUS_OK)
                status = sony2fuji_session_set_perspective(session.get(), &recipe.perspective);
            auto request = recipe.toRequest();
            sony2fuji_buffer image{};
            const auto release = [](sony2fuji_buffer* value) { sony2fuji_release_buffer(value); };
            const std::unique_ptr<sony2fuji_buffer, decltype(release)> decoded(&image, release);
            if (status == SONY2FUJI_STATUS_OK && recipe.rasterInput) {
                status = sony2fuji_load_display_image(recipe.inputPath.c_str(), &image);
                request.input_pixels = image.data;
                request.input_width = image.width;
                request.input_height = image.height;
                request.input_pixel_format = image.pixel_format;
                request.input_color_space = SONY2FUJI_COLOR_SRGB;
                request.input_is_linear = 0;
            }
            if (status == SONY2FUJI_STATUS_OK) status = sony2fuji_process(session.get(), &request, nullptr);
            if (status == SONY2FUJI_STATUS_OK && recipe.schemaVersion >= 4 &&
                (recipe.lensDistortion || recipe.lensTca)) {
                sony2fuji_lens_report report{};
                if (sony2fuji_session_get_lens_report(session.get(), &report) == SONY2FUJI_STATUS_OK) {
                    const char* states[] = {"off", "matched", "no_database", "no_camera", "no_lens", "ambiguous",
                        "no_calibration", "missing_focal_length", "embedded_geometry", "unsupported_input"};
                    const auto state = static_cast<unsigned>(report.state);
                    lensResult = {{"state", state < 10 ? states[state] : "unknown"},
                        {"applied_distortion", report.applied_distortion != 0}, {"applied_tca", report.applied_tca != 0},
                        {"crop_scale", report.crop_scale}, {"profile_id", report.profile.id}};
                }
            }
        }
        if (status != SONY2FUJI_STATUS_OK) return fail(statusCode(status), recipe.hdr ?
            "HDR processing failed; diagnostic reason="+std::to_string(hdrResult.diagnostic.reason) : sony2fuji_status_message(status),status);
        Json result = {{"output_path", recipe.outputPath}, {"format", recipe.hdr && !preview ? "hdr_jpeg" : formatName(recipe.outputFormat)}};
        if (recipe.hdr) {
            result["source_headroom"]=hdrResult.sourceHeadroom; result["edited_headroom"]=hdrResult.editedHeadroom;
            if (preview) result["rendition"]="sdr";
        }
        if (!lensResult.is_null()) result["lens_correction"] = std::move(lensResult);
        if (preview) {
            // Use exact FINAL + no-upscale sizing, so the preview is the final
            // result at the requested size, without interactive approximations.
            std::ifstream png(std::filesystem::u8path(recipe.outputPath), std::ios::binary);
            unsigned char header[24]{};
            png.read(reinterpret_cast<char*>(header), sizeof(header));
            if (png.gcount() != sizeof(header)) return fail("output_io_error", "Cannot inspect written preview", SONY2FUJI_STATUS_OUTPUT_IO_ERROR);
            auto dimension = [&](int offset) {
                return (uint32_t(header[offset]) << 24) | (uint32_t(header[offset + 1]) << 16) |
                    (uint32_t(header[offset + 2]) << 8) | uint32_t(header[offset + 3]);
            };
            result["width"] = dimension(16);
            result["height"] = dimension(20);
            result["long_edge"] = previewEdge;
            result["quality"] = "exact";
        }
        if (jsonOutput) std::cout << machineJson(envelope(command, result)) << '\n';
        else std::cout << "Saved: " << recipe.outputPath << '\n';
        return 0;
    } catch (const std::bad_alloc&) {
        return fail("out_of_memory", "Out of memory", SONY2FUJI_STATUS_OUT_OF_MEMORY);
    } catch (const std::filesystem::filesystem_error& exception) {
        return fail("io_error", exception.what(), SONY2FUJI_STATUS_IO_ERROR);
    } catch (const std::exception& exception) {
        return fail("processing_error", exception.what(), SONY2FUJI_STATUS_PROCESSING_ERROR);
    }
}
} // namespace sony2fuji
