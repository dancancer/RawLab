#include "coreml_graph.h"
#include <algorithm>
#include <cmath>
#include <numeric>
#include <stdexcept>
#import <CoreML/CoreML.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

namespace sony2fuji::ai {
namespace {
size_t elements(const std::vector<int64_t>& shape) {
    return std::accumulate(shape.begin(), shape.end(), size_t(1), std::multiplies<size_t>());
}
NSString* name(const std::string& value) { return [NSString stringWithUTF8String:value.c_str()]; }
std::string message(NSError* error) { return error ? error.localizedDescription.UTF8String : "unknown Core ML error"; }
NSArray<NSNumber*>* dimensions(const std::vector<int64_t>& shape) {
    NSMutableArray<NSNumber*>* result = [NSMutableArray arrayWithCapacity:shape.size()];
    for (auto value : shape) [result addObject:@(value)];
    return result;
}
bool matches(NSArray<NSNumber*>* actual, const std::vector<int64_t>& expected) {
    if (actual.count != expected.size()) return false;
    for (size_t i = 0; i < expected.size(); ++i) if (actual[i].longLongValue != expected[i]) return false;
    return true;
}
void validate(MLFeatureDescription* feature, const std::vector<int64_t>& shape) {
    if (!feature || feature.type != MLFeatureTypeMultiArray || feature.multiArrayConstraint.dataType != MLMultiArrayDataTypeFloat32 ||
        !matches(feature.multiArrayConstraint.shape, shape))
        throw ModelContractError("Core ML tensor contract mismatch");
}
MLModelConfiguration* gpuConfiguration() {
    MLModelConfiguration* configuration = [MLModelConfiguration new];
    configuration.computeUnits = MLComputeUnitsCPUAndGPU;
    configuration.allowLowPrecisionAccumulationOnGPU = NO;
    return configuration;
}

API_AVAILABLE(macos(14.4))
bool verifyGPUBlock(MLComputePlan* plan, MLModelStructureProgramBlock* block) {
    bool hasGPU = false;
    for (MLModelStructureProgramOperation* operation in block.operations) {
        const auto cost = [plan estimatedCostOfMLProgramOperation:operation];
        if (cost && cost.weight > 0) {
            const auto usage = [plan computeDeviceUsageForMLProgramOperation:operation];
            if (![usage.preferredComputeDevice isKindOfClass:MLGPUComputeDevice.class])
                throw std::runtime_error("Core ML scheduled an HDR RAW model operation outside the GPU");
            hasGPU = true;
        }
        for (MLModelStructureProgramBlock* child in operation.blocks)
            hasGPU = verifyGPUBlock(plan, child) || hasGPU;
    }
    return hasGPU;
}
}

struct CoreMLGraph::Impl {
    MLModel* model;
    GraphSignature signature;
    Impl(const std::string& path, GraphKind kind, int size) : signature(graphSignature(kind, size)) {
        if (kind == GraphKind::ISP) throw std::invalid_argument("Official ISP must use ONNX CPU");
        if (!CoreMLGraph::available()) throw std::runtime_error("Native Core ML requires an Apple Silicon GPU and macOS 14");
        @autoreleasepool {
            NSError* error = nil;
            model = [MLModel modelWithContentsOfURL:[NSURL fileURLWithPath:name(path)] configuration:gpuConfiguration() error:&error];
            if (!model) throw std::runtime_error("Cannot load native Core ML model: " + message(error));
            const auto description = model.modelDescription;
            if (description.inputDescriptionsByName.count != signature.inputNames.size() || description.outputDescriptionsByName.count != 1)
                throw ModelContractError("Core ML input/output count mismatch");
            for (size_t i = 0; i < signature.inputNames.size(); ++i)
                validate(description.inputDescriptionsByName[name(signature.inputNames[i])], signature.inputShapes[i]);
            validate(description.outputDescriptionsByName[name(signature.outputName)], signature.outputShape);
        }
    }
};

CoreMLGraph::CoreMLGraph(const std::string& path, GraphKind kind, int size) {
    @try { impl_ = std::make_unique<Impl>(path, kind, size); }
    @catch (NSException* error) { throw std::runtime_error(std::string("Core ML initialization failed: ") + (error.reason ?: error.name).UTF8String); }
}
CoreMLGraph::~CoreMLGraph() = default;

bool CoreMLGraph::available() {
#if defined(__aarch64__)
    if (@available(macOS 14.0, *)) {
        @autoreleasepool {
            for (id<MLComputeDeviceProtocol> device in MLModel.availableComputeDevices)
                if ([device isKindOfClass:MLGPUComputeDevice.class]) return true;
        }
    }
#endif
    return false;
}

bool CoreMLGraph::gpuPlanAvailable() {
    if (@available(macOS 14.4, *)) return available();
    return false;
}

void CoreMLGraph::verifyRawGPUPlacement(const std::string& path) {
    if (@available(macOS 14.4, *)) {
        @try { @autoreleasepool {
            if (path.empty()) throw std::runtime_error("Native Core ML RAW model is not installed");
            __block MLComputePlan* plan = nil;
            __block NSError* failure = nil;
            const auto ready = dispatch_semaphore_create(0);
            [MLComputePlan loadContentsOfURL:[NSURL fileURLWithPath:name(path)] configuration:gpuConfiguration()
                completionHandler:^(MLComputePlan* value, NSError* error) {
                    plan = value;
                    failure = error;
                    dispatch_semaphore_signal(ready);
                }];
            if (dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) != 0)
                throw std::runtime_error("Core ML RAW GPU compute plan timed out");
            if (!plan) throw std::runtime_error("Cannot verify Core ML RAW GPU placement: " + message(failure));
            const auto main = plan.modelStructure.program.functions[@"main"];
            if (!main || !verifyGPUBlock(plan, main.block))
                throw std::runtime_error("Core ML RAW model has no verified GPU placement");
            return;
        }} @catch (NSException* error) {
            throw std::runtime_error(std::string("Core ML RAW GPU plan failed: ") + (error.reason ?: error.name).UTF8String);
        }
    }
    throw std::runtime_error("HDR RAW GPU placement requires macOS 14.4 or newer");
}

std::string CoreMLGraph::runtimeVersion() {
    const auto version = NSProcessInfo.processInfo.operatingSystemVersion;
    return "coreml-native-fp32-v1:" + std::to_string(version.majorVersion) + "." +
        std::to_string(version.minorVersion) + "." + std::to_string(version.patchVersion);
}

std::vector<float> CoreMLGraph::run(const std::vector<std::vector<float>>& inputs) {
    const auto& signature = impl_->signature;
    if (inputs.size() != signature.inputShapes.size()) throw std::invalid_argument("Core ML input count mismatch");
    for (size_t i = 0; i < inputs.size(); ++i)
        if (inputs[i].size() != elements(signature.inputShapes[i]) ||
            !std::all_of(inputs[i].begin(), inputs[i].end(), [](float value) { return std::isfinite(value); }))
            throw std::invalid_argument("Core ML input is nonfinite or has the wrong shape");
    @try { @autoreleasepool {
        NSMutableDictionary<NSString*, MLFeatureValue*>* features = [NSMutableDictionary dictionary];
        NSError* error = nil;
        for (size_t i = 0; i < inputs.size(); ++i) {
            const auto& shape = signature.inputShapes[i];
            std::vector<int64_t> strides(shape.size(), 1);
            for (size_t j = shape.size() - 1; j > 0; --j) strides[j - 1] = strides[j] * shape[j];
            // predictionFromFeatures 是同步调用；输入向量在调用期间保持存活，不转交所有权。
            MLMultiArray* array = [[MLMultiArray alloc] initWithDataPointer:const_cast<float*>(inputs[i].data())
                shape:dimensions(shape) dataType:MLMultiArrayDataTypeFloat32 strides:dimensions(strides)
                deallocator:^(void* ignored) {} error:&error];
            if (!array) throw std::runtime_error("Cannot create Core ML input: " + message(error));
            features[name(signature.inputNames[i])] = [MLFeatureValue featureValueWithMultiArray:array];
        }
        MLDictionaryFeatureProvider* provider = [[MLDictionaryFeatureProvider alloc] initWithDictionary:features error:&error];
        if (!provider) throw std::runtime_error("Cannot create Core ML features: " + message(error));
        id<MLFeatureProvider> result = [impl_->model predictionFromFeatures:provider error:&error];
        if (!result) throw std::runtime_error("Core ML inference failed: " + message(error));
        MLMultiArray* output = [result featureValueForName:name(signature.outputName)].multiArrayValue;
        if (!output || output.dataType != MLMultiArrayDataTypeFloat32 || !matches(output.shape, signature.outputShape))
            throw ModelContractError("Core ML output contract changed");
        const auto& shape = signature.outputShape;
        const float* data = static_cast<const float*>(output.dataPointer);
        std::vector<float> values(elements(shape));
        const size_t cs = output.strides[1].unsignedLongLongValue;
        const size_t ys = output.strides[2].unsignedLongLongValue, xs = output.strides[3].unsignedLongLongValue;
        for (int64_t c = 0; c < shape[1]; ++c) for (int64_t y = 0; y < shape[2]; ++y) for (int64_t x = 0; x < shape[3]; ++x)
            values[(c * shape[2] + y) * shape[3] + x] = data[c * cs + y * ys + x * xs];
        if (!std::all_of(values.begin(), values.end(), [](float value) { return std::isfinite(value); }))
            throw ModelContractError("Core ML returned nonfinite pixels");
        return values;
    }} @catch (NSException* error) {
        throw std::runtime_error(std::string("Core ML inference exception: ") + (error.reason ?: error.name).UTF8String);
    }
}
}
