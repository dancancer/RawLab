#include "sony2fuji/sony2fuji.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#include "sony2fuji/gpu/lut_gpu.h"
#include "core/preview_exposure.h"
#include "core/photo_rendering.h"
#include "core/photo_lut.h"
#include "core/stb_image_write.h"
#include <cerrno>
#include <cmath>
#include <csetjmp>
#include <cstdlib>
#include <cstring>
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
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/stat.h>
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
    const std::string linearDngFixture = std::string(TEST_SOURCE_DIR) + "/tests/fixtures/linear-uncompressed.dng";
    {
        const unsigned char widePixels[6] = {128, 70, 220, 64, 120, 180};
        auto expectRejected = [&](const sony2fuji_request& req, const char* label, sony2fuji_session* target = nullptr) {
            sony2fuji_buffer hugeOut{};
            const sony2fuji_buffer* outPtr = req.output_target == SONY2FUJI_TARGET_BUFFER ? &hugeOut : nullptr;
            const auto st = sony2fuji_process(target ? target : session, &req, const_cast<sony2fuji_buffer*>(outPtr));
            const bool rejected = st == SONY2FUJI_STATUS_INVALID_ARGUMENT &&
                std::string(sony2fuji_status_message(st)) == "invalid argument" && !hugeOut.data;
            sony2fuji_release_buffer(&hugeOut);
            check(rejected, label);
        };

        auto exactCap = request(dngPixels);
        exactCap.size_mode = SONY2FUJI_SIZE_EXACT;
        exactCap.target_width = exactCap.target_height = 46341u; // 46341^2 = 2,147,488,281 > INT32_MAX
        expectRejected(exactCap, "EXACT output above 2.1G pixels is rejected with valid out_buffer");
        exactCap.target_width = exactCap.target_height = 2000000000u;
        expectRejected(exactCap, "EXACT int-overflow output size is rejected with valid out_buffer");

        auto fitLong = request(widePixels);
        fitLong.input_width = 2; fitLong.input_height = 1;
        fitLong.size_mode = SONY2FUJI_SIZE_FIT_LONG_EDGE;
        fitLong.long_edge = 65537u; // 65537 * 32769 = 2,147,581,953 > INT32_MAX
        expectRejected(fitLong, "FIT_LONG_EDGE output above 2.1G pixels is rejected");
        fitLong.long_edge = 2000000000u;
        expectRejected(fitLong, "FIT_LONG_EDGE extreme long_edge is rejected without UB");

        auto previewLong = request(dngPixels);
        previewLong.size_mode = SONY2FUJI_SIZE_NATIVE;
        previewLong.intent = SONY2FUJI_INTENT_PREVIEW;
        previewLong.preview_long_edge = 46341u;
        expectRejected(previewLong, "PREVIEW preview_long_edge override above 2.1G pixels is rejected");

        auto fitShort = request(widePixels);
        fitShort.input_width = 2; fitShort.input_height = 1;
        fitShort.size_mode = SONY2FUJI_SIZE_FIT_SHORT_EDGE;
        fitShort.short_edge = 32769u; // 65538 * 32769 = 2,147,614,722 > INT32_MAX
        expectRejected(fitShort, "FIT_SHORT_EDGE output above 2.1G pixels is rejected");
        fitShort.short_edge = 2000000000u;
        expectRejected(fitShort, "FIT_SHORT_EDGE extreme short_edge is rejected without UB");

        const std::string absentRaw = (dir / "missing-size-cap.ARW").string();
        const std::string absentLut = (dir / "missing-size-cap.cube").string();
        auto rawEarly = request(nullptr);
        rawEarly.input_type = SONY2FUJI_INPUT_RAW;
        rawEarly.input_path = absentRaw.c_str();
        rawEarly.intent = SONY2FUJI_INTENT_FINAL;
        rawEarly.size_mode = SONY2FUJI_SIZE_EXACT;
        rawEarly.target_width = rawEarly.target_height = 46341u;
        expectRejected(rawEarly, "Oversized RAW request is rejected during request validation before RAW decode");

        sony2fuji_session* geomSession = nullptr;
        sony2fuji_session_create(&geomSession);
        sony2fuji_geometry_config geom{};
        geom.version = SONY2FUJI_GEOMETRY_CONFIG_VERSION;
        geom.struct_size = sizeof(geom);
        geom.crop_width = geom.crop_height = 1.0f;
        geom.quarter_turns = 1;
        sony2fuji_session_set_geometry(geomSession, &geom);
        auto finalGeom = fitLong;
        finalGeom.long_edge = 65537u;
        finalGeom.intent = SONY2FUJI_INTENT_FINAL;
        finalGeom.lut_path = absentLut.c_str();
        finalGeom.lut_strength = 1.0f;
        expectRejected(finalGeom, "FINAL+geometry oversized FIT_LONG_EDGE is rejected before LUT/pixel work", geomSession);
        sony2fuji_session_destroy(geomSession);

        // JPEG 65535 single-edge limit lifted to request validation vs PNG/DNG parity at 100000x100 (10MP <= 2.1G).
        const std::string wideJpegOut = (dir / "wide-100000x100.jpg").string();
        const std::string widePngOut = (dir / "wide-100000x100.png").string();
        const std::string wideDngOut = (dir / "wide-100000x100.dng").string();
        auto wideJpegEarly = request(nullptr);
        wideJpegEarly.input_type = SONY2FUJI_INPUT_RAW;
        wideJpegEarly.input_path = absentRaw.c_str();
        wideJpegEarly.lut_path = absentLut.c_str();
        wideJpegEarly.lut_strength = 1.0f;
        wideJpegEarly.intent = SONY2FUJI_INTENT_FINAL;
        wideJpegEarly.output_target = SONY2FUJI_TARGET_FILE;
        wideJpegEarly.output_format = SONY2FUJI_OUTPUT_JPEG;
        wideJpegEarly.output_path = wideJpegOut.c_str();
        wideJpegEarly.size_mode = SONY2FUJI_SIZE_EXACT;
        wideJpegEarly.target_width = 100000u;
        wideJpegEarly.target_height = 100u;
        expectRejected(wideJpegEarly, "EXACT 100000x100 JPEG is rejected at request validation before decode/LUT");
        check(!std::filesystem::exists(wideJpegOut), "Rejected EXACT 100000x100 JPEG creates no output file");

        auto wideJpegBufferSrc = request(dngPixels);
        wideJpegBufferSrc.intent = SONY2FUJI_INTENT_FINAL;
        wideJpegBufferSrc.output_target = SONY2FUJI_TARGET_FILE;
        wideJpegBufferSrc.output_format = SONY2FUJI_OUTPUT_JPEG;
        wideJpegBufferSrc.output_path = wideJpegOut.c_str();
        wideJpegBufferSrc.size_mode = SONY2FUJI_SIZE_EXACT;
        wideJpegBufferSrc.target_width = 100000u;
        wideJpegBufferSrc.target_height = 100u;
        expectRejected(wideJpegBufferSrc, "EXACT 100000x100 JPEG from buffer returns INVALID_ARGUMENT instead of ProcessingError");

        auto wideFitLongJpeg = wideJpegEarly;
        wideFitLongJpeg.size_mode = SONY2FUJI_SIZE_FIT_LONG_EDGE;
        wideFitLongJpeg.long_edge = 70000u;
        expectRejected(wideFitLongJpeg, "FIT_LONG_EDGE >65535 JPEG is rejected at request validation");

        auto widePngCheck = wideJpegEarly;
        widePngCheck.lut_path = nullptr;
        widePngCheck.lut_strength = 0.0f;
        widePngCheck.output_format = SONY2FUJI_OUTPUT_PNG;
        widePngCheck.output_path = widePngOut.c_str();
        check(sony2fuji_process(session, &widePngCheck, nullptr) == SONY2FUJI_STATUS_IO_ERROR,
              "EXACT 100000x100 PNG passes request validation and reaches input open");
        auto wideDngCheck = widePngCheck;
        wideDngCheck.output_format = SONY2FUJI_OUTPUT_DNG;
        wideDngCheck.output_path = wideDngOut.c_str();
        check(sony2fuji_process(session, &wideDngCheck, nullptr) == SONY2FUJI_STATUS_IO_ERROR,
              "EXACT 100000x100 DNG passes request validation and reaches input open");

        auto widePngExport = wideJpegBufferSrc;
        widePngExport.output_format = SONY2FUJI_OUTPUT_PNG;
        widePngExport.output_path = widePngOut.c_str();
        check(sony2fuji_process(session, &widePngExport, nullptr) == SONY2FUJI_STATUS_OK &&
              std::filesystem::exists(widePngOut) && std::filesystem::file_size(widePngOut) > 24,
              "EXACT 100000x100 PNG exports cleanly within 2.1G cap");
        std::filesystem::remove(widePngOut);

        auto wideDngExport = wideJpegBufferSrc;
        wideDngExport.output_format = SONY2FUJI_OUTPUT_DNG;
        wideDngExport.output_path = wideDngOut.c_str();
        check(sony2fuji_process(session, &wideDngExport, nullptr) == SONY2FUJI_STATUS_OK &&
              std::filesystem::exists(wideDngOut) && std::filesystem::file_size(wideDngOut) > 64,
              "EXACT 100000x100 DNG exports cleanly within 2.1G cap");
        std::filesystem::remove(wideDngOut);

        // Header-only / corrupt-payload fixtures for NATIVE pre-decode preflight.
        auto writePngHeaderOnly = [](const std::filesystem::path& target, uint32_t w, uint32_t h) {
            std::ofstream out(target, std::ios::binary);
            const unsigned char sig[8] = {137, 80, 78, 71, 13, 10, 26, 10};
            out.write(reinterpret_cast<const char*>(sig), 8);
            const unsigned char len[4] = {0, 0, 0, 13};
            out.write(reinterpret_cast<const char*>(len), 4);
            unsigned char ihdr[17] = {'I', 'H', 'D', 'R',
                static_cast<unsigned char>(w >> 24), static_cast<unsigned char>(w >> 16),
                static_cast<unsigned char>(w >> 8), static_cast<unsigned char>(w),
                static_cast<unsigned char>(h >> 24), static_cast<unsigned char>(h >> 16),
                static_cast<unsigned char>(h >> 8), static_cast<unsigned char>(h),
                8, 2, 0, 0, 0};
            out.write(reinterpret_cast<const char*>(ihdr), sizeof(ihdr));
            const uLong crc = crc32(0, reinterpret_cast<const Bytef*>(ihdr), sizeof(ihdr));
            const unsigned char crcBytes[4] = {
                static_cast<unsigned char>(crc >> 24), static_cast<unsigned char>(crc >> 16),
                static_cast<unsigned char>(crc >> 8), static_cast<unsigned char>(crc)};
            out.write(reinterpret_cast<const char*>(crcBytes), 4);
            const std::string corruptIdat(64, 'X');
            out.write(corruptIdat.data(), static_cast<std::streamsize>(corruptIdat.size()));
        };
        auto writeJpegHeaderOnly = [](const std::filesystem::path& target, uint16_t w, uint16_t h) {
            std::ofstream out(target, std::ios::binary);
            const unsigned char bytes[] = {
                0xFF, 0xD8,
                0xFF, 0xC0, 0x00, 0x0B, 0x08,
                static_cast<unsigned char>(h >> 8), static_cast<unsigned char>(h),
                static_cast<unsigned char>(w >> 8), static_cast<unsigned char>(w),
                0x01, 0x11, 0x00,
                0xFF, 0xDA, 0x00, 0x02
            };
            out.write(reinterpret_cast<const char*>(bytes), sizeof(bytes));
        };
        std::ifstream dngIn(linearDngFixture, std::ios::binary);
        const std::vector<uint8_t> dngTemplate((std::istreambuf_iterator<char>(dngIn)), {});
        dngIn.close();
        auto writeTruncatedDngHeader = [&](const std::filesystem::path& target, uint32_t w, uint32_t h) {
            std::vector<uint8_t> buf(dngTemplate.begin(), dngTemplate.begin() + 450);
            auto put32 = [&](size_t off, uint32_t v) {
                buf[off] = static_cast<uint8_t>(v & 0xFFu);
                buf[off + 1] = static_cast<uint8_t>((v >> 8) & 0xFFu);
                buf[off + 2] = static_cast<uint8_t>((v >> 16) & 0xFFu);
                buf[off + 3] = static_cast<uint8_t>((v >> 24) & 0xFFu);
            };
            const uint16_t entries = static_cast<uint16_t>(buf[8] | (uint16_t(buf[9]) << 8));
            for (uint16_t i = 0; i < entries; ++i) {
                const size_t off = 10 + static_cast<size_t>(i) * 12;
                const uint16_t tag = static_cast<uint16_t>(buf[off] | (uint16_t(buf[off + 1]) << 8));
                if (tag == 256) put32(off + 8, w);
                else if (tag == 257 || tag == 278) put32(off + 8, h);
                else if (tag == 279) {
                    const uint64_t bytes = std::min<uint64_t>(uint64_t(w) * uint64_t(h) * 6u, 0xFFFFFFFFull);
                    put32(off + 8, static_cast<uint32_t>(bytes));
                } else if (tag == 50829) {
                    const uint32_t areaOff = uint32_t(buf[off + 8]) | (uint32_t(buf[off + 9]) << 8) |
                        (uint32_t(buf[off + 10]) << 16) | (uint32_t(buf[off + 11]) << 24);
                    put32(areaOff + 8, h);
                    put32(areaOff + 12, w);
                }
            }
            std::ofstream out(target, std::ios::binary);
            out.write(reinterpret_cast<const char*>(buf.data()), static_cast<std::streamsize>(buf.size()));
        };

        // Control: truncated 32x24 DNG passes preflight and fails in decode (not INVALID_ARGUMENT).
        const auto corruptSmallDng = dir / "corrupt-small-32x24.dng";
        writeTruncatedDngHeader(corruptSmallDng, 32, 24);
        const std::string corruptSmallDngStr = corruptSmallDng.string();
        auto makeNativeRawReq = [&](const std::string& path) {
            auto req = request(nullptr);
            req.input_type = SONY2FUJI_INPUT_RAW;
            req.input_path = path.c_str();
            req.intent = SONY2FUJI_INTENT_FINAL;
            req.size_mode = SONY2FUJI_SIZE_NATIVE;
            return req;
        };
        {
            const auto smallReq = makeNativeRawReq(corruptSmallDngStr);
            sony2fuji_buffer out{};
            const auto st = sony2fuji_process(session, &smallReq, &out);
            sony2fuji_release_buffer(&out);
            check(st != SONY2FUJI_STATUS_OK && st != SONY2FUJI_STATUS_INVALID_ARGUMENT,
                  "Control truncated small DNG fails in RAW decode rather than size validation");
        }

        // NATIVE >2.1G (50000x50000 = 2.5GP) rejected BEFORE decode across DNG/RAW, PNG, and JPEG headers.
        const auto hugeDng = dir / "corrupt-huge-50000x50000.dng";
        writeTruncatedDngHeader(hugeDng, 50000u, 50000u);
        const std::string hugeDngStr = hugeDng.string();
        auto hugeDngReq = makeNativeRawReq(hugeDngStr);
        hugeDngReq.lut_path = absentLut.c_str();
        hugeDngReq.lut_strength = 1.0f;
        expectRejected(hugeDngReq, "NATIVE 50000x50000 truncated DNG fails pre-decode size preflight before unpack/LUT");

        const auto hugePng = dir / "corrupt-huge-50000x50000.png";
        writePngHeaderOnly(hugePng, 50000u, 50000u);
        const std::string hugePngStr = hugePng.string();
        auto hugePngReq = makeNativeRawReq(hugePngStr);
        hugePngReq.lut_path = absentLut.c_str();
        hugePngReq.lut_strength = 1.0f;
        expectRejected(hugePngReq, "NATIVE 50000x50000 corrupt PNG fails pre-decode size preflight before decode/LUT");

        const auto hugeJpg = dir / "corrupt-huge-50000x50000.jpg";
        writeJpegHeaderOnly(hugeJpg, 50000u, 50000u);
        const std::string hugeJpgStr = hugeJpg.string();
        auto hugeJpgReq = makeNativeRawReq(hugeJpgStr);
        hugeJpgReq.lut_path = absentLut.c_str();
        hugeJpgReq.lut_strength = 1.0f;
        expectRejected(hugeJpgReq, "NATIVE 50000x50000 corrupt JPEG fails pre-decode size preflight before decode/LUT");

        // NATIVE JPEG >65535 single-edge (70000x100) rejected BEFORE decode on both PNG and TIFF/DNG headers.
        const auto widePngHdr = dir / "corrupt-wide-70000x100.png";
        writePngHeaderOnly(widePngHdr, 70000u, 100u);
        const std::string widePngHdrStr = widePngHdr.string();
        auto nativeWideJpegPng = makeNativeRawReq(widePngHdrStr);
        nativeWideJpegPng.lut_path = absentLut.c_str();
        nativeWideJpegPng.lut_strength = 1.0f;
        nativeWideJpegPng.output_target = SONY2FUJI_TARGET_FILE;
        nativeWideJpegPng.output_format = SONY2FUJI_OUTPUT_JPEG;
        nativeWideJpegPng.output_path = wideJpegOut.c_str();
        expectRejected(nativeWideJpegPng, "NATIVE 70000x100 PNG->JPEG fails pre-decode single-edge preflight");

        const auto wideTiffDng = dir / "corrupt-wide-100x70000-orient6.dng";
        writeTruncatedDngHeader(wideTiffDng, 100u, 70000u); // Orientation=6 transposes to 70000x100
        const std::string wideTiffDngStr = wideTiffDng.string();
        auto nativeWideJpegDng = nativeWideJpegPng;
        nativeWideJpegDng.input_path = wideTiffDngStr.c_str();
        expectRejected(nativeWideJpegDng, "NATIVE 70000x100 TIFF/DNG->JPEG fails pre-decode single-edge preflight");

        // Within-cap >128MP NATIVE (15000x10000 = 150MP and 20000x10000 = 200MP) passes request validation & preflight.
        for (uint32_t w : {15000u, 20000u}) {
            const auto medFmtPng = dir / ("header-" + std::to_string(w) + "x10000.png");
            writePngHeaderOnly(medFmtPng, w, 10000u);
            const std::string medFmtPngStr = medFmtPng.string();
            auto medFmtRawReq = makeNativeRawReq(medFmtPngStr);
            sony2fuji_buffer out{};
            const auto bufSt = sony2fuji_process(session, &medFmtRawReq, &out);
            sony2fuji_release_buffer(&out);
            check(bufSt == SONY2FUJI_STATUS_UNSUPPORTED,
                  w == 15000u ? "NATIVE 15000x10000 (150MP) PNG passes size validation and reaches RAW decoder"
                              : "NATIVE 20000x10000 (200MP) PNG passes size validation and reaches RAW decoder");

            auto medFmtJpegReq = medFmtRawReq;
            medFmtJpegReq.output_target = SONY2FUJI_TARGET_FILE;
            medFmtJpegReq.output_format = SONY2FUJI_OUTPUT_JPEG;
            medFmtJpegReq.output_path = wideJpegOut.c_str();
            check(sony2fuji_process(session, &medFmtJpegReq, nullptr) == SONY2FUJI_STATUS_UNSUPPORTED,
                  w == 15000u ? "NATIVE 15000x10000 (150MP) JPEG export passes size validation"
                              : "NATIVE 20000x10000 (200MP) JPEG export passes size validation");
        }

        // Also verify 15000x10000 (150MP) NATIVE INPUT_BUFFER passes validateRequest + preflight without 128M rejection.
        sony2fuji_session* cancelProbeSession = nullptr;
        sony2fuji_session_create(&cancelProbeSession);
        int cancelPolls = 0;
        sony2fuji_session_set_cancellation_callback(cancelProbeSession, [](void* ctx) -> int {
            int& count = *static_cast<int*>(ctx);
            return (++count >= 2) ? 1 : 0; // Poll #1 is before validateRequest; Poll #2 is after validation & preflight.
        }, &cancelPolls);
        auto buf150mp = request(dngPixels);
        buf150mp.input_width = 15000u;
        buf150mp.input_height = 10000u;
        buf150mp.size_mode = SONY2FUJI_SIZE_NATIVE;
        buf150mp.intent = SONY2FUJI_INTENT_FINAL;
        sony2fuji_buffer probeOut{};
        const auto probeSt = sony2fuji_process(cancelProbeSession, &buf150mp, &probeOut);
        sony2fuji_release_buffer(&probeOut);
        sony2fuji_session_destroy(cancelProbeSession);
        check(probeSt == SONY2FUJI_STATUS_CANCELLED && cancelPolls == 2,
              "NATIVE 15000x10000 (150MP) INPUT_BUFFER passes validation and preflight before pixel allocation");

        // Blocking 1 regression anchor: JXL DNG (Compression=52546, IFD 9000x3000, ActiveArea 3000x3000)
        // with FIT_SHORT_EDGE=22000 JPEG must defer size preflight to post-decode rather than falling back
        // to probeTiffHeaderSize on uncropped 9000x3000 (which would compute 66000x22000 > 65535 -> INVALID_ARGUMENT).
        const auto jxlCroppedDng = dir / "jxl-ifd-9000x3000-active-3000x3000.dng";
        {
            std::vector<uint8_t> buf(dngTemplate.begin(), dngTemplate.begin() + 450);
            auto put16 = [&](size_t off, uint16_t v) {
                buf[off] = static_cast<uint8_t>(v & 0xFFu);
                buf[off + 1] = static_cast<uint8_t>((v >> 8) & 0xFFu);
            };
            auto put32 = [&](size_t off, uint32_t v) {
                buf[off] = static_cast<uint8_t>(v & 0xFFu);
                buf[off + 1] = static_cast<uint8_t>((v >> 8) & 0xFFu);
                buf[off + 2] = static_cast<uint8_t>((v >> 16) & 0xFFu);
                buf[off + 3] = static_cast<uint8_t>((v >> 24) & 0xFFu);
            };
            const uint16_t entries = static_cast<uint16_t>(buf[8] | (uint16_t(buf[9]) << 8));
            for (uint16_t i = 0; i < entries; ++i) {
                const size_t off = 10 + static_cast<size_t>(i) * 12;
                const uint16_t tag = static_cast<uint16_t>(buf[off] | (uint16_t(buf[off + 1]) << 8));
                if (tag == 256) put32(off + 8, 9000u);
                else if (tag == 257 || tag == 278) put32(off + 8, 3000u);
                else if (tag == 259) put16(off + 8, 52546u);
                else if (tag == 274) put16(off + 8, 1u);
                else if (tag == 279) put32(off + 8, 64u);
                else if (tag == 50829) {
                    const uint32_t areaOff = uint32_t(buf[off + 8]) | (uint32_t(buf[off + 9]) << 8) |
                        (uint32_t(buf[off + 10]) << 16) | (uint32_t(buf[off + 11]) << 24);
                    put32(areaOff + 0, 0u);
                    put32(areaOff + 4, 0u);
                    put32(areaOff + 8, 3000u);
                    put32(areaOff + 12, 3000u);
                }
            }
            std::ofstream out(jxlCroppedDng, std::ios::binary);
            out.write(reinterpret_cast<const char*>(buf.data()), static_cast<std::streamsize>(buf.size()));
        }
        const std::string jxlCroppedDngStr = jxlCroppedDng.string();
        auto jxlShortEdgeReq = makeNativeRawReq(jxlCroppedDngStr);
        jxlShortEdgeReq.output_target = SONY2FUJI_TARGET_FILE;
        jxlShortEdgeReq.output_format = SONY2FUJI_OUTPUT_JPEG;
        jxlShortEdgeReq.output_path = wideJpegOut.c_str();
        jxlShortEdgeReq.size_mode = SONY2FUJI_SIZE_FIT_SHORT_EDGE;
        jxlShortEdgeReq.short_edge = 22000u;
        const auto jxlShortEdgeSt = sony2fuji_process(session, &jxlShortEdgeReq, nullptr);
        check(jxlShortEdgeSt != SONY2FUJI_STATUS_OK && jxlShortEdgeSt != SONY2FUJI_STATUS_INVALID_ARGUMENT,
              "JXL DNG 9000x3000 IFD with 3000x3000 ActiveArea defers preflight instead of false TIFF rejection");

        const std::string linearJxlFixture = std::string(TEST_SOURCE_DIR) + "/tests/fixtures/linear-jxl.dng";
        uint32_t probedW = 99u, probedH = 99u;
        check(RAWProcessor::probeOutputSize(linearJxlFixture, false, probedW, probedH) == ProbeSizeResult::DeferredPostDecode &&
              probedW == 0u && probedH == 0u,
              "RAWProcessor::probeOutputSize returns DeferredPostDecode on JXL DNG fixture");
        RAWProcessor refProc;
        const bool refLoaded = refProc.loadFile(linearDngFixture, X3fMode::Legacy) == ErrorCode::Success;
        const auto refNative = refProc.getNativeOutputSize();
        check(refLoaded &&
              RAWProcessor::probeOutputSize(linearDngFixture, false, probedW, probedH) == ProbeSizeResult::Probed &&
              probedW == static_cast<uint32_t>(refNative.first) && probedH == static_cast<uint32_t>(refNative.second),
              "RAWProcessor::probeOutputSize matches decoded native output size on uncompressed DNG fixture");

        // Blocking 1b: normalX3f defers preflight (KeepImageArea differs from LibRaw foveon_data),
        // whereas legacyX3f probes via LibRaw.
        const auto synthX3f = dir / "synthetic-quattro-5888x3672.x3f";
        {
            std::vector<uint8_t> x3fBytes(104, 0);
            auto put32le = [&](size_t off, uint32_t v) {
                x3fBytes[off + 0] = static_cast<uint8_t>(v & 0xFFu);
                x3fBytes[off + 1] = static_cast<uint8_t>((v >> 8) & 0xFFu);
                x3fBytes[off + 2] = static_cast<uint8_t>((v >> 16) & 0xFFu);
                x3fBytes[off + 3] = static_cast<uint8_t>((v >> 24) & 0xFFu);
            };
            put32le(0, 0x62564F46u);  // "FOVb"
            put32le(4, 0x00040000u);  // v4.0 (Quattro)
            put32le(36, 5888u);       // columns
            put32le(40, 3672u);       // rows
            put32le(44, 0u);          // rotation
            // SECi raw image header at offset 48 (28 bytes)
            put32le(48, 0x69434553u); // "SECi"
            put32le(52, 0x00020000u); // v2.0
            put32le(56, 1u);          // image type: RAW
            put32le(60, 0x23u);       // format: X3F_IMAGE_RAW_QUATTRO (0x00010023)
            put32le(64, 5888u);
            put32le(68, 3672u);
            put32le(72, 0u);
            // SECd directory at offset 76 (24 bytes) + 4-byte footer at offset 100
            put32le(76, 0x64434553u); // "SECd"
            put32le(80, 0x00020000u); // v2.0
            put32le(84, 1u);          // 1 directory entry
            put32le(88, 48u);         // entry offset
            put32le(92, 28u);         // entry size
            put32le(96, 0x46414D49u); // "IMAG"
            put32le(100, 76u);        // directory offset at EOF-4
            std::ofstream out(synthX3f, std::ios::binary);
            out.write(reinterpret_cast<const char*>(x3fBytes.data()), static_cast<std::streamsize>(x3fBytes.size()));
        }
        const std::string synthX3fStr = synthX3f.string();
        uint32_t x3fW = 0, x3fH = 0;
        check(RAWProcessor::probeOutputSize(synthX3fStr, false, x3fW, x3fH, X3fMode::Normal) == ProbeSizeResult::DeferredPostDecode,
              "RAWProcessor::probeOutputSize defers normalX3f header preflight");
        check(RAWProcessor::probeOutputSize(synthX3fStr, false, x3fW, x3fH, X3fMode::Legacy) == ProbeSizeResult::Probed &&
              x3fW > 0u && x3fH > 0u,
              "RAWProcessor::probeOutputSize probes legacyX3f dimensions via LibRaw");
        {
            sony2fuji_session* x3fSession = nullptr;
            sony2fuji_session_create(&x3fSession);
            sony2fuji_session_set_x3f_mode(x3fSession, SONY2FUJI_X3F_NORMAL);
            auto x3fShortReq = makeNativeRawReq(synthX3fStr);
            x3fShortReq.output_target = SONY2FUJI_TARGET_FILE;
            x3fShortReq.output_format = SONY2FUJI_OUTPUT_JPEG;
            x3fShortReq.output_path = wideJpegOut.c_str();
            x3fShortReq.size_mode = SONY2FUJI_SIZE_FIT_SHORT_EDGE;
            x3fShortReq.short_edge = 43640u; // 5424x3616 -> 65460 <= 65535, vs LibRaw -> >65535
            const auto normalX3fSt = sony2fuji_process(x3fSession, &x3fShortReq, nullptr);
            check(normalX3fSt != SONY2FUJI_STATUS_OK && normalX3fSt != SONY2FUJI_STATUS_INVALID_ARGUMENT,
                  "normalX3f FIT_SHORT_EDGE=43640 JPEG skips LibRaw preflight without false rejection");

            sony2fuji_session_set_x3f_mode(x3fSession, SONY2FUJI_X3F_LEGACY);
            x3fShortReq.lut_path = absentLut.c_str();
            x3fShortReq.lut_strength = 1.0f;
            expectRejected(x3fShortReq, "legacyX3f FIT_SHORT_EDGE=43640 JPEG still rejects pre-decode via LibRaw probe", x3fSession);
            sony2fuji_session_destroy(x3fSession);
        }

        // SHOULD-FIX 3: Plain TIFF header probing (BigTIFF=43, big-endian MM, SubIFDs, DefaultCropSize + den==0, OOB offsets).
        auto append16 = [](std::vector<uint8_t>& b, uint16_t v, bool le) {
            if (le) { b.push_back(uint8_t(v & 0xFFu)); b.push_back(uint8_t((v >> 8) & 0xFFu)); }
            else { b.push_back(uint8_t((v >> 8) & 0xFFu)); b.push_back(uint8_t(v & 0xFFu)); }
        };
        auto append32 = [](std::vector<uint8_t>& b, uint32_t v, bool le) {
            for (int i = 0; i < 4; ++i) {
                const int shift = le ? (i * 8) : ((3 - i) * 8);
                b.push_back(static_cast<uint8_t>((v >> shift) & 0xFFu));
            }
        };
        auto append64 = [](std::vector<uint8_t>& b, uint64_t v, bool le) {
            for (int i = 0; i < 8; ++i) {
                const int shift = le ? (i * 8) : ((7 - i) * 8);
                b.push_back(static_cast<uint8_t>((v >> shift) & 0xFFu));
            }
        };
        auto writeBytesFile = [](const std::filesystem::path& p, const std::vector<uint8_t>& b) {
            std::ofstream out(p, std::ios::binary);
            out.write(reinterpret_cast<const char*>(b.data()), static_cast<std::streamsize>(b.size()));
        };

        // BigTIFF (magic=43, 8-byte offsets, 20-byte IFD entries): 50000x50000 rejected pre-decode.
        const auto bigTiffPath = dir / "bigtiff-50000x50000.tiff";
        {
            std::vector<uint8_t> b = {'I', 'I'};
            append16(b, 43u, true);
            append16(b, 8u, true);
            append16(b, 0u, true);
            append64(b, 16ull, true); // IFD0 offset
            append64(b, 2ull, true);  // 2 entries
            append16(b, 256u, true); append16(b, 4u, true); append64(b, 1ull, true); append64(b, 50000ull, true);
            append16(b, 257u, true); append16(b, 4u, true); append64(b, 1ull, true); append64(b, 50000ull, true);
            append64(b, 0ull, true);
            writeBytesFile(bigTiffPath, b);
        }
        const std::string bigTiffStr = bigTiffPath.string();
        auto bigTiffReq = makeNativeRawReq(bigTiffStr);
        bigTiffReq.lut_path = absentLut.c_str();
        bigTiffReq.lut_strength = 1.0f;
        expectRejected(bigTiffReq, "BigTIFF (magic=43) 50000x50000 fails pre-decode size preflight");

        // Big-endian MM classic TIFF (100x70000 with Orientation=6 -> 70000x100) rejected pre-decode for JPEG.
        const auto mmTiffPath = dir / "mm-100x70000-orient6.tiff";
        {
            std::vector<uint8_t> b = {'M', 'M'};
            append16(b, 42u, false);
            append32(b, 8u, false);
            append16(b, 3u, false);
            append16(b, 256u, false); append16(b, 4u, false); append32(b, 1u, false); append32(b, 100u, false);
            append16(b, 257u, false); append16(b, 4u, false); append32(b, 1u, false); append32(b, 70000u, false);
            append16(b, 274u, false); append16(b, 3u, false); append32(b, 1u, false);
            append16(b, 6u, false); append16(b, 0u, false); // Big-endian inline SHORT sits in upper 2 bytes
            append32(b, 0u, false);
            writeBytesFile(mmTiffPath, b);
        }
        const std::string mmTiffStr = mmTiffPath.string();
        auto mmJpegReq = nativeWideJpegPng;
        mmJpegReq.input_path = mmTiffStr.c_str();
        expectRejected(mmJpegReq, "Big-endian MM TIFF (100x70000, Orientation=6) fails pre-decode JPEG single-edge preflight");

        // SubIFDs (tag=330): IFD0 is 160x120 thumbnail (NewSubfileType=1), SubIFD0 is 50000x50000 primary (NewSubfileType=0).
        const auto subIfdTiffPath = dir / "subifds-primary-50000x50000.tiff";
        {
            std::vector<uint8_t> b = {'I', 'I'};
            append16(b, 42u, true);
            append32(b, 8u, true);
            append16(b, 4u, true); // IFD0: 8 + 2 + 4*12 + 4 = 62 -> SubIFD0 at offset 62
            append16(b, 254u, true); append16(b, 4u, true); append32(b, 1u, true); append32(b, 1u, true); // reduced-res
            append16(b, 256u, true); append16(b, 4u, true); append32(b, 1u, true); append32(b, 160u, true);
            append16(b, 257u, true); append16(b, 4u, true); append32(b, 1u, true); append32(b, 120u, true);
            append16(b, 330u, true); append16(b, 4u, true); append32(b, 1u, true); append32(b, 62u, true);
            append32(b, 0u, true);
            // SubIFD0 at offset 62
            append16(b, 3u, true);
            append16(b, 254u, true); append16(b, 4u, true); append32(b, 1u, true); append32(b, 0u, true); // full-res
            append16(b, 256u, true); append16(b, 4u, true); append32(b, 1u, true); append32(b, 50000u, true);
            append16(b, 257u, true); append16(b, 4u, true); append32(b, 1u, true); append32(b, 50000u, true);
            append32(b, 0u, true);
            writeBytesFile(subIfdTiffPath, b);
        }
        const std::string subIfdTiffStr = subIfdTiffPath.string();
        auto subIfdReq = bigTiffReq;
        subIfdReq.input_path = subIfdTiffStr.c_str();
        expectRejected(subIfdReq, "SubIFDs primary IFD (50000x50000) overrides IFD0 thumbnail and fails pre-decode preflight");

        // DefaultCropSize (tag=50720, RATIONAL): valid {60000/1, 100/1} overrides 70000x100 IFD; den==0 falls back safely.
        auto writeCropRationalTiff = [&](const std::filesystem::path& target, uint32_t denH) {
            std::vector<uint8_t> b = {'I', 'I'};
            append16(b, 42u, true);
            append32(b, 8u, true);
            append16(b, 3u, true); // IFD0 ends at 8 + 2 + 3*12 + 4 = 50
            append16(b, 256u, true); append16(b, 4u, true); append32(b, 1u, true); append32(b, 70000u, true);
            append16(b, 257u, true); append16(b, 4u, true); append32(b, 1u, true); append32(b, 100u, true);
            append16(b, 50720u, true); append16(b, 5u, true); append32(b, 2u, true); append32(b, 50u, true);
            append32(b, 0u, true);
            // Two RATIONALs at offset 50: width = 60000/1, height = 100/denH
            append32(b, 60000u, true); append32(b, 1u, true);
            append32(b, 100u, true); append32(b, denH, true);
            writeBytesFile(target, b);
        };
        const auto validCropTiff = dir / "tiff-default-crop-valid.tiff";
        writeCropRationalTiff(validCropTiff, 1u);
        const std::string validCropTiffStr = validCropTiff.string();
        auto validCropJpegReq = makeNativeRawReq(validCropTiffStr);
        validCropJpegReq.output_target = SONY2FUJI_TARGET_FILE;
        validCropJpegReq.output_format = SONY2FUJI_OUTPUT_JPEG;
        validCropJpegReq.output_path = wideJpegOut.c_str();
        check(sony2fuji_process(session, &validCropJpegReq, nullptr) == SONY2FUJI_STATUS_UNSUPPORTED,
              "DefaultCropSize RATIONAL 60000x100 overrides 70000x100 IFD and passes JPEG preflight");

        const auto zeroDenCropTiff = dir / "tiff-default-crop-den0.tiff";
        writeCropRationalTiff(zeroDenCropTiff, 0u);
        const std::string zeroDenCropTiffStr = zeroDenCropTiff.string();
        auto zeroDenJpegReq = nativeWideJpegPng;
        zeroDenJpegReq.input_path = zeroDenCropTiffStr.c_str();
        expectRejected(zeroDenJpegReq, "DefaultCropSize RATIONAL with den==0 safely falls back to 70000x100 IFD and rejects");

        // Out-of-bounds TIFF offsets degrade/fall back safely without crash or huge allocation.
        const auto oobRootTiff = dir / "tiff-oob-root.tiff";
        {
            std::vector<uint8_t> b = {'I', 'I'};
            append16(b, 42u, true);
            append32(b, 0x7FFFFFF0u, true);
            writeBytesFile(oobRootTiff, b);
        }
        const std::string oobRootTiffStr = oobRootTiff.string();
        auto oobRootReq = makeNativeRawReq(oobRootTiffStr);
        sony2fuji_buffer oobOut{};
        const auto oobRootSt = sony2fuji_process(session, &oobRootReq, &oobOut);
        sony2fuji_release_buffer(&oobOut);
        check(oobRootSt != SONY2FUJI_STATUS_OK && oobRootSt != SONY2FUJI_STATUS_INVALID_ARGUMENT,
              "TIFF with OOB IFD0 offset safely falls back without crash");

        const auto oobChildTiff = dir / "tiff-oob-child-offsets.tiff";
        {
            std::vector<uint8_t> b = {'I', 'I'};
            append16(b, 42u, true);
            append32(b, 8u, true);
            append16(b, 4u, true);
            append16(b, 256u, true); append16(b, 4u, true); append32(b, 1u, true); append32(b, 50000u, true);
            append16(b, 257u, true); append16(b, 4u, true); append32(b, 1u, true); append32(b, 50000u, true);
            append16(b, 330u, true); append16(b, 4u, true); append32(b, 4u, true); append32(b, 0x7FFFFFF0u, true);
            append16(b, 50720u, true); append16(b, 5u, true); append32(b, 2u, true); append32(b, 0x7FFFFFF0u, true);
            append32(b, 0x7FFFFFF0u, true); // OOB nextIfd as well
            writeBytesFile(oobChildTiff, b);
        }
        const std::string oobChildTiffStr = oobChildTiff.string();
        auto oobChildReq = bigTiffReq;
        oobChildReq.input_path = oobChildTiffStr.c_str();
        expectRejected(oobChildReq, "TIFF with OOB SubIFDs/DefaultCropSize/nextIfd offsets preserves valid IFD0 preflight");

        // SHOULD-FIX 1: parseExifOrientation must require count == 1 (count=3 with valueOffset=8 must not transpose as Orientation=8).
        auto writeExifOrientJpg = [&](const std::filesystem::path& target, uint32_t orientCount, uint32_t orientValOrOffset) {
            std::vector<uint8_t> b = {0xFF, 0xD8, 0xFF, 0xE1};
            std::vector<uint8_t> app1 = {'E', 'x', 'i', 'f', 0x00, 0x00, 'I', 'I'};
            append16(app1, 42u, true);
            append32(app1, 8u, true);
            append16(app1, 1u, true);
            append16(app1, 0x0112u, true); // Orientation tag
            append16(app1, 3u, true);      // SHORT
            append32(app1, orientCount, true);
            append32(app1, orientValOrOffset, true);
            append32(app1, 0u, true);
            const uint16_t app1Len = static_cast<uint16_t>(app1.size() + 2u);
            append16(b, app1Len, false);
            b.insert(b.end(), app1.begin(), app1.end());
            const uint8_t sofAndSos[] = {
                0xFF, 0xC0, 0x00, 0x0B, 0x08,
                static_cast<uint8_t>(1000u >> 8), static_cast<uint8_t>(1000u & 0xFFu), // height = 1000
                static_cast<uint8_t>(2000u >> 8), static_cast<uint8_t>(2000u & 0xFFu), // width = 2000
                0x01, 0x11, 0x00,
                0xFF, 0xDA, 0x00, 0x02
            };
            b.insert(b.end(), std::begin(sofAndSos), std::end(sofAndSos));
            writeBytesFile(target, b);
        };
        const auto exifCount3Jpg = dir / "jpeg-exif-orient-count3-2000x1000.jpg";
        const auto exifCount1Jpg = dir / "jpeg-exif-orient-count1-2000x1000.jpg";
        writeExifOrientJpg(exifCount3Jpg, 3u, 8u); // count=3, valueOffset=8 -> must NOT be read as Orientation=8
        writeExifOrientJpg(exifCount1Jpg, 1u, 8u); // count=1, inline value=8 -> true Orientation=8 transpose
        {
            sony2fuji_session* orientSession = nullptr;
            sony2fuji_session_create(&orientSession);
            sony2fuji_geometry_config halfW{};
            halfW.version = SONY2FUJI_GEOMETRY_CONFIG_VERSION;
            halfW.struct_size = sizeof(halfW);
            halfW.crop_width = 0.5f;
            halfW.crop_height = 1.0f;
            sony2fuji_session_set_geometry(orientSession, &halfW);
            const std::string exifCount3JpgStr = exifCount3Jpg.string();
            auto exifReq = makeNativeRawReq(exifCount3JpgStr);
            exifReq.output_target = SONY2FUJI_TARGET_FILE;
            exifReq.output_format = SONY2FUJI_OUTPUT_JPEG;
            exifReq.output_path = wideJpegOut.c_str();
            exifReq.size_mode = SONY2FUJI_SIZE_FIT_SHORT_EDGE;
            exifReq.short_edge = 40000u; // 2000x1000 -> crop 1000x1000 -> 40000x40000 (OK); transpose -> 500x2000 -> 40000x160000 (INVALID_ARGUMENT)
            const auto exifCount3St = sony2fuji_process(orientSession, &exifReq, nullptr);
            check(exifCount3St != SONY2FUJI_STATUS_OK && exifCount3St != SONY2FUJI_STATUS_INVALID_ARGUMENT,
                  "Exif Orientation with count=3 and offset=8 is ignored instead of transposing 2000x1000");

            const std::string exifCount1JpgStr = exifCount1Jpg.string();
            exifReq.input_path = exifCount1JpgStr.c_str();
            exifReq.lut_path = absentLut.c_str();
            exifReq.lut_strength = 1.0f;
            expectRejected(exifReq, "Exif Orientation with count=1 and value=8 still transposes 2000x1000 in preflight", orientSession);
            sony2fuji_session_destroy(orientSession);
        }

        // SHOULD-FIX 2: EXACT and bounded FIT_LONG_EDGE skip source preflight; hot raw_cache session reuses cached size without reopening file;
        // transient open failures must not poison session->probed_header_* cache.
        {
            const auto oversizeSkipPng = dir / "header-3000000000x100.png";
            writePngHeaderOnly(oversizeSkipPng, 3000000000u, 100u);
            const std::string oversizeSkipPngStr = oversizeSkipPng.string();

            sony2fuji_session* coldControlSession = nullptr;
            sony2fuji_session_create(&coldControlSession);
            auto coldNative = makeNativeRawReq(oversizeSkipPngStr);
            coldNative.lut_path = absentLut.c_str();
            coldNative.lut_strength = 1.0f;
            expectRejected(coldNative, "Readable 3000000000x100 PNG header fails preflight when NATIVE probes source size", coldControlSession);
            sony2fuji_session_destroy(coldControlSession);

            sony2fuji_session* coldSkipSession = nullptr;
            sony2fuji_session_create(&coldSkipSession);
            auto coldExact = coldNative;
            coldExact.size_mode = SONY2FUJI_SIZE_EXACT;
            coldExact.target_width = 16u;
            coldExact.target_height = 12u;
            sony2fuji_buffer coldExactOut{};
            const auto coldExactSt = sony2fuji_process(coldSkipSession, &coldExact, &coldExactOut);
            sony2fuji_release_buffer(&coldExactOut);

            auto coldFitLong = coldNative;
            coldFitLong.size_mode = SONY2FUJI_SIZE_FIT_LONG_EDGE;
            coldFitLong.long_edge = 64u;
            sony2fuji_buffer coldFitOut{};
            const auto coldFitSt = sony2fuji_process(coldSkipSession, &coldFitLong, &coldFitOut);
            sony2fuji_release_buffer(&coldFitOut);
            sony2fuji_session_destroy(coldSkipSession);
            check(coldExactSt == SONY2FUJI_STATUS_UNSUPPORTED && coldFitSt == SONY2FUJI_STATUS_UNSUPPORTED,
                  "Bounded EXACT and FIT_LONG_EDGE skip header preflight on oversized readable header and reach loadLUT");
        }
#ifndef _WIN32
        if (geteuid() != 0) {
            const auto hotDng = dir / "hot-cache-32x24.dng";
            std::filesystem::copy_file(linearDngFixture, hotDng, std::filesystem::copy_options::overwrite_existing);
            const std::string hotDngStr = hotDng.string();
            sony2fuji_session* hotSession = nullptr;
            sony2fuji_session_create(&hotSession);
            auto warmReq = makeNativeRawReq(hotDngStr);
            sony2fuji_buffer warmOut{};
            const auto warmSt = sony2fuji_process(hotSession, &warmReq, &warmOut);
            sony2fuji_release_buffer(&warmOut);
            chmod(hotDngStr.c_str(), 0);

            auto hotExact = warmReq;
            hotExact.size_mode = SONY2FUJI_SIZE_EXACT;
            hotExact.target_width = 16u;
            hotExact.target_height = 12u;
            hotExact.exposure_ev = 0.1f;
            sony2fuji_buffer hotOut1{};
            const auto hotExactSt = sony2fuji_process(hotSession, &hotExact, &hotOut1);
            sony2fuji_release_buffer(&hotOut1);

            auto hotFitLong = warmReq;
            hotFitLong.size_mode = SONY2FUJI_SIZE_FIT_LONG_EDGE;
            hotFitLong.long_edge = 64u;
            hotFitLong.exposure_ev = 0.2f;
            sony2fuji_buffer hotOut2{};
            const auto hotFitLongSt = sony2fuji_process(hotSession, &hotFitLong, &hotOut2);
            sony2fuji_release_buffer(&hotOut2);

            auto hotNative = warmReq;
            hotNative.exposure_ev = 0.3f;
            sony2fuji_buffer hotOut3{};
            const auto hotNativeSt = sony2fuji_process(hotSession, &hotNative, &hotOut3);
            sony2fuji_release_buffer(&hotOut3);

            auto hotShortOversize = warmReq;
            hotShortOversize.size_mode = SONY2FUJI_SIZE_FIT_SHORT_EDGE;
            hotShortOversize.short_edge = 45000u; // 32x24 -> 60000x45000 = 2.7GP > INT32_MAX (caught from cached header size)
            hotShortOversize.lut_path = absentLut.c_str();
            hotShortOversize.lut_strength = 1.0f;
            sony2fuji_buffer hotOut4{};
            const auto hotShortSt = sony2fuji_process(hotSession, &hotShortOversize, &hotOut4);
            sony2fuji_release_buffer(&hotOut4);

            chmod(hotDngStr.c_str(), 0600);
            sony2fuji_session_destroy(hotSession);
            check(warmSt == SONY2FUJI_STATUS_OK && hotExactSt == SONY2FUJI_STATUS_OK &&
                  hotFitLongSt == SONY2FUJI_STATUS_OK && hotNativeSt == SONY2FUJI_STATUS_OK &&
                  hotShortSt == SONY2FUJI_STATUS_INVALID_ARGUMENT,
                  "Hot raw_cache session reuses cached size without reopening unreadable RAW input");

            // SF-2(a): chmod 0000 transient open failure must NOT poison session->probed_header_key;
            // after chmod 0644, oversized NATIVE on the same session must still reject pre-decode with INVALID_ARGUMENT.
            const auto transientHugeDng = dir / "transient-unreadable-50000x50000.dng";
            writeTruncatedDngHeader(transientHugeDng, 50000u, 50000u);
            const std::string transientHugeDngStr = transientHugeDng.string();
            sony2fuji_session* poisonGuardSession = nullptr;
            sony2fuji_session_create(&poisonGuardSession);
            chmod(transientHugeDngStr.c_str(), 0);
            auto transientReq = makeNativeRawReq(transientHugeDngStr);
            sony2fuji_buffer transientOut{};
            const auto unreadableSt = sony2fuji_process(poisonGuardSession, &transientReq, &transientOut);
            sony2fuji_release_buffer(&transientOut);
            chmod(transientHugeDngStr.c_str(), 0644);
            check(unreadableSt == SONY2FUJI_STATUS_IO_ERROR,
                  "Unreadable chmod 0000 RAW returns IO_ERROR during transient failure");
            transientReq.lut_path = absentLut.c_str();
            transientReq.lut_strength = 1.0f;
            expectRejected(transientReq,
                           "Restored chmod 0644 oversized NATIVE RAW still fails pre-decode preflight without cache poisoning",
                           poisonGuardSession);
            sony2fuji_session_destroy(poisonGuardSession);
        }
#endif

        // SF-1: Rendered DNG deterministic Classic TIFF bound (pixelBytes + stripTableBytes + metadataBytes <= 2^32 - 1)
        // is enforced at request validation and header preflight before decode/rendering.
        {
            const std::string overCapDngOut = (dir / "over-cap-40000x20000.dng").string();
            auto exact800DngRaw = request(nullptr);
            exact800DngRaw.input_type = SONY2FUJI_INPUT_RAW;
            exact800DngRaw.input_path = absentRaw.c_str();
            exact800DngRaw.lut_path = absentLut.c_str();
            exact800DngRaw.lut_strength = 1.0f;
            exact800DngRaw.intent = SONY2FUJI_INTENT_FINAL;
            exact800DngRaw.output_target = SONY2FUJI_TARGET_FILE;
            exact800DngRaw.output_format = SONY2FUJI_OUTPUT_DNG;
            exact800DngRaw.output_path = overCapDngOut.c_str();
            exact800DngRaw.size_mode = SONY2FUJI_SIZE_EXACT;
            exact800DngRaw.target_width = 40000u;
            exact800DngRaw.target_height = 20000u;
            expectRejected(exact800DngRaw, "EXACT 40000x20000 DNG is rejected before RAW decode via Classic TIFF capacity bound");

            auto exact800DngBuf = request(dngPixels);
            exact800DngBuf.lut_path = absentLut.c_str();
            exact800DngBuf.lut_strength = 1.0f;
            exact800DngBuf.intent = SONY2FUJI_INTENT_FINAL;
            exact800DngBuf.output_target = SONY2FUJI_TARGET_FILE;
            exact800DngBuf.output_format = SONY2FUJI_OUTPUT_DNG;
            exact800DngBuf.output_path = overCapDngOut.c_str();
            exact800DngBuf.size_mode = SONY2FUJI_SIZE_EXACT;
            exact800DngBuf.target_width = 40000u;
            exact800DngBuf.target_height = 20000u;
            expectRejected(exact800DngBuf, "EXACT 40000x20000 DNG from buffer returns INVALID_ARGUMENT before rendering");

            auto fitLongImpossibleDng = exact800DngRaw;
            fitLongImpossibleDng.size_mode = SONY2FUJI_SIZE_FIT_LONG_EDGE;
            fitLongImpossibleDng.long_edge = 720000000u; // 720M * 1 * 6 > 4.29GB in both orientations
            expectRejected(fitLongImpossibleDng, "FIT_LONG_EDGE >715.82M DNG is rejected at request validation");

            const auto square3kPng = dir / "header-3000x3000.png";
            writePngHeaderOnly(square3kPng, 3000u, 3000u);
            const std::string square3kPngStr = square3kPng.string();
            auto fitLong30kSquareDng = exact800DngRaw;
            fitLong30kSquareDng.input_path = square3kPngStr.c_str();
            fitLong30kSquareDng.size_mode = SONY2FUJI_SIZE_FIT_LONG_EDGE;
            fitLong30kSquareDng.long_edge = 30000u; // 30000x30000 * 6 = 5.4GB > Classic TIFF 4.29GB
            expectRejected(fitLong30kSquareDng, "FIT_LONG_EDGE=30000 DNG on 1:1 header fails pre-decode header preflight");

            const auto pano3kPng = dir / "header-3000x1000.png";
            writePngHeaderOnly(pano3kPng, 3000u, 1000u);
            const std::string pano3kPngStr = pano3kPng.string();
            auto fitLong30kPanoDng = fitLong30kSquareDng;
            fitLong30kPanoDng.input_path = pano3kPngStr.c_str();
            fitLong30kPanoDng.lut_path = nullptr;
            fitLong30kPanoDng.lut_strength = 0.0f;
            check(sony2fuji_process(session, &fitLong30kPanoDng, nullptr) == SONY2FUJI_STATUS_UNSUPPORTED,
                  "FIT_LONG_EDGE=30000 DNG on 3:1 header (30000x10000 = 1.8GB) passes Classic TIFF preflight");
        }

        // Blocking 2: 715.8M-2.14G JPEG (40000x20000 = 800MP, rgbBytes = 2.4GB > INT32_MAX, edges <= 65535)
        // passes validation/preflight and stb_image_write indexes >2GB RGB offsets via size_t without int overflow.
        const auto png800mp = dir / "header-40000x20000.png";
        writePngHeaderOnly(png800mp, 40000u, 20000u);
        const std::string png800mpStr = png800mp.string();
        auto jpeg800mpNative = makeNativeRawReq(png800mpStr);
        jpeg800mpNative.output_target = SONY2FUJI_TARGET_FILE;
        jpeg800mpNative.output_format = SONY2FUJI_OUTPUT_JPEG;
        jpeg800mpNative.output_path = wideJpegOut.c_str();
        check(sony2fuji_process(session, &jpeg800mpNative, nullptr) == SONY2FUJI_STATUS_UNSUPPORTED,
              "NATIVE 40000x20000 (800MP > 715.8MP) JPEG export passes size preflight");
        {
            sony2fuji_session* jpeg800CancelSession = nullptr;
            sony2fuji_session_create(&jpeg800CancelSession);
            int polls800 = 0;
            sony2fuji_session_set_cancellation_callback(jpeg800CancelSession, [](void* ctx) -> int {
                int& c = *static_cast<int*>(ctx);
                return (++c >= 2) ? 1 : 0;
            }, &polls800);
            auto exact800Jpeg = request(dngPixels);
            exact800Jpeg.intent = SONY2FUJI_INTENT_FINAL;
            exact800Jpeg.output_target = SONY2FUJI_TARGET_FILE;
            exact800Jpeg.output_format = SONY2FUJI_OUTPUT_JPEG;
            exact800Jpeg.output_path = wideJpegOut.c_str();
            exact800Jpeg.size_mode = SONY2FUJI_SIZE_EXACT;
            exact800Jpeg.target_width = 40000u;
            exact800Jpeg.target_height = 20000u;
            const auto exact800St = sony2fuji_process(jpeg800CancelSession, &exact800Jpeg, nullptr);
            sony2fuji_session_destroy(jpeg800CancelSession);
            check(exact800St == SONY2FUJI_STATUS_CANCELLED && polls800 == 2,
                  "EXACT 40000x20000 (800MP) JPEG passes validation and preflight");
        }
#if !defined(_WIN32) && INTPTR_MAX == INT64_MAX
        {
#ifndef MAP_ANON
#define MAP_ANON MAP_ANONYMOUS
#endif
            constexpr int kBigW = 40000;
            constexpr int kBigH = 20000;
            constexpr size_t kBigBytes = static_cast<size_t>(kBigW) * static_cast<size_t>(kBigH) * 3u; // 2.4 GB > INT32_MAX
            const long sysPage = sysconf(_SC_PAGESIZE);
            const size_t pageSize = sysPage > 0 ? static_cast<size_t>(sysPage) : 4096u;
            const size_t kMapLen = ((kBigBytes + pageSize - 1u) / pageSize) * pageSize;
            const size_t tailStartByte = static_cast<size_t>(kBigH - 16) * static_cast<size_t>(kBigW) * 3u;
            const size_t alignedTailStart = (tailStartByte / pageSize) * pageSize;

            // Reserve 2.4 GB with PROT_NONE (zero commit charge; <2 GB index wrap-around faults immediately),
            // and mprotect only the page-aligned tail covering the bottom 16 rows as RW.
            errno = 0;
            void* mapped = mmap(nullptr, kMapLen, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
            if (mapped == MAP_FAILED) {
                const int err = errno;
                if (err == ENOMEM) {
                    std::cout << "SKIP 800MP stb_image_write mmap probe: ENOMEM reserving 2.4GB PROT_NONE region\n";
                } else {
                    check(false, "800MP stb_image_write PROT_NONE mmap failed with unexpected errno");
                }
            } else {
                auto* rgb = static_cast<unsigned char*>(mapped);
                errno = 0;
                if (mprotect(rgb + alignedTailStart, kMapLen - alignedTailStart, PROT_READ | PROT_WRITE) != 0) {
                    const int err = errno;
                    munmap(mapped, kMapLen);
                    if (err == ENOMEM) {
                        std::cout << "SKIP 800MP stb_image_write mmap probe: ENOMEM committing 16-row tail pages\n";
                    } else {
                        check(false, "800MP stb_image_write tail mprotect failed with unexpected errno");
                    }
                } else {
                    // Populate bottom 16 rows (accessed first when flip_vertically_on_write == 1, where base_p > INT32_MAX).
                    for (int r = kBigH - 16; r < kBigH; ++r) {
                        const size_t rowBase = static_cast<size_t>(r) * static_cast<size_t>(kBigW) * 3u;
                        for (int c = 0; c < 512; ++c) {
                            const size_t p = rowBase + static_cast<size_t>(c) * 3u;
                            rgb[p + 0] = static_cast<unsigned char>((r * 37 + c * 73) & 0xFF);
                            rgb[p + 1] = static_cast<unsigned char>((r * 53 + c * 29) & 0xFF);
                            rgb[p + 2] = static_cast<unsigned char>((r * 97 + c * 11) & 0xFF);
                        }
                    }
                    struct JpegStreamProbe {
                        std::jmp_buf env{};
                        size_t totalBytes = 0;
                        unsigned char firstTwo[2] = {0, 0};
                    };
                    struct FlipResetGuard {
                        ~FlipResetGuard() { stbi_flip_vertically_on_write(0); }
                    } flipGuard;
                    stbi_flip_vertically_on_write(1);

                    bool q85Ok = false, q95Ok = false;
                    for (int quality : {85, 95}) {
                        JpegStreamProbe probe{};
                        if (setjmp(probe.env) == 0) {
                            stbi_write_jpg_to_func([](void* ctx, void* data, int size) {
                                auto& st = *static_cast<JpegStreamProbe*>(ctx);
                                const auto* bytes = static_cast<const unsigned char*>(data);
                                for (int i = 0; i < size && st.totalBytes + static_cast<size_t>(i) < 2u; ++i) {
                                    st.firstTwo[st.totalBytes + static_cast<size_t>(i)] = bytes[i];
                                }
                                st.totalBytes += static_cast<size_t>(size > 0 ? size : 0);
                                if (st.totalBytes >= 1024u) {
                                    std::longjmp(st.env, 1);
                                }
                            }, &probe, kBigW, kBigH, 3, rgb, quality);
                        }
                        const bool ok = probe.totalBytes >= 1024u && probe.firstTwo[0] == 0xFFu && probe.firstTwo[1] == 0xD8u;
                        if (quality == 85) q85Ok = ok;
                        else q95Ok = ok;
                    }
                    munmap(mapped, kMapLen);
                    check(q85Ok && q95Ok,
                          "stb_image_write encodes 40000x20000 (>2GB base_p) macroblocks with <2GB PROT_NONE wrap-around guard");
                }
            }
        }
#endif

        // NOTE: resizeBilinear/sampleBilinear double precision + clamp for single edge > 2^24 (16,777,216).
        {
            constexpr uint32_t kWide24A = 16777222u; // srcWidth - 1 = 16777221 (float rounds down to 16777220)
            constexpr uint32_t kWide24B = 16777220u; // srcWidth - 1 = 16777219 (float rounds up to 16777220 == srcWidth OOB)
            std::vector<unsigned char> linePixels(static_cast<size_t>(kWide24A) * 3u, 0u);
            linePixels[(kWide24A - 1u) * 3u + 0u] = 255u;
            linePixels[(kWide24A - 1u) * 3u + 1u] = 255u;
            linePixels[(kWide24A - 1u) * 3u + 2u] = 255u;

            auto makeWideResizeReq = [&](uint32_t srcW, uint32_t dstW) {
                auto r = request(linePixels.data());
                r.input_width = srcW;
                r.input_height = 1u;
                r.input_is_linear = 0;
                r.intent = SONY2FUJI_INTENT_FINAL;
                r.size_mode = SONY2FUJI_SIZE_EXACT;
                r.target_width = dstW;
                r.target_height = 1u;
                return r;
            };
            sony2fuji_buffer outA{};
            const auto reqA = makeWideResizeReq(kWide24A, 2u);
            const auto stA = sony2fuji_process(session, &reqA, &outA);
            const auto* bytesA = static_cast<const unsigned char*>(outA.data);
            const bool okA = stA == SONY2FUJI_STATUS_OK && outA.width == 2u && outA.height == 1u &&
                bytesA && bytesA[0] < 32u && bytesA[3] > 200u;
            sony2fuji_release_buffer(&outA);

            std::fill(linePixels.begin(), linePixels.end(), 0u);
            linePixels[(kWide24B - 1u) * 3u + 0u] = 255u;
            linePixels[(kWide24B - 1u) * 3u + 1u] = 255u;
            linePixels[(kWide24B - 1u) * 3u + 2u] = 255u;
            sony2fuji_buffer outB{};
            const auto reqB = makeWideResizeReq(kWide24B, 3u);
            const auto stB = sony2fuji_process(session, &reqB, &outB);
            const auto* bytesB = static_cast<const unsigned char*>(outB.data);
            const bool okB = stB == SONY2FUJI_STATUS_OK && outB.width == 3u && outB.height == 1u &&
                bytesB && bytesB[0] < 32u && bytesB[6] > 200u;
            sony2fuji_release_buffer(&outB);

            check(okA && okB,
                  "resizeBilinear/sampleBilinear preserves exact endpoint indexing and bounds above 2^24 width");
        }
    }
    auto dngRequest = request(dngPixels);
    const std::string dngPath = (dir / "rendered.dng").string();
    dngRequest.output_target = SONY2FUJI_TARGET_FILE;
    dngRequest.output_format = static_cast<sony2fuji_output_format>(4);
    dngRequest.output_path = dngPath.c_str();
    dngRequest.intent = SONY2FUJI_INTENT_FINAL;
    check(sony2fuji_process(session, &dngRequest, nullptr) == SONY2FUJI_STATUS_OK &&
          std::filesystem::file_size(dngPath) > 8, "C ABI writes rendered DNG as a file");
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
