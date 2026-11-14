#pragma once

#include <GLES3/gl31.h>
#include <EGL/egl.h>
#include <android/log.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>
#ifdef _WIN32
#include <process.h>
#else
#include <unistd.h>
#endif

namespace rawlabtest {

struct GlesVmConfig {
    int maxComputeWorkGroupCount = 65535;
    int64_t maxSsboBytes = 64 * 1024 * 1024;
    int maxTexture3DSize = 256;
};

struct GlesVmStats {
    size_t genBufferCalls = 0;
    size_t deleteBufferCalls = 0;
    size_t bufferDataCalls = 0;
    size_t bufferSubDataCalls = 0;
    size_t ssboBufferSubDataCalls = 0;
    size_t deleteBuffersWithoutContextCalls = 0;
    size_t totalBufferDataBytes = 0;
    size_t maxBufferDataBytes = 0;
    size_t totalBufferSubDataBytes = 0;
    size_t dispatchCalls = 0;
    size_t texImage3DCalls = 0;
    GLint lastTexUnpackAlignment = 0;
    GLint lastTexInternalFormat = 0;
    GLenum lastTexFormat = 0;
    GLenum lastTexType = 0;
    GLint lastTexMinFilter = 0;
    GLint lastTexMagFilter = 0;
    GLint lastTexWrapS = 0;
    GLint lastTexWrapT = 0;
    GLint lastTexWrapR = 0;

    void resetCounters() {
        genBufferCalls = 0;
        deleteBufferCalls = 0;
        bufferDataCalls = 0;
        bufferSubDataCalls = 0;
        ssboBufferSubDataCalls = 0;
        deleteBuffersWithoutContextCalls = 0;
        totalBufferDataBytes = 0;
        maxBufferDataBytes = 0;
        totalBufferSubDataBytes = 0;
        dispatchCalls = 0;
        texImage3DCalls = 0;
        lastTexUnpackAlignment = 0;
        lastTexInternalFormat = 0;
        lastTexFormat = 0;
        lastTexType = 0;
        lastTexMinFilter = 0;
        lastTexMagFilter = 0;
        lastTexWrapS = 0;
        lastTexWrapT = 0;
        lastTexWrapR = 0;
    }
};

GlesVmConfig& glesVmConfig();
GlesVmStats& glesVmStats();
void resetGlesVmState();
size_t glesVmLiveBufferBytes();

namespace spv_vm {

inline float bitsToFloat(uint32_t w) {
    float f;
    std::memcpy(&f, &w, sizeof(f));
    return f;
}

inline uint32_t floatToBits(float f) {
    uint32_t w;
    std::memcpy(&w, &f, sizeof(w));
    return w;
}

inline int32_t bitsToInt(uint32_t w) {
    int32_t i;
    std::memcpy(&i, &w, sizeof(i));
    return i;
}

inline uint32_t intToBits(int32_t i) {
    uint32_t w;
    std::memcpy(&w, &i, sizeof(w));
    return w;
}

namespace op {
constexpr uint16_t Source = 3;
constexpr uint16_t Name = 5;
constexpr uint16_t MemberName = 6;
constexpr uint16_t ExtInstImport = 11;
constexpr uint16_t ExtInst = 12;
constexpr uint16_t MemoryModel = 14;
constexpr uint16_t EntryPoint = 15;
constexpr uint16_t ExecutionMode = 16;
constexpr uint16_t Capability = 17;
constexpr uint16_t TypeVoid = 19;
constexpr uint16_t TypeBool = 20;
constexpr uint16_t TypeInt = 21;
constexpr uint16_t TypeFloat = 22;
constexpr uint16_t TypeVector = 23;
constexpr uint16_t TypeMatrix = 24;
constexpr uint16_t TypeImage = 25;
constexpr uint16_t TypeSampledImage = 27;
constexpr uint16_t TypeArray = 28;
constexpr uint16_t TypeRuntimeArray = 29;
constexpr uint16_t TypeStruct = 30;
constexpr uint16_t TypePointer = 32;
constexpr uint16_t TypeFunction = 33;
constexpr uint16_t ConstantTrue = 41;
constexpr uint16_t ConstantFalse = 42;
constexpr uint16_t Constant = 43;
constexpr uint16_t ConstantComposite = 44;
constexpr uint16_t Function = 54;
constexpr uint16_t FunctionParameter = 55;
constexpr uint16_t FunctionEnd = 56;
constexpr uint16_t FunctionCall = 57;
constexpr uint16_t Variable = 59;
constexpr uint16_t Load = 61;
constexpr uint16_t Store = 62;
constexpr uint16_t AccessChain = 65;
constexpr uint16_t Decorate = 71;
constexpr uint16_t MemberDecorate = 72;
constexpr uint16_t VectorShuffle = 79;
constexpr uint16_t CompositeConstruct = 80;
constexpr uint16_t CompositeExtract = 81;
constexpr uint16_t ImageFetch = 95;
constexpr uint16_t Image = 100;
constexpr uint16_t ConvertFToU = 109;
constexpr uint16_t ConvertFToS = 110;
constexpr uint16_t ConvertSToF = 111;
constexpr uint16_t ConvertUToF = 112;
constexpr uint16_t Bitcast = 124;
constexpr uint16_t SNegate = 126;
constexpr uint16_t FNegate = 127;
constexpr uint16_t IAdd = 128;
constexpr uint16_t FAdd = 129;
constexpr uint16_t ISub = 130;
constexpr uint16_t FSub = 131;
constexpr uint16_t IMul = 132;
constexpr uint16_t FMul = 133;
constexpr uint16_t UDiv = 134;
constexpr uint16_t SDiv = 135;
constexpr uint16_t FDiv = 136;
constexpr uint16_t UMod = 137;
constexpr uint16_t SMod = 139;
constexpr uint16_t FMod = 141;
constexpr uint16_t VectorTimesScalar = 142;
constexpr uint16_t MatrixTimesVector = 145;
constexpr uint16_t Dot = 148;
constexpr uint16_t All = 155;
constexpr uint16_t LogicalOr = 166;
constexpr uint16_t LogicalAnd = 167;
constexpr uint16_t LogicalNot = 168;
constexpr uint16_t Select = 169;
constexpr uint16_t IEqual = 170;
constexpr uint16_t INotEqual = 171;
constexpr uint16_t UGreaterThan = 172;
constexpr uint16_t SGreaterThan = 173;
constexpr uint16_t UGreaterThanEqual = 174;
constexpr uint16_t SGreaterThanEqual = 175;
constexpr uint16_t ULessThan = 176;
constexpr uint16_t SLessThan = 177;
constexpr uint16_t SLessThanEqual = 179;
constexpr uint16_t FOrdEqual = 180;
constexpr uint16_t FUnordNotEqual = 183;
constexpr uint16_t FOrdLessThan = 184;
constexpr uint16_t FOrdGreaterThan = 186;
constexpr uint16_t FOrdLessThanEqual = 188;
constexpr uint16_t FOrdGreaterThanEqual = 190;
constexpr uint16_t ShiftRightLogical = 194;
constexpr uint16_t ShiftLeftLogical = 196;
constexpr uint16_t BitwiseOr = 197;
constexpr uint16_t BitwiseXor = 198;
constexpr uint16_t BitwiseAnd = 199;
constexpr uint16_t Phi = 245;
constexpr uint16_t LoopMerge = 246;
constexpr uint16_t SelectionMerge = 247;
constexpr uint16_t Label = 248;
constexpr uint16_t Branch = 249;
constexpr uint16_t BranchConditional = 250;
constexpr uint16_t Return = 253;
constexpr uint16_t ReturnValue = 254;
} // namespace op

namespace dec {
constexpr uint32_t BufferBlock = 3;
constexpr uint32_t ArrayStride = 6;
constexpr uint32_t BuiltIn = 11;
constexpr uint32_t Binding = 33;
constexpr uint32_t Offset = 35;
} // namespace dec

namespace sc {
constexpr uint32_t UniformConstant = 0;
constexpr uint32_t Input = 1;
constexpr uint32_t Uniform = 2;
constexpr uint32_t Function = 7;
constexpr uint32_t StorageBuffer = 12;
} // namespace sc

namespace glsl450 {
constexpr uint32_t FAbs = 4;
constexpr uint32_t FSign = 6;
constexpr uint32_t Floor = 8;
constexpr uint32_t Pow = 26;
constexpr uint32_t Log = 28;
constexpr uint32_t Exp2 = 29;
constexpr uint32_t Sqrt = 31;
constexpr uint32_t FMin = 37;
constexpr uint32_t UMin = 38;
constexpr uint32_t SMin = 39;
constexpr uint32_t FMax = 40;
constexpr uint32_t FClamp = 43;
constexpr uint32_t SClamp = 45;
constexpr uint32_t FMix = 46;
} // namespace glsl450

struct Val {
    uint32_t type = 0;
    std::array<uint32_t, 16> w{};
    uint8_t n = 0;
};

struct TypeInfo {
    enum class Kind { Void, Bool, Int, Float, Vector, Matrix, Image, SampledImage, Array, RuntimeArray, Struct, Pointer, Function };
    Kind kind = Kind::Void;
    uint32_t width = 32;
    bool isSigned = false;
    uint32_t elemType = 0;
    uint32_t count = 1;
    uint32_t storageClass = 0;
    std::vector<uint32_t> members;
    std::vector<uint32_t> memberOffsets;
    uint32_t arrayStride = 0;
    bool hasBufferBlock = false;
};

struct GlobalVar {
    uint32_t id = 0;
    uint32_t pointeeType = 0;
    uint32_t storageClass = 0;
    uint32_t binding = 0;
    bool isSsbo = false;
    bool hasBuiltIn = false;
    uint32_t builtIn = 0;
    std::string name;
};

struct FuncInfo {
    uint32_t id = 0;
    std::vector<uint32_t> params;
    std::unordered_map<uint32_t, size_t> labelToWord;
    size_t bodyStart = 0;
    size_t endWord = 0;
};

struct Texture3DView {
    int width = 0;
    int height = 0;
    int depth = 0;
    const std::vector<float>* data = nullptr;
};

struct RuntimeBindings {
    const std::unordered_map<std::string, std::vector<uint32_t>>* uniforms = nullptr;
    std::array<std::vector<uint8_t>*, 8> ssbo{};
    std::array<std::vector<uint8_t>*, 4> ubo{};
    Texture3DView tex3d;
};

class Module {
public:
    uint32_t entryPoint = 0;
    std::array<uint32_t, 3> localSize{1, 1, 1};
    std::vector<uint32_t> words;
    std::vector<TypeInfo> types;
    std::vector<Val> constants;
    std::vector<bool> hasConstant;
    std::vector<std::string> names;
    std::vector<GlobalVar> globals;
    std::unordered_map<uint32_t, size_t> globalById;
    std::unordered_map<uint32_t, FuncInfo> functions;

    uint32_t typeWords(uint32_t tid) const {
        if (tid >= types.size()) throw std::runtime_error("typeWords OOB tid=" + std::to_string(tid) + "/" + std::to_string(types.size()));
        const auto& t = types[tid];
        switch (t.kind) {
            case TypeInfo::Kind::Bool:
            case TypeInfo::Kind::Int:
            case TypeInfo::Kind::Float:
            case TypeInfo::Kind::Image:
            case TypeInfo::Kind::SampledImage:
                return 1;
            case TypeInfo::Kind::Vector:
                return t.count;
            case TypeInfo::Kind::Matrix:
                return t.count * typeWords(t.elemType);
            case TypeInfo::Kind::Array:
                return t.count * typeWords(t.elemType);
            case TypeInfo::Kind::Struct: {
                uint32_t total = 0;
                for (uint32_t m : t.members) total += typeWords(m);
                return total;
            }
            default:
                return 0;
        }
    }

    static Module parse(std::vector<uint32_t> spv) {
        if (spv.size() < 5 || spv[0] != 0x07230203u) {
            throw std::runtime_error("Invalid SPIR-V magic/header");
        }
        Module m;
        m.words = std::move(spv);
        const uint32_t bound = m.words[3];
        m.types.resize(bound);
        m.constants.resize(bound);
        m.hasConstant.assign(bound, false);
        m.names.resize(bound);

        std::vector<uint32_t> decBinding(bound, 0);
        std::vector<uint32_t> decBuiltIn(bound, 0);
        std::vector<bool> hasBuiltIn(bound, false);
        std::vector<uint32_t> decArrayStride(bound, 0);
        std::vector<bool> hasBufferBlock(bound, false);
        std::unordered_map<uint64_t, uint32_t> memberOffsets;

        FuncInfo* currentFunc = nullptr;
        for (size_t pc = 5; pc < m.words.size();) {
            const uint32_t hdr = m.words[pc];
            const uint16_t wc = static_cast<uint16_t>(hdr >> 16);
            const uint16_t opcode = static_cast<uint16_t>(hdr & 0xFFFFu);
            if (wc == 0 || pc + wc > m.words.size()) throw std::runtime_error("Truncated SPIR-V instruction");

            if (!currentFunc) {
                switch (opcode) {
                    case op::Name: {
                        const uint32_t tid = m.words[pc + 1];
                        if (tid < bound) {
                            const char* str = reinterpret_cast<const char*>(&m.words[pc + 2]);
                            m.names[tid] = str;
                        }
                        break;
                    }
                    case op::Decorate: {
                        const uint32_t tid = m.words[pc + 1];
                        const uint32_t d = m.words[pc + 2];
                        if (tid < bound) {
                            if (d == dec::BufferBlock) hasBufferBlock[tid] = true;
                            else if (d == dec::ArrayStride && wc >= 4) decArrayStride[tid] = m.words[pc + 3];
                            else if (d == dec::Binding && wc >= 4) decBinding[tid] = m.words[pc + 3];
                            else if (d == dec::BuiltIn && wc >= 4) { hasBuiltIn[tid] = true; decBuiltIn[tid] = m.words[pc + 3]; }
                        }
                        break;
                    }
                    case op::MemberDecorate: {
                        if (wc >= 5 && m.words[pc + 3] == dec::Offset) {
                            const uint64_t key = (uint64_t(m.words[pc + 1]) << 32) | m.words[pc + 2];
                            memberOffsets[key] = m.words[pc + 4];
                        }
                        break;
                    }
                    case op::EntryPoint:
                        m.entryPoint = m.words[pc + 2];
                        break;
                    case op::ExecutionMode:
                        if (m.words[pc + 2] == 17 && wc >= 6) {
                            m.localSize = {m.words[pc + 3], m.words[pc + 4], m.words[pc + 5]};
                        }
                        break;
                    case op::TypeVoid:
                        m.types[m.words[pc + 1]].kind = TypeInfo::Kind::Void;
                        break;
                    case op::TypeBool:
                        m.types[m.words[pc + 1]].kind = TypeInfo::Kind::Bool;
                        break;
                    case op::TypeInt: {
                        auto& t = m.types[m.words[pc + 1]];
                        t.kind = TypeInfo::Kind::Int;
                        t.width = m.words[pc + 2];
                        t.isSigned = m.words[pc + 3] != 0;
                        break;
                    }
                    case op::TypeFloat: {
                        auto& t = m.types[m.words[pc + 1]];
                        t.kind = TypeInfo::Kind::Float;
                        t.width = m.words[pc + 2];
                        break;
                    }
                    case op::TypeVector: {
                        auto& t = m.types[m.words[pc + 1]];
                        t.kind = TypeInfo::Kind::Vector;
                        t.elemType = m.words[pc + 2];
                        t.count = m.words[pc + 3];
                        break;
                    }
                    case op::TypeMatrix: {
                        auto& t = m.types[m.words[pc + 1]];
                        t.kind = TypeInfo::Kind::Matrix;
                        t.elemType = m.words[pc + 2];
                        t.count = m.words[pc + 3];
                        break;
                    }
                    case op::TypeImage:
                        m.types[m.words[pc + 1]].kind = TypeInfo::Kind::Image;
                        break;
                    case op::TypeSampledImage:
                        m.types[m.words[pc + 1]].kind = TypeInfo::Kind::SampledImage;
                        m.types[m.words[pc + 1]].elemType = m.words[pc + 2];
                        break;
                    case op::TypeArray: {
                        const uint32_t tid = m.words[pc + 1];
                        auto& t = m.types[tid];
                        t.kind = TypeInfo::Kind::Array;
                        t.elemType = m.words[pc + 2];
                        t.count = m.constants.at(m.words[pc + 3]).w[0];
                        t.arrayStride = decArrayStride[tid];
                        break;
                    }
                    case op::TypeRuntimeArray: {
                        const uint32_t tid = m.words[pc + 1];
                        auto& t = m.types[tid];
                        t.kind = TypeInfo::Kind::RuntimeArray;
                        t.elemType = m.words[pc + 2];
                        t.arrayStride = decArrayStride[tid];
                        break;
                    }
                    case op::TypeStruct: {
                        const uint32_t tid = m.words[pc + 1];
                        auto& t = m.types[tid];
                        t.kind = TypeInfo::Kind::Struct;
                        t.hasBufferBlock = hasBufferBlock[tid];
                        for (uint16_t i = 2; i < wc; ++i) {
                            t.members.push_back(m.words[pc + i]);
                            auto it = memberOffsets.find((uint64_t(tid) << 32) | (i - 2));
                            t.memberOffsets.push_back(it != memberOffsets.end() ? it->second : UINT32_MAX);
                        }
                        break;
                    }
                    case op::TypePointer: {
                        auto& t = m.types[m.words[pc + 1]];
                        t.kind = TypeInfo::Kind::Pointer;
                        t.storageClass = m.words[pc + 2];
                        t.elemType = m.words[pc + 3];
                        break;
                    }
                    case op::TypeFunction:
                        m.types[m.words[pc + 1]].kind = TypeInfo::Kind::Function;
                        break;
                    case op::ConstantTrue: {
                        const uint32_t id = m.words[pc + 2];
                        m.constants[id] = Val{m.words[pc + 1], {1}, 1};
                        m.hasConstant[id] = true;
                        break;
                    }
                    case op::ConstantFalse: {
                        const uint32_t id = m.words[pc + 2];
                        m.constants[id] = Val{m.words[pc + 1], {0}, 1};
                        m.hasConstant[id] = true;
                        break;
                    }
                    case op::Constant: {
                        const uint32_t id = m.words[pc + 2];
                        Val v;
                        v.type = m.words[pc + 1];
                        v.n = 1;
                        v.w[0] = m.words[pc + 3];
                        m.constants[id] = v;
                        m.hasConstant[id] = true;
                        break;
                    }
                    case op::ConstantComposite: {
                        const uint32_t id = m.words[pc + 2];
                        Val v;
                        v.type = m.words[pc + 1];
                        for (uint16_t i = 3; i < wc; ++i) {
                            const Val& c = m.constants.at(m.words[pc + i]);
                            for (uint8_t k = 0; k < c.n; ++k) v.w[v.n++] = c.w[k];
                        }
                        m.constants[id] = v;
                        m.hasConstant[id] = true;
                        break;
                    }
                    case op::Variable: {
                        GlobalVar g;
                        g.id = m.words[pc + 2];
                        const auto& ptrT = m.types.at(m.words[pc + 1]);
                        g.pointeeType = ptrT.elemType;
                        g.storageClass = m.words[pc + 3];
                        g.binding = decBinding[g.id];
                        g.hasBuiltIn = hasBuiltIn[g.id];
                        g.builtIn = decBuiltIn[g.id];
                        g.name = m.names[g.id];
                        const auto& pt = m.types.at(g.pointeeType);
                        g.isSsbo = (g.storageClass == sc::StorageBuffer) ||
                                   (g.storageClass == sc::Uniform && pt.hasBufferBlock);
                        m.globalById[g.id] = m.globals.size();
                        m.globals.push_back(std::move(g));
                        break;
                    }
                    case op::Function: {
                        const uint32_t fid = m.words[pc + 2];
                        auto& fn = m.functions[fid];
                        fn.id = fid;
                        fn.bodyStart = pc + wc;
                        currentFunc = &fn;
                        break;
                    }
                    default:
                        break;
                }
            } else {
                if (opcode == op::FunctionParameter) {
                    currentFunc->params.push_back(m.words[pc + 2]);
                    currentFunc->bodyStart = pc + wc;
                } else if (opcode == op::Label) {
                    currentFunc->labelToWord[m.words[pc + 1]] = pc;
                } else if (opcode == op::FunctionEnd) {
                    currentFunc->endWord = pc;
                    currentFunc = nullptr;
                }
            }
            pc += wc;
        }
        return m;
    }

    void dispatch(GLuint groupsX, GLuint groupsY, GLuint groupsZ, RuntimeBindings& bindings) const {
        if (entryPoint == 0) throw std::runtime_error("SPIR-V module has no entry point");
        std::vector<Val> ssa(types.size());
        for (size_t id = 0; id < hasConstant.size(); ++id) {
            if (hasConstant[id]) ssa[id] = constants[id];
        }
        for (size_t gi = 0; gi < globals.size(); ++gi) {
            const auto& g = globals[gi];
            Val ptr;
            ptr.n = 4;
            ptr.w[0] = g.storageClass;
            ptr.w[1] = static_cast<uint32_t>(gi);
            ptr.w[2] = 0; // byteOffset
            ptr.w[3] = g.pointeeType;
            ssa[g.id] = ptr;
        }
        std::vector<std::vector<uint32_t>> locals;
        for (GLuint wz = 0; wz < groupsZ; ++wz) {
            for (GLuint wy = 0; wy < groupsY; ++wy) {
                for (GLuint wx = 0; wx < groupsX; ++wx) {
                    for (uint32_t lz = 0; lz < localSize[2]; ++lz) {
                        for (uint32_t ly = 0; ly < localSize[1]; ++ly) {
                            for (uint32_t lx = 0; lx < localSize[0]; ++lx) {
                                std::array<uint32_t, 3> gid{
                                    wx * localSize[0] + lx,
                                    wy * localSize[1] + ly,
                                    wz * localSize[2] + lz};
                                locals.clear();
                                runFunction(entryPoint, {}, gid, bindings, ssa, locals);
                            }
                        }
                    }
                }
            }
        }
    }

private:
    static int32_t sMod(int32_t a, int32_t b) {
        if (b == 0) return 0;
        int32_t r = a % b;
        if (r != 0 && ((r < 0) != (b < 0))) r += b;
        return r;
    }

    void stepAccessChain(Val& ptr, uint32_t idxWord) const {
        const uint32_t curTid = ptr.w[3];
        const auto& t = types.at(curTid);
        const uint32_t idx = idxWord;
        switch (t.kind) {
            case TypeInfo::Kind::Vector:
                ptr.w[2] += idx * 4u;
                ptr.w[3] = t.elemType;
                break;
            case TypeInfo::Kind::Matrix:
                ptr.w[2] += idx * typeWords(t.elemType) * 4u;
                ptr.w[3] = t.elemType;
                break;
            case TypeInfo::Kind::Array:
            case TypeInfo::Kind::RuntimeArray: {
                const uint32_t stride = t.arrayStride ? t.arrayStride : typeWords(t.elemType) * 4u;
                ptr.w[2] += idx * stride;
                ptr.w[3] = t.elemType;
                break;
            }
            case TypeInfo::Kind::Struct: {
                if (idx >= t.members.size()) throw std::runtime_error("Struct index out of bounds");
                uint32_t off = t.memberOffsets[idx];
                if (off == UINT32_MAX) {
                    off = 0;
                    for (uint32_t m = 0; m < idx; ++m) off += typeWords(t.members[m]) * 4u;
                }
                ptr.w[2] += off;
                ptr.w[3] = t.members[idx];
                break;
            }
            default:
                throw std::runtime_error("Unsupported AccessChain pointee type");
        }
    }

    Val loadPtr(const Val& ptr, uint32_t resultType, const std::array<uint32_t, 3>& gid,
                const RuntimeBindings& bindings, const std::vector<std::vector<uint32_t>>& locals) const {
        Val out;
        out.type = resultType;
        const uint32_t storage = ptr.w[0];
        const uint32_t slot = ptr.w[1];
        const uint32_t byteOff = ptr.w[2];
        const uint32_t wordOff = byteOff / 4u;
        const uint32_t nw = typeWords(resultType);
        out.n = static_cast<uint8_t>(std::max<uint32_t>(1, nw));

        if (storage == sc::Function) {
            if (slot >= locals.size()) throw std::runtime_error("loadPtr Function slot OOB");
            const auto& buf = locals[slot];
            for (uint32_t k = 0; k < out.n; ++k) out.w[k] = (wordOff + k < buf.size()) ? buf[wordOff + k] : 0u;
            return out;
        }
        if (slot >= globals.size()) throw std::runtime_error("loadPtr global slot OOB");
        const auto& g = globals[slot];
        if (storage == sc::Input) {
            if (g.hasBuiltIn && g.builtIn == 28) { // GlobalInvocationId
                for (uint32_t k = 0; k < out.n; ++k) out.w[k] = (wordOff + k < 3) ? gid[wordOff + k] : 0u;
                return out;
            }
        }
        if (storage == sc::UniformConstant) {
            if (g.pointeeType >= types.size()) throw std::runtime_error("loadPtr UniformConstant pointee OOB");
            const auto& pt = types[g.pointeeType];
            if (pt.kind == TypeInfo::Kind::SampledImage || pt.kind == TypeInfo::Kind::Image) {
                out.n = 1;
                out.w[0] = g.binding;
                return out;
            }
            if (bindings.uniforms) {
                auto it = bindings.uniforms->find(g.name);
                if (it != bindings.uniforms->end()) {
                    const auto& vec = it->second;
                    for (uint32_t k = 0; k < out.n; ++k) {
                        out.w[k] = (wordOff + k < vec.size()) ? vec[wordOff + k] : 0u;
                    }
                    return out;
                }
            }
            out.w.fill(0);
            return out;
        }
        const std::vector<uint8_t>* buf = g.isSsbo ? bindings.ssbo.at(g.binding) : bindings.ubo.at(g.binding);
        if (!buf) {
            out.w.fill(0);
            return out;
        }
        for (uint32_t k = 0; k < out.n; ++k) {
            const size_t off = size_t(byteOff) + size_t(k) * 4u;
            if (off + 4 <= buf->size()) {
                std::memcpy(&out.w[k], buf->data() + off, 4);
            } else {
                out.w[k] = 0;
            }
        }
        return out;
    }

    void storePtr(const Val& ptr, const Val& val, RuntimeBindings& bindings,
                  std::vector<std::vector<uint32_t>>& locals) const {
        const uint32_t storage = ptr.w[0];
        const uint32_t slot = ptr.w[1];
        const uint32_t byteOff = ptr.w[2];
        if (storage == sc::Function) {
            auto& buf = locals.at(slot);
            const uint32_t wordOff = byteOff / 4u;
            for (uint8_t k = 0; k < val.n; ++k) {
                if (wordOff + k < buf.size()) buf[wordOff + k] = val.w[k];
            }
            return;
        }
        const auto& g = globals.at(slot);
        if (g.isSsbo && bindings.ssbo.at(g.binding)) {
            auto* buf = bindings.ssbo.at(g.binding);
            for (uint8_t k = 0; k < val.n; ++k) {
                const size_t off = size_t(byteOff) + size_t(k) * 4u;
                if (off + 4 <= buf->size()) {
                    std::memcpy(buf->data() + off, &val.w[k], 4);
                }
            }
            return;
        }
        throw std::runtime_error("OpStore to read-only storage class");
    }

    Val runFunction(uint32_t funcId, const std::vector<Val>& args, const std::array<uint32_t, 3>& gid,
                    RuntimeBindings& bindings, std::vector<Val>& ssa,
                    std::vector<std::vector<uint32_t>>& locals) const {
        const auto& fn = functions.at(funcId);
        const size_t localsMark = locals.size();
        auto cleanup = [&]() { locals.resize(localsMark); };
        struct FrameGuard {
            decltype(cleanup)& fn;
            ~FrameGuard() { fn(); }
        } guard{cleanup};
        for (size_t i = 0; i < fn.params.size() && i < args.size(); ++i) ssa[fn.params[i]] = args[i];

        size_t pc = fn.bodyStart;
        uint32_t prevLabel = 0;
        uint32_t curLabel = 0;

        while (pc < fn.endWord) {
            const uint32_t hdr = words[pc];
            const uint16_t wc = static_cast<uint16_t>(hdr >> 16);
            const uint16_t opcode = static_cast<uint16_t>(hdr & 0xFFFFu);

            if (opcode == op::Label) {
                curLabel = words[pc + 1];
                pc += wc;
                // Commit all consecutive OpPhi instructions atomically before storing into ssa.
                std::vector<std::pair<uint32_t, Val>> phiUpdates;
                while (pc < fn.endWord && (words[pc] & 0xFFFFu) == op::Phi) {
                    const uint16_t pwc = static_cast<uint16_t>(words[pc] >> 16);
                    const uint32_t resType = words[pc + 1];
                    const uint32_t resId = words[pc + 2];
                    for (uint16_t k = 3; k + 1 < pwc; k += 2) {
                        if (words[pc + k + 1] == prevLabel) {
                            Val chosen = ssa[words[pc + k]];
                            chosen.type = resType;
                            phiUpdates.emplace_back(resId, chosen);
                            break;
                        }
                    }
                    pc += pwc;
                }
                for (const auto& kv : phiUpdates) ssa[kv.first] = kv.second;
                continue;
            }

            switch (opcode) {
                case op::Variable: {
                    const uint32_t ptrType = words[pc + 1];
                    const uint32_t id = words[pc + 2];
                    const uint32_t pointee = types.at(ptrType).elemType;
                    const uint32_t slot = static_cast<uint32_t>(locals.size());
                    locals.emplace_back(std::max<uint32_t>(1, typeWords(pointee)), 0u);
                    Val ptr;
                    ptr.type = ptrType;
                    ptr.n = 4;
                    ptr.w[0] = sc::Function;
                    ptr.w[1] = slot;
                    ptr.w[2] = 0;
                    ptr.w[3] = pointee;
                    ssa[id] = ptr;
                    break;
                }
                case op::AccessChain: {
                    const uint32_t resType = words[pc + 1];
                    const uint32_t resId = words[pc + 2];
                    Val ptr = ssa[words[pc + 3]];
                    ptr.type = resType;
                    for (uint16_t k = 4; k < wc; ++k) {
                        stepAccessChain(ptr, ssa[words[pc + k]].w[0]);
                    }
                    ssa[resId] = ptr;
                    break;
                }
                case op::Load: {
                    const uint32_t resType = words[pc + 1];
                    const uint32_t resId = words[pc + 2];
                    ssa[resId] = loadPtr(ssa[words[pc + 3]], resType, gid, bindings, locals);
                    break;
                }
                case op::Store:
                    storePtr(ssa[words[pc + 1]], ssa[words[pc + 2]], bindings, locals);
                    break;
                case op::CompositeConstruct: {
                    Val out;
                    out.type = words[pc + 1];
                    for (uint16_t k = 3; k < wc; ++k) {
                        const Val& opnd = ssa[words[pc + k]];
                        for (uint8_t j = 0; j < opnd.n; ++j) out.w[out.n++] = opnd.w[j];
                    }
                    ssa[words[pc + 2]] = out;
                    break;
                }
                case op::CompositeExtract: {
                    Val out;
                    out.type = words[pc + 1];
                    const Val& comp = ssa[words[pc + 3]];
                    const uint32_t idx = words[pc + 4];
                    const uint32_t tid = comp.type;
                    if (types[tid].kind == TypeInfo::Kind::Vector) {
                        out.n = 1;
                        out.w[0] = comp.w[idx];
                    } else if (types[tid].kind == TypeInfo::Kind::Matrix && wc == 5) {
                        const uint32_t rows = typeWords(types[tid].elemType);
                        out.n = static_cast<uint8_t>(rows);
                        for (uint8_t r = 0; r < out.n; ++r) out.w[r] = comp.w[idx * rows + r];
                    } else if (types[tid].kind == TypeInfo::Kind::Matrix && wc == 6) {
                        const uint32_t rows = typeWords(types[tid].elemType);
                        out.n = 1;
                        out.w[0] = comp.w[idx * rows + words[pc + 5]];
                    } else {
                        out.n = 1;
                        out.w[0] = comp.w[idx];
                    }
                    ssa[words[pc + 2]] = out;
                    break;
                }
                case op::VectorShuffle: {
                    Val out;
                    out.type = words[pc + 1];
                    const Val& a = ssa[words[pc + 3]];
                    const Val& b = ssa[words[pc + 4]];
                    for (uint16_t k = 5; k < wc; ++k) {
                        const uint32_t c = words[pc + k];
                        out.w[out.n++] = (c < a.n) ? a.w[c] : b.w[c - a.n];
                    }
                    ssa[words[pc + 2]] = out;
                    break;
                }
                case op::Image: {
                    Val out = ssa[words[pc + 3]];
                    out.type = words[pc + 1];
                    ssa[words[pc + 2]] = out;
                    break;
                }
                case op::ImageFetch: {
                    Val out;
                    out.type = words[pc + 1];
                    out.n = 4;
                    const Val& coord = ssa[words[pc + 4]];
                    const int ix = std::clamp(bitsToInt(coord.w[0]), 0, std::max(0, bindings.tex3d.width - 1));
                    const int iy = std::clamp(bitsToInt(coord.w[1]), 0, std::max(0, bindings.tex3d.height - 1));
                    const int iz = std::clamp(bitsToInt(coord.w[2]), 0, std::max(0, bindings.tex3d.depth - 1));
                    if (bindings.tex3d.data && !bindings.tex3d.data->empty()) {
                        const size_t base = (size_t(iz) * size_t(bindings.tex3d.height) * size_t(bindings.tex3d.width) +
                                             size_t(iy) * size_t(bindings.tex3d.width) + size_t(ix)) * 4u;
                        for (uint8_t c = 0; c < 4; ++c) {
                            out.w[c] = (base + c < bindings.tex3d.data->size()) ? floatToBits((*bindings.tex3d.data)[base + c]) : 0u;
                        }
                    } else {
                        out.w.fill(0);
                    }
                    ssa[words[pc + 2]] = out;
                    break;
                }
                case op::FunctionCall: {
                    std::vector<Val> callArgs;
                    for (uint16_t k = 4; k < wc; ++k) callArgs.push_back(ssa[words[pc + k]]);
                    Val ret = runFunction(words[pc + 3], callArgs, gid, bindings, ssa, locals);
                    ret.type = words[pc + 1];
                    ssa[words[pc + 2]] = ret;
                    break;
                }
                case op::Bitcast: {
                    Val out = ssa[words[pc + 3]];
                    out.type = words[pc + 1];
                    ssa[words[pc + 2]] = out;
                    break;
                }
                case op::ConvertFToU:
                case op::ConvertFToS:
                case op::ConvertSToF:
                case op::ConvertUToF: {
                    Val out;
                    out.type = words[pc + 1];
                    const Val& a = ssa[words[pc + 3]];
                    out.n = a.n;
                    for (uint8_t k = 0; k < a.n; ++k) {
                        if (opcode == op::ConvertFToU) out.w[k] = static_cast<uint32_t>(bitsToFloat(a.w[k]));
                        else if (opcode == op::ConvertFToS) out.w[k] = intToBits(static_cast<int32_t>(bitsToFloat(a.w[k])));
                        else if (opcode == op::ConvertSToF) out.w[k] = floatToBits(static_cast<float>(bitsToInt(a.w[k])));
                        else out.w[k] = floatToBits(static_cast<float>(a.w[k]));
                    }
                    ssa[words[pc + 2]] = out;
                    break;
                }
                case op::FNegate:
                case op::SNegate:
                case op::LogicalNot: {
                    Val out;
                    out.type = words[pc + 1];
                    const Val& a = ssa[words[pc + 3]];
                    out.n = a.n;
                    for (uint8_t k = 0; k < a.n; ++k) {
                        if (opcode == op::FNegate) out.w[k] = floatToBits(-bitsToFloat(a.w[k]));
                        else if (opcode == op::SNegate) out.w[k] = intToBits(-bitsToInt(a.w[k]));
                        else out.w[k] = a.w[k] ? 0u : 1u;
                    }
                    ssa[words[pc + 2]] = out;
                    break;
                }
                case op::All: {
                    Val out;
                    out.type = words[pc + 1];
                    out.n = 1;
                    const Val& a = ssa[words[pc + 3]];
                    uint32_t all = 1;
                    for (uint8_t k = 0; k < a.n; ++k) all &= (a.w[k] ? 1u : 0u);
                    out.w[0] = all;
                    ssa[words[pc + 2]] = out;
                    break;
                }
                case op::VectorTimesScalar: {
                    Val out;
                    out.type = words[pc + 1];
                    const Val& v = ssa[words[pc + 3]];
                    const float s = bitsToFloat(ssa[words[pc + 4]].w[0]);
                    out.n = v.n;
                    for (uint8_t k = 0; k < v.n; ++k) out.w[k] = floatToBits(bitsToFloat(v.w[k]) * s);
                    ssa[words[pc + 2]] = out;
                    break;
                }
                case op::MatrixTimesVector: {
                    Val out;
                    out.type = words[pc + 1];
                    const Val& mat = ssa[words[pc + 3]];
                    const Val& vec = ssa[words[pc + 4]];
                    const uint32_t cols = vec.n;
                    const uint32_t rows = mat.n / cols;
                    out.n = static_cast<uint8_t>(rows);
                    for (uint32_t r = 0; r < rows; ++r) {
                        float sum = 0.0f;
                        for (uint32_t c = 0; c < cols; ++c) {
                            sum += bitsToFloat(mat.w[c * rows + r]) * bitsToFloat(vec.w[c]);
                        }
                        out.w[r] = floatToBits(sum);
                    }
                    ssa[words[pc + 2]] = out;
                    break;
                }
                case op::Dot: {
                    Val out;
                    out.type = words[pc + 1];
                    out.n = 1;
                    const Val& a = ssa[words[pc + 3]];
                    const Val& b = ssa[words[pc + 4]];
                    float sum = 0.0f;
                    for (uint8_t k = 0; k < a.n; ++k) sum += bitsToFloat(a.w[k]) * bitsToFloat(b.w[k]);
                    out.w[0] = floatToBits(sum);
                    ssa[words[pc + 2]] = out;
                    break;
                }
                case op::Select: {
                    Val out;
                    out.type = words[pc + 1];
                    const Val& cond = ssa[words[pc + 3]];
                    const Val& a = ssa[words[pc + 4]];
                    const Val& b = ssa[words[pc + 5]];
                    out.n = a.n;
                    for (uint8_t k = 0; k < out.n; ++k) {
                        const uint32_t c = (cond.n == 1) ? cond.w[0] : cond.w[k];
                        out.w[k] = c ? a.w[k] : b.w[k];
                    }
                    ssa[words[pc + 2]] = out;
                    break;
                }
                case op::FAdd: case op::FSub: case op::FMul: case op::FDiv: case op::FMod:
                case op::FOrdEqual: case op::FUnordNotEqual: case op::FOrdLessThan:
                case op::FOrdGreaterThan: case op::FOrdLessThanEqual: case op::FOrdGreaterThanEqual: {
                    Val out;
                    out.type = words[pc + 1];
                    const Val& a = ssa[words[pc + 3]];
                    const Val& b = ssa[words[pc + 4]];
                    out.n = a.n;
                    for (uint8_t k = 0; k < a.n; ++k) {
                        const float fa = bitsToFloat(a.w[k]);
                        const float fb = bitsToFloat(b.w[k]);
                        switch (opcode) {
                            case op::FAdd: out.w[k] = floatToBits(fa + fb); break;
                            case op::FSub: out.w[k] = floatToBits(fa - fb); break;
                            case op::FMul: out.w[k] = floatToBits(fa * fb); break;
                            case op::FDiv: out.w[k] = floatToBits(fa / fb); break;
                            case op::FMod: out.w[k] = floatToBits(fa - fb * std::floor(fa / fb)); break;
                            case op::FOrdEqual: out.w[k] = (fa == fb) ? 1u : 0u; break;
                            case op::FUnordNotEqual: out.w[k] = (!(fa == fb)) ? 1u : 0u; break;
                            case op::FOrdLessThan: out.w[k] = (fa < fb) ? 1u : 0u; break;
                            case op::FOrdGreaterThan: out.w[k] = (fa > fb) ? 1u : 0u; break;
                            case op::FOrdLessThanEqual: out.w[k] = (fa <= fb) ? 1u : 0u; break;
                            case op::FOrdGreaterThanEqual: out.w[k] = (fa >= fb) ? 1u : 0u; break;
                            default: break;
                        }
                    }
                    ssa[words[pc + 2]] = out;
                    break;
                }
                case op::IAdd: case op::ISub: case op::IMul: case op::UDiv: case op::SDiv:
                case op::UMod: case op::SMod: case op::ShiftRightLogical: case op::ShiftLeftLogical:
                case op::BitwiseOr: case op::BitwiseXor: case op::BitwiseAnd:
                case op::LogicalOr: case op::LogicalAnd:
                case op::IEqual: case op::INotEqual:
                case op::UGreaterThan: case op::UGreaterThanEqual: case op::ULessThan:
                case op::SLessThan: case op::SLessThanEqual: case op::SGreaterThan: case op::SGreaterThanEqual: {
                    Val out;
                    out.type = words[pc + 1];
                    const Val& a = ssa[words[pc + 3]];
                    const Val& b = ssa[words[pc + 4]];
                    out.n = a.n;
                    for (uint8_t k = 0; k < a.n; ++k) {
                        const uint32_t ua = a.w[k], ub = b.w[k];
                        const int32_t ia = bitsToInt(ua), ib = bitsToInt(ub);
                        switch (opcode) {
                            case op::IAdd: out.w[k] = ua + ub; break;
                            case op::ISub: out.w[k] = ua - ub; break;
                            case op::IMul: out.w[k] = ua * ub; break;
                            case op::UDiv: out.w[k] = ub ? (ua / ub) : 0u; break;
                            case op::SDiv: out.w[k] = ib ? intToBits(ia / ib) : 0u; break;
                            case op::UMod: out.w[k] = ub ? (ua % ub) : 0u; break;
                            case op::SMod: out.w[k] = intToBits(sMod(ia, ib)); break;
                            case op::ShiftRightLogical: out.w[k] = ua >> (ub & 31u); break;
                            case op::ShiftLeftLogical: out.w[k] = ua << (ub & 31u); break;
                            case op::BitwiseOr: out.w[k] = ua | ub; break;
                            case op::BitwiseXor: out.w[k] = ua ^ ub; break;
                            case op::BitwiseAnd: out.w[k] = ua & ub; break;
                            case op::LogicalOr: out.w[k] = (ua || ub) ? 1u : 0u; break;
                            case op::LogicalAnd: out.w[k] = (ua && ub) ? 1u : 0u; break;
                            case op::IEqual: out.w[k] = (ua == ub) ? 1u : 0u; break;
                            case op::INotEqual: out.w[k] = (ua != ub) ? 1u : 0u; break;
                            case op::UGreaterThan: out.w[k] = (ua > ub) ? 1u : 0u; break;
                            case op::UGreaterThanEqual: out.w[k] = (ua >= ub) ? 1u : 0u; break;
                            case op::ULessThan: out.w[k] = (ua < ub) ? 1u : 0u; break;
                            case op::SLessThan: out.w[k] = (ia < ib) ? 1u : 0u; break;
                            case op::SLessThanEqual: out.w[k] = (ia <= ib) ? 1u : 0u; break;
                            case op::SGreaterThan: out.w[k] = (ia > ib) ? 1u : 0u; break;
                            case op::SGreaterThanEqual: out.w[k] = (ia >= ib) ? 1u : 0u; break;
                            default: break;
                        }
                    }
                    ssa[words[pc + 2]] = out;
                    break;
                }
                case op::ExtInst: {
                    Val out;
                    out.type = words[pc + 1];
                    const uint32_t extOp = words[pc + 4];
                    const Val& a = ssa[words[pc + 5]];
                    out.n = a.n;
                    for (uint8_t k = 0; k < a.n; ++k) {
                        const float fa = bitsToFloat(a.w[k]);
                        switch (extOp) {
                            case glsl450::FAbs: out.w[k] = floatToBits(std::fabs(fa)); break;
                            case glsl450::FSign: out.w[k] = floatToBits(fa > 0.f ? 1.f : (fa < 0.f ? -1.f : 0.f)); break;
                            case glsl450::Floor: out.w[k] = floatToBits(std::floor(fa)); break;
                            case glsl450::Log: out.w[k] = floatToBits(std::log(fa)); break;
                            case glsl450::Exp2: out.w[k] = floatToBits(std::exp2(fa)); break;
                            case glsl450::Sqrt: out.w[k] = floatToBits(std::sqrt(fa)); break;
                            case glsl450::Pow: out.w[k] = floatToBits(std::pow(fa, bitsToFloat(ssa[words[pc + 6]].w[k]))); break;
                            case glsl450::FMin: out.w[k] = floatToBits(std::min(fa, bitsToFloat(ssa[words[pc + 6]].w[k]))); break;
                            case glsl450::FMax: out.w[k] = floatToBits(std::max(fa, bitsToFloat(ssa[words[pc + 6]].w[k]))); break;
                            case glsl450::SMin: out.w[k] = intToBits(std::min(bitsToInt(a.w[k]), bitsToInt(ssa[words[pc + 6]].w[k]))); break;
                            case glsl450::UMin: out.w[k] = std::min(a.w[k], ssa[words[pc + 6]].w[k]); break;
                            case glsl450::FClamp: {
                                const float lo = bitsToFloat(ssa[words[pc + 6]].w[k]);
                                const float hi = bitsToFloat(ssa[words[pc + 7]].w[k]);
                                out.w[k] = floatToBits(std::clamp(fa, lo, hi));
                                break;
                            }
                            case glsl450::SClamp: {
                                const int32_t lo = bitsToInt(ssa[words[pc + 6]].w[k]);
                                const int32_t hi = bitsToInt(ssa[words[pc + 7]].w[k]);
                                out.w[k] = intToBits(std::clamp(bitsToInt(a.w[k]), lo, hi));
                                break;
                            }
                            case glsl450::FMix: {
                                const float fb = bitsToFloat(ssa[words[pc + 6]].w[k]);
                                const float ft = bitsToFloat(ssa[words[pc + 7]].w[k]);
                                out.w[k] = floatToBits(fa + (fb - fa) * ft);
                                break;
                            }
                            default:
                                throw std::runtime_error("Unhandled GLSLstd450 opcode " + std::to_string(extOp));
                        }
                    }
                    ssa[words[pc + 2]] = out;
                    break;
                }
                case op::LoopMerge:
                case op::SelectionMerge:
                    break;
                case op::Branch:
                    prevLabel = curLabel;
                    pc = fn.labelToWord.at(words[pc + 1]);
                    continue;
                case op::BranchConditional:
                    prevLabel = curLabel;
                    pc = fn.labelToWord.at(ssa[words[pc + 1]].w[0] ? words[pc + 2] : words[pc + 3]);
                    continue;
                case op::Return:
                    return {};
                case op::ReturnValue:
                    return ssa[words[pc + 1]];
                default:
                    throw std::runtime_error("Unhandled SPIR-V opcode " + std::to_string(opcode));
            }
            pc += wc;
        }
        return {};
    }
};

} // namespace spv_vm

#ifdef SONY2FUJI_GLES_VM_IMPLEMENT

namespace detail {

struct Texture3DObj {
    GLint minFilter = GL_NEAREST;
    GLint magFilter = GL_NEAREST;
    GLint wrapS = GL_CLAMP_TO_EDGE;
    GLint wrapT = GL_CLAMP_TO_EDGE;
    GLint wrapR = GL_CLAMP_TO_EDGE;
    int width = 0, height = 0, depth = 0;
    std::vector<float> data;
};

struct BufferObj {
    std::vector<uint8_t> bytes;
    bool mapped = false;
};

struct ProgramObj {
    spv_vm::Module module;
    bool linked = false;
    std::vector<std::string> locToName;
    std::unordered_map<std::string, GLint> nameToLoc;
    std::unordered_map<std::string, std::vector<uint32_t>> uniforms;
};

struct GlContextState {
    GLuint activeProgram = 0;
    GLuint activeTexUnit = 0;
    std::array<GLuint, 8> boundTex3D{};
    GLuint boundArraySsbo = 0;
    GLuint boundArrayUbo = 0;
    std::array<GLuint, 8> boundSsbo{};
    std::array<GLuint, 4> boundUbo{};
    GLint unpackAlignment = 4;
};

struct GlState {
    GlesVmConfig config;
    GlesVmStats stats;
    std::unordered_map<std::string, spv_vm::Module> spvCache;

    EGLDisplay currentDisplay = EGL_NO_DISPLAY;
    EGLContext currentContext = EGL_NO_CONTEXT;
    EGLSurface currentDraw = EGL_NO_SURFACE;
    EGLSurface currentRead = EGL_NO_SURFACE;
    EGLenum currentApi = EGL_OPENGL_ES_API;
    uintptr_t nextContextId = 0x100;
    std::unordered_map<EGLContext, GlContextState> contexts;
    GlContextState fallbackContext;

    GLuint nextShader = 1, nextProgram = 1, nextBuffer = 1, nextTexture = 1;
    std::unordered_map<GLuint, std::string> shaderSources;
    std::unordered_map<GLuint, bool> shaderCompiled;
    std::unordered_map<GLuint, std::string> shaderLogs;
    std::unordered_map<GLuint, ProgramObj> programs;
    std::unordered_map<GLuint, BufferObj> buffers;
    std::unordered_map<GLuint, Texture3DObj> textures;
    GLenum lastError = GL_NO_ERROR;
};

inline GlState& state() {
    static GlState s;
    return s;
}

inline GlContextState& ctxState() {
    auto& s = state();
    if (s.currentContext != EGL_NO_CONTEXT) {
        return s.contexts[s.currentContext];
    }
    return s.fallbackContext;
}

inline const spv_vm::Module& compileGlslToSpv(const std::string& source, std::string& logOut) {
    auto& cache = state().spvCache;
    auto it = cache.find(source);
    if (it != cache.end()) return it->second;

#ifndef RAWLAB_GLSLANG_PATH
    throw std::runtime_error("RAWLAB_GLSLANG_PATH not configured");
#else
    static std::atomic<uint64_t> seq{0};
    const std::string compiler = RAWLAB_GLSLANG_PATH;
#ifdef _WIN32
    const auto pid = static_cast<unsigned long>(_getpid());
#else
    const auto pid = static_cast<unsigned long>(getpid());
#endif
    const auto uniqueTag = std::to_string(pid) + "_" +
                           std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()) + "_" +
                           std::to_string(reinterpret_cast<uintptr_t>(&cache)) + "_" +
                           std::to_string(seq.fetch_add(1, std::memory_order_relaxed));
    const auto tmpDir = std::filesystem::temp_directory_path() / ("rawlab_gles_vm_tmp_" + uniqueTag);
    std::filesystem::create_directories(tmpDir);
    const auto compPath = tmpDir / "shader.comp";
    const auto spvPath = tmpDir / "shader.spv";
    const auto logPath = tmpDir / "shader.log";
    {
        std::ofstream out(compPath, std::ios::binary | std::ios::trunc);
        out.write(source.data(), static_cast<std::streamsize>(source.size()));
    }
    const std::string innerCmd = "\"" + compiler + "\" -G --auto-map-locations -S comp \"" +
                                 compPath.string() + "\" -o \"" + spvPath.string() + "\" > \"" +
                                 logPath.string() + "\" 2>&1";
#ifdef _WIN32
    const std::string cmd = "\"" + innerCmd + "\"";
#else
    const std::string cmd = innerCmd;
#endif
    const int rc = std::system(cmd.c_str());
    {
        std::ifstream logIn(logPath, std::ios::binary);
        std::ostringstream ss;
        ss << logIn.rdbuf();
        logOut = ss.str();
    }
    std::vector<uint32_t> words;
    if (rc == 0) {
        std::ifstream spvIn(spvPath, std::ios::binary | std::ios::ate);
        const size_t bytes = static_cast<size_t>(spvIn.tellg());
        spvIn.seekg(0);
        words.resize(bytes / 4);
        spvIn.read(reinterpret_cast<char*>(words.data()), static_cast<std::streamsize>(words.size() * 4));
    }
    std::error_code ec;
    std::filesystem::remove_all(tmpDir, ec);
    if (rc != 0 || words.empty()) {
        throw std::runtime_error(logOut.empty() ? "glslangValidator failed" : logOut);
    }
    auto parsed = spv_vm::Module::parse(std::move(words));
    return cache.emplace(source, std::move(parsed)).first->second;
#endif
}

inline GLuint boundBufferFor(GLenum target) {
    auto& c = ctxState();
    return target == GL_UNIFORM_BUFFER ? c.boundArrayUbo : c.boundArraySsbo;
}

inline void setBoundBufferFor(GLenum target, GLuint buf) {
    auto& c = ctxState();
    if (target == GL_UNIFORM_BUFFER) c.boundArrayUbo = buf;
    else c.boundArraySsbo = buf;
}

inline std::vector<uint32_t>* resolveUniformSlot(ProgramObj& p, GLint location, size_t& offsetWords) {
    offsetWords = 0;
    if (location < 0 || size_t(location) >= p.locToName.size()) return nullptr;
    return &p.uniforms[p.locToName[size_t(location)]];
}

} // namespace detail

inline GlesVmConfig& glesVmConfig() { return detail::state().config; }
inline GlesVmStats& glesVmStats() { return detail::state().stats; }
inline void resetGlesVmState() {
    auto& s = detail::state();
    s.stats.resetCounters();
    s.contexts.clear();
    s.fallbackContext = {};
    s.shaderSources.clear();
    s.shaderCompiled.clear();
    s.shaderLogs.clear();
    s.programs.clear();
    s.buffers.clear();
    s.textures.clear();
    s.lastError = GL_NO_ERROR;
}

inline size_t glesVmLiveBufferBytes() {
    size_t total = 0;
    for (const auto& kv : detail::state().buffers) {
        total += kv.second.bytes.size();
    }
    return total;
}

extern "C" {

static EGLDisplay const kDisplay = reinterpret_cast<EGLDisplay>(0x1);
static EGLConfig const kConfig = reinterpret_cast<EGLConfig>(0x2);
static EGLSurface const kSurface = reinterpret_cast<EGLSurface>(0x3);

EGLDisplay eglGetDisplay(EGLNativeDisplayType) { return kDisplay; }
EGLBoolean eglInitialize(EGLDisplay dpy, EGLint* maj, EGLint* min) {
    if (dpy != kDisplay) return EGL_FALSE;
    if (maj) *maj = 1;
    if (min) *min = 5;
    return EGL_TRUE;
}
EGLBoolean eglChooseConfig(EGLDisplay, const EGLint*, EGLConfig* cfgs, EGLint sz, EGLint* num) {
    if (!cfgs || sz < 1 || !num) return EGL_FALSE;
    cfgs[0] = kConfig;
    *num = 1;
    return EGL_TRUE;
}
EGLSurface eglCreatePbufferSurface(EGLDisplay, EGLConfig, const EGLint*) { return kSurface; }
EGLContext eglCreateContext(EGLDisplay, EGLConfig, EGLContext, const EGLint*) {
    auto& s = detail::state();
    auto ctx = reinterpret_cast<EGLContext>(s.nextContextId++);
    s.contexts[ctx] = {};
    return ctx;
}
EGLBoolean eglDestroyContext(EGLDisplay, EGLContext ctx) {
    detail::state().contexts.erase(ctx);
    return EGL_TRUE;
}
EGLBoolean eglDestroySurface(EGLDisplay, EGLSurface) { return EGL_TRUE; }
EGLBoolean eglMakeCurrent(EGLDisplay dpy, EGLSurface draw, EGLSurface read, EGLContext ctx) {
    auto& s = detail::state();
    s.currentDisplay = dpy;
    s.currentDraw = draw;
    s.currentRead = read;
    s.currentContext = ctx;
    return EGL_TRUE;
}
EGLDisplay eglGetCurrentDisplay(void) { return detail::state().currentDisplay; }
EGLSurface eglGetCurrentSurface(EGLint readdraw) {
    return readdraw == EGL_READ ? detail::state().currentRead : detail::state().currentDraw;
}
EGLContext eglGetCurrentContext(void) { return detail::state().currentContext; }
EGLBoolean eglBindAPI(EGLenum api) { detail::state().currentApi = api; return EGL_TRUE; }
EGLenum eglQueryAPI(void) { return detail::state().currentApi; }
EGLint eglGetError(void) { return EGL_SUCCESS; }

int __android_log_print(int prio, const char* tag, const char* fmt, ...) {
    if (prio >= ANDROID_LOG_WARN) {
        std::fprintf(stderr, "[%s] ", tag ? tag : "RawLabGPU");
        va_list args;
        va_start(args, fmt);
        std::vfprintf(stderr, fmt, args);
        va_end(args);
        std::fprintf(stderr, "\n");
    }
    return 0;
}

GLuint glCreateShader(GLenum) { return detail::state().nextShader++; }
void glShaderSource(GLuint shader, GLsizei count, const GLchar* const* str, const GLint* len) {
    std::string combined;
    for (GLsizei i = 0; i < count; ++i) {
        if (!str[i]) continue;
        if (len && len[i] >= 0) combined.append(str[i], static_cast<size_t>(len[i]));
        else combined.append(str[i]);
    }
    detail::state().shaderSources[shader] = std::move(combined);
}
void glCompileShader(GLuint shader) {
    auto& s = detail::state();
    try {
        std::string log;
        (void)detail::compileGlslToSpv(s.shaderSources.at(shader), log);
        s.shaderCompiled[shader] = true;
        s.shaderLogs[shader] = std::move(log);
    } catch (const std::exception& e) {
        s.shaderCompiled[shader] = false;
        s.shaderLogs[shader] = e.what();
    }
}
void glGetShaderiv(GLuint shader, GLenum pname, GLint* params) {
    if (pname == GL_COMPILE_STATUS && params) *params = detail::state().shaderCompiled[shader] ? GL_TRUE : GL_FALSE;
}
void glGetShaderInfoLog(GLuint shader, GLsizei bufSize, GLsizei* length, GLchar* infoLog) {
    const auto& log = detail::state().shaderLogs[shader];
    if (length) *length = static_cast<GLsizei>(log.size());
    if (infoLog && bufSize > 0) {
        const size_t n = std::min<size_t>(static_cast<size_t>(bufSize - 1), log.size());
        std::memcpy(infoLog, log.data(), n);
        infoLog[n] = '\0';
    }
}
void glDeleteShader(GLuint shader) {
    detail::state().shaderSources.erase(shader);
    detail::state().shaderCompiled.erase(shader);
    detail::state().shaderLogs.erase(shader);
}

GLuint glCreateProgram(void) { return detail::state().nextProgram++; }
void glAttachShader(GLuint program, GLuint shader) {
    auto& s = detail::state();
    auto& p = s.programs[program];
    if (s.shaderCompiled[shader]) {
        std::string log;
        p.module = detail::compileGlslToSpv(s.shaderSources.at(shader), log);
    }
}
void glLinkProgram(GLuint program) {
    auto& p = detail::state().programs[program];
    p.linked = (p.module.entryPoint != 0);
}
void glGetProgramiv(GLuint program, GLenum pname, GLint* params) {
    if (pname == GL_LINK_STATUS && params) *params = detail::state().programs[program].linked ? GL_TRUE : GL_FALSE;
}
void glDeleteProgram(GLuint program) { detail::state().programs.erase(program); }
void glUseProgram(GLuint program) { detail::ctxState().activeProgram = program; }

GLint glGetUniformLocation(GLuint program, const GLchar* name) {
    auto& p = detail::state().programs[program];
    std::string key = name ? name : "";
    const auto pos = key.rfind("[0]");
    if (pos != std::string::npos && pos + 3 == key.size()) key.resize(pos);
    auto it = p.nameToLoc.find(key);
    if (it != p.nameToLoc.end()) return it->second;
    const GLint loc = static_cast<GLint>(p.locToName.size());
    p.locToName.push_back(key);
    p.nameToLoc[key] = loc;
    return loc;
}

void glUniform1i(GLint loc, GLint v0) {
    auto& p = detail::state().programs[detail::ctxState().activeProgram];
    size_t off = 0;
    if (auto* vec = detail::resolveUniformSlot(p, loc, off)) *vec = {spv_vm::intToBits(v0)};
}
void glUniform1ui(GLint loc, GLuint v0) {
    auto& p = detail::state().programs[detail::ctxState().activeProgram];
    size_t off = 0;
    if (auto* vec = detail::resolveUniformSlot(p, loc, off)) *vec = {v0};
}
void glUniform2ui(GLint loc, GLuint v0, GLuint v1) {
    auto& p = detail::state().programs[detail::ctxState().activeProgram];
    size_t off = 0;
    if (auto* vec = detail::resolveUniformSlot(p, loc, off)) *vec = {v0, v1};
}
void glUniform1f(GLint loc, GLfloat v0) {
    auto& p = detail::state().programs[detail::ctxState().activeProgram];
    size_t off = 0;
    if (auto* vec = detail::resolveUniformSlot(p, loc, off)) *vec = {spv_vm::floatToBits(v0)};
}
void glUniform3f(GLint loc, GLfloat v0, GLfloat v1, GLfloat v2) {
    auto& p = detail::state().programs[detail::ctxState().activeProgram];
    size_t off = 0;
    if (auto* vec = detail::resolveUniformSlot(p, loc, off)) {
        *vec = {spv_vm::floatToBits(v0), spv_vm::floatToBits(v1), spv_vm::floatToBits(v2)};
    }
}
void glUniform4f(GLint loc, GLfloat v0, GLfloat v1, GLfloat v2, GLfloat v3) {
    auto& p = detail::state().programs[detail::ctxState().activeProgram];
    size_t off = 0;
    if (auto* vec = detail::resolveUniformSlot(p, loc, off)) {
        *vec = {spv_vm::floatToBits(v0), spv_vm::floatToBits(v1),
                spv_vm::floatToBits(v2), spv_vm::floatToBits(v3)};
    }
}
void glUniform3fv(GLint loc, GLsizei count, const GLfloat* val) {
    auto& p = detail::state().programs[detail::ctxState().activeProgram];
    size_t off = 0;
    if (auto* vec = detail::resolveUniformSlot(p, loc, off)) {
        const size_t n = size_t(std::max<GLsizei>(0, count)) * 3;
        vec->resize(n);
        if (n > 0) std::memcpy(vec->data(), val, n * sizeof(uint32_t));
    }
}
void glUniform4fv(GLint loc, GLsizei count, const GLfloat* val) {
    auto& p = detail::state().programs[detail::ctxState().activeProgram];
    size_t off = 0;
    if (auto* vec = detail::resolveUniformSlot(p, loc, off)) {
        const size_t n = size_t(std::max<GLsizei>(0, count)) * 4;
        vec->resize(n);
        if (n > 0) std::memcpy(vec->data(), val, n * sizeof(uint32_t));
    }
}
void glUniformMatrix3fv(GLint loc, GLsizei count, GLboolean, const GLfloat* val) {
    auto& p = detail::state().programs[detail::ctxState().activeProgram];
    size_t off = 0;
    if (auto* vec = detail::resolveUniformSlot(p, loc, off)) {
        const size_t n = size_t(std::max<GLsizei>(0, count)) * 9;
        vec->resize(n);
        if (n > 0) std::memcpy(vec->data(), val, n * sizeof(uint32_t));
    }
}

const GLubyte* glGetString(GLenum name) {
    if (name == GL_RENDERER) return reinterpret_cast<const GLubyte*>("RawLab-SPIRV-VM");
    if (name == GL_VERSION) return reinterpret_cast<const GLubyte*>("OpenGL ES 3.1 RawLabTest");
    return reinterpret_cast<const GLubyte*>("");
}
void glGetIntegerv(GLenum pname, GLint* data) {
    if (!data) return;
    const auto& cfg = detail::state().config;
    switch (pname) {
        case GL_MAJOR_VERSION: *data = 3; break;
        case GL_MINOR_VERSION: *data = 1; break;
        case GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS: *data = 128; break;
        case GL_MAX_COMPUTE_SHADER_STORAGE_BLOCKS: *data = 8; break;
        case GL_MAX_3D_TEXTURE_SIZE: *data = cfg.maxTexture3DSize; break;
        default: *data = 0; break;
    }
}
void glGetIntegeri_v(GLenum target, GLuint, GLint* data) {
    if (!data) return;
    if (target == GL_MAX_COMPUTE_WORK_GROUP_SIZE) *data = 128;
    else if (target == GL_MAX_COMPUTE_WORK_GROUP_COUNT) *data = detail::state().config.maxComputeWorkGroupCount;
    else *data = 0;
}
void glGetInteger64v(GLenum pname, GLint64* data) {
    if (pname == GL_MAX_SHADER_STORAGE_BLOCK_SIZE && data) *data = detail::state().config.maxSsboBytes;
}
GLenum glGetError(void) {
    const GLenum err = detail::state().lastError;
    detail::state().lastError = GL_NO_ERROR;
    return err;
}

void glGenTextures(GLsizei n, GLuint* tex) {
    for (GLsizei i = 0; i < n; ++i) {
        const GLuint id = detail::state().nextTexture++;
        detail::state().textures[id] = {};
        tex[i] = id;
    }
}
void glBindTexture(GLenum, GLuint tex) {
    auto& c = detail::ctxState();
    c.boundTex3D[c.activeTexUnit] = tex;
}
void glTexParameteri(GLenum, GLenum pname, GLint param) {
    auto& s = detail::state();
    auto& c = detail::ctxState();
    auto& t = s.textures[c.boundTex3D[c.activeTexUnit]];
    switch (pname) {
        case GL_TEXTURE_MIN_FILTER: t.minFilter = param; s.stats.lastTexMinFilter = param; break;
        case GL_TEXTURE_MAG_FILTER: t.magFilter = param; s.stats.lastTexMagFilter = param; break;
        case GL_TEXTURE_WRAP_S: t.wrapS = param; s.stats.lastTexWrapS = param; break;
        case GL_TEXTURE_WRAP_T: t.wrapT = param; s.stats.lastTexWrapT = param; break;
        case GL_TEXTURE_WRAP_R: t.wrapR = param; s.stats.lastTexWrapR = param; break;
        default: break;
    }
}
void glPixelStorei(GLenum pname, GLint param) {
    if (pname == GL_UNPACK_ALIGNMENT) detail::ctxState().unpackAlignment = param;
}
void glTexImage3D(GLenum, GLint, GLint internalformat, GLsizei width, GLsizei height, GLsizei depth,
                  GLint, GLenum format, GLenum type, const void* pixels) {
    auto& s = detail::state();
    auto& c = detail::ctxState();
    ++s.stats.texImage3DCalls;
    s.stats.lastTexUnpackAlignment = c.unpackAlignment;
    s.stats.lastTexInternalFormat = internalformat;
    s.stats.lastTexFormat = format;
    s.stats.lastTexType = type;

    auto& tex = s.textures[c.boundTex3D[c.activeTexUnit]];
    tex.width = width;
    tex.height = height;
    tex.depth = depth;
    const size_t totalFloats = size_t(width) * height * depth * 4;
    tex.data.resize(totalFloats);
    if (pixels && totalFloats > 0) {
        const size_t align = static_cast<size_t>(std::max(1, c.unpackAlignment));
        const size_t rowBytes = size_t(width) * 4 * sizeof(float);
        const size_t alignedRowBytes = (rowBytes + align - 1) & ~(align - 1);
        const auto* src = static_cast<const uint8_t*>(pixels);
        auto* dst = reinterpret_cast<uint8_t*>(tex.data.data());
        for (int z = 0; z < depth; ++z) {
            for (int y = 0; y < height; ++y) {
                std::memcpy(dst + (size_t(z) * height + y) * rowBytes,
                            src + (size_t(z) * height + y) * alignedRowBytes,
                            rowBytes);
            }
        }
    }
}
void glActiveTexture(GLenum texture) {
    auto& c = detail::ctxState();
    const GLuint unit = texture >= GL_TEXTURE0 ? (texture - GL_TEXTURE0) : 0;
    if (unit < c.boundTex3D.size()) c.activeTexUnit = unit;
}
void glDeleteTextures(GLsizei n, const GLuint* tex) {
    for (GLsizei i = 0; i < n; ++i) detail::state().textures.erase(tex[i]);
}

void glGenBuffers(GLsizei n, GLuint* buffers) {
    auto& s = detail::state();
    s.stats.genBufferCalls += static_cast<size_t>(n);
    for (GLsizei i = 0; i < n; ++i) {
        const GLuint id = s.nextBuffer++;
        s.buffers[id] = {};
        buffers[i] = id;
    }
}
void glBindBuffer(GLenum target, GLuint buffer) { detail::setBoundBufferFor(target, buffer); }
void glBindBufferBase(GLenum target, GLuint index, GLuint buffer) {
    auto& c = detail::ctxState();
    if (target == GL_UNIFORM_BUFFER && index < c.boundUbo.size()) c.boundUbo[index] = buffer;
    else if (target == GL_SHADER_STORAGE_BUFFER && index < c.boundSsbo.size()) c.boundSsbo[index] = buffer;
}
void glBufferData(GLenum target, GLsizeiptr size, const void* data, GLenum) {
    auto& s = detail::state();
    ++s.stats.bufferDataCalls;
    const size_t nbytes = static_cast<size_t>(std::max<GLsizeiptr>(0, size));
    s.stats.totalBufferDataBytes += nbytes;
    s.stats.maxBufferDataBytes = std::max(s.stats.maxBufferDataBytes, nbytes);
    const GLuint id = detail::boundBufferFor(target);
    auto& b = s.buffers[id];
    b.bytes.assign(static_cast<size_t>(size), 0);
    if (data && size > 0) std::memcpy(b.bytes.data(), data, static_cast<size_t>(size));
}
void glBufferSubData(GLenum target, GLintptr offset, GLsizeiptr size, const void* data) {
    auto& s = detail::state();
    ++s.stats.bufferSubDataCalls;
    if (target == GL_SHADER_STORAGE_BUFFER) ++s.stats.ssboBufferSubDataCalls;
    s.stats.totalBufferSubDataBytes += static_cast<size_t>(std::max<GLsizeiptr>(0, size));
    const GLuint id = detail::boundBufferFor(target);
    auto& b = s.buffers[id];
    if (offset >= 0 && size > 0 && size_t(offset) + size_t(size) <= b.bytes.size() && data) {
        std::memcpy(b.bytes.data() + offset, data, static_cast<size_t>(size));
    } else if (offset < 0 || size_t(offset) + size_t(size) > b.bytes.size()) {
        s.lastError = GL_INVALID_VALUE;
    }
}
void* glMapBufferRange(GLenum target, GLintptr offset, GLsizeiptr length, GLbitfield) {
    auto& s = detail::state();
    const GLuint id = detail::boundBufferFor(target);
    auto& b = s.buffers[id];
    if (offset < 0 || length < 0 || size_t(offset) + size_t(length) > b.bytes.size()) {
        s.lastError = GL_INVALID_VALUE;
        return nullptr;
    }
    b.mapped = true;
    return b.bytes.data() + offset;
}
GLboolean glUnmapBuffer(GLenum target) {
    auto& s = detail::state();
    const GLuint id = detail::boundBufferFor(target);
    s.buffers[id].mapped = false;
    return GL_TRUE;
}
void glDeleteBuffers(GLsizei n, const GLuint* buffers) {
    auto& s = detail::state();
    for (GLsizei i = 0; i < n; ++i) {
        if (buffers[i]) {
            if (s.currentContext == EGL_NO_CONTEXT) ++s.stats.deleteBuffersWithoutContextCalls;
            ++s.stats.deleteBufferCalls;
            s.buffers.erase(buffers[i]);
        }
    }
}

void glDispatchCompute(GLuint gx, GLuint gy, GLuint gz) {
    auto& s = detail::state();
    auto& c = detail::ctxState();
    ++s.stats.dispatchCalls;
    auto& p = s.programs[c.activeProgram];
    spv_vm::RuntimeBindings bindings;
    bindings.uniforms = &p.uniforms;
    for (size_t i = 0; i < bindings.ssbo.size(); ++i) {
        if (c.boundSsbo[i]) bindings.ssbo[i] = &s.buffers[c.boundSsbo[i]].bytes;
    }
    for (size_t i = 0; i < bindings.ubo.size(); ++i) {
        if (c.boundUbo[i]) bindings.ubo[i] = &s.buffers[c.boundUbo[i]].bytes;
    }
    if (c.boundTex3D[0]) {
        const auto& t = s.textures[c.boundTex3D[0]];
        bindings.tex3d = {t.width, t.height, t.depth, &t.data};
    }
    p.module.dispatch(gx, gy, gz, bindings);
}
void glMemoryBarrier(GLbitfield) {}

} // extern "C"

#endif // SONY2FUJI_GLES_VM_IMPLEMENT

} // namespace rawlabtest
