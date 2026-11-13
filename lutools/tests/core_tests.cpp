#include "sony2fuji/sony2fuji.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#include "sony2fuji/gpu/lut_gpu.h"
#include "core/preview_exposure.h"
#include "core/photo_rendering.h"
#include "core/photo_lut.h"
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <zlib.h>
#include <limits>
#include <array>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#undef near
#include <process.h>
#define getpid _getpid
#else
#include <csignal>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>
#include <pthread.h>
#endif
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
#include "ai/dualdn_cache.h"
#include "ai/model_package.h"
#include "ai/network_graph.h"
#include "ai/directml_device.h"
#include <nlohmann/json.hpp>
#include <optional>
#endif

using namespace sony2fuji;
int failures = 0;
void check(bool ok, const char* name) {
    std::cout << (ok ? "PASS " : "FAIL ") << name << '\n';
    if (!ok) ++failures;
}
bool near(float a, float b, float tolerance = 1e-5f) { return std::abs(a-b) < tolerance; }

sony2fuji_request request(const unsigned char* pixels) {
    sony2fuji_request r{};
    r.version = SONY2FUJI_REQUEST_VERSION;
    r.struct_size = sizeof(r);
    r.input_type = SONY2FUJI_INPUT_BUFFER;
    r.input_pixels = pixels;
    r.input_width = r.input_height = 1;
    r.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
    r.input_color_space = SONY2FUJI_COLOR_SRGB;
    r.input_is_linear = 1;
    r.output_target = SONY2FUJI_TARGET_BUFFER;
    r.output_format = SONY2FUJI_OUTPUT_RGB8;
    r.size_mode = SONY2FUJI_SIZE_EXACT;
    r.target_width = r.target_height = 1;
    r.brightness = r.contrast = r.saturation = 1;
    r.temperature = 6500;
    r.wb_mode = SONY2FUJI_WB_CAMERA;
    return r;
}

void testFujiLUTs(const std::filesystem::path& dir, sony2fuji_session* session) {
    check(near(encodePhotoLog(0, LUTTransfer::FLog) * 1023, 95, .001f) &&
          near(encodePhotoLog(.18f, LUTTransfer::FLog) * 1023, 469.88278f, .002f) &&
          near(encodePhotoLog(.9f, LUTTransfer::FLog) * 1023, 705.36192f, .002f),
          "F-Log published black/gray/white anchors use its own curve");
    for (auto transfer : {LUTTransfer::FLog, LUTTransfer::FLog2, LUTTransfer::FLog2C}) {
        for (float value : {-.005f, 0.0f, .0005f, .001f, .18f, .9f, 2.0f})
            check(near(decodePhotoLog(encodePhotoLog(value, transfer), transfer), value, 1e-5f),
                  "Fuji curves round-trip low branch, pedestal, gray and super-white");
    }
    const auto redC = ColorConverter::applyMatrix(RGB(1,0,0), photoLUTInputMatrix(LUTTransfer::FLog2C));
    check(near(redC.r,.51715127f) && near(redC.g,.08863135f) && near(redC.b,.01775287f),
          "F-Gamut C matrix matches independently derived sRGB-red coordinates");
    const struct { const char* gamma; const char* gamut; LUTTransfer transfer; } inputs[] = {
        {"F-Log", "F-Gamut", LUTTransfer::FLog},
        {"F-Log2", "F-Gamut", LUTTransfer::FLog2},
        {"f-log2 C", "F-Gamut C", LUTTransfer::FLog2C}
    };
    const unsigned char gray[3] = {46,46,46};
    for (const auto& input : inputs) {
        const auto identityPath = (dir / (std::string(input.gamma) + "-identity.cube")).string();
        {
            std::ofstream file(identityPath);
            file << "#Gamma:" << input.gamma << " to Encoded Test\n#Gamut:" << input.gamut
                 << " to ITU-R BT.709\nLUT_3D_SIZE 2\n";
            for (int i=0; i<8; ++i) file << (i&1) << ' ' << ((i>>1)&1) << ' ' << ((i>>2)&1) << '\n';
        }
        const unsigned char red[3] = {255,0,0};
        const bool gamutC = input.transfer == LUTTransfer::FLog2C;
        auto identityRequest = request(gamutC ? red : gray);
        identityRequest.lut_path = identityPath.c_str(); identityRequest.lut_strength = 1;
        sony2fuji_buffer encoded{};
        check(sony2fuji_process(session, &identityRequest, &encoded) == SONY2FUJI_STATUS_OK,
              "Photo input adapter renders an identity diagnostic LUT");
        const std::array<int,3> expected = gamutC ? std::array<int,3>{127,82,49} :
            (input.transfer == LUTTransfer::FLog ? std::array<int,3>{117,117,117} : std::array<int,3>{100,100,100});
        if (encoded.data) for (int c=0; c<3; ++c)
            check(std::abs(static_cast<unsigned char*>(encoded.data)[c] - expected[c]) <= 1,
                  "Photo API uses the declared input curve and F-Gamut C matrix");
        sony2fuji_release_buffer(&encoded);
        for (const auto& output : inputs) {
            const auto path = (dir / (std::string(input.gamma) + "-" + output.gamma + ".cube")).string();
            // 表内常量取自原厂公式的独立锚点，不能由被测编码函数生成。
            const bool flog = output.transfer == LUTTransfer::FLog;
            {
                std::ofstream file(path);
                file << "#Gamma:" << input.gamma << " to " << output.gamma << "\n#Gamut:"
                     << input.gamut << " to ITU-R BT.709\nLUT_3D_SIZE 2\n";
                for (int i=0; i<8; ++i) file << (flog ? "0.459318459 0.689799217 0.092864\n"
                                                                     : "0.391007241 0.557245291 0.092864\n");
            }
            const auto lut = LUTParser::loadLUT(path);
            check(lut && lut->inputTransfer() == input.transfer && lut->outputTransfer() == output.transfer,
                  "Technical contract preserves input/output transfer independently");
            auto r = request(gray); r.lut_path = path.c_str(); r.lut_strength = 1;
            sony2fuji_gpu_config config{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(sony2fuji_gpu_config), SONY2FUJI_GPU_OFF};
            std::array<int,3> cpu{};
            for (auto mode : {SONY2FUJI_GPU_OFF, SONY2FUJI_GPU_AUTO}) {
                config.mode = mode; sony2fuji_session_set_gpu_config(session, &config);
                sony2fuji_buffer out{};
                const auto status = sony2fuji_process(session, &r, &out);
                const auto* pixels = static_cast<const unsigned char*>(out.data);
                check(status == SONY2FUJI_STATUS_OK && pixels &&
                      std::abs(pixels[0] - std::round(neutralDisplay(.18f)*255)) <= 1 &&
                      std::abs(pixels[1] - std::round(neutralDisplay(.9f)*255)) <= 1 && pixels[2] == 0,
                      "Technical output is decoded and displayed, not treated as display RGB");
                if (pixels) for (int c=0; c<3; ++c) {
                    if (mode == SONY2FUJI_GPU_OFF) cpu[c] = pixels[c];
                    else check(std::abs(cpu[c] - pixels[c]) <= 1, "Technical Auto agrees with CPU");
                }
                if (mode == SONY2FUJI_GPU_OFF)
                    check(sony2fuji_session_get_last_backend(session) == SONY2FUJI_BACKEND_CPU,
                          "Technical Off reports the CPU backend");
                sony2fuji_release_buffer(&out);
            }
            config.mode = SONY2FUJI_GPU_OFF; sony2fuji_session_set_gpu_config(session, &config);
            r.lut_strength = .5f;
            sony2fuji_buffer blended{};
            check(sony2fuji_process(session, &r, &blended) == SONY2FUJI_STATUS_OK, "Technical half-strength renders");
            if (blended.data) for (int c=0; c<3; ++c)
                check(std::abs(static_cast<unsigned char*>(blended.data)[c] -
                    (neutralDisplay(46.0f/255)*255 + cpu[c])*.5f) <= 1, "Technical blend uses display endpoints");
            sony2fuji_release_buffer(&blended);
        }
    }
}

bool hasJpegStagingFile(const std::filesystem::path& directory) {
    for (const auto& entry : std::filesystem::directory_iterator(directory)) {
        const std::string name = entry.path().filename().string();
        if (name.find(".rawlab-jpeg-") == 0) return true;
        if (name.size() >= 7 && name.rfind("rlj", 0) == 0 && entry.path().extension() == ".tmp") {
            return true;
        }
    }
    return false;
}

std::string readTextFile(const std::filesystem::path& path) {
    std::ifstream file(path, std::ios::binary);
    return std::string((std::istreambuf_iterator<char>(file)), {});
}

void writeTextFile(const std::filesystem::path& path, const std::string& content) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    file.write(content.data(), static_cast<std::streamsize>(content.size()));
}

void testJpegExportWriteSafety(const std::filesystem::path& parentDir, sony2fuji_session* session) {
    const auto jpegDir = parentDir / "jpeg-write-safety";
    std::filesystem::create_directories(jpegDir);

    // Keep pixel count below parallelPixelRanges's 65536 threshold so fork() children stay off libdispatch.
    ImageData noisy(128, 128);
    std::vector<unsigned char> noisyBytes(128 * 128 * 3);
    uint32_t seed = 0x12345678u;
    for (size_t i = 0; i < noisy.pixels.size(); ++i) {
        seed = seed * 1664525u + 1013904223u;
        const unsigned char r = static_cast<unsigned char>((seed >> 16) & 0xFFu);
        seed = seed * 1664525u + 1013904223u;
        const unsigned char g = static_cast<unsigned char>((seed >> 16) & 0xFFu);
        seed = seed * 1664525u + 1013904223u;
        const unsigned char b = static_cast<unsigned char>((seed >> 16) & 0xFFu);
        noisy.pixels[i] = RGB(r / 255.0f, g / 255.0f, b / 255.0f);
        noisyBytes[i * 3 + 0] = r;
        noisyBytes[i * 3 + 1] = g;
        noisyBytes[i * 3 + 2] = b;
    }

    const auto validTarget = jpegDir / "replace-existing.jpg";
    writeTextFile(validTarget, "old target");
    check(ImageEncoder::saveJPEG(noisy, validTarget.string(), 95) == ErrorCode::Success,
          "JPEG writes and atomically replaces an existing target");
    const std::string encodedJpeg = readTextFile(validTarget);
    check(encodedJpeg.size() > 8192 &&
          static_cast<unsigned char>(encodedJpeg[0]) == 0xFF &&
          static_cast<unsigned char>(encodedJpeg[1]) == 0xD8 &&
          static_cast<unsigned char>(encodedJpeg[encodedJpeg.size() - 2]) == 0xFF &&
          static_cast<unsigned char>(encodedJpeg[encodedJpeg.size() - 1]) == 0xD9,
          "JPEG output has valid SOI/EOI markers and exceeds stdio buffer size");
    check(!hasJpegStagingFile(jpegDir), "successful JPEG export leaves no staging file");

    const auto invalidTarget = jpegDir / "invalid-preserves.jpg";
    writeTextFile(invalidTarget, "preserve this target");
    ImageData mismatched(2, 2);
    mismatched.pixels.resize(1);
    check(ImageEncoder::saveJPEG(ImageData(), invalidTarget.string(), 95) == ErrorCode::ProcessingError &&
          ImageEncoder::saveJPEG(mismatched, invalidTarget.string(), 95) == ErrorCode::ProcessingError,
          "JPEG rejects invalid ImageData as a processing error");
    check(readTextFile(invalidTarget) == "preserve this target" && !hasJpegStagingFile(jpegDir),
          "invalid JPEG input preserves existing target and creates no staging file");

    const auto missingParentTarget = jpegDir / "absent" / "out.jpg";
    check(ImageEncoder::saveJPEG(noisy, missingParentTarget.string(), 95) == ErrorCode::IOError &&
          !std::filesystem::exists(missingParentTarget),
          "JPEG missing output directory returns IOError without creating target");

    auto jpegRequest = request(noisyBytes.data());
    jpegRequest.input_width = 128;
    jpegRequest.input_height = 128;
    jpegRequest.size_mode = SONY2FUJI_SIZE_EXACT;
    jpegRequest.target_width = 128;
    jpegRequest.target_height = 128;
    jpegRequest.intent = SONY2FUJI_INTENT_FINAL;
    jpegRequest.output_target = SONY2FUJI_TARGET_FILE;
    jpegRequest.output_format = SONY2FUJI_OUTPUT_JPEG;
    jpegRequest.jpeg_quality = 95;
    const std::string missingJpegPath = missingParentTarget.string();
    jpegRequest.output_path = missingJpegPath.c_str();
    check(sony2fuji_process(session, &jpegRequest, nullptr) == SONY2FUJI_STATUS_OUTPUT_IO_ERROR &&
          !std::filesystem::exists(missingParentTarget),
          "C ABI JPEG storage failure maps to SONY2FUJI_STATUS_OUTPUT_IO_ERROR");

    const auto blockedDir = jpegDir / "blocked-dir";
    std::filesystem::create_directory(blockedDir);
    const auto marker = blockedDir / "keep.txt";
    writeTextFile(marker, "keep directory contents");
    check(ImageEncoder::saveJPEG(noisy, blockedDir.string(), 95) == ErrorCode::IOError &&
          std::filesystem::is_directory(blockedDir) &&
          readTextFile(marker) == "keep directory contents" &&
          !hasJpegStagingFile(jpegDir),
          "JPEG directory target fails cleanly without leaving staging files");

#ifndef _WIN32
    auto runLimitedWriteChild = [](rlim_t byteLimit, auto&& fn) -> int {
        const pid_t child = fork();
        if (child < 0) return -1;
        if (child == 0) {
            std::signal(SIGXFSZ, SIG_IGN);
            const struct rlimit limit = {byteLimit, byteLimit};
            if (setrlimit(RLIMIT_FSIZE, &limit) != 0) _exit(2);
            _exit(fn() ? 0 : 1);
        }
        int status = 0;
        if (waitpid(child, &status, 0) != child || !WIFEXITED(status)) return -2;
        return WEXITSTATUS(status);
    };

    const auto midwriteMissingTarget = jpegDir / "midwrite-missing.jpg";
    const int missingExit = runLimitedWriteChild(4096, [&]() {
        return ImageEncoder::saveJPEG(noisy, midwriteMissingTarget.string(), 95) == ErrorCode::IOError;
    });
    check(missingExit == 0, "mid-write JPEG fwrite failure returns ErrorCode::IOError");
    check(missingExit >= 0 && !std::filesystem::exists(midwriteMissingTarget) && !hasJpegStagingFile(jpegDir),
          "mid-write JPEG failure leaves neither truncated target nor staging file");

    const auto midwriteExistingTarget = jpegDir / "midwrite-existing.jpg";
    writeTextFile(midwriteExistingTarget, "preserve existing jpeg");
    const std::string existingPathString = midwriteExistingTarget.string();
    jpegRequest.output_path = existingPathString.c_str();
    const int existingExit = runLimitedWriteChild(4096, [&]() {
        return sony2fuji_process(session, &jpegRequest, nullptr) == SONY2FUJI_STATUS_OUTPUT_IO_ERROR;
    });
    check(existingExit == 0,
          "C ABI mid-write JPEG failure returns SONY2FUJI_STATUS_OUTPUT_IO_ERROR");
    check(existingExit >= 0 && readTextFile(midwriteExistingTarget) == "preserve existing jpeg" &&
          !hasJpegStagingFile(jpegDir),
          "mid-write JPEG failure preserves pre-existing target intact");

    ImageData tiny(8, 8);
    for (auto& pixel : tiny.pixels) pixel = RGB(0.4f, 0.6f, 0.2f);
    const auto flushFailTarget = jpegDir / "flush-fail.jpg";
    const int flushExit = runLimitedWriteChild(128, [&]() {
        return ImageEncoder::saveJPEG(tiny, flushFailTarget.string(), 95) == ErrorCode::IOError;
    });
    check(flushExit == 0 && !std::filesystem::exists(flushFailTarget) &&
          !hasJpegStagingFile(jpegDir),
          "stdio-buffered small JPEG flush failure returns IOError and leaves no partial file");
#endif
}

int main(int argc, char** argv) {
    std::cout << std::unitbuf;
    if (argc > 2) return 2;
    if (argc == 2) {
        const char* argRaw = *argv[1] ? argv[1] : nullptr;
        const char* envRaw = std::getenv("RAWLAB_TEST_RAW");
        if (envRaw && !*envRaw) envRaw = nullptr;
        const char* thumbnailRaw = argRaw ? argRaw : envRaw;
        if (!thumbnailRaw) {
            std::cout << "SKIP color_contracts_raw: supply SONY2FUJI_TEST_RAW or RAWLAB_TEST_RAW\n";
            return 77;
        }
        if (!std::filesystem::is_regular_file(std::filesystem::u8path(thumbnailRaw))) {
            std::cerr << "FAIL color_contracts_raw: RAW sample does not exist: " << thumbnailRaw << '\n';
            return 1;
        }
#ifdef _WIN32
        HANDLE worker = CreateThread(nullptr, 512*1024, [](LPVOID path)->DWORD {
            return loadPreviewLuminance(static_cast<const char*>(path)).empty() ? 1 : 0;
        }, const_cast<char*>(thumbnailRaw), STACK_SIZE_PARAM_IS_A_RESERVATION, nullptr);
        DWORD result = 1;
        if (worker) { WaitForSingleObject(worker, INFINITE); GetExitCodeThread(worker, &result); CloseHandle(worker); }
        check(worker && result == 0,"Preview decode fits a desktop worker thread stack");
#else
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setstacksize(&attr,512*1024);
        pthread_t worker;
        const int started=pthread_create(&worker,&attr,[](void* path)->void* {
            return loadPreviewLuminance(static_cast<const char*>(path)).empty() ? reinterpret_cast<void*>(1) : nullptr;
        },const_cast<char*>(thumbnailRaw));
        pthread_attr_destroy(&attr);
        void* result=nullptr;
        if (!started) pthread_join(worker,&result);
        check(!started && !result,"Preview decode fits a desktop worker thread stack");
#endif
        return failures ? 1 : 0;
    }
    check(!RAWProcessOptions().matchEmbeddedPreviewExposure, "Default exposure does not meter the embedded JPEG");
    check(near(sceneExposureEV(.35f),1.05f) && near(sceneExposureEV(-.5f),.2f) &&
        near(sceneExposureEV(-999),.7f), "DNG baseline offsets are independent of scene content");
    check(near(neutralDisplay(.1845f),GammaConverter::applySRGBGamma(.1845f)) &&
        near(neutralDisplay(0),0), "Neutral view anchors middle gray and black");
    std::vector<float> source(100,.045f), preview(100,.18f);
    check(near(estimatePreviewExposureEV(source,preview),2), "Preview supplies default +2 EV");
    std::fill(preview.begin(),preview.end(),.01125f);
    check(near(estimatePreviewExposureEV(source,preview),-2), "Dark camera preview stays dark, not middle gray");
    preview=source;
    std::fill_n(preview.begin(),10,1.0f);
    check(near(estimatePreviewExposureEV(source,preview),0), "Specular highlights do not drive default exposure");
    check(near(estimatePreviewExposureEV({},preview),0) &&
          near(estimatePreviewExposureEV(source,std::vector<float>(100,0)),0) &&
          near(estimatePreviewExposureEV(source,std::vector<float>(100,1)),0), "Missing/black/clipped preview leaves sensor baseline");
    check(loadPreviewLuminance("/missing-rawtools-exposure.raw").empty(), "Unreadable preview is optional");
    const auto dir = std::filesystem::temp_directory_path() / ("rawtools-tests-" + std::to_string(getpid()));
    std::filesystem::create_directories(dir);
    auto cube = dir / "swap.cube";
    {
        std::ofstream f(cube);
        f << "TITLE \"Swap\"\nLUT_3D_SIZE 2\nDOMAIN_MIN 0.25 0.25 0.25\nDOMAIN_MAX 0.75 0.75 0.75\n";
        for (int b=0;b<2;++b) for (int g=0;g<2;++g) for (int r=0;r<2;++r)
            f << 2*b << ' ' << g << ' ' << r << '\n';
    }
    auto lut = LUTParser::loadLUTCached(cube.string());
    check(lut && lut->isValid(), "CUBE loads");
    sony2fuji_look_format importedFormat = SONY2FUJI_LOOK_RLOOK;
    uint32_t importedVersion = 99;
    check(sony2fuji_validate_look(cube.u8string().c_str(), &importedFormat, &importedVersion) == SONY2FUJI_STATUS_UNSUPPORTED &&
          importedFormat == SONY2FUJI_LOOK_UNKNOWN && importedVersion == 0,
          "look import rejects an untagged CUBE and clears output information");
    check(sony2fuji_validate_look(nullptr, &importedFormat, &importedVersion) == SONY2FUJI_STATUS_INVALID_ARGUMENT &&
          sony2fuji_validate_look("", nullptr, nullptr) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "look import rejects an absent path without creating a session");
    check(sony2fuji_validate_look((dir / "missing.cube").u8string().c_str(), nullptr, nullptr) == SONY2FUJI_STATUS_IO_ERROR &&
          sony2fuji_validate_look(dir.u8string().c_str(), nullptr, nullptr) == SONY2FUJI_STATUS_IO_ERROR,
          "look import distinguishes missing files and directories");
    if (lut) {
        LUTApplicator apply(lut);
        auto red = apply.apply(RGB(.75f,.25f,.25f));
        check(near(red.r,0) && near(red.b,1), "CUBE standard R-fast channel swap");
        auto blue = apply.apply(RGB(.25f,.25f,.75f));
        check(near(blue.r,2), "CUBE preserves table values above one");
        auto middle = apply.apply(RGB(.375f,.375f,.375f));
        check(near(middle.r,.5f) && near(middle.g,.25f), "CUBE domain coordinates");
        if (std::getenv("SONY2FUJI_TEST_GPU")) {
            ImageData gpu(3,1);
            gpu.pixels={RGB(.75f,.25f,.25f),RGB(.25f,.25f,.75f),RGB(.375f,.375f,.375f)};
            auto cpu=gpu;
            apply.applyToImage(cpu);
            const auto status=applyLUTWithConfig(lut,gpu,GpuConfig{GpuMode::Force});
            bool same=status==ErrorCode::Success;
            for (size_t i=0;i<gpu.pixels.size();++i)
                same=same && near(gpu.pixels[i].r,cpu.pixels[i].r,.001f) &&
                    near(gpu.pixels[i].g,cpu.pixels[i].g,.001f) && near(gpu.pixels[i].b,cpu.pixels[i].b,.001f);
            check(same,"Metal/CPU parity including non-unit domain and tiny buffer");
        }
    }
    check(near(GammaConverter::applyFLog2(.18f)*1023,400,.001f), "F-Log2 reference gray");
    ImageData ramp(3,1);
    ramp.pixels = {RGB(1,1,1),RGB(2,2,2),RGB(4,4,4)};
    GammaConverter::FLog2Options options;
    GammaConverter::applyFLog2ToImage(ramp,options);
    check(near(ramp.pixels[1].r,.64144017f), "F-Log2 preserves super-white exposure");
    check(near(ramp.pixels[2].r,.71496770f), "F-Log2 is not histogram normalized");

    ImageData red(1,1); red.pixels[0] = RGB(1,0,0);
    auto png = dir / "red.png";
    check(ImageEncoder::savePNG(red,png.string()) == ErrorCode::Success, "PNG writes");
    std::ifstream pf(png,std::ios::binary);
    std::vector<unsigned char> bytes((std::istreambuf_iterator<char>(pf)),{});
    pf.close(); // Windows cannot remove the temporary directory while this file is open.
    check(bytes.size()>25 && bytes[24]==16, "PNG IHDR declares sixteen bits");
    auto read32 = [&](size_t offset) { return (uint32_t(bytes[offset])<<24) |
        (uint32_t(bytes[offset+1])<<16) | (uint32_t(bytes[offset+2])<<8) | bytes[offset+3]; };
    std::vector<unsigned char> compressed;
    for (size_t offset=8; offset+12<=bytes.size();) {
        uint32_t size=read32(offset);
        if (offset+size+12>bytes.size()) break;
        if (std::string(reinterpret_cast<const char*>(bytes.data()+offset+4),4)=="IDAT")
            compressed.insert(compressed.end(),bytes.begin()+offset+8,bytes.begin()+offset+8+size);
        offset+=size+12;
    }
    unsigned char decoded[7]={}; uLongf length=sizeof(decoded);
    check(uncompress(decoded,&length,compressed.data(),compressed.size())==Z_OK && length==7 &&
        decoded[0]==0 && decoded[1]==255 && decoded[2]==255 && decoded[3]==0 && decoded[5]==0,
        "PNG sixteen-bit red survives decompression");
    bool nativeRejected=false;
    try { ColorConverter().convert(RGB(1,0,0),ColorSpace::SonyNative,ColorSpace::FujiFilm_FGamut); }
    catch (const std::invalid_argument&) { nativeRejected=true; }
    check(nativeRejected,"Uncalibrated native matrix is rejected");

    {
        ImageData negW(-4, 5), negH(5, -4), zeroW(0, 5);
        check(negW.width == 0 && negW.height == 0 && negW.pixels.empty() &&
              negH.width == 0 && negH.height == 0 && negH.pixels.empty() &&
              zeroW.width == 0 && zeroW.height == 0 && zeroW.pixels.empty(),
              "ImageData clamps non-positive dimensions consistently across members and buffer");
        bool overflowRejected = false;
        try { ImageData hugeImage(2000000000, 2000000000); (void)hugeImage; }
        catch (const std::bad_alloc&) { overflowRejected = true; }
        check(overflowRejected, "ImageData rejects unrepresentable pixel byte counts");
    }

    sony2fuji_session* session=nullptr;
    sony2fuji_session_create(&session);
    const unsigned char dngPixels[3] = {128, 70, 220};
    {
        const unsigned char widePixels[6] = {128, 70, 220, 64, 120, 180};
        auto expectRejected = [&](const sony2fuji_request& req, const char* label, sony2fuji_session* target = nullptr) {
            sony2fuji_buffer hugeOut{};
            const auto st = sony2fuji_process(target ? target : session, &req, &hugeOut);
            const bool rejected = st == SONY2FUJI_STATUS_INVALID_ARGUMENT && !hugeOut.data;
            sony2fuji_release_buffer(&hugeOut);
            check(rejected, label);
        };

        auto exactCap = request(dngPixels);
        exactCap.size_mode = SONY2FUJI_SIZE_EXACT;
        exactCap.target_width = exactCap.target_height = 11314;
        expectRejected(exactCap, "EXACT output above 128M pixels is rejected with valid out_buffer");
        exactCap.target_width = exactCap.target_height = 2000000000u;
        expectRejected(exactCap, "EXACT int-overflow output size is rejected with valid out_buffer");

        auto fitLong = request(widePixels);
        fitLong.input_width = 2; fitLong.input_height = 1;
        fitLong.size_mode = SONY2FUJI_SIZE_FIT_LONG_EDGE;
        fitLong.long_edge = 16002;
        expectRejected(fitLong, "FIT_LONG_EDGE output above 128M pixels is rejected");
        fitLong.long_edge = 2000000000u;
        expectRejected(fitLong, "FIT_LONG_EDGE extreme long_edge is rejected without UB");

        auto previewLong = request(dngPixels);
        previewLong.size_mode = SONY2FUJI_SIZE_NATIVE;
        previewLong.intent = SONY2FUJI_INTENT_PREVIEW;
        previewLong.preview_long_edge = 11314;
        expectRejected(previewLong, "PREVIEW preview_long_edge override above 128M pixels is rejected");

        auto fitShort = request(widePixels);
        fitShort.input_width = 2; fitShort.input_height = 1;
        fitShort.size_mode = SONY2FUJI_SIZE_FIT_SHORT_EDGE;
        fitShort.short_edge = 8001;
        expectRejected(fitShort, "FIT_SHORT_EDGE output above 128M pixels is rejected");
        fitShort.short_edge = 2000000000u;
        expectRejected(fitShort, "FIT_SHORT_EDGE extreme short_edge is rejected without UB");

        const std::string absentRaw = (dir / "missing-size-cap.ARW").string();
        auto rawEarly = request(nullptr);
        rawEarly.input_type = SONY2FUJI_INPUT_RAW;
        rawEarly.input_path = absentRaw.c_str();
        rawEarly.intent = SONY2FUJI_INTENT_FINAL;
        rawEarly.size_mode = SONY2FUJI_SIZE_EXACT;
        rawEarly.target_width = rawEarly.target_height = 11314;
        expectRejected(rawEarly, "Oversized RAW request is rejected during request validation before RAW decode");

        sony2fuji_session* geomSession = nullptr;
        sony2fuji_session_create(&geomSession);
        sony2fuji_geometry_config geom{};
        geom.version = SONY2FUJI_GEOMETRY_CONFIG_VERSION;
        geom.struct_size = sizeof(geom);
        geom.crop_width = geom.crop_height = 1.0f;
        geom.quarter_turns = 1;
        sony2fuji_session_set_geometry(geomSession, &geom);
        const std::string absentLut = (dir / "missing-size-cap.cube").string();
        auto finalGeom = fitLong;
        finalGeom.long_edge = 16002;
        finalGeom.intent = SONY2FUJI_INTENT_FINAL;
        finalGeom.lut_path = absentLut.c_str();
        finalGeom.lut_strength = 1.0f;
        expectRejected(finalGeom, "FINAL+geometry oversized FIT_LONG_EDGE is rejected before LUT/pixel work", geomSession);
        sony2fuji_session_destroy(geomSession);
    }
    auto dngRequest = request(dngPixels);
    const std::string dngPath = (dir / "rendered.dng").string();
    dngRequest.output_target = SONY2FUJI_TARGET_FILE;
    dngRequest.output_format = static_cast<sony2fuji_output_format>(4);
    dngRequest.output_path = dngPath.c_str();
    dngRequest.intent = SONY2FUJI_INTENT_FINAL;
    check(sony2fuji_process(session, &dngRequest, nullptr) == SONY2FUJI_STATUS_OK &&
          std::filesystem::file_size(dngPath) > 8, "C ABI writes rendered DNG as a file");
    const std::string linearDngFixture = std::string(TEST_SOURCE_DIR) + "/tests/fixtures/linear-uncompressed.dng";
    {
        sony2fuji_session* aeSession = nullptr;
        sony2fuji_session_create(&aeSession);

        sony2fuji_request aeRaw{};
        aeRaw.version = SONY2FUJI_REQUEST_VERSION;
        aeRaw.struct_size = sizeof(aeRaw);
        aeRaw.input_type = SONY2FUJI_INPUT_RAW;
        aeRaw.input_path = linearDngFixture.c_str();
        aeRaw.wb_mode = SONY2FUJI_WB_CAMERA;
        aeRaw.wb_mul[0] = aeRaw.wb_mul[1] = aeRaw.wb_mul[2] = aeRaw.wb_mul[3] = 1.0f;
        aeRaw.brightness = aeRaw.contrast = aeRaw.saturation = 1.0f;
        aeRaw.temperature = 6500.0f;
        float rawEv = 999.0f;
        const auto rawAeStatus = sony2fuji_session_estimate_auto_exposure(aeSession, &aeRaw, &rawEv);

        sony2fuji_request aePreviewBuf{};
        aePreviewBuf.version = SONY2FUJI_REQUEST_VERSION;
        aePreviewBuf.struct_size = sizeof(aePreviewBuf);
        aePreviewBuf.input_type = SONY2FUJI_INPUT_BUFFER;
        aePreviewBuf.input_pixels = dngPixels;
        aePreviewBuf.input_width = aePreviewBuf.input_height = 1;
        aePreviewBuf.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
        aePreviewBuf.input_color_space = SONY2FUJI_COLOR_SRGB;
        aePreviewBuf.input_is_linear = 1;
        aePreviewBuf.wb_mode = SONY2FUJI_WB_CAMERA;
        aePreviewBuf.brightness = aePreviewBuf.contrast = aePreviewBuf.saturation = 1.0f;
        aePreviewBuf.temperature = 6500.0f;
        aePreviewBuf.intent = SONY2FUJI_INTENT_PREVIEW;
        aePreviewBuf.preview_long_edge = 1280;
        float bufEv = 999.0f;
        const auto bufAeStatus = sony2fuji_session_estimate_auto_exposure(aeSession, &aePreviewBuf, &bufEv);

        sony2fuji_session_destroy(aeSession);
        check(aeRaw.size_mode == SONY2FUJI_SIZE_EXACT && aeRaw.target_width == 0 && aeRaw.target_height == 0 &&
              rawAeStatus == SONY2FUJI_STATUS_OK && std::isfinite(rawEv) && rawEv >= -4.0f && rawEv <= 4.0f &&
              aePreviewBuf.size_mode == SONY2FUJI_SIZE_EXACT && aePreviewBuf.target_width == 0 && aePreviewBuf.target_height == 0 &&
              bufAeStatus == SONY2FUJI_STATUS_OK && std::isfinite(bufEv) && bufEv >= -4.0f && bufEv <= 4.0f,
              "Auto exposure succeeds with zero-initialized size fields");
    }
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    {
        bool aiRuntimeAvailable = true;
#ifdef _WIN32
        std::optional<ai::DirectMLAdapter> aiAdapter;
        try { aiAdapter = ai::findDirectMLAdapter(); } catch (const std::runtime_error&) { aiRuntimeAvailable = false; }
#endif
        if (aiRuntimeAvailable) {
            const auto aiModelDir = dir / "ai-model";
            const auto aiCacheDir = dir / "ai-cache";
            std::filesystem::create_directories(aiModelDir);
            nlohmann::json manifest = {
                {"format_version", 1}, {"protocol", "rawlab-dualdn-v1"},
                {"model_id", "dualdn-big-restormer-v1"}, {"source_revision", ai::dualdnSourceRevision},
                {"weights_sha256", ai::dualdnWeightsSHA256}, {"tile_size", 640}, {"production_geometry", true},
                {"raw_core", 384}, {"raw_halo", 128}, {"rgb_core", 512}, {"rgb_halo", 64},
                {"packed_order", {"R", "G_top", "G_bottom", "B"}},
                {"input_floor", 1e-8}, {"variance_floor", 1e-7}, {"sigma_semantics", "variance"},
                {"isp", {{"demosaic", "AHD"}, {"gamma", "Rec709"}, {"reference", "D65"}, {"alpha", 0}, {"bgu", false}}}
            };
            for (const char* name : {"raw", "isp", "rgb"}) {
                const auto file = aiModelDir / (std::string(name) + ".onnx");
                { std::ofstream(file, std::ios::binary) << "test package integrity"; }
                manifest["graphs"][name] = {
                    {"file", file.filename().u8string()},
                    {"sha256", ai::sha256File(file.u8string())},
                    {"bytes", std::filesystem::file_size(file)}
                };
            }
            const auto blindFile = aiModelDir / "blind_rgb.onnx";
            const auto licenseFile = aiModelDir / "Restormer-LICENSE.txt";
            { std::ofstream(blindFile, std::ios::binary) << "RGB model package integrity fixture"; }
            std::filesystem::copy_file(
                std::filesystem::u8path(std::string(TEST_SOURCE_DIR) + "/tests/fixtures/restormer-v1-LICENSE.txt"),
                licenseFile);
            manifest["blind_rgb"] = {
                {"model_id", "restormer-real-srgb-v1"}, {"protocol", "rawlab-scene-rgb-v1"},
                {"source_revision", ai::restormerSourceRevision}, {"weights_sha256", ai::restormerWeightsSHA256},
                {"tile_size", 640}, {"core", 512}, {"halo", 64}, {"input", "encoded_rgb"}, {"output", "denoised_rgb"},
                {"file", "blind_rgb.onnx"}, {"bytes", std::filesystem::file_size(blindFile)},
                {"sha256", ai::sha256File(blindFile.u8string())},
                {"license_file", "Restormer-LICENSE.txt"}, {"license_sha256", ai::restormerLicenseSHA256}
            };
            { std::ofstream(aiModelDir / "manifest.json", std::ios::binary) << manifest.dump(); }

#ifdef _WIN32
            constexpr auto aiBackend = SONY2FUJI_AI_DIRECTML;
            constexpr auto coreBackend = ai::Backend::DirectML;
            const std::string runtimeIdentity = ai::NetworkGraph::runtimeVersion(coreBackend, aiAdapter ? &*aiAdapter : nullptr);
#else
            constexpr auto aiBackend = SONY2FUJI_AI_COREML;
            constexpr auto coreBackend = ai::Backend::CoreML;
            const std::string runtimeIdentity = ai::NetworkGraph::runtimeVersion(coreBackend);
#endif
            const auto package = ai::loadModelPackage(aiModelDir.u8string());
            const auto fullIdentity = package.digest + ":" + runtimeIdentity;
            const auto digest = ai::sha256Bytes(fullIdentity.data(), fullIdentity.size());
            RAWProcessOptions aiOptions;
            aiOptions.legacySonyCrop = true;
            const auto rawKey = ai::rawCacheKey(linearDngFixture, digest, static_cast<int>(coreBackend), aiOptions.legacySonyCrop);
            const float zeroScene[3] = {0.0f, 0.0f, 0.0f};
            ai::DenoiseCache(aiCacheDir.u8string()).store(
                ai::sceneRGBCacheKey(rawKey, aiOptions), ai::CacheKind::SceneRGB, 1, 1, zeroScene, 3, {}, "test-identity");

            sony2fuji_session* aiSession = nullptr;
            sony2fuji_session_create(&aiSession);
            const std::string modelDirUtf8 = aiModelDir.u8string();
            const std::string cacheDirUtf8 = aiCacheDir.u8string();
            sony2fuji_ai_denoise_config aiConfig{};
            aiConfig.version = SONY2FUJI_AI_DENOISE_CONFIG_VERSION;
            aiConfig.struct_size = sizeof(aiConfig);
            aiConfig.enabled = 1;
            aiConfig.backend = aiBackend;
            aiConfig.model_directory = modelDirUtf8.c_str();
            aiConfig.cache_directory = cacheDirUtf8.c_str();
            const auto setAiStatus = sony2fuji_session_set_ai_denoise(aiSession, &aiConfig);

            sony2fuji_request aiReq{};
            aiReq.version = SONY2FUJI_REQUEST_VERSION;
            aiReq.struct_size = sizeof(aiReq);
            aiReq.input_type = SONY2FUJI_INPUT_RAW;
            aiReq.input_path = linearDngFixture.c_str();
            aiReq.wb_mode = SONY2FUJI_WB_CAMERA;
            aiReq.wb_mul[0] = aiReq.wb_mul[1] = aiReq.wb_mul[2] = aiReq.wb_mul[3] = 1.0f;
            aiReq.brightness = aiReq.contrast = aiReq.saturation = 1.0f;
            aiReq.temperature = 6500.0f;
            const auto prepStatus = sony2fuji_session_prepare_ai(aiSession, &aiReq, nullptr, nullptr);
            sony2fuji_session_destroy(aiSession);

            check(setAiStatus == SONY2FUJI_STATUS_OK &&
                  aiReq.size_mode == SONY2FUJI_SIZE_EXACT && aiReq.target_width == 0 && aiReq.target_height == 0 &&
                  prepStatus == SONY2FUJI_STATUS_OK,
                  "AI preparation succeeds with zero-initialized size fields");
        } else {
            std::cout << "SKIP AI preparation zero-init check (no hardware AI adapter)\n";
        }
    }
#else
    std::cout << "SKIP AI preparation zero-init check (enable SONY2FUJI_ENABLE_AI_DENOISE)\n";
#endif
    const std::string missingDngPath = (dir / "absent" / "out.dng").string();
    dngRequest.output_path = missingDngPath.c_str();
    check(sony2fuji_process(session, &dngRequest, nullptr) == SONY2FUJI_STATUS_OUTPUT_IO_ERROR,
          "DNG storage failures have a distinct output IO status for batch cancellation");
    dngRequest.output_path = dngPath.c_str();
    dngRequest.intent = SONY2FUJI_INTENT_PREVIEW;
    check(sony2fuji_process(session, &dngRequest, nullptr) == SONY2FUJI_STATUS_UNSUPPORTED,
          "DNG rejects preview intent instead of exporting a proxy");
    dngRequest.intent = SONY2FUJI_INTENT_FINAL;
    dngRequest.output_target = SONY2FUJI_TARGET_BUFFER;
    sony2fuji_buffer dngBuffer{};
    check(sony2fuji_process(session, &dngRequest, &dngBuffer) == SONY2FUJI_STATUS_UNSUPPORTED,
          "Rendered DNG is not a preview buffer format");
    dngRequest.output_target = SONY2FUJI_TARGET_FILE;
    dngRequest.input_type = SONY2FUJI_INPUT_RAW;
    const std::string missingInputPath = (dir / "missing-input.ARW").string();
    dngRequest.input_path = missingInputPath.c_str();
    check(sony2fuji_process(session, &dngRequest, nullptr) == SONY2FUJI_STATUS_IO_ERROR,
          "Missing RAW input remains a source IO error, not an output storage error");
    dngRequest.input_path = dngPath.c_str();
    check(sony2fuji_process(session, &dngRequest, nullptr) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "DNG output cannot overwrite the original input");
    {
        const auto unsupported = cube.u8string();
        const auto missing = (dir / "missing.dng").u8string();
        RAWProcessor raw;
        check(raw.loadFile(unsupported) == ErrorCode::InvalidFormat,
              "Existing non-RAW input is unsupported, not a missing file");
        check(raw.loadFile(missing) == ErrorCode::FileNotFound,
              "Missing RAW input remains a file error");
        auto rawRequest = request(nullptr);
        rawRequest.input_type = SONY2FUJI_INPUT_RAW;
        sony2fuji_buffer rawOutput{};
        rawRequest.input_path = unsupported.c_str();
        check(sony2fuji_process(session, &rawRequest, &rawOutput) == SONY2FUJI_STATUS_UNSUPPORTED &&
              !rawOutput.data, "RAW C ABI distinguishes unsupported input from IO failure");
        rawRequest.input_path = missing.c_str();
        check(sony2fuji_process(session, &rawRequest, &rawOutput) == SONY2FUJI_STATUS_IO_ERROR &&
              !rawOutput.data, "RAW C ABI preserves missing-path IO failure");
    }
    testJpegExportWriteSafety(dir, session);
    testFujiLUTs(dir, session);
    const unsigned char black[3]={0,0,0};
    auto r=request(black);
    std::string provia = std::string(TEST_SOURCE_DIR)+"/flog-2-new/FLog2_to_PROVIA_65grid_V.1.00.cube";
    r.lut_path=provia.c_str(); r.lut_strength=.01f;
    sony2fuji_buffer out{};
    auto status=sony2fuji_process(session,&r,&out);
    check(status==SONY2FUJI_STATUS_OK && static_cast<unsigned char*>(out.data)[0]<=1, "LUT near-zero strength preserves black");
    sony2fuji_release_buffer(&out);
    for (const auto& file : std::filesystem::directory_iterator(std::string(TEST_SOURCE_DIR)+"/flog-2-new")) {
        if (file.path().extension()!=".cube") continue;
        const auto film=LUTParser::loadLUT(file.path().string());
        check(film && film->isPhotoLUT(), file.path().filename().string().c_str());
    }
    std::string log = std::string(TEST_SOURCE_DIR)+"/flog-2-new/FLog2_to_FLog2-709_65grid_V.1.00.cube";
    r.lut_path=log.c_str(); r.lut_strength=1;
    check(sony2fuji_process(session,&r,&out)==SONY2FUJI_STATUS_OK, "Photo pipeline displays technical Log output");
    sony2fuji_release_buffer(&out);
    const struct { const char* gamma; const char* gamut; bool accepted; } contracts[] = {
        {"F-Log2 to EKTAR 100 Phuket", "F-Gamut to ITU-R BT.709", true},
        {"F-Log2 to My Custom Look", "F-Gamut to ITU-R BT.709", true},
        {"f-log2 TO independently-named-look", "f-gamut TO itu-r bt.709", true},
        {"F-Log to ETERNA", "F-Gamut to ITU-R BT.709", true},
        {"F-Log2C to ETERNA", "F-Gamut C to ITU-R BT.709", true},
        {"F-Log2C to ETERNA", "F-Gamut to ITU-R BT.709", false},
        {"F-Log to ETERNA", "F-Gamut C to ITU-R BT.709", false},
        {"F-Log2 to", "F-Gamut to ITU-R BT.709", false},
        {"", "F-Gamut to ITU-R BT.709", false},
        {"sRGB to My Custom Look", "F-Gamut to ITU-R BT.709", false},
        {"F-Log2 to My Custom Look", "F-Gamut C to ITU-R BT.709", false},
        {"F-Log2 to My Custom Look", "F-Gamut to Adobe RGB", false},
        {"F-Log2 to My Custom Look", "", false}
    };
    for (size_t i=0; i<std::size(contracts); ++i) {
        const auto& contract = contracts[i];
        const auto path = (dir / ("contract-" + std::to_string(i) + ".cube")).string();
        {
            std::ofstream file(path);
            file << "#Gamma:" << contract.gamma << "\n#Gamut:" << contract.gamut << "\nLUT_3D_SIZE 2\n";
            for (int point=0; point<8; ++point) file << "0.25 0.5 0.75\n";
        }
        const auto custom = LUTParser::loadLUT(path);
        check(custom && custom->isPhotoLUT()==contract.accepted,
              ("Photo contract without film-name allowlist: " + std::to_string(i)).c_str());
        std::ifstream beforeStream(path, std::ios::binary);
        const std::string before((std::istreambuf_iterator<char>(beforeStream)), {});
        beforeStream.close();
        importedFormat = SONY2FUJI_LOOK_UNKNOWN; importedVersion = 99;
        const auto validated = sony2fuji_validate_look(path.c_str(), &importedFormat, &importedVersion);
        check(validated == (contract.accepted ? SONY2FUJI_STATUS_OK : SONY2FUJI_STATUS_UNSUPPORTED) &&
              importedFormat == (contract.accepted ? SONY2FUJI_LOOK_CUBE : SONY2FUJI_LOOK_UNKNOWN) && importedVersion == 0,
              "look import uses the real PHOTO contract and reports unversioned CUBE");
        std::ifstream afterStream(path, std::ios::binary);
        const std::string after((std::istreambuf_iterator<char>(afterStream)), {});
        check(after == before, "look validation preserves source bytes");
        r=request(black); r.lut_path=path.c_str(); r.lut_strength=1;
        const auto code = sony2fuji_process(session,&r,&out);
        if (contract.accepted) {
            const auto* pixels = static_cast<const unsigned char*>(out.data);
            check(code==SONY2FUJI_STATUS_OK && pixels && pixels[0]==64 && pixels[1]==128 && pixels[2]==191,
                  "Arbitrary display look renders through the photo API");
        } else {
            check(code==SONY2FUJI_STATUS_UNSUPPORTED, "Incompatible color contract remains unsupported");
        }
        sony2fuji_release_buffer(&out);
    }
    auto render = [&](const unsigned char* pixel, float strength, float exposure) {
        auto input=request(pixel); input.lut_path=provia.c_str(); input.lut_strength=strength; input.exposure_ev=exposure;
        sony2fuji_buffer result{};
        const auto code=sony2fuji_process(session,&input,&result);
        check(code==SONY2FUJI_STATUS_OK,"Render comparison fixture");
        std::array<int,3> rgb{};
        if (code==SONY2FUJI_STATUS_OK) for (int c=0;c<3;++c) rgb[c]=static_cast<unsigned char*>(result.data)[c];
        sony2fuji_release_buffer(&result);
        return rgb;
    };
    const unsigned char gray[3]={46,46,46}, doubled[3]={92,92,92};
    auto whiteBalancePixel = [&](float temperature, float tint) {
        auto input = request(gray); input.temperature = temperature; input.tint = tint;
        sony2fuji_buffer result{};
        const auto code = sony2fuji_process(session, &input, &result);
        std::array<float,3> rgb{};
        if (code == SONY2FUJI_STATUS_OK) for (int c=0;c<3;++c) rgb[c]=static_cast<unsigned char*>(result.data)[c];
        sony2fuji_release_buffer(&result);
        return rgb;
    };
    const auto cool = whiteBalancePixel(4000,0), warm = whiteBalancePixel(9000,0);
    const auto green = whiteBalancePixel(6500,-80), magenta = whiteBalancePixel(6500,80);
    check(warm[0]/warm[2] > cool[0]/cool[2], "Increasing temperature warms instead of cooling");
    check(magenta[1]/(magenta[0]+magenta[2]) < green[1]/(green[0]+green[2]),
          "Positive tint adds magenta instead of green");
    const auto neutral=render(gray,0,0), film=render(gray,1,0), half=render(gray,.5f,0);
    auto directInput=ColorConverter().convert(RGB(46.0f/255,46.0f/255,46.0f/255),
        ColorSpace::sRGB,ColorSpace::FujiFilm_FGamut);
    directInput=RGB(GammaConverter::applyFLog2(directInput.r),GammaConverter::applyFLog2(directInput.g),
        GammaConverter::applyFLog2(directInput.b));
    const auto directFilm=LUTApplicator(LUTParser::loadLUTCached(provia)).apply(directInput);
    check(std::abs(film[0]-std::round(directFilm.r*255))<=1 &&
        std::abs(film[1]-std::round(directFilm.g*255))<=1 &&
        std::abs(film[2]-std::round(directFilm.b*255))<=1, "Full-strength film bypasses the neutral view transform");
    bool midpoint=true;
    for (int c=0;c<3;++c) midpoint=midpoint && std::abs(half[c]-(neutral[c]+film[c])/2.0)<=1;
    check(midpoint,"Half strength blends the two display endpoints");
    check(render(gray,1,1)==render(doubled,1,0),"Exposure doubles linear input before film LUT");
    const unsigned char white[3]={255,255,255};
    const auto one=render(white,0,0), two=render(white,0,1), four=render(white,0,2);
    check(one[0]<two[0] && two[0]<four[0] && four[0]<255,
        "Neutral display transform rolls off super-white instead of clipping at one");
    r=request(gray); r.wb_mode=SONY2FUJI_WB_CUSTOM;
    r.wb_mul[0]=2; r.wb_mul[1]=1; r.wb_mul[2]=1; r.wb_mul[3]=1;
    const auto wbStatus=sony2fuji_process(session,&r,&out);
    check(wbStatus==SONY2FUJI_STATUS_OK && std::abs(static_cast<unsigned char*>(out.data)[0] -
        std::round(neutralDisplay(92.0f/255)*255))<=1,
        "Custom buffer white balance is applied in linear RGB");
    sony2fuji_release_buffer(&out);
    r=request(black); r.exposure_ev=std::numeric_limits<float>::quiet_NaN();
    check(sony2fuji_process(session,&r,&out)==SONY2FUJI_STATUS_INVALID_ARGUMENT,"Non-finite exposure is rejected");
    sony2fuji_release_buffer(&out);
    sony2fuji_session_destroy(session);
    sony2fuji_session_create(&session);
    std::vector<unsigned char> detail(16*16*3);
    for (int y=0;y<16;++y) for (int x=0;x<16;++x) for (int c=0;c<3;++c)
        detail[(y*16+x)*3+c]=static_cast<unsigned char>((x*37+y*19+c*23)%220+10);
    auto detailRequest=request(detail.data());
    detailRequest.input_width=detailRequest.input_height=16;
    detailRequest.sharpening=1;
    detailRequest.size_mode=SONY2FUJI_SIZE_FIT_LONG_EDGE; detailRequest.long_edge=8;
    detailRequest.intent=SONY2FUJI_INTENT_FINAL;
    sony2fuji_buffer fullDetail{},previewDetail{};
    const auto fullStatus=sony2fuji_process(session,&detailRequest,&fullDetail);
    detailRequest.intent=SONY2FUJI_INTENT_PREVIEW; detailRequest.preview_long_edge=8;
    const auto previewStatus=sony2fuji_process(session,&detailRequest,&previewDetail);
    check(fullStatus==SONY2FUJI_STATUS_OK && previewStatus==SONY2FUJI_STATUS_OK &&
        fullDetail.size_bytes==previewDetail.size_bytes &&
        std::equal(static_cast<unsigned char*>(fullDetail.data),
            static_cast<unsigned char*>(fullDetail.data)+fullDetail.size_bytes,
            static_cast<unsigned char*>(previewDetail.data)),
        "Sharpening uses original pixel scale in preview and final output");
    sony2fuji_buffer unsharpened{};
    detailRequest.intent=SONY2FUJI_INTENT_FINAL; detailRequest.sharpening=0;
    const auto unsharpStatus=sony2fuji_process(session,&detailRequest,&unsharpened);
    check(unsharpStatus==SONY2FUJI_STATUS_OK && fullStatus==SONY2FUJI_STATUS_OK &&
        !std::equal(static_cast<unsigned char*>(fullDetail.data),
            static_cast<unsigned char*>(fullDetail.data)+fullDetail.size_bytes,
            static_cast<unsigned char*>(unsharpened.data)),
        "Sharpening changes real edges rather than only preview resizing");
    sony2fuji_release_buffer(&unsharpened);
    sony2fuji_release_buffer(&fullDetail); sony2fuji_release_buffer(&previewDetail);
    {
        auto bytesOf = [](const sony2fuji_buffer& b) {
            const auto* p = static_cast<const unsigned char*>(b.data);
            return p ? std::vector<unsigned char>(p, p + b.size_bytes) : std::vector<unsigned char>{};
        };
        auto denoiseRequest = request(detail.data());
        denoiseRequest.input_width = denoiseRequest.input_height = 16;
        denoiseRequest.size_mode = SONY2FUJI_SIZE_FIT_LONG_EDGE; denoiseRequest.long_edge = 8;
        denoiseRequest.noise_reduction = 1.0f;
        denoiseRequest.intent = SONY2FUJI_INTENT_FINAL;
        sony2fuji_buffer exported{}, preview{}, plain{}, sharpened{}, viewport{};
        const auto exportStatus = sony2fuji_process(session, &denoiseRequest, &exported);
        auto previewRequest = denoiseRequest;
        previewRequest.intent = SONY2FUJI_INTENT_PREVIEW; previewRequest.preview_long_edge = 8;
        const auto previewStatus = sony2fuji_process(session, &previewRequest, &preview);
        auto plainRequest = denoiseRequest; plainRequest.noise_reduction = 0;
        const auto plainStatus = sony2fuji_process(session, &plainRequest, &plain);
        check(exportStatus == SONY2FUJI_STATUS_OK && previewStatus == SONY2FUJI_STATUS_OK &&
            exported.width == 8 && exported.height == 8 && bytesOf(exported) == bytesOf(preview),
            "Legacy noise reduction uses original pixel scale in preview and final output");
        check(plainStatus == SONY2FUJI_STATUS_OK && bytesOf(exported) != bytesOf(plain),
            "Legacy noise reduction changes pixels rather than only preview resizing");
        auto sharpenRequest = previewRequest; sharpenRequest.sharpening = 1e-4f;
        const auto sharpenStatus = sony2fuji_process(session, &sharpenRequest, &sharpened);
        const auto base = bytesOf(preview), nudged = bytesOf(sharpened);
        int maxDelta = base.size() == nudged.size() && !base.empty() ? 0 : 256;
        for (size_t i = 0; maxDelta <= 255 && i < base.size(); ++i)
            maxDelta = std::max(maxDelta, std::abs(int(base[i]) - int(nudged[i])));
        check(sharpenStatus == SONY2FUJI_STATUS_OK && maxDelta <= 1,
            "Denoised preview stays continuous when sharpening leaves zero");
        sony2fuji_session_set_viewport_preview(session, 1);
        const auto viewportStatus = sony2fuji_process(session, &previewRequest, &viewport);
        sony2fuji_session_set_viewport_preview(session, 0);
        check(viewportStatus == SONY2FUJI_STATUS_OK && viewport.width == 8 && viewport.height == 8 &&
            viewport.size_bytes == 8 * 8 * 3,
            "Viewport preview keeps the reduced approximation for legacy noise reduction");
        for (auto* b : {&exported, &preview, &plain, &sharpened, &viewport}) sony2fuji_release_buffer(b);
    }
    std::vector<unsigned char> sizingPixels(18 * 12 * 3, 80);
    auto sizingRequest = request(sizingPixels.data());
    sizingRequest.input_width = 18; sizingRequest.input_height = 12;
    sizingRequest.intent = SONY2FUJI_INTENT_FINAL;
    sizingRequest.size_mode = static_cast<sony2fuji_size_mode>(4);
    for (auto edge : {9u, 36u}) {
        sizingRequest.long_edge = edge;
        sony2fuji_buffer resized{};
        const auto code = sony2fuji_process(session, &sizingRequest, &resized);
        check(code == SONY2FUJI_STATUS_OK && resized.width == (edge == 9 ? 9u : 18u) &&
              resized.height == (edge == 9 ? 6u : 12u),
              "Export long-edge limit preserves aspect ratio without enlarging small inputs");
        sony2fuji_release_buffer(&resized);
    }
    sizingRequest.input_width = 12; sizingRequest.input_height = 18; sizingRequest.long_edge = 9;
    sony2fuji_buffer portrait{};
    check(sony2fuji_process(session, &sizingRequest, &portrait) == SONY2FUJI_STATUS_OK &&
          portrait.width == 6 && portrait.height == 9, "Export sizing uses the oriented portrait long edge");
    sony2fuji_release_buffer(&portrait);
    sizingRequest.long_edge = 0;
    check(sony2fuji_process(session, &sizingRequest, &portrait) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "Export sizing rejects an empty pixel limit");
    sony2fuji_session_destroy(session);
    std::filesystem::remove_all(dir);
    return failures ? 1 : 0;
}
