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
NetworkGraph::NetworkGraph(const ModelPackage& package, GraphKind kind, Backend requested) {
    if (requested != Backend::Cpu && requested != Backend::CoreML && requested != Backend::Auto && requested != Backend::DirectML)
        throw std::invalid_argument("invalid DualDn backend");
    const size_t index = kind == GraphKind::Raw ? 0 : kind == GraphKind::ISP ? 1 : kind == GraphKind::RGB ? 2 : kind == GraphKind::BlindRGB ? 3 :
        throw std::invalid_argument("invalid DualDn graph kind");
    const auto& onnxPath = kind == GraphKind::BlindRGB ? package.blindRGBPath : package.paths[index];
    if (onnxPath.empty()) throw std::runtime_error("Scene RGB AI model is not installed");
    if (requested != Backend::Cpu && kind != GraphKind::ISP) {
        try {
            if (preferred(requested) == Backend::DirectML)
                onnx_ = std::make_unique<OnnxGraph>(onnxPath, kind, package.tileSize, Backend::DirectML);
            else {
                const auto& path = kind == GraphKind::BlindRGB ? package.blindRGBCoreMLPath : package.coreMLPaths[kind == GraphKind::Raw ? 0 : 1];
                if (path.empty()) throw std::runtime_error("Native Core ML model is not installed");
                native_ = std::make_unique<CoreMLGraph>(path, kind, package.tileSize);
            }
            return;
        } catch (const std::runtime_error& error) {
            if (requested != Backend::Auto) throw;
            fallback_ = error.what();
        }
    }
    onnx_ = std::make_unique<OnnxGraph>(onnxPath, kind, package.tileSize);
}
std::vector<float> NetworkGraph::run(const std::vector<std::vector<float>>& inputs) {
    return native_ ? native_->run(inputs) : onnx_->run(inputs);
}
std::string NetworkGraph::runtimeVersion(Backend requested) {
    return OnnxGraph::runtimeVersion() + (requested == Backend::Cpu ? std::string() :
        ":" + (preferred(requested) == Backend::DirectML ? directMLRuntimeVersion() : CoreMLGraph::runtimeVersion()));
}
}
