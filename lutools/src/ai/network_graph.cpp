#include "network_graph.h"
#include "directml_device.h"
#include <stdexcept>

namespace sony2fuji::ai {
namespace {
Backend preferred(Backend requested) {
    if (requested != Backend::Auto) return requested;
#ifdef _WIN32
    return Backend::DirectML;
#else
    return Backend::CoreML;
#endif
}
}
NetworkGraph::NetworkGraph(const ModelPackage& package, GraphKind kind, Backend requested, AIExecution execution) {
    if (requested != Backend::CoreML && requested != Backend::Auto && requested != Backend::DirectML)
        throw std::invalid_argument("CPU AI denoising is not supported; a hardware GPU is required");
    const size_t index = kind == GraphKind::Raw ? 0 : kind == GraphKind::ISP ? 1 : kind == GraphKind::RGB ? 2 : kind == GraphKind::BlindRGB ? 3 :
        throw std::invalid_argument("invalid DualDn graph kind");
    const auto& onnxPath = kind == GraphKind::BlindRGB ? package.blindRGBPath : package.paths[index];
    if (onnxPath.empty()) throw std::runtime_error("Scene RGB AI model is not installed");
    // 官方 ISP 是确定性的预处理，神经网络仅允许平台 GPU，不提供 CPU 推理或回退。
    if (kind == GraphKind::ISP) {
        onnx_ = std::make_unique<OnnxGraph>(onnxPath, kind, package.tileSize, Backend::Cpu, execution);
    } else if (preferred(requested) == Backend::DirectML) {
        onnx_ = std::make_unique<OnnxGraph>(onnxPath, kind, package.tileSize, Backend::DirectML, execution);
    } else {
        const auto& path = kind == GraphKind::BlindRGB ? package.blindRGBCoreMLPath : package.coreMLPaths[kind == GraphKind::Raw ? 0 : 1];
        if (path.empty()) throw std::runtime_error("Native Core ML model is not installed");
        native_ = std::make_unique<CoreMLGraph>(path, kind, package.tileSize);
    }
}
std::vector<float> NetworkGraph::run(const std::vector<std::vector<float>>& inputs) {
    return native_ ? native_->run(inputs) : onnx_->run(inputs);
}
std::string NetworkGraph::runtimeVersion(Backend requested, const DirectMLAdapter* device) {
    return "gpu-only-v1:" + OnnxGraph::runtimeVersion() + (requested == Backend::Cpu ? std::string() :
        ":" + (preferred(requested) == Backend::DirectML ? directMLRuntimeVersion(device) : CoreMLGraph::runtimeVersion()));
}
}
