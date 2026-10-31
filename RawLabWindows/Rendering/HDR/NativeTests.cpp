#include "Native.cpp"
#include "core/hdr_half.h"
#include <iostream>
#include <stdexcept>

int main() {
    try {
        Surface value;
        if(FAILED(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_WARP,nullptr,0,nullptr,0,D3D11_SDK_VERSION,&value.device,nullptr,&value.context)))return 77;
        if(!value.pipeline())throw std::runtime_error("HDR shaders failed to compile");
        value.ready=true;value.width=64;value.height=32;value.headroom=2;value.whiteScale=1;
        D3D11_TEXTURE2D_DESC desc{};desc.Width=value.width;desc.Height=value.height;desc.MipLevels=desc.ArraySize=1;
        desc.Format=DXGI_FORMAT_R16G16B16A16_FLOAT;desc.SampleDesc.Count=1;desc.BindFlags=D3D11_BIND_RENDER_TARGET;
        ComPtr<ID3D11Texture2D> target;
        if(FAILED(value.device->CreateTexture2D(&desc,nullptr,&target)) || FAILED(value.device->CreateRenderTargetView(target.Get(),nullptr,&value.target)))throw std::runtime_error("Cannot create FP16 test target");
        desc.BindFlags=0;desc.Usage=D3D11_USAGE_STAGING;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
        ComPtr<ID3D11Texture2D> staging;if(FAILED(value.device->CreateTexture2D(&desc,nullptr,&staging)))throw std::runtime_error("Cannot create test readback");
        float edited[]={4,4,4},reference[]={.25f,.25f,.25f};
        if(!value.upload(0,edited,1,1) || !value.upload(1,reference,1,1))throw std::runtime_error("Cannot upload float textures");
        value.parameters={0,0,64,32,64,32,2,1,0,32,0,0,4,4,0,0};
        auto pixel=[&](int x,int channel) {
            value.render();value.context->CopyResource(staging.Get(),target.Get());D3D11_MAPPED_SUBRESOURCE mapped{};
            if(FAILED(value.context->Map(staging.Get(),0,D3D11_MAP_READ,0,&mapped)))throw std::runtime_error("Cannot read shader output");
            auto* samples=reinterpret_cast<const uint16_t*>(static_cast<const uint8_t*>(mapped.pData)+16*mapped.RowPitch);
            const float result=sony2fuji::hdr::halfToFloat(samples[x*4+channel]);value.context->Unmap(staging.Get(),0);return result;
        };
        auto equal=[](float actual,float expected) {if(std::abs(actual-expected)>.003f)throw std::runtime_error("HDR display pixel differs");};
        equal(pixel(48,0),2);
        value.parameters[8]=1;equal(pixel(12,0),.25f);equal(pixel(48,0),2);
        value.parameters[8]=2;equal(pixel(48,0),.25f);
        value.parameters[8]=0;value.parameters[10]=1;equal(pixel(48,0),1);equal(pixel(48,1),0);equal(pixel(48,2),.35f);
        value.parameters[10]=0;value.whiteScale=2;equal(pixel(48,0),4);
        edited[0]=NAN;if(value.upload(0,edited,1,1))throw std::runtime_error("Nonfinite display upload admitted");
        std::cout<<"PASS: FP16 scRGB shader shoulder, screen-pixel wipe, before, false color and reference white (WARP only)\n";
        return 0;
    }catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}
}
