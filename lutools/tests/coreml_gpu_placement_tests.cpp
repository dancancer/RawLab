#include "ai/coreml_graph.h"
#include "ai/model_package.h"
#include "ai/network_graph.h"
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

using namespace sony2fuji::ai;

void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

// Minimal protobuf wire encoder for Core ML specificationVersion=8 MLProgram models.
void appendVarint(std::vector<uint8_t>& out, uint64_t value) {
    while (true) {
        uint8_t byte = static_cast<uint8_t>(value & 0x7f);
        value >>= 7;
        if (value) {
            out.push_back(byte | 0x80);
        } else {
            out.push_back(byte);
            return;
        }
    }
}

void appendTag(std::vector<uint8_t>& out, uint32_t field, uint8_t wire) {
    appendVarint(out, (static_cast<uint64_t>(field) << 3) | wire);
}

void appendFieldVarint(std::vector<uint8_t>& out, uint32_t field, uint64_t value) {
    appendTag(out, field, 0);
    appendVarint(out, value);
}

void appendFieldBytes(std::vector<uint8_t>& out, uint32_t field, const std::vector<uint8_t>& bytes) {
    appendTag(out, field, 2);
    appendVarint(out, bytes.size());
    out.insert(out.end(), bytes.begin(), bytes.end());
}

void appendFieldString(std::vector<uint8_t>& out, uint32_t field, const std::string& text) {
    appendTag(out, field, 2);
    appendVarint(out, text.size());
    out.insert(out.end(), text.begin(), text.end());
}

std::vector<uint8_t> mapEntry(const std::string& key, const std::vector<uint8_t>& value) {
    std::vector<uint8_t> out;
    appendFieldString(out, 1, key);
    appendFieldBytes(out, 2, value);
    return out;
}

std::vector<uint8_t> makeNamedValueType(const std::string& name, const std::vector<int64_t>& shape) {
    // MILSpec.DataType::FLOAT32 == 11
    std::vector<uint8_t> tensorType;
    appendFieldVarint(tensorType, 1, 11);
    appendFieldVarint(tensorType, 2, shape.size());
    for (int64_t d : shape) {
        std::vector<uint8_t> constantDim;
        appendFieldVarint(constantDim, 1, static_cast<uint64_t>(d));
        std::vector<uint8_t> dim;
        appendFieldBytes(dim, 1, constantDim);
        appendFieldBytes(tensorType, 3, dim);
    }
    std::vector<uint8_t> valueType;
    appendFieldBytes(valueType, 1, tensorType);
    std::vector<uint8_t> nvt;
    appendFieldString(nvt, 1, name);
    appendFieldBytes(nvt, 2, valueType);
    return nvt;
}

std::vector<uint8_t> makeFeatureDescription(const std::string& name, const std::vector<int64_t>& shape) {
    // CoreML.Specification.ArrayFeatureType::FLOAT32 == 65568
    std::vector<uint8_t> arrayType;
    for (int64_t d : shape) {
        appendFieldVarint(arrayType, 1, static_cast<uint64_t>(d));
    }
    appendFieldVarint(arrayType, 2, 65568);
    std::vector<uint8_t> featureType;
    appendFieldBytes(featureType, 5, arrayType);
    std::vector<uint8_t> desc;
    appendFieldString(desc, 1, name);
    appendFieldBytes(desc, 3, featureType);
    return desc;
}

std::vector<uint8_t> makeArgBinding(const std::string& name) {
    std::vector<uint8_t> binding;
    appendFieldString(binding, 1, name);
    std::vector<uint8_t> arg;
    appendFieldBytes(arg, 1, binding);
    return arg;
}

std::vector<uint8_t> makeOp(const std::string& opType,
                            const std::vector<std::pair<std::string, std::string>>& inputs,
                            const std::string& outName,
                            const std::vector<int64_t>& outShape) {
    std::vector<uint8_t> op;
    appendFieldString(op, 1, opType);
    for (const auto& [param, argName] : inputs) {
        appendFieldBytes(op, 2, mapEntry(param, makeArgBinding(argName)));
    }
    appendFieldBytes(op, 3, makeNamedValueType(outName, outShape));
    return op;
}

std::vector<uint8_t> buildCpuScheduledMlModel(GraphKind kind, int tileSize) {
    const auto sig = graphSignature(kind, tileSize);
    std::vector<std::vector<uint8_t>> ops;
    if (kind == GraphKind::BlindRGB) {
        ops.push_back(makeOp("erf", {{"x", sig.inputNames[0]}}, sig.outputName, sig.outputShape));
    } else if (kind == GraphKind::RGB) {
        ops.push_back(makeOp("erf", {{"x", sig.inputNames[0]}}, "erf_tmp", sig.outputShape));
        ops.push_back(makeOp("add", {{"x", "erf_tmp"}, {"y", sig.inputNames[1]}}, sig.outputName, sig.outputShape));
    } else if (kind == GraphKind::Raw) {
        ops.push_back(makeOp("erf", {{"x", sig.inputNames[0]}}, "erf_tmp", sig.outputShape));
        ops.push_back(makeOp("add", {{"x", "erf_tmp"}, {"y", sig.inputNames[1]}}, "add_k_tmp", sig.outputShape));
        ops.push_back(makeOp("add", {{"x", "add_k_tmp"}, {"y", sig.inputNames[2]}}, sig.outputName, sig.outputShape));
    } else {
        throw std::invalid_argument("Unsupported GraphKind for CoreML fixture");
    }

    std::vector<uint8_t> block;
    appendFieldString(block, 2, sig.outputName);
    for (const auto& op : ops) {
        appendFieldBytes(block, 3, op);
    }

    std::vector<uint8_t> func;
    for (size_t i = 0; i < sig.inputNames.size(); ++i) {
        appendFieldBytes(func, 1, makeNamedValueType(sig.inputNames[i], sig.inputShapes[i]));
    }
    appendFieldString(func, 2, "CoreML7");
    appendFieldBytes(func, 3, mapEntry("CoreML7", block));

    std::vector<uint8_t> program;
    appendFieldVarint(program, 1, 1);
    appendFieldBytes(program, 2, mapEntry("main", func));

    std::vector<uint8_t> description;
    for (size_t i = 0; i < sig.inputNames.size(); ++i) {
        appendFieldBytes(description, 1, makeFeatureDescription(sig.inputNames[i], sig.inputShapes[i]));
    }
    appendFieldBytes(description, 10, makeFeatureDescription(sig.outputName, sig.outputShape));

    std::vector<uint8_t> model;
    appendFieldVarint(model, 1, 8);
    appendFieldBytes(model, 2, description);
    appendFieldBytes(model, 502, program);
    return model;
}

std::filesystem::path compileMlModel(const std::filesystem::path& dir,
                                     const std::string& stem,
                                     GraphKind kind,
                                     int tileSize) {
    const auto mlmodelPath = dir / (stem + ".mlmodel");
    const auto bytes = buildCpuScheduledMlModel(kind, tileSize);
    {
        std::ofstream out(mlmodelPath, std::ios::binary);
        out.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
        require(bool(out), "failed to write synthetic .mlmodel");
    }
    const std::string cmd = "xcrun coremlcompiler compile \"" + mlmodelPath.string() + "\" \"" + dir.string() + "\" >/dev/null 2>&1";
    const int rc = std::system(cmd.c_str());
    require(rc == 0, "xcrun coremlcompiler failed to compile synthetic .mlmodel");
    const auto mlmodelcPath = dir / (stem + ".mlmodelc");
    require(std::filesystem::is_directory(mlmodelcPath), "compiled .mlmodelc directory missing");
    return mlmodelcPath;
}

template <typename Fn>
void requireRejectedOutsideGpu(Fn&& fn, const char* context) {
    bool rejected = false;
    bool contractError = false;
    std::string message;
    try {
        fn();
    } catch (const ModelContractError& err) {
        contractError = true;
        message = err.what();
    } catch (const std::runtime_error& err) {
        rejected = true;
        message = err.what();
    }
    require(!contractError, (std::string(context) + ": unexpected ModelContractError: " + message).c_str());
    require(rejected, (std::string(context) + ": CPU-scheduled Core ML model was accepted without error").c_str());
    require(message.find("outside the GPU") != std::string::npos,
            (std::string(context) + ": error missing 'outside the GPU': " + message).c_str());
}

} // namespace

int main(int argc, char** argv) {
    namespace fs = std::filesystem;
    fs::path root;
    bool created = false;
    try {
        require(argc == 2, "requires temporary directory path");
        if (!CoreMLGraph::available()) {
            std::cout << "SKIP Core ML GPU placement checks (Apple Silicon GPU + macOS 14.4+ unavailable)\n";
            return 77;
        }
        root = fs::u8path(argv[1]);
        fs::remove_all(root);
        require(fs::create_directories(root), "cannot create temporary directory");
        created = true;

        constexpr int kTile = 16;
        const auto rawCompiled = compileMlModel(root, "cpu_raw", GraphKind::Raw, kTile);
        const auto rgbCompiled = compileMlModel(root, "cpu_rgb", GraphKind::RGB, kTile);
        const auto blindCompiled = compileMlModel(root, "cpu_blind", GraphKind::BlindRGB, kTile);

        ModelPackage package;
        package.tileSize = kTile;
        package.paths = {"raw.onnx", "isp.onnx", "rgb.onnx"};
        package.blindRGBPath = "blind_rgb.onnx";
        package.coreMLPaths = {rawCompiled.u8string(), rgbCompiled.u8string()};
        package.blindRGBCoreMLPath = blindCompiled.u8string();

        for (const auto kind : {GraphKind::Raw, GraphKind::RGB, GraphKind::BlindRGB}) {
            const std::string& path =
                kind == GraphKind::BlindRGB ? package.blindRGBCoreMLPath :
                kind == GraphKind::Raw ? package.coreMLPaths[0] : package.coreMLPaths[1];

            requireRejectedOutsideGpu(
                [&] { CoreMLGraph::verifyGPUPlacement(path, kind); },
                "CoreMLGraph::verifyGPUPlacement");

            requireRejectedOutsideGpu(
                [&] { CoreMLGraph graph(path, kind, kTile); },
                "CoreMLGraph constructor");

            requireRejectedOutsideGpu(
                [&] { NetworkGraph graph(package, kind, Backend::Auto); },
                "NetworkGraph(Backend::Auto)");

            requireRejectedOutsideGpu(
                [&] { NetworkGraph graph(package, kind, Backend::CoreML); },
                "NetworkGraph(Backend::CoreML)");
        }

        // Malformed/empty .mlmodelc directory lacking regular coremldata.bin must throw
        // std::runtime_error cleanly rather than letting MLComputePlan SIGABRT.
        {
            const auto emptyDir = root / "empty.mlmodelc";
            require(fs::create_directories(emptyDir), "cannot create empty.mlmodelc fixture");
            bool threw = false;
            try {
                CoreMLGraph::verifyGPUPlacement(emptyDir.u8string(), GraphKind::RGB);
            } catch (const std::runtime_error& err) {
                threw = std::string(err.what()).find("coremldata.bin") != std::string::npos;
            }
            require(threw, "empty .mlmodelc directory without coremldata.bin was not rejected cleanly");

            const auto dirInsteadOfFile = root / "bad_data.mlmodelc";
            require(fs::create_directories(dirInsteadOfFile / "coremldata.bin"), "cannot create nested coremldata.bin dir");
            threw = false;
            try {
                CoreMLGraph::verifyGPUPlacement(dirInsteadOfFile.u8string(), GraphKind::Raw);
            } catch (const std::runtime_error& err) {
                threw = std::string(err.what()).find("coremldata.bin") != std::string::npos;
            }
            require(threw, ".mlmodelc with directory coremldata.bin was not rejected cleanly");
        }

        fs::remove_all(root);
        std::cout << "PASS Core ML MLComputePlan rejects CPU-scheduled RAW/RGB/BlindRGB graphs without CPU fallback\n";
        return 0;
    } catch (const std::exception& error) {
        if (created) {
            std::error_code ignored;
            fs::remove_all(root, ignored);
        }
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
