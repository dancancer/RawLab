#pragma once
#include "coreml_graph.h"
#include "model_package.h"

namespace sony2fuji::ai {
class NetworkGraph {
public:
    NetworkGraph(const ModelPackage& package, GraphKind kind, Backend requested, AIExecution execution = {});
    std::vector<float> run(const std::vector<std::vector<float>>& inputs);
    std::string backend() const { return native_ ? "CoreML" : onnx_->backend(); }
    std::string fallbackReason() const { return fallback_; }
    static std::string runtimeVersion(Backend requested, const DirectMLAdapter* device = nullptr);
private:
    std::unique_ptr<CoreMLGraph> native_;
    std::unique_ptr<OnnxGraph> onnx_;
    std::string fallback_;
};
}
