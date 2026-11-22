#include "test_harness.h"
#include "sony2fuji/raw_processor.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#include "core/white_balance.h"
#include <libraw/libraw.h>
#include <array>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <memory>
#include <string>

using rawlab::test::checkPass;
int main(int argc,char** argv) {
    for (double temperature:{2000.,2500.,5000.,6500.,10000.,50000.}) {
        const auto xy=sony2fuji::temperatureWhitePoint(temperature,20);
        const auto result=sony2fuji::whitePointTemperature(xy);
        checkPass(std::abs(result.temperature-temperature)/temperature<0.005 && std::abs(result.tint-20)<0.5,
              "Kelvin/tint and illuminant xy round trip");
    }
    const auto d65=sony2fuji::whitePointTemperature({.3127,.3290});
    checkPass(std::abs(d65.temperature-6504)<30,"D65 has the expected correlated color temperature");
    auto fixture=std::make_unique<libraw_data_t>();
    fixture->idata.colors=3; fixture->idata.dng_version=1;
    const auto white=sony2fuji::temperatureWhitePoint(5000,0);
    const std::array<double,3> xyz={white.x/white.y,1,(1-white.x-white.y)/white.y};
    const double calibrationMatrix[3][3]={{1,.1,0},{0,1,.2},{.3,0,1}};
    const double color1[3]={.9,1.1,.8}, color2[3]={1.05,.95,1.2};
    const double fraction=(1/5000.0-1/6504.0)/(1/2856.0-1/6504.0);
    std::array<double,3> expectedResponse{};
    for (int r=0;r<3;++r) {
        fixture->color.dng_levels.analogbalance[r]=r+2;
        for (int c=0;c<3;++c) {
            for (int profile=0;profile<2;++profile) {
                auto& matrix=fixture->color.dng_color[profile];
                matrix.illuminant=profile==0 ? 17 : 21;
                matrix.calibration[r][c]=calibrationMatrix[r][c];
                matrix.colormatrix[r][c]=r==c ? (profile==0 ? color1[r] : color2[r]) : 0;
            }
            expectedResponse[r]+=(r+2)*calibrationMatrix[r][c]*(fraction*color1[c]+(1-fraction)*color2[c])*xyz[c];
        }
        fixture->color.cam_mul[r]=1/expectedResponse[r];
    }
    sony2fuji::CameraWhiteBalance synthetic(*fixture);
    float gains[4]{};
    checkPass(synthetic.available() && synthetic.multipliers(5000,0,gains),"Synthetic dual-illuminant DNG is calibrated");
    for (int c=0;c<3;++c) checkPass(std::abs(gains[c]-expectedResponse[1]/expectedResponse[c])<1e-5,
        "DNG applies AnalogBalance times CameraCalibration times ColorMatrix with reciprocal-K interpolation");
    checkPass(std::abs(synthetic.asShot().temperature-5000)<10 && std::abs(synthetic.asShot().tint)<.1,
          "DNG inverse calibration recovers as-shot white point");
    const std::array<std::array<double,3>,3> profile={{{1,0,0},{0,1,0},{0,0,1}}};
    auto invalidCamera=std::make_unique<libraw_data_t>();
    invalidCamera->idata.colors=3;
    sony2fuji::CameraWhiteBalance missingMatrix(*invalidCamera);
    checkPass(!missingMatrix.available() && !missingMatrix.multipliers(5000,0,gains),
          "Missing camera calibration cannot supply custom white balance");
    checkPass(missingMatrix.multipliers(5000,0,gains,&profile),
          "A valid profile supplies custom WB without a camera matrix or as-shot calibration");
    for (int c=0;c<3;++c) checkPass(std::abs(gains[c]-xyz[1]/xyz[c])<1e-5,
        "Profile custom WB uses the profile matrix without camera calibration");
    for (int c=0;c<3;++c) invalidCamera->color.cam_xyz[c][c]=1;
    sony2fuji::CameraWhiteBalance missingNeutral(*invalidCamera);
    checkPass(!missingNeutral.available() && missingNeutral.multipliers(5000,0,gains,&profile),
          "Missing as-shot multipliers do not disable a supplied profile's custom WB");
    checkPass(!missingNeutral.multipliers(1000,0,gains,&profile),
          "A supplied profile does not bypass custom WB parameter validation");

    // solveTemperatureTint inverse check against CameraWhiteBalance::multipliers
    {
        float targetGains[4]{};
        checkPass(synthetic.multipliers(5200.0, 12.0, targetGains), "Compute forward gains at 5200K/+12");
        const std::array<double,3> sampleCamRgb = {1.0 / targetGains[0], 1.0 / targetGains[1], 1.0 / targetGains[2]};
        sony2fuji::TemperatureTint solved{};
        checkPass(synthetic.solveTemperatureTint(sampleCamRgb, solved),
                  "solveTemperatureTint succeeds for calibrated camera");
        checkPass(std::abs(solved.temperature - 5200.0) < 15.0 && std::abs(solved.tint - 12.0) < 0.5,
                  "solveTemperatureTint recovers 5200K / +12 within tolerance");
    }

    // SDR Raster Relative WB + WB Eyedropper on DisplayBuffer + Auto Exposure + Zero Bypass
    {
        sony2fuji_session* rasterSession = nullptr;
        checkPass(sony2fuji_session_create(&rasterSession) == SONY2FUJI_STATUS_OK && rasterSession != nullptr,
                  "Create session for raster WB tests");
        // 8x8 raster image: left warm/bluish neutralizable patch, top-right overexposed clipped pixels, mixed patch at x=0.5,y=0.25
        constexpr int W = 8, H = 8;
        std::vector<uint8_t> img(size_t(W) * H * 4, 0);
        for (int y = 0; y < H; ++y) {
            for (int x = 0; x < W; ++x) {
                const size_t idx = (size_t(y) * W + x) * 4;
                if (x >= 5 && y <= 2) {
                    img[idx] = 255; img[idx + 1] = 255; img[idx + 2] = 255; img[idx + 3] = 255;
                } else if (x == 4 && y == 1) {
                    img[idx] = 160; img[idx + 1] = 140; img[idx + 2] = 110; img[idx + 3] = 255;
                } else {
                    img[idx] = 180; img[idx + 1] = 155; img[idx + 2] = 120; img[idx + 3] = 255;
                }
            }
        }
        sony2fuji_request rReq{};
        rReq.version = SONY2FUJI_REQUEST_VERSION; rReq.struct_size = sizeof(rReq);
        rReq.input_type = SONY2FUJI_INPUT_DISPLAY_BUFFER;
        rReq.input_pixels = img.data(); rReq.input_width = W; rReq.input_height = H;
        rReq.input_pixel_format = SONY2FUJI_PIXEL_RGBA8;
        rReq.wb_mode = SONY2FUJI_WB_CAMERA; rReq.temperature = 6500; rReq.tint = 0;
        rReq.brightness = 1; rReq.contrast = 1; rReq.saturation = 1;
        rReq.intent = SONY2FUJI_INTENT_FINAL; rReq.size_mode = SONY2FUJI_SIZE_NATIVE;
        rReq.output_target = SONY2FUJI_TARGET_BUFFER; rReq.output_format = SONY2FUJI_OUTPUT_RGB8;

        auto renderRaster = [&](const sony2fuji_request& req) {
            sony2fuji_buffer buf{};
            checkPass(sony2fuji_process(rasterSession, &req, &buf) == SONY2FUJI_STATUS_OK, "Raster render");
            const auto* p = static_cast<const uint8_t*>(buf.data);
            std::vector<uint8_t> out(p, p + buf.size_bytes);
            sony2fuji_release_buffer(&buf);
            return out;
        };
        const auto noneOut = renderRaster(rReq);
        auto applyRasterRelativeWb = [&](double temp, double tint) {
            const std::string json =
                R"({"schema_version":17,"processing":{"family":"rawlab","version":3,"quality":"standard"},"input":{"path":"memory.png","type":"raster"},"edits":{"exposure":{"mode":"sensor","ev":0.0,"brightness":1.0},"white_balance":{"mode":"relative","relative_temperature":)" +
                std::to_string(temp) + R"(,"relative_tint":)" + std::to_string(tint) +
                R"(}},"output":{"path":"out.png","format":"png","size":{"mode":"native"}}})";
            checkPass(sony2fuji_apply_params(rasterSession, json.c_str()) == SONY2FUJI_STATUS_OK,
                      "Apply raster relative WB via canonical recipe");
        };
        applyRasterRelativeWb(6500.0, 0.0);
        checkPass(renderRaster(rReq) == noneOut, "Raster Relative 6500K/0 tint zero-bypass matches neutral bit-identical");

        // Probe warm gray card at center (0.25, 0.5)
        sony2fuji_wb_probe_query q{SONY2FUJI_WB_PROBE_VERSION, sizeof(q), 0.25f, 0.5f, 3, 0};
        sony2fuji_wb_probe_result res{};
        res.version = SONY2FUJI_WB_PROBE_VERSION; res.struct_size = sizeof(res);
        checkPass(sony2fuji_session_sample_wb_probe(rasterSession, &rReq, &q, &res) == SONY2FUJI_STATUS_OK, "Probe warm patch");
        checkPass(res.availability == SONY2FUJI_WB_PROBE_AVAILABLE && res.valid_pixel_count == 9 && res.temperature < 6500.f,
                  "Warm cast resolves cooler neutralizing relative Kelvin");

        // Apply solved relative WB -> pixels neutralize
        applyRasterRelativeWb(res.temperature, res.tint);
        const auto neutralized = renderRaster(rReq);
        checkPass(neutralized != noneOut, "Relative WB changes SDR raster output");
        // Verify auto exposure accepts Relative WB on raster
        float autoEv = 0;
        checkPass(sony2fuji_session_estimate_auto_exposure(rasterSession, &rReq, &autoEv) == SONY2FUJI_STATUS_OK,
                  "estimateAutoExposure accepts Relative WB on raster");

        // All-clipped top-right corner returns OVEREXPOSED
        sony2fuji_wb_probe_query qClip{SONY2FUJI_WB_PROBE_VERSION, sizeof(qClip), 0.85f, 0.1f, 3, 0};
        sony2fuji_wb_probe_result resClip{};
        resClip.version = SONY2FUJI_WB_PROBE_VERSION; resClip.struct_size = sizeof(resClip);
        checkPass(sony2fuji_session_sample_wb_probe(rasterSession, &rReq, &qClip, &resClip) == SONY2FUJI_STATUS_OK &&
                  resClip.availability == SONY2FUJI_WB_PROBE_OVEREXPOSED && resClip.valid_pixel_count == 0,
                  "All-clipped 3x3 patch returns OVEREXPOSED");

        // Partial-clipped patch around (4/7, 1/7) returns AVAILABLE with reduced valid_pixel_count
        sony2fuji_wb_probe_query qPartial{SONY2FUJI_WB_PROBE_VERSION, sizeof(qPartial), 0.57f, 0.18f, 3, 0};
        sony2fuji_wb_probe_result resPartial{};
        resPartial.version = SONY2FUJI_WB_PROBE_VERSION; resPartial.struct_size = sizeof(resPartial);
        checkPass(sony2fuji_session_sample_wb_probe(rasterSession, &rReq, &qPartial, &resPartial) == SONY2FUJI_STATUS_OK &&
                  resPartial.availability == SONY2FUJI_WB_PROBE_AVAILABLE &&
                  resPartial.valid_pixel_count > 0 && resPartial.rejected_overexposed_count > 0,
                  "Partially clipped 3x3 patch filters out clipped pixels while remaining AVAILABLE");

        // Post-geometry coordinate mapping: after quarter_turns=1, clipped top-right corner moves to bottom-right!
        sony2fuji_geometry_config geom{};
        geom.version = SONY2FUJI_GEOMETRY_CONFIG_VERSION; geom.struct_size = sizeof(geom);
        geom.crop_width = 1.0f; geom.crop_height = 1.0f; geom.quarter_turns = 1;
        checkPass(sony2fuji_session_set_geometry(rasterSession, &geom) == SONY2FUJI_STATUS_OK, "Set quarter_turns=1 geometry");
        sony2fuji_wb_probe_query qRot{SONY2FUJI_WB_PROBE_VERSION, sizeof(qRot), 0.9f, 0.85f, 1, 0};
        sony2fuji_wb_probe_result resRot{};
        resRot.version = SONY2FUJI_WB_PROBE_VERSION; resRot.struct_size = sizeof(resRot);
        checkPass(sony2fuji_session_sample_wb_probe(rasterSession, &rReq, &qRot, &resRot) == SONY2FUJI_STATUS_OK &&
                  resRot.availability == SONY2FUJI_WB_PROBE_OVEREXPOSED,
                  "WB probe applies post-geometry coordinate transform");
        sony2fuji_session_destroy(rasterSession);
    }
    if (argc<2) return rawlab::test::exitCode();
    if (rawlab::test::failureCount()) return 1;
    const char* rawPath=nullptr;
    if (argc==3 && std::string(argv[1])=="--default-raw") {
        if (!argv[2] || !*argv[2] || !std::filesystem::is_regular_file(std::filesystem::u8path(argv[2]))) {
            std::cout<<"SKIP dng_white_balance: default RAW sample not present ("<<(argv[2] ? argv[2] : "")<<")\n";
            return 77;
        }
        rawPath=argv[2];
    } else if (argc==2) {
        const char* argRaw=*argv[1] ? argv[1] : nullptr;
        const char* envRaw=std::getenv("RAWLAB_TEST_RAW");
        if (envRaw && !*envRaw) envRaw=nullptr;
        rawPath=argRaw ? argRaw : envRaw;
        if (!rawPath) {
            std::cout<<"SKIP raw_white_balance: supply SONY2FUJI_TEST_RAW or RAWLAB_TEST_RAW\n";
            return 77;
        }
        if (!std::filesystem::is_regular_file(std::filesystem::u8path(rawPath))) {
            std::cerr<<"FAIL raw_white_balance: RAW sample does not exist: "<<rawPath<<'\n';
            return 1;
        }
    } else {
        return 2;
    }
    LibRaw calibration;
    checkPass(calibration.open_file(rawPath)==LIBRAW_SUCCESS,"Read camera matrix fixture");
    sony2fuji::CameraWhiteBalance camera(calibration.imgdata);
    for (double temperature:{2000.,50000.}) for (double tint:{-150.,150.}) {
        float gains[4]{};
        checkPass(camera.multipliers(temperature,tint,gains),"Slider endpoints produce usable camera gains");
    }
    sony2fuji::RAWProcessor raw;
    checkPass(raw.loadFile(rawPath)==sony2fuji::ErrorCode::Success,"Read RAW calibration");
    float temperature=0,tint=0;
    checkPass(raw.getAsShotWhiteBalance(temperature,tint),"As-shot is derived from camera calibration");
    std::cout<<"As-shot "<<temperature<<" K / "<<tint<<'\n';
    sony2fuji_session* session=nullptr; sony2fuji_session_create(&session);
    float t=0,g=0;
    checkPass(sony2fuji_session_get_raw_white_balance(session,&t,&g)==SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "No stale white balance before decoding");
    sony2fuji_request request{};
    request.version=SONY2FUJI_REQUEST_VERSION; request.struct_size=sizeof(request);
    request.input_type=SONY2FUJI_INPUT_RAW; request.input_path=rawPath;
    request.wb_mode=SONY2FUJI_WB_CAMERA; request.temperature=6500;
    request.brightness=request.contrast=request.saturation=1;
    request.intent=SONY2FUJI_INTENT_PREVIEW; request.size_mode=SONY2FUJI_SIZE_NATIVE;
    request.preview_long_edge=180; request.output_target=SONY2FUJI_TARGET_BUFFER;
    request.output_format=SONY2FUJI_OUTPUT_RGB8;
    auto render=[&]() {
        sony2fuji_buffer buffer{};
        const auto status=sony2fuji_process(session,&request,&buffer);
        checkPass(status==SONY2FUJI_STATUS_OK,"White balance renders real RAW");
        std::array<double,3> sum{};
        if (status==SONY2FUJI_STATUS_OK) {
            const auto* bytes=static_cast<const unsigned char*>(buffer.data);
            for (unsigned y=0;y<buffer.height;++y) for (unsigned x=0;x<buffer.width;++x)
                for (int c=0;c<3;++c) sum[c]+=bytes[y*buffer.stride_bytes+x*3+c];
        }
        sony2fuji_release_buffer(&buffer); return sum;
    };
    const auto original=render();
    checkPass(sony2fuji_session_get_raw_white_balance(session,&t,&g)==SONY2FUJI_STATUS_OK &&
          std::abs(t-temperature)<1 && std::abs(g-tint)<.1,"Decode preserves as-shot metadata");
    request.wb_mode=SONY2FUJI_WB_TEMPERATURE; request.temperature=temperature; request.tint=tint;
    const auto matched=render();
    for (int c=0;c<3;++c) {
        const double error=std::abs(matched[c]-original[c])/std::max(1.0,original[c]);
        const auto label =
            "Absolute as-shot WB preserves the camera output and exposure within 0.5 percent; channel " +
            std::to_string(c) + " error=" + std::to_string(error*100) + " percent";
        checkPass(error<0.005,label.c_str());
    }
    request.wb_mode=SONY2FUJI_WB_TEMPERATURE; request.temperature=4000; request.tint=0;
    const auto cool=render(); request.temperature=8500; const auto warm=render();
    checkPass(warm[0]/warm[2]>cool[0]/cool[2],"Absolute Kelvin increases RAW warmth");
    request.temperature=5500; request.tint=-50; const auto green=render();
    request.tint=50; const auto magenta=render();
    checkPass(magenta[1]/(magenta[0]+magenta[2])<green[1]/(green[0]+green[2]),"Positive RAW tint adds magenta");
    request.wb_mode=SONY2FUJI_WB_CAMERA; request.temperature=6500; request.tint=0;
    checkPass(render()==original,"As-shot reset restores exact output after custom WB and cache changes");
    request.wb_mode=SONY2FUJI_WB_TEMPERATURE; request.temperature=1000;
    sony2fuji_buffer buffer{};
    checkPass(sony2fuji_process(session,&request,&buffer)==SONY2FUJI_STATUS_INVALID_ARGUMENT,"Invalid Kelvin is rejected");
    sony2fuji_session_set_raw_exposure_mode(session,SONY2FUJI_EXPOSURE_PREVIEW);
    request.wb_mode=SONY2FUJI_WB_CAMERA; request.temperature=6500; request.tint=0; render();
    float baseline=0,metadata=0,customBaseline=0;
    sony2fuji_session_get_raw_exposure(session,&baseline,&metadata);
    request.wb_mode=SONY2FUJI_WB_TEMPERATURE; request.temperature=8500; render();
    sony2fuji_session_get_raw_exposure(session,&customBaseline,&metadata);
    checkPass(std::abs(baseline-customBaseline)<1e-5,"White balance leaves preview-matched exposure anchored to as-shot");

    // Calibrated RAW WB eyedropper: sample at (0.5, 0.5), apply solved (temperature, tint), and verify idempotence
    {
        request.wb_mode = SONY2FUJI_WB_CAMERA; request.temperature = 6500; request.tint = 0;
        sony2fuji_wb_probe_query rq{SONY2FUJI_WB_PROBE_VERSION, sizeof(rq), 0.5f, 0.5f, 3, 0};
        sony2fuji_wb_probe_result rres{};
        rres.version = SONY2FUJI_WB_PROBE_VERSION; rres.struct_size = sizeof(rres);
        checkPass(sony2fuji_session_sample_wb_probe(session, &request, &rq, &rres) == SONY2FUJI_STATUS_OK,
                  "Calibrated RAW WB probe succeeds");
        if (rres.availability == SONY2FUJI_WB_PROBE_AVAILABLE) {
            request.wb_mode = SONY2FUJI_WB_TEMPERATURE;
            request.temperature = rres.temperature;
            request.tint = rres.tint;
            sony2fuji_wb_probe_result rres2{};
            rres2.version = SONY2FUJI_WB_PROBE_VERSION; rres2.struct_size = sizeof(rres2);
            checkPass(sony2fuji_session_sample_wb_probe(session, &request, &rq, &rres2) == SONY2FUJI_STATUS_OK &&
                      rres2.availability == SONY2FUJI_WB_PROBE_AVAILABLE &&
                      std::abs(rres2.temperature - rres.temperature) < 50.0f &&
                      std::abs(rres2.tint - rres.tint) < 2.0f,
                      "RAW WB eyedropper probe is idempotent across re-renders");
        }
    }
    sony2fuji_session_destroy(session);
    return rawlab::test::exitCode();
}
