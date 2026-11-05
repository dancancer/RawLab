#include "core/proraw_source.h"
#include "core/processing_cancellation.h"
#include "core/hdr_jpeg.h"
#include "core/sha256.h"
#include <algorithm>
#include <cmath>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <fstream>
#include <cstdio>
#include <jpeglib.h>
#include <stdexcept>
#ifdef SONY2FUJI_TEST_DNGSDK
#include "dng_file_stream.h"
#include "dng_host.h"
#include "dng_info.h"
#include "dng_negative.h"
#include "dng_render.h"
#include "dng_image.h"
#include "dng_color_space.h"
#include "dng_tag_types.h"
#include "dng_image_writer.h"
#include "dng_ifd.h"
#include "dng_tag_values.h"
#include "dng_exceptions.h"
#endif

using namespace sony2fuji;
void check(bool condition, const char* message) { if (!condition) throw std::runtime_error(message); }
template<class T> T initialized() { T value{}; value.version = 1; value.struct_size = sizeof(value); return value; }
void verifySDRJPEG(const std::vector<uint8_t>& bytes, uint32_t width, uint32_t height) {
    jpeg_decompress_struct decoder{}; jpeg_error_mgr errors{};
    decoder.err = jpeg_std_error(&errors); jpeg_create_decompress(&decoder);
    jpeg_mem_src(&decoder, bytes.data(), bytes.size());
    check(jpeg_read_header(&decoder, TRUE) == JPEG_HEADER_OK, "Invalid SDR JPEG header");
    decoder.out_color_space = JCS_RGB; jpeg_start_decompress(&decoder);
    check(decoder.output_width == width && decoder.output_height == height, "Published SDR JPEG dimensions changed");
    std::vector<uint8_t> row(size_t(width) * 3);
    while (decoder.output_scanline < decoder.output_height) {
        auto* pixels = row.data(); check(jpeg_read_scanlines(&decoder, &pixels, 1) == 1, "Truncated SDR JPEG");
    }
    jpeg_finish_decompress(&decoder); jpeg_destroy_decompress(&decoder);
}
#ifdef SONY2FUJI_TEST_DNGSDK
// 使用 SDK 原生内存图像作独立基准，校验磁盘块的裁切、旋转和像素类型语义。
HDRImagePair reference(const char* path, uint32_t edge) {
    const auto nativePath = std::filesystem::u8path(path);
    dng_file_stream stream(nativePath.c_str());
    dng_host host;
    dng_info info; info.Parse(host, stream); info.PostParse(host);
    AutoPtr<dng_negative> negative(host.Make_dng_negative());
    negative->Parse(host, stream, info); negative->PostParse(host, stream, info);
    negative->ReadStage1Image(host, stream, info); negative->SynchronizeMetadata();
    dng_camera_profile profile;
    check(negative->GetProfileByID(dng_camera_profile_id("Apple Embedded Color Profile"), profile), "Missing reference profile");
    profile.SetName("Reference HDR");
    dng_camera_profile_dynamic_range range; range.fDynamicRange = 1; range.fHintMaxOutputValue = 4;
    profile.SetDynamicRangeInfo(range);
    AutoPtr<dng_camera_profile> copy(new dng_camera_profile()); *copy.Get() = profile;
    negative->AddProfile(copy);
    negative->BuildStage2Image(host); negative->BuildStage3Image(host);
    HDRImagePair pair;
    for (bool hdr : {true, false}) {
        dng_render renderer(host, *negative);
        renderer.SetFinalSpace(dng_space_sRGB_Linear::Get()); renderer.SetFinalPixelType(ttFloat);
        renderer.SetExposure(0); renderer.SetMaximumSize(edge);
        renderer.SetCameraProfileID(dng_camera_profile_id(hdr ? "Reference HDR" : "Apple Embedded Color Profile"));
        AutoPtr<dng_image> rendered(renderer.Render()); rendered->Rotate(negative->BaseOrientation());
        auto& output = hdr ? pair.hdr : pair.sdr;
        output = ImageData(rendered->Width(), rendered->Height());
        dng_pixel_buffer buffer;
        buffer.fArea = rendered->Bounds(); buffer.fPlane = 0; buffer.fPlanes = 3;
        buffer.fRowStep = output.width * 3; buffer.fColStep = 3; buffer.fPlaneStep = 1;
        buffer.fPixelType = ttFloat; buffer.fPixelSize = 4; buffer.fData = output.pixels.data(); buffer.fDirty = true;
        rendered->Get(buffer);
    }
    return pair;
}
void writeJXLCopy(const char* path, const std::filesystem::path& output) {
    check(!std::filesystem::exists(output), "JXL fixture output already exists");
    try {
        const auto input = std::filesystem::u8path(path);
        dng_file_stream stream(input.c_str()); dng_host host;
        dng_info info; info.Parse(host, stream); info.PostParse(host);
        AutoPtr<dng_negative> negative(host.Make_dng_negative());
        negative->Parse(host, stream, info); negative->PostParse(host, stream, info);
        negative->ReadStage1Image(host, stream, info);
        // 读取时不保留旧 JPEG 压缩数据；建立 Stage2 前启用保存，以保留原始线性化表和 Stage1。
        host.SetSaveDNGVersion(dngVersion_SaveDefault); host.SetSaveLinearDNG(false); host.SetKeepOriginalFile(false);
        negative->SynchronizeMetadata(); negative->BuildStage2Image(host); negative->BuildStage3Image(host);
        dng_image_writer writer; negative->LosslessCompressJXL(host, writer, false);
        dng_file_stream target(output.c_str(), true);
        writer.WriteDNG(host, target, *negative, nullptr, dngVersion_SaveDefault, false);
    } catch (const dng_exception& error) {
        throw std::runtime_error("Cannot generate JXL fixture: " + std::to_string(error.ErrorCode()));
    }
}
#endif
int main() {
    try {
        bool rejected = false;
        try { hdr::probeProRAW(TEST_FIXTURE_DIR "/bayer-demosaic.dng"); }
        catch (const hdr::Error&) { rejected = true; }
        check(rejected, "Ordinary DNG was accepted as ProRAW");
        const auto* input = std::getenv("RAWLAB_TEST_PRORAW");
        if (!input) { std::cout << "ProRAW rejection passed; real input not configured\n"; return 0; }
        const auto info = hdr::probeProRAW(input);
        check(info.width >= 3000 && info.height >= 3000 && info.orientation == 1,
            "ProRAW probe did not return the full oriented canvas");
        std::cout << "ProRAW native canvas " << info.width << 'x' << info.height << '\n';
        const auto temporary = std::filesystem::temp_directory_path() /
            ("rawlab-proraw-test-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
        std::filesystem::create_directory(temporary);
        struct Cleanup { std::filesystem::path path; ~Cleanup() { std::error_code e; std::filesystem::remove_all(path, e); } } cleanup{temporary};
        if (std::getenv("RAWLAB_TEST_PRORAW_SPACE_ONLY")) {
            const uint64_t pixels = uint64_t(info.width) * info.height;
            const auto available = std::filesystem::space(temporary).available;
            const uint64_t stage = pixels * 88 + (128ull << 20);
            check(available > stage && available < stage + pixels * 44 + (64ull << 20),
                "Space test requires enough disk for each phase but not their combined budget");
            sony2fuji_session* session = nullptr;
            check(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK, "Cannot create disk admission session");
            struct Session { sony2fuji_session* value; ~Session() { sony2fuji_session_destroy(value); } } owner{session};
            struct Monitor { std::filesystem::path path; bool began = false; } monitor{temporary};
            sony2fuji_session_set_cancellation_callback(session, [](void* value) -> int32_t {
                auto& monitor = *static_cast<Monitor*>(value);
                for (const auto& file : std::filesystem::directory_iterator(monitor.path)) {
                    if (file.path().filename().string().find("RawLab-HDR-") == 0) monitor.began = true;
                }
                // 旧实现会开始解码；立即中止，避免测试本身占满受限卷。
                return monitor.began;
            }, &monitor);
            auto request = initialized<sony2fuji_hdr_request_v1>();
            request.hdr_processing_version = 1; request.intent = SONY2FUJI_INTENT_FINAL;
            request.temperature = 6500; request.crop_width = request.crop_height = 1;
            auto config = initialized<sony2fuji_hdr_export_config_v1>();
            config.jpeg_quality = 95; config.base_color = SONY2FUJI_HDR_COLOR_DISPLAY_P3;
            config.metadata_policy = SONY2FUJI_HDR_METADATA_ISO_XMP; config.metadata_source_path = input;
            const auto digest = hash::sha256File(input);
            for (size_t i = 0; i < 32; ++i) config.source_sha256[i] = uint8_t(std::stoul(digest.substr(i * 2, 2), nullptr, 16));
            const auto output = temporary / "existing.jpg";
            { std::ofstream file(output); file << "existing destination"; }
            auto result = initialized<sony2fuji_hdr_stream_result_v1>();
            auto diagnostic = initialized<sony2fuji_hdr_diagnostic_v1>();
            const auto status = sony2fuji_hdr_export_proraw(session, input, &request, &config, 1,
                temporary.u8string().c_str(), output.u8string().c_str(), &result, &diagnostic);
            check(status == SONY2FUJI_STATUS_OUTPUT_IO_ERROR && !monitor.began,
                "Combined ProRAW disk budget was not rejected before decoder scratch creation");
            std::ifstream file(output); std::string contents{std::istreambuf_iterator<char>(file), {}};
            check(contents == "existing destination" && result.width == 0, "Disk rejection changed destination or result");
            std::cout << "PASS combined ProRAW disk admission before decode; destination preserved\n";
            return 0;
        }
        sony2fuji_hdr_decode_options_v1 options{};
        options.version = 1; options.struct_size = sizeof(options); options.long_edge = 512;
        const bool final = std::getenv("RAWLAB_TEST_PRORAW_FINAL") != nullptr;
        if (final) { options.intent = SONY2FUJI_INTENT_FINAL; options.long_edge = 0; }
        auto decoded = hdr::decodeProRAW(input, options, temporary);
        const auto& pair = decoded.pixels;
        check(std::max(pair.hdr.width, pair.hdr.height) == int(final ? std::max(info.width,info.height) : 512) && pair.hdr.width == pair.sdr.width &&
            pair.hdr.height == pair.sdr.height && pair.isProxy != final && pair.nativeWidth == info.width &&
            pair.nativeHeight == info.height && pair.decodeRevision == 2,
            "ProRAW preview lost dimensions or decoder identity");
        float maximum = 0;
        size_t above = 0;
        for (const auto& pixel : pair.hdr.pixels) {
            check(std::isfinite(pixel.r) && std::isfinite(pixel.g) && std::isfinite(pixel.b), "Nonfinite HDR pixel");
            maximum = std::max({maximum, pixel.r, pixel.g, pixel.b});
            if (std::max({pixel.r, pixel.g, pixel.b}) > 1) ++above;
        }
        std::cout << "HDR peak=" << maximum << ", above=" << above << std::endl;
        check(maximum > 0.1f, "ProRAW preview was empty");
        for (const auto& pixel : pair.sdr.pixels)
            check(std::isfinite(pixel.r) && pixel.r >= 0 && pixel.r <= 1 &&
                std::isfinite(pixel.g) && pixel.g >= 0 && pixel.g <= 1 &&
                std::isfinite(pixel.b) && pixel.b >= 0 && pixel.b <= 1, "ProRAW SDR base exceeded its gamut");
        check(decoded.info.headroom_kind == (final ? SONY2FUJI_HDR_HEADROOM_MEASURED : SONY2FUJI_HDR_HEADROOM_UNKNOWN) &&
            std::any_of(std::begin(decoded.info.source_sha256), std::end(decoded.info.source_sha256), [](auto x) { return x != 0; }),
            "ProRAW preview lost source hash or claimed full-source headroom");
        check(std::filesystem::is_empty(temporary), "ProRAW decode leaked scratch files");
#ifdef SONY2FUJI_TEST_DNGSDK
        if (!std::getenv("RAWLAB_TEST_PRORAW_SKIP_REFERENCE")) {
        const auto expected = reference(input, options.long_edge);
        for (bool hdr : {true, false}) {
            const auto& actual = hdr ? pair.hdr : pair.sdr;
            const auto& reference = hdr ? expected.hdr : expected.sdr;
            check(actual.width == reference.width && actual.height == reference.height, "SDK reference canvas differs");
            float difference = 0;
            for (size_t i = 0; i < actual.pixels.size(); ++i) {
                const auto a = actual.pixels[i], b = reference.pixels[i];
                difference = std::max({difference, std::abs(a.r-b.r), std::abs(a.g-b.g), std::abs(a.b-b.b)});
            }
            std::cout << (hdr ? "HDR" : "SDR") << " reference maximum error=" << difference << '\n';
            check(difference <= 1e-6f, "Disk-backed ProRAW pixels differ from native SDK reference");
        }
        }
#endif
        std::cout << "ProRAW " << (final ? "FINAL " : "preview ") << pair.hdr.width << 'x' << pair.hdr.height << ", peak=" << maximum
            << ", above-white=" << above << '\n';
        bool cancelled = false;
        {
            ProcessingCancellationScope cancellation({[](void*) -> int32_t { return 1; }, nullptr});
            try { hdr::decodeProRAW(input, options, temporary); } catch (const ProcessingCancelled&) { cancelled = true; }
        }
        check(cancelled && std::filesystem::is_empty(temporary), "Cancelled ProRAW decode leaked scratch or ignored cancellation");
        unsigned checks = 0;
        cancelled = false;
        {
            ProcessingCancellationScope cancellation({[](void* opaque) -> int32_t {
                return ++*static_cast<unsigned*>(opaque) > 1000;
            }, &checks});
            try { hdr::decodeProRAW(input, options, temporary); } catch (const ProcessingCancelled&) { cancelled = true; }
        }
        check(cancelled && checks > 1000 && std::filesystem::is_empty(temporary), "Mid-decode cancellation leaked SDK scratch");
#ifdef SONY2FUJI_TEST_DNGSDK
        if (std::getenv("RAWLAB_TEST_PRORAW_JXL")) {
            const auto copy = temporary / "lossless-jxl.dng";
            writeJXLCopy(input, copy);
            const auto copyPath = copy.u8string();
            {
                dng_file_stream stream(copy.c_str()); dng_host host; dng_info encoded;
                encoded.Parse(host, stream); encoded.PostParse(host);
                check(encoded.IsValidDNG() && encoded.fMainIndex >= 0 &&
                    encoded.fIFD[encoded.fMainIndex]->fCompression == ccJXL,
                    "Lossless fixture did not exercise JPEG XL decoding");
            }
            const auto jxl = hdr::decodeProRAW(copyPath.c_str(), options, temporary);
            for (bool high : {true, false}) {
                const auto& a = high ? pair.hdr : pair.sdr;
                const auto& b = high ? jxl.pixels.hdr : jxl.pixels.sdr;
                check(a.width == b.width && a.height == b.height, "JXL ProRAW canvas differs from original");
                float error = 0;
                for (size_t i = 0; i < a.pixels.size(); ++i) error = std::max({error,
                    std::abs(a.pixels[i].r-b.pixels[i].r), std::abs(a.pixels[i].g-b.pixels[i].g), std::abs(a.pixels[i].b-b.pixels[i].b)});
                std::cout << "Lossless JXL " << (high ? "HDR" : "SDR") << " maximum error=" << error << '\n';
                check(error <= 1e-6f, "JXL ProRAW changed source pixels");
            }
            std::filesystem::remove(copy);
            check(std::filesystem::is_empty(temporary), "JXL ProRAW decode leaked scratch");
        }
#endif
        auto diagnostic = initialized<sony2fuji_hdr_diagnostic_v1>();
        auto sourceInfo = initialized<sony2fuji_hdr_source_info_v1>();
        check(sony2fuji_hdr_probe_proraw(input, &sourceInfo, &diagnostic) == SONY2FUJI_STATUS_OK &&
            sourceInfo.container == SONY2FUJI_HDR_CONTAINER_PRORAW, "C ABI did not classify ProRAW explicitly");
        sony2fuji_session* session = nullptr;
        check(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK, "Cannot create ProRAW test session");
        struct Session { sony2fuji_session* value; ~Session() { sony2fuji_session_destroy(value); } } sessionCleanup{session};
        auto result = initialized<sony2fuji_hdr_image_pair_v1>();
        const auto temporaryPath = temporary.u8string();
        auto gpu = initialized<sony2fuji_gpu_config>(); gpu.mode = SONY2FUJI_GPU_FORCE;
        sony2fuji_session_set_gpu_config(session, &gpu);
        check(sony2fuji_hdr_decode_proraw(session, input, &options, temporaryPath.c_str(), &result, &diagnostic) ==
            SONY2FUJI_STATUS_UNSUPPORTED && diagnostic.reason == SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU,
            "ProRAW silently used CPU under GPU Force");
        gpu.mode = SONY2FUJI_GPU_AUTO; sony2fuji_session_set_gpu_config(session, &gpu);
        sony2fuji_session_set_cancellation_callback(session, [](void*) -> int32_t { return 1; }, nullptr);
        check(sony2fuji_hdr_decode_proraw(session, input, &options, temporaryPath.c_str(), &result, &diagnostic) ==
            SONY2FUJI_STATUS_CANCELLED && !result.owner_token, "Cancelled C ABI decode published an owner");
        sony2fuji_session_set_cancellation_callback(session, nullptr, nullptr);
        if (final && std::getenv("RAWLAB_TEST_PRORAW_STREAM")) {
            HDRRenderOptions edit; edit.longEdge = 1024; edit.exposureEV = .7f; edit.highlights = -20;
            edit.geometry.quarter_turns = 1; edit.geometry.flip_horizontal = true;
            const auto reference = renderHDRPair(pair, edit);
            for (bool hdr : {true, false}) {
                auto rows = hdr::openProRAW(input, temporary);
                const auto streamed = hdr::encodeStream(rows, edit, hdr, 93, SONY2FUJI_HDR_COLOR_DISPLAY_P3, temporary);
                const auto expected = hdr ? hdr::encodeJPEG(reference, 93, SONY2FUJI_HDR_COLOR_DISPLAY_P3) : hdr::encodeSDRJPEG(reference.sdr, 93);
                check(streamed.jpeg == expected, "Real ProRAW stream differs from full-frame JPEG");
                check(std::filesystem::is_empty(temporary), "Real ProRAW stream leaked SDK or codec scratch");
            }
            auto request = initialized<sony2fuji_hdr_request_v1>();
            request.hdr_processing_version = 1; request.intent = SONY2FUJI_INTENT_FINAL;
            request.temperature = 6500; request.crop_width = request.crop_height = 1;
            request.long_edge = 1024; request.exposure_ev = .7f; request.highlights = -20;
            request.quarter_turns = 1; request.flip_horizontal = 1;
            auto config = initialized<sony2fuji_hdr_export_config_v1>();
            config.jpeg_quality = 93; config.base_color = SONY2FUJI_HDR_COLOR_DISPLAY_P3;
            config.metadata_policy = SONY2FUJI_HDR_METADATA_ISO_XMP; config.metadata_source_path = input;
            std::copy_n(decoded.info.source_sha256, 32, config.source_sha256);
            auto exported = initialized<sony2fuji_hdr_stream_result_v1>();
            const auto output = (temporary / std::filesystem::u8path(u8"\u6210\u7247.jpg")).u8string();
            for (bool hdr : {true, false}) {
                const auto exportStatus = sony2fuji_hdr_export_proraw(session, input, &request, &config, hdr, temporaryPath.c_str(),
                    output.c_str(), &exported, &diagnostic);
                if (exportStatus != SONY2FUJI_STATUS_OK) std::cerr << "Export status=" << exportStatus << " reason=" << diagnostic.reason << " field=" << diagnostic.field << std::endl;
                check(exportStatus == SONY2FUJI_STATUS_OK, "C ABI ProRAW export failed");
                check(exported.width == uint32_t(reference.hdr.width) && exported.height == uint32_t(reference.hdr.height) &&
                    exported.native_width == info.width && exported.native_height == info.height && exported.decode_revision == 2,
                    "C ABI ProRAW export lost dimensions or source identity");
                std::ifstream file(std::filesystem::u8path(output), std::ios::binary);
                std::vector<uint8_t> bytes{std::istreambuf_iterator<char>(file), {}}; file.close();
                if (hdr) {
                    const auto image = hdr::decodeJPEG(bytes.data(), bytes.size());
                    check(image.width == int(exported.width) && image.height == int(exported.height), "Published ProRAW JPEG dimensions changed");
                } else verifySDRJPEG(bytes, exported.width, exported.height);
                if (const char* artifacts = std::getenv("RAWLAB_TEST_PRORAW_ARTIFACTS")) {
                    const auto target = std::filesystem::u8path(artifacts) /
                        ("proraw-" + std::to_string(info.width) + (hdr ? "-hdr.jpg" : "-sdr.jpg"));
                    std::filesystem::copy_file(std::filesystem::u8path(output), target, std::filesystem::copy_options::overwrite_existing);
                }
                config.source_sha256[0] ^= 1;
                check(sony2fuji_hdr_export_proraw(session, input, &request, &config, hdr, temporaryPath.c_str(),
                    output.c_str(), &exported, &diagnostic) == SONY2FUJI_STATUS_INVALID_ARGUMENT &&
                    diagnostic.reason == SONY2FUJI_HDR_REASON_SOURCE_CHANGED && exported.width == 0,
                    "ProRAW export accepted a stale source");
                config.source_sha256[0] ^= 1;
                std::ifstream preserved(std::filesystem::u8path(output), std::ios::binary);
                check(std::vector<uint8_t>{std::istreambuf_iterator<char>(preserved), {}} == bytes, "Failed ProRAW export replaced destination");
                preserved.close(); std::filesystem::remove(std::filesystem::u8path(output));
            }
            check(std::filesystem::is_empty(temporary), "ProRAW C ABI export left transaction files");
            std::cout << "ProRAW real-source byte-identical HDR/SDR stream, C ABI publication and source protection passed\n";
        }
        if (std::getenv("RAWLAB_TEST_PRORAW_NATIVE_EXPORT")) {
            // 清除完整配对参考图，单独执行产品使用的原生分块入口。
            decoded.pixels = HDRImagePair{};
            auto request = initialized<sony2fuji_hdr_request_v1>();
            request.hdr_processing_version = 1; request.intent = SONY2FUJI_INTENT_FINAL;
            request.temperature = 6500; request.crop_width = request.crop_height = 1;
            request.exposure_ev = .7f;
            auto config = initialized<sony2fuji_hdr_export_config_v1>();
            config.jpeg_quality = 93; config.base_color = SONY2FUJI_HDR_COLOR_DISPLAY_P3;
            config.metadata_policy = SONY2FUJI_HDR_METADATA_ISO_XMP; config.metadata_source_path = input;
            std::copy_n(decoded.info.source_sha256, 32, config.source_sha256);
            const auto output = (temporary / std::filesystem::u8path(u8"\u539f\u5c3a\u5bf8.jpg")).u8string();
            for (bool hdr : {true, false}) {
                auto exported = initialized<sony2fuji_hdr_stream_result_v1>();
                const auto status = sony2fuji_hdr_export_proraw(session, input, &request, &config, hdr, temporaryPath.c_str(),
                    output.c_str(), &exported, &diagnostic);
                if (status != SONY2FUJI_STATUS_OK) std::cerr << "Native export status=" << status << " reason=" << diagnostic.reason << std::endl;
                check(status == SONY2FUJI_STATUS_OK && exported.width == info.width && exported.height == info.height,
                    "Native-size ProRAW JPEG export failed");
                std::ifstream file(std::filesystem::u8path(output), std::ios::binary);
                std::vector<uint8_t> bytes{std::istreambuf_iterator<char>(file), {}}; file.close();
                if (hdr) {
                    const auto description = hdr::probeJPEG(bytes.data(),bytes.size());
                    check(description.width == info.width && description.height == info.height && description.headroom > 1,
                        "Native-size ProRAW JPEG lost HDR metadata");
                } else verifySDRJPEG(bytes,info.width,info.height);
                if (const char* artifacts = std::getenv("RAWLAB_TEST_PRORAW_ARTIFACTS"))
                    std::filesystem::copy_file(std::filesystem::u8path(output), std::filesystem::u8path(artifacts) /
                        ("proraw-" + std::to_string(info.width) + (hdr ? "-native-hdr.jpg" : "-native-sdr.jpg")),
                        std::filesystem::copy_options::overwrite_existing);
                std::filesystem::remove(std::filesystem::u8path(output));
            }
            check(std::filesystem::is_empty(temporary), "Native-size export leaked scratch");
            std::cout << "Native-size ProRAW HDR/SDR C ABI exports passed\n";
        }
        return 0;
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
