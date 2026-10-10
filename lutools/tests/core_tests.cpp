#include "sony2fuji/sony2fuji.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#include "sony2fuji/gpu/lut_gpu.h"
#include "core/preview_exposure.h"
#include "core/photo_rendering.h"
#include "core/photo_lut.h"
#include <cmath>
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
#include <unistd.h>
#include <pthread.h>
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

int main() {
    std::cout << std::unitbuf;
    const std::string thumbnailRaw=TEST_RAW_PATH;
    if (!thumbnailRaw.empty()) {
#ifdef _WIN32
    HANDLE worker = CreateThread(nullptr, 512*1024, [](LPVOID path)->DWORD {
        return loadPreviewLuminance(static_cast<const char*>(path)).empty() ? 1 : 0;
    }, const_cast<char*>(thumbnailRaw.c_str()), STACK_SIZE_PARAM_IS_A_RESERVATION, nullptr);
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
    },const_cast<char*>(thumbnailRaw.c_str()));
    pthread_attr_destroy(&attr);
    void* result=nullptr;
    if (!started) pthread_join(worker,&result);
    check(!started && !result,"Preview decode fits a desktop worker thread stack");
#endif
    } else std::cout << "SKIP worker thumbnail (set SONY2FUJI_TEST_RAW)\n";
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

    sony2fuji_session* session=nullptr;
    sony2fuji_session_create(&session);
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
