#include "sony2fuji/sony2fuji.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#include "core/photo_rendering.h"
#include <cmath>
#include <iostream>
#include <libraw/libraw.h>
#include <algorithm>
#include <filesystem>
#include <limits>
#include <memory>
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_JPEG
#define STBI_NO_STDIO
#include "core/stb_image.h"
using namespace sony2fuji;

float medianLuminance(const ImageData& image) {
    std::vector<float> values;
    for (int y=0;y<128;++y) for (int x=0;x<128;++x) {
        const auto p=image.at((2*x+1)*image.width/256,(2*y+1)*image.height/256);
        values.push_back(.2126f*p.r+.7152f*p.g+.0722f*p.b);
    }
    std::sort(values.begin(),values.end());
    return values[values.size()/2];
}

ImageData embeddedPreview(LibRaw& raw) {
    if (raw.unpack_thumb()!=LIBRAW_SUCCESS) return {};
    auto* thumb=raw.dcraw_make_mem_thumb();
    if (!thumb) return {};
    int w=thumb->width,h=thumb->height,n=thumb->colors;
    unsigned char* decoded=nullptr;
    const auto* bytes=thumb->data;
    if (thumb->type==LIBRAW_IMAGE_JPEG) {
        decoded=stbi_load_from_memory(bytes,thumb->data_size,&w,&h,&n,3);
        bytes=decoded; n=3;
    }
    ImageData image;
    if (bytes && w>0 && h>0 && n==3) {
        image=ImageData(w,h);
        auto linear=[](unsigned char b) {
            const float v=b/255.0f;
            return v<=.04045f ? v/12.92f : std::pow((v+.055f)/1.055f,2.4f);
        };
        for (size_t i=0;i<image.pixels.size();++i)
            image.pixels[i]=RGB(linear(bytes[3*i]),linear(bytes[3*i+1]),linear(bytes[3*i+2]));
    }
    stbi_image_free(decoded);
    LibRaw::dcraw_clear_mem(thumb);
    return image;
}

void saveProof(const ImageData& image, const std::filesystem::path& path, bool scene=true) {
    const int w=std::min(1200,image.width),h=image.height*w/image.width;
    ImageData display(w,h);
    for (int y=0;y<h;++y) for (int x=0;x<w;++x) {
        const auto p=image.at(x*image.width/w,y*image.height/h);
        auto encode=[scene](float v) { return scene ? neutralDisplay(v) : GammaConverter::applySRGBGamma(std::clamp(v,0.0f,1.0f)); };
        display.at(x,y)=RGB(encode(p.r),encode(p.g),encode(p.b));
    }
    if (ImageEncoder::saveJPEG(display,path.string())!=ErrorCode::Success)
        throw std::runtime_error("Could not write exposure proof");
}

int main(int argc, char** argv) {
    if (argc != 2 && argc != 4) return 2;
    auto metadataOwner = std::make_unique<LibRaw>();
    auto& metadata = *metadataOwner;
    metadata.imgdata.params.use_camera_wb=1;
    metadata.imgdata.params.use_camera_matrix=1;
    metadata.open_file(argv[1]);
    for (const auto& crop : metadata.imgdata.sizes.raw_inset_crops)
        std::cout << "inset " << crop.cleft << ',' << crop.ctop << ' ' << crop.cwidth << 'x' << crop.cheight << '\n';
    RAWProcessor raw;
    if (raw.loadFile(argv[1]) != ErrorCode::Success) return 1;
    RAWProcessOptions options;
    ImageData base, eight, exposed;
    if (raw.process(options, base) != ErrorCode::Success) return 1;
    const float baselineEV=raw.getBaselineExposureEV();
    const float tag=metadata.imgdata.color.dng_levels.baseline_exposure;
    const float expectedMetadata=std::isfinite(tag) && std::abs(tag)<=8 ? tag : 0;
    if (raw.getPreviewExposureEV()!=0 || std::abs(baselineEV-(.7f+expectedMetadata))>1e-5) {
        std::cerr << "Default RAW exposure is not metadata-based\n"; return 1;
    }
    {
        auto referenceOwner = std::make_unique<LibRaw>();
        auto& reference = *referenceOwner;
        auto& p=reference.imgdata.params;
        p.use_camera_wb=1; p.use_camera_matrix=1; p.output_color=0;
        p.no_auto_bright=1; p.no_auto_scale=0; p.adjust_maximum_thr=0; p.highlight=2;
        p.gamm[0]=p.gamm[1]=1;
        if (reference.open_file(argv[1]) || reference.unpack()) return 1;
        if (reference.error_count() != 0) {
            std::cerr << "RAW decoder reported corrupt data despite successful unpack\n";
            return 1;
        }
        reference.adjust_to_raw_inset_crop(3);
        if (reference.dcraw_process()) return 1;
        const auto& ref=reference.imgdata;
        std::cout << "Reference " << ref.sizes.iwidth << 'x' << ref.sizes.iheight
                  << "; flip=" << ref.sizes.flip << "; output=" << base.width << 'x' << base.height << '\n';
        const float scale=std::exp2(baselineEV)/(65535*ref.color.pre_mul[1]);
        double error=0; size_t count=0;
        for (size_t i=0;i<base.pixels.size();i+=127) {
            // Output is oriented; LibRaw image storage remains in sensor order.
            int row=static_cast<int>(i/base.width), col=static_cast<int>(i%base.width);
            if (ref.sizes.flip & 4) std::swap(row,col);
            if (ref.sizes.flip & 2) row=ref.sizes.iheight-1-row;
            if (ref.sizes.flip & 1) col=ref.sizes.iwidth-1-col;
            const size_t sourceIndex=static_cast<size_t>(row)*ref.sizes.iwidth+col;
            float rgb[3]={};
            for (int d=0;d<3;++d) for (int c=0;c<ref.idata.colors;++c)
                rgb[d]+=ref.color.rgb_cam[d][c]*ref.image[sourceIndex][c]*scale;
            error+=std::abs(base.pixels[i].r-rgb[0])+std::abs(base.pixels[i].g-rgb[1])+std::abs(base.pixels[i].b-rgb[2]);
            count+=3;
        }
        std::cout << "LibRaw WB-before-demosaic mean error=" << error/count << '\n';
        if (error/count>1e-5) { std::cerr << "RAW differs from standard WB-before-demosaic reference\n"; return 1; }
    }
    const auto preview=embeddedPreview(metadata);
    if (preview.pixels.empty()) { std::cerr << "Fixture preview missing\n"; return 1; }
    std::cout << "Preview " << preview.width << 'x' << preview.height
              << "; DNG preview color space=" << metadata.imgdata.color.dng_levels.preview_colorspace << '\n';
    const float previewMedian=medianLuminance(preview), rawMedian=medianLuminance(base);
    const float mismatch=std::log2(rawMedian/previewMedian);
    std::cout << "Embedded preview median=" << previewMedian << "; RAW median=" << rawMedian
              << "; exposure difference=" << mismatch << " EV; baseline=" << baselineEV << " EV\n";
    const float xyz[3][3]={{.4124564f,.3575761f,.1804375f},{.2126729f,.7151522f,.0721750f},{.0193339f,.1191920f,.9503041f}};
    float camera[3][3];
    if (!raw.getCameraColorMatrix(camera)) return 1;
    for (int r=0;r<3;++r) for (int c=0;c<3;++c) {
        float expected=0;
        for (int k=0;k<3;++k) expected+=xyz[r][k]*metadata.imgdata.color.rgb_cam[k][c];
        if (std::abs(expected-camera[r][c])>1e-5) { std::cerr << "Camera XYZ matrix direction mismatch\n"; return 1; }
    }
    if (argc == 4 && (base.width != std::stoi(argv[2]) || base.height != std::stoi(argv[3]))) {
        std::cerr << "Active area mismatch: " << base.width << 'x' << base.height << '\n'; return 1;
    }
    options.outputBitsPerSample = 8;
    if (raw.process(options, eight) != ErrorCode::Success) return 1;
    options.outputBitsPerSample = 16;
    options.exposure = 1;
    if (raw.process(options, exposed) != ErrorCode::Success) return 1;
    if (std::abs(raw.getBaselineExposureEV()-baselineEV)>1e-6) {
        std::cerr << "User exposure changed the scene baseline\n"; return 1;
    }
    if (base.pixels.size() != eight.pixels.size() || base.pixels.size() != exposed.pixels.size()) {
        std::cerr << "Repeated RAW processing changed image dimensions\n"; return 1;
    }
    float maximum = 0;
    for (size_t i=0; i<base.pixels.size(); ++i) {
        const auto a=base.pixels[i], b=eight.pixels[i], c=exposed.pixels[i];
        for (auto v : {a.r,a.g,a.b,c.r,c.g,c.b}) if (!std::isfinite(v)) {
            std::cerr << "Non-finite RAW pixel at " << i << '\n'; return 1;
        }
        if (std::abs(a.r-b.r)>1e-6 || std::abs(a.g-b.g)>1e-6 || std::abs(a.b-b.b)>1e-6) {
            std::cerr << "Repeated 8/16-bit RAW mismatch at " << i << ": "
                      << a.r-b.r << ',' << a.g-b.g << ',' << a.b-b.b << '\n'; return 1;
        }
        if (std::abs(2*a.r-c.r)>1e-5 || std::abs(2*a.g-c.g)>1e-5 || std::abs(2*a.b-c.b)>1e-5) {
            std::cerr << "RAW exposure linearity mismatch at " << i << ": "
                      << 2*a.r-c.r << ',' << 2*a.g-c.g << ',' << 2*a.b-c.b << '\n'; return 1;
        }
        maximum=std::max(maximum,std::max(c.r,std::max(c.g,c.b)));
    }
    if (maximum <= 0) { std::cerr << "Empty RAW signal\n"; return 1; }
    options.exposure=0;
    options.matchEmbeddedPreviewExposure=false;
    options.applyBaselineExposure=false;
    if (raw.process(options,eight)!=ErrorCode::Success || raw.getBaselineExposureEV()!=0) return 1;
    const float gain=std::exp2(baselineEV);
    for (size_t i=0;i<base.pixels.size();i+=101) {
        const auto a=base.pixels[i],b=eight.pixels[i];
        if (std::abs(a.r-b.r*gain)>1e-5 || std::abs(a.g-b.g*gain)>1e-5 || std::abs(a.b-b.b*gain)>1e-5) {
            std::cerr << "Scene baseline is not a single linear gain\n"; return 1;
        }
    }
    if (const auto* root=std::getenv("RAWTOOLS_TEST_ARTIFACTS")) {
        auto dir=std::filesystem::path(root)/std::filesystem::path(argv[1]).stem();
        std::filesystem::create_directories(dir);
        saveProof(eight,dir/"before.jpg");
        saveProof(base,dir/"after.jpg");
        saveProof(preview,dir/"embedded.jpg",false);
    }
    options.matchEmbeddedPreviewExposure=true;
    options.applyBaselineExposure=true;
    if (raw.process(options,exposed)!=ErrorCode::Success ||
        std::abs(std::log2(medianLuminance(exposed)/previewMedian))>.15f) {
        std::cerr << "Optional embedded preview matching failed\n"; return 1;
    }
    options.matchEmbeddedPreviewExposure=false;
    options.exposure=20;
    options.brightness=std::numeric_limits<float>::max();
    if (raw.process(options,eight)!=ErrorCode::InvalidFormat) {
        std::cerr << "Overflowing exposure gain accepted\n"; return 1;
    }
    sony2fuji_session* session=nullptr;
    sony2fuji_session_create(&session);
    sony2fuji_request r{};
    r.version=SONY2FUJI_REQUEST_VERSION; r.struct_size=sizeof(r);
    r.brightness=r.contrast=r.saturation=1; r.temperature=6500;
    r.input_type=SONY2FUJI_INPUT_RAW; r.input_path=argv[1];
    r.output_target=SONY2FUJI_TARGET_FILE; r.output_format=SONY2FUJI_OUTPUT_JPEG; r.output_path=argv[1];
    auto status=sony2fuji_process(session,&r,nullptr);
    sony2fuji_session_destroy(session);
    if (status!=SONY2FUJI_STATUS_INVALID_ARGUMENT) return 1;
    std::cout << raw.getCameraMake() << ' ' << raw.getCameraModel() << ' ' << base.width << 'x' << base.height
              << " float max(+1EV)=" << maximum << "; 8/16 safe; exposure linear; source protected\n";
}
