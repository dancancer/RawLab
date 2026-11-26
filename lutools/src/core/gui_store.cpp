#include "sony2fuji/gui_store.h"

#include "nlohmann/json.hpp"
#include "platform/file_lock.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <limits>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace sony2fuji {
namespace gui_store {
namespace {

using Json = nlohmann::json;
using platform::MacFileIdentity;
using platform::ScopedFileLock;
using platform::StoreError;
using platform::WindowsFileIdentity;

// ---------------------------------------------------------------------------
// Strict RFC 8259 JSON Byte-Slice Scanner
// ---------------------------------------------------------------------------

struct JsonNode {
    enum class Kind { Object, Array, String, Number, Boolean, Null };
    Kind kind = Kind::Null;
    size_t start = 0;
    size_t end = 0;
    bool ownDuplicateKey = false;
    bool nestedDuplicateKey = false;
    std::string stringVal;
    std::string numberLiteral;
    bool boolVal = false;
    std::vector<std::pair<std::string, JsonNode>> members;
    std::vector<JsonNode> items;
};

bool isIntegerLiteral(const std::string& lit) {
    if (lit.empty()) return false;
    size_t i = (lit[0] == '-') ? 1 : 0;
    if (i >= lit.size()) return false;
    for (; i < lit.size(); ++i) {
        if (lit[i] < '0' || lit[i] > '9') return false;
    }
    return true;
}

bool isVersionOneLiteral(const JsonNode* node) {
    if (node == nullptr || node->kind != JsonNode::Kind::Number || !isIntegerLiteral(node->numberLiteral)) {
        return false;
    }
    try {
        size_t pos = 0;
        const long long val = std::stoll(node->numberLiteral, &pos);
        return pos == node->numberLiteral.size() && val == 1;
    } catch (const std::exception&) {
        return false;
    }
}

class StrictJsonScanner {
public:
    explicit StrictJsonScanner(const std::string& bytes) : data_(bytes) {
        // Tolerate at most ONE leading UTF-8 BOM at byte 0 (matches EditRecordPersistenceTests).
        if (data_.size() >= 3 &&
            static_cast<unsigned char>(data_[0]) == 0xEF &&
            static_cast<unsigned char>(data_[1]) == 0xBB &&
            static_cast<unsigned char>(data_[2]) == 0xBF) {
            idx_ = 3;
        }
    }

    JsonNode scanRoot() {
        JsonNode root = parseValue(0);
        skipWs();
        if (idx_ != data_.size()) {
            throw StoreError(6, "output_io_error", "Trailing content in JSON");
        }
        return root;
    }

private:
    const std::string& data_;
    size_t idx_ = 0;

    void skipWs() {
        while (idx_ < data_.size()) {
            const char c = data_[idx_];
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
                ++idx_;
            } else {
                break;
            }
        }
    }

    static bool isHex(char c, uint32_t& out) {
        if (c >= '0' && c <= '9') {
            out = static_cast<uint32_t>(c - '0');
            return true;
        }
        if (c >= 'a' && c <= 'f') {
            out = static_cast<uint32_t>(10 + c - 'a');
            return true;
        }
        if (c >= 'A' && c <= 'F') {
            out = static_cast<uint32_t>(10 + c - 'A');
            return true;
        }
        return false;
    }

    uint32_t parseHex4() {
        if (idx_ + 4 > data_.size()) {
            throw StoreError(6, "output_io_error", "Truncated \\u escape in JSON");
        }
        uint32_t val = 0;
        for (int i = 0; i < 4; ++i) {
            uint32_t d = 0;
            if (!isHex(data_[idx_ + static_cast<size_t>(i)], d)) {
                throw StoreError(6, "output_io_error", "Invalid hex digit in \\u escape");
            }
            val = (val << 4) | d;
        }
        idx_ += 4;
        return val;
    }

    static void appendUtf8(std::string& out, uint32_t cp) {
        if (cp < 0x80) {
            out.push_back(static_cast<char>(cp));
        } else if (cp < 0x800) {
            out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else if (cp < 0x10000) {
            out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else {
            out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        }
    }

    std::string parseString() {
        ++idx_; // consume opening '"'
        std::string out;
        while (idx_ < data_.size()) {
            const unsigned char b = static_cast<unsigned char>(data_[idx_]);
            if (b == '"') {
                ++idx_;
                return out;
            }
            if (b == '\\') {
                ++idx_;
                if (idx_ >= data_.size()) {
                    throw StoreError(6, "output_io_error", "Unterminated escape in JSON");
                }
                const char esc = data_[idx_++];
                switch (esc) {
                    case '"': out.push_back('"'); break;
                    case '\\': out.push_back('\\'); break;
                    case '/': out.push_back('/'); break;
                    case 'b': out.push_back('\b'); break;
                    case 'f': out.push_back('\f'); break;
                    case 'n': out.push_back('\n'); break;
                    case 'r': out.push_back('\r'); break;
                    case 't': out.push_back('\t'); break;
                    case 'u': {
                        const uint32_t code = parseHex4();
                        if (code >= 0xD800 && code <= 0xDBFF) {
                            if (idx_ + 2 > data_.size() || data_[idx_] != '\\' || data_[idx_ + 1] != 'u') {
                                throw StoreError(6, "output_io_error", "Missing low surrogate in JSON");
                            }
                            idx_ += 2;
                            const uint32_t low = parseHex4();
                            if (low < 0xDC00 || low > 0xDFFF) {
                                throw StoreError(6, "output_io_error", "Invalid low surrogate in JSON");
                            }
                            const uint32_t cp = 0x10000 + (((code - 0xD800) << 10) | (low - 0xDC00));
                            appendUtf8(out, cp);
                        } else if (code >= 0xDC00 && code <= 0xDFFF) {
                            throw StoreError(6, "output_io_error", "Lone low surrogate in JSON");
                        } else {
                            appendUtf8(out, code);
                        }
                        break;
                    }
                    default:
                        throw StoreError(6, "output_io_error", "Invalid escape sequence in JSON");
                }
            } else {
                if (b < 0x20) {
                    throw StoreError(6, "output_io_error", "Unescaped control char in JSON string");
                }
                // Validate raw UTF-8 sequence.
                size_t len = 1;
                uint32_t cp = b;
                if (b < 0x80) {
                    len = 1;
                } else if ((b & 0xE0) == 0xC0) {
                    if (idx_ + 1 >= data_.size()) throw StoreError(6, "output_io_error", "Invalid UTF-8 in JSON");
                    const unsigned char b1 = static_cast<unsigned char>(data_[idx_ + 1]);
                    if ((b1 & 0xC0) != 0x80) throw StoreError(6, "output_io_error", "Invalid UTF-8 in JSON");
                    cp = (static_cast<uint32_t>(b & 0x1F) << 6) | (b1 & 0x3F);
                    if (cp < 0x80) throw StoreError(6, "output_io_error", "Overlong UTF-8 in JSON");
                    len = 2;
                } else if ((b & 0xF0) == 0xE0) {
                    if (idx_ + 2 >= data_.size()) throw StoreError(6, "output_io_error", "Invalid UTF-8 in JSON");
                    const unsigned char b1 = static_cast<unsigned char>(data_[idx_ + 1]);
                    const unsigned char b2 = static_cast<unsigned char>(data_[idx_ + 2]);
                    if ((b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80) throw StoreError(6, "output_io_error", "Invalid UTF-8 in JSON");
                    cp = (static_cast<uint32_t>(b & 0x0F) << 12) | (static_cast<uint32_t>(b1 & 0x3F) << 6) | (b2 & 0x3F);
                    if (cp < 0x800 || (cp >= 0xD800 && cp <= 0xDFFF)) throw StoreError(6, "output_io_error", "Invalid UTF-8 in JSON");
                    len = 3;
                } else if ((b & 0xF8) == 0xF0) {
                    if (idx_ + 3 >= data_.size()) throw StoreError(6, "output_io_error", "Invalid UTF-8 in JSON");
                    const unsigned char b1 = static_cast<unsigned char>(data_[idx_ + 1]);
                    const unsigned char b2 = static_cast<unsigned char>(data_[idx_ + 2]);
                    const unsigned char b3 = static_cast<unsigned char>(data_[idx_ + 3]);
                    if ((b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80 || (b3 & 0xC0) != 0x80)
                        throw StoreError(6, "output_io_error", "Invalid UTF-8 in JSON");
                    cp = (static_cast<uint32_t>(b & 0x07) << 18) | (static_cast<uint32_t>(b1 & 0x3F) << 12) |
                         (static_cast<uint32_t>(b2 & 0x3F) << 6) | (b3 & 0x3F);
                    if (cp < 0x10000 || cp > 0x10FFFF) throw StoreError(6, "output_io_error", "Invalid UTF-8 in JSON");
                    len = 4;
                } else {
                    throw StoreError(6, "output_io_error", "Invalid UTF-8 byte in JSON");
                }
                out.append(data_, idx_, len);
                idx_ += len;
            }
        }
        throw StoreError(6, "output_io_error", "Unterminated JSON string");
    }

    static bool isValidNumberLiteral(const std::string& s) {
        size_t i = 0;
        const size_t n = s.size();
        if (i < n && s[i] == '-') ++i;
        if (i >= n || s[i] < '0' || s[i] > '9') return false;
        if (s[i] == '0') {
            ++i;
            if (i < n && s[i] >= '0' && s[i] <= '9') return false;
        } else {
            while (i < n && s[i] >= '0' && s[i] <= '9') ++i;
        }
        if (i < n && s[i] == '.') {
            ++i;
            if (i >= n || s[i] < '0' || s[i] > '9') return false;
            while (i < n && s[i] >= '0' && s[i] <= '9') ++i;
        }
        if (i < n && (s[i] == 'e' || s[i] == 'E')) {
            ++i;
            if (i < n && (s[i] == '+' || s[i] == '-')) ++i;
            if (i >= n || s[i] < '0' || s[i] > '9') return false;
            while (i < n && s[i] >= '0' && s[i] <= '9') ++i;
        }
        return i == n;
    }

    JsonNode parseValue(int depth) {
        if (depth > 64) {
            throw StoreError(6, "output_io_error", "JSON nesting depth exceeded");
        }
        skipWs();
        if (idx_ >= data_.size()) {
            throw StoreError(6, "output_io_error", "Unexpected end of JSON");
        }
        const size_t start = idx_;
        const unsigned char b = static_cast<unsigned char>(data_[idx_]);
        if (b == '{') {
            ++idx_;
            JsonNode node;
            node.kind = JsonNode::Kind::Object;
            node.start = start;
            std::unordered_set<std::string> seen;
            skipWs();
            if (idx_ < data_.size() && data_[idx_] == '}') {
                ++idx_;
                node.end = idx_;
                return node;
            }
            while (true) {
                skipWs();
                if (idx_ >= data_.size() || data_[idx_] != '"') {
                    throw StoreError(6, "output_io_error", "Expected JSON object key string");
                }
                std::string key = parseString();
                skipWs();
                if (idx_ >= data_.size() || data_[idx_] != ':') {
                    throw StoreError(6, "output_io_error", "Expected ':' after JSON object key");
                }
                ++idx_;
                JsonNode child = parseValue(depth + 1);
                node.nestedDuplicateKey = node.nestedDuplicateKey || child.nestedDuplicateKey;
                if (!seen.insert(key).second) {
                    node.ownDuplicateKey = true;
                }
                node.members.emplace_back(std::move(key), std::move(child));
                skipWs();
                if (idx_ < data_.size() && data_[idx_] == '}') {
                    ++idx_;
                    break;
                }
                if (idx_ >= data_.size() || data_[idx_] != ',') {
                    throw StoreError(6, "output_io_error", "Expected ',' or '}' in JSON object");
                }
                ++idx_;
            }
            node.end = idx_;
            node.nestedDuplicateKey = node.nestedDuplicateKey || node.ownDuplicateKey;
            return node;
        }
        if (b == '[') {
            ++idx_;
            JsonNode node;
            node.kind = JsonNode::Kind::Array;
            node.start = start;
            skipWs();
            if (idx_ < data_.size() && data_[idx_] == ']') {
                ++idx_;
                node.end = idx_;
                return node;
            }
            while (true) {
                JsonNode item = parseValue(depth + 1);
                node.nestedDuplicateKey = node.nestedDuplicateKey || item.nestedDuplicateKey;
                node.items.push_back(std::move(item));
                skipWs();
                if (idx_ < data_.size() && data_[idx_] == ']') {
                    ++idx_;
                    break;
                }
                if (idx_ >= data_.size() || data_[idx_] != ',') {
                    throw StoreError(6, "output_io_error", "Expected ',' or ']' in JSON array");
                }
                ++idx_;
            }
            node.end = idx_;
            return node;
        }
        if (b == '"') {
            JsonNode node;
            node.kind = JsonNode::Kind::String;
            node.start = start;
            node.stringVal = parseString();
            node.end = idx_;
            return node;
        }
        if (b == 't' && data_.compare(start, 4, "true") == 0) {
            idx_ = start + 4;
            JsonNode node;
            node.kind = JsonNode::Kind::Boolean;
            node.start = start;
            node.end = idx_;
            node.boolVal = true;
            return node;
        }
        if (b == 'f' && data_.compare(start, 5, "false") == 0) {
            idx_ = start + 5;
            JsonNode node;
            node.kind = JsonNode::Kind::Boolean;
            node.start = start;
            node.end = idx_;
            node.boolVal = false;
            return node;
        }
        if (b == 'n' && data_.compare(start, 4, "null") == 0) {
            idx_ = start + 4;
            JsonNode node;
            node.kind = JsonNode::Kind::Null;
            node.start = start;
            node.end = idx_;
            return node;
        }
        while (idx_ < data_.size()) {
            const char c = data_[idx_];
            if ((c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E') {
                ++idx_;
            } else {
                break;
            }
        }
        const std::string lit = data_.substr(start, idx_ - start);
        if (!isValidNumberLiteral(lit)) {
            throw StoreError(6, "output_io_error", "Invalid JSON token");
        }
        JsonNode node;
        node.kind = JsonNode::Kind::Number;
        node.start = start;
        node.end = idx_;
        node.numberLiteral = lit;
        return node;
    }
};

bool timestampsAreIntegers(const JsonNode& node) {
    if (node.kind == JsonNode::Kind::Object) {
        for (const auto& [k, child] : node.members) {
            if (k == "created_at" || k == "updated_at") {
                if (child.kind != JsonNode::Kind::Number || !isIntegerLiteral(child.numberLiteral)) {
                    return false;
                }
            }
            if (!timestampsAreIntegers(child)) return false;
        }
    } else if (node.kind == JsonNode::Kind::Array) {
        for (const auto& item : node.items) {
            if (!timestampsAreIntegers(item)) return false;
        }
    }
    return true;
}

Json parseStrictJsonObject(const std::string& rawBytes, int errorStatus, const std::string& errorCode) {
    try {
        StrictJsonScanner scanner(rawBytes);
        const JsonNode root = scanner.scanRoot();
        if (root.nestedDuplicateKey) {
            throw StoreError(errorStatus, errorCode, "Duplicate JSON keys are forbidden");
        }
        if (root.kind != JsonNode::Kind::Object) {
            throw StoreError(errorStatus, errorCode, "JSON root must be an object");
        }
        return Json::parse(rawBytes.substr(root.start, root.end - root.start));
    } catch (const StoreError& err) {
        throw StoreError(errorStatus, errorCode, err.what());
    } catch (const std::exception& err) {
        throw StoreError(errorStatus, errorCode, err.what());
    }
}

// ---------------------------------------------------------------------------
// Helpers & Canonical Spec Rules (89 fields + HDR v1..v9)
// ---------------------------------------------------------------------------

bool isCanonicalUuidLower(const std::string& s) {
    if (s.size() != 36) return false;
    for (size_t i = 0; i < 36; ++i) {
        const char c = s[i];
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (c != '-') return false;
        } else {
            const bool hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
            if (!hex) return false;
        }
    }
    return true;
}

bool hasControlChars(const std::string& s) {
    const auto* bytes = reinterpret_cast<const unsigned char*>(s.data());
    for (size_t i = 0; i < s.size(); ++i) {
        const unsigned char b = bytes[i];
        if (b < 0x20 || b == 0x7F) return true;
        // C1 control characters U+0080..U+009F are UTF-8 encoded as 0xC2 0x80..0x9F
        if (b == 0xC2 && i + 1 < s.size()) {
            const unsigned char b1 = bytes[i + 1];
            if (b1 >= 0x80 && b1 <= 0x9F) return true;
        }
    }
    return false;
}

bool isFiniteNumberJson(const Json& j) {
    if (!j.is_number() || j.is_boolean()) return false;
    const double v = j.get<double>();
    return std::isfinite(v);
}

bool isStrictIntJson(const Json& j, int64_t& out) {
    if (!j.is_number_integer() || j.is_boolean()) return false;
    if (j.is_number_unsigned()) {
        const uint64_t u = j.get<uint64_t>();
        if (u > static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) return false;
        out = static_cast<int64_t>(u);
        return true;
    }
    out = j.get<int64_t>();
    return true;
}

double roundDigits(double value, int digits) {
    const double scale = std::pow(10.0, digits);
    const double r = std::round(value * scale) / scale;
    return r == 0.0 ? 0.0 : r;
}

std::string asciiLower(const std::string& s) {
    std::string out = s;
    for (char& c : out) {
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }
    return out;
}

enum class FieldValueType { Boolean, Integer, Number, String, Object };

struct TransferFieldSpec {
    FieldValueType valueType;
    bool nullable;
    bool hasMin;
    double minVal;
    bool hasMax;
    double maxVal;
    bool exclusiveMin;
    bool exclusiveMax;
    bool nonEmpty;
    bool hdrOnly;
    std::vector<std::string> strEnum;
    std::vector<int> intEnum;
};

const std::unordered_map<std::string, TransferFieldSpec>& transferFieldSpecs() {
    static const std::unordered_map<std::string, TransferFieldSpec> specs = [] {
        std::unordered_map<std::string, TransferFieldSpec> m;
        auto addNum = [&](const char* k, double lo, double hi, bool exMin = false, bool nullable = false, bool hdrOnly = false) {
            m[k] = TransferFieldSpec{FieldValueType::Number, nullable, true, lo, true, hi, exMin, false, false, hdrOnly, {}, {}};
        };
        auto addBool = [&](const char* k) {
            m[k] = TransferFieldSpec{FieldValueType::Boolean, false, false, 0, false, 0, false, false, false, false, {}, {}};
        };
        auto addIntEnum = [&](const char* k, std::vector<int> vals, bool nullable = false) {
            const int lo = *std::min_element(vals.begin(), vals.end());
            const int hi = *std::max_element(vals.begin(), vals.end());
            m[k] = TransferFieldSpec{FieldValueType::Integer, nullable, true, static_cast<double>(lo), true, static_cast<double>(hi), false, false, false, false, {}, std::move(vals)};
        };
        auto addStrEnum = [&](const char* k, std::vector<std::string> vals) {
            m[k] = TransferFieldSpec{FieldValueType::String, false, false, 0, false, 0, false, false, false, false, std::move(vals), {}};
        };

        m["looks.reference"] = TransferFieldSpec{FieldValueType::Object, false, false, 0, false, 0, false, false, false, false, {}, {}};
        addNum("looks.strength", 0.0, 2.0);
        addNum("light.exposure", -20.0, 20.0);
        m["light.exposure_mode"] = TransferFieldSpec{FieldValueType::String, false, false, 0, false, 0, false, false, false, false, {"scene", "preview", "sensor"}, {}};
        addNum("light.contrast", 0.0, 2.0);
        addNum("light.highlights", -1.0, 1.0);
        addNum("light.shadows", -1.0, 1.0);
        addNum("light.s_curve", -1.0, 1.0);
        m["light.curve"] = TransferFieldSpec{FieldValueType::Object, false, false, 0, false, 0, false, false, false, false, {}, {}};
        addBool("light.curve.apply_to_luminosity");
        m["light.curve.parametric"] = TransferFieldSpec{FieldValueType::Object, false, false, 0, false, 0, false, false, false, false, {}, {}};
        addNum("tone.black_point", -100.0, 100.0);
        addNum("tone.white_point", -100.0, 100.0);
        addNum("color.vibrance", -100.0, 100.0);
        m["color.grading.shadows"] = TransferFieldSpec{FieldValueType::Object, false, false, 0, false, 0, false, false, false, false, {}, {}};
        m["color.grading.midtones"] = TransferFieldSpec{FieldValueType::Object, false, false, 0, false, 0, false, false, false, false, {}, {}};
        m["color.grading.highlights"] = TransferFieldSpec{FieldValueType::Object, false, false, 0, false, 0, false, false, false, false, {}, {}};
        m["color.grading.global"] = TransferFieldSpec{FieldValueType::Object, false, false, 0, false, 0, false, false, false, false, {}, {}};
        addNum("color.grading.blending", 0.0, 100.0);
        addNum("color.grading.balance", -100.0, 100.0);
        m["color.white_balance.mode"] = TransferFieldSpec{FieldValueType::String, false, false, 0, false, 0, false, false, false, false, {"camera", "temperature", "relative", "none"}, {}};
        addNum("color.white_balance.temperature_kelvin", 2000.0, 50000.0, false, true);
        addNum("color.white_balance.tint", -150.0, 150.0, false, true);
        addNum("color.saturation", 0.0, 2.0);
        addNum("hdr.relative_temperature", 2000.0, 50000.0, false, false, true);
        addNum("hdr.relative_tint", -150.0, 150.0, false, false, true);
        addNum("hdr.peak_limit_ev", 0.0, 6.0, false, false, true);
        addNum("hdr.sdr_exposure_ev", -4.0, 4.0, false, false, true);
        addNum("hdr.sdr_contrast", -100.0, 100.0, false, false, true);
        addNum("hdr.sdr_saturation", -100.0, 100.0, false, false, true);
        m["hdr.look"] = TransferFieldSpec{FieldValueType::Object, true, false, 0, false, 0, false, false, false, true, {}, {}};
        m["hdr.camera_development"] = TransferFieldSpec{FieldValueType::Object, false, false, 0, false, 0, false, false, false, true, {}, {}};

        for (const char* axis : {"hue", "saturation", "lightness"}) {
            for (const char* ch : {"red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"}) {
                const std::string key = std::string("color.hsl.") + axis + "." + ch;
                m[key] = TransferFieldSpec{FieldValueType::Number, false, true, -100.0, true, 100.0, false, false, false, false, {}, {}};
            }
        }
        addNum("color.calibration.shadow_tint", -100.0, 100.0);
        addNum("color.calibration.red_hue", -100.0, 100.0);
        addNum("color.calibration.red_saturation", -100.0, 100.0);
        addNum("color.calibration.green_hue", -100.0, 100.0);
        addNum("color.calibration.green_saturation", -100.0, 100.0);
        addNum("color.calibration.blue_hue", -100.0, 100.0);
        addNum("color.calibration.blue_saturation", -100.0, 100.0);
        m["color.point_color"] = TransferFieldSpec{FieldValueType::Object, false, false, 0, false, 0, false, false, false, false, {}, {}};
        m["color.selective_color"] = TransferFieldSpec{FieldValueType::Object, false, false, 0, false, 0, false, false, false, false, {}, {}};
        addBool("color.bw.enabled");
        m["color.bw.mixer"] = TransferFieldSpec{FieldValueType::Object, false, false, 0, false, 0, false, false, false, false, {}, {}};

        addNum("effects.vignette.amount", -100.0, 100.0);
        addNum("effects.vignette.midpoint", 0.0, 100.0);
        addNum("effects.vignette.roundness", -100.0, 100.0);
        addNum("effects.vignette.feather", 0.0, 100.0);
        addNum("effects.vignette.highlights", 0.0, 100.0);
        addNum("effects.grain.amount", 0.0, 100.0);
        addNum("effects.clarity", -100.0, 100.0);
        addNum("effects.dehaze", -100.0, 100.0);
        addNum("effects.texture", -100.0, 100.0);
        addNum("effects.grain.size", 0.0, 100.0);
        addNum("effects.grain.roughness", 0.0, 100.0);
        addStrEnum("effects.grain.tone_curve", {"legacy", "negative_asymmetric"});
        addStrEnum("effects.grain.format_preset", {"custom", "135", "120"});
        addNum("effects.halation.amount", 0.0, 100.0);
        addNum("effects.halation.threshold", 0.0, 100.0);
        addNum("effects.halation.radius", 0.0, 100.0);
        addNum("effects.halation.hue", -100.0, 100.0);
        addNum("effects.bloom.amount", 0.0, 100.0);
        addNum("effects.bloom.threshold", 0.0, 100.0);
        addNum("effects.bloom.radius", 0.0, 100.0);
        addNum("detail.sharpening", 0.0, 2.0);
        addBool("detail.sharpening.luminance_v2");
        addNum("detail.sharpening.radius", 0.5, 3.0);
        addNum("detail.sharpening.detail", 0.0, 100.0);
        addNum("detail.sharpening.masking", 0.0, 100.0);
        addIntEnum("detail.denoise.raw_level", {0, 1, 2});
        addNum("detail.denoise.post_rgb", 0.0, 1.0);
        addIntEnum("detail.denoise.chroma_mode", {0, 1, 2}, true);
        m["detail.denoise.wavelet"] = TransferFieldSpec{FieldValueType::Object, true, false, 0, false, 0, false, false, false, false, {}, {}};
        addNum("geometry.crop.x", 0.0, 1.0);
        addNum("geometry.crop.y", 0.0, 1.0);
        addNum("geometry.crop.width", 0.0, 1.0, true);
        addNum("geometry.crop.height", 0.0, 1.0, true);
        addIntEnum("geometry.quarter_turns", {0, 1, 2, 3});
        addBool("geometry.flip_horizontal");
        addBool("geometry.flip_vertical");
        addNum("geometry.straighten_degrees", -45.0, 45.0);
        addNum("geometry.perspective.horizontal", -1.0, 1.0);
        addNum("geometry.perspective.vertical", -1.0, 1.0);
        addBool("geometry.lens.distortion");
        addBool("geometry.lens.tca");
        addBool("geometry.lens.vignetting");
        addBool("geometry.lens.auto_crop");
        m["geometry.lens.profile_id"] = TransferFieldSpec{FieldValueType::String, true, false, 0, false, 0, false, false, true, false, {}, {}};
        addNum("geometry.lens.defringe_purple_amount", 0.0, 20.0);
        addNum("geometry.lens.defringe_purple_hue", 0.0, 100.0);
        addNum("geometry.lens.defringe_green_amount", 0.0, 20.0);
        addNum("geometry.lens.defringe_green_hue", 0.0, 100.0);

        return m;
    }();
    return specs;
}

std::unordered_set<std::string> hdrSupportedFields(int version) {
    std::unordered_set<std::string> out = {
        "light.exposure", "light.contrast", "light.highlights", "light.shadows",
        "color.saturation", "hdr.relative_temperature", "hdr.relative_tint",
        "geometry.crop.x", "geometry.crop.y", "geometry.crop.width", "geometry.crop.height",
        "geometry.quarter_turns", "geometry.flip_horizontal", "geometry.flip_vertical",
        "geometry.straighten_degrees", "geometry.perspective.horizontal", "geometry.perspective.vertical",
        "hdr.camera_development",
    };
    if (version >= 2) {
        out.insert({"tone.black_point", "tone.white_point", "light.s_curve", "light.curve"});
    }
    if (version >= 3) {
        out.insert({"color.vibrance", "color.grading.shadows", "color.grading.midtones", "color.grading.highlights"});
        for (const char* axis : {"hue", "saturation", "lightness"}) {
            for (const char* ch : {"red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"}) {
                out.insert(std::string("color.hsl.") + axis + "." + ch);
            }
        }
    }
    if (version >= 4) {
        out.insert({"hdr.peak_limit_ev", "hdr.sdr_exposure_ev", "hdr.sdr_contrast", "hdr.sdr_saturation"});
    }
    if (version >= 5) {
        out.insert({
            "effects.vignette.amount", "effects.vignette.midpoint", "effects.vignette.roundness",
            "effects.vignette.feather", "effects.vignette.highlights",
            "effects.grain.amount", "effects.grain.size", "effects.grain.roughness",
        });
    }
    if (version >= 6) {
        out.insert({"detail.sharpening", "effects.clarity", "effects.dehaze", "detail.denoise.post_rgb"});
    }
    if (version >= 7) {
        out.insert("hdr.look");
    }
    if (version >= 9) {
        out.insert({
            "light.curve.apply_to_luminosity", "light.curve.parametric",
            "color.grading.global", "color.grading.blending", "color.grading.balance",
        });
    }
    return out;
}

Json validateToneCurveShape(const Json& obj, const std::string& fieldName) {
    if (!obj.is_object()) {
        throw StoreError(2, "invalid_argument", fieldName + " must contain exactly mode and points");
    }
    if (obj.size() != 2 || !obj.contains("mode") || !obj.contains("points")) {
        throw StoreError(2, "invalid_argument", fieldName + " must contain exactly mode and points");
    }
    if (!obj.at("mode").is_string()) {
        throw StoreError(2, "invalid_argument", fieldName + ".mode must be legacy or custom");
    }
    const std::string mode = obj.at("mode").get<std::string>();
    if (mode != "legacy" && mode != "custom") {
        throw StoreError(2, "invalid_argument", fieldName + ".mode must be legacy or custom");
    }
    const Json& points = obj.at("points");
    if (!points.is_array()) {
        throw StoreError(2, "invalid_argument", fieldName + ".points must be an array");
    }
    if (mode == "legacy") {
        if (!points.empty()) {
            throw StoreError(2, "invalid_argument", fieldName + ".points must be empty when mode is legacy");
        }
        return Json{{"mode", "legacy"}, {"points", Json::array()}};
    }
    if (points.size() < 2 || points.size() > 33) {
        throw StoreError(2, "invalid_argument", fieldName + ".points must contain 2..33 points when mode is custom");
    }
    Json outPoints = Json::array();
    double prevX = -1.0;
    double prevY = -1.0;
    for (size_t i = 0; i < points.size(); ++i) {
        const Json& pt = points[i];
        if (!pt.is_array() || pt.size() != 2 || !isFiniteNumberJson(pt[0]) || !isFiniteNumberJson(pt[1])) {
            throw StoreError(2, "invalid_argument", fieldName + ".points[" + std::to_string(i) + "] must be [x, y]");
        }
        const double x = pt[0].get<double>();
        const double y = pt[1].get<double>();
        if (x < 0.0 || x > 1.0 || y < 0.0 || y > 1.0) {
            throw StoreError(2, "invalid_argument", fieldName + ".points[" + std::to_string(i) + "] coordinates must be in [0, 1]");
        }
        if (i > 0) {
            if (x <= prevX) {
                throw StoreError(2, "invalid_argument", fieldName + ".points x values must be strictly increasing");
            }
            if (y < prevY) {
                throw StoreError(2, "invalid_argument", fieldName + ".points y values must be non-decreasing");
            }
        }
        prevX = x;
        prevY = y;
        outPoints.push_back(Json::array({x, y}));
    }
    return Json{{"mode", "custom"}, {"points", std::move(outPoints)}};
}

// HDR 记录的端点放开程度由处理版本决定：v9 只放开 y，v10 起 x 也可内移。
void requireHdrCurveEndpoints(const Json& curve, const std::string& fieldName, int hdrProcessingVersion) {
    if (curve.at("mode") != "custom") return;
    const auto& pts = curve.at("points");
    const auto& first = pts[0];
    const auto& last = pts[pts.size() - 1];
    if (hdrProcessingVersion < 9 && (first[1].get<double>() != 0.0 || last[1].get<double>() != 1.0)) {
        throw StoreError(2, "invalid_argument", "Free curve endpoints on " + fieldName + " require hdr_processing_version >= 9");
    }
    if (hdrProcessingVersion < 10 && (first[0].get<double>() != 0.0 || last[0].get<double>() != 1.0)) {
        throw StoreError(2, "invalid_argument", "Free curve endpoint x on " + fieldName + " requires hdr_processing_version >= 10");
    }
}

Json validateParametricCurve(const Json& pIn, const std::string& fieldName) {
    static const std::array<std::pair<const char*, std::pair<double, double>>, 7> kBounds = {{
        {"highlights", {-100.0, 100.0}},
        {"lights", {-100.0, 100.0}},
        {"darks", {-100.0, 100.0}},
        {"shadows", {-100.0, 100.0}},
        {"split_shadow", {0.05, 0.45}},
        {"split_midtone", {0.25, 0.75}},
        {"split_highlight", {0.55, 0.95}},
    }};
    if (!pIn.is_object() || pIn.size() != kBounds.size()) {
        throw StoreError(2, "invalid_argument", fieldName + " must contain exact parametric curve keys");
    }
    Json out = Json::object();
    for (const auto& [k, bounds] : kBounds) {
        if (!pIn.contains(k)) {
            throw StoreError(2, "invalid_argument", fieldName + " missing key " + k);
        }
        const Json& val = pIn.at(k);
        if (!isFiniteNumberJson(val)) {
            throw StoreError(2, "invalid_argument", fieldName + "." + k + " must be finite");
        }
        const double num = val.get<double>();
        if (num < bounds.first || num > bounds.second) {
            throw StoreError(2, "invalid_argument", fieldName + "." + k + " out of range");
        }
        out[k] = num;
    }
    const double sShadow = out.at("split_shadow").get<double>();
    const double sMid = out.at("split_midtone").get<double>();
    const double sHigh = out.at("split_highlight").get<double>();
    if (sShadow + 0.02 > sMid || sMid + 0.02 > sHigh) {
        throw StoreError(2, "invalid_argument", fieldName + " split points must maintain at least 0.02 separation");
    }
    return out;
}

struct GradingWheelVal {
    double hue = 0.0;
    double saturation = 0.0;
    double luminance = 0.0;
};

GradingWheelVal validateGradingWheel(const Json& val, const std::string& fieldName) {
    if (!val.is_object() || !val.contains("hue") || !val.contains("saturation")) {
        throw StoreError(2, "invalid_argument", fieldName + " must be a grading wheel object");
    }
    for (const auto& item : val.items()) {
        if (item.key() != "hue" && item.key() != "saturation" && item.key() != "luminance") {
            throw StoreError(2, "invalid_argument", fieldName + " contains unexpected key: " + item.key());
        }
    }
    const Json& hueJ = val.at("hue");
    const Json& satJ = val.at("saturation");
    if (!isFiniteNumberJson(hueJ) || hueJ.get<double>() < 0.0 || hueJ.get<double>() >= 360.0) {
        throw StoreError(2, "invalid_argument", fieldName + ".hue must be in [0, 360)");
    }
    if (!isFiniteNumberJson(satJ) || satJ.get<double>() < 0.0 || satJ.get<double>() > 100.0) {
        throw StoreError(2, "invalid_argument", fieldName + ".saturation must be in [0, 100]");
    }
    double lum = 0.0;
    if (val.contains("luminance")) {
        const Json& lumJ = val.at("luminance");
        if (!isFiniteNumberJson(lumJ) || lumJ.get<double>() < -100.0 || lumJ.get<double>() > 100.0) {
            throw StoreError(2, "invalid_argument", fieldName + ".luminance must be in [-100, 100]");
        }
        lum = lumJ.get<double>();
    }
    return GradingWheelVal{hueJ.get<double>(), satJ.get<double>(), lum};
}

void validateRecipeContext(const Json& rc) {
    if (!rc.is_object() || rc.size() != 3 || !rc.contains("id") || !rc.contains("strength") || !rc.contains("settings_version")) {
        throw StoreError(2, "invalid_argument", "recipe_context must contain id, strength, settings_version");
    }
    if (!rc.at("id").is_string() || rc.at("id").get<std::string>().empty()) {
        throw StoreError(2, "invalid_argument", "recipe_context.id must be a nonempty string");
    }
    if (!isFiniteNumberJson(rc.at("strength")) || rc.at("strength").get<double>() < 0.0 || rc.at("strength").get<double>() > 2.0) {
        throw StoreError(2, "invalid_argument", "recipe_context.strength must be in [0, 2]");
    }
    int64_t sv = 0;
    if (!isStrictIntJson(rc.at("settings_version"), sv) || (sv != 2 && sv != 3 && sv != 4)) {
        throw StoreError(2, "invalid_argument", "recipe_context.settings_version must be 2, 3, or 4");
    }
}

void validateScalarAgainstProto(const std::string& key, const Json& val, const TransferFieldSpec& spec) {
    switch (spec.valueType) {
        case FieldValueType::Boolean:
            if (!val.is_boolean()) {
                throw StoreError(2, "invalid_argument", "Field '" + key + "' must be a boolean");
            }
            return;
        case FieldValueType::Integer: {
            int64_t iv = 0;
            if (!isStrictIntJson(val, iv)) {
                throw StoreError(2, "invalid_argument", "Field '" + key + "' must be an integer");
            }
            if (spec.hasMin && iv < static_cast<int64_t>(spec.minVal)) {
                throw StoreError(2, "invalid_argument", "Field '" + key + "' below minimum");
            }
            if (spec.hasMax && iv > static_cast<int64_t>(spec.maxVal)) {
                throw StoreError(2, "invalid_argument", "Field '" + key + "' exceeds maximum");
            }
            if (!spec.intEnum.empty() && std::find(spec.intEnum.begin(), spec.intEnum.end(), static_cast<int>(iv)) == spec.intEnum.end()) {
                throw StoreError(2, "invalid_argument", "Field '" + key + "' has invalid integer enum value");
            }
            return;
        }
        case FieldValueType::Number: {
            if (!isFiniteNumberJson(val)) {
                throw StoreError(2, "invalid_argument", "Field '" + key + "' must be a finite number");
            }
            const double num = val.get<double>();
            if (spec.hasMin) {
                if (spec.exclusiveMin ? !(num > spec.minVal) : (num < spec.minVal)) {
                    throw StoreError(2, "invalid_argument", "Field '" + key + "' below minimum");
                }
            }
            if (spec.hasMax) {
                if (spec.exclusiveMax ? !(num < spec.maxVal) : (num > spec.maxVal)) {
                    throw StoreError(2, "invalid_argument", "Field '" + key + "' exceeds maximum");
                }
            }
            return;
        }
        case FieldValueType::String: {
            if (!val.is_string()) {
                throw StoreError(2, "invalid_argument", "Field '" + key + "' must be a string");
            }
            const std::string s = val.get<std::string>();
            if (spec.nonEmpty && s.empty()) {
                throw StoreError(2, "invalid_argument", "Field '" + key + "' must be nonempty");
            }
            if (!spec.strEnum.empty() && std::find(spec.strEnum.begin(), spec.strEnum.end(), s) == spec.strEnum.end()) {
                throw StoreError(2, "invalid_argument", "Field '" + key + "' has invalid enum value");
            }
            return;
        }
        case FieldValueType::Object:
            throw StoreError(2, "invalid_argument", "Unhandled object field '" + key + "'");
    }
}

void validateTransferValues(
    const Json& values,
    bool isHdr,
    std::optional<int> hdrProcessingVersion,
    std::optional<bool> isRaw,
    const Json* recipeContext) {
    if (!values.is_object() || values.empty()) {
        throw StoreError(2, "invalid_argument", "Preset values must be a non-empty dictionary");
    }
    const auto& specs = transferFieldSpecs();

    if (isHdr) {
        if (isRaw.has_value() && *isRaw) {
            throw StoreError(2, "invalid_argument", "HDR presets require is_raw=false");
        }
        if (recipeContext != nullptr && !recipeContext->is_null()) {
            throw StoreError(2, "invalid_argument", "HDR presets cannot include recipe_context");
        }
        if (hdrProcessingVersion.has_value()) {
            const auto allowedHdr = hdrSupportedFields(*hdrProcessingVersion);
            for (const auto& item : values.items()) {
                if (allowedHdr.find(item.key()) == allowedHdr.end()) {
                    if (specs.find(item.key()) == specs.end()) {
                        throw StoreError(2, "invalid_argument", "Unknown adjustment transfer field: " + item.key());
                    }
                    throw StoreError(2, "invalid_argument",
                        "Field '" + item.key() + "' is not supported in hdr_processing_version=" + std::to_string(*hdrProcessingVersion));
                }
            }
        }
    }

    for (const auto& item : values.items()) {
        const std::string& key = item.key();
        const Json& val = item.value();
        const auto it = specs.find(key);
        if (it == specs.end()) {
            throw StoreError(2, "invalid_argument", "Unknown adjustment transfer field: " + key);
        }
        const TransferFieldSpec& spec = it->second;
        if (spec.hdrOnly && !isHdr) {
            throw StoreError(2, "invalid_argument", "HDR field '" + key + "' requires hdr_processing_version");
        }
        if (val.is_null()) {
            if (spec.nullable) continue;
            throw StoreError(2, "invalid_argument", "Field '" + key + "' is not nullable");
        }

        if (key == "color.grading.shadows" || key == "color.grading.midtones" ||
            key == "color.grading.highlights" || key == "color.grading.global") {
            const GradingWheelVal wheel = validateGradingWheel(val, key);
            if (isHdr && hdrProcessingVersion.has_value() && *hdrProcessingVersion < 9 && wheel.luminance != 0.0) {
                throw StoreError(2, "invalid_argument",
                    key + ".luminance is not supported in hdr_processing_version=" + std::to_string(*hdrProcessingVersion));
            }
        } else if (key == "looks.reference") {
            if (!val.is_object() || val.size() != 2 || !val.contains("kind") || !val.contains("id")) {
                throw StoreError(2, "invalid_argument", "looks.reference must contain exactly kind and id");
            }
            if (!val.at("kind").is_string()) {
                throw StoreError(2, "invalid_argument", "Invalid looks.reference.kind");
            }
            const std::string kind = val.at("kind").get<std::string>();
            if (kind != "neutral" && kind != "builtin" && kind != "managed" && kind != "recipe" && kind != "recipe_lut") {
                throw StoreError(2, "invalid_argument", "Invalid looks.reference.kind");
            }
            const Json& refId = val.at("id");
            if (kind == "neutral") {
                if (!refId.is_null()) {
                    throw StoreError(2, "invalid_argument", "looks.reference.id must be null when kind is neutral");
                }
            } else {
                if (!refId.is_string()) {
                    throw StoreError(2, "invalid_argument", "Invalid looks.reference.id");
                }
                const std::string s = refId.get<std::string>();
                if (s.empty() || s == "." || s == ".." || s.find('/') != std::string::npos || s.find('\\') != std::string::npos) {
                    throw StoreError(2, "invalid_argument", "Invalid looks.reference.id");
                }
            }
        } else if (key == "light.curve") {
            if (!val.is_object() || !val.contains("mode") || !val.contains("points")) {
                throw StoreError(2, "invalid_argument", "light.curve must include mode and points");
            }
            for (const auto& kv : val.items()) {
                if (kv.key() != "mode" && kv.key() != "points" && kv.key() != "channels") {
                    throw StoreError(2, "invalid_argument", "light.curve contains unexpected key: " + kv.key());
                }
            }
            const Json masterCurve = validateToneCurveShape(
                Json{{"mode", val.at("mode")}, {"points", val.at("points")}},
                "light.curve");
            if (isHdr && hdrProcessingVersion.has_value()) {
                requireHdrCurveEndpoints(masterCurve, "light.curve", *hdrProcessingVersion);
            }
            if (val.contains("channels")) {
                if (isHdr && hdrProcessingVersion.has_value() && *hdrProcessingVersion < 8) {
                    throw StoreError(2, "invalid_argument",
                        "light.curve.channels is not supported in hdr_processing_version=" + std::to_string(*hdrProcessingVersion));
                }
                const Json& ch = val.at("channels");
                if (!ch.is_object()) {
                    throw StoreError(2, "invalid_argument", "light.curve.channels must be an object");
                }
                for (const auto& cItem : ch.items()) {
                    if (cItem.key() != "red" && cItem.key() != "green" && cItem.key() != "blue") {
                        throw StoreError(2, "invalid_argument", "light.curve.channels keys must be a subset of red, green, blue");
                    }
                    const Json chCurve = validateToneCurveShape(cItem.value(), "light.curve.channels." + cItem.key());
                    if (isHdr && hdrProcessingVersion.has_value()) {
                        requireHdrCurveEndpoints(chCurve, "light.curve.channels." + cItem.key(), *hdrProcessingVersion);
                    }
                }
            }
        } else if (key == "light.curve.parametric") {
            (void)validateParametricCurve(val, "light.curve.parametric");
        } else if (key == "color.point_color") {
            if (!val.is_object() || val.size() != 1 || !val.contains("swatches") || !val.at("swatches").is_array()) {
                throw StoreError(2, "invalid_argument", "color.point_color must contain only swatches array");
            }
            const Json& swatches = val.at("swatches");
            if (swatches.size() > 8) {
                throw StoreError(2, "invalid_argument", "color.point_color.swatches exceeds max 8");
            }
            static const std::unordered_set<std::string> kSwatchKeys = {
                "src_hue", "src_saturation", "src_luminance",
                "hue_shift", "saturation_shift", "luminance_shift", "variance",
                "range", "hue_range", "sat_range", "lum_range", "enabled",
            };
            for (const auto& sw : swatches) {
                if (!sw.is_object() || !sw.contains("src_hue") || !sw.contains("src_saturation") || !sw.contains("src_luminance")) {
                    throw StoreError(2, "invalid_argument", "color.point_color swatch requires src_hue, src_saturation, src_luminance");
                }
                for (const auto& sk : sw.items()) {
                    if (kSwatchKeys.find(sk.key()) == kSwatchKeys.end()) {
                        throw StoreError(2, "invalid_argument", "color.point_color swatch has unexpected key: " + sk.key());
                    }
                }
                auto checkNum = [&](const char* k, double lo, double hi, bool exHi = false) {
                    if (!sw.contains(k)) return;
                    if (!isFiniteNumberJson(sw.at(k))) throw StoreError(2, "invalid_argument", std::string("color.point_color.") + k + " must be finite");
                    const double v = sw.at(k).get<double>();
                    if (v < lo || (exHi ? v >= hi : v > hi)) throw StoreError(2, "invalid_argument", std::string("color.point_color.") + k + " out of range");
                };
                checkNum("src_hue", 0.0, 360.0, true);
                checkNum("src_saturation", 0.0, 1.0);
                checkNum("src_luminance", 0.0, 1.0);
                for (const char* k : {"hue_shift", "saturation_shift", "luminance_shift", "variance"}) checkNum(k, -100.0, 100.0);
                for (const char* k : {"range", "hue_range", "sat_range", "lum_range"}) checkNum(k, 0.0, 100.0);
                if (sw.contains("enabled") && !sw.at("enabled").is_boolean()) {
                    throw StoreError(2, "invalid_argument", "color.point_color.enabled must be boolean");
                }
            }
        } else if (key == "color.selective_color") {
            if (!val.is_object() || !val.contains("method") || !val.contains("bands") || val.size() != 2) {
                throw StoreError(2, "invalid_argument", "color.selective_color must contain method and bands");
            }
            if (!val.at("method").is_string() || (val.at("method").get<std::string>() != "relative" && val.at("method").get<std::string>() != "absolute")) {
                throw StoreError(2, "invalid_argument", "color.selective_color.method must be relative or absolute");
            }
            const Json& bands = val.at("bands");
            static const std::unordered_set<std::string> kBands = {
                "reds", "yellows", "greens", "cyans", "blues", "magentas", "whites", "neutrals", "blacks"
            };
            if (!bands.is_object() || bands.size() != kBands.size()) {
                throw StoreError(2, "invalid_argument", "color.selective_color.bands must contain all 9 bands");
            }
            for (const auto& bItem : bands.items()) {
                if (kBands.find(bItem.key()) == kBands.end()) {
                    throw StoreError(2, "invalid_argument", "color.selective_color unexpected band: " + bItem.key());
                }
                const Json& comp = bItem.value();
                if (!comp.is_object() || comp.size() != 4) {
                    throw StoreError(2, "invalid_argument", "color.selective_color band must contain cyan, magenta, yellow, black");
                }
                for (const char* ck : {"cyan", "magenta", "yellow", "black"}) {
                    if (!comp.contains(ck) || !isFiniteNumberJson(comp.at(ck)) ||
                        comp.at(ck).get<double>() < -100.0 || comp.at(ck).get<double>() > 100.0) {
                        throw StoreError(2, "invalid_argument", "color.selective_color component out of range");
                    }
                }
            }
        } else if (key == "color.bw.mixer") {
            static const std::unordered_set<std::string> kChannels = {
                "red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"
            };
            if (!val.is_object() || val.size() != kChannels.size()) {
                throw StoreError(2, "invalid_argument", "color.bw.mixer must contain all 8 channel keys");
            }
            for (const auto& item2 : val.items()) {
                if (kChannels.find(item2.key()) == kChannels.end() || !isFiniteNumberJson(item2.value()) ||
                    item2.value().get<double>() < -100.0 || item2.value().get<double>() > 100.0) {
                    throw StoreError(2, "invalid_argument", "color.bw.mixer channel out of range");
                }
            }
        } else if (key == "detail.denoise.wavelet") {
            if (!val.is_object() || val.size() != 5 ||
                !val.contains("enabled") || !val.contains("preset") ||
                !val.contains("luma") || !val.contains("chroma") || !val.contains("coarse")) {
                throw StoreError(2, "invalid_argument", "detail.denoise.wavelet has invalid keys");
            }
            if (!val.at("enabled").is_boolean() || !val.at("preset").is_string()) {
                throw StoreError(2, "invalid_argument", "Invalid detail.denoise.wavelet flags");
            }
            const std::string preset = val.at("preset").get<std::string>();
            if (preset != "detail" && preset != "clean" && preset != "custom") {
                throw StoreError(2, "invalid_argument", "Invalid detail.denoise.wavelet flags");
            }
            for (const char* k : {"luma", "chroma", "coarse"}) {
                if (!isFiniteNumberJson(val.at(k)) || val.at(k).get<double>() < 0.0 || val.at(k).get<double>() > 100.0) {
                    throw StoreError(2, "invalid_argument", std::string("detail.denoise.wavelet.") + k + " must be in [0, 100]");
                }
            }
        } else if (key == "hdr.look") {
            if (!val.is_object() || val.size() != 3 ||
                !val.contains("sha256") || !val.contains("name") || !val.contains("strength")) {
                throw StoreError(2, "invalid_argument", "hdr.look must contain sha256, name, strength");
            }
            if (!val.at("sha256").is_string()) {
                throw StoreError(2, "invalid_argument", "hdr.look.sha256 must be 64 lowercase hex characters");
            }
            const std::string sha = val.at("sha256").get<std::string>();
            if (sha.size() != 64 || !std::all_of(sha.begin(), sha.end(), [](unsigned char c) {
                    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
                })) {
                throw StoreError(2, "invalid_argument", "hdr.look.sha256 must be 64 lowercase hex characters");
            }
            if (!val.at("name").is_string()) {
                throw StoreError(2, "invalid_argument", "hdr.look.name must be a valid string without control characters");
            }
            const std::string lookName = val.at("name").get<std::string>();
            if (hasControlChars(lookName) || lookName.empty() || lookName.size() > 512) {
                throw StoreError(2, "invalid_argument", "hdr.look.name invalid or UTF-8 byte length out of range");
            }
            if (!isFiniteNumberJson(val.at("strength")) || val.at("strength").get<double>() < 0.0 || val.at("strength").get<double>() > 2.0) {
                throw StoreError(2, "invalid_argument", "hdr.look.strength must be in [0, 2]");
            }
        } else if (key == "hdr.camera_development") {
            if (!val.is_object() || val.size() != 6 ||
                !val.contains("version") || !val.contains("white_balance_mode") ||
                !val.contains("temperature") || !val.contains("tint") ||
                !val.contains("exposure_reference") || !val.contains("fbdd_level")) {
                throw StoreError(2, "invalid_argument", "hdr.camera_development has invalid keys");
            }
            int64_t ver = 0;
            if (!isStrictIntJson(val.at("version"), ver) || ver != 1) {
                throw StoreError(2, "invalid_argument", "hdr.camera_development has invalid version");
            }
            if (!val.at("white_balance_mode").is_string()) {
                throw StoreError(2, "invalid_argument", "hdr.camera_development has invalid white_balance_mode");
            }
            const std::string wbMode = val.at("white_balance_mode").get<std::string>();
            if (wbMode != "as_shot" && wbMode != "temperature") {
                throw StoreError(2, "invalid_argument", "hdr.camera_development has invalid white_balance_mode");
            }
            if (!val.at("exposure_reference").is_string()) {
                throw StoreError(2, "invalid_argument", "hdr.camera_development has invalid exposure_reference");
            }
            const std::string expRef = val.at("exposure_reference").get<std::string>();
            if (expRef != "metadata" && expRef != "sensor") {
                throw StoreError(2, "invalid_argument", "hdr.camera_development has invalid exposure_reference");
            }
            int64_t fbdd = 0;
            if (!isStrictIntJson(val.at("fbdd_level"), fbdd) || fbdd < 0 || fbdd > 2) {
                throw StoreError(2, "invalid_argument", "hdr.camera_development has invalid fbdd_level");
            }
            if (!isFiniteNumberJson(val.at("temperature")) || !isFiniteNumberJson(val.at("tint"))) {
                throw StoreError(2, "invalid_argument", "hdr.camera_development temperature and tint must be finite numbers");
            }
            const double tempVal = val.at("temperature").get<double>();
            const double tintVal = val.at("tint").get<double>();
            if (wbMode == "as_shot") {
                if (tempVal != 0.0 || tintVal != 0.0) {
                    throw StoreError(2, "invalid_argument",
                        "hdr.camera_development temperature and tint must be 0.0 when white_balance_mode is as_shot");
                }
            } else {
                if (tempVal < 2000.0 || tempVal > 50000.0) {
                    throw StoreError(2, "invalid_argument", "hdr.camera_development.temperature out of range");
                }
                if (tintVal < -150.0 || tintVal > 150.0) {
                    throw StoreError(2, "invalid_argument", "hdr.camera_development.tint out of range");
                }
            }
        } else {
            validateScalarAgainstProto(key, val, spec);
        }
    }

    if (recipeContext != nullptr && !recipeContext->is_null()) {
        if (values.contains("looks.strength") &&
            values.at("looks.strength").get<double>() != recipeContext->at("strength").get<double>()) {
            throw StoreError(2, "invalid_argument", "looks.strength must match recipe_context.strength");
        }
        if (values.contains("looks.reference") && values.at("looks.reference").is_object()) {
            const Json& lr = values.at("looks.reference");
            if (lr.value("kind", "") == "recipe" && lr.value("id", "") != recipeContext->at("id").get<std::string>()) {
                throw StoreError(2, "invalid_argument", "looks.reference.id must match recipe_context.id");
            }
        }
    }

    if (isRaw.has_value() && !isHdr) {
        if (!*isRaw) {
            if (values.contains("light.exposure_mode") && values.at("light.exposure_mode") != "sensor") {
                throw StoreError(2, "invalid_argument", "Raster SDR presets require light.exposure_mode == 'sensor'");
            }
            if (values.contains("detail.denoise.raw_level") && values.at("detail.denoise.raw_level") != 0) {
                throw StoreError(2, "invalid_argument", "Raster SDR presets require detail.denoise.raw_level == 0");
            }
            if (values.contains("detail.denoise.post_rgb") && values.at("detail.denoise.post_rgb").get<double>() != 0.0) {
                throw StoreError(2, "invalid_argument", "Raster SDR presets require detail.denoise.post_rgb == 0");
            }
        }

        const bool hasWbMode = values.contains("color.white_balance.mode");
        const std::string wbMode = hasWbMode ? values.at("color.white_balance.mode").get<std::string>() : "";
        const bool hasTempNonNull = values.contains("color.white_balance.temperature_kelvin") &&
                                    !values.at("color.white_balance.temperature_kelvin").is_null();
        const bool hasTintNonNull = values.contains("color.white_balance.tint") &&
                                    !values.at("color.white_balance.tint").is_null();

        if (hasWbMode) {
            if (*isRaw && wbMode == "none") {
                throw StoreError(2, "invalid_argument", "RAW presets cannot use color.white_balance.mode == 'none'");
            }
            if (!*isRaw && (wbMode == "camera" || wbMode == "temperature")) {
                throw StoreError(2, "invalid_argument", "Raster presets cannot use camera or temperature white_balance.mode");
            }
        }
        if (!*isRaw && wbMode != "relative") {
            if (hasTempNonNull || (recipeContext == nullptr && hasTintNonNull)) {
                throw StoreError(2, "invalid_argument", "Raster presets without relative WB cannot specify temperature_kelvin or tint");
            }
        }
        if (recipeContext != nullptr && !recipeContext->is_null() &&
            values.contains("color.white_balance.tint") && values.at("color.white_balance.tint").is_null()) {
            throw StoreError(2, "invalid_argument", "Recipe presets cannot set color.white_balance.tint to null");
        }
        if (wbMode == "camera" && (hasTempNonNull || (recipeContext == nullptr && hasTintNonNull))) {
            throw StoreError(2, "invalid_argument", "Camera white balance conflicts with temperature_kelvin or tint");
        }
        if (wbMode == "temperature" && (!hasTempNonNull || !hasTintNonNull)) {
            throw StoreError(2, "invalid_argument", "Temperature white balance requires non-null temperature_kelvin and tint");
        }
    }
}

bool isCanonicalPresetEntry(const Json& entry) {
    if (!entry.is_object() || entry.size() != 5 ||
        !entry.contains("id") || !entry.contains("name") ||
        !entry.contains("created_at") || !entry.contains("updated_at") || !entry.contains("payload")) {
        return false;
    }
    if (!entry.at("id").is_string() || !isCanonicalUuidLower(entry.at("id").get<std::string>())) return false;
    if (!entry.at("name").is_string()) return false;
    const std::string ename = entry.at("name").get<std::string>();
    if (ename.empty()) return false;
    try {
        if (platform::normalizePresetNameUtf8(ename) != ename) return false;
    } catch (const StoreError&) {
        return false;
    }

    int64_t cat = 0;
    int64_t uat = 0;
    if (!isStrictIntJson(entry.at("created_at"), cat) || !isStrictIntJson(entry.at("updated_at"), uat) ||
        cat < 0 || uat < cat) {
        return false;
    }

    const Json& payload = entry.at("payload");
    if (!payload.is_object() || payload.size() != 4 ||
        !payload.contains("payload_version") || !payload.contains("scope_version") ||
        !payload.contains("source") || !payload.contains("values")) {
        return false;
    }
    int64_t pv = 0;
    int64_t sv = 0;
    if (!isStrictIntJson(payload.at("payload_version"), pv) ||
        !isStrictIntJson(payload.at("scope_version"), sv) ||
        (pv != 1 && pv != 2) || pv != sv) {
        return false;
    }
    const Json& source = payload.at("source");
    if (!source.is_object() ||
        !source.contains("identifier") || !source.contains("is_raw") || !source.contains("processing_version")) {
        return false;
    }
    for (const auto& kv : source.items()) {
        if (kv.key() != "identifier" && kv.key() != "is_raw" &&
            kv.key() != "processing_version" && kv.key() != "recipe" &&
            kv.key() != "hdr_processing_version") {
            return false;
        }
    }
    if (!source.at("identifier").is_string() ||
        source.at("identifier").get<std::string>() != ("preset:" + entry.at("id").get<std::string>())) {
        return false;
    }
    if (!source.at("is_raw").is_boolean()) return false;
    const bool isRaw = source.at("is_raw").get<bool>();
    int64_t procVer = 0;
    if (!isStrictIntJson(source.at("processing_version"), procVer) || procVer < 1 || procVer > 3) return false;

    std::optional<int> hdrVer;
    const bool hasHdrField = source.contains("hdr_processing_version") && !source.at("hdr_processing_version").is_null();
    if ((pv == 2) != hasHdrField) return false;
    if (hasHdrField) {
        int64_t hv = 0;
        if (!isStrictIntJson(source.at("hdr_processing_version"), hv) || hv < 1 || hv > 10) return false;
        hdrVer = static_cast<int>(hv);
    }

    const Json* recipePtr = nullptr;
    if (source.contains("recipe") && !source.at("recipe").is_null()) {
        recipePtr = &source.at("recipe");
        try {
            validateRecipeContext(*recipePtr);
        } catch (const StoreError&) {
            return false;
        }
    }

    try {
        validateTransferValues(payload.at("values"), pv == 2, hdrVer, isRaw, recipePtr);
    } catch (const StoreError&) {
        return false;
    }
    return true;
}

std::string dumpCompactJson(const Json& j) {
    return j.dump(-1, ' ', false, Json::error_handler_t::strict);
}

// ---------------------------------------------------------------------------
// Adjustments Input Validation (Shared across macOS & Windows sync_photo_edit)
// ---------------------------------------------------------------------------

double numIn(const Json& obj, const char* key, double fallback, double lo, double hi, bool exclusiveMin = false) {
    if (!obj.contains(key) || obj.at(key).is_null()) return fallback;
    const Json& val = obj.at(key);
    if (!isFiniteNumberJson(val)) {
        throw StoreError(2, "invalid_argument", std::string("Adjustment '") + key + "' must be a finite number");
    }
    const double num = val.get<double>();
    if (exclusiveMin ? !(num > lo && num <= hi) : !(num >= lo && num <= hi)) {
        throw StoreError(2, "invalid_argument", std::string("Adjustment '") + key + "' is out of range");
    }
    return num;
}

struct ParsedAdjustments {
    int procVer = 3;
    std::string x3fMode = "normal-v1";
    std::string expModeCanonical = "preview";
    std::string wbModeInput = "camera";
    double effectiveTemp = 6500.0;
    double effectiveTint = 0.0;
    double exposure = 0.0;
    double strength = 1.0;
    double contrastPct = 0.0;
    double highlightsPct = 0.0;
    double shadowsPct = 0.0;
    double sCurvePct = 0.0;
    double saturationPct = 0.0;
    double sharpeningPct = 0.0;
    int rawDenoise = 0;
    bool aiDenoiseEnabled = false;
    std::optional<double> aiDenoiseBlend;
    std::optional<int> chromaNoiseReduction;
    struct Wavelet {
        bool enabled = false;
        double luma = 0.0;
        double chroma = 46.0;
        double coarse = 50.0;
        std::string preset = "detail";
    };
    std::optional<Wavelet> wavelet;
    double blackPoint = 0.0;
    double whitePoint = 0.0;
    double vibrance = 0.0;
    bool hasToneControls = false;
    double clarity = 0.0;
    double dehaze = 0.0;
    double texture = 0.0;
    bool hasAtmosphere = false;
    std::optional<Json> calibration;
    std::optional<Json> pointColor;
    std::optional<Json> selectiveColor;
    std::optional<Json> bwMixer;
    std::optional<Json> sharpenV2;
    std::optional<Json> filmOptics;
    std::optional<Json> toneCurveConfig;
    std::optional<Json> colorGradingCanonical; // lowercase keys
    std::optional<Json> hsl;                   // {hue:[8], saturation:[8], lightness:[8]}
    struct Effects {
        double vignetteAmount = 0.0;
        double vignetteMidpoint = 50.0;
        double vignetteRoundness = 0.0;
        double vignetteFeather = 50.0;
        double vignetteHighlights = 0.0;
        double grainAmount = 0.0;
        double grainSize = 25.0;
        double grainRoughness = 50.0;
        std::string grainToneCurve = "legacy";
        std::string grainFormatPreset = "custom";
    };
    std::optional<Effects> effects;
    struct Lens {
        bool distortion = false;
        bool tca = false;
        bool vignetting = false;
        bool autoCrop = true;
        std::optional<std::string> profileId;
        double defringePurpleAmount = 0.0;
        double defringePurpleHue = 50.0;
        double defringeGreenAmount = 0.0;
        double defringeGreenHue = 50.0;
    };
    std::optional<Lens> lens;
    struct Geometry {
        double cropX = 0.0;
        double cropY = 0.0;
        double cropWidth = 1.0;
        double cropHeight = 1.0;
        int quarterTurns = 0;
        bool flipHorizontal = false;
        bool flipVertical = false;
        double straightenDegrees = 0.0;
        double perspectiveHorizontal = 0.0;
        double perspectiveVertical = 0.0;
    };
    std::optional<Geometry> geometry;
    int masterRecipeSettingsVersion = 3;
    std::optional<std::string> masterRecipeId;
    std::string filmId;

    // Track which canonical adjustment inputs were explicitly passed (non-null or explicit null reset)
    std::unordered_set<std::string> explicitInputs;
    std::unordered_set<std::string> explicitNulls;
    bool hasWhiteBalanceMode = false;
    bool hasTemp = false;
    bool hasTint = false;
};

bool isDefaultEffects(const ParsedAdjustments::Effects& e) {
    return e.vignetteAmount == 0.0 && e.vignetteMidpoint == 50.0 &&
        e.vignetteRoundness == 0.0 && e.vignetteFeather == 50.0 &&
        e.vignetteHighlights == 0.0 && e.grainAmount == 0.0 &&
        e.grainSize == 25.0 && e.grainRoughness == 50.0 &&
        e.grainToneCurve == "legacy" && e.grainFormatPreset == "custom";
}

bool isDefaultLens(const ParsedAdjustments::Lens& l) {
    return !l.distortion && !l.tca && !l.vignetting && l.autoCrop &&
        !l.profileId.has_value() && l.defringePurpleAmount == 0.0 &&
        l.defringePurpleHue == 50.0 && l.defringeGreenAmount == 0.0 &&
        l.defringeGreenHue == 50.0;
}

bool isDefaultGeometry(const ParsedAdjustments::Geometry& g) {
    return g.cropX == 0.0 && g.cropY == 0.0 && g.cropWidth == 1.0 && g.cropHeight == 1.0 &&
        g.quarterTurns == 0 && !g.flipHorizontal && !g.flipVertical &&
        g.straightenDegrees == 0.0 && g.perspectiveHorizontal == 0.0 && g.perspectiveVertical == 0.0;
}

bool isDefaultHsl(const Json& hsl) {
    for (const char* axis : {"hue", "saturation", "lightness"}) {
        if (!hsl.contains(axis) || !hsl.at(axis).is_array()) return false;
        for (const auto& v : hsl.at(axis)) {
            if (v.get<double>() != 0.0) return false;
        }
    }
    return true;
}

Json defaultWindowsEffectsJson() {
    return Json{
        {"VignetteAmount", 0.0}, {"VignetteMidpoint", 50.0}, {"VignetteRoundness", 0.0},
        {"VignetteFeather", 50.0}, {"VignetteHighlights", 0.0},
        {"GrainAmount", 0.0}, {"GrainSize", 25.0}, {"GrainRoughness", 50.0},
    };
}

Json buildWindowsEffectsJson(const ParsedAdjustments::Effects& e) {
    Json fx = {
        {"VignetteAmount", e.vignetteAmount},
        {"VignetteMidpoint", e.vignetteMidpoint},
        {"VignetteRoundness", e.vignetteRoundness},
        {"VignetteFeather", e.vignetteFeather},
        {"VignetteHighlights", e.vignetteHighlights},
        {"GrainAmount", e.grainAmount},
        {"GrainSize", e.grainSize},
        {"GrainRoughness", e.grainRoughness},
    };
    if (e.grainToneCurve != "legacy") fx["GrainToneCurve"] = e.grainToneCurve;
    if (e.grainFormatPreset != "custom") fx["GrainFormatPreset"] = e.grainFormatPreset;
    return fx;
}

Json defaultWindowsLensJson() {
    return Json{
        {"Distortion", false}, {"Tca", false}, {"AutoCrop", true}, {"Manual", false},
        {"ProfileId", nullptr}, {"FocalLength", nullptr}, {"CropFactor", nullptr}, {"Vignetting", false},
    };
}

Json buildWindowsLensJson(const ParsedAdjustments::Lens& l) {
    Json lc = {
        {"Distortion", l.distortion},
        {"Tca", l.tca},
        {"AutoCrop", l.autoCrop},
        {"Manual", l.profileId.has_value()},
        {"ProfileId", l.profileId.has_value() ? Json(*l.profileId) : Json(nullptr)},
        {"FocalLength", nullptr},
        {"CropFactor", nullptr},
        {"Vignetting", l.vignetting},
    };
    if (l.defringePurpleAmount != 0.0 || l.defringePurpleHue != 50.0 ||
        l.defringeGreenAmount != 0.0 || l.defringeGreenHue != 50.0) {
        lc["DefringePurpleAmount"] = l.defringePurpleAmount;
        lc["DefringePurpleHue"] = l.defringePurpleHue;
        lc["DefringeGreenAmount"] = l.defringeGreenAmount;
        lc["DefringeGreenHue"] = l.defringeGreenHue;
    }
    return lc;
}

ParsedAdjustments parseAndValidateAdjustments(
    const Json& adjustments,
    bool isRaster,
    const std::string& filmId,
    const std::optional<std::string>& masterRecipeId) {
    if (!adjustments.is_object()) {
        throw StoreError(2, "invalid_argument", "adjustments must be an object");
    }
    static const std::unordered_set<std::string> kAllowedKeys = {
        "processing_version", "x3f_mode", "exposure_mode",
        "exposure", "contrast", "highlights", "shadows", "s_curve",
        "saturation", "vibrance", "black_point", "white_point",
        "clarity", "dehaze", "texture", "sharpening", "sharpen_v2", "strength",
        "white_balance_mode", "temperature", "tint",
        "raw_noise_reduction", "chroma_noise_reduction", "wavelet",
        "hsl", "tone_curve", "color_grading", "calibration", "point_color",
        "selective_color", "bw", "photo_effects", "film_optics",
        "geometry", "lens_correction", "master_recipe_settings_version",
        "ai_denoise_enabled", "ai_denoise_blend",
    };
    for (const auto& kv : adjustments.items()) {
        if (kAllowedKeys.find(kv.key()) == kAllowedKeys.end()) {
            throw StoreError(2, "invalid_argument", "Unsupported adjustment key: " + kv.key());
        }
        if (!kv.value().is_null()) {
            // Note: white_balance_mode handled specifically too
        }
    }

    ParsedAdjustments out;
    out.filmId = masterRecipeId.has_value() ? "" : filmId;
    out.masterRecipeId = masterRecipeId;

    for (const auto& kv : adjustments.items()) {
        if (kv.value().is_null()) out.explicitNulls.insert(kv.key());
        else out.explicitInputs.insert(kv.key());
    }

    if (adjustments.contains("processing_version")) {
        int64_t pv = 0;
        if (!isStrictIntJson(adjustments.at("processing_version"), pv) || pv < 1 || pv > 3) {
            throw StoreError(2, "invalid_argument", "processing_version must be 1, 2, or 3");
        }
        out.procVer = static_cast<int>(pv);
    }

    out.expModeCanonical = isRaster ? "sensor" : "preview";
    if (adjustments.contains("exposure_mode")) {
        if (!adjustments.at("exposure_mode").is_string()) {
            throw StoreError(2, "invalid_argument", "exposure_mode must be preview, scene, or sensor");
        }
        out.expModeCanonical = adjustments.at("exposure_mode").get<std::string>();
        if (out.expModeCanonical != "preview" && out.expModeCanonical != "scene" && out.expModeCanonical != "sensor") {
            throw StoreError(2, "invalid_argument", "exposure_mode must be preview, scene, or sensor");
        }
    }

    out.hasWhiteBalanceMode = adjustments.contains("white_balance_mode");
    out.wbModeInput = isRaster ? "none" : "camera";
    if (out.hasWhiteBalanceMode) {
        if (!adjustments.at("white_balance_mode").is_string()) {
            throw StoreError(2, "invalid_argument", "white_balance_mode must be a string");
        }
        out.wbModeInput = adjustments.at("white_balance_mode").get<std::string>();
    }
    out.hasTemp = adjustments.contains("temperature") && !adjustments.at("temperature").is_null();
    out.hasTint = adjustments.contains("tint") && !adjustments.at("tint").is_null();

    if (isRaster) {
        if (out.wbModeInput != "camera" && out.wbModeInput != "none" && out.wbModeInput != "relative") {
            throw StoreError(2, "invalid_argument", "Raster white_balance_mode must be relative, none, or camera");
        }
        if (out.wbModeInput != "relative" && (out.hasTemp || out.hasTint)) {
            throw StoreError(2, "invalid_argument", "Raster temperature and tint require white_balance_mode='relative'");
        }
        out.effectiveTemp = (out.wbModeInput == "relative")
            ? roundDigits(numIn(adjustments, "temperature", 6500.0, 2000.0, 50000.0), 2)
            : 6500.0;
        out.effectiveTint = (out.wbModeInput == "relative")
            ? roundDigits(numIn(adjustments, "tint", 0.0, -150.0, 150.0), 2)
            : 0.0;
    } else {
        if (out.wbModeInput != "camera" && out.wbModeInput != "temperature") {
            throw StoreError(2, "invalid_argument", "RAW white_balance_mode must be camera or temperature");
        }
        if (out.wbModeInput == "camera" && (out.hasTemp || (!masterRecipeId.has_value() && out.hasTint))) {
            throw StoreError(2, "invalid_argument", "RAW camera white_balance_mode conflicts with temperature or tint");
        }
        out.effectiveTemp = (out.wbModeInput == "temperature")
            ? roundDigits(numIn(adjustments, "temperature", 6500.0, 2000.0, 50000.0), 2)
            : 6500.0;
        out.effectiveTint = (out.wbModeInput == "temperature" || masterRecipeId.has_value())
            ? roundDigits(numIn(adjustments, "tint", 0.0, -150.0, 150.0), 2)
            : 0.0;
    }

    int64_t recipeVer = masterRecipeId.has_value() ? 4 : 3;
    if (adjustments.contains("master_recipe_settings_version")) {
        if (!isStrictIntJson(adjustments.at("master_recipe_settings_version"), recipeVer) ||
            (recipeVer != 2 && recipeVer != 3 && recipeVer != 4)) {
            throw StoreError(2, "invalid_argument", "master_recipe_settings_version must be 2, 3, or 4");
        }
    }
    out.masterRecipeSettingsVersion = static_cast<int>(recipeVer);

    if (adjustments.contains("raw_noise_reduction")) {
        int64_t rdn = 0;
        if (!isStrictIntJson(adjustments.at("raw_noise_reduction"), rdn) || rdn < 0 || rdn > 2) {
            throw StoreError(2, "invalid_argument", "raw_noise_reduction must be 0, 1, or 2");
        }
        out.rawDenoise = static_cast<int>(rdn);
    }

    if (adjustments.contains("x3f_mode")) {
        if (!adjustments.at("x3f_mode").is_string()) {
            throw StoreError(2, "invalid_argument", "x3f_mode must be legacy or normal-v1");
        }
        out.x3fMode = adjustments.at("x3f_mode").get<std::string>();
        if (out.x3fMode != "legacy" && out.x3fMode != "normal-v1") {
            throw StoreError(2, "invalid_argument", "x3f_mode must be legacy or normal-v1");
        }
    }

    out.exposure = roundDigits(numIn(adjustments, "exposure", 0.0, -5.0, 5.0), 6);
    out.strength = roundDigits(numIn(adjustments, "strength", 1.0, 0.0, 2.0), 6);
    out.contrastPct = roundDigits(numIn(adjustments, "contrast", 0.0, -100.0, 100.0), 4);
    out.highlightsPct = roundDigits(numIn(adjustments, "highlights", 0.0, -100.0, 100.0), 4);
    out.shadowsPct = roundDigits(numIn(adjustments, "shadows", 0.0, -100.0, 100.0), 4);
    out.sCurvePct = roundDigits(numIn(adjustments, "s_curve", 0.0, -100.0, 100.0), 4);
    out.saturationPct = roundDigits(numIn(adjustments, "saturation", 0.0, -100.0, 100.0), 4);
    out.sharpeningPct = roundDigits(numIn(adjustments, "sharpening", 0.0, 0.0, 200.0), 4);

    if (adjustments.contains("ai_denoise_enabled") && !adjustments.at("ai_denoise_enabled").is_null()) {
        if (!adjustments.at("ai_denoise_enabled").is_boolean()) {
            throw StoreError(2, "invalid_argument", "ai_denoise_enabled must be a boolean");
        }
        const bool aiOn = adjustments.at("ai_denoise_enabled").get<bool>();
        if (isRaster && aiOn) {
            throw StoreError(2, "invalid_argument", "Raster inputs do not support AI denoise");
        }
        out.aiDenoiseEnabled = aiOn;
    }

    if (adjustments.contains("ai_denoise_blend") && !adjustments.at("ai_denoise_blend").is_null()) {
        out.aiDenoiseBlend = roundDigits(numIn(adjustments, "ai_denoise_blend", 100.0, 0.0, 100.0), 2);
    }

    if (adjustments.contains("chroma_noise_reduction") && !adjustments.at("chroma_noise_reduction").is_null()) {
        int64_t cdn = 0;
        if (!isStrictIntJson(adjustments.at("chroma_noise_reduction"), cdn) || cdn < 0 || cdn > 2) {
            throw StoreError(2, "invalid_argument", "chroma_noise_reduction must be 0, 1, or 2");
        }
        out.chromaNoiseReduction = static_cast<int>(cdn);
    }

    if (adjustments.contains("wavelet") && !adjustments.at("wavelet").is_null()) {
        const Json& wv = adjustments.at("wavelet");
        if (!wv.is_object()) throw StoreError(2, "invalid_argument", "wavelet must be an object");
        for (const auto& kv : wv.items()) {
            if (kv.key() != "enabled" && kv.key() != "luma" && kv.key() != "chroma" &&
                kv.key() != "coarse" && kv.key() != "preset") {
                throw StoreError(2, "invalid_argument", "Unsupported wavelet key: " + kv.key());
            }
        }
        ParsedAdjustments::Wavelet w;
        if (wv.contains("enabled")) {
            if (!wv.at("enabled").is_boolean()) throw StoreError(2, "invalid_argument", "wavelet.enabled must be a boolean");
            w.enabled = wv.at("enabled").get<bool>();
        }
        if (wv.contains("preset")) {
            if (!wv.at("preset").is_string()) throw StoreError(2, "invalid_argument", "wavelet.preset must be detail, clean, or custom");
            w.preset = wv.at("preset").get<std::string>();
            if (w.preset != "detail" && w.preset != "clean" && w.preset != "custom") {
                throw StoreError(2, "invalid_argument", "wavelet.preset must be detail, clean, or custom");
            }
        }
        w.luma = roundDigits(numIn(wv, "luma", 0.0, 0.0, 100.0), 2);
        w.chroma = roundDigits(numIn(wv, "chroma", 46.0, 0.0, 100.0), 2);
        w.coarse = roundDigits(numIn(wv, "coarse", 50.0, 0.0, 100.0), 2);
        out.wavelet = w;
    }

    out.blackPoint = roundDigits(numIn(adjustments, "black_point", 0.0, -100.0, 100.0), 4);
    out.whitePoint = roundDigits(numIn(adjustments, "white_point", 0.0, -100.0, 100.0), 4);
    out.vibrance = roundDigits(numIn(adjustments, "vibrance", 0.0, -100.0, 100.0), 4);
    out.hasToneControls = (out.blackPoint != 0.0 || out.whitePoint != 0.0 || out.vibrance != 0.0);

    out.clarity = roundDigits(numIn(adjustments, "clarity", 0.0, -100.0, 100.0), 4);
    out.dehaze = roundDigits(numIn(adjustments, "dehaze", 0.0, -100.0, 100.0), 4);
    out.texture = roundDigits(numIn(adjustments, "texture", 0.0, -100.0, 100.0), 4);
    out.hasAtmosphere = (out.clarity != 0.0 || out.dehaze != 0.0 || out.texture != 0.0);

    if (adjustments.contains("calibration") && !adjustments.at("calibration").is_null()) {
        const Json& cal = adjustments.at("calibration");
        if (!cal.is_object()) throw StoreError(2, "invalid_argument", "calibration must be an object");
        static const std::unordered_set<std::string> kCalKeys = {
            "shadow_tint", "red_hue", "red_saturation",
            "green_hue", "green_saturation", "blue_hue", "blue_saturation"
        };
        for (const auto& kv : cal.items()) {
            if (kCalKeys.find(kv.key()) == kCalKeys.end()) {
                throw StoreError(2, "invalid_argument", "Unsupported calibration key: " + kv.key());
            }
        }
        const double st = roundDigits(numIn(cal, "shadow_tint", 0.0, -100.0, 100.0), 4);
        const double rh = roundDigits(numIn(cal, "red_hue", 0.0, -100.0, 100.0), 4);
        const double rs = roundDigits(numIn(cal, "red_saturation", 0.0, -100.0, 100.0), 4);
        const double gh = roundDigits(numIn(cal, "green_hue", 0.0, -100.0, 100.0), 4);
        const double gs = roundDigits(numIn(cal, "green_saturation", 0.0, -100.0, 100.0), 4);
        const double bh = roundDigits(numIn(cal, "blue_hue", 0.0, -100.0, 100.0), 4);
        const double bs = roundDigits(numIn(cal, "blue_saturation", 0.0, -100.0, 100.0), 4);
        if (st != 0.0 || rh != 0.0 || rs != 0.0 || gh != 0.0 || gs != 0.0 || bh != 0.0 || bs != 0.0) {
            out.calibration = Json{
                {"shadowTint", st},
                {"redHue", rh},
                {"redSaturation", rs},
                {"greenHue", gh},
                {"greenSaturation", gs},
                {"blueHue", bh},
                {"blueSaturation", bs},
            };
        }
    }

    if (adjustments.contains("point_color") && !adjustments.at("point_color").is_null()) {
        const Json& pc = adjustments.at("point_color");
        if (!pc.is_object() || pc.size() != 1 || !pc.contains("swatches") || !pc.at("swatches").is_array()) {
            throw StoreError(2, "invalid_argument", "point_color must contain swatches array");
        }
        if (pc.at("swatches").size() > 8) {
            throw StoreError(2, "invalid_argument", "point_color.swatches exceeds max 8");
        }
        static const std::unordered_set<std::string> kSwatchKeys = {
            "src_hue", "src_saturation", "src_luminance",
            "hue_shift", "saturation_shift", "luminance_shift", "variance",
            "range", "hue_range", "sat_range", "lum_range", "enabled",
        };
        Json swOut = Json::array();
        for (const auto& sw : pc.at("swatches")) {
            if (!sw.is_object() || !sw.contains("src_hue") || !sw.contains("src_saturation") || !sw.contains("src_luminance")) {
                throw StoreError(2, "invalid_argument", "point_color swatch missing required coordinates");
            }
            for (const auto& sk : sw.items()) {
                if (kSwatchKeys.find(sk.key()) == kSwatchKeys.end()) {
                    throw StoreError(2, "invalid_argument", "Unsupported point_color swatch key: " + sk.key());
                }
            }
            if (sw.at("src_hue").is_null() || sw.at("src_saturation").is_null() || sw.at("src_luminance").is_null()) {
                throw StoreError(2, "invalid_argument", "point_color swatch source coordinates cannot be null");
            }
            const double srcHue = roundDigits(numIn(sw, "src_hue", 0.0, 0.0, 360.0), 4);
            if (srcHue >= 360.0) throw StoreError(2, "invalid_argument", "point_color.src_hue must be < 360");
            bool enabled = true;
            if (sw.contains("enabled")) {
                if (!sw.at("enabled").is_boolean()) {
                    throw StoreError(2, "invalid_argument", "point_color.enabled must be boolean");
                }
                enabled = sw.at("enabled").get<bool>();
            }
            swOut.push_back({
                {"srcHue", srcHue},
                {"srcSaturation", roundDigits(numIn(sw, "src_saturation", 0.0, 0.0, 1.0), 6)},
                {"srcLuminance", roundDigits(numIn(sw, "src_luminance", 0.0, 0.0, 1.0), 6)},
                {"hueShift", roundDigits(numIn(sw, "hue_shift", 0.0, -100.0, 100.0), 4)},
                {"saturationShift", roundDigits(numIn(sw, "saturation_shift", 0.0, -100.0, 100.0), 4)},
                {"luminanceShift", roundDigits(numIn(sw, "luminance_shift", 0.0, -100.0, 100.0), 4)},
                {"variance", roundDigits(numIn(sw, "variance", 0.0, -100.0, 100.0), 4)},
                {"range", roundDigits(numIn(sw, "range", 50.0, 0.0, 100.0), 4)},
                {"hueRange", roundDigits(numIn(sw, "hue_range", 50.0, 0.0, 100.0), 4)},
                {"satRange", roundDigits(numIn(sw, "sat_range", 50.0, 0.0, 100.0), 4)},
                {"lumRange", roundDigits(numIn(sw, "lum_range", 50.0, 0.0, 100.0), 4)},
                {"enabled", enabled},
            });
        }
        if (!swOut.empty()) {
            out.pointColor = Json{{"swatches", std::move(swOut)}};
        }
    }

    if (adjustments.contains("selective_color") && !adjustments.at("selective_color").is_null()) {
        const Json& sc = adjustments.at("selective_color");
        if (!sc.is_object()) throw StoreError(2, "invalid_argument", "selective_color must be an object");
        for (const auto& kv : sc.items()) {
            if (kv.key() != "method" && kv.key() != "bands") {
                throw StoreError(2, "invalid_argument", "Unsupported selective_color key: " + kv.key());
            }
        }
        std::string method = "relative";
        if (sc.contains("method") && !sc.at("method").is_null()) {
            if (!sc.at("method").is_string()) throw StoreError(2, "invalid_argument", "selective_color.method must be string");
            method = sc.at("method").get<std::string>();
            if (method != "relative" && method != "absolute") throw StoreError(2, "invalid_argument", "selective_color.method invalid");
        }
        Json bandsOut = Json::object();
        static const std::array<const char*, 9> kBands = {
            "reds", "yellows", "greens", "cyans", "blues", "magentas", "whites", "neutrals", "blacks"
        };
        static const std::unordered_set<std::string> kBandSet(kBands.begin(), kBands.end());
        static const std::unordered_set<std::string> kCompSet = {"cyan", "magenta", "yellow", "black"};
        bool hasNonZeroBand = false;
        if (sc.contains("bands") && !sc.at("bands").is_null()) {
            if (!sc.at("bands").is_object()) {
                throw StoreError(2, "invalid_argument", "selective_color.bands must be an object");
            }
            const Json& bIn = sc.at("bands");
            for (const auto& kv : bIn.items()) {
                if (kBandSet.find(kv.key()) == kBandSet.end()) {
                    throw StoreError(2, "invalid_argument", "Unsupported selective_color band: " + kv.key());
                }
            }
            for (const char* bName : kBands) {
                if (bIn.contains(bName) && !bIn.at(bName).is_null()) {
                    const Json& c = bIn.at(bName);
                    if (!c.is_object()) {
                        throw StoreError(2, "invalid_argument", std::string("selective_color.bands.") + bName + " must be an object");
                    }
                    for (const auto& ckv : c.items()) {
                        if (kCompSet.find(ckv.key()) == kCompSet.end()) {
                            throw StoreError(2, "invalid_argument", "Unsupported selective_color component: " + ckv.key());
                        }
                    }
                    const double cy = roundDigits(numIn(c, "cyan", 0.0, -100.0, 100.0), 4);
                    const double mg = roundDigits(numIn(c, "magenta", 0.0, -100.0, 100.0), 4);
                    const double yl = roundDigits(numIn(c, "yellow", 0.0, -100.0, 100.0), 4);
                    const double bk = roundDigits(numIn(c, "black", 0.0, -100.0, 100.0), 4);
                    if (cy != 0.0 || mg != 0.0 || yl != 0.0 || bk != 0.0) hasNonZeroBand = true;
                    bandsOut[bName] = {{"cyan", cy}, {"magenta", mg}, {"yellow", yl}, {"black", bk}};
                } else {
                    bandsOut[bName] = {{"cyan", 0.0}, {"magenta", 0.0}, {"yellow", 0.0}, {"black", 0.0}};
                }
            }
        } else {
            for (const char* bName : kBands) {
                bandsOut[bName] = {{"cyan", 0.0}, {"magenta", 0.0}, {"yellow", 0.0}, {"black", 0.0}};
            }
        }
        if (method != "relative" || hasNonZeroBand) {
            out.selectiveColor = Json{{"method", method}, {"bands", std::move(bandsOut)}};
        }
    }

    if (adjustments.contains("bw") && !adjustments.at("bw").is_null()) {
        const Json& bw = adjustments.at("bw");
        if (!bw.is_object()) throw StoreError(2, "invalid_argument", "bw must be an object");
        for (const auto& kv : bw.items()) {
            if (kv.key() != "enabled" && kv.key() != "mixer") {
                throw StoreError(2, "invalid_argument", "Unsupported bw key: " + kv.key());
            }
        }
        bool enabled = false;
        if (bw.contains("enabled") && !bw.at("enabled").is_null()) {
            if (!bw.at("enabled").is_boolean()) {
                throw StoreError(2, "invalid_argument", "bw.enabled must be boolean");
            }
            enabled = bw.at("enabled").get<bool>();
        }
        Json mixerOut = Json::object();
        static const std::array<const char*, 8> kCh = {
            "red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"
        };
        static const std::unordered_set<std::string> kChSet(kCh.begin(), kCh.end());
        bool hasNonZeroWeight = false;
        if (bw.contains("mixer") && !bw.at("mixer").is_null()) {
            if (!bw.at("mixer").is_object()) throw StoreError(2, "invalid_argument", "bw.mixer must be an object");
            const Json& mx = bw.at("mixer");
            for (const auto& kv : mx.items()) {
                if (kChSet.find(kv.key()) == kChSet.end()) {
                    throw StoreError(2, "invalid_argument", "Unsupported bw.mixer channel: " + kv.key());
                }
            }
            for (const char* ck : kCh) {
                const double w = roundDigits(numIn(mx, ck, 0.0, -100.0, 100.0), 4);
                if (w != 0.0) hasNonZeroWeight = true;
                mixerOut[ck] = w;
            }
        } else {
            for (const char* ck : kCh) mixerOut[ck] = 0.0;
        }
        if (enabled || hasNonZeroWeight) {
            out.bwMixer = Json{{"enabled", enabled}, {"mixer", std::move(mixerOut)}};
        }
    }

    if (adjustments.contains("sharpen_v2") && !adjustments.at("sharpen_v2").is_null()) {
        const Json& sv = adjustments.at("sharpen_v2");
        if (!sv.is_object()) throw StoreError(2, "invalid_argument", "sharpen_v2 must be an object");
        for (const auto& kv : sv.items()) {
            if (kv.key() != "luminance_v2" && kv.key() != "radius" &&
                kv.key() != "detail" && kv.key() != "masking") {
                throw StoreError(2, "invalid_argument", "Unsupported sharpen_v2 key: " + kv.key());
            }
        }
        bool lumV2 = false;
        if (sv.contains("luminance_v2") && !sv.at("luminance_v2").is_null()) {
            if (!sv.at("luminance_v2").is_boolean()) {
                throw StoreError(2, "invalid_argument", "sharpen_v2.luminance_v2 must be boolean");
            }
            lumV2 = sv.at("luminance_v2").get<bool>();
        }
        const double radius = roundDigits(numIn(sv, "radius", 1.0, 0.5, 3.0), 4);
        const double detail = roundDigits(numIn(sv, "detail", 25.0, 0.0, 100.0), 4);
        const double masking = roundDigits(numIn(sv, "masking", 0.0, 0.0, 100.0), 4);
        if (lumV2 || radius != 1.0 || detail != 25.0 || masking != 0.0) {
            out.sharpenV2 = Json{
                {"luminanceV2", lumV2},
                {"radius", radius},
                {"detail", detail},
                {"masking", masking},
            };
        }
    }

    if (adjustments.contains("film_optics") && !adjustments.at("film_optics").is_null()) {
        const Json& fo = adjustments.at("film_optics");
        if (!fo.is_object()) throw StoreError(2, "invalid_argument", "film_optics must be an object");
        static const std::unordered_set<std::string> kFoKeys = {
            "halation_amount", "halation_threshold", "halation_radius", "halation_hue",
            "bloom_amount", "bloom_threshold", "bloom_radius",
        };
        for (const auto& kv : fo.items()) {
            if (kFoKeys.find(kv.key()) == kFoKeys.end()) {
                throw StoreError(2, "invalid_argument", "Unsupported film_optics key: " + kv.key());
            }
        }
        const double hAmt = roundDigits(numIn(fo, "halation_amount", 0.0, 0.0, 100.0), 4);
        const double hThr = roundDigits(numIn(fo, "halation_threshold", 75.0, 0.0, 100.0), 4);
        const double hRad = roundDigits(numIn(fo, "halation_radius", 35.0, 0.0, 100.0), 4);
        const double hHue = roundDigits(numIn(fo, "halation_hue", 0.0, -100.0, 100.0), 4);
        const double bAmt = roundDigits(numIn(fo, "bloom_amount", 0.0, 0.0, 100.0), 4);
        const double bThr = roundDigits(numIn(fo, "bloom_threshold", 70.0, 0.0, 100.0), 4);
        const double bRad = roundDigits(numIn(fo, "bloom_radius", 40.0, 0.0, 100.0), 4);
        if (hAmt != 0.0 || hThr != 75.0 || hRad != 35.0 || hHue != 0.0 ||
            bAmt != 0.0 || bThr != 70.0 || bRad != 40.0) {
            out.filmOptics = Json{
                {"halationAmount", hAmt},
                {"halationThreshold", hThr},
                {"halationRadius", hRad},
                {"halationHue", hHue},
                {"bloomAmount", bAmt},
                {"bloomThreshold", bThr},
                {"bloomRadius", bRad},
            };
        }
    }

    if (adjustments.contains("tone_curve") && !adjustments.at("tone_curve").is_null()) {
        const Json& tcIn = adjustments.at("tone_curve");
        if (!tcIn.is_object()) throw StoreError(2, "invalid_argument", "tone_curve must be an object");
        for (const auto& kv : tcIn.items()) {
            if (kv.key() != "mode" && kv.key() != "points" && kv.key() != "channels" &&
                kv.key() != "apply_to_luminosity" && kv.key() != "parametric") {
                throw StoreError(2, "invalid_argument", "Unsupported tone_curve key: " + kv.key());
            }
        }
        const Json masterIn = {
            {"mode", tcIn.contains("mode") ? tcIn.at("mode") : Json("legacy")},
            {"points", tcIn.contains("points") ? tcIn.at("points") : Json::array()},
        };
        const Json master = validateToneCurveShape(masterIn, "tone_curve");
        Json tcOut = {{"mode", master.at("mode")}, {"points", master.at("points")}};
        if (master.at("mode") == "custom") {
            out.sCurvePct = 0.0;
        }
        if (tcIn.contains("channels") && !tcIn.at("channels").is_null()) {
            const Json& ch = tcIn.at("channels");
            if (!ch.is_object()) {
                throw StoreError(2, "invalid_argument", "tone_curve.channels must be an object");
            }
            Json chOut = Json::object();
            for (const auto& kv : ch.items()) {
                if (kv.key() != "red" && kv.key() != "green" && kv.key() != "blue") {
                    throw StoreError(2, "invalid_argument", "tone_curve.channels must be a subset of red, green, blue");
                }
                chOut[kv.key()] = validateToneCurveShape(kv.value(), "tone_curve.channels." + kv.key());
            }
            if (!chOut.empty()) tcOut["channels"] = std::move(chOut);
        }
        if (tcIn.contains("apply_to_luminosity")) {
            if (!tcIn.at("apply_to_luminosity").is_boolean()) {
                throw StoreError(2, "invalid_argument", "tone_curve.apply_to_luminosity must be bool");
            }
            if (tcIn.at("apply_to_luminosity").get<bool>()) {
                tcOut["apply_to_luminosity"] = true;
            }
        }
        if (tcIn.contains("parametric") && !tcIn.at("parametric").is_null()) {
            const Json pValid = validateParametricCurve(tcIn.at("parametric"), "tone_curve.parametric");
            Json pRounded = Json::object();
            for (const auto& kv : pValid.items()) {
                pRounded[kv.key()] = roundDigits(kv.value().get<double>(), 4);
            }
            if (pRounded.at("split_shadow").get<double>() + 0.02 > pRounded.at("split_midtone").get<double>() ||
                pRounded.at("split_midtone").get<double>() + 0.02 > pRounded.at("split_highlight").get<double>()) {
                throw StoreError(2, "invalid_argument", "tone_curve.parametric split points violate split_min_gap after rounding");
            }
            tcOut["parametric"] = std::move(pRounded);
        }
        out.toneCurveConfig = std::move(tcOut);
    }

    if (adjustments.contains("color_grading") && !adjustments.at("color_grading").is_null()) {
        const Json& cgIn = adjustments.at("color_grading");
        if (!cgIn.is_object()) throw StoreError(2, "invalid_argument", "color_grading must be an object");
        for (const auto& kv : cgIn.items()) {
            if (kv.key() != "shadows" && kv.key() != "midtones" && kv.key() != "highlights" &&
                kv.key() != "global" && kv.key() != "blending" && kv.key() != "balance") {
                throw StoreError(2, "invalid_argument", "Unsupported color_grading key: " + kv.key());
            }
        }
        Json cgOut = Json::object();
        auto roundWheel = [](const GradingWheelVal& w, const std::string& zone) -> Json {
            const double hueR = roundDigits(w.hue, 4);
            if (!(hueR >= 0.0 && hueR < 360.0)) {
                throw StoreError(2, "invalid_argument", "color_grading." + zone + ".hue must be strictly < 360.0");
            }
            return Json{
                {"hue", hueR},
                {"saturation", roundDigits(w.saturation, 4)},
                {"luminance", roundDigits(w.luminance, 4)},
            };
        };
        for (const char* zone : {"shadows", "midtones", "highlights"}) {
            if (cgIn.contains(zone) && !cgIn.at(zone).is_null()) {
                cgOut[zone] = roundWheel(validateGradingWheel(cgIn.at(zone), std::string("color_grading.") + zone), zone);
            } else {
                cgOut[zone] = Json{{"hue", 0.0}, {"saturation", 0.0}, {"luminance", 0.0}};
            }
        }
        if (cgIn.contains("global") && !cgIn.at("global").is_null()) {
            cgOut["global"] = roundWheel(validateGradingWheel(cgIn.at("global"), "color_grading.global"), "global");
        }
        if (cgIn.contains("blending")) {
            cgOut["blending"] = roundDigits(numIn(cgIn, "blending", 50.0, 0.0, 100.0), 4);
        }
        if (cgIn.contains("balance")) {
            cgOut["balance"] = roundDigits(numIn(cgIn, "balance", 0.0, -100.0, 100.0), 4);
        }
        out.colorGradingCanonical = std::move(cgOut);
    }

    if (adjustments.contains("hsl") && !adjustments.at("hsl").is_null()) {
        const Json& hIn = adjustments.at("hsl");
        if (!hIn.is_object() || hIn.size() != 3 ||
            !hIn.contains("hue") || !hIn.contains("saturation") || !hIn.contains("lightness")) {
            throw StoreError(2, "invalid_argument", "hsl must contain hue, saturation, lightness arrays of length 8");
        }
        Json hOut = Json::object();
        for (const char* axis : {"hue", "saturation", "lightness"}) {
            const Json& arr = hIn.at(axis);
            if (!arr.is_array() || arr.size() != 8) {
                throw StoreError(2, "invalid_argument", std::string("hsl.") + axis + " must contain 8 numbers in [-100, 100]");
            }
            Json axisOut = Json::array();
            for (const Json& v : arr) {
                if (!isFiniteNumberJson(v) || v.get<double>() < -100.0 || v.get<double>() > 100.0) {
                    throw StoreError(2, "invalid_argument", std::string("hsl.") + axis + " must contain 8 numbers in [-100, 100]");
                }
                axisOut.push_back(v.get<double>());
            }
            hOut[axis] = std::move(axisOut);
        }
        out.hsl = std::move(hOut);
    }

    if (adjustments.contains("photo_effects") && !adjustments.at("photo_effects").is_null()) {
        const Json& eff = adjustments.at("photo_effects");
        if (!eff.is_object()) throw StoreError(2, "invalid_argument", "photo_effects must be an object");
        static const std::unordered_set<std::string> kEffKeys = {
            "vignette_amount", "vignette_midpoint", "vignette_roundness", "vignette_feather",
            "vignette_highlights", "grain_amount", "grain_size", "grain_roughness",
            "grain_tone_curve", "grain_format_preset",
        };
        for (const auto& kv : eff.items()) {
            if (kEffKeys.find(kv.key()) == kEffKeys.end()) {
                throw StoreError(2, "invalid_argument", "Unsupported photo_effects key: " + kv.key());
            }
        }
        ParsedAdjustments::Effects e;
        e.vignetteAmount = roundDigits(numIn(eff, "vignette_amount", 0.0, -100.0, 100.0), 2);
        e.vignetteMidpoint = roundDigits(numIn(eff, "vignette_midpoint", 50.0, 0.0, 100.0), 2);
        e.vignetteRoundness = roundDigits(numIn(eff, "vignette_roundness", 0.0, -100.0, 100.0), 2);
        e.vignetteFeather = roundDigits(numIn(eff, "vignette_feather", 50.0, 0.0, 100.0), 2);
        e.vignetteHighlights = roundDigits(numIn(eff, "vignette_highlights", 0.0, 0.0, 100.0), 2);
        e.grainAmount = roundDigits(numIn(eff, "grain_amount", 0.0, 0.0, 100.0), 2);
        e.grainSize = roundDigits(numIn(eff, "grain_size", 25.0, 0.0, 100.0), 2);
        e.grainRoughness = roundDigits(numIn(eff, "grain_roughness", 50.0, 0.0, 100.0), 2);
        if (eff.contains("grain_tone_curve")) {
            if (!eff.at("grain_tone_curve").is_string()) throw StoreError(2, "invalid_argument", "grain_tone_curve must be string");
            e.grainToneCurve = eff.at("grain_tone_curve").get<std::string>();
            if (e.grainToneCurve != "legacy" && e.grainToneCurve != "negative_asymmetric")
                throw StoreError(2, "invalid_argument", "Unsupported grain_tone_curve");
        }
        if (eff.contains("grain_format_preset")) {
            if (!eff.at("grain_format_preset").is_string()) throw StoreError(2, "invalid_argument", "grain_format_preset must be string");
            e.grainFormatPreset = eff.at("grain_format_preset").get<std::string>();
            if (e.grainFormatPreset != "custom" && e.grainFormatPreset != "135" && e.grainFormatPreset != "120")
                throw StoreError(2, "invalid_argument", "Unsupported grain_format_preset");
        }
        out.effects = e;
    }

    if (adjustments.contains("lens_correction") && !adjustments.at("lens_correction").is_null()) {
        const Json& lc = adjustments.at("lens_correction");
        if (!lc.is_object()) throw StoreError(2, "invalid_argument", "lens_correction must be an object");
        for (const auto& kv : lc.items()) {
            if (kv.key() != "distortion" && kv.key() != "tca" && kv.key() != "vignetting" &&
                kv.key() != "auto_crop" && kv.key() != "profile_id" &&
                kv.key() != "defringe_purple_amount" && kv.key() != "defringe_purple_hue" &&
                kv.key() != "defringe_green_amount" && kv.key() != "defringe_green_hue") {
                throw StoreError(2, "invalid_argument", "Unsupported lens_correction key: " + kv.key());
            }
        }
        ParsedAdjustments::Lens l;
        auto readBool = [&](const char* k, bool fallback) {
            if (!lc.contains(k)) return fallback;
            if (!lc.at(k).is_boolean()) throw StoreError(2, "invalid_argument", std::string("lens_correction.") + k + " must be a boolean");
            return lc.at(k).get<bool>();
        };
        l.distortion = readBool("distortion", false);
        l.tca = readBool("tca", false);
        l.vignetting = readBool("vignetting", false);
        l.autoCrop = readBool("auto_crop", true);
        if (lc.contains("profile_id") && !lc.at("profile_id").is_null()) {
            if (!lc.at("profile_id").is_string() || lc.at("profile_id").get<std::string>().empty()) {
                throw StoreError(2, "invalid_argument", "lens_correction.profile_id must be a nonempty string or null");
            }
            l.profileId = lc.at("profile_id").get<std::string>();
        }
        l.defringePurpleAmount = roundDigits(numIn(lc, "defringe_purple_amount", 0.0, 0.0, 20.0), 4);
        l.defringePurpleHue = roundDigits(numIn(lc, "defringe_purple_hue", 50.0, 0.0, 100.0), 4);
        l.defringeGreenAmount = roundDigits(numIn(lc, "defringe_green_amount", 0.0, 0.0, 20.0), 4);
        l.defringeGreenHue = roundDigits(numIn(lc, "defringe_green_hue", 50.0, 0.0, 100.0), 4);
        out.lens = l;
    }

    if (adjustments.contains("geometry") && !adjustments.at("geometry").is_null()) {
        const Json& gIn = adjustments.at("geometry");
        if (!gIn.is_object()) throw StoreError(2, "invalid_argument", "geometry must be an object");
        static const std::unordered_set<std::string> kGeomKeys = {
            "crop_x", "crop_y", "crop_width", "crop_height", "quarter_turns",
            "flip_horizontal", "flip_vertical", "straighten_degrees",
            "perspective_horizontal", "perspective_vertical",
        };
        for (const auto& kv : gIn.items()) {
            if (kGeomKeys.find(kv.key()) == kGeomKeys.end()) {
                throw StoreError(2, "invalid_argument", "Unsupported geometry key: " + kv.key());
            }
        }
        ParsedAdjustments::Geometry g;
        if (gIn.contains("quarter_turns")) {
            int64_t qt = 0;
            if (!isStrictIntJson(gIn.at("quarter_turns"), qt) || qt < 0 || qt > 3) {
                throw StoreError(2, "invalid_argument", "geometry.quarter_turns must be 0, 1, 2, or 3");
            }
            g.quarterTurns = static_cast<int>(qt);
        }
        auto readBool = [&](const char* k) {
            if (!gIn.contains(k)) return false;
            if (!gIn.at(k).is_boolean()) throw StoreError(2, "invalid_argument", std::string("geometry.") + k + " must be a boolean");
            return gIn.at(k).get<bool>();
        };
        g.flipHorizontal = readBool("flip_horizontal");
        g.flipVertical = readBool("flip_vertical");
        g.cropX = roundDigits(numIn(gIn, "crop_x", 0.0, 0.0, 1.0), 6);
        g.cropY = roundDigits(numIn(gIn, "crop_y", 0.0, 0.0, 1.0), 6);
        g.cropWidth = roundDigits(numIn(gIn, "crop_width", 1.0, 0.0, 1.0, true), 6);
        g.cropHeight = roundDigits(numIn(gIn, "crop_height", 1.0, 0.0, 1.0, true), 6);
        if (g.cropWidth <= 0.0 || g.cropHeight <= 0.0) {
            throw StoreError(2, "invalid_argument", "geometry.crop_width and crop_height must be > 0");
        }
        if (g.cropX + g.cropWidth > 1.0 || g.cropY + g.cropHeight > 1.0) {
            throw StoreError(2, "invalid_argument", "geometry crop bounds must satisfy crop_x + crop_width <= 1.0 and crop_y + crop_height <= 1.0");
        }
        g.straightenDegrees = roundDigits(numIn(gIn, "straighten_degrees", 0.0, -45.0, 45.0), 4);
        g.perspectiveHorizontal = roundDigits(numIn(gIn, "perspective_horizontal", 0.0, -1.0, 1.0), 6);
        g.perspectiveVertical = roundDigits(numIn(gIn, "perspective_vertical", 0.0, -1.0, 1.0), 6);
        out.geometry = g;
    }

    return out;
}

// ---------------------------------------------------------------------------
// macOS Edits/edits.json Codec
// ---------------------------------------------------------------------------

std::pair<Json, std::unordered_set<std::string>> buildMacEditState(
    const ParsedAdjustments& adj,
    bool isRaster) {
    const std::string expModeCn =
        (adj.expModeCanonical == "preview") ? "匹配内嵌预览" :
        (adj.expModeCanonical == "scene") ? "标准显影" : "传感器基准";
    const std::string wbModeCn = isRaster
        ? "拍摄时设置"
        : (adj.wbModeInput == "camera" ? "拍摄时设置" : "自定义");

    Json settings = {
        {"processing", {{"family", "rawlab"}, {"quality", "standard"}, {"version", adj.procVer}}},
        {"x3fMode", adj.x3fMode},
        {"exposureMode", expModeCn},
        {"exposure", adj.exposure},
        {"temperature", adj.effectiveTemp},
        {"tint", adj.effectiveTint},
        {"whiteBalanceMode", wbModeCn},
        {"strength", adj.strength},
        {"contrast", adj.contrastPct},
        {"highlights", adj.highlightsPct},
        {"shadows", adj.shadowsPct},
        {"toneCurve", adj.sCurvePct},
        {"saturation", adj.saturationPct},
        {"sharpening", adj.sharpeningPct},
        {"rawNoiseReduction", static_cast<double>(adj.rawDenoise)},
        {"aiDenoiseEnabled", adj.aiDenoiseEnabled},
        {"supportsRawNoiseReduction", !isRaster},
        {"masterRecipeSettingsVersion", adj.masterRecipeSettingsVersion},
    };
    if (adj.aiDenoiseBlend.has_value() && *adj.aiDenoiseBlend != 100.0) {
        settings["aiDenoiseBlend"] = *adj.aiDenoiseBlend;
    }
    if (adj.chromaNoiseReduction.has_value() && *adj.chromaNoiseReduction != 0) {
        settings["chromaNoiseReduction"] = static_cast<double>(*adj.chromaNoiseReduction);
    }
    if (adj.wavelet.has_value()) {
        settings["waveletNoiseReduction"] = {
            {"enabled", adj.wavelet->enabled},
            {"luma", adj.wavelet->luma},
            {"chroma", adj.wavelet->chroma},
            {"coarse", adj.wavelet->coarse},
            {"preset", adj.wavelet->preset},
        };
    }
    if (adj.hasToneControls) {
        settings["toneControls"] = {
            {"blackPoint", adj.blackPoint},
            {"whitePoint", adj.whitePoint},
            {"vibrance", adj.vibrance},
        };
    }
    if (adj.hasAtmosphere) {
        Json atm = {
            {"clarity", adj.clarity},
            {"dehaze", adj.dehaze},
        };
        if (adj.texture != 0.0) atm["texture"] = adj.texture;
        settings["atmosphere"] = std::move(atm);
    }
    if (adj.calibration.has_value()) settings["cameraCalibration"] = *adj.calibration;
    if (adj.pointColor.has_value()) settings["pointColor"] = *adj.pointColor;
    if (adj.selectiveColor.has_value()) settings["selectiveColor"] = *adj.selectiveColor;
    if (adj.bwMixer.has_value()) settings["bwMixer"] = *adj.bwMixer;
    if (adj.sharpenV2.has_value()) settings["sharpenV2"] = *adj.sharpenV2;
    if (adj.filmOptics.has_value()) settings["filmOptics"] = *adj.filmOptics;
    if (adj.toneCurveConfig.has_value()) {
        settings["toneCurveConfig"] = *adj.toneCurveConfig;
    }
    if (adj.colorGradingCanonical.has_value()) {
        settings["colorGrading"] = *adj.colorGradingCanonical;
    }
    if (adj.hsl.has_value() && !isDefaultHsl(*adj.hsl)) {
        settings["hsl"] = *adj.hsl;
    }
    if (adj.effects.has_value() && !isDefaultEffects(*adj.effects)) {
        Json fx = {
            {"vignetteAmount", adj.effects->vignetteAmount},
            {"vignetteMidpoint", adj.effects->vignetteMidpoint},
            {"vignetteRoundness", adj.effects->vignetteRoundness},
            {"vignetteFeather", adj.effects->vignetteFeather},
            {"vignetteHighlights", adj.effects->vignetteHighlights},
            {"grainAmount", adj.effects->grainAmount},
            {"grainSize", adj.effects->grainSize},
            {"grainRoughness", adj.effects->grainRoughness},
        };
        if (adj.effects->grainToneCurve != "legacy") fx["grainToneCurve"] = adj.effects->grainToneCurve;
        if (adj.effects->grainFormatPreset != "custom") fx["grainFormatPreset"] = adj.effects->grainFormatPreset;
        settings["photoEffects"] = std::move(fx);
    }
    if (adj.lens.has_value() && !isDefaultLens(*adj.lens)) {
        Json lc = {
            {"distortion", adj.lens->distortion},
            {"tca", adj.lens->tca},
            {"vignetting", adj.lens->vignetting},
            {"autoCrop", adj.lens->autoCrop},
            {"mode", adj.lens->profileId.has_value() ? "manual" : "automatic"},
            {"profileID", adj.lens->profileId.has_value() ? Json(*adj.lens->profileId) : Json(nullptr)},
        };
        if (adj.lens->defringePurpleAmount != 0.0) lc["defringePurpleAmount"] = adj.lens->defringePurpleAmount;
        if (adj.lens->defringePurpleHue != 50.0) lc["defringePurpleHue"] = adj.lens->defringePurpleHue;
        if (adj.lens->defringeGreenAmount != 0.0) lc["defringeGreenAmount"] = adj.lens->defringeGreenAmount;
        if (adj.lens->defringeGreenHue != 50.0) lc["defringeGreenHue"] = adj.lens->defringeGreenHue;
        settings["lensCorrection"] = std::move(lc);
    }
    if (adj.geometry.has_value() && !isDefaultGeometry(*adj.geometry)) {
        settings["geometry"] = {
            {"cropX", adj.geometry->cropX},
            {"cropY", adj.geometry->cropY},
            {"cropWidth", adj.geometry->cropWidth},
            {"cropHeight", adj.geometry->cropHeight},
            {"quarterTurns", adj.geometry->quarterTurns},
            {"flipHorizontal", adj.geometry->flipHorizontal},
            {"flipVertical", adj.geometry->flipVertical},
            {"straightenDegrees", adj.geometry->straightenDegrees},
            {"perspectiveHorizontal", adj.geometry->perspectiveHorizontal},
            {"perspectiveVertical", adj.geometry->perspectiveVertical},
        };
    }
    if (adj.masterRecipeId.has_value()) {
        settings["masterRecipeID"] = *adj.masterRecipeId;
    }

    static const std::unordered_map<std::string, std::string> kKeyMap = {
        {"processing_version", "processing"},
        {"x3f_mode", "x3fMode"},
        {"exposure_mode", "exposureMode"},
        {"exposure", "exposure"},
        {"strength", "strength"},
        {"contrast", "contrast"},
        {"highlights", "highlights"},
        {"shadows", "shadows"},
        {"s_curve", "toneCurve"},
        {"saturation", "saturation"},
        {"sharpening", "sharpening"},
        {"raw_noise_reduction", "rawNoiseReduction"},
        {"master_recipe_settings_version", "masterRecipeSettingsVersion"},
        {"chroma_noise_reduction", "chromaNoiseReduction"},
        {"wavelet", "waveletNoiseReduction"},
        {"tone_curve", "toneCurveConfig"},
        {"color_grading", "colorGrading"},
        {"calibration", "cameraCalibration"},
        {"point_color", "pointColor"},
        {"selective_color", "selectiveColor"},
        {"bw", "bwMixer"},
        {"sharpen_v2", "sharpenV2"},
        {"film_optics", "filmOptics"},
        {"hsl", "hsl"},
        {"photo_effects", "photoEffects"},
        {"lens_correction", "lensCorrection"},
        {"geometry", "geometry"},
        {"ai_denoise_enabled", "aiDenoiseEnabled"},
        {"ai_denoise_blend", "aiDenoiseBlend"},
    };
    std::unordered_set<std::string> explicitKeys;
    for (const auto& [adjKey, settingsKey] : kKeyMap) {
        if ((adj.explicitInputs.count(adjKey) || adj.explicitNulls.count(adjKey)) && settings.contains(settingsKey)) {
            explicitKeys.insert(settingsKey);
        }
    }
    if (adj.hasWhiteBalanceMode) {
        explicitKeys.insert({"whiteBalanceMode", "temperature", "tint"});
    }
    if (adj.hasTemp) explicitKeys.insert("temperature");
    if (adj.hasTint) explicitKeys.insert("tint");
    if ((adj.explicitInputs.count("black_point") || adj.explicitInputs.count("white_point") || adj.explicitInputs.count("vibrance") ||
         adj.explicitNulls.count("black_point") || adj.explicitNulls.count("white_point") || adj.explicitNulls.count("vibrance")) &&
        settings.contains("toneControls")) {
        explicitKeys.insert("toneControls");
    }
    if ((adj.explicitInputs.count("clarity") || adj.explicitInputs.count("dehaze") || adj.explicitInputs.count("texture") ||
         adj.explicitNulls.count("clarity") || adj.explicitNulls.count("dehaze") || adj.explicitNulls.count("texture")) &&
        settings.contains("atmosphere")) {
        explicitKeys.insert("atmosphere");
    }
    if (explicitKeys.count("toneCurveConfig") && settings.contains("toneCurveConfig") &&
        settings.at("toneCurveConfig").value("mode", "") == "custom") {
        explicitKeys.insert("toneCurve");
    }
    if (adj.masterRecipeId.has_value()) {
        explicitKeys.insert({"masterRecipeID", "masterRecipeSettingsVersion"});
    }

    Json state = {
        {"filmID", adj.filmId},
        {"masterRecipeID", adj.masterRecipeId.has_value() ? Json(*adj.masterRecipeId) : Json(nullptr)},
        {"settings", std::move(settings)},
    };
    return {std::move(state), std::move(explicitKeys)};
}

std::string encodeRawMapSorted(const std::map<std::string, std::string>& slices) {
    std::string out = "{";
    bool first = true;
    for (const auto& [k, raw] : slices) {
        if (!first) out.push_back(',');
        first = false;
        out += dumpCompactJson(Json(k));
        out.push_back(':');
        out += raw;
    }
    out.push_back('}');
    return out;
}

std::string syncMacEditsFile(
    const std::filesystem::path& editsFile,
    const GuiStoreFileIdentity& identity,
    const ParsedAdjustments& adj,
    bool isRaster,
    bool& outHadExisting,
    Json& outFinalState) {
    std::map<std::string, std::string> recordSlices;
    std::map<std::string, std::string> migrationSlices;
    bool hasMigrationMap = false;
    std::map<std::string, std::string> unknownRootSlices;

    if (std::filesystem::exists(editsFile)) {
        const std::string rawBytes = platform::readFileBytes(editsFile, 6, "output_io_error");
        StrictJsonScanner scanner(rawBytes);
        const JsonNode rootNode = scanner.scanRoot();
        if (rootNode.kind != JsonNode::Kind::Object || rootNode.ownDuplicateKey) {
            throw StoreError(6, "output_io_error", "Unsupported or corrupt edits.json");
        }
        const JsonNode* verNode = nullptr;
        const JsonNode* recordsNode = nullptr;
        const JsonNode* migNode = nullptr;
        for (const auto& [k, child] : rootNode.members) {
            if (k == "version") verNode = &child;
            else if (k == "records") recordsNode = &child;
            else if (k == "processingMigrations") migNode = &child;
            else unknownRootSlices[k] = rawBytes.substr(child.start, child.end - child.start);
        }
        if (!isVersionOneLiteral(verNode) ||
            recordsNode == nullptr || recordsNode->kind != JsonNode::Kind::Object || recordsNode->ownDuplicateKey) {
            throw StoreError(6, "output_io_error", "Unsupported or corrupt edits.json");
        }
        for (const auto& [k, child] : recordsNode->members) {
            recordSlices[k] = rawBytes.substr(child.start, child.end - child.start);
        }
        if (migNode != nullptr && migNode->kind != JsonNode::Kind::Null) {
            if (migNode->kind != JsonNode::Kind::Object || migNode->ownDuplicateKey) {
                throw StoreError(6, "output_io_error", "Unsupported or corrupt edits.json");
            }
            hasMigrationMap = true;
            for (const auto& [k, child] : migNode->members) {
                migrationSlices[k] = rawBytes.substr(child.start, child.end - child.start);
            }
        }
    }

    const Json identityJson = {
        {"fileNumber", identity.macFileNumber},
        {"modified", identity.macModified},
        {"path", identity.path},
        {"size", identity.size},
    };
    const std::string& photoKey = identity.path;
    auto [newState, explicitKeys] = buildMacEditState(adj, isRaster);

    auto recIt = recordSlices.find(photoKey);
    outHadExisting = (recIt != recordSlices.end());
    Json existingRecord;
    if (outHadExisting) {
        try {
            existingRecord = Json::parse(recIt->second);
        } catch (const std::exception& e) {
            throw StoreError(6, "output_io_error", std::string("Corrupt record for ") + photoKey + " in edits.json: " + e.what());
        }
    }

    Json finalRecord;
    if (existingRecord.is_object() && existingRecord.contains("state") && existingRecord.at("state").is_object()) {
        const Json& existingState = existingRecord.at("state");
        const bool hasExistingSettings = existingState.contains("settings") && existingState.at("settings").is_object();
        std::optional<int> oldProcVer;
        if (hasExistingSettings && existingState.at("settings").contains("processing") &&
            existingState.at("settings").at("processing").is_object() &&
            existingState.at("settings").at("processing").contains("version") &&
            existingState.at("settings").at("processing").at("version").is_number_integer()) {
            oldProcVer = existingState.at("settings").at("processing").at("version").get<int>();
        }
        Json mergedSettings;
        std::optional<std::string> upgradedLutId;
        if (hasExistingSettings) {
            mergedSettings = existingState.at("settings");
            if (mergedSettings.contains("settingsVersion") &&
                mergedSettings.at("settingsVersion").is_number_integer() &&
                mergedSettings.at("settingsVersion").get<int>() == 2) {
                if (mergedSettings.contains("contrast") && isFiniteNumberJson(mergedSettings.at("contrast"))) {
                    mergedSettings["contrast"] = roundDigits((mergedSettings.at("contrast").get<double>() - 1.0) * 100.0, 4);
                }
                if (mergedSettings.contains("highlights") && isFiniteNumberJson(mergedSettings.at("highlights"))) {
                    mergedSettings["highlights"] = roundDigits(-mergedSettings.at("highlights").get<double>() * 100.0, 4);
                }
                if (mergedSettings.contains("shadows") && isFiniteNumberJson(mergedSettings.at("shadows"))) {
                    mergedSettings["shadows"] = roundDigits(mergedSettings.at("shadows").get<double>() * 100.0, 4);
                }
                if (mergedSettings.contains("toneCurve") && isFiniteNumberJson(mergedSettings.at("toneCurve"))) {
                    mergedSettings["toneCurve"] = roundDigits(mergedSettings.at("toneCurve").get<double>() * 100.0, 4);
                }
                if (mergedSettings.contains("saturation") && isFiniteNumberJson(mergedSettings.at("saturation"))) {
                    mergedSettings["saturation"] = roundDigits((mergedSettings.at("saturation").get<double>() - 1.0) * 100.0, 4);
                }
                if (mergedSettings.contains("sharpening") && isFiniteNumberJson(mergedSettings.at("sharpening"))) {
                    mergedSettings["sharpening"] = roundDigits(mergedSettings.at("sharpening").get<double>() * 100.0, 4);
                }
                if (mergedSettings.contains("exposureMode") && mergedSettings.at("exposureMode").is_string()) {
                    const std::string em = mergedSettings.at("exposureMode").get<std::string>();
                    if (em == "scene") mergedSettings["exposureMode"] = "标准显影";
                    else if (em == "preview") mergedSettings["exposureMode"] = "匹配内嵌预览";
                    else if (em == "sensor") mergedSettings["exposureMode"] = "传感器基准";
                }
                if (mergedSettings.contains("whiteBalanceMode") && mergedSettings.at("whiteBalanceMode").is_string()) {
                    const std::string wm = mergedSettings.at("whiteBalanceMode").get<std::string>();
                    if (wm == "camera") mergedSettings["whiteBalanceMode"] = "拍摄时设置";
                    else if (wm == "custom") mergedSettings["whiteBalanceMode"] = "自定义";
                }
                if (mergedSettings.contains("lutID") && mergedSettings.at("lutID").is_string() &&
                    !mergedSettings.at("lutID").get<std::string>().empty()) {
                    upgradedLutId = mergedSettings.at("lutID").get<std::string>();
                }
                mergedSettings.erase("settingsVersion");
                mergedSettings.erase("lutID");
                mergedSettings.erase("lutStrength");
                mergedSettings.erase("denoise");
                mergedSettings.erase("displayChromaDenoise");
            }
            for (const auto& [k, v] : newState.at("settings").items()) {
                if (k == "chromaNoiseReduction" || k == "toneControls" || k == "atmosphere") {
                    continue;
                }
                if (explicitKeys.count(k) || !mergedSettings.contains(k)) {
                    mergedSettings[k] = v;
                }
            }
            auto touched = [&](const char* key) -> bool {
                return adj.explicitInputs.count(key) > 0 || adj.explicitNulls.count(key) > 0;
            };
            static const std::array<std::pair<const char*, const char*>, 15> kResetEraseKeys = {{
                {"ai_denoise_blend", "aiDenoiseBlend"},
                {"wavelet", "waveletNoiseReduction"},
                {"tone_curve", "toneCurveConfig"},
                {"color_grading", "colorGrading"},
                {"calibration", "cameraCalibration"},
                {"point_color", "pointColor"},
                {"selective_color", "selectiveColor"},
                {"bw", "bwMixer"},
                {"sharpen_v2", "sharpenV2"},
                {"film_optics", "filmOptics"},
                {"hsl", "hsl"},
                {"photo_effects", "photoEffects"},
                {"lens_correction", "lensCorrection"},
                {"geometry", "geometry"},
                {"chroma_noise_reduction", "chromaNoiseReduction"},
            }};
            for (const auto& [adjKey, settingsKey] : kResetEraseKeys) {
                if (touched(adjKey) && !newState.at("settings").contains(settingsKey)) {
                    mergedSettings.erase(settingsKey);
                }
            }
            if (touched("black_point") || touched("white_point") || touched("vibrance")) {
                Json tc = (mergedSettings.contains("toneControls") && mergedSettings.at("toneControls").is_object())
                    ? mergedSettings.at("toneControls")
                    : Json{{"blackPoint", 0.0}, {"whitePoint", 0.0}, {"vibrance", 0.0}};
                if (touched("black_point")) tc["blackPoint"] = adj.blackPoint;
                if (touched("white_point")) tc["whitePoint"] = adj.whitePoint;
                if (touched("vibrance")) tc["vibrance"] = adj.vibrance;
                if (tc.value("blackPoint", 0.0) == 0.0 && tc.value("whitePoint", 0.0) == 0.0 && tc.value("vibrance", 0.0) == 0.0) {
                    mergedSettings.erase("toneControls");
                } else {
                    mergedSettings["toneControls"] = std::move(tc);
                }
            }
            if (touched("clarity") || touched("dehaze") || touched("texture")) {
                Json atm = (mergedSettings.contains("atmosphere") && mergedSettings.at("atmosphere").is_object())
                    ? mergedSettings.at("atmosphere")
                    : Json{{"clarity", 0.0}, {"dehaze", 0.0}};
                if (touched("clarity")) atm["clarity"] = adj.clarity;
                if (touched("dehaze")) atm["dehaze"] = adj.dehaze;
                if (touched("texture")) {
                    if (adj.texture == 0.0) atm.erase("texture");
                    else atm["texture"] = adj.texture;
                }
                if (atm.value("clarity", 0.0) == 0.0 && atm.value("dehaze", 0.0) == 0.0 && atm.value("texture", 0.0) == 0.0) {
                    mergedSettings.erase("atmosphere");
                } else {
                    mergedSettings["atmosphere"] = std::move(atm);
                }
            }
            mergedSettings["supportsRawNoiseReduction"] = !isRaster;
        } else {
            mergedSettings = newState.at("settings");
        }

        std::optional<int> newProcVer;
        if (mergedSettings.contains("processing") && mergedSettings.at("processing").is_object() &&
            mergedSettings.at("processing").contains("version") &&
            mergedSettings.at("processing").at("version").is_number_integer()) {
            newProcVer = mergedSettings.at("processing").at("version").get<int>();
        }
        if (hasMigrationMap && explicitKeys.count("processing") && oldProcVer != newProcVer) {
            migrationSlices.erase(photoKey);
            if (migrationSlices.empty()) hasMigrationMap = false;
        }

        Json finalState = existingState;
        finalState["settings"] = std::move(mergedSettings);
        if (adj.masterRecipeId.has_value()) {
            finalState["masterRecipeID"] = *adj.masterRecipeId;
            finalState["filmID"] = "";
        } else if (!adj.filmId.empty()) {
            finalState["filmID"] = adj.filmId;
            finalState["masterRecipeID"] = nullptr;
            finalState["settings"].erase("masterRecipeID");
        } else if (upgradedLutId.has_value() &&
                   (!finalState.contains("filmID") || finalState.at("filmID").is_null() ||
                    (finalState.at("filmID").is_string() && finalState.at("filmID").get<std::string>().empty()))) {
            finalState["filmID"] = *upgradedLutId;
        }

        finalRecord = existingRecord;
        finalRecord["identity"] = identityJson;
        finalRecord["state"] = finalState;
        outFinalState = std::move(finalState);
    } else {
        outFinalState = newState;
        finalRecord = {{"identity", identityJson}, {"state", outFinalState}};
        if (hasMigrationMap && explicitKeys.count("processing")) {
            migrationSlices.erase(photoKey);
            if (migrationSlices.empty()) hasMigrationMap = false;
        }
    }

    recordSlices[photoKey] = dumpCompactJson(finalRecord);

    // Deterministic root output preserving any unknown Tier-1 keys via raw slices.
    std::map<std::string, std::string> rootSlices = std::move(unknownRootSlices);
    rootSlices["records"] = encodeRawMapSorted(recordSlices);
    if (hasMigrationMap && !migrationSlices.empty()) {
        rootSlices["processingMigrations"] = encodeRawMapSorted(migrationSlices);
    }
    rootSlices["version"] = "1";
    return encodeRawMapSorted(rootSlices);
}

// ---------------------------------------------------------------------------
// Windows Edits/edits.json Codec
// ---------------------------------------------------------------------------

Json buildWindowsWheel(const Json& w) {
    Json out = {
        {"Hue", w.at("hue").get<double>()},
        {"Saturation", w.at("saturation").get<double>()},
    };
    const double lum = w.value("luminance", 0.0);
    if (lum != 0.0) out["Luminance"] = lum;
    return out;
}

Json buildWindowsColorGrading(const Json& cg) {
    Json out = {
        {"Shadows", buildWindowsWheel(cg.at("shadows"))},
        {"Midtones", buildWindowsWheel(cg.at("midtones"))},
        {"Highlights", buildWindowsWheel(cg.at("highlights"))},
    };
    if (cg.contains("global")) {
        const Json& g = cg.at("global");
        if (g.value("hue", 0.0) != 0.0 || g.value("saturation", 0.0) != 0.0 || g.value("luminance", 0.0) != 0.0) {
            out["Global"] = buildWindowsWheel(g);
        }
    }
    const double blending = cg.value("blending", 50.0);
    if (blending != 50.0) out["Blending"] = blending;
    const double balance = cg.value("balance", 0.0);
    if (balance != 0.0) out["Balance"] = balance;
    return out;
}

std::array<double, 10> extractOrMigrateWindowsValues(const Json& existingSettings) {
    std::array<double, 10> vals = {1.0, 0.0, 6500.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0};
    if (!existingSettings.contains("Values") || !existingSettings.at("Values").is_array() ||
        existingSettings.at("Values").size() != 10) {
        return vals;
    }
    const Json& arr = existingSettings.at("Values");
    for (size_t i = 0; i < 10; ++i) {
        if (!isFiniteNumberJson(arr[i])) {
            throw StoreError(6, "output_io_error", "Invalid numeric value in Windows Values array");
        }
        vals[i] = arr[i].get<double>();
    }
    const int sv = existingSettings.value("SettingsVersion", 0);
    if (sv < 2) {
        vals[0] = vals[0] / 100.0;
        vals[4] = 1.0 + vals[4] / 100.0;
        vals[5] = -vals[5] / 100.0;
        vals[6] = vals[6] / 100.0;
        vals[7] = vals[7] / 100.0;
        vals[8] = 1.0 + vals[8] / 100.0;
        vals[9] = vals[9] / 100.0;
    }
    return vals;
}

std::string syncWindowsEditsFile(
    const std::filesystem::path& editsFile,
    const GuiStoreFileIdentity& identity,
    const ParsedAdjustments& adj,
    bool isRaster,
    bool& outHadExisting,
    Json& outFinalResultInfo) {
    // Store records and receipts preserving original casing, indexed by asciiLower for OrdinalIgnoreCase.
    struct CaseMap {
        std::map<std::string, std::pair<std::string, std::string>> byLower; // lower -> (originalKey, rawSlice)
        std::string* findMut(const std::string& key, std::string* foundKey = nullptr) {
            auto it = byLower.find(asciiLower(key));
            if (it == byLower.end()) return nullptr;
            if (foundKey) *foundKey = it->second.first;
            return &it->second.second;
        }
        void put(const std::string& key, std::string rawSlice) {
            const std::string lk = asciiLower(key);
            auto it = byLower.find(lk);
            if (it != byLower.end()) {
                it->second.second = std::move(rawSlice);
            } else {
                byLower.emplace(lk, std::make_pair(key, std::move(rawSlice)));
            }
        }
        bool erase(const std::string& key) {
            return byLower.erase(asciiLower(key)) > 0;
        }
        std::string encode() const {
            // Output deterministic sorted by original key
            std::map<std::string, std::string> ordered;
            for (const auto& kv : byLower) {
                ordered[kv.second.first] = kv.second.second;
            }
            return encodeRawMapSorted(ordered);
        }
    };

    CaseMap recordsMap;
    CaseMap receiptsMap;
    bool hasReceipts = false;
    std::map<std::string, std::string> unknownRootSlices;

    if (std::filesystem::exists(editsFile)) {
        const std::string rawBytes = platform::readFileBytes(editsFile, 6, "output_io_error");
        StrictJsonScanner scanner(rawBytes);
        const JsonNode rootNode = scanner.scanRoot();
        if (rootNode.kind != JsonNode::Kind::Object || rootNode.ownDuplicateKey) {
            throw StoreError(6, "output_io_error", "Unsupported or corrupt edits.json");
        }
        const JsonNode* verNode = nullptr;
        const JsonNode* recordsNode = nullptr;
        const JsonNode* receiptsNode = nullptr;
        for (const auto& [k, child] : rootNode.members) {
            if (k == "Version") verNode = &child;
            else if (k == "Records") recordsNode = &child;
            else if (k == "MigrationReceipts") receiptsNode = &child;
            else unknownRootSlices[k] = rawBytes.substr(child.start, child.end - child.start);
        }
        if (!isVersionOneLiteral(verNode) ||
            recordsNode == nullptr || recordsNode->kind != JsonNode::Kind::Object || recordsNode->ownDuplicateKey) {
            throw StoreError(6, "output_io_error", "Unsupported or corrupt edits.json");
        }
        for (const auto& [k, child] : recordsNode->members) {
            const std::string lk = asciiLower(k);
            if (recordsMap.byLower.count(lk)) {
                throw StoreError(6, "output_io_error", "Duplicate case-insensitive key in Windows edits.json Records");
            }
            recordsMap.put(k, rawBytes.substr(child.start, child.end - child.start));
        }
        if (receiptsNode != nullptr && receiptsNode->kind != JsonNode::Kind::Null) {
            if (receiptsNode->kind != JsonNode::Kind::Object || receiptsNode->ownDuplicateKey) {
                throw StoreError(6, "output_io_error", "Unsupported or corrupt edits.json MigrationReceipts");
            }
            hasReceipts = true;
            for (const auto& [k, child] : receiptsNode->members) {
                const std::string lk = asciiLower(k);
                if (receiptsMap.byLower.count(lk)) {
                    throw StoreError(6, "output_io_error", "Duplicate case-insensitive key in Windows edits.json MigrationReceipts");
                }
                receiptsMap.put(k, rawBytes.substr(child.start, child.end - child.start));
            }
        }
    }

    Json identityJson = {
        {"Path", identity.path},
        {"Length", identity.size},
        {"Modified", identity.winModifiedTicks},
        {"Created", identity.winCreatedTicks},
    };
    if (!identity.winFileId.empty()) {
        identityJson["FileID"] = identity.winFileId;
    }

    const int expModeInt = (adj.expModeCanonical == "scene") ? 0 : (adj.expModeCanonical == "preview" ? 1 : 2);
    const bool cameraWb = isRaster ? true : (adj.wbModeInput == "camera");
    const std::string& photoKey = identity.path;
    std::string* existingSlice = recordsMap.findMut(photoKey);
    outHadExisting = (existingSlice != nullptr);

    Json existingRecord;
    if (outHadExisting) {
        try {
            existingRecord = Json::parse(*existingSlice);
        } catch (const std::exception& e) {
            throw StoreError(6, "output_io_error", std::string("Corrupt record for ") + photoKey + " in edits.json: " + e.what());
        }
    }

    Json finalRecord;
    const bool explicitProc = adj.explicitInputs.count("processing_version") > 0;
    if (existingRecord.is_object() && existingRecord.contains("Settings") && existingRecord.at("Settings").is_object()) {
        const Json& existingSettings = existingRecord.at("Settings");
        std::optional<int> oldProcVer;
        if (existingSettings.contains("Processing") && existingSettings.at("Processing").is_object() &&
            existingSettings.at("Processing").contains("version") &&
            existingSettings.at("Processing").at("version").is_number_integer()) {
            oldProcVer = existingSettings.at("Processing").at("version").get<int>();
        }

        Json mergedSettings = existingSettings;
        mergedSettings["SettingsVersion"] = 2;

        auto touched = [&](const char* key) -> bool {
            return adj.explicitInputs.count(key) > 0 || adj.explicitNulls.count(key) > 0;
        };
        std::array<double, 10> vals = extractOrMigrateWindowsValues(existingSettings);
        if (touched("strength")) vals[0] = adj.strength;
        if (touched("exposure")) vals[1] = adj.exposure;
        if (adj.hasWhiteBalanceMode || adj.hasTemp) vals[2] = adj.effectiveTemp;
        if (adj.hasWhiteBalanceMode || adj.hasTint) vals[3] = adj.effectiveTint;
        if (touched("contrast")) vals[4] = 1.0 + adj.contrastPct / 100.0;
        if (touched("highlights")) vals[5] = -adj.highlightsPct / 100.0;
        if (touched("shadows")) vals[6] = adj.shadowsPct / 100.0;
        if (touched("s_curve") ||
            (adj.toneCurveConfig.has_value() && adj.toneCurveConfig->value("mode", "") == "custom")) {
            vals[7] = adj.sCurvePct / 100.0;
        }
        if (touched("saturation")) vals[8] = 1.0 + adj.saturationPct / 100.0;
        if (touched("sharpening")) vals[9] = adj.sharpeningPct / 100.0;
        mergedSettings["Values"] = Json::array({
            vals[0], vals[1], vals[2], vals[3], vals[4],
            vals[5], vals[6], vals[7], vals[8], vals[9],
        });

        if (adj.explicitInputs.count("exposure_mode") || !mergedSettings.contains("ExposureMode")) {
            mergedSettings["ExposureMode"] = expModeInt;
        }
        if (adj.hasWhiteBalanceMode || !mergedSettings.contains("CameraWhiteBalance")) {
            mergedSettings["CameraWhiteBalance"] = cameraWb;
        }
        if (explicitProc || !mergedSettings.contains("Processing")) {
            mergedSettings["Processing"] = {{"family", "rawlab"}, {"version", adj.procVer}, {"quality", "standard"}};
        }
        if (adj.explicitInputs.count("x3f_mode") || !mergedSettings.contains("X3fMode")) {
            mergedSettings["X3fMode"] = adj.x3fMode;
        }
        if (touched("ai_denoise_enabled") || !mergedSettings.contains("AIDenoiseEnabled")) {
            mergedSettings["AIDenoiseEnabled"] = adj.aiDenoiseEnabled;
        }
        if (touched("ai_denoise_blend")) {
            if (!adj.aiDenoiseBlend.has_value() || *adj.aiDenoiseBlend == 100.0) mergedSettings.erase("AIDenoiseBlend");
            else mergedSettings["AIDenoiseBlend"] = *adj.aiDenoiseBlend;
        }
        if (touched("chroma_noise_reduction")) {
            mergedSettings["DisplayChromaDenoise"] = adj.chromaNoiseReduction.value_or(0);
        } else if (!mergedSettings.contains("DisplayChromaDenoise")) {
            mergedSettings["DisplayChromaDenoise"] = 0;
        }
        if (adj.wavelet.has_value()) {
            mergedSettings["Denoise"] = {
                {"Enabled", adj.wavelet->enabled},
                {"Luma", adj.wavelet->luma},
                {"Chroma", adj.wavelet->chroma},
                {"Coarse", adj.wavelet->coarse},
            };
        } else if (adj.explicitNulls.count("wavelet")) {
            mergedSettings["Denoise"] = {{"Enabled", false}, {"Luma", 0.0}, {"Chroma", 46.0}, {"Coarse", 50.0}};
        }
        if (adj.effects.has_value()) {
            mergedSettings["Effects"] = buildWindowsEffectsJson(*adj.effects);
        } else if (adj.explicitNulls.count("photo_effects")) {
            mergedSettings["Effects"] = defaultWindowsEffectsJson();
        }
        if (adj.hsl.has_value()) {
            Json hslArr = Json::array();
            for (const char* axis : {"hue", "saturation", "lightness"}) {
                for (const Json& v : adj.hsl->at(axis)) hslArr.push_back(v);
            }
            mergedSettings["Hsl"] = {{"Values", std::move(hslArr)}};
        } else if (adj.explicitNulls.count("hsl")) {
            mergedSettings["Hsl"] = {{"Values", std::vector<double>(24, 0.0)}};
        }
        if (adj.lens.has_value()) {
            mergedSettings["Lens"] = buildWindowsLensJson(*adj.lens);
        } else if (adj.explicitNulls.count("lens_correction")) {
            mergedSettings["Lens"] = defaultWindowsLensJson();
        }
        if (adj.geometry.has_value()) {
            mergedSettings["Geometry"] = {
                {"CropX", adj.geometry->cropX},
                {"CropY", adj.geometry->cropY},
                {"CropWidth", adj.geometry->cropWidth},
                {"CropHeight", adj.geometry->cropHeight},
                {"QuarterTurns", adj.geometry->quarterTurns},
                {"FlipHorizontal", adj.geometry->flipHorizontal},
                {"FlipVertical", adj.geometry->flipVertical},
                {"StraightenDegrees", adj.geometry->straightenDegrees},
                {"PerspectiveHorizontal", adj.geometry->perspectiveHorizontal},
                {"PerspectiveVertical", adj.geometry->perspectiveVertical},
            };
        } else if (adj.explicitNulls.count("geometry")) {
            mergedSettings["Geometry"] = {
                {"CropX", 0.0}, {"CropY", 0.0}, {"CropWidth", 1.0}, {"CropHeight", 1.0},
                {"QuarterTurns", 0}, {"FlipHorizontal", false}, {"FlipVertical", false},
                {"StraightenDegrees", 0.0}, {"PerspectiveHorizontal", 0.0}, {"PerspectiveVertical", 0.0},
            };
        }
        if (touched("black_point") || touched("white_point") || touched("vibrance")) {
            Json tc = (mergedSettings.contains("ToneControls") && mergedSettings.at("ToneControls").is_object())
                ? mergedSettings.at("ToneControls")
                : Json{{"BlackPoint", 0.0}, {"WhitePoint", 0.0}, {"Vibrance", 0.0}};
            if (touched("black_point")) tc["BlackPoint"] = adj.blackPoint;
            if (touched("white_point")) tc["WhitePoint"] = adj.whitePoint;
            if (touched("vibrance")) tc["Vibrance"] = adj.vibrance;
            if (tc.value("BlackPoint", 0.0) == 0.0 && tc.value("WhitePoint", 0.0) == 0.0 && tc.value("Vibrance", 0.0) == 0.0) {
                mergedSettings.erase("ToneControls");
            } else {
                mergedSettings["ToneControls"] = std::move(tc);
            }
        }
        if (touched("clarity") || touched("dehaze") || touched("texture")) {
            Json atm = (mergedSettings.contains("Atmosphere") && mergedSettings.at("Atmosphere").is_object())
                ? mergedSettings.at("Atmosphere")
                : Json{{"Clarity", 0.0}, {"Dehaze", 0.0}};
            if (touched("clarity")) atm["Clarity"] = adj.clarity;
            if (touched("dehaze")) atm["Dehaze"] = adj.dehaze;
            if (touched("texture")) atm["Texture"] = adj.texture;
            if (atm.value("Clarity", 0.0) == 0.0 && atm.value("Dehaze", 0.0) == 0.0 && atm.value("Texture", 0.0) == 0.0) {
                mergedSettings.erase("Atmosphere");
            } else {
                if (atm.value("Texture", 0.0) == 0.0) atm.erase("Texture");
                mergedSettings["Atmosphere"] = std::move(atm);
            }
        }
        auto syncOptionalBlock = [&](const char* adjKey, const char* winKey, const std::optional<Json>& value) {
            if (value.has_value()) mergedSettings[winKey] = *value;
            else if (touched(adjKey)) mergedSettings.erase(winKey);
        };
        syncOptionalBlock("calibration", "CameraCalibration", adj.calibration);
        syncOptionalBlock("point_color", "PointColor", adj.pointColor);
        syncOptionalBlock("selective_color", "SelectiveColor", adj.selectiveColor);
        syncOptionalBlock("bw", "BwMixer", adj.bwMixer);
        syncOptionalBlock("sharpen_v2", "SharpenV2", adj.sharpenV2);
        syncOptionalBlock("film_optics", "FilmOptics", adj.filmOptics);
        if (adj.colorGradingCanonical.has_value()) {
            mergedSettings["ColorGrading"] = buildWindowsColorGrading(*adj.colorGradingCanonical);
        } else if (adj.explicitNulls.count("color_grading")) {
            mergedSettings.erase("ColorGrading");
        }
        if (adj.toneCurveConfig.has_value()) {
            mergedSettings["Curve"] = *adj.toneCurveConfig;
        } else if (adj.explicitNulls.count("tone_curve")) {
            mergedSettings.erase("Curve");
        }
        if (adj.explicitInputs.count("master_recipe_settings_version") || !mergedSettings.contains("MasterRecipeSettingsVersion")) {
            mergedSettings["MasterRecipeSettingsVersion"] = adj.masterRecipeSettingsVersion;
        }

        finalRecord = existingRecord;
        finalRecord["Identity"] = identityJson;

        if (adj.masterRecipeId.has_value()) {
            mergedSettings["MasterRecipeID"] = *adj.masterRecipeId;
            mergedSettings["MasterRecipeSettingsVersion"] = adj.masterRecipeSettingsVersion;
            finalRecord["Look"] = nullptr;
        } else if (!adj.filmId.empty()) {
            mergedSettings["MasterRecipeID"] = nullptr;
            finalRecord["Look"] = adj.filmId;
        } else if (!finalRecord.contains("Look")) {
            finalRecord["Look"] = nullptr;
        }

        std::optional<int> newProcVer;
        if (mergedSettings.contains("Processing") && mergedSettings.at("Processing").is_object() &&
            mergedSettings.at("Processing").contains("version") &&
            mergedSettings.at("Processing").at("version").is_number_integer()) {
            newProcVer = mergedSettings.at("Processing").at("version").get<int>();
        }
        if (hasReceipts && explicitProc && oldProcVer != newProcVer) {
            receiptsMap.erase(photoKey);
            if (receiptsMap.byLower.empty()) hasReceipts = false;
        }

        finalRecord["Settings"] = std::move(mergedSettings);
    } else {
        Json settings = {
            {"Values", Json::array({
                adj.strength,
                adj.exposure,
                adj.effectiveTemp,
                adj.effectiveTint,
                1.0 + adj.contrastPct / 100.0,
                -adj.highlightsPct / 100.0,
                adj.shadowsPct / 100.0,
                adj.sCurvePct / 100.0,
                1.0 + adj.saturationPct / 100.0,
                adj.sharpeningPct / 100.0,
            })},
            {"ExposureMode", expModeInt},
            {"CameraWhiteBalance", cameraWb},
            {"AsShotTemperature", nullptr},
            {"AsShotTint", nullptr},
            {"Denoise", adj.wavelet.has_value()
                ? Json{{"Enabled", adj.wavelet->enabled}, {"Luma", adj.wavelet->luma}, {"Chroma", adj.wavelet->chroma}, {"Coarse", adj.wavelet->coarse}}
                : Json{{"Enabled", false}, {"Luma", 0.0}, {"Chroma", 46.0}, {"Coarse", 50.0}}},
            {"Effects", adj.effects.has_value()
                ? buildWindowsEffectsJson(*adj.effects)
                : defaultWindowsEffectsJson()},
            {"DisplayChromaDenoise", adj.chromaNoiseReduction.value_or(0)},
            {"MasterRecipeID", adj.masterRecipeId.has_value() ? Json(*adj.masterRecipeId) : Json(nullptr)},
            {"Lens", adj.lens.has_value()
                ? buildWindowsLensJson(*adj.lens)
                : defaultWindowsLensJson()},
            {"Geometry", adj.geometry.has_value()
                ? Json{
                    {"CropX", adj.geometry->cropX}, {"CropY", adj.geometry->cropY},
                    {"CropWidth", adj.geometry->cropWidth}, {"CropHeight", adj.geometry->cropHeight},
                    {"QuarterTurns", adj.geometry->quarterTurns}, {"FlipHorizontal", adj.geometry->flipHorizontal},
                    {"FlipVertical", adj.geometry->flipVertical}, {"StraightenDegrees", adj.geometry->straightenDegrees},
                    {"PerspectiveHorizontal", adj.geometry->perspectiveHorizontal}, {"PerspectiveVertical", adj.geometry->perspectiveVertical}}
                : Json{
                    {"CropX", 0.0}, {"CropY", 0.0}, {"CropWidth", 1.0}, {"CropHeight", 1.0},
                    {"QuarterTurns", 0}, {"FlipHorizontal", false}, {"FlipVertical", false},
                    {"StraightenDegrees", 0.0}, {"PerspectiveHorizontal", 0.0}, {"PerspectiveVertical", 0.0}}},
            {"SettingsVersion", 2},
            {"Processing", {{"family", "rawlab"}, {"version", adj.procVer}, {"quality", "standard"}}},
            {"X3fMode", adj.x3fMode},
            {"AIDenoiseEnabled", adj.aiDenoiseEnabled},
            {"MasterRecipeSettingsVersion", adj.masterRecipeSettingsVersion},
        };
        if (adj.aiDenoiseBlend.has_value() && *adj.aiDenoiseBlend != 100.0) {
            settings["AIDenoiseBlend"] = *adj.aiDenoiseBlend;
        }
        if (adj.hsl.has_value()) {
            Json hslArr = Json::array();
            for (const char* axis : {"hue", "saturation", "lightness"}) {
                for (const Json& v : adj.hsl->at(axis)) hslArr.push_back(v);
            }
            settings["Hsl"] = {{"Values", std::move(hslArr)}};
        } else {
            settings["Hsl"] = {{"Values", std::vector<double>(24, 0.0)}};
        }
        if (adj.hasToneControls) {
            settings["ToneControls"] = {{"BlackPoint", adj.blackPoint}, {"WhitePoint", adj.whitePoint}, {"Vibrance", adj.vibrance}};
        }
        if (adj.hasAtmosphere) {
            Json atm = {{"Clarity", adj.clarity}, {"Dehaze", adj.dehaze}};
            if (adj.texture != 0.0) atm["Texture"] = adj.texture;
            settings["Atmosphere"] = std::move(atm);
        }
        if (adj.calibration.has_value()) settings["CameraCalibration"] = *adj.calibration;
        if (adj.pointColor.has_value()) settings["PointColor"] = *adj.pointColor;
        if (adj.selectiveColor.has_value()) settings["SelectiveColor"] = *adj.selectiveColor;
        if (adj.bwMixer.has_value()) settings["BwMixer"] = *adj.bwMixer;
        if (adj.sharpenV2.has_value()) settings["SharpenV2"] = *adj.sharpenV2;
        if (adj.filmOptics.has_value()) settings["FilmOptics"] = *adj.filmOptics;
        if (adj.colorGradingCanonical.has_value()) {
            settings["ColorGrading"] = buildWindowsColorGrading(*adj.colorGradingCanonical);
        }
        if (adj.toneCurveConfig.has_value()) {
            settings["Curve"] = *adj.toneCurveConfig;
        }

        finalRecord = {
            {"Identity", identityJson},
            {"Settings", std::move(settings)},
            {"Look", (!adj.masterRecipeId.has_value() && !adj.filmId.empty()) ? Json(adj.filmId) : Json(nullptr)},
        };
        if (hasReceipts && explicitProc) {
            receiptsMap.erase(photoKey);
            if (receiptsMap.byLower.empty()) hasReceipts = false;
        }
    }

    recordsMap.put(photoKey, dumpCompactJson(finalRecord));

    const Json lookVal = finalRecord.value("Look", Json(nullptr));
    const Json masterVal = finalRecord.at("Settings").value("MasterRecipeID", Json(nullptr));
    outFinalResultInfo = {
        {"filmID", lookVal.is_string() ? lookVal.get<std::string>() : std::string("")},
        {"masterRecipeID", masterVal},
    };

    std::map<std::string, std::string> rootSlices = std::move(unknownRootSlices);
    if (hasReceipts && !receiptsMap.byLower.empty()) {
        rootSlices["MigrationReceipts"] = receiptsMap.encode();
    }
    rootSlices["Records"] = recordsMap.encode();
    rootSlices["Version"] = "1";
    return encodeRawMapSorted(rootSlices);
}

GuiStoreResult makeError(const StoreError& err) {
    GuiStoreStatus status = GuiStoreStatus::InvalidArgument;
    switch (err.status) {
        case 2: status = GuiStoreStatus::InvalidArgument; break;
        case 3: status = GuiStoreStatus::IoError; break;
        case 4: status = GuiStoreStatus::Unsupported; break;
        case 5: status = GuiStoreStatus::OutOfMemory; break;
        case 6: status = GuiStoreStatus::OutputIoError; break;
        case 7: status = GuiStoreStatus::Cancelled; break;
        case 8: status = GuiStoreStatus::AiNotReady; break;
        default: status = GuiStoreStatus::InvalidArgument; break;
    }
    return GuiStoreResult{false, status, err.code, err.what(), ""};
}

} // namespace

std::optional<GuiStorePlatform> currentHostPlatform() {
#if defined(__APPLE__)
    return GuiStorePlatform::MacOS;
#elif defined(_WIN32)
    return GuiStorePlatform::Windows;
#else
    return std::nullopt;
#endif
}

GuiStoreResult savePresetFromRequestJson(const std::string& requestJson, const GuiStoreOptions& options) {
    try {
        const Json req = parseStrictJsonObject(requestJson, 2, "invalid_argument");
        static const std::unordered_set<std::string> kAllowedReq = {
            "data_dir", "name", "values", "is_raw", "processing_version",
            "overwrite", "recipe_context", "hdr_processing_version",
        };
        for (const auto& kv : req.items()) {
            if (kAllowedReq.find(kv.key()) == kAllowedReq.end()) {
                throw StoreError(2, "invalid_argument", "Unsupported save_preset request field: " + kv.key());
            }
        }
        if (!req.contains("data_dir") || !req.at("data_dir").is_string() || req.at("data_dir").get<std::string>().empty()) {
            throw StoreError(2, "invalid_argument", "save_preset requires nonempty string 'data_dir'");
        }
        if (!req.contains("name") || !req.at("name").is_string()) {
            throw StoreError(2, "invalid_argument", "save_preset requires string 'name'");
        }
        if (!req.contains("values") || !req.at("values").is_object()) {
            throw StoreError(2, "invalid_argument", "save_preset requires object 'values'");
        }

        const std::string dataDirStr = req.at("data_dir").get<std::string>();
        const std::string rawName = req.at("name").get<std::string>();
        const std::string normalizedName = platform::normalizePresetNameUtf8(rawName);
        if (normalizedName.empty()) {
            throw StoreError(2, "invalid_argument", "Preset name cannot be empty");
        }

        std::optional<int> hdrProcVer;
        if (req.contains("hdr_processing_version") && !req.at("hdr_processing_version").is_null()) {
            int64_t hv = 0;
            if (!isStrictIntJson(req.at("hdr_processing_version"), hv) || hv < 1 || hv > 10) {
                throw StoreError(2, "invalid_argument", "hdr_processing_version must be 1..10");
            }
            hdrProcVer = static_cast<int>(hv);
        }

        bool effectiveIsRaw = !hdrProcVer.has_value();
        if (req.contains("is_raw") && !req.at("is_raw").is_null()) {
            if (!req.at("is_raw").is_boolean()) {
                throw StoreError(2, "invalid_argument", "is_raw must be a boolean");
            }
            effectiveIsRaw = req.at("is_raw").get<bool>();
        }

        int procVer = 3;
        if (req.contains("processing_version")) {
            int64_t pv = 0;
            if (!isStrictIntJson(req.at("processing_version"), pv) || pv < 1 || pv > 3) {
                throw StoreError(2, "invalid_argument", "processing_version must be 1, 2, or 3");
            }
            procVer = static_cast<int>(pv);
        }

        bool overwrite = false;
        if (req.contains("overwrite")) {
            if (!req.at("overwrite").is_boolean()) {
                throw StoreError(2, "invalid_argument", "overwrite must be a boolean");
            }
            overwrite = req.at("overwrite").get<bool>();
        }

        Json recipeCtx = nullptr;
        const Json* recipeCtxPtr = nullptr;
        if (req.contains("recipe_context") && !req.at("recipe_context").is_null()) {
            recipeCtx = req.at("recipe_context");
            validateRecipeContext(recipeCtx);
            recipeCtxPtr = &recipeCtx;
        }

        const bool isHdr = hdrProcVer.has_value();
        const Json& values = req.at("values");
        validateTransferValues(values, isHdr, hdrProcVer, effectiveIsRaw, recipeCtxPtr);

        const std::filesystem::path dataDir = platform::pathFromUtf8(dataDirStr);
        const std::filesystem::path presetsFile = platform::resolveControlledSubpath(dataDir, "Presets", "presets.json");
#if defined(_WIN32)
        const char* lockName = "presets.json.lock";
#else
        const char* lockName = ".presets.lock";
#endif
        const std::filesystem::path lockFile = platform::resolveControlledSubpath(dataDir, "Presets", lockName);

        std::string action;
        std::string pid;

        {
            ScopedFileLock lock(lockFile);

            struct UnreadableItem {
                std::optional<std::string> id;
                std::optional<std::string> name;
                std::string rawSlice;
            };
            std::vector<Json> readable;
            std::vector<UnreadableItem> unreadable;
            std::vector<std::string> retiredIds;

            if (std::filesystem::exists(presetsFile)) {
                const std::string rawBytes = platform::readFileBytes(presetsFile, 6, "output_io_error");
                StrictJsonScanner scanner(rawBytes);
                const JsonNode rootNode = scanner.scanRoot();
                if (rootNode.kind != JsonNode::Kind::Object || rootNode.ownDuplicateKey) {
                    throw StoreError(6, "output_io_error", "Unsupported or corrupt presets.json");
                }
                const JsonNode* rvNode = nullptr;
                const JsonNode* presetsNode = nullptr;
                const JsonNode* retiredNode = nullptr;
                for (const auto& [k, child] : rootNode.members) {
                    if (k == "registry_version") rvNode = &child;
                    else if (k == "presets") presetsNode = &child;
                    else if (k == "retired_ids") retiredNode = &child;
                    else throw StoreError(6, "output_io_error", "Corrupt presets.json root keys");
                }
                if (rvNode == nullptr || presetsNode == nullptr) {
                    throw StoreError(6, "output_io_error", "Corrupt presets.json root keys");
                }
                if (!isVersionOneLiteral(rvNode) || presetsNode->kind != JsonNode::Kind::Array) {
                    throw StoreError(6, "output_io_error", "Unsupported or corrupt presets.json");
                }
                if (retiredNode != nullptr) {
                    if (retiredNode->kind != JsonNode::Kind::Array) {
                        throw StoreError(6, "output_io_error", "Corrupt presets.json retired_ids");
                    }
                    std::unordered_set<std::string> retiredSeen;
                    for (const auto& item : retiredNode->items) {
                        if (item.kind != JsonNode::Kind::String || !isCanonicalUuidLower(item.stringVal)) {
                            throw StoreError(6, "output_io_error", "Corrupt presets.json retired_ids");
                        }
                        if (!retiredSeen.insert(item.stringVal).second) {
                            throw StoreError(6, "output_io_error", "Duplicate entries in presets.json retired_ids");
                        }
                        retiredIds.push_back(item.stringVal);
                    }
                }

                for (const auto& element : presetsNode->items) {
                    const std::string rawSlice = rawBytes.substr(element.start, element.end - element.start);
                    std::optional<std::string> entryId;
                    std::optional<std::string> entryName;
                    if (element.kind == JsonNode::Kind::Object) {
                        for (const auto& [mk, mv] : element.members) {
                            if (mk == "id" && mv.kind == JsonNode::Kind::String && !entryId.has_value()) {
                                entryId = mv.stringVal;
                            } else if (mk == "name" && mv.kind == JsonNode::Kind::String && !entryName.has_value()) {
                                entryName = mv.stringVal;
                            }
                        }
                    }
                    bool parsedOk = false;
                    Json parsedEntry;
                    if (element.kind == JsonNode::Kind::Object && !element.nestedDuplicateKey &&
                        timestampsAreIntegers(element)) {
                        try {
                            parsedEntry = Json::parse(rawSlice);
                            parsedOk = isCanonicalPresetEntry(parsedEntry);
                        } catch (const std::exception&) {
                            parsedOk = false;
                        }
                    }
                    if (parsedOk) {
                        readable.push_back(std::move(parsedEntry));
                    } else {
                        unreadable.push_back(UnreadableItem{entryId, entryName, rawSlice});
                        if (entryName.has_value()) {
                            std::string normEntryName;
                            try {
                                normEntryName = platform::normalizePresetNameUtf8(*entryName);
                            } catch (const StoreError&) {
                                normEntryName.clear();
                            }
                            if (!normEntryName.empty() && normEntryName == normalizedName) {
                                throw StoreError(2, "invalid_argument",
                                    "Preset name conflicts with an unreadable future entry: " + normalizedName);
                            }
                        }
                    }
                }

                std::unordered_set<std::string> seenIds;
                std::unordered_set<std::string> seenNames;
                std::unordered_set<std::string> retiredSet(retiredIds.begin(), retiredIds.end());
                for (const auto& p : readable) {
                    const std::string idStr = p.at("id").get<std::string>();
                    const std::string nameStr = p.at("name").get<std::string>();
                    if (!seenIds.insert(idStr).second || !seenNames.insert(nameStr).second || retiredSet.count(idStr)) {
                        throw StoreError(6, "output_io_error", "Corrupt presets.json identity collision");
                    }
                }
            }

            std::unordered_set<std::string> forbiddenIds(retiredIds.begin(), retiredIds.end());
            for (const auto& p : readable) forbiddenIds.insert(p.at("id").get<std::string>());
            for (const auto& u : unreadable) {
                if (u.id.has_value()) forbiddenIds.insert(*u.id);
            }

            const int64_t nowMs = options.clockMillis ? options.clockMillis() : platform::currentUnixMillis();
            auto existingIt = std::find_if(readable.begin(), readable.end(), [&](const Json& p) {
                return p.at("name").get<std::string>() == normalizedName;
            });

            int64_t createdAt = nowMs;
            int64_t updatedAt = nowMs;
            if (existingIt != readable.end()) {
                if (!overwrite) {
                    throw StoreError(2, "invalid_argument",
                        "Preset '" + normalizedName + "' already exists; pass overwrite=true to update");
                }
                pid = existingIt->at("id").get<std::string>();
                createdAt = existingIt->at("created_at").get<int64_t>();
                updatedAt = std::max<int64_t>(nowMs, existingIt->at("updated_at").get<int64_t>() + 1);
                action = "updated";
            } else {
                for (int attempt = 0; attempt < 16; ++attempt) {
                    const std::string cand = options.generateUuid ? options.generateUuid() : platform::generateUuidV4Lowercase();
                    if (isCanonicalUuidLower(cand) && !forbiddenIds.count(cand)) {
                        pid = cand;
                        break;
                    }
                }
                if (pid.empty()) {
                    throw StoreError(6, "output_io_error", "Failed to allocate unique preset UUID");
                }
                action = "created";
            }

            Json source = {
                {"identifier", "preset:" + pid},
                {"is_raw", effectiveIsRaw},
                {"processing_version", procVer},
                {"recipe", recipeCtx},
            };
            if (hdrProcVer.has_value()) {
                source["hdr_processing_version"] = *hdrProcVer;
            }
            const int payloadVer = isHdr ? 2 : 1;
            Json presetEntry = {
                {"id", pid},
                {"name", normalizedName},
                {"created_at", createdAt},
                {"updated_at", updatedAt},
                {"payload", {
                    {"payload_version", payloadVer},
                    {"scope_version", payloadVer},
                    {"source", std::move(source)},
                    {"values", values},
                }},
            };

            if (existingIt != readable.end()) {
                *existingIt = std::move(presetEntry);
            } else {
                readable.push_back(std::move(presetEntry));
            }

            std::string encoded = "{\"presets\":[";
            bool first = true;
            for (const auto& p : readable) {
                if (!first) encoded.push_back(',');
                first = false;
                encoded += dumpCompactJson(p);
            }
            for (const auto& u : unreadable) {
                if (!first) encoded.push_back(',');
                first = false;
                encoded += u.rawSlice;
            }
            encoded += "],\"registry_version\":1,\"retired_ids\":";
            encoded += dumpCompactJson(Json(retiredIds));
            encoded.push_back('}');

            platform::atomicWriteBytes(presetsFile, encoded);
        }

        const Json result = {
            {"action", action},
            {"id", pid},
            {"name", normalizedName},
            {"presets_file", platform::pathToUtf8(presetsFile)},
        };
        return GuiStoreResult{true, GuiStoreStatus::Ok, "ok", "", dumpCompactJson(result)};
    } catch (const StoreError& err) {
        return makeError(err);
    } catch (const std::bad_alloc&) {
        return GuiStoreResult{false, GuiStoreStatus::OutOfMemory, "out_of_memory", "Out of memory", ""};
    } catch (const std::exception& err) {
        return GuiStoreResult{false, GuiStoreStatus::InvalidArgument, "invalid_argument", err.what(), ""};
    }
}

GuiStoreResult syncPhotoEditFromRequestJson(const std::string& requestJson, const GuiStoreOptions& options) {
    try {
        const std::optional<GuiStorePlatform> target = options.targetPlatform.has_value()
            ? options.targetPlatform
            : currentHostPlatform();
        if (!target.has_value()) {
            throw StoreError(4, "unsupported", "sync_photo_edit targets macOS or Windows desktop RawLab");
        }

        const Json req = parseStrictJsonObject(requestJson, 2, "invalid_argument");
        static const std::unordered_set<std::string> kAllowedReq = {
            "data_dir", "photo_path", "adjustments", "is_raster", "film_id", "master_recipe_id",
        };
        for (const auto& kv : req.items()) {
            if (kAllowedReq.find(kv.key()) == kAllowedReq.end()) {
                throw StoreError(2, "invalid_argument", "Unsupported sync_photo_edit request field: " + kv.key());
            }
        }
        if (!req.contains("data_dir") || !req.at("data_dir").is_string() || req.at("data_dir").get<std::string>().empty()) {
            throw StoreError(2, "invalid_argument", "sync_photo_edit requires nonempty string 'data_dir'");
        }
        if (!req.contains("photo_path") || !req.at("photo_path").is_string() || req.at("photo_path").get<std::string>().empty()) {
            throw StoreError(2, "invalid_argument", "sync_photo_edit requires nonempty string 'photo_path'");
        }
        if (!req.contains("adjustments") || !req.at("adjustments").is_object()) {
            throw StoreError(2, "invalid_argument", "sync_photo_edit requires object 'adjustments'");
        }
        if (!req.contains("is_raster") || !req.at("is_raster").is_boolean()) {
            throw StoreError(2, "invalid_argument", "sync_photo_edit requires boolean 'is_raster'");
        }

        std::string filmId;
        if (req.contains("film_id") && !req.at("film_id").is_null()) {
            if (!req.at("film_id").is_string()) {
                throw StoreError(2, "invalid_argument", "film_id must be a string");
            }
            filmId = req.at("film_id").get<std::string>();
        }
        std::optional<std::string> masterRecipeId;
        if (req.contains("master_recipe_id") && !req.at("master_recipe_id").is_null()) {
            if (!req.at("master_recipe_id").is_string() || req.at("master_recipe_id").get<std::string>().empty()) {
                throw StoreError(2, "invalid_argument", "master_recipe_id must be a nonempty string or null");
            }
            masterRecipeId = req.at("master_recipe_id").get<std::string>();
        }

        const bool isRaster = req.at("is_raster").get<bool>();
        const ParsedAdjustments parsedAdj = parseAndValidateAdjustments(
            req.at("adjustments"), isRaster, filmId, masterRecipeId);

        const std::string dataDirStr = req.at("data_dir").get<std::string>();
        const std::string photoPathStr = req.at("photo_path").get<std::string>();

        GuiStoreFileIdentity identity;
        if (options.readIdentity) {
            identity = options.readIdentity(photoPathStr, *target);
        } else if (*target == GuiStorePlatform::MacOS) {
            const MacFileIdentity macId = platform::readMacFileIdentity(platform::pathFromUtf8(photoPathStr));
            identity.path = macId.path;
            identity.size = macId.size;
            identity.macModified = macId.modified;
            identity.macFileNumber = macId.fileNumber;
        } else {
            const WindowsFileIdentity winId = platform::readWindowsFileIdentity(platform::pathFromUtf8(photoPathStr));
            identity.path = winId.path;
            identity.size = winId.length;
            identity.winModifiedTicks = winId.modified;
            identity.winCreatedTicks = winId.created;
            identity.winFileId = winId.fileId;
        }

        const std::filesystem::path dataDir = platform::pathFromUtf8(dataDirStr);
        const std::filesystem::path editsFile = platform::resolveControlledSubpath(dataDir, "Edits", "edits.json");
#if defined(_WIN32)
        const char* lockName = "edits.json.lock";
#else
        const char* lockName = ".edits.lock";
#endif
        const std::filesystem::path lockFile = platform::resolveControlledSubpath(dataDir, "Edits", lockName);

        bool hadExisting = false;
        Json resultMeta;
        {
            ScopedFileLock lock(lockFile);
            std::string encoded;
            if (*target == GuiStorePlatform::MacOS) {
                Json finalState;
                encoded = syncMacEditsFile(editsFile, identity, parsedAdj, isRaster, hadExisting, finalState);
                std::string finalFilmId;
                if (finalState.contains("filmID") && finalState.at("filmID").is_string()) {
                    finalFilmId = finalState.at("filmID").get<std::string>();
                }
                resultMeta = {
                    {"filmID", finalFilmId},
                    {"masterRecipeID", finalState.contains("masterRecipeID") ? finalState.at("masterRecipeID") : Json(nullptr)},
                };
            } else {
                encoded = syncWindowsEditsFile(editsFile, identity, parsedAdj, isRaster, hadExisting, resultMeta);
            }
            platform::atomicWriteBytes(editsFile, encoded);
        }

        const Json result = {
            {"action", hadExisting ? "updated" : "created"},
            {"photo_path", identity.path},
            {"edits_file", platform::pathToUtf8(editsFile)},
            {"filmID", resultMeta.value("filmID", "")},
            {"masterRecipeID", resultMeta.value("masterRecipeID", Json(nullptr))},
        };
        return GuiStoreResult{true, GuiStoreStatus::Ok, "ok", "", dumpCompactJson(result)};
    } catch (const StoreError& err) {
        return makeError(err);
    } catch (const std::bad_alloc&) {
        return GuiStoreResult{false, GuiStoreStatus::OutOfMemory, "out_of_memory", "Out of memory", ""};
    } catch (const std::exception& err) {
        return GuiStoreResult{false, GuiStoreStatus::InvalidArgument, "invalid_argument", err.what(), ""};
    }
}

} // namespace gui_store
} // namespace sony2fuji
