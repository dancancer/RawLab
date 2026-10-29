#include <windows.h>
#include <d3d11.h>
#include <dxgi1_6.h>
#include <d3dcompiler.h>
#include <wrl/client.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <memory>
#include <vector>
using Microsoft::WRL::ComPtr;

namespace {
constexpr wchar_t windowClass[]=L"RawLabHDRSurface";
constexpr char shader[]=R"(
cbuffer Params : register(b0) { float4 rect; float4 display; float4 comparison; float4 content; };
Texture2D<float4> edited : register(t0); Texture2D<float4> original : register(t1);
SamplerState sampling : register(s0);
struct Vertex { float4 position:SV_POSITION; float2 uv:TEXCOORD0; };
Vertex vs(uint id:SV_VertexID) {
 const float2 points[6]={float2(0,0),float2(1,0),float2(0,1),float2(0,1),float2(1,0),float2(1,1)};
 Vertex v;v.uv=points[id];float2 p=rect.xy+v.uv*rect.zw;
 v.position=float4(p.x/display.x*2-1,1-p.y/display.y*2,0,1);return v;
}
float4 ps(Vertex v):SV_TARGET {
 // Rasterization converts SV_POSITION to screen pixels before this stage.
 bool before=comparison.x>1.5 || (comparison.x>.5 && v.position.x<comparison.y);
 float3 rgb=before ? original.Sample(sampling,v.uv).rgb : edited.Sample(sampling,v.uv).rgb;
 float peak=before ? content.y : content.x;
 float y=dot(rgb,float3(.2126,.7152,.0722));
 if(comparison.z>.5) {
   rgb=y>display.z ? float3(1,0,.35) : y>1 ? float3(1,.6,0) : y<=.01 ? float3(.02,.15,.7) : float3(.35,.35,.35);
 } else if(y>1 && peak>display.z) {
   float a=(peak-display.z)/((display.z-1)*(peak-1));
   rgb*= (1+(y-1)/(1+a*(y-1)))/y;
 }
 if(comparison.x>.5 && comparison.x<1.5 && abs(v.position.x-comparison.y)<1)rgb=1;
 return float4(rgb*display.w,1);
})";

struct Surface {
    HWND window=nullptr;
    HMONITOR monitor=nullptr;
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<IDXGISwapChain3> swap;
    ComPtr<ID3D11RenderTargetView> target;
    ComPtr<ID3D11VertexShader> vertex;
    ComPtr<ID3D11PixelShader> pixel;
    ComPtr<ID3D11Buffer> constants;
    ComPtr<ID3D11SamplerState> sampler;
    ComPtr<ID3D11RasterizerState> rasterizer;
    std::array<ComPtr<ID3D11ShaderResourceView>,2> images;
    std::array<float,16> parameters{};
    float headroom=1,whiteScale=1;
    unsigned generation=0,width=0,height=0;
    bool ready=false,pending=false;

    void reset() {
        ready=false;pending=false;KillTimer(window,1);ShowWindow(window,SW_HIDE);
        if(context)context->ClearState();
        images={};target.Reset();swap.Reset();vertex.Reset();pixel.Reset();constants.Reset();sampler.Reset();rasterizer.Reset();context.Reset();device.Reset();
        width=height=0;headroom=whiteScale=1;++generation;
    }
    static float referenceWhite(HMONITOR monitor) {
        MONITORINFOEXW info{};info.cbSize=sizeof(info);if(!GetMonitorInfoW(monitor,&info))return 80;
        UINT32 paths=0,modes=0;
        if(GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS,&paths,&modes)!=ERROR_SUCCESS)return 80;
        std::vector<DISPLAYCONFIG_PATH_INFO> path(paths);std::vector<DISPLAYCONFIG_MODE_INFO> mode(modes);
        if(QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS,&paths,path.data(),&modes,mode.data(),nullptr)!=ERROR_SUCCESS)return 80;
        for(unsigned i=0;i<paths;++i) {
            DISPLAYCONFIG_SOURCE_DEVICE_NAME name{};name.header.type=DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
            name.header.size=sizeof(name);name.header.adapterId=path[i].sourceInfo.adapterId;name.header.id=path[i].sourceInfo.id;
            if(DisplayConfigGetDeviceInfo(&name.header)!=ERROR_SUCCESS || wcscmp(name.viewGdiDeviceName,info.szDevice))continue;
            DISPLAYCONFIG_SDR_WHITE_LEVEL white{};white.header.type=DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL;
            white.header.size=sizeof(white);white.header.adapterId=path[i].targetInfo.adapterId;white.header.id=path[i].targetInfo.id;
            if(DisplayConfigGetDeviceInfo(&white.header)==ERROR_SUCCESS && white.SDRWhiteLevel>0)return white.SDRWhiteLevel*.08f;
        }
        return 80;
    }
    bool capabilities() {
        const auto current=MonitorFromWindow(window,MONITOR_DEFAULTTONEAREST);
        ComPtr<IDXGIFactory1> factory;if(FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))){reset();return false;}
        ComPtr<IDXGIAdapter1> selected;DXGI_OUTPUT_DESC1 output{};
        for(unsigned a=0;!selected;++a) {
            ComPtr<IDXGIAdapter1> adapter;if(factory->EnumAdapters1(a,&adapter)==DXGI_ERROR_NOT_FOUND)break;
            DXGI_ADAPTER_DESC1 description{};if(FAILED(adapter->GetDesc1(&description)) || description.Flags&DXGI_ADAPTER_FLAG_SOFTWARE)continue;
            for(unsigned o=0;;++o) {
                ComPtr<IDXGIOutput> item;if(adapter->EnumOutputs(o,&item)==DXGI_ERROR_NOT_FOUND)break;
                ComPtr<IDXGIOutput6> advanced;DXGI_OUTPUT_DESC1 desc{};
                if(SUCCEEDED(item.As(&advanced)) && SUCCEEDED(advanced->GetDesc1(&desc)) && desc.Monitor==current &&
                    desc.ColorSpace==DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020 && std::isfinite(desc.MaxLuminance) && desc.MaxLuminance>80) {
                    selected=adapter;output=desc;break;
                }
            }
        }
        if(!selected){if(ready)reset();return false;}
        if(current!=monitor){reset();monitor=current;}
        const float white=referenceWhite(current);
        headroom=std::clamp(output.MaxLuminance/white,1.0f,65504.0f);whiteScale=white/80;
        if(headroom<=1){reset();return false;}
        if(ready)return true;
        if(FAILED(D3D11CreateDevice(selected.Get(),D3D_DRIVER_TYPE_UNKNOWN,nullptr,0,nullptr,0,D3D11_SDK_VERSION,&device,nullptr,&context))){reset();return false;}
        UINT support=0;if(FAILED(device->CheckFormatSupport(DXGI_FORMAT_R16G16B16A16_FLOAT,&support)) ||
            !(support&D3D11_FORMAT_SUPPORT_RENDER_TARGET)){reset();return false;}
        ComPtr<IDXGIFactory2> factory2;if(FAILED(factory.As(&factory2))){reset();return false;}
        DXGI_SWAP_CHAIN_DESC1 desc{};desc.Width=desc.Height=1;desc.Format=DXGI_FORMAT_R16G16B16A16_FLOAT;
        desc.SampleDesc.Count=1;desc.BufferUsage=DXGI_USAGE_RENDER_TARGET_OUTPUT;desc.BufferCount=2;
        desc.SwapEffect=DXGI_SWAP_EFFECT_FLIP_DISCARD;desc.Scaling=DXGI_SCALING_STRETCH;desc.AlphaMode=DXGI_ALPHA_MODE_IGNORE;
        ComPtr<IDXGISwapChain1> chain;
        if(FAILED(factory2->CreateSwapChainForHwnd(device.Get(),window,&desc,nullptr,nullptr,&chain)) || FAILED(chain.As(&swap))){reset();return false;}
        factory->MakeWindowAssociation(window,DXGI_MWA_NO_ALT_ENTER);
        UINT flags=0;if(FAILED(swap->CheckColorSpaceSupport(DXGI_COLOR_SPACE_RGB_FULL_G10_NONE_P709,&flags)) ||
            !(flags&DXGI_SWAP_CHAIN_COLOR_SPACE_SUPPORT_FLAG_PRESENT) || FAILED(swap->SetColorSpace1(DXGI_COLOR_SPACE_RGB_FULL_G10_NONE_P709))){reset();return false;}
        if(!pipeline())return false;
        ready=true;++generation;return true;
    }
    bool pipeline() {
        ComPtr<ID3DBlob> vs,ps,error;
        if(FAILED(D3DCompile(shader,sizeof(shader)-1,nullptr,nullptr,nullptr,"vs","vs_5_0",D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&vs,&error)) ||
            FAILED(D3DCompile(shader,sizeof(shader)-1,nullptr,nullptr,nullptr,"ps","ps_5_0",D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&ps,&error)) ||
            FAILED(device->CreateVertexShader(vs->GetBufferPointer(),vs->GetBufferSize(),nullptr,&vertex)) ||
            FAILED(device->CreatePixelShader(ps->GetBufferPointer(),ps->GetBufferSize(),nullptr,&pixel))){reset();return false;}
        D3D11_BUFFER_DESC buffer{};buffer.ByteWidth=64;buffer.Usage=D3D11_USAGE_DEFAULT;buffer.BindFlags=D3D11_BIND_CONSTANT_BUFFER;
        D3D11_SAMPLER_DESC sample{};sample.Filter=D3D11_FILTER_MIN_MAG_LINEAR_MIP_POINT;sample.AddressU=sample.AddressV=sample.AddressW=D3D11_TEXTURE_ADDRESS_CLAMP;sample.MaxLOD=D3D11_FLOAT32_MAX;
        D3D11_RASTERIZER_DESC raster{};raster.FillMode=D3D11_FILL_SOLID;raster.CullMode=D3D11_CULL_NONE;raster.DepthClipEnable=TRUE;
        if(FAILED(device->CreateBuffer(&buffer,nullptr,&constants)) || FAILED(device->CreateSamplerState(&sample,&sampler)) ||
            FAILED(device->CreateRasterizerState(&raster,&rasterizer))){reset();return false;}
        return true;
    }
    bool upload(int index,const float* rgb,unsigned w,unsigned h) {
        if(!ready || index<0 || index>1 || !rgb || !w || !h || uint64_t(w)*h>16000000)return false;
        std::vector<float> rgba(size_t(w)*h*4);
        for(size_t i=0;i<size_t(w)*h;++i) {
            for(int c=0;c<3;++c){const float value=rgb[i*3+c];if(!std::isfinite(value) || std::abs(value*whiteScale)>65504)return false;rgba[i*4+c]=value;}
            rgba[i*4+3]=1;
        }
        D3D11_TEXTURE2D_DESC desc{};desc.Width=w;desc.Height=h;desc.MipLevels=desc.ArraySize=1;desc.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;
        desc.SampleDesc.Count=1;desc.Usage=D3D11_USAGE_IMMUTABLE;desc.BindFlags=D3D11_BIND_SHADER_RESOURCE;
        D3D11_SUBRESOURCE_DATA data{rgba.data(),w*16,0};ComPtr<ID3D11Texture2D> texture;
        return SUCCEEDED(device->CreateTexture2D(&desc,&data,&texture)) && SUCCEEDED(device->CreateShaderResourceView(texture.Get(),nullptr,&images[index]));
    }
    void render() {
        parameters[4]=float(width);parameters[5]=float(height);parameters[6]=headroom;parameters[7]=whiteScale;
        context->UpdateSubresource(constants.Get(),0,nullptr,parameters.data(),0,0);
        ID3D11Buffer* buffers[]={constants.Get()};context->VSSetConstantBuffers(0,1,buffers);context->PSSetConstantBuffers(0,1,buffers);
        context->VSSetShader(vertex.Get(),nullptr,0);context->PSSetShader(pixel.Get(),nullptr,0);
        ID3D11ShaderResourceView* sources[]={images[0].Get(),images[1].Get()};context->PSSetShaderResources(0,2,sources);
        ID3D11SamplerState* samples[]={sampler.Get()};context->PSSetSamplers(0,1,samples);
        ID3D11RenderTargetView* targets[]={target.Get()};context->OMSetRenderTargets(1,targets,nullptr);
        const float clear[]={0,0,0,1};context->ClearRenderTargetView(target.Get(),clear);
        D3D11_VIEWPORT viewport{0,0,float(width),float(height),0,1};context->RSSetViewports(1,&viewport);context->RSSetState(rasterizer.Get());
        context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);context->Draw(6,0);
    }
    bool draw() {
        if(!ready || !images[0] || !images[1])return false;
        RECT bounds{};GetClientRect(window,&bounds);const unsigned w=std::max(1L,bounds.right),h=std::max(1L,bounds.bottom);
        if(w!=width || h!=height) {
            context->OMSetRenderTargets(0,nullptr,nullptr);target.Reset();
            if(FAILED(swap->ResizeBuffers(0,w,h,DXGI_FORMAT_UNKNOWN,0))){reset();return false;}
            ComPtr<ID3D11Texture2D> back;if(FAILED(swap->GetBuffer(0,IID_PPV_ARGS(&back))) || FAILED(device->CreateRenderTargetView(back.Get(),nullptr,&target))){reset();return false;}
            width=w;height=h;
        }
        render();
        const auto result=swap->Present(0,DXGI_PRESENT_DO_NOT_WAIT);
        if(result==DXGI_ERROR_WAS_STILL_DRAWING){pending=true;SetTimer(window,1,16,nullptr);return true;}
        pending=false;KillTimer(window,1);
        if(FAILED(result)){reset();return false;}
        ShowWindow(window,SW_SHOWNOACTIVATE);return true;
    }
};
Surface* surface(HWND window){return reinterpret_cast<Surface*>(GetWindowLongPtrW(window,GWLP_USERDATA));}
LRESULT CALLBACK procedure(HWND window,UINT message,WPARAM w,LPARAM l) {
    if(message==WM_NCCREATE){auto* value=static_cast<Surface*>(reinterpret_cast<CREATESTRUCTW*>(l)->lpCreateParams);value->window=window;SetWindowLongPtrW(window,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(value));}
    if(message==WM_NCHITTEST)return HTTRANSPARENT;
    if(message==WM_ERASEBKGND)return 1;
    if(message==WM_SIZE){if(auto* value=surface(window))value->draw();}
    if(message==WM_TIMER && w==1){if(auto* value=surface(window))value->draw();return 0;}
    return DefWindowProcW(window,message,w,l);
}
}
#define API extern "C" __declspec(dllexport)
API HWND rawlab_hdr_create(HWND parent) noexcept {
    try {
        WNDCLASSW type{};type.lpfnWndProc=procedure;type.hInstance=GetModuleHandleW(nullptr);type.lpszClassName=windowClass;
        RegisterClassW(&type);auto value=std::make_unique<Surface>();
        const auto window=CreateWindowExW(WS_EX_NOACTIVATE,windowClass,L"",WS_CHILD|WS_CLIPSIBLINGS,0,0,1,1,parent,nullptr,type.hInstance,value.get());
        if(window)value.release();return window;
    }catch(...){return nullptr;}
}
API void rawlab_hdr_destroy(HWND window) noexcept {auto* value=surface(window);if(value){value->reset();DestroyWindow(window);delete value;}}
API int rawlab_hdr_capabilities(HWND window,float* values) noexcept {
    try {auto* value=surface(window);if(!value || !values)return 0;const bool available=value->capabilities();values[0]=value->headroom;values[1]=value->whiteScale;values[2]=float(value->generation);return available ? 1 : 0;}
    catch(...){if(auto* value=surface(window))value->reset();return 0;}
}
API int rawlab_hdr_upload(HWND window,int index,const float* rgb,unsigned width,unsigned height) noexcept {
    try {auto* value=surface(window);return value && value->upload(index,rgb,width,height) ? 1 : 0;}catch(...){return 0;}
}
API int rawlab_hdr_present(HWND window,const float* parameters,const RECT* exclusions,int count) noexcept {
    try {
        auto* value=surface(window);if(!value || !parameters || count<0 || count>32)return 0;
        std::copy_n(parameters,16,value->parameters.begin());
        for(float p:value->parameters)if(!std::isfinite(p))return 0;
        const auto* p=parameters;HRGN region=CreateRectRgn(int(std::floor(p[0])),int(std::floor(p[1])),int(std::ceil(p[0]+p[2])),int(std::ceil(p[1]+p[3])));
        for(int i=0;i<count;++i){HRGN hole=CreateRectRgnIndirect(exclusions+i);CombineRgn(region,region,hole,RGN_DIFF);DeleteObject(hole);}
        if(!SetWindowRgn(window,region,TRUE))DeleteObject(region);
        return value->draw() ? 1 : 0;
    }catch(...){if(auto* value=surface(window))value->reset();return 0;}
}
API void rawlab_hdr_hide(HWND window) noexcept {if(auto* value=surface(window)){KillTimer(window,1);value->pending=false;ShowWindow(window,SW_HIDE);}}
