#include "sony2fuji/lut_parser.h"
#include <algorithm>
#include <cctype>
#include <charconv>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <filesystem>
#include <locale.h>
#ifdef __APPLE__
#include <xlocale.h>
#endif
#include <set>
#include <string_view>
#include <sys/stat.h>
#include "../../third_party/nlohmann/json.hpp"
#include "sha256.h"
#include "parsed_resource_cache.h"
#include "lut_compatibility.h"
#include "lut_contract_json.h"

namespace sony2fuji {
namespace {
constexpr bool isAsciiSpace(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r';
}

std::string compact(std::string_view text) {
    std::string result;
    result.reserve(text.size());
    for (unsigned char c : text) {
        if (c >= '0' && c <= '9') {
            result += static_cast<char>(c);
        } else if (c >= 'A' && c <= 'Z') {
            result += static_cast<char>(c + ('a' - 'A'));
        } else if (c >= 'a' && c <= 'z') {
            result += static_cast<char>(c);
        }
    }
    return result;
}

bool parseFloatCLocale(const char* token, size_t len, float& out) {
#ifdef _WIN32
    struct LocaleHolder {
        _locale_t loc = _create_locale(LC_ALL, "C");
        ~LocaleHolder() {
            if (loc) _free_locale(loc);
        }
    };
    static const LocaleHolder holder;
#else
    struct LocaleHolder {
        locale_t loc = newlocale(LC_NUMERIC_MASK, "C", nullptr);
        ~LocaleHolder() {
            if (loc) freelocale(loc);
        }
    };
    static const LocaleHolder holder;
#endif
    char stackBuf[128];
    std::string heapBuf;
    const char* buf = nullptr;
    if (len < sizeof(stackBuf)) {
        std::memcpy(stackBuf, token, len);
        stackBuf[len] = '\0';
        buf = stackBuf;
    } else {
        heapBuf.assign(token, len);
        buf = heapBuf.c_str();
    }
    char* endPtr = nullptr;
#ifdef _WIN32
    out = holder.loc ? _strtof_l(buf, &endPtr, holder.loc) : std::strtof(buf, &endPtr);
#else
    out = holder.loc ? strtof_l(buf, &endPtr, holder.loc) : std::strtof(buf, &endPtr);
#endif
    return endPtr == buf + len && std::isfinite(out);
}

bool fastParseFloat(const char*& cur, const char* end, float& out) {
    while (cur < end && isAsciiSpace(*cur)) ++cur;
    if (cur == end) return false;
    const char* const tokenStart = cur;
    bool neg = false;
    if (*cur == '-') {
        neg = true;
        ++cur;
    } else if (*cur == '+') {
        ++cur;
    }
    uint64_t mantissa = 0;
    int sigDigits = 0;
    int exp10 = 0;
    bool anyDigit = false;
    bool needsFallback = false;
    while (cur < end && *cur >= '0' && *cur <= '9') {
        anyDigit = true;
        const unsigned d = static_cast<unsigned>(*cur - '0');
        if (mantissa != 0 || d != 0) {
            if (sigDigits < 15) {
                mantissa = mantissa * 10 + d;
                ++sigDigits;
            } else {
                needsFallback = true;
            }
        }
        ++cur;
    }
    if (cur < end && *cur == '.') {
        ++cur;
        while (cur < end && *cur >= '0' && *cur <= '9') {
            anyDigit = true;
            const unsigned d = static_cast<unsigned>(*cur - '0');
            if (mantissa != 0 || d != 0) {
                if (sigDigits < 15) {
                    mantissa = mantissa * 10 + d;
                    ++sigDigits;
                    --exp10;
                } else {
                    needsFallback = true;
                }
            } else {
                // Leading fractional zeros when mantissa == 0 still shift the decimal point.
                if (exp10 > -100000) --exp10;
            }
            ++cur;
        }
    }
    if (!anyDigit) return false;
    if (cur < end && (*cur == 'e' || *cur == 'E')) {
        ++cur;
        bool expNeg = false;
        if (cur < end && (*cur == '-' || *cur == '+')) {
            expNeg = (*cur == '-');
            ++cur;
        }
        if (cur == end || *cur < '0' || *cur > '9') return false;
        int parsedExp = 0;
        while (cur < end && *cur >= '0' && *cur <= '9') {
            if (parsedExp < 100000) parsedExp = parsedExp * 10 + (*cur - '0');
            ++cur;
        }
        exp10 += expNeg ? -parsedExp : parsedExp;
    }
    if (cur < end && !isAsciiSpace(*cur) && *cur != '#') return false;

    if (mantissa == 0 && !needsFallback) {
        out = neg ? -0.0f : 0.0f;
        return true;
    }
    if (!needsFallback && exp10 >= -22 && exp10 <= 22) {
        static constexpr double kPow10[23] = {
            1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
            1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22
        };
        double d = static_cast<double>(mantissa);
        if (exp10 > 0) d *= kPow10[exp10];
        else if (exp10 < 0) d /= kPow10[-exp10];
        out = static_cast<float>(neg ? -d : d);
        return std::isfinite(out);
    }
    return parseFloatCLocale(tokenStart, static_cast<size_t>(cur - tokenStart), out);
}

bool readRGB(const char* cur, const char* end, RGB& p) {
    if (!fastParseFloat(cur, end, p.r) ||
        !fastParseFloat(cur, end, p.g) ||
        !fastParseFloat(cur, end, p.b)) return false;
    while (cur < end && isAsciiSpace(*cur)) ++cur;
    return cur == end || *cur == '#';
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
    if (bytes.size() > 256u * 1024u * 1024u) return ErrorCode::InvalidFormat;
    vlt_ = vlt;
    std::string gamma, gamut, style, compatibility, contractText;
    std::streamoff compatibilityOffset = -1;
    std::vector<RGB> values;
    bool minSeen = false, maxSeen = false, vltHeader = false, vltSource = false, duplicateContract = false;
    bool hdrLook = false;
    std::set<std::string> colorKeys;
    bool duplicateColor = false;
    size_t bytesRead = 0;
    const std::string_view sv(bytes);
    size_t pos = 0;
    while (pos < sv.size()) {
        const size_t lineOffset = pos;
        const size_t nl = sv.find('\n', pos);
        std::string_view line = (nl == std::string_view::npos) ? sv.substr(pos) : sv.substr(pos, nl - pos);
        pos = (nl == std::string_view::npos) ? sv.size() : nl + 1;
        // 兼容记录必须是最后一行；原文件的所有字节都在该记录之前。
        if (compatibilityOffset >= 0) return ErrorCode::InvalidFormat;
        bytesRead += line.size() + 1;
        if (bytesRead > 256u * 1024u * 1024u || line.size() > 65536) return ErrorCode::InvalidFormat;
        if (lineOffset == 0 && line.size() >= 3 && line.compare(0, 3, "\xEF\xBB\xBF") == 0) line.remove_prefix(3);
        const auto first = line.find_first_not_of(" \t\r");
        if (first == std::string_view::npos) continue;
        line.remove_prefix(first);
        if (line.front() == '#') {
            if (line.back() == '\r') line.remove_suffix(1);
            if (line == "# panasonic vlt file version 1.0") vltHeader = true;
            if (line.size() >= 19 && line.compare(0, 19, "# source vlt file \"") == 0 && line.back() == '"') vltSource = true;
            if (line.size() >= 17 && line.compare(0, 17, "#LUMIXPHOTOSTYLE ") == 0) {
                duplicateColor |= !colorKeys.insert("lumixphotostyle").second;
                style = compact(line.substr(17));
            }
            const auto colon = line.find(':');
            if (colon == std::string_view::npos) continue;
            const auto key = compact(line.substr(1, colon - 1));
            const auto value = line.substr(colon + 1);
            if (key == "gamma" || key == "gamut") duplicateColor |= !colorKeys.insert(key).second;
            if (key == "rawlabcolorcontract") {
                duplicateContract |= explicitContract_;
                explicitContract_ = true;
                contractText.assign(value);
                contractState_ = readContract(contractText, colorContract_);
            }
            if (key == "rawlabhdrlook") {
                const auto start = value.find_first_not_of(" \t");
                const auto end = value.find_last_not_of(" \t");
                if (hdrLook || size_ || start == std::string_view::npos ||
                    value.substr(start, end - start + 1) != "display-linear-srgb-v1") return ErrorCode::InvalidFormat;
                hdrLook = true;
            }
            if (key == "rawlabcompatibility") {
                compatibility.assign(value);
                compatibilityOffset = static_cast<std::streamoff>(lineOffset);
            }
            if (key == "gamma") gamma = compact(value);
            if (key == "gamut") gamut = compact(value);
            if (key == "title") title_.assign(value);
            continue;
        }
        const char* const lineStart = line.data();
        const char* const lineEnd = lineStart + line.size();
        const char firstChar = *lineStart;
        const bool looksNumeric = (firstChar >= '0' && firstChar <= '9') ||
            firstChar == '-' || firstChar == '+' || firstChar == '.';
        if (!looksNumeric) {
            const char* ks = lineStart;
            while (ks < lineEnd && isAsciiSpace(*ks)) ++ks;
            const char* ke = ks;
            while (ke < lineEnd && !isAsciiSpace(*ke)) ++ke;
            const std::string_view key(ks, static_cast<size_t>(ke - ks));
            const std::string_view rest(ke, static_cast<size_t>(lineEnd - ke));
            if (key == "TITLE") {
                title_.assign(rest);
                continue;
            }
            if (key == "LUT_3D_SIZE") {
                const char* s = rest.data();
                const char* const restEnd = s + rest.size();
                while (s < restEnd && isAsciiSpace(*s)) ++s;
                if (size_ || s == restEnd) return ErrorCode::InvalidFormat;
                if (*s == '+' && s + 1 < restEnd && s[1] >= '0' && s[1] <= '9') ++s;
                int parsedSize = 0;
                const auto [ptr, ec] = std::from_chars(s, restEnd, parsedSize);
                if (ec != std::errc() || parsedSize < 2 || parsedSize > (hdrLook ? 65 : 256))
                    return ErrorCode::InvalidFormat;
                size_ = parsedSize;
                if (vlt_ && size_ != 17) return ErrorCode::InvalidFormat;
                values.reserve(static_cast<size_t>(size_) * size_ * size_);
                continue;
            }
            if (key == "DOMAIN_MIN") {
                if (vlt_) return ErrorCode::InvalidFormat;
                if (minSeen || !readRGB(ke, lineEnd, domainMin_)) return ErrorCode::ParseError;
                minSeen = true;
                continue;
            }
            if (key == "DOMAIN_MAX") {
                if (vlt_) return ErrorCode::InvalidFormat;
                if (maxSeen || !readRGB(ke, lineEnd, domainMax_)) return ErrorCode::ParseError;
                maxSeen = true;
                continue;
            }
        }
        RGB value;
        if (!size_ || !readRGB(lineStart, lineEnd, value)) return ErrorCode::ParseError;
        if (vlt_) {
            for (float n : {value.r, value.g, value.b})
                if (n < 0 || n > 4095 || std::floor(n) != n) return ErrorCode::InvalidFormat;
            value = RGB(value.r / 4095.f, value.g / 4095.f, value.b / 4095.f);
        }
        if (values.size() >= static_cast<size_t>(size_) * size_ * size_) return ErrorCode::ParseError;
        values.push_back(value);
    }
    if (!size_ || values.size() != static_cast<size_t>(size_)*size_*size_ ||
        domainMin_.r >= domainMax_.r || domainMin_.g >= domainMax_.g || domainMin_.b >= domainMax_.b)
        return ErrorCode::ParseError;
    // CUBE specifies R-fast order, independent of the output color variation.
    data_ = std::move(values);
    if (vlt_ && (!vltHeader || !vltSource)) return ErrorCode::InvalidFormat;
    if (hdrLook) {
        const auto coversHDR = [](float low, float high) { return low >= -16 && low <= 0 && high >= 2 && high <= 64; };
        const auto validValue = [](const RGB& p) {
            return std::min({p.r, p.g, p.b}) >= -16 && std::max({p.r, p.g, p.b}) <= 64;
        };
        if (vlt_ || explicitContract_ || compatibilityOffset >= 0 || !gamma.empty() || !gamut.empty() || !style.empty() ||
            !maxSeen || !coversHDR(domainMin_.r, domainMax_.r) || !coversHDR(domainMin_.g, domainMax_.g) ||
            !coversHDR(domainMin_.b, domainMax_.b) || !std::all_of(data_.begin(), data_.end(), validValue))
            return ErrorCode::InvalidFormat;
        hdrLookContract_ = true;
        contractState_ = LUTContractState::Unsupported;
        return ErrorCode::Success;
    }
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
    const auto format = detectFormat(path);
    if (format != "cube" && format != "vlt") return nullptr;
    std::ifstream file(std::filesystem::u8path(path), std::ios::binary | std::ios::ate);
    if (!file) return nullptr;
    const auto length = file.tellg();
    if (length < 0 || length > 256u * 1024u * 1024u) return nullptr;
    file.seekg(0);
    std::string bytes(static_cast<size_t>(length), '\0');
    if (!file.read(bytes.data(), bytes.size()) || file.peek() != std::char_traits<char>::eof()) return nullptr;
    // 文件可能被同大小内容覆盖且时间戳不变；缓存命中必须基于实际字节。
    const auto digest = hash::sha256Bytes(bytes.data(), bytes.size());
    static ParsedResourceCache<std::shared_ptr<LUT3D>> cache;
    if (auto cached = cache.find(path, digest)) return *cached;
    auto parsed = std::make_shared<LUT3D>();
    if (parsed->loadFromData(bytes, format == "vlt") != ErrorCode::Success) return nullptr;
    return cache.put(path, digest, std::move(parsed));
}

std::string LUTParser::detectFormat(const std::string& path) {
    const auto dot = path.find_last_of('.');
    return dot == std::string::npos ? "" : compact(path.substr(dot+1));
}
}
