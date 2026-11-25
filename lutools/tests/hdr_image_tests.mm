#include "test_harness.h"
#include "sony2fuji/ffi/sony2fuji_hdr.h"
#include "platform/hdr_image.h"
#include "core/hdr_jpeg.h"
#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <vector>
#include <tiffio.h>

namespace {
using rawlab::test::require;
template<class T> T init() { T v{}; v.version=1; v.struct_size=sizeof(v); return v; }

}
#include "hdr_codec/numeric_acceptance.h"
namespace {

NSData* fixture(bool changed=false) API_AVAILABLE(macos(15.0), ios(18.0)) {
    std::vector<float> h(64 * 32 * 4), s(h.size());
    for (size_t i=0; i<h.size(); ++i) {
        const float base[] = {.18f,.5f,.8f,1};
        s[i]=base[i%4]; h[i]=i%4==3 ? 1 : s[i]*(1+float(i/4%64/16)+(changed ? .25f : 0));
    }
    CGColorSpaceRef linear = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
    CIImage* hdr = [CIImage imageWithBitmapData:[NSData dataWithBytes:h.data() length:h.size()*4]
        bytesPerRow:64*16 size:CGSizeMake(64,32) format:kCIFormatRGBAf colorSpace:linear];
    CIImage* sdr = [CIImage imageWithBitmapData:[NSData dataWithBytes:s.data() length:s.size()*4]
        bytesPerRow:64*16 size:CGSizeMake(64,32) format:kCIFormatRGBAf colorSpace:linear];
    CIContext* context = [CIContext contextWithOptions:@{kCIContextWorkingFormat:@(kCIFormatRGBAf)}];
    CGImageRef image = [context createCGImage:hdr fromRect:hdr.extent format:kCIFormatRGBAf colorSpace:linear];
    CGImageRef tagged = image ? CGImageCreateCopyWithContentHeadroom(4,image) : nullptr;
    require(tagged, "cannot author HDR fixture");
    hdr = [CIImage imageWithCGImage:tagged];
    CGColorSpaceRef srgb=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    NSData* data=[context JPEGRepresentationOfImage:sdr colorSpace:srgb options:@{kCIImageRepresentationHDRImage:hdr,
        (__bridge NSString*)kCGImageDestinationLossyCompressionQuality:@.98}];
    CGImageRelease(tagged); CGImageRelease(image); CGColorSpaceRelease(linear); CGColorSpaceRelease(srgb);
    require(data.length>0,"cannot encode HDR fixture"); return data;
}

void tiledExports(NSURL* directory) API_AVAILABLE(macos(15.0), ios(18.0)) {
    using namespace sony2fuji;
    namespace fs = std::filesystem;
    require(sony2fuji_hdr_heif_export_available() != 0, "Tiled HEIF acceptance requires a working HEIF codec");
    HDRImagePair source;
    source.hdr = ImageData(529, 317); source.sdr = ImageData(529, 317);
    source.nativeWidth = 529; source.nativeHeight = 317; source.sourceHeadroom = 8;
    for (int y = 0; y < 317; ++y) for (int x = 0; x < 529; ++x) {
        const float r = .05f + .75f * x / 528, g = .03f + .7f * y / 316;
        source.sdr.at(x, y) = {r, g, .12f};
        source.hdr.at(x, y) = {r * 8, g * 2, .25f};
    }
    const auto root = fs::path(directory.fileSystemRepresentation);
    const auto opaqueSource = root / "camera-source.raw";
    std::ofstream(opaqueSource) << "Decoded by the camera backend, without ImageIO metadata";
    {
        hdr::StreamSourcePin pin;
        const auto hashes = hdr::sourceHashPassCount();
        hdr::freezeStreamSourceFile(opaqueSource.c_str(), pin);
        require(hdr::sourceHashPassCount() == hashes, "Camera source pin read the original for unused metadata");
        hdr::verifyStreamSource(pin);
        std::ofstream(opaqueSource, std::ios::app) << "changed";
        bool rejected = false;
        try { hdr::verifyStreamSource(pin); }
        catch (const hdr::Error& error) { rejected = error.reason == SONY2FUJI_HDR_REASON_SOURCE_CHANGED; }
        require(rejected, "Camera source mutation was not rejected without ImageIO metadata");
    }
    const auto original = root / "tiled-original.jpg", scratch = root / "tiled-scratch";
    fs::create_directory(scratch);
    const auto originalBytes = hdr::encodeJPEG(source, 95, SONY2FUJI_HDR_COLOR_SRGB);
    std::ofstream(original, std::ios::binary).write(reinterpret_cast<const char*>(originalBytes.data()), originalBytes.size());
    auto read = [](const fs::path& path) {
        std::ifstream file(path, std::ios::binary);
        return std::vector<uint8_t>(std::istreambuf_iterator<char>(file), {});
    };
    auto diagnostic = init<sony2fuji_hdr_diagnostic_v1>();
    auto info = init<sony2fuji_hdr_source_info_v1>();
    require(sony2fuji_hdr_probe(original.c_str(), &info, &diagnostic) == SONY2FUJI_STATUS_OK, "Tiled fixture probe failed");
    auto decode = init<sony2fuji_hdr_decode_options_v1>(); decode.intent = SONY2FUJI_INTENT_FINAL;
    auto decoded = init<sony2fuji_hdr_image_pair_v1>();
    require(sony2fuji_hdr_decode(original.c_str(), &decode, &decoded, &diagnostic) == SONY2FUJI_STATUS_OK,
        "Tiled full-frame reference decode failed");
    sony2fuji_session* session = nullptr;
    require(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK, "Tiled reference session failed");
    struct Release {
        sony2fuji_session* session;
        sony2fuji_hdr_image_pair_v1& image;
        ~Release() { sony2fuji_hdr_release_pair(&image); sony2fuji_session_destroy(session); }
    } release{session, decoded};
    auto request = init<sony2fuji_hdr_request_v1>();
    request.hdr_processing_version = 1; request.intent = SONY2FUJI_INTENT_FINAL;
    request.temperature = 6500; request.exposure_ev = .35f;
    request.crop_x = .1f; request.crop_y = .07f; request.crop_width = .8f; request.crop_height = .83f;
    request.quarter_turns = 1; request.long_edge = 293;
    auto config = init<sony2fuji_hdr_export_config_v1>();
    config.jpeg_quality = 95; config.base_color = SONY2FUJI_HDR_COLOR_SRGB;
    config.metadata_policy = SONY2FUJI_HDR_METADATA_ISO; config.metadata_source_path = original.c_str();
    std::copy_n(info.source_sha256, 32, config.source_sha256);
    auto result = init<sony2fuji_hdr_stream_result_v1>();
    auto run = [&](const fs::path& output, uint32_t format) {
        return sony2fuji_hdr_export_tiled(session, nullptr, nullptr, original.c_str(), &request, &config, format,
            scratch.c_str(), output.c_str(), &result, &diagnostic);
    };
    auto rendered = init<sony2fuji_hdr_image_pair_v1>();
    require(sony2fuji_hdr_render(session, &decoded, &request, &rendered, &diagnostic) == SONY2FUJI_STATUS_OK,
        "Tiled full-frame render reference failed");
    struct ReleasePair { sony2fuji_hdr_image_pair_v1& image; ~ReleasePair() { sony2fuji_hdr_release_pair(&image); } } pairRelease{rendered};
    for (auto color : {SONY2FUJI_HDR_COLOR_SRGB, SONY2FUJI_HDR_COLOR_DISPLAY_P3}) {
        config.base_color = color;
        const auto output = root / ("tiled-" + std::to_string(color) + ".heif"), reference = root / "full-reference.heif";
        require(sony2fuji_hdr_export_heif(&rendered, &config, reference.c_str(), &diagnostic) == SONY2FUJI_STATUS_OK,
            "Full-frame HEIF reference export failed");
        const auto status = run(output, SONY2FUJI_HDR_TILED_HEIF);
        if (status) std::cerr << "tiled HEIF status=" << status << " reason=" << diagnostic.reason << '\n';
        require(status == SONY2FUJI_STATUS_OK, "Tiled HEIF export failed");
        auto outputInfo = hdr::probeFile(output.c_str());
        require(result.width == rendered.hdr.width && result.height == rendered.hdr.height &&
            outputInfo.width == rendered.hdr.width && outputInfo.height == rendered.hdr.height && outputInfo.orientation == 1 &&
            outputInfo.protocol == SONY2FUJI_HDR_PROTOCOL_ISO && outputInfo.colorDescription == uint32_t(color),
            "Tiled HEIF lost its canvas, ISO gain map, direction or color");
        const auto actual = hdr::decodeFile(output.c_str(), sony2fuji::HDRDecodeOptions{decode.intent, decode.long_edge}),
                   expected = hdr::decodeFile(reference.c_str(), sony2fuji::HDRDecodeOptions{decode.intent, decode.long_edge});
        std::vector<double> luminanceError;
        double sdrError = 0;
        for (size_t i = 0; i < expected.pixels.hdr.pixels.size(); ++i) {
            const auto& a = actual.pixels.hdr.pixels[i]; const auto& b = expected.pixels.hdr.pixels[i];
            const double ay = .2126 * a.r + .7152 * a.g + .0722 * a.b, by = .2126 * b.r + .7152 * b.g + .0722 * b.b;
            luminanceError.push_back(std::abs(std::log2(std::max(ay, 1e-4) / std::max(by, 1e-4))));
            const auto& low = actual.pixels.sdr.pixels[i]; const auto& baseline = expected.pixels.sdr.pixels[i];
            sdrError += std::abs(low.r - baseline.r) + std::abs(low.g - baseline.g) + std::abs(low.b - baseline.b);
        }
        std::sort(luminanceError.begin(), luminanceError.end());
        require(luminanceError[luminanceError.size() * 95 / 100] <= .10 &&
            sdrError / (luminanceError.size() * 3) <= .01, "Tiled HEIF pixels differ from the full-frame reference");
        require(fs::is_empty(scratch), "Tiled HEIF left scratch files");
    }
    const auto dng = root / "tiled-output.dng", dngReference = root / "full-reference.dng";
    auto dngConfig = init<sony2fuji_hdr_sdr_export_config_v1>();
    dngConfig.output_format = SONY2FUJI_OUTPUT_DNG; dngConfig.quality = 95;
    require(sony2fuji_hdr_export_sdr(&rendered, &dngConfig, dngReference.c_str(), &diagnostic) == SONY2FUJI_STATUS_OK,
        "Full-frame DNG reference failed");
    require(run(dng, SONY2FUJI_HDR_TILED_SDR_DNG) == SONY2FUJI_STATUS_OK && read(dng) == read(dngReference),
        "Tiled DNG differs from the full-frame pixels, tags or previews");
    const auto saved = read(dng);
    request.intent = SONY2FUJI_INTENT_PREVIEW;
    require(run(dng, SONY2FUJI_HDR_TILED_SDR_DNG) == SONY2FUJI_STATUS_INVALID_ARGUMENT &&
        diagnostic.reason == SONY2FUJI_HDR_REASON_PREVIEW_SOURCE && result.width == 0, "Tiled export accepted preview intent");
    request.intent = SONY2FUJI_INTENT_FINAL;
    config.source_sha256[0] ^= 1;
    require(run(dng, SONY2FUJI_HDR_TILED_SDR_DNG) == SONY2FUJI_STATUS_INVALID_ARGUMENT &&
        diagnostic.reason == SONY2FUJI_HDR_REASON_SOURCE_CHANGED, "Tiled export accepted a changed source");
    config.source_sha256[0] ^= 1;
    require(run(original, SONY2FUJI_HDR_TILED_SDR_DNG) == SONY2FUJI_STATUS_INVALID_ARGUMENT &&
        diagnostic.reason == SONY2FUJI_HDR_REASON_SAME_FILE, "Tiled export overwrote its source");
    int checks = 0;
    sony2fuji_session_set_cancellation_callback(session, [](void* opaque) {
        return ++*static_cast<int*>(opaque) > 20 ? 1 : 0;
    }, &checks);
    require(run(dng, SONY2FUJI_HDR_TILED_SDR_DNG) == SONY2FUJI_STATUS_CANCELLED,
        "Tiled export did not cancel during processing");
    sony2fuji_session_set_cancellation_callback(session, nullptr, nullptr);
    require(read(dng) == saved && read(original) == originalBytes && fs::is_empty(scratch),
        "Failed tiled export changed its target, original or scratch ownership");
    request.exposure_ev = -4;
    require(run(root / "tiled-below-white.heif", SONY2FUJI_HDR_TILED_HEIF) == SONY2FUJI_STATUS_OK,
        "Tiled HEIF rejected an edited image below reference white");
    std::cout << "PASS tiled HEIF/DNG full-frame equivalence, ISO gain maps, source identity, cancellation and cleanup\n";
}
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        if (@available(macOS 15.0, iOS 18.0, *)) {
            if (argc==3 && std::string(argv[1])=="--fixture") {
                return [fixture() writeToFile:[NSString stringWithUTF8String:argv[2]] atomically:YES] ? 0 : 1;
            }
            NSURL* directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
            [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
            try {
                auto checkAppleProRAW = [&]() API_AVAILABLE(macos(15.0), ios(18.0)) {
                    namespace fs = std::filesystem;
                    const fs::path root(directory.fileSystemRepresentation);
                    auto probeRejected = [&](const fs::path& file, sony2fuji_status expectedStatus, uint32_t expectedReason, const char* msg) {
                        auto pInfo = init<sony2fuji_hdr_source_info_v1>();
                        auto pDiag = init<sony2fuji_hdr_diagnostic_v1>();
                        const auto st = sony2fuji_hdr_probe_apple_proraw(file.u8string().c_str(), &pInfo, &pDiag);
                        require(st == expectedStatus && pDiag.reason == expectedReason, msg);
                    };
                    auto writeBytes = [](const fs::path& file, const std::vector<uint8_t>& bytes) {
                        std::ofstream out(file, std::ios::binary | std::ios::trunc);
                        out.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
                        require(!out.fail(), "cannot write synthetic ProRAW test fixture");
                    };
                    auto append16 = [](std::vector<uint8_t>& buf, uint16_t v) {
                        buf.push_back(uint8_t(v & 0xff));
                        buf.push_back(uint8_t((v >> 8) & 0xff));
                    };
                    auto append32 = [](std::vector<uint8_t>& buf, uint32_t v) {
                        buf.push_back(uint8_t(v & 0xff));
                        buf.push_back(uint8_t((v >> 8) & 0xff));
                        buf.push_back(uint8_t((v >> 16) & 0xff));
                        buf.push_back(uint8_t((v >> 24) & 0xff));
                    };
                    auto appendEntry = [&](std::vector<uint8_t>& buf, uint16_t tag, uint16_t type, uint32_t count, uint32_t value) {
                        append16(buf, tag);
                        append16(buf, type);
                        append32(buf, count);
                        append32(buf, value);
                    };

                    // 1. < 8 bytes, missing path, bayer-demosaic.dng
                    const fs::path tiny = root / "tiny.dng";
                    writeBytes(tiny, {0x49, 0x49, 42, 0});
                    probeRejected(tiny, SONY2FUJI_STATUS_UNSUPPORTED, SONY2FUJI_HDR_REASON_UNSUPPORTED_RAW,
                        "tiny <8B DNG was not rejected");
                    probeRejected(root / "missing.dng", SONY2FUJI_STATUS_IO_ERROR, SONY2FUJI_HDR_REASON_INPUT_IO,
                        "missing DNG did not return IO_ERROR");
                    probeRejected(fs::path(TEST_FIXTURE_DIR "/bayer-demosaic.dng"),
                        SONY2FUJI_STATUS_UNSUPPORTED, SONY2FUJI_HDR_REASON_UNSUPPORTED_RAW,
                        "bayer-demosaic.dng was accepted as Apple ProRAW");

                    // 2. Truncated IFD
                    const fs::path truncated = root / "truncated.dng";
                    writeBytes(truncated, {'I', 'I', 42, 0, 8, 0, 0, 0, 2, 0, 1, 2});
                    probeRejected(truncated, SONY2FUJI_STATUS_UNSUPPORTED, SONY2FUJI_HDR_REASON_UNSUPPORTED_RAW,
                        "truncated IFD was accepted as Apple ProRAW");

                    // 3. Cyclic SubIFD (tag 330 pointing back to IFD0 at offset 8)
                    const fs::path cyclic = root / "cyclic.dng";
                    std::vector<uint8_t> cyc{'I', 'I', 42, 0, 8, 0, 0, 0};
                    append16(cyc, 2);
                    appendEntry(cyc, 330, 4, 1, 8);
                    appendEntry(cyc, 50706, 1, 4, 0x00000401u);
                    append32(cyc, 0);
                    writeBytes(cyclic, cyc);
                    probeRejected(cyclic, SONY2FUJI_STATUS_UNSUPPORTED, SONY2FUJI_HDR_REASON_UNSUPPORTED_RAW,
                        "cyclic SubIFD was accepted as Apple ProRAW");

                    // 4. Oversized SubIFDs (count = 33)
                    const fs::path oversized = root / "oversized-subifd.dng";
                    std::vector<uint8_t> over{'I', 'I', 42, 0, 8, 0, 0, 0};
                    append16(over, 2);
                    appendEntry(over, 330, 4, 33, 64);
                    appendEntry(over, 50706, 1, 4, 0x00000401u);
                    append32(over, 0);
                    over.resize(64 + 33 * 4, 0);
                    writeBytes(oversized, over);
                    probeRejected(oversized, SONY2FUJI_STATUS_UNSUPPORTED, SONY2FUJI_HDR_REASON_UNSUPPORTED_RAW,
                        "oversized SubIFDs count=33 was accepted");

                    // 5. Missing DNGVersion (50706)
                    const fs::path noVersion = root / "no-dngversion.dng";
                    std::vector<uint8_t> noVer{'I', 'I', 42, 0, 8, 0, 0, 0};
                    append16(noVer, 3);
                    appendEntry(noVer, 262, 3, 1, 34892);
                    appendEntry(noVer, 50712, 3, 1, 0);
                    appendEntry(noVer, 52525, 1, 1, 0);
                    append32(noVer, 0);
                    writeBytes(noVersion, noVer);
                    probeRejected(noVersion, SONY2FUJI_STATUS_UNSUPPORTED, SONY2FUJI_HDR_REASON_UNSUPPORTED_RAW,
                        "LinearRaw TIFF without DNGVersion 50706 was accepted");

                    // 6. Real non-Apple LinearRaw DNG (Make="Sony")
                    const fs::path nonApple = root / "sony-linear.dng";
                    {
                        TIFF* tif = TIFFOpen(nonApple.u8string().c_str(), "w");
                        require(tif != nullptr, "cannot author synthetic non-Apple DNG");
                        const uint8_t dngVer[4] = {1, 4, 0, 0};
                        const uint16_t linTable[2] = {0, 65535};
                        TIFFSetField(tif, TIFFTAG_IMAGEWIDTH, 4);
                        TIFFSetField(tif, TIFFTAG_IMAGELENGTH, 4);
                        TIFFSetField(tif, TIFFTAG_SAMPLESPERPIXEL, 3);
                        TIFFSetField(tif, TIFFTAG_BITSPERSAMPLE, 16);
                        TIFFSetField(tif, TIFFTAG_PHOTOMETRIC, 34892);
                        TIFFSetField(tif, TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG);
                        TIFFSetField(tif, TIFFTAG_COMPRESSION, COMPRESSION_NONE);
                        TIFFSetField(tif, TIFFTAG_ROWSPERSTRIP, 4);
                        TIFFSetField(tif, TIFFTAG_MAKE, "Sony");
                        TIFFSetField(tif, TIFFTAG_MODEL, "iPhone 16 Pro");
                        TIFFSetField(tif, 50706, dngVer);
                        TIFFSetField(tif, 50712, 2, linTable);
                        std::vector<uint16_t> row(4 * 3, 1024);
                        for (uint32_t r = 0; r < 4; ++r) TIFFWriteScanline(tif, row.data(), r, 0);
                        TIFFClose(tif);
                    }
                    probeRejected(nonApple, SONY2FUJI_STATUS_UNSUPPORTED, SONY2FUJI_HDR_REASON_UNSUPPORTED_RAW,
                        "non-Apple Make DNG was accepted as Apple ProRAW");
                    auto hProbeInfo = init<sony2fuji_hdr_source_info_v1>();
                    auto hProbeDiag = init<sony2fuji_hdr_diagnostic_v1>();
                    require(sony2fuji_hdr_probe(nonApple.u8string().c_str(), &hProbeInfo, &hProbeDiag) != SONY2FUJI_STATUS_OK,
                        "sony2fuji_hdr_probe accepted a DNG");

                    // Export rejection on non-Apple DNG
                    {
                        sony2fuji_session* s = nullptr;
                        require(sony2fuji_session_create(&s) == SONY2FUJI_STATUS_OK, "session create failed");
                        auto cfg = init<sony2fuji_hdr_export_config_v1>();
                        cfg.jpeg_quality = 95;
                        cfg.base_color = SONY2FUJI_HDR_COLOR_DISPLAY_P3;
                        cfg.metadata_policy = SONY2FUJI_HDR_METADATA_ISO_XMP;
                        const std::string srcStr = nonApple.u8string();
                        cfg.metadata_source_path = srcStr.c_str();
                        auto res = init<sony2fuji_hdr_stream_result_v1>();
                        auto diag = init<sony2fuji_hdr_diagnostic_v1>();
                        const fs::path outPath = root / "rejected-export.jpg";
                        const auto est = sony2fuji_hdr_export_apple_proraw_json(
                            s, srcStr.c_str(), nullptr, nullptr, &cfg, 1,
                            root.u8string().c_str(), outPath.u8string().c_str(), &res, &diag);
                        sony2fuji_session_destroy(s);
                        require(est == SONY2FUJI_STATUS_UNSUPPORTED && diag.reason == SONY2FUJI_HDR_REASON_UNSUPPORTED_RAW,
                            "non-Apple DNG was accepted by export_apple_proraw_json");
                    }

                    // 7. Optional real Apple ProRAW fixture validation
                    if (const char* prorawPath = std::getenv("RAWLAB_TEST_PRORAW"); prorawPath && *prorawPath) {
                        auto pInfo = init<sony2fuji_hdr_source_info_v1>();
                        auto pDiag = init<sony2fuji_hdr_diagnostic_v1>();
                        require(sony2fuji_hdr_probe_apple_proraw(prorawPath, &pInfo, &pDiag) == SONY2FUJI_STATUS_OK &&
                                pInfo.container == SONY2FUJI_HDR_CONTAINER_PRORAW,
                            "real ProRAW probe_apple_proraw failed");
                        require(sony2fuji_hdr_probe(prorawPath, &hProbeInfo, &hProbeDiag) != SONY2FUJI_STATUS_OK,
                            "sony2fuji_hdr_probe leaked real Apple ProRAW");
                        auto decOpts = init<sony2fuji_hdr_decode_options_v1>();
                        decOpts.intent = SONY2FUJI_INTENT_PREVIEW;
                        decOpts.long_edge = 512;
                        auto prevPair = init<sony2fuji_hdr_image_pair_v1>();
                        require(sony2fuji_hdr_decode(prorawPath, &decOpts, &prevPair, &pDiag) == SONY2FUJI_STATUS_OK &&
                                prevPair.decode_revision == 1 &&
                                prevPair.source_headroom_kind == SONY2FUJI_HDR_HEADROOM_UNKNOWN,
                            "real ProRAW preview decode failed");
                        sony2fuji_hdr_release_pair(&prevPair);

                        decOpts.intent = SONY2FUJI_INTENT_FINAL;
                        decOpts.long_edge = 0;
                        auto finalPair = init<sony2fuji_hdr_image_pair_v1>();
                        require(sony2fuji_hdr_decode(prorawPath, &decOpts, &finalPair, &pDiag) == SONY2FUJI_STATUS_OK &&
                                finalPair.decode_revision == 1 &&
                                finalPair.source_headroom_kind == SONY2FUJI_HDR_HEADROOM_MEASURED,
                            "real ProRAW FINAL decode failed");
                        sony2fuji_hdr_release_pair(&finalPair);
                    }
                };
                checkAppleProRAW();
                NSURL* file=[directory URLByAppendingPathComponent:@"source.jpg"];
                require([fixture() writeToURL:file atomically:YES],"fixture write failed");
                const char* path=argc==2 ? argv[1] : file.fileSystemRepresentation;
                auto info=init<sony2fuji_hdr_source_info_v1>(); auto d=init<sony2fuji_hdr_diagnostic_v1>();
                auto status=sony2fuji_hdr_probe(path,&info,&d);
                if (status) std::cerr << "probe status=" << status << " reason=" << d.reason << '\n';
                require(status==SONY2FUJI_STATUS_OK,"HDR probe failed");
                require(info.width && info.height && info.protocol,"HDR source identity missing");
                if (argc==2 && info.container==SONY2FUJI_HDR_CONTAINER_JPEG) {
                    NSData* data=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]];
                    auto hasNamespace=[&](const std::string& name) {
                        const auto* begin=static_cast<const char*>(data.bytes); const auto* end=begin+data.length;
                        return std::search(begin,end,name.begin(),name.end())!=end;
                    };
                    if (hasNamespace("http://ns.adobe.com/hdr-gain-map/1.0/") && !hasNamespace("urn:iso:std:iso:ts:21496:-1") &&
                        !hasNamespace("urn:com:apple:photo:2020:aux:hdrgainmap"))
                        require(info.protocol==SONY2FUJI_HDR_PROTOCOL_XMP,"ImageIO synthesized ISO metadata for an XMP-only original");
                }
                auto options=init<sony2fuji_hdr_decode_options_v1>(); options.intent=SONY2FUJI_INTENT_PREVIEW; options.long_edge=1024;
                auto pair=init<sony2fuji_hdr_image_pair_v1>();
                status=sony2fuji_hdr_decode(path,&options,&pair,&d);
                if (status) std::cerr << "decode status=" << status << " reason=" << d.reason << '\n';
                require(status==SONY2FUJI_STATUS_OK,"HDR decode failed");
                require(pair.hdr.width==pair.sdr.width && pair.hdr.height==pair.sdr.height && pair.is_proxy,
                    "decoded pair/provenance mismatch");
                const auto* h=static_cast<float*>(pair.hdr.data); const auto* s=static_cast<float*>(pair.sdr.data);
                double delta=0; float maximum=0;
                for (size_t i=0; i<pair.hdr.width*pair.hdr.height*3; ++i) {
                    require(std::isfinite(h[i]) && std::isfinite(s[i]),"nonfinite decoded value");
                    delta+=std::abs(h[i]-s[i]); maximum=std::max(maximum,h[i]);
                }
                require(maximum>1.5 && delta>1,"HDR expansion lost its luminance range");
                require(pair.source_headroom>1 && pair.source_headroom_kind,"source headroom missing");
                sony2fuji_hdr_release_pair(&pair);
                if (argc==1) {
                    tiledExports(directory);
                    try {
                        sony2fuji::hdr::admitMemory(UINT64_MAX);
                        require(false,"unbounded HDR allocation admitted");
                    } catch (const sony2fuji::hdr::Error& error) {
                        require(error.status==sony2fuji::RenderStatus::OutOfMemory && error.reason==SONY2FUJI_HDR_REASON_OUT_OF_MEMORY,
                            "memory budget has no recoverable resource diagnostic");
                    }
                    const std::string legacyPath=std::string(TEST_FIXTURE_DIR)+"/hdr/apple-legacy-macos26.jpg";
                    auto legacyInfo=init<sony2fuji_hdr_source_info_v1>();
                    require(sony2fuji_hdr_probe(legacyPath.c_str(),&legacyInfo,&d)==SONY2FUJI_STATUS_OK &&
                        legacyInfo.protocol==SONY2FUJI_HDR_PROTOCOL_APPLE,"Apple legacy JPEG was treated as modern XMP/ISO");
                    for (auto intent:{SONY2FUJI_INTENT_PREVIEW,SONY2FUJI_INTENT_FINAL}) {
                        auto legacyPair=init<sony2fuji_hdr_image_pair_v1>();
                        options.intent=intent; options.long_edge=intent==SONY2FUJI_INTENT_PREVIEW ? 32 : 0;
                        require(sony2fuji_hdr_decode(legacyPath.c_str(),&options,&legacyPair,&d)==SONY2FUJI_STATUS_OK,
                            "Apple legacy JPEG decode failed");
                        const auto* pixels=static_cast<const float*>(legacyPair.hdr.data);
                        require(*std::max_element(pixels,pixels+legacyPair.hdr.width*legacyPair.hdr.height*3)>1.5f,
                            "Apple legacy JPEG lost HDR expansion");
                        sony2fuji_hdr_release_pair(&legacyPair);
                    }
                    numericAcceptance(directory);
                    pair=init<sony2fuji_hdr_image_pair_v1>();
                    options.intent=SONY2FUJI_INTENT_FINAL; options.long_edge=0;
                    require(sony2fuji_hdr_decode(path,&options,&pair,&d)==SONY2FUJI_STATUS_OK,"FINAL decode failed");
                    auto config=init<sony2fuji_hdr_export_config_v1>();
                    config.jpeg_quality=95; config.base_color=SONY2FUJI_HDR_COLOR_SRGB;
                    config.metadata_policy=SONY2FUJI_HDR_METADATA_ISO_XMP;
                    NSURL* other=[directory URLByAppendingPathComponent:@"different-source.jpg"];
                    require([fixture(true) writeToURL:other atomically:YES],"cannot stage different metadata source");
                    auto otherInfo=init<sony2fuji_hdr_source_info_v1>();
                    require(sony2fuji_hdr_probe(other.fileSystemRepresentation,&otherInfo,&d)==SONY2FUJI_STATUS_OK,
                        "cannot probe different metadata source");
                    config.metadata_source_path=other.fileSystemRepresentation;
                    std::copy_n(otherInfo.source_sha256,32,config.source_sha256);
                    NSURL* protectedOutput=[directory URLByAppendingPathComponent:@"protected.jpg"];
                    NSData* previous=[@"previous output" dataUsingEncoding:NSUTF8StringEncoding];
                    [previous writeToURL:protectedOutput atomically:YES];
                    require(sony2fuji_hdr_export_jpeg(&pair,&config,protectedOutput.fileSystemRepresentation,&d)!=SONY2FUJI_STATUS_OK &&
                        d.reason==SONY2FUJI_HDR_REASON_SOURCE_CHANGED,"unrelated metadata source was accepted");
                    require([previous isEqualToData:[NSData dataWithContentsOfURL:protectedOutput]],"failed metadata export replaced destination");
                    config.metadata_source_path=nullptr;
                    std::fill_n(config.source_sha256,32,0);
                    NSData* original=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]];
                    require(sony2fuji_hdr_export_jpeg(&pair,&config,path,&d)==SONY2FUJI_STATUS_INVALID_ARGUMENT,
                        "export was allowed to replace its decoded source without metadata_source_path");
                    require([original isEqualToData:[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]]],
                        "export changed the source container");
                    NSURL* output=[directory URLByAppendingPathComponent:@"output.jpg"];
                    status=sony2fuji_hdr_export_jpeg(&pair,&config,output.fileSystemRepresentation,&d);
                    if (status) std::cerr<<"export status="<<status<<" reason="<<d.reason<<'\n';
                    require(status==SONY2FUJI_STATUS_OK,"HDR JPEG export failed");
                    NSMutableData* conflicting=[[NSData dataWithContentsOfURL:output] mutableCopy];
                    const std::string capacityTag="hdrgm:HDRCapacityMax=\"";
                    auto* text=static_cast<char*>(conflicting.mutableBytes); auto* limit=text+conflicting.length;
                    auto* capacity=std::search(text,limit,capacityTag.begin(),capacityTag.end());
                    require(capacity!=limit,"missing XMP capacity in dual metadata output");
                    capacity+=capacityTag.size(); *capacity=*capacity=='1' ? '2' : '1';
                    NSURL* conflictingFile=[directory URLByAppendingPathComponent:@"conflicting-dual.jpg"];
                    require([conflicting writeToURL:conflictingFile atomically:YES],"cannot stage conflicting metadata");
                    // Apple 标记不能绕过实际 ISO/XMP 描述的一致性检查。
                    const char* appleMarker="urn:com:apple:photo:2020:aux:hdrgainmap";
                    [conflicting appendBytes:appleMarker length:std::strlen(appleMarker)];
                    require([conflicting writeToURL:conflictingFile atomically:YES],"cannot stage mixed protocol metadata");
                    auto conflictingInfo=init<sony2fuji_hdr_source_info_v1>();
                    require(sony2fuji_hdr_probe(conflictingFile.fileSystemRepresentation,&conflictingInfo,&d)==SONY2FUJI_STATUS_PROCESSING_ERROR &&
                        d.reason==SONY2FUJI_HDR_REASON_MALFORMED_AUX,"contradictory ISO/XMP descriptions were accepted");
                    NSMutableData* xmpOnly=[[NSData dataWithContentsOfURL:output] mutableCopy];
                    const std::string isoName="urn:iso:std:iso:ts:21496:-1";
                    auto* begin=static_cast<char*>(xmpOnly.mutableBytes); auto* end=begin+xmpOnly.length;
                    for (auto* found=std::search(begin,end,isoName.begin(),isoName.end()); found!=end;
                            found=std::search(found+isoName.size(),end,isoName.begin(),isoName.end()))
                        std::fill_n(found,isoName.size(),'x');
                    NSURL* xmpFile=[directory URLByAppendingPathComponent:@"xmp-only.jpg"];
                    require([xmpOnly writeToURL:xmpFile atomically:YES],"cannot stage XMP-only fixture");
                    auto xmpInfo=init<sony2fuji_hdr_source_info_v1>();
                    require(sony2fuji_hdr_probe(xmpFile.fileSystemRepresentation,&xmpInfo,&d)==SONY2FUJI_STATUS_OK &&
                        xmpInfo.protocol==SONY2FUJI_HDR_PROTOCOL_XMP,"synthesized ImageIO ISO dictionary mislabelled an XMP file");
                    NSMutableData* invalidXMP=[xmpOnly mutableCopy];
                    const std::string versionTag="hdrgm:Version";
                    auto* invalidBegin=static_cast<char*>(invalidXMP.mutableBytes); auto* invalidEnd=invalidBegin+invalidXMP.length;
                    auto* version=std::search(invalidBegin,invalidEnd,versionTag.begin(),versionTag.end());
                    require(version!=invalidEnd,"missing XMP version in test output");
                    for (;version!=invalidEnd;version=std::search(version+versionTag.size(),invalidEnd,versionTag.begin(),versionTag.end()))
                        std::fill_n(version,versionTag.size(),'x');
                    NSURL* invalidFile=[directory URLByAppendingPathComponent:@"invalid-xmp.jpg"];
                    require([invalidXMP writeToURL:invalidFile atomically:YES],"cannot stage malformed XMP");
                    auto invalidInfo=init<sony2fuji_hdr_source_info_v1>();
                    require(sony2fuji_hdr_probe(invalidFile.fileSystemRepresentation,&invalidInfo,&d)==SONY2FUJI_STATUS_PROCESSING_ERROR &&
                        d.reason==SONY2FUJI_HDR_REASON_MALFORMED_AUX,"malformed modern XMP was admitted as legacy Apple");
                    [invalidXMP appendBytes:appleMarker length:std::strlen(appleMarker)];
                    require([invalidXMP writeToURL:invalidFile atomically:YES],"cannot stage malformed XMP with Apple marker");
                    invalidInfo=init<sony2fuji_hdr_source_info_v1>();
                    require(sony2fuji_hdr_probe(invalidFile.fileSystemRepresentation,&invalidInfo,&d)==SONY2FUJI_STATUS_PROCESSING_ERROR &&
                        d.reason==SONY2FUJI_HDR_REASON_MALFORMED_AUX,"Apple marker bypassed malformed modern XMP validation");
                    auto roundtrip=init<sony2fuji_hdr_image_pair_v1>();
                    status=sony2fuji_hdr_decode(output.fileSystemRepresentation,&options,&roundtrip,&d);
                    if (status) std::cerr<<"roundtrip status="<<status<<" reason="<<d.reason<<'\n';
                    require(status==SONY2FUJI_STATUS_OK,
                        "exported JPEG could not be decoded");
                    require(roundtrip.hdr.content_headroom>1.5,"HDR JPEG lost edited headroom");
                    sony2fuji_hdr_release_pair(&roundtrip);
                    if (sony2fuji_hdr_heif_export_available()) {
                        // C-08 红锚：HEIF 导出对元数据源只做一次整文件摘要；撤掉快照核对修复后此计数回到 2。
                        auto heifConfig=init<sony2fuji_hdr_export_config_v1>();
                        heifConfig.jpeg_quality=95; heifConfig.base_color=SONY2FUJI_HDR_COLOR_SRGB;
                        heifConfig.metadata_policy=SONY2FUJI_HDR_METADATA_ISO;
                        heifConfig.metadata_source_path=path;
                        std::copy_n(info.source_sha256,32,heifConfig.source_sha256);
                        NSURL* heifOutput=[directory URLByAppendingPathComponent:@"output.heif"];
                        sony2fuji::hdr::resetSourceHashPassCount();
                        status=sony2fuji_hdr_export_heif(&pair,&heifConfig,heifOutput.fileSystemRepresentation,&d);
                        if (status) std::cerr<<"heif export status="<<status<<" reason="<<d.reason<<'\n';
                        require(status==SONY2FUJI_STATUS_OK,"HDR HEIF export failed");
                        require(sony2fuji::hdr::sourceHashPassCount()==1,"HDR HEIF export still performs a second full-file digest pass");
                    }
                    // 编辑后全图低于参考白仍是有效的增益图来源，不能按峰值误判成坏图。
                    sony2fuji_session* session=nullptr;
                    require(sony2fuji_session_create(&session)==SONY2FUJI_STATUS_OK,"session creation failed");
                    auto settings=init<sony2fuji_hdr_request_v1>(); settings.hdr_processing_version=1;
                    settings.intent=SONY2FUJI_INTENT_FINAL; settings.temperature=6500;
                    settings.crop_width=settings.crop_height=1; settings.exposure_ev=-4;
                    auto dark=init<sony2fuji_hdr_image_pair_v1>();
                    require(sony2fuji_hdr_render(session,&pair,&settings,&dark,&d)==SONY2FUJI_STATUS_OK,"dark edit failed");
                    NSURL* darkOutput=[directory URLByAppendingPathComponent:@"dark.jpg"];
                    status=sony2fuji_hdr_export_jpeg(&dark,&config,darkOutput.fileSystemRepresentation,&d);
                    if (status) std::cerr<<"dark export status="<<status<<" reason="<<d.reason<<'\n';
                    require(status==SONY2FUJI_STATUS_OK,
                        "dark HDR encoding failed");
                    roundtrip=init<sony2fuji_hdr_image_pair_v1>();
                    status=sony2fuji_hdr_decode(darkOutput.fileSystemRepresentation,&options,&roundtrip,&d);
                    if (status) std::cerr<<"dark decode status="<<status<<" reason="<<d.reason<<'\n';
                    require(status==SONY2FUJI_STATUS_OK,"valid headroom-one HDR file rejected");
                    sony2fuji_hdr_release_pair(&roundtrip); sony2fuji_hdr_release_pair(&dark);
                    sony2fuji_session_destroy(session);
                    auto sdrConfig=init<sony2fuji_hdr_sdr_export_config_v1>();
                    sdrConfig.output_format=SONY2FUJI_OUTPUT_JPEG; sdrConfig.quality=95;
                    sdrConfig.metadata_source_path=other.fileSystemRepresentation;
                    std::copy_n(otherInfo.source_sha256,32,sdrConfig.source_sha256);
                    require(sony2fuji_hdr_export_sdr(&pair,&sdrConfig,protectedOutput.fileSystemRepresentation,&d)!=SONY2FUJI_STATUS_OK &&
                        d.reason==SONY2FUJI_HDR_REASON_SOURCE_CHANGED,"SDR export accepted unrelated metadata source");
                    require([previous isEqualToData:[NSData dataWithContentsOfURL:protectedOutput]],"failed SDR metadata export replaced destination");
                    sdrConfig.metadata_source_path=nullptr; std::fill_n(sdrConfig.source_sha256,32,0);
                    NSURL* sdrOutput=[directory URLByAppendingPathComponent:@"sdr.jpg"];
                    require(sony2fuji_hdr_export_sdr(&pair,&sdrConfig,sdrOutput.fileSystemRepresentation,&d)==SONY2FUJI_STATUS_OK,
                        "SDR rendition export failed");
                    info=init<sony2fuji_hdr_source_info_v1>();
                    require(sony2fuji_hdr_probe(sdrOutput.fileSystemRepresentation,&info,&d)==SONY2FUJI_STATUS_UNSUPPORTED,
                        "ordinary SDR export retained gain-map metadata");
                    require(d.reason==SONY2FUJI_HDR_REASON_NOT_HDR,
                        "ordinary SDR is indistinguishable from unsupported or damaged HDR");
                    NSMutableData* falseApple=[[NSData dataWithContentsOfURL:sdrOutput] mutableCopy];
                    [falseApple appendBytes:appleMarker length:std::strlen(appleMarker)];
                    NSURL* falseAppleFile=[directory URLByAppendingPathComponent:@"false-apple.jpg"];
                    require([falseApple writeToURL:falseAppleFile atomically:YES],"cannot stage missing Apple gain map");
                    info=init<sony2fuji_hdr_source_info_v1>();
                    require(sony2fuji_hdr_probe(falseAppleFile.fileSystemRepresentation,&info,&d)==SONY2FUJI_STATUS_PROCESSING_ERROR &&
                        d.reason==SONY2FUJI_HDR_REASON_MALFORMED_AUX,"Apple marker without a gain map was accepted");
                    sdrConfig.output_format=SONY2FUJI_OUTPUT_PNG;
                    NSURL* pngOutput=[directory URLByAppendingPathComponent:@"sdr.png"];
                    require(sony2fuji_hdr_export_sdr(&pair,&sdrConfig,pngOutput.fileSystemRepresentation,&d)==SONY2FUJI_STATUS_OK,
                        "SDR PNG export failed");
                    NSData* png=[NSData dataWithContentsOfURL:pngOutput];
                    require(png.length>25 && static_cast<const uint8_t*>(png.bytes)[24]==16,"SDR PNG lost existing 16-bit precision");
                    sdrConfig.output_format=SONY2FUJI_OUTPUT_DNG;
                    NSURL* dngOutput=[directory URLByAppendingPathComponent:@"sdr.dng"];
                    require(sony2fuji_hdr_export_sdr(&pair,&sdrConfig,dngOutput.fileSystemRepresentation,&d)==SONY2FUJI_STATUS_OK,
                        "SDR rendered DNG export failed");
                    TIFF* dng=TIFFOpen(dngOutput.fileSystemRepresentation,"r");
                    require(dng,"cannot inspect rendered DNG");
                    uint16_t subIfdCount=0; uint64_t* subIfds=nullptr;
                    require(TIFFGetField(dng,TIFFTAG_SUBIFD,&subIfdCount,&subIfds) && subIfdCount>=1 && subIfds &&
                          TIFFSetSubDirectory(dng,subIfds[0]), "cannot find SDR DNG image directory");
                    uint16_t bits=0,format=0; uint32_t w=0,height=0;
                    TIFFGetField(dng,TIFFTAG_BITSPERSAMPLE,&bits); TIFFGetField(dng,TIFFTAG_SAMPLEFORMAT,&format);
                    TIFFGetField(dng,TIFFTAG_IMAGEWIDTH,&w); TIFFGetField(dng,TIFFTAG_IMAGELENGTH,&height);
                    require(bits==16 && format==SAMPLEFORMAT_UINT && w==pair.sdr.width && height==pair.sdr.height,
                        "SDR DNG format/canvas changed");
                    std::vector<uint16_t> row(w*3);
                    const bool read=TIFFReadScanline(dng,row.data(),0,0)>=0; TIFFClose(dng);
                    require(read,"cannot read SDR DNG pixels");
                    const auto* expected=static_cast<const float*>(pair.sdr.data);
                    for (size_t i=0;i<row.size();++i)
                        require(std::abs(row[i]/65535.0f-std::clamp(expected[i],0.0f,1.0f))<=1.0f/65535.0f,
                            "SDR DNG used HDR or the wrong transfer");
                    NSURL* damaged=[directory URLByAppendingPathComponent:@"damaged.jpg"];
                    NSData* source=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]];
                    require([[source subdataWithRange:NSMakeRange(0,source.length/2)] writeToURL:damaged atomically:YES],
                        "cannot stage damaged auxiliary fixture");
                    info=init<sony2fuji_hdr_source_info_v1>();
                    require(sony2fuji_hdr_probe(damaged.fileSystemRepresentation,&info,&d)!=SONY2FUJI_STATUS_OK &&
                        d.reason!=SONY2FUJI_HDR_REASON_NOT_HDR,"damaged HDR was classified as ordinary SDR");
                    sony2fuji_hdr_release_pair(&pair);
                }
                [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
                std::cout << "PASS hdr_image_decode\n"; return 0;
            } catch (const std::exception& e) {
                if (std::getenv("RAWLAB_HDR_KEEP_TEST")) std::cerr<<"fixture directory="<<directory.fileSystemRepresentation<<'\n';
                else [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
                std::cerr << "FAIL: " << e.what() << '\n'; return 1;
            }
        }
        return 77;
    }
}
