#pragma once
#include "onnx_graph.h"

namespace sony2fuji::ai {
// RAW/RGB 原生 float32 MLProgram。Core ML 可调度 CPU/GPU；ISP 不经过此类。
class CoreMLGraph {
public:
    CoreMLGraph(const std::string& compiledPath, GraphKind kind, int tileSize);
    ~CoreMLGraph();
    CoreMLGraph(const CoreMLGraph&) = delete;
    CoreMLGraph& operator=(const CoreMLGraph&) = delete;
    std::vector<float> run(const std::vector<std::vector<float>>& inputs);
    static bool available();
    static std::string runtimeVersion();
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}
