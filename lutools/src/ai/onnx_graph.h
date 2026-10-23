#pragma once

#include <memory>
#include <cstdint>
#include <string>
#include <vector>

namespace sony2fuji::ai {

enum class Backend { Cpu = 0, CoreML = 1, Auto = 2, DirectML = 3 };
enum class GraphKind { Raw, ISP, RGB };
struct GraphSignature {
    std::vector<std::string> inputNames;
    std::string outputName;
    std::vector<std::vector<int64_t>> inputShapes;
    std::vector<int64_t> outputShape;
};
GraphSignature graphSignature(GraphKind kind, int tileSize);

// 会话由后台任务单线程持有；只接受固定协议中的三种图。
class OnnxGraph {
public:
    OnnxGraph(const std::string& path, GraphKind kind, int tileSize, Backend backend = Backend::Cpu);
    ~OnnxGraph();
    OnnxGraph(const OnnxGraph&) = delete;
    OnnxGraph& operator=(const OnnxGraph&) = delete;
    std::vector<float> run(const std::vector<std::vector<float>>& inputs);
    std::string backend() const;
    static std::string runtimeVersion();
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace sony2fuji::ai
