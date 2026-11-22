#include "agent_commands.h"
#include "raw_info.h"
#include "core/bsh_diagnostics.h"
#include "core/edit_recipe_params.h"
#include "core/pipeline.h"
#include "core/x3f_processor.h"
#include "platform/display_image.h"
#include "sony2fuji/edit_recipe.h"
#include "nlohmann/json.hpp"
#include <filesystem>
#include <charconv>
#include <cmath>
#include <cstring>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
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
        case SONY2FUJI_STATUS_CANCELLED: return "cancelled";
        case SONY2FUJI_STATUS_AI_NOT_READY: return "ai_not_ready";
    }
    return "processing_error";
}

sony2fuji_status renderStatusToFfi(RenderStatus status) noexcept {
    switch (status) {
        case RenderStatus::Ok: return SONY2FUJI_STATUS_OK;
        case RenderStatus::InvalidArgument: return SONY2FUJI_STATUS_INVALID_ARGUMENT;
        case RenderStatus::Unsupported: return SONY2FUJI_STATUS_UNSUPPORTED;
        case RenderStatus::IoError: return SONY2FUJI_STATUS_IO_ERROR;
        case RenderStatus::ProcessingError: return SONY2FUJI_STATUS_PROCESSING_ERROR;
        case RenderStatus::OutOfMemory: return SONY2FUJI_STATUS_OUT_OF_MEMORY;
        case RenderStatus::OutputIoError: return SONY2FUJI_STATUS_OUTPUT_IO_ERROR;
        case RenderStatus::Cancelled: return SONY2FUJI_STATUS_CANCELLED;
        case RenderStatus::AiNotReady: return SONY2FUJI_STATUS_AI_NOT_READY;
        default: return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
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
    auto probe = [&](const char* editsJson) {
        const std::string doc = std::string(
            R"({"schema_version":4,"input":{"path":"probe.dng"},"edits":{"exposure":{"mode":"scene"},)") +
            editsJson + R"(},"output":{"path":"probe.jpg","format":"jpeg"}})";
        return sony2fuji_apply_params(session, doc.c_str()) == SONY2FUJI_STATUS_OK;
    };
    return {{"wavelet_denoise", probe(R"("denoise":{"wavelet":{"enabled":true}})")},
        {"chroma_denoise", probe(R"("denoise":{"chroma_mode":1})")},
        {"lens_correction", probe(R"("lens_correction":{"distortion":true})")}};
}

bool rasterPath(const std::string& path) {
    auto extension = std::filesystem::u8path(path).extension().u8string();
    std::transform(extension.begin(), extension.end(), extension.begin(), [](unsigned char c) { return std::tolower(c); });
    return extension == ".jpg" || extension == ".jpeg" || extension == ".png" || extension == ".tif" ||
        extension == ".tiff" || extension == ".heif" || extension == ".heic";
}

bool rawPath(const std::string& path) {
    auto extension = std::filesystem::u8path(path).extension().u8string();
    std::transform(extension.begin(), extension.end(), extension.begin(), [](unsigned char c) { return std::tolower(c); });
    // 与 Mac 文件库的 RAW 后缀表一致，避免把 TIFF 结构 RAW 的 IFD0 缩略图当作原图。
    static const char* extensions[] = {".arw", ".arq", ".dng", ".nef", ".nrw", ".cr2", ".cr3", ".crw", ".raf",
        ".rw2", ".rwl", ".orf", ".pef", ".srw", ".raw", ".3fr", ".fff", ".iiq", ".mos", ".srf", ".sr2",
        ".mrw", ".kdc", ".dcr", ".erf", ".x3f"};
    for (const auto* candidate : extensions)
        if (extension == candidate) return true;
    return false;
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

void sniffImageSignature(const std::string& absolute, bool& rasterCandidate, bool& hdrCandidate) {
    std::ifstream file(std::filesystem::u8path(absolute), std::ios::binary);
    char signature[12]{};
    file.read(signature, sizeof(signature));
    const auto length = file.gcount();
    const bool jpeg = length >= 2 && static_cast<unsigned char>(signature[0]) == 0xff && static_cast<unsigned char>(signature[1]) == 0xd8;
    const bool heif = length >= 12 && std::string(signature + 4, 4) == "ftyp" &&
        (std::string(signature + 8, 4) == "heic" || std::string(signature + 8, 4) == "heix" ||
         std::string(signature + 8, 4) == "mif1" || std::string(signature + 8, 4) == "heif");
    const bool png = length >= 8 && std::string(signature, 8) == std::string("\x89PNG\r\n\x1a\n", 8);
    const bool tiff = length >= 4 &&
        ((signature[0] == 'I' && signature[1] == 'I' && (signature[2] == 42 || signature[2] == 43) && signature[3] == 0) ||
         (signature[0] == 'M' && signature[1] == 'M' && signature[2] == 0 && (signature[3] == 42 || signature[3] == 43)));
    hdrCandidate = jpeg || heif;
    rasterCandidate = hdrCandidate || png || tiff;
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
    OwnedPixelBuffer sdrRgba16{};
};

HDRCommandResult renderHDR(
    const EditRecipe& recipe,
    bool preview,
    bool analyze,
    const std::string& lensDatabase
) {
    HDRCommandResult result;
    HDRPair source,edited;
    const auto& settings=*recipe.hdr;
    sony2fuji_session* pointer=nullptr;
    result.status=sony2fuji_session_create(&pointer);
    const std::unique_ptr<sony2fuji_session,decltype(&sony2fuji_session_destroy)> session(pointer,sony2fuji_session_destroy);
    if (result.status==SONY2FUJI_STATUS_OK && settings.inputType=="raw" && !lensDatabase.empty())
        result.status=sony2fuji_session_set_lens_database(session.get(),lensDatabase.c_str());
    if (result.status!=SONY2FUJI_STATUS_OK) return result;
    const bool useV9 = recipe.schemaVersion >= 16;
    const auto requestV9 = useV9 ? recipe.toHDRRenderRequestV9() : sony2fuji_hdr_request_v9{};
    const auto requestV8 = useV9 ? requestV9.base : recipe.toHDRRenderRequest();
    const sony2fuji_hdr_request_v1* requestPtr = useV9
        ? &requestV9.base.base.base.base.base.base.base.base
        : &requestV8.base.base.base.base.base.base.base;
    if (settings.inputType=="proraw" && settings.hdrOutput && !preview && !analyze) {
        auto info=hdrInitial<sony2fuji_hdr_source_info_v1>();
        result.status=sony2fuji_hdr_probe_proraw(recipe.inputPath.c_str(),&info,&result.diagnostic);
        if (result.status!=SONY2FUJI_STATUS_OK) return result;
        auto config=hdrInitial<sony2fuji_hdr_export_config_v1>();
        config.jpeg_quality=recipe.jpegQuality; config.base_color=settings.baseColor;
        config.metadata_policy=SONY2FUJI_HDR_METADATA_ISO_XMP; config.metadata_source_path=recipe.inputPath.c_str();
        // 全零 source_sha256：导出内部在 validate 单次读取时自采冻结摘要，CLI 不再前置扫盘（C-10）。
        auto streamed=hdrInitial<sony2fuji_hdr_stream_result_v1>();
        const auto temporary=std::filesystem::temp_directory_path().u8string();
        result.status=sony2fuji_hdr_export_proraw(session.get(),recipe.inputPath.c_str(),
            requestPtr,&config,1,temporary.c_str(),recipe.outputPath.c_str(),&streamed,&result.diagnostic);
        result.sourceHeadroom=streamed.source_headroom; result.editedHeadroom=streamed.edited_headroom;
        return result;
    }
    auto options=hdrInitial<sony2fuji_hdr_decode_options_v1>(); options.intent=SONY2FUJI_INTENT_FINAL;
    if (settings.inputType=="raw") {
        sony2fuji_hdr_camera_development_v2 development{};
        development.base=settings.cameraDevelopment;
        development.base.lens_profile_id=settings.lensProfile.empty() ? nullptr : settings.lensProfile.c_str();
        if (!settings.cameraProfilePath.empty()) {
            development.base.version=2; development.base.struct_size=sizeof(development);
            development.profile_path=settings.cameraProfilePath.c_str();
            std::copy(settings.cameraProfileSHA256.begin(),settings.cameraProfileSHA256.end(),development.profile_sha256);
        }
        result.status=sony2fuji_hdr_decode_camera_raw_with_development(session.get(),recipe.inputPath.c_str(),
            &options,&development.base,&source.value,&result.diagnostic);
    } else if (settings.inputType=="proraw") {
        const auto temporary=std::filesystem::temp_directory_path().u8string();
        result.status=sony2fuji_hdr_decode_proraw(session.get(),recipe.inputPath.c_str(),&options,temporary.c_str(),&source.value,&result.diagnostic);
    } else result.status=sony2fuji_hdr_decode(recipe.inputPath.c_str(),&options,&source.value,&result.diagnostic);
    if (result.status==SONY2FUJI_STATUS_OK)
        result.status=sony2fuji_hdr_render(session.get(),&source.value,requestPtr,&edited.value,&result.diagnostic);
    if (result.status!=SONY2FUJI_STATUS_OK) return result;
    result.sourceHeadroom=edited.value.source_headroom; result.editedHeadroom=edited.value.hdr.content_headroom;
    if (analyze) {
        const auto& sdr = edited.value.sdr;
        if (!sdr.data || sdr.width == 0 || sdr.height == 0 ||
            sdr.pixel_format != SONY2FUJI_HDR_RGB32F_LINEAR) {
            result.status = SONY2FUJI_STATUS_PROCESSING_ERROR;
            return result;
        }
        ImageData linearImg(static_cast<int>(sdr.width), static_cast<int>(sdr.height));
        const uint8_t* srcBytes = static_cast<const uint8_t*>(sdr.data);
        const size_t rowBytes = static_cast<size_t>(sdr.width) * sizeof(RGB);
        for (uint32_t y = 0; y < sdr.height; ++y) {
            std::memcpy(
                linearImg.pixels.data() + static_cast<size_t>(y) * sdr.width,
                srcBytes + static_cast<size_t>(y) * sdr.stride_bytes,
                rowBytes);
        }
        result.sdrRgba16 = encodeRgba16BufferFromImageData(linearImg, /*linearToSrgb=*/true);
        if (!result.sdrRgba16.data) {
            result.status = SONY2FUJI_STATUS_OUT_OF_MEMORY;
            return result;
        }
    }
    if (analyze && !preview) {
        return result;
    }
    // 与客户端一致：相机 RAW 和 ProRAW 渲染型 DNG 不读原片元数据；
    // 跨平台元数据读取只认增益图和 ProRAW 容器，传入 NEF/CR3 等会让导出失败。
    const bool cameraRAW=settings.inputType=="raw";
    if (preview || !settings.hdrOutput) {
        auto config=hdrInitial<sony2fuji_hdr_sdr_export_config_v1>();
        config.output_format=preview ? SONY2FUJI_OUTPUT_PNG : recipe.outputFormat; config.quality=recipe.jpegQuality;
        const bool proRAWDNG=settings.inputType=="proraw" && config.output_format==SONY2FUJI_OUTPUT_DNG;
        config.metadata_source_path=cameraRAW || proRAWDNG ? nullptr : recipe.inputPath.c_str();
        std::copy_n(source.value.source_sha256,32,config.source_sha256);
        result.status=sony2fuji_hdr_export_sdr(&edited.value,&config,recipe.outputPath.c_str(),&result.diagnostic);
    } else {
        auto config=hdrInitial<sony2fuji_hdr_export_config_v1>();
        config.jpeg_quality=recipe.jpegQuality; config.base_color=recipe.hdr->baseColor;
        config.metadata_policy=SONY2FUJI_HDR_METADATA_ISO_XMP;
        config.metadata_source_path=cameraRAW ? nullptr : recipe.inputPath.c_str();
        std::copy_n(source.value.source_sha256,32,config.source_sha256);
        result.status=sony2fuji_hdr_export_jpeg(&edited.value,&config,recipe.outputPath.c_str(),&result.diagnostic);
    }
    return result;
}

Json runBshDiagnosticsOnRgba16(
    const OwnedPixelBuffer& rgba16,
    const std::vector<BshSampleQueryItem>& sampleQueries
) {
    sony2fuji_buffer buf{};
    buf.data = rgba16.data;
    buf.size_bytes = rgba16.sizeBytes;
    buf.width = rgba16.width;
    buf.height = rgba16.height;
    buf.stride_bytes = rgba16.strideBytes;
    buf.pixel_format = SONY2FUJI_PIXEL_RGBA16;

    sony2fuji_bsh_diagnosis diag{};
    diag.version = SONY2FUJI_BSH_DIAGNOSIS_VERSION;
    diag.struct_size = sizeof(diag);
    const auto dStatus = sony2fuji_diagnose_image(&buf, nullptr, &diag);
    if (dStatus != SONY2FUJI_STATUS_OK) {
        throw std::runtime_error("sony2fuji_diagnose_image failed");
    }

    std::vector<BshSampleEntry> samples;
    samples.reserve(sampleQueries.size());
    const float radiusNorm = 4.0f / static_cast<float>(std::max(buf.width, buf.height));
    for (const auto& qItem : sampleQueries) {
        sony2fuji_bsh_sample_query q{};
        q.version = SONY2FUJI_BSH_SAMPLE_VERSION;
        q.struct_size = sizeof(q);
        q.norm_x = qItem.normX;
        q.norm_y = qItem.normY;
        q.radius_norm = radiusNorm;
        q.reserved = 0;

        BshSampleEntry entry;
        entry.label = qItem.label;
        entry.normX = qItem.normX;
        entry.normY = qItem.normY;
        entry.result.version = SONY2FUJI_BSH_SAMPLE_VERSION;
        entry.result.struct_size = sizeof(entry.result);
        const auto sStatus = sony2fuji_sample_region_bsh(&buf, &q, &entry.result);
        if (sStatus != SONY2FUJI_STATUS_OK) {
            throw std::runtime_error("sony2fuji_sample_region_bsh failed");
        }
        samples.push_back(std::move(entry));
    }
    return Json::parse(bshDiagnosisToJsonString(diag, samples));
}

Json curveShapeToTransferJson(const sony2fuji_tone_curve_config& c) {
    Json pts = Json::array();
    if (c.mode == SONY2FUJI_CURVE_CUSTOM) {
        for (uint32_t i = 0; i < c.count; ++i) {
            pts.push_back({c.points[i].x, c.points[i].y});
        }
    }
    return {
        {"mode", c.mode == SONY2FUJI_CURVE_CUSTOM ? "custom" : "legacy"},
        {"points", std::move(pts)},
    };
}

Json gradingWheelToTransferJson(float hue, float sat, float lum, bool includeLuminance) {
    Json w = {{"hue", hue}, {"saturation", sat}};
    if (includeLuminance && lum != 0.0f) {
        w["luminance"] = lum;
    }
    return w;
}

Json recipeToTransferPayload(const EditRecipe& recipe) {
    static constexpr const char* kHslNames[SONY2FUJI_HSL_CHANNELS] = {
        "red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"
    };

    auto buildCurve = [&]() {
        Json out = curveShapeToTransferJson(recipe.toneCurve);
        const bool hasChannels = std::any_of(recipe.channelCurves.begin(), recipe.channelCurves.end(),
            [](const auto& c) { return c.mode == SONY2FUJI_CURVE_CUSTOM; });
        if (hasChannels) {
            out["channels"] = {
                {"red", curveShapeToTransferJson(recipe.channelCurves[0])},
                {"green", curveShapeToTransferJson(recipe.channelCurves[1])},
                {"blue", curveShapeToTransferJson(recipe.channelCurves[2])},
            };
        }
        return out;
    };

    auto buildParametric = [&]() -> Json {
        const auto& p = recipe.parametricCurve;
        return {
            {"highlights", p.highlights},
            {"lights", p.lights},
            {"darks", p.darks},
            {"shadows", p.shadows},
            {"split_shadow", p.split_shadow},
            {"split_midtone", p.split_midtone},
            {"split_highlight", p.split_highlight},
        };
    };

    if (recipe.hdr) {
        const auto& h = *recipe.hdr;
        const uint32_t hv = h.processingVersion;
        Json values = {
            {"light.exposure", recipe.exposureEv},
            {"light.contrast", recipe.contrast},
            {"light.highlights", recipe.highlights},
            {"light.shadows", recipe.shadows},
            {"color.saturation", recipe.saturation},
            {"hdr.relative_temperature", h.relativeTemperature},
            {"hdr.relative_tint", h.relativeTint},
            {"geometry.crop.x", recipe.geometry.crop_x},
            {"geometry.crop.y", recipe.geometry.crop_y},
            {"geometry.crop.width", recipe.geometry.crop_width},
            {"geometry.crop.height", recipe.geometry.crop_height},
            {"geometry.quarter_turns", recipe.geometry.quarter_turns},
            {"geometry.flip_horizontal", recipe.geometry.flip_horizontal != 0},
            {"geometry.flip_vertical", recipe.geometry.flip_vertical != 0},
            {"geometry.straighten_degrees", recipe.geometry.straighten_degrees},
            {"geometry.perspective.horizontal", recipe.perspective.horizontal},
            {"geometry.perspective.vertical", recipe.perspective.vertical},
        };
        if (hv >= 2) {
            values["tone.black_point"] = static_cast<double>(recipe.toneControls.black_point) * 100.0;
            values["tone.white_point"] = static_cast<double>(recipe.toneControls.white_point) * 100.0;
            values["light.s_curve"] = recipe.sCurve;
            values["light.curve"] = buildCurve();
        }
        if (hv >= 3) {
            values["color.vibrance"] = static_cast<double>(recipe.toneControls.vibrance) * 100.0;
            for (size_t i = 0; i < SONY2FUJI_HSL_CHANNELS; ++i) {
                values[std::string("color.hsl.hue.") + kHslNames[i]] = recipe.hsl.hue[i];
                values[std::string("color.hsl.saturation.") + kHslNames[i]] = recipe.hsl.saturation[i];
                values[std::string("color.hsl.lightness.") + kHslNames[i]] = recipe.hsl.lightness[i];
            }
            const bool v2Lum = hv >= 9;
            values["color.grading.shadows"] = gradingWheelToTransferJson(
                recipe.colorGrading.shadows_hue, recipe.colorGrading.shadows_saturation,
                recipe.colorGradingV2.shadows_luminance, v2Lum);
            values["color.grading.midtones"] = gradingWheelToTransferJson(
                recipe.colorGrading.midtones_hue, recipe.colorGrading.midtones_saturation,
                recipe.colorGradingV2.midtones_luminance, v2Lum);
            values["color.grading.highlights"] = gradingWheelToTransferJson(
                recipe.colorGrading.highlights_hue, recipe.colorGrading.highlights_saturation,
                recipe.colorGradingV2.highlights_luminance, v2Lum);
        }
        if (hv >= 4) {
            values["hdr.peak_limit_ev"] = h.peakLimitEV;
            values["hdr.sdr_exposure_ev"] = h.sdrExposureEV;
            values["hdr.sdr_contrast"] = static_cast<double>(h.sdrContrast) * 100.0;
            values["hdr.sdr_saturation"] = static_cast<double>(h.sdrSaturation) * 100.0;
        }
        if (hv >= 5) {
            values["effects.vignette.amount"] = recipe.effects.vignette_amount;
            values["effects.vignette.midpoint"] = recipe.effects.vignette_midpoint;
            values["effects.vignette.roundness"] = recipe.effects.vignette_roundness;
            values["effects.vignette.feather"] = recipe.effects.vignette_feather;
            values["effects.vignette.highlights"] = recipe.effects.vignette_highlights;
            values["effects.grain.amount"] = recipe.effects.grain_amount;
            values["effects.grain.size"] = recipe.effects.grain_size;
            values["effects.grain.roughness"] = recipe.effects.grain_roughness;
        }
        if (hv >= 6) {
            values["detail.sharpening"] = h.sharpening;
            values["effects.clarity"] = static_cast<double>(h.clarity) * 100.0;
            values["effects.dehaze"] = static_cast<double>(h.dehaze) * 100.0;
            values["detail.denoise.post_rgb"] = h.denoise;
        }
        if (hv >= 7) {
            if (!recipe.lookPath.empty() && h.lookSHA256.size() == 64) {
                const auto fname = std::filesystem::u8path(recipe.lookPath).filename().u8string();
                values["hdr.look"] = {
                    {"sha256", h.lookSHA256},
                    {"name", fname},
                    {"strength", recipe.lookStrength},
                };
            } else {
                values["hdr.look"] = nullptr;
            }
        }
        if (hv >= 9) {
            values["light.curve.apply_to_luminosity"] = recipe.curveApplyToLuminosity;
            values["light.curve.parametric"] = buildParametric();
            values["color.grading.global"] = gradingWheelToTransferJson(
                recipe.colorGradingV2.global_hue, recipe.colorGradingV2.global_saturation,
                recipe.colorGradingV2.global_luminance, true);
            values["color.grading.blending"] = recipe.colorGradingV2.blending;
            values["color.grading.balance"] = recipe.colorGradingV2.balance;
        }
        if (h.inputType == "raw") {
            const auto& cd = h.cameraDevelopment;
            values["hdr.camera_development"] = {
                {"version", 1},
                {"white_balance_mode", cd.white_balance == SONY2FUJI_HDR_CAMERA_WB_TEMPERATURE ? "temperature" : "as_shot"},
                {"temperature", cd.temperature},
                {"tint", cd.tint},
                {"exposure_reference", cd.exposure_reference == SONY2FUJI_HDR_CAMERA_EXPOSURE_SENSOR ? "sensor" : "metadata"},
                {"fbdd_level", cd.fbdd_level},
            };
        }
        return {
            {"payload_version", 2},
            {"scope_version", 2},
            {"source", {
                {"identifier", recipe.inputPath},
                {"is_raw", false},
                {"processing_version", 3},
                {"hdr_processing_version", hv},
            }},
            {"values", std::move(values)},
        };
    }

    const bool isRaw = !recipe.rasterInput;
    const char* expMode = recipe.exposureMode == SONY2FUJI_EXPOSURE_SCENE ? "scene"
        : recipe.exposureMode == SONY2FUJI_EXPOSURE_SENSOR ? "sensor" : "preview";
    Json lookRef = {{"kind", "neutral"}, {"id", nullptr}};
    if (!recipe.lookPath.empty()) {
        const auto fname = std::filesystem::u8path(recipe.lookPath).filename().u8string();
        if (!fname.empty() && fname != "." && fname != "..") {
            lookRef = {{"kind", "builtin"}, {"id", fname}};
        }
    }
    const char* waveletPreset = "detail";
    if (recipe.wavelet.enabled && recipe.wavelet.chroma == 72.0f && recipe.wavelet.coarse == 100.0f) {
        waveletPreset = "clean";
    }
    Json values = {
        {"looks.reference", std::move(lookRef)},
        {"looks.strength", recipe.lookStrength},
        {"light.exposure", recipe.exposureEv},
        {"light.exposure_mode", isRaw ? expMode : "sensor"},
        {"light.contrast", recipe.contrast},
        {"light.highlights", recipe.highlights},
        {"light.shadows", recipe.shadows},
        {"light.s_curve", recipe.toneCurve.mode == SONY2FUJI_CURVE_CUSTOM ? 0.0 : static_cast<double>(recipe.sCurve)},
        {"light.curve", buildCurve()},
        {"tone.black_point", static_cast<double>(recipe.toneControls.black_point) * 100.0},
        {"tone.white_point", static_cast<double>(recipe.toneControls.white_point) * 100.0},
        {"color.vibrance", static_cast<double>(recipe.toneControls.vibrance) * 100.0},
        {"color.saturation", recipe.saturation},
        {"color.grading.shadows", gradingWheelToTransferJson(
            recipe.colorGrading.shadows_hue, recipe.colorGrading.shadows_saturation,
            recipe.colorGradingV2.shadows_luminance, recipe.schemaVersion >= 17)},
        {"color.grading.midtones", gradingWheelToTransferJson(
            recipe.colorGrading.midtones_hue, recipe.colorGrading.midtones_saturation,
            recipe.colorGradingV2.midtones_luminance, recipe.schemaVersion >= 17)},
        {"color.grading.highlights", gradingWheelToTransferJson(
            recipe.colorGrading.highlights_hue, recipe.colorGrading.highlights_saturation,
            recipe.colorGradingV2.highlights_luminance, recipe.schemaVersion >= 17)},
        {"effects.clarity", static_cast<double>(recipe.atmosphere.clarity) * 100.0},
        {"effects.dehaze", static_cast<double>(recipe.atmosphere.dehaze) * 100.0},
        {"effects.vignette.amount", recipe.effects.vignette_amount},
        {"effects.vignette.midpoint", recipe.effects.vignette_midpoint},
        {"effects.vignette.roundness", recipe.effects.vignette_roundness},
        {"effects.vignette.feather", recipe.effects.vignette_feather},
        {"effects.vignette.highlights", recipe.effects.vignette_highlights},
        {"effects.grain.amount", recipe.effects.grain_amount},
        {"effects.grain.size", recipe.effects.grain_size},
        {"effects.grain.roughness", recipe.effects.grain_roughness},
        {"detail.sharpening", recipe.sharpening},
        {"detail.denoise.raw_level", isRaw ? recipe.rawNoiseReduction : 0},
        {"detail.denoise.post_rgb", 0.0},
        {"detail.denoise.chroma_mode", recipe.chromaDenoise},
        {"detail.denoise.wavelet", {
            {"enabled", recipe.wavelet.enabled != 0},
            {"luma", recipe.wavelet.luma},
            {"chroma", recipe.wavelet.chroma},
            {"coarse", recipe.wavelet.coarse},
            {"preset", waveletPreset},
        }},
        {"geometry.crop.x", recipe.geometry.crop_x},
        {"geometry.crop.y", recipe.geometry.crop_y},
        {"geometry.crop.width", recipe.geometry.crop_width},
        {"geometry.crop.height", recipe.geometry.crop_height},
        {"geometry.quarter_turns", recipe.geometry.quarter_turns},
        {"geometry.flip_horizontal", recipe.geometry.flip_horizontal != 0},
        {"geometry.flip_vertical", recipe.geometry.flip_vertical != 0},
        {"geometry.straighten_degrees", recipe.geometry.straighten_degrees},
        {"geometry.perspective.horizontal", recipe.perspective.horizontal},
        {"geometry.perspective.vertical", recipe.perspective.vertical},
        {"geometry.lens.distortion", recipe.lensDistortion},
        {"geometry.lens.tca", recipe.lensTca},
        {"geometry.lens.vignetting", recipe.lensVignetting},
        {"geometry.lens.auto_crop", recipe.lensAutoCrop},
        {"geometry.lens.profile_id", recipe.lensProfileId.empty() ? Json(nullptr) : Json(recipe.lensProfileId)},
    };
    if (!isRaw) {
        if (recipe.rasterRelativeWb) {
            values["color.white_balance.mode"] = "relative";
            values["color.white_balance.temperature_kelvin"] = recipe.temperatureKelvin;
            values["color.white_balance.tint"] = recipe.tint;
        } else {
            values["color.white_balance.mode"] = "none";
            values["color.white_balance.temperature_kelvin"] = nullptr;
            values["color.white_balance.tint"] = nullptr;
        }
    } else if (recipe.whiteBalanceMode == SONY2FUJI_WB_TEMPERATURE) {
        values["color.white_balance.mode"] = "temperature";
        values["color.white_balance.temperature_kelvin"] = recipe.temperatureKelvin;
        values["color.white_balance.tint"] = recipe.tint;
    } else {
        values["color.white_balance.mode"] = "camera";
        values["color.white_balance.temperature_kelvin"] = nullptr;
        values["color.white_balance.tint"] = nullptr;
    }
    for (size_t i = 0; i < SONY2FUJI_HSL_CHANNELS; ++i) {
        values[std::string("color.hsl.hue.") + kHslNames[i]] = recipe.hsl.hue[i];
        values[std::string("color.hsl.saturation.") + kHslNames[i]] = recipe.hsl.saturation[i];
        values[std::string("color.hsl.lightness.") + kHslNames[i]] = recipe.hsl.lightness[i];
    }
    if (recipe.schemaVersion >= 17) {
        values["light.curve.apply_to_luminosity"] = recipe.curveApplyToLuminosity;
        values["light.curve.parametric"] = buildParametric();
        values["color.grading.global"] = gradingWheelToTransferJson(
            recipe.colorGradingV2.global_hue, recipe.colorGradingV2.global_saturation,
            recipe.colorGradingV2.global_luminance, true);
        values["color.grading.blending"] = recipe.colorGradingV2.blending;
        values["color.grading.balance"] = recipe.colorGradingV2.balance;
    }
    const int procVer = static_cast<int>(recipe.processingVersion);
    return {
        {"payload_version", 1},
        {"scope_version", 1},
        {"source", {
            {"identifier", recipe.inputPath},
            {"is_raw", isRaw},
            {"processing_version", (procVer >= 1 && procVer <= 3) ? procVer : 1},
        }},
        {"values", std::move(values)},
    };
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
    bool jsonOutput = false, capabilities = false, printRecipe = false, printTransfer = false;
    bool info = false, preview = false, analyze = false;
    std::string recipeFile, inputFile, infoFile, previewFile, lensDatabase;
    std::vector<std::string> rawSamples;
    uint32_t previewEdge = 1280;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        jsonOutput |= arg == "--json";
        capabilities |= arg == "--capabilities";
        printRecipe |= arg == "--print-recipe";
        printTransfer |= arg == "--print-transfer";
        info |= arg == "--info";
        preview |= arg == "--preview";
        analyze |= arg == "--analyze";
    }
    const std::string command = capabilities ? "capabilities"
        : info ? "info"
        : printRecipe ? "validate_recipe"
        : printTransfer ? "print_transfer"
        : preview ? "preview"
        : analyze ? "analyze"
        : "export";
    auto fail = [&](const std::string& code, const std::string& message, const Json& status = nullptr) {
        if (jsonOutput || capabilities || info)
            std::cout << machineJson(envelope(command, nullptr, {{"code", code}, {"message", message}, {"status", status}})) << '\n';
        else std::cerr << message << '\n';
        return 1;
    };
    try {
        bool seenJson = false, seenCapabilities = false, seenPrint = false, seenPrintTransfer = false;
        bool seenAnalyze = false, seenEdge = false;
        for (int i = 1; i < argc; ++i) {
            const std::string arg = argv[i];
            if (arg == "--json" && !seenJson) seenJson = true;
            else if (arg == "--capabilities" && !seenCapabilities) seenCapabilities = true;
            else if (arg == "--print-recipe" && !seenPrint) seenPrint = true;
            else if (arg == "--print-transfer" && !seenPrintTransfer) seenPrintTransfer = true;
            else if (arg == "--analyze" && !seenAnalyze) seenAnalyze = true;
            else if (arg == "--recipe" && recipeFile.empty() && i + 1 < argc && argv[i + 1][0] != '-')
                recipeFile = argv[++i];
            else if (arg == "--input" && inputFile.empty() && i + 1 < argc && argv[i + 1][0] != '-')
                inputFile = argv[++i];
            else if (arg == "--info" && infoFile.empty() && i + 1 < argc && argv[i + 1][0] != '-')
                infoFile = argv[++i];
            else if (arg == "--preview" && previewFile.empty() && i + 1 < argc && argv[i + 1][0] != '-')
                previewFile = argv[++i];
            else if (arg == "--lens-database" && lensDatabase.empty() && i + 1 < argc && argv[i + 1][0] != '-')
                lensDatabase = argv[++i];
            else if (arg == "--sample" && i + 1 < argc)
                rawSamples.emplace_back(argv[++i]);
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
            if (!recipeFile.empty() || !inputFile.empty() || printRecipe || printTransfer || info || preview ||
                analyze || !rawSamples.empty() || seenEdge || !lensDatabase.empty())
                return fail("invalid_argument", "Capabilities cannot be combined with another command");
            Json inputs = {"raw"};
            Json raster = nullptr;
            Json versions={1,2,3,4,5},formats={"jpeg","png","dng"},hdr=nullptr;
            if (hdrAvailable()) {
                versions.push_back(6); formats.push_back("hdr_jpeg");
                hdr={{"processing_version",1},{"recipe_min_version",6},{"probe",true},{"decode",true},
                    {"processing_versions",{1,2,3,4,5,6,7,8}},{"tone_recipe_version",8},{"color_recipe_version",9},{"rendition_recipe_version",10},
                    {"effects_recipe_version",11},
                    {"detail_recipe_version",12},
                    {"look_recipe_version",13},{"look_profile","display-linear-srgb-v1"},
                    {"channel_curve_recipe_version",15},{"source_recipe_version",14},{"input_types",{"hdr_raster","raw"}},
                    {"output_formats",{"hdr_jpeg","jpeg","png","dng"}},
                    {"minimum_system",{{"macos","15.0"},{"ios","18.0"},{"android","26"},{"windows","10"}}},
                    {"protocols",{"apple_gain_map","iso_21496","ultra_hdr"}},
                    {"working_format","rgb32f_extended_linear_srgb"},{"backend","cpu"},{"gpu_force","unsupported"},
                    {"adjustments",{"exposure","relative_white_balance","contrast","highlights","shadows","saturation","geometry"}},
                    {"tone_adjustments",{"black_point","white_point","s_curve","curve"}},
                    {"color_adjustments",{"vibrance","hsl","color_grading"}},
                    {"detail_adjustments",{"sharpening","clarity","dehaze","denoise"}},
                    {"rendition_adjustments",{"peak_limit_ev","sdr_exposure_ev","sdr_contrast","sdr_saturation"}},
                    {"effects_adjustments",{"vignette","grain"}},
                    {"jpeg_export",{{"metadata",{"iso","xmp"}},{"base_colors",{"srgb","display_p3"}}}},
                    {"display",false},{"preview_rendition","sdr"}};
#if defined(SONY2FUJI_ENABLE_DNGSDK)
                hdr["input_types"].push_back("proraw");
#endif
            }
#if defined(__APPLE__) || defined(_WIN32)
            inputs.push_back("raster");
#if defined(_WIN32)
            raster = {{"formats", {"jpeg", "png", "tiff", "heif"}}, {"bits_per_component", {8, 16}},
#else
            raster = {{"formats", {"jpeg", "png", "tiff", "heif"}}, {"bits_per_component", {8, 16}},
#endif
                {"tiff_bits_per_component", {8, 16}},
                {"alpha", "opaque_only"}, {"dynamic_range", "sdr"}, {"color_space", "srgb"},
                {"backend", "cpu"}, {"max_pixels", 128000000}};
#endif
            if (hdrAvailable()) {
                inputs.push_back("hdr_raster");
#if defined(SONY2FUJI_ENABLE_DNGSDK)
                inputs.push_back("proraw");
#endif
            }
            versions.push_back(7);
            if (hdrAvailable()) for (int version : {8, 9, 10, 11, 12, 13, 14, 15, 16}) versions.push_back(version);
            versions.push_back(17);
            std::cout << machineJson(envelope(command, {{"recipe_versions", versions},
                {"commands", {"capabilities", "validate_recipe", "info", "preview", "export", "analyze", "print_transfer"}},
                {"input_types", inputs},
                {"raster_input", raster},
                {"hdr",hdr},
                {"x3f", {{"normal_available", sony2fuji_x3f_available() != 0},
                    {"recipe_min_version",7},{"modes",{"legacy","normal-v1"}}}},
                {"output_formats", formats}, {"exposure_modes", {"scene", "preview", "sensor"}},
                {"geometry_operations", {"crop", "quarter_turns", "flip_horizontal", "flip_vertical", "straighten", "perspective"}},
                {"edit_groups", {"exposure", "white_balance", "look", "geometry", "tone", "color", "color_grading", "detail", "hsl", "effects", "denoise", "lens_correction"}},
                {"tone_controls", {{"version", 1}, {"recipe_min_version", 5}, {"range", {-1,1}},
                    {"fields", {"tone.black_point","tone.white_point","color.vibrance"}}}},
                {"color_grading", {{"version",1},{"recipe_min_version",5},{"zones",{"shadows","midtones","highlights"}},
                    {"hue_degrees",{{"minimum",0},{"exclusive_maximum",360}}},{"saturation_range",{0,100}}}},
                {"tone_curve", {{"version",1},{"recipe_min_version",5},{"modes",{"legacy","custom"}},
                    {"channels",{"red","green","blue"}},{"max_points",33},{"interpolation","pchip"},{"fixed_endpoints",true},{"monotone",true}}},
                {"atmosphere", {{"version",1},{"recipe_min_version",5},{"range",{-1,1}},
                    {"fields",{"effects.clarity","effects.dehaze"}},{"backend","cpu"},
                    {"gpu_force","unsupported"},{"preview","complete_source"}}},
                {"optional_features", optionalFeatures()}})) << '\n';
            return 0;
        }
        if (info) {
            if (infoFile.empty() || !recipeFile.empty() || !inputFile.empty() || printRecipe || printTransfer ||
                preview || analyze || !rawSamples.empty() || seenEdge || !lensDatabase.empty())
                return fail("invalid_argument", "--info <image> requires one input and no recipe");
            const auto absolute = std::filesystem::absolute(std::filesystem::u8path(infoFile)).lexically_normal().u8string();
            const bool knownRaster=rasterPath(absolute);
            bool rasterCandidate=knownRaster, hdrCandidate=hdrCandidatePath(absolute);
            if (!knownRaster && !rawPath(absolute)) {
                sniffImageSignature(absolute, rasterCandidate, hdrCandidate);
            }
            if (rasterCandidate) {
                if (hdrCandidate) {
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
                if (status != SONY2FUJI_STATUS_OK && knownRaster)
                    return fail(statusCode(status), "Raster input requires a supported single-frame opaque SDR image", status);
                if (status == SONY2FUJI_STATUS_OK) {
                    const Json result = {{"input_path", absolute}, {"input_type", "raster"},
                        {"identified_size", {{"width", image.width}, {"height", image.height}, {"orientation", 1}}},
                        {"rendered_size", nullptr}, {"color_space", "srgb"},
                        {"bits_per_component", image.pixel_format == SONY2FUJI_PIXEL_RGBA16 ? 16 : 8},
                        {"camera", nullptr}, {"lens", nullptr}, {"capture", nullptr}, {"as_shot_white_balance", nullptr}};
                    sony2fuji_release_buffer(&image);
                    std::cout << machineJson(envelope(command, result)) << '\n';
                    return 0;
                }
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
        if (printTransfer) {
            if (recipeFile.empty() || !inputFile.empty() || preview || printRecipe || analyze ||
                !rawSamples.empty() || seenEdge || !lensDatabase.empty())
                return fail("invalid_argument", "--print-transfer requires --recipe <file> and cannot be combined with rendering");
        }
        if (!rawSamples.empty() && !analyze)
            return fail("invalid_argument", "--sample requires --analyze");
        if ((preview && (previewFile.empty() || printRecipe)) || (seenEdge && !preview && !analyze))
            return fail("invalid_argument", "Preview requires --preview <file> and cannot be combined with validation");
        if (analyze && printRecipe)
            return fail("invalid_argument", "--analyze cannot be combined with --print-recipe");
        if (!inputFile.empty() && !analyze)
            return fail("invalid_argument", "--input requires --analyze");
        if (!inputFile.empty() && !recipeFile.empty())
            return fail("invalid_argument", "--input cannot be combined with --recipe");
        if (recipeFile.empty() && inputFile.empty())
            return fail("invalid_argument", "--recipe <file> is required");

        std::vector<BshSampleQueryItem> sampleQueries;
        sampleQueries.reserve(rawSamples.size());
        for (const auto& rawSample : rawSamples) {
            BshSampleQueryItem item;
            std::string sampleErr;
            if (!parseBshSampleArg(rawSample, item, sampleErr)) {
                return fail("invalid_argument", sampleErr);
            }
            sampleQueries.push_back(std::move(item));
        }

        EditRecipe recipe;
        std::filesystem::path recipeDiskPath;
        if (!recipeFile.empty()) {
            recipeDiskPath = std::filesystem::u8path(recipeFile);
            std::ifstream file(recipeDiskPath, std::ios::binary);
            if (!file) return fail("io_error", "Cannot read recipe: " + recipeFile, SONY2FUJI_STATUS_IO_ERROR);
            std::string document(1024 * 1024 + 1, '\0');
            file.read(document.data(), static_cast<std::streamsize>(document.size()));
            document.resize(static_cast<size_t>(file.gcount()));
            if (file.bad()) return fail("io_error", "Cannot read recipe: " + recipeFile, SONY2FUJI_STATUS_IO_ERROR);
            std::string error;
            if (!parseEditRecipe(document, recipe, error)) return fail("invalid_recipe", error);
            if (recipe.hdr && !hdrAvailable()) return fail("unsupported","HDR requires macOS15/iOS18",SONY2FUJI_STATUS_UNSUPPORTED);
            if (printRecipe) {
                const auto normalized = serializeEditRecipe(recipe);
                std::cout << (jsonOutput ? machineJson(envelope(command, Json::parse(normalized))) + "\n" : normalized);
                return 0;
            }
            if (printTransfer) {
                const Json transfer = recipeToTransferPayload(recipe);
                std::cout << (jsonOutput ? machineJson(envelope(command, transfer)) + "\n" : transfer.dump(2) + "\n");
                return 0;
            }
            const auto directory = std::filesystem::absolute(recipeDiskPath).parent_path();
            auto resolve = [&](std::string& value) {
                if (!value.empty()) value = (directory / std::filesystem::u8path(value)).lexically_normal().u8string();
            };
            resolve(recipe.inputPath);
            resolve(recipe.outputPath);
            resolve(recipe.lookPath);
            if (recipe.hdr) resolve(recipe.hdr->cameraProfilePath);
            if (recipe.schemaVersion == 7 && !hasX3fSignature(recipe.inputPath))
                return fail("invalid_argument", "schema_version 7 requires an actual FOVb X3F source",
                    SONY2FUJI_STATUS_INVALID_ARGUMENT);
        } else {
            // In-memory neutral recipe for `--input <image> --analyze`.
            const auto absPath = std::filesystem::absolute(std::filesystem::u8path(inputFile)).lexically_normal();
            const std::string absolute = absPath.u8string();
            std::error_code fsErr;
            if (!std::filesystem::is_regular_file(absPath, fsErr) || fsErr) {
                return fail("io_error", "Cannot read input image: " + inputFile, SONY2FUJI_STATUS_IO_ERROR);
            }
            const bool knownRaster = rasterPath(absolute);
            bool rasterCandidate = knownRaster, hdrCandidate = hdrCandidatePath(absolute);
            if (!knownRaster && !rawPath(absolute)) {
                sniffImageSignature(absolute, rasterCandidate, hdrCandidate);
            }
            bool useHdr = false;
            if (rasterCandidate && hdrCandidate && hdrAvailable()) {
                auto hdrInfo = hdrInitial<sony2fuji_hdr_source_info_v1>();
                auto diag = hdrInitial<sony2fuji_hdr_diagnostic_v1>();
                const auto st = sony2fuji_hdr_probe(absolute.c_str(), &hdrInfo, &diag);
                if (st == SONY2FUJI_STATUS_OK) {
                    useHdr = true;
                } else if (diag.reason != SONY2FUJI_HDR_REASON_NOT_HDR) {
                    return fail(statusCode(st), "HDR input rejected; diagnostic reason=" + std::to_string(diag.reason), st);
                }
            }
            recipe.inputPath = absolute;
            recipe.outputFormat = SONY2FUJI_OUTPUT_PNG;
            recipe.outputLongEdge = previewEdge;
            if (useHdr) {
                recipe.schemaVersion = 6;
                recipe.hdr.emplace();
                recipe.hdr->inputType = "hdr_raster";
                recipe.hdr->hdrOutput = false;
                recipe.hdr->processingVersion = SONY2FUJI_HDR_PROCESSING_VERSION;
            } else if (rasterCandidate) {
                recipe.schemaVersion = 5;
                recipe.processingVersion = SONY2FUJI_PROCESSING_BASIC_V3;
                recipe.rasterInput = true;
                recipe.exposureMode = SONY2FUJI_EXPOSURE_SENSOR;
                recipe.whiteBalanceMode = SONY2FUJI_WB_CAMERA;
            } else {
                const bool x3f = hasX3fSignature(absolute) && sony2fuji_x3f_available() != 0;
                recipe.schemaVersion = x3f ? 7 : 5;
                recipe.x3fMode = x3f ? SONY2FUJI_X3F_NORMAL : SONY2FUJI_X3F_LEGACY;
                recipe.processingVersion = SONY2FUJI_PROCESSING_BASIC_V3;
                recipe.rasterInput = false;
                recipe.exposureMode = SONY2FUJI_EXPOSURE_PREVIEW;
                recipe.whiteBalanceMode = SONY2FUJI_WB_CAMERA;
            }
        }

        if (preview) {
            recipe.outputPath = std::filesystem::absolute(std::filesystem::u8path(previewFile)).lexically_normal().u8string();
            recipe.outputFormat = SONY2FUJI_OUTPUT_PNG;
            recipe.outputLongEdge = previewEdge;
        } else if (analyze) {
            recipe.outputLongEdge = previewEdge;
        }

        const bool writesOutput = preview || !analyze;
        if (writesOutput) {
            const auto output = std::filesystem::u8path(recipe.outputPath);
            const auto overwrites = [&](const std::filesystem::path& source) {
                std::error_code identityError;
                return std::filesystem::equivalent(source, output, identityError) ||
                    std::filesystem::weakly_canonical(source) == std::filesystem::weakly_canonical(output);
            };
            if (!recipeFile.empty() && overwrites(recipeDiskPath))
                return fail("invalid_argument", "Output must not overwrite the recipe", SONY2FUJI_STATUS_INVALID_ARGUMENT);
            if (overwrites(std::filesystem::u8path(recipe.inputPath)))
                return fail("invalid_argument", "Output must not overwrite the input", SONY2FUJI_STATUS_INVALID_ARGUMENT);
            if (!recipe.lookPath.empty() && overwrites(std::filesystem::u8path(recipe.lookPath)))
                return fail("invalid_argument", "Output must not overwrite the look", SONY2FUJI_STATUS_INVALID_ARGUMENT);
            if (recipe.hdr && !recipe.hdr->cameraProfilePath.empty() && overwrites(std::filesystem::u8path(recipe.hdr->cameraProfilePath)))
                return fail("invalid_argument", "Output must not overwrite the camera profile", SONY2FUJI_STATUS_INVALID_ARGUMENT);
            if (!lensDatabase.empty() && overwrites(std::filesystem::u8path(lensDatabase)))
                return fail("invalid_argument", "Output must not overwrite the lens database", SONY2FUJI_STATUS_INVALID_ARGUMENT);
        }

        sony2fuji_status status = SONY2FUJI_STATUS_OK;
        std::string sourceError;
        Json lensResult = nullptr;
        HDRCommandResult hdrResult;
        OwnedPixelBuffer sdrDiagRgba16;

        if (recipe.hdr) {
            DiagnosticsToStderr diagnostics;
            hdrResult = renderHDR(recipe, preview, analyze, lensDatabase);
            status = hdrResult.status;
        } else if (analyze) {
            DiagnosticsToStderr diagnostics;
            EditRecipe canonicalSource = recipe;
            if (canonicalSource.outputPath.empty()) {
                canonicalSource.outputPath = "unused-analyze.png";
                canonicalSource.outputFormat = SONY2FUJI_OUTPUT_PNG;
            }
            const std::string canonicalJson = serializeEditRecipe(canonicalSource);
            CanonicalSdrRecipe coreRecipe;
            std::string coreErr;
            if (!parseCanonicalSdrRecipe(canonicalJson, coreRecipe, coreErr, /*allowRasterLensCorrection=*/false)) {
                return fail("invalid_recipe", coreErr);
            }
            Pipeline pipeline;
            if (!lensDatabase.empty()) {
                status = renderStatusToFfi(pipeline.setLensDatabase(lensDatabase.c_str()));
            }
            if (status == SONY2FUJI_STATUS_OK) {
                status = renderStatusToFfi(pipeline.applyParams(canonicalJson.c_str()));
            }
            RenderParams params = coreRecipe.toRenderParams();
            params.intent = RenderIntent::Final;
            if (preview) {
                params.outputTarget = RenderOutputTarget::File;
                params.outputFormat = RenderOutputFormat::PNG;
                params.outputPath = recipe.outputPath;
            } else {
                params.outputTarget = RenderOutputTarget::Buffer;
                params.outputFormat = RenderOutputFormat::RGBA8;
                params.outputPath.clear();
            }
            OwnedPixelBuffer inputOwned;
            if (status == SONY2FUJI_STATUS_OK && recipe.rasterInput) {
                status = renderStatusToFfi(loadDisplayImage(recipe.inputPath.c_str(), inputOwned));
                if (status == SONY2FUJI_STATUS_OK) {
                    params.inputPixels = inputOwned.data;
                    params.inputWidth = inputOwned.width;
                    params.inputHeight = inputOwned.height;
                    params.inputPixelFormat = inputOwned.format;
                    params.inputColorSpace = ColorSpace::sRGB;
                    params.inputIsLinear = false;
                }
            }
            ImageData renderedImage;
            if (status == SONY2FUJI_STATUS_OK) {
                status = renderStatusToFfi(pipeline.processToImageData(params, renderedImage));
            }
            if (status != SONY2FUJI_STATUS_OK) {
                sourceError = pipeline.x3fError();
            }
            if (status == SONY2FUJI_STATUS_OK && recipe.schemaVersion >= 4 &&
                (recipe.lensDistortion || recipe.lensTca || recipe.lensVignetting)) {
                const auto& lr = pipeline.lensReport();
                const char* states[] = {"off", "matched", "no_database", "no_camera", "no_lens", "ambiguous",
                    "no_calibration", "missing_focal_length", "embedded_geometry", "unsupported_input"};
                const auto state = static_cast<unsigned>(lr.state);
                lensResult = {{"state", state < 10 ? states[state] : "unknown"},
                    {"applied_distortion", lr.appliedDistortion}, {"applied_tca", lr.appliedTCA},
                    {"applied_vignetting", lr.appliedVignetting}, {"crop_scale", lr.cropScale}, {"profile_id", lr.profile.id}};
            }
            if (status == SONY2FUJI_STATUS_OK) {
                sdrDiagRgba16 = encodeRgba16BufferFromImageData(renderedImage, /*linearToSrgb=*/false);
                if (!sdrDiagRgba16.data) {
                    status = SONY2FUJI_STATUS_OUT_OF_MEMORY;
                }
            }
        } else {
            DiagnosticsToStderr diagnostics;
            sony2fuji_session* pointer = nullptr;
            status = sony2fuji_session_create(&pointer);
            auto destroy = [](sony2fuji_session* session) { sony2fuji_session_destroy(session); };
            const std::unique_ptr<sony2fuji_session, decltype(destroy)> session(pointer, destroy);
            if (status == SONY2FUJI_STATUS_OK && !lensDatabase.empty())
                status = sony2fuji_session_set_lens_database(session.get(), lensDatabase.c_str());
            if (status == SONY2FUJI_STATUS_OK) {
                const std::string canonicalJson = serializeEditRecipe(recipe);
                status = sony2fuji_apply_params(session.get(), canonicalJson.c_str());
            }
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
            if (status != SONY2FUJI_STATUS_OK) sourceError = sony2fuji_session_x3f_error(session.get());
            if (status == SONY2FUJI_STATUS_OK && recipe.schemaVersion >= 4 &&
                (recipe.lensDistortion || recipe.lensTca || recipe.lensVignetting)) {
                sony2fuji_lens_report_v2 report{};
                if (sony2fuji_session_get_lens_report_v2(session.get(), &report) == SONY2FUJI_STATUS_OK) {
                    const char* states[] = {"off", "matched", "no_database", "no_camera", "no_lens", "ambiguous",
                        "no_calibration", "missing_focal_length", "embedded_geometry", "unsupported_input"};
                    const auto state = static_cast<unsigned>(report.base.state);
                    lensResult = {{"state", state < 10 ? states[state] : "unknown"},
                        {"applied_distortion", report.base.applied_distortion != 0}, {"applied_tca", report.base.applied_tca != 0},
                        {"applied_vignetting", report.applied_vignetting != 0}, {"crop_scale", report.base.crop_scale}, {"profile_id", report.base.profile.id}};
                }
            }
        }
        if (status != SONY2FUJI_STATUS_OK) return fail(statusCode(status), recipe.hdr ?
            "HDR processing failed; diagnostic reason="+std::to_string(hdrResult.diagnostic.reason) :
            (sourceError.empty() ? sony2fuji_status_message(status) : sourceError),status);

        if (analyze && !preview) {
            const OwnedPixelBuffer& diagBuf = recipe.hdr ? hdrResult.sdrRgba16 : sdrDiagRgba16;
            Json diagResult = runBshDiagnosticsOnRgba16(diagBuf, sampleQueries);
            if (jsonOutput) std::cout << machineJson(envelope(command, diagResult)) << '\n';
            else std::cout << diagResult.dump(2) + "\n";
            return 0;
        }

        Json result = {{"output_path", recipe.outputPath}, {"format", recipe.hdr && recipe.hdr->hdrOutput && !preview ? "hdr_jpeg" : formatName(recipe.outputFormat)}};
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
        if (analyze) {
            const OwnedPixelBuffer& diagBuf = recipe.hdr ? hdrResult.sdrRgba16 : sdrDiagRgba16;
            result["diagnostics"] = runBshDiagnosticsOnRgba16(diagBuf, sampleQueries);
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
