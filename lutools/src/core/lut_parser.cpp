#include "sony2fuji/lut_parser.h"
#include <algorithm>
#include <cctype>
#include <cmath>
#include <fstream>
#include <filesystem>
#include <mutex>
#include <set>
#include <sstream>
#include <sys/stat.h>
#include "../../third_party/nlohmann/json.hpp"
#include "sha256.h"
#include "lut_compatibility.h"
#include "lut_contract_json.h"

namespace sony2fuji {
namespace {
std::string compact(std::string text) {
    std::string result;
    for (unsigned char c : text) if (std::isalnum(c)) result += std::tolower(c);
    return result;
}
bool readRGB(std::istringstream& line, RGB& p) {
    if (!(line >> p.r >> p.g >> p.b) ||
        !std::isfinite(p.r) || !std::isfinite(p.g) || !std::isfinite(p.b)) return false;
    line >> std::ws;
    return line.eof() || line.peek() == '#';
}
LUTTransfer logTransfer(const std::string& name) {
    if (name == "flog") return LUTTransfer::FLog;
    if (name == "flog2") return LUTTransfer::FLog2;
    if (name == "flog2c") return LUTTransfer::FLog2C;
    return LUTTransfer::Unknown;
}
using nlohmann::json;
bool keys(const json& object, std::initializer_list<const char*> names) {
    if (!object.is_object() || object.size() != names.size()) return false;
    for (const auto* name : names) if (!object.contains(name)) return false;
    return true;
}
bool meaningful(const json& value) {
    if (!value.is_string()) return false;
    const auto text = value.get<std::string>();
    return text.size() <= 4096 && text.find_first_not_of(" \r\n\t") != std::string::npos &&
        text.find('\0') == std::string::npos;
}
bool signal(const json& value, LUTSignal& out) {
    if (!keys(value, {"space", "reference", "range"})) return false;
    const auto space = value.at("space").get<std::string>();
    if (space == "srgb") out.space = LUTColorSpace::SRGB;
    else if (space == "rec709-gamma24") out.space = LUTColorSpace::Rec709Gamma24;
    else if (space == "linear-srgb") out.space = LUTColorSpace::LinearSRGB;
    else if (space == "vlog-vgamut") out.space = LUTColorSpace::VLogVGamut;
    else if (space == "slog3-sgamut3") out.space = LUTColorSpace::SLog3SGamut3;
    else if (space == "slog3-sgamut3-cine") out.space = LUTColorSpace::SLog3SGamut3Cine;
    else return false;
    const auto reference = value.at("reference").get<std::string>();
    if (reference == "scene") out.reference = LUTReference::Scene;
    else if (reference == "display") out.reference = LUTReference::Display;
    else return false;
    if ((out.space == LUTColorSpace::SRGB || out.space == LUTColorSpace::Rec709Gamma24) && out.reference != LUTReference::Display) return false;
    if (out.space >= LUTColorSpace::VLogVGamut && out.reference != LUTReference::Scene) return false;
    const auto range = value.at("range").get<std::string>();
    if (range == "full") out.range = LUTRange::Full;
    else if (range == "legal10") out.range = LUTRange::Legal10;
    else return false;
    return true;
}
LUTContractState readContract(const std::string& text, LUTColorContract& out) {
    try {
        auto data = parseLUTJSON(text);
        const bool missingEvidence = !data.contains("evidence");
        if (missingEvidence) data["evidence"] = nullptr;
        if (!keys(data, {"version", "input", "output", "interpolation", "base_rendering", "evidence"}) ||
            !data["version"].is_number_integer() || data["version"] != 1) return LUTContractState::Invalid;
        if (!signal(data["input"], out.input) || !signal(data["output"], out.output)) return LUTContractState::Unsupported;
        const auto interpolation = data["interpolation"].get<std::string>();
        if (interpolation == "linear") out.interpolation = LUTInterpolation::Linear;
        else if (interpolation == "tetrahedral") out.interpolation = LUTInterpolation::Tetrahedral;
        else return LUTContractState::Unsupported;
        const auto base = data["base_rendering"].get<std::string>();
        if (base == "none") out.base = LUTBaseRendering::None;
        else if (base == "rawlab-neutral-v1") out.base = LUTBaseRendering::RawLabNeutral;
        else if (base == "source-display") out.base = LUTBaseRendering::SourceDisplay;
        else return LUTContractState::Unsupported;
        if (out.input.reference == LUTReference::Display &&
            (out.base == LUTBaseRendering::None || out.output.reference == LUTReference::Scene)) return LUTContractState::Unsupported;
        if (out.input.reference == LUTReference::Scene && out.base != LUTBaseRendering::None) return LUTContractState::Unsupported;
        const auto& evidence = data["evidence"];
        if (missingEvidence || evidence.is_null()) return LUTContractState::MissingReference;
        if (!keys(evidence, {"source", "conditions"})) return LUTContractState::Invalid;
        if (!meaningful(evidence["source"]) || !meaningful(evidence["conditions"])) return LUTContractState::MissingReference;
        out.evidenceSource = evidence["source"].get<std::string>();
        out.evidenceConditions = evidence["conditions"].get<std::string>();
        return LUTContractState::Declared;
    } catch (const std::exception&) { return LUTContractState::Invalid; }
}
}
LUTContractState parseLUTColorContract(const std::string& text, LUTColorContract& out) { return readContract(text,out); }

ErrorCode LUT3D::loadFromFile(const std::string& path) { return parseCubeFile(path); }

RGB LUT3D::getValue(int r, int g, int b) const {
    if (r < 0 || g < 0 || b < 0 || r >= size_ || g >= size_ || b >= size_) return RGB();
    return data_[static_cast<size_t>((b * size_ + g) * size_ + r)];
}

ErrorCode LUT3D::parseCubeFile(const std::string& path) {
    *this = LUT3D();
    std::ifstream file(std::filesystem::u8path(path), std::ios::binary);
    if (!file) return ErrorCode::FileNotFound;
    file.seekg(0,std::ios::end);
    const auto length=file.tellg();
    if(length<0 || length>256u*1024u*1024u) return ErrorCode::InvalidFormat;
    file.seekg(0);
    std::string bytes(static_cast<size_t>(length),'\0');
    if(!file.read(bytes.data(),bytes.size())) return ErrorCode::ParseError;
    return loadFromData(bytes,LUTParser::detectFormat(path)=="vlt");
}

ErrorCode LUT3D::loadFromData(const std::string& bytes, bool vlt) {
    *this = LUT3D();
    if(bytes.size()>256u*1024u*1024u) return ErrorCode::InvalidFormat;
    std::istringstream file(bytes);
    vlt_ = vlt;
    std::string line, gamma, gamut, style, compatibility, contractText;
    std::streamoff compatibilityOffset = -1;
    std::vector<RGB> values;
    bool minSeen = false, maxSeen = false, vltHeader = false, vltSource = false, duplicateContract = false;
    std::set<std::string> colorKeys;
    bool duplicateColor = false;
    size_t bytesRead = 0;
    while (file) {
        const auto lineOffset = file.tellg();
        if (!std::getline(file, line)) break;
        // 兼容记录必须是最后一行；原文件的所有字节都在该记录之前。
        if (compatibilityOffset >= 0) return ErrorCode::InvalidFormat;
        bytesRead += line.size() + 1;
        if (bytesRead > 256u*1024u*1024u || line.size() > 65536) return ErrorCode::InvalidFormat;
        if (bytesRead == line.size()+1 && line.compare(0, 3, "\xEF\xBB\xBF") == 0) line.erase(0, 3);
        auto first = line.find_first_not_of(" \t\r");
        if (first == std::string::npos) continue;
        line.erase(0, first);
        if (line.front() == '#') {
            if (line.back() == '\r') line.pop_back();
            if (line == "# panasonic vlt file version 1.0") vltHeader = true;
            if (line.rfind("# source vlt file \"", 0) == 0 && line.back() == '"') vltSource = true;
            if (line.rfind("#LUMIXPHOTOSTYLE ", 0) == 0) {
                duplicateColor |= !colorKeys.insert("lumixphotostyle").second;
                style = compact(line.substr(17));
            }
            const auto colon = line.find(':');
            if (colon == std::string::npos) continue;
            auto key = compact(line.substr(1, colon-1));
            auto value = line.substr(colon+1);
            if (key == "gamma" || key == "gamut") duplicateColor |= !colorKeys.insert(key).second;
            if (key == "rawlabcolorcontract") {
                duplicateContract |= explicitContract_;
                explicitContract_ = true;
                contractText = value;
                contractState_ = readContract(value, colorContract_);
            }
            if (key == "rawlabcompatibility") {
                compatibility = value;
                compatibilityOffset = lineOffset;
            }
            if (key == "gamma") gamma = compact(value);
            if (key == "gamut") gamut = compact(value);
            if (key == "title") title_ = value;
            continue;
        }
        std::istringstream input(line);
        std::string key;
        input >> key;
        if (key == "TITLE") {
            std::getline(input, title_);
        } else if (key == "LUT_3D_SIZE") {
            if (size_ || !(input >> size_) || size_ < 2 || size_ > 256) return ErrorCode::InvalidFormat;
            if (vlt_ && size_ != 17) return ErrorCode::InvalidFormat;
            values.reserve(static_cast<size_t>(size_) * size_ * size_);
        } else if (key == "DOMAIN_MIN") {
            if (vlt_) return ErrorCode::InvalidFormat;
            if (minSeen || !readRGB(input, domainMin_)) return ErrorCode::ParseError;
            minSeen = true;
        } else if (key == "DOMAIN_MAX") {
            if (vlt_) return ErrorCode::InvalidFormat;
            if (maxSeen || !readRGB(input, domainMax_)) return ErrorCode::ParseError;
            maxSeen = true;
        } else {
            RGB value;
            std::istringstream numbers(line);
            if (!size_ || !readRGB(numbers, value)) return ErrorCode::ParseError;
            if (vlt_) {
                for (float n : {value.r, value.g, value.b})
                    if (n < 0 || n > 4095 || std::floor(n) != n) return ErrorCode::InvalidFormat;
                value = RGB(value.r/4095.f, value.g/4095.f, value.b/4095.f);
            }
            if (values.size() >= static_cast<size_t>(size_)*size_*size_) return ErrorCode::ParseError;
            values.push_back(value);
        }
    }
    if (!size_ || values.size() != static_cast<size_t>(size_)*size_*size_ ||
        domainMin_.r >= domainMax_.r || domainMin_.g >= domainMax_.g || domainMin_.b >= domainMax_.b)
        return ErrorCode::ParseError;
    // CUBE specifies R-fast order, independent of the output color variation.
    data_ = std::move(values);
    if (vlt_ && (!vltHeader || !vltSource)) return ErrorCode::InvalidFormat;
    if (duplicateColor || (!explicitContract_ && !style.empty() && (!gamma.empty() || !gamut.empty()))) {
        contractState_ = LUTContractState::Invalid;
        return ErrorCode::Success;
    }
    if (compatibilityOffset >= 0) {
        try {
            auto record = parseLUTJSON(compatibility);
            const auto extremeConfirmation = record.value("confirmed_extreme_values", false);
            record.erase("confirmed_extreme_values");
            const auto originalState = contractState_;
            contractState_ = LUTContractState::Invalid;
            if (!keys(record, {"version", "source_bytes", "source_sha256", "confirmed", "contract"}) ||
                !record["version"].is_number_integer() || record["version"] != 1 || !record["source_bytes"].is_number_unsigned() ||
                !record["confirmed"].is_boolean() || !record["confirmed"].get<bool>() ||
                !record["source_sha256"].is_string() || duplicateContract || !gamma.empty() || !gamut.empty() ||
                (explicitContract_ && originalState != LUTContractState::MissingReference)) return ErrorCode::Success;
            if (explicitContract_) {
                auto originalContract = parseLUTJSON(contractText); originalContract.erase("evidence");
                if (originalContract != record["contract"]) return ErrorCode::Success;
            }
            if (!extremeConfirmation && std::any_of(data_.begin(),data_.end(),[](RGB value) {
                    return std::max({std::abs(value.r),std::abs(value.g),std::abs(value.b)}) > 16.f;
                })) return ErrorCode::Success;
            const auto size = record["source_bytes"].get<size_t>();
            if (size > 256u*1024u*1024u || compatibilityOffset < 1 ||
                size != static_cast<size_t>(compatibilityOffset - 1)) return ErrorCode::Success;
            if (size>=bytes.size() || bytes[size]!='\n' ||
                hash::sha256Bytes(bytes.data(), size) != record["source_sha256"].get<std::string>()) return ErrorCode::Success;
            LUTColorContract effective;
            if (record["contract"].contains("evidence") ||
                readContract(record["contract"].dump(), effective) != LUTContractState::MissingReference) return ErrorCode::Success;
            if ((!style.empty() && style != "std" && style != "vlog") ||
                (style == "vlog" && effective.input.space != LUTColorSpace::VLogVGamut) ||
                (style == "std" && effective.input.reference != LUTReference::Display)) return ErrorCode::Success;
            colorContract_ = effective;
            explicitContract_ = true;
            contractState_ = effective.base == LUTBaseRendering::RawLabNeutral
                ? LUTContractState::ApproximateBase : LUTContractState::Compatibility;
        } catch (const std::exception&) { contractState_ = LUTContractState::Invalid; }
        return ErrorCode::Success;
    }
    if (explicitContract_) {
        if (duplicateContract || !gamma.empty() || !gamut.empty()) contractState_ = LUTContractState::Invalid;
        if (!style.empty() && contractState_ == LUTContractState::Declared) {
            const bool matchingVLog = style == "vlog" && colorContract_.input.space == LUTColorSpace::VLogVGamut;
            const bool matchingDisplay = style == "std" && colorContract_.input.reference == LUTReference::Display &&
                colorContract_.base == LUTBaseRendering::SourceDisplay;
            if (!matchingVLog && !matchingDisplay) contractState_ = LUTContractState::Unsupported;
        }
        return ErrorCode::Success;
    }
    if (vlt_) return ErrorCode::Success;
    if (gamma == "srgbtosrgb" && gamut == "iturbt709toiturbt709") {
        inputTransfer_ = LUTTransfer::SRGB;
        outputTransfer_ = LUTTransfer::Display;
        contractState_ = LUTContractState::Legacy;
        return ErrorCode::Success;
    }
    const auto separator = gamma.find("to");
    if (separator != std::string::npos && separator + 2 < gamma.size()) {
        const auto input = logTransfer(gamma.substr(0, separator));
        const auto expectedGamut = input == LUTTransfer::FLog2C
            ? "fgamutctoiturbt709" : "fgamuttoiturbt709";
        if (input != LUTTransfer::Unknown && gamut == expectedGamut) {
            inputTransfer_ = input;
            outputTransfer_ = logTransfer(gamma.substr(separator + 2));
            if (outputTransfer_ == LUTTransfer::Unknown) outputTransfer_ = LUTTransfer::Display;
            contractState_ = LUTContractState::Legacy;
        }
    }
    return ErrorCode::Success;
}

std::unique_ptr<LUT3D> LUTParser::loadLUT(const std::string& path) {
    if (detectFormat(path) != "cube" && detectFormat(path) != "vlt") return nullptr;
    auto lut = std::make_unique<LUT3D>();
    return lut->loadFromFile(path) == ErrorCode::Success ? std::move(lut) : nullptr;
}

std::shared_ptr<LUT3D> LUTParser::loadLUTCached(const std::string& path) {
    std::error_code error;
    const auto filePath = std::filesystem::u8path(path);
    const auto stamp = std::filesystem::last_write_time(filePath, error);
    if (error) return nullptr;
    const auto bytes = std::filesystem::file_size(filePath, error);
    if (error) return nullptr;
    static std::mutex mutex;
    static std::string previous;
    static std::filesystem::file_time_type modified;
    static uintmax_t size = 0;
    static std::shared_ptr<LUT3D> cached;
    std::lock_guard<std::mutex> lock(mutex);
    if (previous == path && modified == stamp && size == bytes && cached) return cached;
    cached = loadLUT(path);
    previous = path; modified = stamp; size = bytes;
    return cached;
}

std::string LUTParser::detectFormat(const std::string& path) {
    const auto dot = path.find_last_of('.');
    return dot == std::string::npos ? "" : compact(path.substr(dot+1));
}
}
