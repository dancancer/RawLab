#include "ai/network_graph.h"
#include "ai/directml_device.h"
#include <iostream>

// 外部推理引擎在此只提供确定的 GPU 不可用故障，测试真实 NetworkGraph 的准入和回退行为。
namespace sony2fuji::ai {
struct OnnxGraph::Impl { Backend backend; };
OnnxGraph::OnnxGraph(const std::string&, GraphKind, int, Backend backend, AIExecution) : impl_(std::make_unique<Impl>()) {
    if (backend == Backend::DirectML) throw std::runtime_error("GPU unavailable");
    impl_->backend = backend;
}
OnnxGraph::~OnnxGraph() = default;
std::string OnnxGraph::backend() const { return "CPU"; }
std::string OnnxGraph::runtimeVersion() { return "test-ort"; }
std::vector<float> OnnxGraph::run(const std::vector<std::vector<float>>&) { return {}; }
struct CoreMLGraph::Impl {};
CoreMLGraph::CoreMLGraph(const std::string&, GraphKind, int) { throw std::runtime_error("GPU unavailable"); }
CoreMLGraph::~CoreMLGraph() = default;
bool CoreMLGraph::available() { return false; }
std::string CoreMLGraph::runtimeVersion() { return "test-coreml"; }
std::vector<float> CoreMLGraph::run(const std::vector<std::vector<float>>&) { return {}; }
std::string directMLRuntimeVersion(const DirectMLAdapter*) { return "test-directml"; }
}
int main() {
    using namespace sony2fuji::ai;
    try {
        ModelPackage package; package.tileSize = 640;
        package.paths = {"raw.onnx", "isp.onnx", "rgb.onnx"};
        package.coreMLPaths = {"raw.mlmodelc", "rgb.mlmodelc"};
        package.blindRGBPath = "blind_rgb.onnx"; package.blindRGBCoreMLPath = "blind_rgb.mlmodelc";
        for (auto kind : {GraphKind::Raw, GraphKind::RGB, GraphKind::BlindRGB}) {
            bool unavailable = false;
            try { NetworkGraph graph(package, kind, Backend::Auto); }
            catch (const std::runtime_error& error) { unavailable = std::string(error.what()) == "GPU unavailable"; }
            if (!unavailable) throw std::runtime_error("Auto AI silently accepted CPU after GPU failure");
            bool rejected = false;
            try { NetworkGraph graph(package, kind, Backend::Cpu); }
            catch (const std::invalid_argument&) { rejected = true; }
            if (!rejected) throw std::runtime_error("CPU neural inference mode was accepted");
        }
        std::cout << "PASS GPU-only admission and GPU failure propagation\n";
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
