#include "gpu/d3d11_photo.h"
#include "gpu/compute_denoise.h"
#include "core/processing_cancellation.h"
#include "d3d11_test_hooks.h"
#undef RGB
#include <dxgi.h>
#include <cmath>
#include <iostream>
#include <string>

using namespace sony2fuji;
namespace {
void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
sony2fuji_request request() {
    sony2fuji_request r{};
    r.intent = SONY2FUJI_INTENT_PREVIEW;
    r.brightness = r.contrast = r.saturation = 1;
    return r;
}
bool render(D3D11PhotoRenderer& renderer, ImageData& output) {
    ImageData input(17, 19);
    for (auto& p : input.pixels) p = RGB(.2f, .3f, .4f);
    return renderer.render(input, ColorSpace::sRGB, request(), {}, RGB(1, 1, 1), 17, 19, 0, output);
}
void recovery() {
    D3D11PhotoRenderer renderer;
    ImageData output(1, 1);
    output.pixels[0] = RGB(7, 8, 9);
    d3d11_test::initializationFailures = 2;
    require(!render(renderer, output), "injected initialization must fail");
    require(!render(renderer, output), "cooldown must fail without rebuilding");
    require(d3d11_test::photoInitializations == 1, "C7: immediate retry rebuilt the failed renderer");
    require(output.width == 1 && output.pixels[0].r == 7, "failed render published output");
    d3d11_test::now += std::chrono::milliseconds(100);
    require(!render(renderer, output), "second initialization must fail");
    d3d11_test::now += std::chrono::milliseconds(100);
    require(!render(renderer, output), "second cooldown must double");
    require(d3d11_test::photoInitializations == 2, "C7: exponential cooldown was not retained");
    d3d11_test::now += std::chrono::milliseconds(100);
    require(render(renderer, output), "renderer did not recover after cooldown");
    require(d3d11_test::photoInitializations == 3, "recovery did not rebuild exactly once");
    d3d11_test::deviceStatus = DXGI_ERROR_DEVICE_REMOVED;
    require(!render(renderer, output), "removed device must fail");
    d3d11_test::deviceStatus = S_OK;
    require(!render(renderer, output), "removed device must enter cooldown");
    require(d3d11_test::photoInitializations == 3, "device loss caused an immediate rebuild");
    d3d11_test::now += std::chrono::milliseconds(100);
    require(render(renderer, output), "successful render did not reset the failure streak");
    const int before = d3d11_test::photoInitializations;
    try {
        ProcessingCancellationScope scope({[](void*) -> int32_t { return 1; }, nullptr});
        render(renderer, output);
        require(false, "cancellation was swallowed");
    } catch (const ProcessingCancelled&) {}
    require(render(renderer, output), "cancellation incorrectly entered cooldown");
    require(d3d11_test::photoInitializations == before, "cancellation discarded the healthy device");
    ImageData input(17, 19);
    require(!renderer.render(input, ColorSpace::SonyNative, request(), {}, {1, 1, 1}, 17, 19, 0, output),
        "unsupported color conversion must fail");
    require(render(renderer, output), "non-device failure entered cooldown");
    require(d3d11_test::photoInitializations == before, "non-device failure discarded a healthy device");
}
void filterRecovery() {
    ImageData input(17, 19);
    d3d11_test::initializationFailures = 2;
    require(!gpuDetailFilter(input, .2f, 0), "filter initialization must fail");
    require(!gpuDetailFilter(input, .2f, 0), "filter cooldown must fail");
    require(d3d11_test::filterInitializations == 1, "C7: shared filters rebuilt without cooldown");
    d3d11_test::now += std::chrono::milliseconds(100);
    require(!gpuDetailFilter(input, .2f, 0), "second filter initialization must fail");
    d3d11_test::now += std::chrono::milliseconds(100);
    require(!gpuDetailFilter(input, .2f, 0), "filter cooldown must double");
    require(d3d11_test::filterInitializations == 2, "filter failure count did not survive device teardown");
    d3d11_test::now += std::chrono::milliseconds(100);
    require(gpuDetailFilter(input, .2f, 0), "shared filter did not recover");
}
}
int main(int argc, char** argv) {
    try {
        require(argc == 2, "expected a test case");
        const std::string name = argv[1];
        if (name == "recovery") recovery();
        else if (name == "filter-recovery") filterRecovery();
        else require(false, "unknown test case");
        std::cout << "PASS: D3D11 " << argv[1] << " (WARP software adapter; no hardware GPU claim)\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
