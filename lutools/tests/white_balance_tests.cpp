#include "sony2fuji/raw_processor.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#include "core/white_balance.h"
#include <libraw/libraw.h>
#include <array>
#include <cmath>
#include <iostream>
#include <memory>

int failures=0;
void check(bool value,const char* name) {
    std::cout<<(value ? "PASS " : "FAIL ")<<name<<'\n'; if (!value) ++failures;
}
int main(int argc,char** argv) {
    for (double temperature:{2000.,2500.,5000.,6500.,10000.,50000.}) {
        const auto xy=sony2fuji::temperatureWhitePoint(temperature,20);
        const auto result=sony2fuji::whitePointTemperature(xy);
        check(std::abs(result.temperature-temperature)/temperature<0.005 && std::abs(result.tint-20)<0.5,
              "Kelvin/tint and illuminant xy round trip");
    }
    const auto d65=sony2fuji::whitePointTemperature({.3127,.3290});
    check(std::abs(d65.temperature-6504)<30,"D65 has the expected correlated color temperature");
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
    check(synthetic.available() && synthetic.multipliers(5000,0,gains),"Synthetic dual-illuminant DNG is calibrated");
    for (int c=0;c<3;++c) check(std::abs(gains[c]-expectedResponse[1]/expectedResponse[c])<1e-5,
        "DNG applies AnalogBalance times CameraCalibration times ColorMatrix with reciprocal-K interpolation");
    check(std::abs(synthetic.asShot().temperature-5000)<10 && std::abs(synthetic.asShot().tint)<.1,
          "DNG inverse calibration recovers as-shot white point");
    if (argc<2) return failures;
    LibRaw calibration;
    check(calibration.open_file(argv[1])==LIBRAW_SUCCESS,"Read camera matrix fixture");
    sony2fuji::CameraWhiteBalance camera(calibration.imgdata);
    for (double temperature:{2000.,50000.}) for (double tint:{-150.,150.}) {
        float gains[4]{};
        check(camera.multipliers(temperature,tint,gains),"Slider endpoints produce usable camera gains");
    }
    sony2fuji::RAWProcessor raw;
    check(raw.loadFile(argv[1])==sony2fuji::ErrorCode::Success,"Read RAW calibration");
    float temperature=0,tint=0;
    check(raw.getAsShotWhiteBalance(temperature,tint),"As-shot is derived from camera calibration");
    std::cout<<"As-shot "<<temperature<<" K / "<<tint<<'\n';
    sony2fuji_session* session=nullptr; sony2fuji_session_create(&session);
    float t=0,g=0;
    check(sony2fuji_session_get_raw_white_balance(session,&t,&g)==SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "No stale white balance before decoding");
    sony2fuji_request request{};
    request.version=SONY2FUJI_REQUEST_VERSION; request.struct_size=sizeof(request);
    request.input_type=SONY2FUJI_INPUT_RAW; request.input_path=argv[1];
    request.wb_mode=SONY2FUJI_WB_CAMERA; request.temperature=6500;
    request.brightness=request.contrast=request.saturation=1;
    request.intent=SONY2FUJI_INTENT_PREVIEW; request.size_mode=SONY2FUJI_SIZE_NATIVE;
    request.preview_long_edge=180; request.output_target=SONY2FUJI_TARGET_BUFFER;
    request.output_format=SONY2FUJI_OUTPUT_RGB8;
    auto render=[&]() {
        sony2fuji_buffer buffer{};
        const auto status=sony2fuji_process(session,&request,&buffer);
        check(status==SONY2FUJI_STATUS_OK,"White balance renders real RAW");
        std::array<double,3> sum{};
        if (status==SONY2FUJI_STATUS_OK) {
            const auto* bytes=static_cast<const unsigned char*>(buffer.data);
            for (unsigned y=0;y<buffer.height;++y) for (unsigned x=0;x<buffer.width;++x)
                for (int c=0;c<3;++c) sum[c]+=bytes[y*buffer.stride_bytes+x*3+c];
        }
        sony2fuji_release_buffer(&buffer); return sum;
    };
    const auto original=render();
    check(sony2fuji_session_get_raw_white_balance(session,&t,&g)==SONY2FUJI_STATUS_OK &&
          std::abs(t-temperature)<1 && std::abs(g-tint)<.1,"Decode preserves as-shot metadata");
    request.wb_mode=SONY2FUJI_WB_TEMPERATURE; request.temperature=temperature; request.tint=tint;
    const auto matched=render();
    for (int c=0;c<3;++c) {
        const double error=std::abs(matched[c]-original[c])/std::max(1.0,original[c]);
        const auto label =
            "Absolute as-shot WB preserves the camera output and exposure within 0.5 percent; channel " +
            std::to_string(c) + " error=" + std::to_string(error*100) + " percent";
        check(error<0.005,label.c_str());
    }
    request.wb_mode=SONY2FUJI_WB_TEMPERATURE; request.temperature=4000; request.tint=0;
    const auto cool=render(); request.temperature=8500; const auto warm=render();
    check(warm[0]/warm[2]>cool[0]/cool[2],"Absolute Kelvin increases RAW warmth");
    request.temperature=5500; request.tint=-50; const auto green=render();
    request.tint=50; const auto magenta=render();
    check(magenta[1]/(magenta[0]+magenta[2])<green[1]/(green[0]+green[2]),"Positive RAW tint adds magenta");
    request.wb_mode=SONY2FUJI_WB_CAMERA; request.temperature=6500; request.tint=0;
    check(render()==original,"As-shot reset restores exact output after custom WB and cache changes");
    request.wb_mode=SONY2FUJI_WB_TEMPERATURE; request.temperature=1000;
    sony2fuji_buffer buffer{};
    check(sony2fuji_process(session,&request,&buffer)==SONY2FUJI_STATUS_INVALID_ARGUMENT,"Invalid Kelvin is rejected");
    sony2fuji_session_set_raw_exposure_mode(session,SONY2FUJI_EXPOSURE_PREVIEW);
    request.wb_mode=SONY2FUJI_WB_CAMERA; request.temperature=6500; request.tint=0; render();
    float baseline=0,metadata=0,customBaseline=0;
    sony2fuji_session_get_raw_exposure(session,&baseline,&metadata);
    request.wb_mode=SONY2FUJI_WB_TEMPERATURE; request.temperature=8500; render();
    sony2fuji_session_get_raw_exposure(session,&customBaseline,&metadata);
    check(std::abs(baseline-customBaseline)<1e-5,"White balance leaves preview-matched exposure anchored to as-shot");
    sony2fuji_session_destroy(session);
    return failures ? 1 : 0;
}
