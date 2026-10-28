#include "sony2fuji/ffi/sony2fuji_c.h"
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

// 外部许可样片由 runner 校验；raster 输入是已定向/转换 sRGB 的紧密 RGB8。
int main(int argc,char** argv) {
    if(argc!=9) {std::cerr<<"raw|rgb input width height clarity dehaze output.png long-edge\n";return 2;}
    sony2fuji_session* session=nullptr;
    try {
        auto check=[](sony2fuji_status status) {
            if(status!=SONY2FUJI_STATUS_OK) throw std::runtime_error("native status "+std::to_string(status));
        };
        check(sony2fuji_session_create(&session));
        sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION,sizeof(gpu),SONY2FUJI_GPU_OFF};
        check(sony2fuji_session_set_gpu_config(session,&gpu));
        check(sony2fuji_session_set_processing_version(session,SONY2FUJI_PROCESSING_C5_V2));
        sony2fuji_atmosphere_config controls{SONY2FUJI_ATMOSPHERE_CONFIG_VERSION,sizeof(controls),std::stof(argv[5]),std::stof(argv[6])};
        check(sony2fuji_session_set_atmosphere(session,&controls));
        sony2fuji_request r{};r.version=SONY2FUJI_REQUEST_VERSION;r.struct_size=sizeof(r);
        std::vector<uint8_t> pixels;
        if(std::string(argv[1])=="raw") {r.input_type=SONY2FUJI_INPUT_RAW;r.input_path=argv[2];}
        else {
            std::ifstream stream(argv[2],std::ios::binary);
            pixels.assign(std::istreambuf_iterator<char>(stream),{});
            r.input_width=std::stoi(argv[3]);r.input_height=std::stoi(argv[4]);
            if(pixels.size()!=size_t(r.input_width)*r.input_height*3) throw std::runtime_error("RGB8 size mismatch");
            r.input_type=SONY2FUJI_INPUT_DISPLAY_BUFFER;r.input_pixels=pixels.data();
            r.input_pixel_format=SONY2FUJI_PIXEL_RGB8;r.input_color_space=SONY2FUJI_COLOR_SRGB;
        }
        r.wb_mode=SONY2FUJI_WB_CAMERA;r.temperature=6500;r.brightness=r.contrast=r.saturation=1;
        r.output_target=SONY2FUJI_TARGET_FILE;r.output_format=SONY2FUJI_OUTPUT_PNG;r.output_path=argv[7];
        r.intent=SONY2FUJI_INTENT_FINAL;r.size_mode=SONY2FUJI_SIZE_NATIVE;
        r.long_edge=std::stoi(argv[8]);if(r.long_edge>0) r.size_mode=SONY2FUJI_SIZE_LIMIT_LONG_EDGE;
        check(sony2fuji_process(session,&r,nullptr));
        sony2fuji_session_destroy(session);return 0;
    } catch(const std::exception& e) {sony2fuji_session_destroy(session);std::cerr<<e.what()<<'\n';return 1;}
}
