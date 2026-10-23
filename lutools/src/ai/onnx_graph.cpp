#include "onnx_graph.h"
#include "directml_device.h"
#include <onnxruntime_cxx_api.h>
#include <algorithm>
#include <cmath>
#include <filesystem>
#include <numeric>
#include <stdexcept>
#ifdef SONY2FUJI_ENABLE_DIRECTML
#include <dml_provider_factory.h>
#endif

namespace sony2fuji::ai {
namespace {
Ort::Env& environment() {
    static Ort::Env value{ORT_LOGGING_LEVEL_WARNING, "rawlab-dualdn"};
    return value;
}

size_t elements(const std::vector<int64_t>& shape) {
    return std::accumulate(shape.begin(), shape.end(), size_t(1), std::multiplies<size_t>());
}
}

GraphSignature graphSignature(GraphKind kind, int size) {
    if (size < 16 || size > 2048 || size % 8) throw std::invalid_argument("invalid DualDn tile size");
    const std::vector<int64_t> raw{1, 4, size, size}, rgb{1, 3, size, size};
    switch (kind) {
    case GraphKind::Raw: return {{"packed_raw", "k", "b"}, "denoised_packed", {raw, {1}, {1}}, raw};
    case GraphKind::ISP: return {{"mosaic", "wb", "camera_to_xyz"}, "encoded_rgb", {{1, 1, size, size}, {1, 1, 1, 4}, {1, 1, 3, 3}}, rgb};
    case GraphKind::RGB: return {{"skip_rgb", "noise_rgb"}, "denoised_rgb", {rgb, rgb}, rgb};
    default: throw std::invalid_argument("invalid DualDn graph kind");
    }
}

struct OnnxGraph::Impl {
    Ort::Session session{nullptr};
    std::vector<std::string> inputNames;
    std::string outputName;
    std::string backend;
    std::vector<std::vector<int64_t>> inputShapes;
    std::vector<int64_t> outputShape;

    Impl(const std::string& path, GraphKind kind, int size, Backend requested) {
        if (requested != Backend::Cpu && requested != Backend::DirectML)
            throw std::invalid_argument("ONNX graph requires CPU or DirectML");
        const auto signature = graphSignature(kind, size);
        inputNames = signature.inputNames; outputName = signature.outputName;
        inputShapes = signature.inputShapes; outputShape = signature.outputShape;
        Ort::SessionOptions options;
        options.SetIntraOpNumThreads(6).SetInterOpNumThreads(1);
        options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
        backend = requested == Backend::DirectML ? "DirectML" : "CPU";
        try {
            if (requested == Backend::DirectML) {
                const auto adapter = findDirectMLAdapter();
#ifdef SONY2FUJI_ENABLE_DIRECTML
                options.DisableMemPattern().SetExecutionMode(ExecutionMode::ORT_SEQUENTIAL);
                const OrtDmlApi* dml = nullptr;
                Ort::ThrowOnError(Ort::GetApi().GetExecutionProviderApi("DML", ORT_API_VERSION, reinterpret_cast<const void**>(&dml)));
                Ort::ThrowOnError(dml->SessionOptionsAppendExecutionProvider_DML(options, adapter.index));
                options.AddConfigEntry("session.disable_cpu_ep_fallback", "1");
#endif
            }
            session = Ort::Session(environment(), std::filesystem::u8path(path).c_str(), options);
        } catch (const Ort::Exception& error) {
            throw std::runtime_error(std::string("Cannot initialize ") + backend + " graph: " + error.what());
        }
        if (session.GetInputCount() != inputNames.size() || session.GetOutputCount() != 1)
            throw std::invalid_argument("DualDn graph input/output count mismatch");
        Ort::AllocatorWithDefaultOptions allocator;
        for (size_t i = 0; i <= inputNames.size(); ++i) {
            const bool output = i == inputNames.size();
            const auto name = output ? session.GetOutputNameAllocated(0, allocator) :
                session.GetInputNameAllocated(i, allocator);
            const auto info = output ? session.GetOutputTypeInfo(0) : session.GetInputTypeInfo(i);
            const auto tensor = info.GetTensorTypeAndShapeInfo();
            if (name.get() != (output ? outputName : inputNames[i]) ||
                tensor.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT ||
                tensor.GetShape() != (output ? outputShape : inputShapes[i]))
                throw std::invalid_argument("DualDn graph tensor contract mismatch");
        }
    }
};

OnnxGraph::OnnxGraph(const std::string& path, GraphKind kind, int size, Backend backend)
    : impl_(std::make_unique<Impl>(path, kind, size, backend)) {}
OnnxGraph::~OnnxGraph() = default;
std::string OnnxGraph::backend() const { return impl_->backend; }
std::string OnnxGraph::runtimeVersion() { return OrtGetApiBase()->GetVersionString(); }

std::vector<float> OnnxGraph::run(const std::vector<std::vector<float>>& inputs) {
    if (inputs.size() != impl_->inputShapes.size())
        throw std::invalid_argument("DualDn input count mismatch");
    auto memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    std::vector<Ort::Value> tensors;
    std::vector<const char*> names;
    for (size_t i = 0; i < inputs.size(); ++i) {
        const auto& input = inputs[i]; const auto& shape = impl_->inputShapes[i];
        if (input.size() != elements(shape) ||
            !std::all_of(input.begin(), input.end(), [](float x) { return std::isfinite(x); }))
            throw std::invalid_argument("DualDn input is nonfinite or has the wrong shape");
        // ORT 的张量视图接口接受可写指针，模型图只读这些输入。
        tensors.push_back(Ort::Value::CreateTensor<float>(memory, const_cast<float*>(input.data()),
                          input.size(), shape.data(), shape.size()));
        names.push_back(impl_->inputNames[i].c_str());
    }
    const char* outputName = impl_->outputName.c_str();
    std::vector<Ort::Value> result;
    try {
        result = impl_->session.Run(Ort::RunOptions{nullptr}, names.data(), tensors.data(),
                                    tensors.size(), &outputName, 1);
    } catch (const Ort::Exception& error) {
        throw std::runtime_error(std::string("DualDn inference failed: ") + error.what());
    }
    const auto info = result[0].GetTensorTypeAndShapeInfo();
    if (info.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT ||
        info.GetShape() != impl_->outputShape)
        throw std::runtime_error("DualDn output changed shape or type");
    const float* values = result[0].GetTensorData<float>();
    const size_t count = elements(impl_->outputShape);
    if (!std::all_of(values, values + count, [](float x) { return std::isfinite(x); }))
        throw std::runtime_error("DualDn returned nonfinite pixels");
    return {values, values + count};
}
} // namespace sony2fuji::ai
