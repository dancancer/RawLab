#include "ai/ai_session.h"
#include "ai/coreml_graph.h"
#include "ai/directml_device.h"
#include "ai/dualdn_cache.h"
#include "ai/model_package.h"
#include "core/pipeline.h"
#include "core/sha256.h"
#include "sony2fuji/raw_processor.h"
#include <nlohmann/json.hpp>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <random>
#include <stdexcept>
#include <vector>

#if defined(_WIN32)
#define NOMINMAX
#include <windows.h>
#include <psapi.h>
#else
#include <sys/resource.h>
#endif

#if defined(__APPLE__)
#include <malloc/malloc.h>
#endif

namespace {

void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

uint64_t peakRssBytes() {
#if defined(_WIN32)
    PROCESS_MEMORY_COUNTERS pmc{};
    if (!GetProcessMemoryInfo(GetCurrentProcess(), &pmc, sizeof(pmc))) {
        throw std::runtime_error("Cannot read peak working set");
    }
    return static_cast<uint64_t>(pmc.PeakWorkingSetSize);
#elif defined(__APPLE__)
    rusage usage{};
    if (getrusage(RUSAGE_SELF, &usage) != 0) throw std::runtime_error("Cannot read peak RSS");
    return static_cast<uint64_t>(usage.ru_maxrss);
#else
    rusage usage{};
    if (getrusage(RUSAGE_SELF, &usage) != 0) throw std::runtime_error("Cannot read peak RSS");
    return static_cast<uint64_t>(usage.ru_maxrss) * 1024ULL;
#endif
}

#if defined(__APPLE__)
uint64_t appleHeapInUseBytes() {
    malloc_statistics_t stats{};
    malloc_zone_statistics(nullptr, &stats);
    return static_cast<uint64_t>(stats.size_in_use);
}
#endif

void createSyntheticPackage(const std::filesystem::path& modelDir) {
    using namespace sony2fuji::ai;
    std::filesystem::create_directories(modelDir);
    nlohmann::json manifest = {
        {"format_version", 1},
        {"protocol", "rawlab-dualdn-v1"},
        {"model_id", "dualdn-big-restormer-v1"},
        {"source_revision", dualdnSourceRevision},
        {"weights_sha256", dualdnWeightsSHA256},
        {"tile_size", 640},
        {"production_geometry", true},
        {"raw_core", 384},
        {"raw_halo", 128},
        {"rgb_core", 512},
        {"rgb_halo", 64},
        {"packed_order", {"R", "G_top", "G_bottom", "B"}},
        {"input_floor", 1e-8},
        {"variance_floor", 1e-7},
        {"sigma_semantics", "variance"},
        {"isp", {{"demosaic", "AHD"}, {"gamma", "Rec709"}, {"reference", "D65"}, {"alpha", 0}, {"bgu", false}}}
    };
    for (const auto* name : {"raw", "isp", "rgb"}) {
        const auto file = modelDir / (std::string(name) + ".onnx");
        { std::ofstream out(file, std::ios::binary); out << "synthetic onnx " << name; }
        manifest["graphs"][name] = {
            {"file", file.filename().u8string()},
            {"sha256", sha256File(file.u8string())},
            {"bytes", std::filesystem::file_size(file)}
        };
    }
    const auto blindFile = modelDir / "blind_rgb.onnx";
    const auto licenseFile = modelDir / "Restormer-LICENSE.txt";
    { std::ofstream out(blindFile, std::ios::binary); out << "synthetic blind_rgb"; }
    std::filesystem::copy_file(RESTORMER_TEST_LICENSE, licenseFile, std::filesystem::copy_options::overwrite_existing);
    manifest["blind_rgb"] = {
        {"model_id", "restormer-real-srgb-v1"},
        {"protocol", "rawlab-scene-rgb-v1"},
        {"source_revision", restormerSourceRevision},
        {"weights_sha256", restormerWeightsSHA256},
        {"tile_size", 640},
        {"core", 512},
        {"halo", 64},
        {"input", "encoded_rgb"},
        {"output", "denoised_rgb"},
        {"file", "blind_rgb.onnx"},
        {"bytes", std::filesystem::file_size(blindFile)},
        {"sha256", sha256File(blindFile.u8string())},
        {"license_file", "Restormer-LICENSE.txt"},
        {"license_sha256", restormerLicenseSHA256}
    };
    std::ofstream(modelDir / "manifest.json", std::ios::binary) << manifest.dump();
}

std::string writeStreamedCacheFile(const std::filesystem::path& cacheDir,
                                   const std::string& key,
                                   sony2fuji::ai::CacheKind kind,
                                   int width,
                                   int height,
                                   const std::string& dependency,
                                   const std::string& producer) {
    const int channels = kind == sony2fuji::ai::CacheKind::Raw ? 1 : 3;
    const size_t pixels = static_cast<size_t>(width) * static_cast<size_t>(height);
    const size_t totalFloats = pixels * static_cast<size_t>(channels);
    constexpr size_t kChunkFloats = 65536;
    std::vector<float> chunk(std::min(totalFloats, kChunkFloats));
    sony2fuji::hash::Sha256 hasher;
    for (int c = 0; c < channels; ++c) {
        size_t offset = 0;
        while (offset < pixels) {
            const size_t n = std::min(chunk.size(), pixels - offset);
            for (size_t i = 0; i < n; ++i) {
                chunk[i] = static_cast<float>(c) * 0.5f + 0.0001f * static_cast<float>((offset + i) % 512);
            }
            hasher.update(chunk.data(), n * sizeof(float));
            offset += n;
        }
    }
    const std::string payloadDigest = hasher.finish();
    nlohmann::json header = {
        {"format", "rawlab-dualdn-cache-v1"},
        {"key", key},
        {"width", width},
        {"height", height},
        {"channels", channels},
        {"sha256", payloadDigest},
        {"dependency", dependency},
        {"producer", producer}
    };
    const std::string headerRaw = header.dump();
    header["header_sha256"] = sony2fuji::hash::sha256Bytes(headerRaw.data(), headerRaw.size());
    const std::string text = header.dump();
    const uint32_t length = static_cast<uint32_t>(text.size());

    std::filesystem::create_directories(cacheDir);
    const char* ext = kind == sony2fuji::ai::CacheKind::Raw ? ".rawcache" : ".rgbcache";
    std::ofstream output(cacheDir / (key + ext), std::ios::binary);
    output.write(reinterpret_cast<const char*>(&length), sizeof(length));
    output.write(text.data(), text.size());
    for (int c = 0; c < channels; ++c) {
        size_t offset = 0;
        while (offset < pixels) {
            const size_t n = std::min(chunk.size(), pixels - offset);
            for (size_t i = 0; i < n; ++i) {
                chunk[i] = static_cast<float>(c) * 0.5f + 0.0001f * static_cast<float>((offset + i) % 512);
            }
            output.write(reinterpret_cast<const char*>(chunk.data()), n * sizeof(float));
            offset += n;
        }
    }
    output.close();
    require(bool(output), "failed to write streamed AI cache file");
    return payloadDigest;
}

void writeU16LE(std::vector<uint8_t>& buf, size_t offset, uint16_t value) {
    buf[offset] = static_cast<uint8_t>(value & 0xffu);
    buf[offset + 1] = static_cast<uint8_t>((value >> 8) & 0xffu);
}

void writeU32LE(std::vector<uint8_t>& buf, size_t offset, uint32_t value) {
    buf[offset] = static_cast<uint8_t>(value & 0xffu);
    buf[offset + 1] = static_cast<uint8_t>((value >> 8) & 0xffu);
    buf[offset + 2] = static_cast<uint8_t>((value >> 16) & 0xffu);
    buf[offset + 3] = static_cast<uint8_t>((value >> 24) & 0xffu);
}

struct TiffEntry {
    uint16_t tag;
    uint16_t type;
    uint32_t count;
    std::vector<uint8_t> payload;
};

TiffEntry tiffU16(uint16_t tag, const std::vector<uint16_t>& values) {
    TiffEntry e{tag, 3, static_cast<uint32_t>(values.size()), std::vector<uint8_t>(values.size() * 2)};
    for (size_t i = 0; i < values.size(); ++i) writeU16LE(e.payload, i * 2, values[i]);
    return e;
}

TiffEntry tiffU32(uint16_t tag, const std::vector<uint32_t>& values) {
    TiffEntry e{tag, 4, static_cast<uint32_t>(values.size()), std::vector<uint8_t>(values.size() * 4)};
    for (size_t i = 0; i < values.size(); ++i) writeU32LE(e.payload, i * 4, values[i]);
    return e;
}

TiffEntry tiffBytes(uint16_t tag, uint16_t type, std::vector<uint8_t> bytes) {
    return TiffEntry{tag, type, static_cast<uint32_t>(bytes.size()), std::move(bytes)};
}

TiffEntry tiffAscii(uint16_t tag, const std::string& text) {
    std::vector<uint8_t> bytes(text.begin(), text.end());
    bytes.push_back(0);
    return TiffEntry{tag, 2, static_cast<uint32_t>(bytes.size()), std::move(bytes)};
}

TiffEntry tiffRationals(uint16_t tag, uint16_t type, const std::vector<std::pair<int32_t, int32_t>>& pairs) {
    TiffEntry e{tag, type, static_cast<uint32_t>(pairs.size()), std::vector<uint8_t>(pairs.size() * 8)};
    for (size_t i = 0; i < pairs.size(); ++i) {
        writeU32LE(e.payload, i * 8, static_cast<uint32_t>(pairs[i].first));
        writeU32LE(e.payload, i * 8 + 4, static_cast<uint32_t>(pairs[i].second));
    }
    return e;
}

void writeNoisyBayerDng(const std::filesystem::path& path, int width, int height) {
    std::mt19937 rng(7419);
    std::normal_distribution<float> noise(0.0f, 38.0f);
    std::vector<uint8_t> rawBytes(static_cast<size_t>(width) * height * 2);
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const float zone = 420.0f + ((y >= height / 2) ? 320.0f : 0.0f) +
                ((x >= width / 2) ? 220.0f : 0.0f);
            const float sample = std::clamp(zone + noise(rng), 80.0f, 3900.0f);
            writeU16LE(rawBytes, (static_cast<size_t>(y) * width + x) * 2,
                       static_cast<uint16_t>(std::lround(sample)));
        }
    }
    std::vector<TiffEntry> ifd0 = {
        tiffU32(254, {0}),
        tiffU32(256, {static_cast<uint32_t>(width)}),
        tiffU32(257, {static_cast<uint32_t>(height)}),
        tiffU16(258, {16}),
        tiffU16(259, {1}),
        tiffU16(262, {32803}),
        tiffAscii(271, "RawLab"),
        tiffAscii(272, "BayerRgbCacheMissTest"),
        tiffU32(273, {0}),
        tiffU16(274, {1}),
        tiffU16(277, {1}),
        tiffU32(278, {static_cast<uint32_t>(height)}),
        tiffU32(279, {static_cast<uint32_t>(rawBytes.size())}),
        tiffU16(284, {1}),
        tiffU16(33421, {2, 2}),
        tiffBytes(33422, 1, {0, 1, 1, 2}),
        tiffBytes(50706, 1, {1, 4, 0, 0}),
        tiffBytes(50707, 1, {1, 3, 0, 0}),
        tiffAscii(50708, "RawLab BayerTest"),
        tiffBytes(50710, 1, {0, 1, 2}),
        tiffU16(50711, {1}),
        tiffU16(50713, {1, 1}),
        tiffRationals(50714, 5, {{64, 1}}),
        tiffU32(50717, {4095}),
        tiffRationals(50721, 10, {
            {32406, 10000}, {-15372, 10000}, {-4986, 10000},
            {-9689, 10000}, {18758, 10000}, {415, 10000},
            {557, 10000}, {-2040, 10000}, {10570, 10000}
        }),
        tiffRationals(50728, 5, {{1, 2}, {1, 1}, {2, 3}}),
        tiffU16(50778, {21}),
    };
    size_t ifdSize = 2 + ifd0.size() * 12 + 4;
    for (const auto& e : ifd0) {
        if (e.payload.size() > 4) ifdSize += (e.payload.size() + 1) & ~size_t(1);
    }
    const uint32_t ifd0Offset = 8;
    const uint32_t rawOffset = static_cast<uint32_t>((ifd0Offset + ifdSize + 3) & ~size_t(3));
    for (auto& e : ifd0) {
        if (e.tag == 273) {
            writeU32LE(e.payload, 0, rawOffset);
            break;
        }
    }
    std::vector<uint8_t> file(rawOffset + rawBytes.size(), 0);
    file[0] = 'I'; file[1] = 'I';
    writeU16LE(file, 2, 42);
    writeU32LE(file, 4, ifd0Offset);
    writeU16LE(file, ifd0Offset, static_cast<uint16_t>(ifd0.size()));
    uint32_t entryOffset = ifd0Offset + 2;
    uint32_t dataOffset = entryOffset + static_cast<uint32_t>(ifd0.size()) * 12 + 4;
    for (const auto& e : ifd0) {
        writeU16LE(file, entryOffset, e.tag);
        writeU16LE(file, entryOffset + 2, e.type);
        writeU32LE(file, entryOffset + 4, e.count);
        if (e.payload.size() <= 4) {
            std::copy(e.payload.begin(), e.payload.end(), file.begin() + entryOffset + 8);
        } else {
            writeU32LE(file, entryOffset + 8, dataOffset);
            std::copy(e.payload.begin(), e.payload.end(), file.begin() + dataOffset);
            dataOffset += static_cast<uint32_t>((e.payload.size() + 1) & ~size_t(1));
        }
        entryOffset += 12;
    }
    std::copy(rawBytes.begin(), rawBytes.end(), file.begin() + rawOffset);
    std::ofstream out(path, std::ios::binary);
    out.write(reinterpret_cast<const char*>(file.data()), static_cast<std::streamsize>(file.size()));
    out.close();
    require(bool(out), "failed to write synthetic noisy Bayer DNG");
}

void appendVarint(std::vector<uint8_t>& out, uint64_t value) {
    while (true) {
        uint8_t byte = static_cast<uint8_t>(value & 0x7f);
        value >>= 7;
        if (value) out.push_back(byte | 0x80);
        else { out.push_back(byte); return; }
    }
}

void appendFieldVarint(std::vector<uint8_t>& out, uint32_t field, uint64_t value) {
    appendVarint(out, (static_cast<uint64_t>(field) << 3) | 0);
    appendVarint(out, value);
}

void appendFieldBytes(std::vector<uint8_t>& out, uint32_t field, const std::vector<uint8_t>& bytes) {
    appendVarint(out, (static_cast<uint64_t>(field) << 3) | 2);
    appendVarint(out, bytes.size());
    out.insert(out.end(), bytes.begin(), bytes.end());
}

void appendFieldString(std::vector<uint8_t>& out, uint32_t field, const std::string& text) {
    appendVarint(out, (static_cast<uint64_t>(field) << 3) | 2);
    appendVarint(out, text.size());
    out.insert(out.end(), text.begin(), text.end());
}

std::vector<uint8_t> onnxValueInfo(const std::string& name, const std::vector<int64_t>& shape) {
    std::vector<uint8_t> shapeProto;
    for (int64_t d : shape) {
        std::vector<uint8_t> dim;
        appendFieldVarint(dim, 1, static_cast<uint64_t>(d));
        appendFieldBytes(shapeProto, 1, dim);
    }
    std::vector<uint8_t> tensorType;
    appendFieldVarint(tensorType, 1, 1); // TensorProto::FLOAT == 1
    appendFieldBytes(tensorType, 2, shapeProto);
    std::vector<uint8_t> typeProto;
    appendFieldBytes(typeProto, 1, tensorType);
    std::vector<uint8_t> valueInfo;
    appendFieldString(valueInfo, 1, name);
    appendFieldBytes(valueInfo, 2, typeProto);
    return valueInfo;
}

std::vector<uint8_t> buildIspOnnx(int tileSize) {
    // Minimal ONNX ModelProto: Concat(axis=1, [mosaic, mosaic, mosaic]) -> encoded_rgb
    std::vector<uint8_t> attr;
    appendFieldString(attr, 1, "axis");
    appendFieldVarint(attr, 3, 1);
    appendFieldVarint(attr, 20, 2); // AttributeProto::INT == 2

    std::vector<uint8_t> node;
    appendFieldString(node, 1, "mosaic");
    appendFieldString(node, 1, "mosaic");
    appendFieldString(node, 1, "mosaic");
    appendFieldString(node, 2, "encoded_rgb");
    appendFieldString(node, 4, "Concat");
    appendFieldBytes(node, 5, attr);

    std::vector<uint8_t> graph;
    appendFieldBytes(graph, 1, node);
    appendFieldString(graph, 2, "isp_identity");
    appendFieldBytes(graph, 11, onnxValueInfo("mosaic", {1, 1, tileSize, tileSize}));
    appendFieldBytes(graph, 11, onnxValueInfo("wb", {1, 1, 1, 4}));
    appendFieldBytes(graph, 11, onnxValueInfo("camera_to_xyz", {1, 1, 3, 3}));
    appendFieldBytes(graph, 12, onnxValueInfo("encoded_rgb", {1, 3, tileSize, tileSize}));

    std::vector<uint8_t> opset;
    appendFieldString(opset, 1, "");
    appendFieldVarint(opset, 2, 13);

    std::vector<uint8_t> model;
    appendFieldVarint(model, 1, 8);
    appendFieldBytes(model, 7, graph);
    appendFieldBytes(model, 8, opset);
    return model;
}

std::vector<uint8_t> buildRgbOnnx(int tileSize) {
    // Minimal ONNX ModelProto: Add(skip_rgb, noise_rgb) -> denoised_rgb
    std::vector<uint8_t> node;
    appendFieldString(node, 1, "skip_rgb");
    appendFieldString(node, 1, "noise_rgb");
    appendFieldString(node, 2, "denoised_rgb");
    appendFieldString(node, 4, "Add");

    std::vector<uint8_t> graph;
    appendFieldBytes(graph, 1, node);
    appendFieldString(graph, 2, "rgb_identity");
    appendFieldBytes(graph, 11, onnxValueInfo("skip_rgb", {1, 3, tileSize, tileSize}));
    appendFieldBytes(graph, 11, onnxValueInfo("noise_rgb", {1, 3, tileSize, tileSize}));
    appendFieldBytes(graph, 12, onnxValueInfo("denoised_rgb", {1, 3, tileSize, tileSize}));

    std::vector<uint8_t> opset;
    appendFieldString(opset, 1, "");
    appendFieldVarint(opset, 2, 13);

    std::vector<uint8_t> model;
    appendFieldVarint(model, 1, 8);
    appendFieldBytes(model, 7, graph);
    appendFieldBytes(model, 8, opset);
    return model;
}

#if defined(__APPLE__)
std::vector<uint8_t> mapEntry(const std::string& key, const std::vector<uint8_t>& value) {
    std::vector<uint8_t> out;
    appendFieldString(out, 1, key);
    appendFieldBytes(out, 2, value);
    return out;
}

std::vector<uint8_t> makeNamedValueType(const std::string& name, const std::vector<int64_t>& shape) {
    std::vector<uint8_t> tensorType;
    appendFieldVarint(tensorType, 1, 11); // FLOAT32
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
    std::vector<uint8_t> arrayType;
    for (int64_t d : shape) appendFieldVarint(arrayType, 1, static_cast<uint64_t>(d));
    appendFieldVarint(arrayType, 2, 65568); // FLOAT32
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

std::vector<uint8_t> buildGpuScheduledRgbMlModel(int tileSize) {
    const auto sig = sony2fuji::ai::graphSignature(sony2fuji::ai::GraphKind::RGB, tileSize);
    auto makeOp = [&](const std::string& opType, const std::string& x, const std::string& y, const std::string& outName) {
        std::vector<uint8_t> op;
        appendFieldString(op, 1, opType);
        appendFieldBytes(op, 2, mapEntry("x", makeArgBinding(x)));
        appendFieldBytes(op, 2, mapEntry("y", makeArgBinding(y)));
        appendFieldBytes(op, 3, makeNamedValueType(outName, sig.outputShape));
        return op;
    };

    std::vector<std::vector<uint8_t>> ops;
    ops.push_back(makeOp("mul", sig.inputNames[0], sig.inputNames[1], "t0"));
    for (int i = 1; i < 32; ++i) {
        const std::string out = (i == 31) ? sig.outputName : ("t" + std::to_string(i));
        ops.push_back(makeOp((i % 2 == 1) ? "add" : "sub", "t" + std::to_string(i - 1), sig.inputNames[1], out));
    }

    std::vector<uint8_t> block;
    appendFieldString(block, 2, sig.outputName);
    for (const auto& op : ops) appendFieldBytes(block, 3, op);

    std::vector<uint8_t> func;
    for (size_t i = 0; i < sig.inputNames.size(); ++i)
        appendFieldBytes(func, 1, makeNamedValueType(sig.inputNames[i], sig.inputShapes[i]));
    appendFieldString(func, 2, "CoreML7");
    appendFieldBytes(func, 3, mapEntry("CoreML7", block));

    std::vector<uint8_t> program;
    appendFieldVarint(program, 1, 1);
    appendFieldBytes(program, 2, mapEntry("main", func));

    std::vector<uint8_t> description;
    for (size_t i = 0; i < sig.inputNames.size(); ++i)
        appendFieldBytes(description, 1, makeFeatureDescription(sig.inputNames[i], sig.inputShapes[i]));
    appendFieldBytes(description, 10, makeFeatureDescription(sig.outputName, sig.outputShape));

    std::vector<uint8_t> model;
    appendFieldVarint(model, 1, 8);
    appendFieldBytes(model, 2, description);
    appendFieldBytes(model, 502, program);
    return model;
}

nlohmann::json coremlManifestEntry(const std::filesystem::path& folder) {
    nlohmann::json files = nlohmann::json::array();
    for (const auto& entry : std::filesystem::recursive_directory_iterator(folder)) {
        if (!entry.is_regular_file()) continue;
        files.push_back({
            {"path", entry.path().lexically_relative(folder).generic_u8string()},
            {"bytes", std::filesystem::file_size(entry.path())},
            {"sha256", sony2fuji::ai::sha256File(entry.path().u8string())}
        });
    }
    return {{"directory", folder.filename().u8string()}, {"files", files}};
}
#endif

void createBayerExecutablePackage(const std::filesystem::path& modelDir) {
    using namespace sony2fuji::ai;
    std::filesystem::create_directories(modelDir);
    nlohmann::json manifest = {
        {"format_version", 1},
        {"protocol", "rawlab-dualdn-v1"},
        {"model_id", "dualdn-big-restormer-v1"},
        {"source_revision", dualdnSourceRevision},
        {"weights_sha256", dualdnWeightsSHA256},
        {"tile_size", 640},
        {"production_geometry", true},
        {"raw_core", 384},
        {"raw_halo", 128},
        {"rgb_core", 512},
        {"rgb_halo", 64},
        {"packed_order", {"R", "G_top", "G_bottom", "B"}},
        {"input_floor", 1e-8},
        {"variance_floor", 1e-7},
        {"sigma_semantics", "variance"},
        {"isp", {{"demosaic", "AHD"}, {"gamma", "Rec709"}, {"reference", "D65"}, {"alpha", 0}, {"bgu", false}}}
    };
    const auto writeBinary = [](const std::filesystem::path& p, const std::vector<uint8_t>& bytes) {
        std::ofstream out(p, std::ios::binary);
        out.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
        out.close();
        require(bool(out), "failed to write synthetic ONNX fixture");
    };
    {
        const auto file = modelDir / "raw.onnx";
        std::ofstream out(file, std::ios::binary); out << "synthetic onnx raw";
        out.close();
        manifest["graphs"]["raw"] = {{"file", "raw.onnx"}, {"sha256", sha256File(file.u8string())},
                                     {"bytes", std::filesystem::file_size(file)}};
    }
    {
        const auto file = modelDir / "isp.onnx";
        writeBinary(file, buildIspOnnx(640));
        manifest["graphs"]["isp"] = {{"file", "isp.onnx"}, {"sha256", sha256File(file.u8string())},
                                     {"bytes", std::filesystem::file_size(file)}};
    }
    {
        const auto file = modelDir / "rgb.onnx";
        writeBinary(file, buildRgbOnnx(640));
        manifest["graphs"]["rgb"] = {{"file", "rgb.onnx"}, {"sha256", sha256File(file.u8string())},
                                     {"bytes", std::filesystem::file_size(file)}};
    }
#if defined(__APPLE__)
    if (CoreMLGraph::available()) {
        const auto compileFromMlmodel = [&](const std::string& stem, const std::vector<uint8_t>& bytes) {
            const auto mlmodelPath = modelDir / (stem + ".mlmodel");
            writeBinary(mlmodelPath, bytes);
            const std::string cmd = "xcrun coremlcompiler compile \"" + mlmodelPath.string() + "\" \"" + modelDir.string() + "\" >/dev/null 2>&1";
            require(std::system(cmd.c_str()) == 0, "xcrun coremlcompiler failed to compile synthetic rgb.mlmodel");
            std::filesystem::remove(mlmodelPath);
            return modelDir / (stem + ".mlmodelc");
        };
        const auto rgbBytes = buildGpuScheduledRgbMlModel(640);
        const auto rawCompiled = compileFromMlmodel("raw", rgbBytes);
        const auto rgbCompiled = compileFromMlmodel("rgb", rgbBytes);
        manifest["coreml"] = {
            {"format", "mlmodelc"},
            {"precision", "float32"},
            {"raw", coremlManifestEntry(rawCompiled)},
            {"rgb", coremlManifestEntry(rgbCompiled)}
        };
    }
#endif
    std::ofstream(modelDir / "manifest.json", std::ios::binary) << manifest.dump();
}

} // namespace

int main(int argc, char** argv) {
    namespace fs = std::filesystem;
    fs::path root;
    bool created = false;
    try {
        require(argc == 3, "requires DNG fixture path and temporary directory path");
        const fs::path dngPath = fs::u8path(argv[1]);
        root = fs::u8path(argv[2]);
        fs::remove_all(root);
        require(fs::create_directories(root), "cannot create temporary root");
        created = true;

        const fs::path modelDir = root / "model";
        const fs::path cacheDir = root / "cache";
        createSyntheticPackage(modelDir);

        // 1. End-to-end Pipeline::process residency check (SceneRGB cache + DNG fixture).
        {
            using namespace sony2fuji;
            using namespace sony2fuji::ai;
#ifdef _WIN32
            constexpr auto aiPref = AiBackendPreference::DirectML;
            constexpr auto backend = Backend::DirectML;
            bool hasDirectMLHardware = true;
            try { findDirectMLAdapter(); } catch (const std::runtime_error&) { hasDirectMLHardware = false; }
#else
            constexpr auto aiPref = AiBackendPreference::CoreML;
            constexpr auto backend = Backend::CoreML;
#endif
            require(AISession::totalResidentBytes() == 0,
                    "unexpected AI resident bytes before Pipeline::process test");
            Pipeline pipeline;
            AiDenoiseConfig aiCfg;
            aiCfg.enabled = true;
            aiCfg.backend = aiPref;
            aiCfg.modelDirectory = modelDir.u8string();
            aiCfg.cacheDirectory = cacheDir.u8string();
            require(pipeline.setAiDenoise(aiCfg) == RenderStatus::Ok, "Pipeline::setAiDenoise failed");

            RAWProcessor decoder;
            ImageData source;
            RAWProcessOptions decOpts;
            decOpts.legacySonyCrop = true;
            require(decoder.loadFile(dngPath.u8string()) == ErrorCode::Success &&
                    decoder.process(decOpts, source) == ErrorCode::Success,
                    "failed to decode DNG fixture");
            const auto package = loadModelPackage(modelDir.u8string());
            const auto fullIdentity = package.digest + ":" + NetworkGraph::runtimeVersion(backend);
            const auto modelDigest = sha256Bytes(fullIdentity.data(), fullIdentity.size());
            const auto rawKey = rawCacheKey(dngPath.u8string(), modelDigest, static_cast<int>(backend), decOpts.legacySonyCrop);
            const auto sceneKey = sceneRGBCacheKey(rawKey, decOpts);
            std::vector<float> zero(source.pixels.size() * 3, 0.0f);
            DenoiseCache(cacheDir.u8string()).store(
                sceneKey, CacheKind::SceneRGB, source.width, source.height, zero.data(), zero.size(), {}, "test-identity");

            RenderParams previewParams;
            previewParams.inputType = RenderInputType::Raw;
            previewParams.inputPath = dngPath.u8string();
            previewParams.wbMode = RenderWhiteBalanceMode::Camera;
            previewParams.outputTarget = RenderOutputTarget::Buffer;
            previewParams.intent = RenderIntent::Preview;
            OwnedPixelBuffer previewOut;

            RenderParams exportParams = previewParams;
            exportParams.intent = RenderIntent::Final;
            OwnedPixelBuffer exportOut;

#ifdef _WIN32
            if (!hasDirectMLHardware) {
                require(pipeline.process(previewParams, &previewOut) == RenderStatus::ProcessingError,
                        "Pipeline::process preview without DirectML hardware did not fail with ProcessingError");
                require(AISession::totalResidentBytes() == 0,
                        "Pipeline::process preview retained AI result resident without DirectML hardware");
                require(pipeline.process(exportParams, &exportOut) == RenderStatus::ProcessingError,
                        "Pipeline::process export without DirectML hardware did not fail with ProcessingError");
                require(AISession::totalResidentBytes() == 0,
                        "Pipeline::process export retained AI result resident without DirectML hardware");
            } else
#endif
            {
                require(pipeline.process(previewParams, &previewOut) == RenderStatus::Ok,
                        "Pipeline::process preview with SceneRGB cache failed");
                require(AISession::totalResidentBytes() == 0,
                        "Pipeline::process preview retained AI result resident in AISession");
                require(pipeline.process(exportParams, &exportOut) == RenderStatus::Ok,
                        "Pipeline::process export with SceneRGB cache failed");
                require(AISession::totalResidentBytes() == 0,
                        "Pipeline::process export retained AI result resident in AISession");
            }
        }

        // 2. prepare() must release stale loaded_ on entry (before Phase::Loading 0/1 callback returns).
        {
            using namespace sony2fuji;
            using namespace sony2fuji::ai;
#ifdef _WIN32
            constexpr auto backend = Backend::DirectML;
#else
            constexpr auto backend = Backend::CoreML;
#endif
            AISession session([](Backend) { return std::string("test-runtime-mem"); });
            session.enabled = true;
            session.configure(modelDir.u8string(), cacheDir.u8string(), backend);
            const auto package = loadModelPackage(modelDir.u8string());
            const auto identity = package.digest + ":test-runtime-mem";
            const auto modelDigest = sha256Bytes(identity.data(), identity.size());
            RAWProcessOptions opts;
            opts.legacySonyCrop = true;
            const auto rawKey = rawCacheKey(dngPath.u8string(), modelDigest, static_cast<int>(backend), opts.legacySonyCrop);

            RAWProcessor decoder;
            ImageData decoded;
            require(decoder.loadFile(dngPath.u8string()) == ErrorCode::Success &&
                    decoder.process(opts, decoded) == ErrorCode::Success,
                    "failed to decode DNG for prepare residency test");
            std::vector<float> zero(decoded.pixels.size() * 3, 0.0f);
            DenoiseCache(cacheDir.u8string()).store(
                sceneRGBCacheKey(rawKey, opts), CacheKind::SceneRGB, decoded.width, decoded.height,
                zero.data(), zero.size(), {}, "test-identity");

            const auto& loaded = session.result(dngPath.u8string(), opts, nullptr);
            require(!loaded.scene.values.empty() && session.residentBytes() > 0,
                    "AISession::result did not populate residentBytes()");

            bool observedZeroAtPrepareEntry = false;
            const auto report = session.prepare(dngPath.u8string(), opts, [&](Phase phase, size_t done, size_t) {
                if (phase == Phase::Loading && done == 0) {
                    observedZeroAtPrepareEntry = (session.residentBytes() == 0);
                }
                return true;
            });
            require(report.rgbCacheHit && observedZeroAtPrepareEntry && session.residentBytes() == 0,
                    "AISession::prepare did not release stale resident result on entry");
        }

        // 3. Large 4096x4096 (16.77MP) Bayer takeResult() peak RSS & release gate.
        {
            using namespace sony2fuji;
            using namespace sony2fuji::ai;
#ifdef _WIN32
            constexpr auto backend = Backend::DirectML;
            constexpr const char* producer = "DirectML";
#else
            constexpr auto backend = Backend::CoreML;
            constexpr const char* producer = "CoreML";
#endif
            constexpr int kWidth = 4096;
            constexpr int kHeight = 4096;
            constexpr size_t kPixels = static_cast<size_t>(kWidth) * static_cast<size_t>(kHeight);
            constexpr uint64_t kRawBytes = kPixels * sizeof(float); // 64 MiB
            constexpr uint64_t kRgbBytes = kPixels * sizeof(RGB);   // 192 MiB
            constexpr uint64_t kMiB = 1024ULL * 1024ULL;

            const fs::path largeSource = root / "large_4096.raw";
            { std::ofstream out(largeSource, std::ios::binary); out << "4096x4096 synthetic raw"; }

            AISession session([](Backend) { return std::string("test-runtime-4k"); });
            session.enabled = true;
            session.configure(modelDir.u8string(), cacheDir.u8string(), backend);
            const auto package = loadModelPackage(modelDir.u8string());
            const auto identity = package.digest + ":test-runtime-4k";
            const auto modelDigest = sha256Bytes(identity.data(), identity.size());
            RAWProcessOptions opts;
            const auto rawKey = rawCacheKey(largeSource.u8string(), modelDigest, static_cast<int>(backend), opts.legacySonyCrop);
            const auto rgbKey = rgbCacheKey(rawKey, opts);

            const std::string rawPayload = writeStreamedCacheFile(
                cacheDir, rawKey, CacheKind::Raw, kWidth, kHeight, {}, producer);
            writeStreamedCacheFile(
                cacheDir, rgbKey, CacheKind::RGB, kWidth, kHeight, rawPayload, producer);

            RAWBayerSource metadata;
            metadata.width = kWidth;
            metadata.height = kHeight;

            const uint64_t baselineRss = peakRssBytes();
#if defined(__APPLE__)
            const uint64_t baselineHeap = appleHeapInUseBytes();
#endif
            {
                auto res = session.takeResult(largeSource.u8string(), opts, &metadata);
                require(session.residentBytes() == 0,
                        "AISession::takeResult retained bytes inside AISession");
                require(res.bayer.width == kWidth && res.bayer.height == kHeight &&
                        res.bayer.normalizedMosaic.size() == kPixels &&
                        res.bayer.cameraCorrection.size() == kPixels,
                        "AISession::takeResult returned wrong 16.77MP Bayer dimensions");

                const uint64_t postLoadRss = peakRssBytes();
                const uint64_t rssDelta = postLoadRss > baselineRss ? (postLoadRss - baselineRss) : 0;
                const uint64_t budget = kRawBytes + kRgbBytes + 64 * kMiB; // 256 MiB + 64 MiB = 320 MiB
                std::cout << "16.77MP takeResult Bayer: baseline_rss=" << baselineRss
                          << " post_rss=" << postLoadRss
                          << " rss_delta_mib=" << (double(rssDelta) / double(kMiB))
                          << " budget_mib=" << (double(budget) / double(kMiB)) << '\n';
                require(rssDelta <= budget,
                        "AISession::takeResult exceeded 16P + 64 MiB peak RSS budget (double allocation regression)");
#if defined(__APPLE__)
                const uint64_t postHeap = appleHeapInUseBytes();
                const uint64_t heapDelta = postHeap > baselineHeap ? (postHeap - baselineHeap) : 0;
                std::cout << "16.77MP takeResult apple_heap_delta_mib="
                          << (double(heapDelta) / double(kMiB)) << '\n';
                require(heapDelta <= kRawBytes + kRgbBytes + 16 * kMiB,
                        "AISession::takeResult exceeded Apple heap budget");
#endif
            }
#if defined(__APPLE__)
            const uint64_t freedHeap = appleHeapInUseBytes();
            const uint64_t residualHeap = freedHeap > baselineHeap ? (freedHeap - baselineHeap) : 0;
            std::cout << "16.77MP takeResult after drop apple_heap_residual_mib="
                      << (double(residualHeap) / double(kMiB)) << '\n';
            require(residualHeap < 4 * kMiB,
                    "16.77MP takeResult memory remained resident after caller dropped PreparedDenoise");
#endif
        }

        // 4. Deterministic Bayer RGB cache-miss AISession::prepare() regression (#546).
        // Exercises `useBayer == true` with `.rawcache` present and `.rgbcache` missing so
        // `denoiseRgb` runs and `cache.store(rgbKey, CacheKind::RGB, correction.width, correction.height, ...)`
        // executes after `source = {};` clears `source.width`/`source.height`.
        {
            using namespace sony2fuji;
            using namespace sony2fuji::ai;
            constexpr int kBayerW = 512;
            constexpr int kBayerH = 512;
            const fs::path bayerDng = root / "bayer_prepare.dng";
            const fs::path bayerModelDir = root / "bayer_model";
            const fs::path bayerCacheDir = root / "bayer_cache";
            writeNoisyBayerDng(bayerDng, kBayerW, kBayerH);
            createBayerExecutablePackage(bayerModelDir);

#ifdef _WIN32
            constexpr auto backend = Backend::DirectML;
            bool gpuAvailable = true;
            try { findDirectMLAdapter(); } catch (const std::runtime_error&) { gpuAvailable = false; }
#else
            constexpr auto backend = Backend::CoreML;
            const bool gpuAvailable = CoreMLGraph::available();
#endif
            AISession session;
            session.enabled = true;
            session.configure(bayerModelDir.u8string(), bayerCacheDir.u8string(), backend);
            const auto package = loadModelPackage(bayerModelDir.u8string());
            const auto fullIdentity = package.digest + ":" + NetworkGraph::runtimeVersion(backend);
            const auto modelDigest = sha256Bytes(fullIdentity.data(), fullIdentity.size());
            RAWProcessOptions opts;
            const auto rawKey = rawCacheKey(bayerDng.u8string(), modelDigest, static_cast<int>(backend), opts.legacySonyCrop);
            const auto rgbKey = rgbCacheKey(rawKey, opts);

            std::vector<float> rawMosaic(static_cast<size_t>(kBayerW) * kBayerH, 0.2f);
            std::string rawPayload;
            DenoiseCache(bayerCacheDir.u8string()).store(
                rawKey, CacheKind::Raw, kBayerW, kBayerH, rawMosaic.data(), rawMosaic.size(), {}, "test-raw", {}, &rawPayload);

            if (gpuAvailable) {
                const auto report = session.prepare(bayerDng.u8string(), opts, {});
                require(report.route == "Bayer", "expected Bayer route on noisy Bayer DNG");
                require(report.rawCacheHit && !report.rgbCacheHit,
                        "expected .rawcache hit and .rgbcache miss to exercise Bayer RGB store");
                require(session.residentBytes() == 0 && AISession::totalResidentBytes() == 0,
                        "Bayer prepare retained resident bytes");
                require(DenoiseCache(bayerCacheDir.u8string()).verify(rgbKey, CacheKind::RGB, kBayerW, kBayerH, rawPayload),
                        "Bayer RGB cache miss did not persist valid .rgbcache");

                RAWBayerSource bayerMeta;
                bayerMeta.width = kBayerW;
                bayerMeta.height = kBayerH;
                const auto loaded = session.takeResult(bayerDng.u8string(), opts, &bayerMeta);
                require(loaded.bayer.width == kBayerW && loaded.bayer.height == kBayerH &&
                        loaded.bayer.cameraCorrection.size() == static_cast<size_t>(kBayerW) * kBayerH,
                        "Bayer takeResult after RGB cache-miss prepare returned wrong dimensions");
                require(session.residentBytes() == 0 && AISession::totalResidentBytes() == 0,
                        "Bayer takeResult retained resident bytes");
                std::cout << "PASS Bayer RGB cache-miss prepare executed on hardware GPU\n";
            } else {
                bool rejected = false;
                try {
                    session.prepare(bayerDng.u8string(), opts, {});
                } catch (const std::runtime_error&) {
                    rejected = true;
                }
                require(rejected, "Bayer RGB cache miss succeeded without a hardware GPU");
                require(!DenoiseCache(bayerCacheDir.u8string()).verify(rgbKey, CacheKind::RGB, kBayerW, kBayerH, rawPayload),
                        "Bayer RGB cache miss wrote .rgbcache without a hardware GPU");
                require(session.residentBytes() == 0 && AISession::totalResidentBytes() == 0,
                        "failed Bayer prepare retained resident bytes");
            }
        }

        fs::remove_all(root);
        std::cout << "PASS AI session residency release, prepare cleanup, 16.77MP Bayer peak RSS, and Bayer RGB cache-miss prepare\n";
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
