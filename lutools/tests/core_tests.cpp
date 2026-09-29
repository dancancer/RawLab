#include "sony2fuji/sony2fuji.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#include "sony2fuji/gpu/lut_gpu.h"
#include "core/preview_exposure.h"
#include "core/photo_rendering.h"
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
        const bool isLog=file.path().string().find("to_FLog2-709")!=std::string::npos;
        check(film && film->isPhotoLUT()!=isLog, file.path().filename().string().c_str());
    }
    std::string log = std::string(TEST_SOURCE_DIR)+"/flog-2-new/FLog2_to_FLog2-709_65grid_V.1.00.cube";
    r.lut_path=log.c_str(); r.lut_strength=1;
    check(sony2fuji_process(session,&r,&out)==SONY2FUJI_STATUS_UNSUPPORTED, "Photo pipeline rejects Log output");
    sony2fuji_release_buffer(&out);
    const struct { const char* gamma; const char* gamut; bool accepted; } contracts[] = {
        {"F-Log2 to EKTAR 100 Phuket", "F-Gamut to ITU-R BT.709", true},
        {"F-Log2 to My Custom Look", "F-Gamut to ITU-R BT.709", true},
        {"f-log2 TO independently-named-look", "f-gamut TO itu-r bt.709", true},
        {"F-Log2 to F-Log2", "F-Gamut to ITU-R BT.709", false},
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
    sony2fuji_session_destroy(session);
    std::filesystem::remove_all(dir);
    return failures ? 1 : 0;
}
