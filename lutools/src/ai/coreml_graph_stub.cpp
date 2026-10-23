#include "coreml_graph.h"
#include <stdexcept>
namespace sony2fuji::ai {
struct CoreMLGraph::Impl {};
CoreMLGraph::CoreMLGraph(const std::string&, GraphKind, int) { throw std::runtime_error("Native Core ML is unavailable on this platform"); }
CoreMLGraph::~CoreMLGraph() = default;
bool CoreMLGraph::available() { return false; }
std::string CoreMLGraph::runtimeVersion() { return "coreml-unavailable"; }
std::vector<float> CoreMLGraph::run(const std::vector<std::vector<float>>&) { throw std::runtime_error("Native Core ML is unavailable"); }
}
