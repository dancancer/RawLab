#include "core/sony_ptpip.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <string>
#include <string_view>
#include <vector>

namespace sony2fuji::sony {
namespace {

inline uint16_t readU16LE(const uint8_t* p) noexcept {
    return static_cast<uint16_t>(p[0]) | (static_cast<uint16_t>(p[1]) << 8);
}

inline uint32_t readU32LE(const uint8_t* p) noexcept {
    return static_cast<uint32_t>(p[0]) |
           (static_cast<uint32_t>(p[1]) << 8) |
           (static_cast<uint32_t>(p[2]) << 16) |
           (static_cast<uint32_t>(p[3]) << 24);
}

inline uint64_t readU64LE(const uint8_t* p) noexcept {
    return static_cast<uint64_t>(readU32LE(p)) |
           (static_cast<uint64_t>(readU32LE(p + 4)) << 32);
}

inline void appendU16LE(std::vector<uint8_t>& out, uint16_t v) {
    out.push_back(static_cast<uint8_t>(v & 0xffu));
    out.push_back(static_cast<uint8_t>((v >> 8) & 0xffu));
}

inline void appendU32LE(std::vector<uint8_t>& out, uint32_t v) {
    out.push_back(static_cast<uint8_t>(v & 0xffu));
    out.push_back(static_cast<uint8_t>((v >> 8) & 0xffu));
    out.push_back(static_cast<uint8_t>((v >> 16) & 0xffu));
    out.push_back(static_cast<uint8_t>((v >> 24) & 0xffu));
}

inline void appendU64LE(std::vector<uint8_t>& out, uint64_t v) {
    appendU32LE(out, static_cast<uint32_t>(v & 0xffffffffu));
    appendU32LE(out, static_cast<uint32_t>((v >> 32) & 0xffffffffu));
}

void wrapPacket(uint32_t packet_type, const uint8_t* payload, size_t payload_len, std::vector<uint8_t>& out_packet) {
    out_packet.clear();
    out_packet.reserve(8 + payload_len);
    appendU32LE(out_packet, static_cast<uint32_t>(8 + payload_len));
    appendU32LE(out_packet, packet_type);
    if (payload_len > 0 && payload != nullptr) {
        out_packet.insert(out_packet.end(), payload, payload + payload_len);
    }
}

bool appendUtf8CodePoint(uint32_t cp, std::string& out) {
    if (cp == 0 || cp > 0x10FFFFu || (cp >= 0xD800u && cp <= 0xDFFFu)) {
        return false;
    }
    if (cp <= 0x7Fu) {
        out.push_back(static_cast<char>(cp));
    } else if (cp <= 0x7FFu) {
        out.push_back(static_cast<char>(0xC0u | (cp >> 6)));
        out.push_back(static_cast<char>(0x80u | (cp & 0x3Fu)));
    } else if (cp <= 0xFFFFu) {
        out.push_back(static_cast<char>(0xE0u | (cp >> 12)));
        out.push_back(static_cast<char>(0x80u | ((cp >> 6) & 0x3Fu)));
        out.push_back(static_cast<char>(0x80u | (cp & 0x3Fu)));
    } else {
        out.push_back(static_cast<char>(0xF0u | (cp >> 18)));
        out.push_back(static_cast<char>(0x80u | ((cp >> 12) & 0x3Fu)));
        out.push_back(static_cast<char>(0x80u | ((cp >> 6) & 0x3Fu)));
        out.push_back(static_cast<char>(0x80u | (cp & 0x3Fu)));
    }
    return true;
}

bool utf16LeToUtf8(const uint8_t* bytes, size_t byte_len, std::string& out) {
    out.clear();
    if (byte_len % 2 != 0) {
        return false;
    }
    const size_t unit_count = byte_len / 2;
    out.reserve(unit_count);
    for (size_t i = 0; i < unit_count; ++i) {
        const uint16_t u1 = readU16LE(bytes + i * 2);
        if (u1 == 0) {
            return false;
        }
        if (u1 >= 0xD800u && u1 <= 0xDBFFu) {
            if (i + 1 >= unit_count) {
                return false;
            }
            const uint16_t u2 = readU16LE(bytes + (i + 1) * 2);
            if (u2 < 0xDC00u || u2 > 0xDFFFu) {
                return false;
            }
            const uint32_t cp = 0x10000u + ((static_cast<uint32_t>(u1 - 0xD800u) << 10) |
                                             static_cast<uint32_t>(u2 - 0xDC00u));
            if (!appendUtf8CodePoint(cp, out)) {
                return false;
            }
            ++i;
        } else if (u1 >= 0xDC00u && u1 <= 0xDFFFu) {
            return false;
        } else {
            if (!appendUtf8CodePoint(u1, out)) {
                return false;
            }
        }
    }
    return true;
}

bool isValidUtf8NoNul(const uint8_t* bytes, size_t len) noexcept {
    size_t i = 0;
    while (i < len) {
        const uint8_t b0 = bytes[i];
        if (b0 == 0) {
            return false;
        }
        if (b0 <= 0x7Fu) {
            ++i;
        } else if ((b0 & 0xE0u) == 0xC0u) {
            if (i + 1 >= len || b0 < 0xC2u) return false;
            const uint8_t b1 = bytes[i + 1];
            if ((b1 & 0xC0u) != 0x80u) return false;
            i += 2;
        } else if ((b0 & 0xF0u) == 0xE0u) {
            if (i + 2 >= len) return false;
            const uint8_t b1 = bytes[i + 1];
            const uint8_t b2 = bytes[i + 2];
            if ((b1 & 0xC0u) != 0x80u || (b2 & 0xC0u) != 0x80u) return false;
            if (b0 == 0xE0u && b1 < 0xA0u) return false;
            if (b0 == 0xEDu && b1 >= 0xA0u) return false;
            i += 3;
        } else if ((b0 & 0xF8u) == 0xF0u) {
            if (i + 3 >= len || b0 > 0xF4u) return false;
            const uint8_t b1 = bytes[i + 1];
            const uint8_t b2 = bytes[i + 2];
            const uint8_t b3 = bytes[i + 3];
            if ((b1 & 0xC0u) != 0x80u || (b2 & 0xC0u) != 0x80u || (b3 & 0xC0u) != 0x80u) return false;
            if (b0 == 0xF0u && b1 < 0x90u) return false;
            if (b0 == 0xF4u && b1 > 0x8Fu) return false;
            i += 4;
        } else {
            return false;
        }
    }
    return true;
}

bool utf8ToUtf16LeWithNul(std::string_view utf8, std::vector<uint8_t>& out_bytes) {
    out_bytes.clear();
    const auto* bytes = reinterpret_cast<const uint8_t*>(utf8.data());
    const size_t len = utf8.size();
    size_t i = 0;
    while (i < len) {
        const uint8_t b0 = bytes[i];
        uint32_t cp = 0;
        if (b0 == 0) {
            return false;
        } else if (b0 <= 0x7Fu) {
            cp = b0;
            ++i;
        } else if ((b0 & 0xE0u) == 0xC0u) {
            if (i + 1 >= len || b0 < 0xC2u) return false;
            const uint8_t b1 = bytes[i + 1];
            if ((b1 & 0xC0u) != 0x80u) return false;
            cp = ((static_cast<uint32_t>(b0 & 0x1Fu)) << 6) | static_cast<uint32_t>(b1 & 0x3Fu);
            i += 2;
        } else if ((b0 & 0xF0u) == 0xE0u) {
            if (i + 2 >= len) return false;
            const uint8_t b1 = bytes[i + 1];
            const uint8_t b2 = bytes[i + 2];
            if ((b1 & 0xC0u) != 0x80u || (b2 & 0xC0u) != 0x80u) return false;
            if (b0 == 0xE0u && b1 < 0xA0u) return false;
            if (b0 == 0xEDu && b1 >= 0xA0u) return false;
            cp = ((static_cast<uint32_t>(b0 & 0x0Fu)) << 12) |
                 ((static_cast<uint32_t>(b1 & 0x3Fu)) << 6) |
                 static_cast<uint32_t>(b2 & 0x3Fu);
            i += 3;
        } else if ((b0 & 0xF8u) == 0xF0u) {
            if (i + 3 >= len || b0 > 0xF4u) return false;
            const uint8_t b1 = bytes[i + 1];
            const uint8_t b2 = bytes[i + 2];
            const uint8_t b3 = bytes[i + 3];
            if ((b1 & 0xC0u) != 0x80u || (b2 & 0xC0u) != 0x80u || (b3 & 0xC0u) != 0x80u) return false;
            if (b0 == 0xF0u && b1 < 0x90u) return false;
            if (b0 == 0xF4u && b1 > 0x8Fu) return false;
            cp = ((static_cast<uint32_t>(b0 & 0x07u)) << 18) |
                 ((static_cast<uint32_t>(b1 & 0x3Fu)) << 12) |
                 ((static_cast<uint32_t>(b2 & 0x3Fu)) << 6) |
                 static_cast<uint32_t>(b3 & 0x3Fu);
            i += 4;
        } else {
            return false;
        }
        if (cp <= 0xFFFFu) {
            appendU16LE(out_bytes, static_cast<uint16_t>(cp));
        } else {
            const uint32_t adj = cp - 0x10000u;
            appendU16LE(out_bytes, static_cast<uint16_t>(0xD800u | (adj >> 10)));
            appendU16LE(out_bytes, static_cast<uint16_t>(0xDC00u | (adj & 0x3FFu)));
        }
    }
    appendU16LE(out_bytes, 0);
    return true;
}

class Reader {
public:
    Reader(const uint8_t* data, size_t len) noexcept : data_(data), len_(len) {}

    size_t remaining() const noexcept { return len_ - offset_; }

    bool take(size_t count, const uint8_t*& out_ptr) noexcept {
        if (count > remaining()) {
            return false;
        }
        out_ptr = data_ + offset_;
        offset_ += count;
        return true;
    }

    bool skip(size_t count) noexcept {
        if (count > remaining()) {
            return false;
        }
        offset_ += count;
        return true;
    }

    bool u8(uint8_t& out) noexcept {
        const uint8_t* p = nullptr;
        if (!take(1, p)) return false;
        out = p[0];
        return true;
    }

    bool u16(uint16_t& out) noexcept {
        const uint8_t* p = nullptr;
        if (!take(2, p)) return false;
        out = readU16LE(p);
        return true;
    }

    bool u32(uint32_t& out) noexcept {
        const uint8_t* p = nullptr;
        if (!take(4, p)) return false;
        out = readU32LE(p);
        return true;
    }

    bool u64(uint64_t& out) noexcept {
        const uint8_t* p = nullptr;
        if (!take(8, p)) return false;
        out = readU64LE(p);
        return true;
    }

    bool ptpString(bool terminated, std::string& out) {
        out.clear();
        uint8_t count = 0;
        if (!u8(count)) return false;
        if (count == 0) {
            return true;
        }
        const size_t byte_len = static_cast<size_t>(count) * 2u;
        const uint8_t* p = nullptr;
        if (!take(byte_len, p)) return false;
        size_t payload_bytes = byte_len;
        if (payload_bytes >= 2 && p[payload_bytes - 2] == 0 && p[payload_bytes - 1] == 0) {
            payload_bytes -= 2;
        } else if (terminated) {
            return false;
        }
        return utf16LeToUtf8(p, payload_bytes, out);
    }

    bool u16Array(std::vector<uint16_t>& out) {
        out.clear();
        uint32_t count = 0;
        if (!u32(count)) return false;
        if (count > 4096u || static_cast<size_t>(count) * 2u > remaining()) {
            return false;
        }
        out.reserve(count);
        for (uint32_t i = 0; i < count; ++i) {
            uint16_t v = 0;
            if (!u16(v)) return false;
            out.push_back(v);
        }
        return true;
    }

private:
    const uint8_t* data_ = nullptr;
    size_t len_ = 0;
    size_t offset_ = 0;
};

struct PropVal {
    sony2fuji_sony_property_value_kind kind = SONY2FUJI_SONY_PROP_OPAQUE;
    int64_t number = 0;
    std::string text;
};

bool readPropertyValue(Reader& reader, uint16_t type, PropVal& out, int depth = 0) {
    if (depth > 2) {
        return false;
    }
    if (type == 0xffffu) {
        out.kind = SONY2FUJI_SONY_PROP_TEXT;
        out.number = 0;
        return reader.ptpString(false, out.text);
    }
    if ((type & 0x4000u) != 0) {
        uint32_t count = 0;
        if (!reader.u32(count)) return false;
        const uint16_t scalar = static_cast<uint16_t>(type & ~uint16_t(0x4000u));
        if (count > 4096u || scalar < 1u || scalar > 10u) {
            return false;
        }
        PropVal elem;
        for (uint32_t i = 0; i < count; ++i) {
            if (!readPropertyValue(reader, scalar, elem, depth + 1)) {
                return false;
            }
        }
        out.kind = SONY2FUJI_SONY_PROP_OPAQUE;
        out.number = 0;
        out.text.clear();
        return true;
    }
    out.text.clear();
    switch (type) {
        case 1: {
            uint8_t v = 0;
            if (!reader.u8(v)) return false;
            out.kind = SONY2FUJI_SONY_PROP_NUMBER;
            out.number = static_cast<int8_t>(v);
            return true;
        }
        case 2: {
            uint8_t v = 0;
            if (!reader.u8(v)) return false;
            out.kind = SONY2FUJI_SONY_PROP_NUMBER;
            out.number = static_cast<int64_t>(v);
            return true;
        }
        case 3: {
            uint16_t v = 0;
            if (!reader.u16(v)) return false;
            out.kind = SONY2FUJI_SONY_PROP_NUMBER;
            out.number = static_cast<int16_t>(v);
            return true;
        }
        case 4: {
            uint16_t v = 0;
            if (!reader.u16(v)) return false;
            out.kind = SONY2FUJI_SONY_PROP_NUMBER;
            out.number = static_cast<int64_t>(v);
            return true;
        }
        case 5: {
            uint32_t v = 0;
            if (!reader.u32(v)) return false;
            out.kind = SONY2FUJI_SONY_PROP_NUMBER;
            out.number = static_cast<int32_t>(v);
            return true;
        }
        case 6: {
            uint32_t v = 0;
            if (!reader.u32(v)) return false;
            out.kind = SONY2FUJI_SONY_PROP_NUMBER;
            out.number = static_cast<int64_t>(v);
            return true;
        }
        case 7:
        case 8: {
            uint64_t v = 0;
            if (!reader.u64(v)) return false;
            out.kind = SONY2FUJI_SONY_PROP_NUMBER;
            int64_t signed_val = 0;
            std::memcpy(&signed_val, &v, sizeof(signed_val));
            out.number = signed_val;
            return true;
        }
        case 9:
        case 10:
            if (!reader.skip(16)) return false;
            out.kind = SONY2FUJI_SONY_PROP_OPAQUE;
            out.number = 0;
            return true;
        default:
            return false;
    }
}

bool containsU16(const uint16_t* arr, uint32_t count, uint16_t target) noexcept {
    if (!arr || count == 0) return false;
    for (uint32_t i = 0; i < count; ++i) {
        if (arr[i] == target) return true;
    }
    return false;
}

bool asciiEndsWithInsensitive(std::string_view str, std::string_view suffix) noexcept {
    if (str.size() < suffix.size()) return false;
    const size_t offset = str.size() - suffix.size();
    for (size_t i = 0; i < suffix.size(); ++i) {
        char a = str[offset + i];
        char b = suffix[i];
        if (a >= 'A' && a <= 'Z') a = static_cast<char>(a + ('a' - 'A'));
        if (b >= 'A' && b <= 'Z') b = static_cast<char>(b + ('a' - 'A'));
        if (a != b) return false;
    }
    return true;
}

bool asciiContainsInsensitive(std::string_view haystack, std::string_view needle) noexcept {
    if (needle.empty()) return true;
    if (haystack.size() < needle.size()) return false;
    for (size_t i = 0; i + needle.size() <= haystack.size(); ++i) {
        bool match = true;
        for (size_t j = 0; j < needle.size(); ++j) {
            char a = haystack[i + j];
            char b = needle[j];
            if (a >= 'A' && a <= 'Z') a = static_cast<char>(a + ('a' - 'A'));
            if (b >= 'A' && b <= 'Z') b = static_cast<char>(b + ('a' - 'A'));
            if (a != b) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

bool isFixedFocusArea(int64_t area) noexcept {
    return area == 0x0001 || area == 0x0003 || area == 0x0201 || area == 0x0203;
}

} // namespace

const PropertyEntry* PropertyTable::find(uint16_t code) const noexcept {
    for (const auto& entry : entries) {
        if (entry.info.code == code) {
            return &entry;
        }
    }
    return nullptr;
}

sony2fuji_status buildInitCommand(
    const uint8_t* guid16,
    std::string_view client_name,
    uint32_t protocol_version,
    std::vector<uint8_t>& out_packet
) {
    if (!guid16) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    std::vector<uint8_t> utf16_name;
    if (!utf8ToUtf16LeWithNul(client_name, utf16_name)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    std::vector<uint8_t> payload;
    payload.reserve(16 + utf16_name.size() + 4);
    payload.insert(payload.end(), guid16, guid16 + 16);
    payload.insert(payload.end(), utf16_name.begin(), utf16_name.end());
    appendU32LE(payload, protocol_version);
    wrapPacket(1u, payload.data(), payload.size(), out_packet);
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status buildInitEvent(uint32_t connection_number, std::vector<uint8_t>& out_packet) {
    std::vector<uint8_t> payload;
    payload.reserve(4);
    appendU32LE(payload, connection_number);
    wrapPacket(3u, payload.data(), payload.size(), out_packet);
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status buildOpRequest(
    uint32_t data_phase,
    uint16_t op_code,
    uint32_t transaction_id,
    const uint32_t* params,
    uint32_t param_count,
    std::vector<uint8_t>& out_packet
) {
    if (param_count > 5u || (param_count > 0 && params == nullptr)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    std::vector<uint8_t> payload;
    payload.reserve(10 + param_count * 4u);
    appendU32LE(payload, data_phase);
    appendU16LE(payload, op_code);
    appendU32LE(payload, transaction_id);
    for (uint32_t i = 0; i < param_count; ++i) {
        appendU32LE(payload, params[i]);
    }
    wrapPacket(6u, payload.data(), payload.size(), out_packet);
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status buildStartData(
    uint32_t transaction_id,
    uint64_t total_bytes,
    std::vector<uint8_t>& out_packet
) {
    std::vector<uint8_t> payload;
    payload.reserve(12);
    appendU32LE(payload, transaction_id);
    appendU64LE(payload, total_bytes);
    wrapPacket(9u, payload.data(), payload.size(), out_packet);
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status buildEndData(
    uint32_t transaction_id,
    const uint8_t* payload,
    size_t payload_len,
    std::vector<uint8_t>& out_packet
) {
    if (payload_len > kPtpipDataLimit || (payload_len > 0 && payload == nullptr)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    std::vector<uint8_t> body;
    body.reserve(4 + payload_len);
    appendU32LE(body, transaction_id);
    if (payload_len > 0) {
        body.insert(body.end(), payload, payload + payload_len);
    }
    wrapPacket(12u, body.data(), body.size(), out_packet);
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status buildProbeResponse(std::vector<uint8_t>& out_packet) {
    wrapPacket(14u, nullptr, 0, out_packet);
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status parsePtpipHeader(
    const uint8_t* header8,
    size_t len,
    uint64_t max_payload_bytes,
    sony2fuji_sony_ptpip_header& out_header
) noexcept {
    out_header = {};
    if (!header8 || len != 8u) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    const uint32_t length = readU32LE(header8);
    const uint32_t type = readU32LE(header8 + 4);
    if (length < 8u || static_cast<uint64_t>(length - 8u) > max_payload_bytes) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    out_header.packet_type = type;
    out_header.payload_size = length - 8u;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status parseInitCmdAck(
    const uint8_t* payload,
    size_t len,
    uint32_t& out_connection_number
) noexcept {
    out_connection_number = 0;
    if (!payload || len < 24u) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    out_connection_number = readU32LE(payload);
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status parseStartData(
    const uint8_t* payload,
    size_t len,
    sony2fuji_sony_ptpip_start_data& out_start
) noexcept {
    out_start = {};
    if (!payload || len != 12u) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    out_start.transaction_id = readU32LE(payload);
    out_start.reserved0 = 0;
    out_start.total_bytes = readU64LE(payload + 4);
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status parseResponse(
    const uint8_t* payload,
    size_t len,
    sony2fuji_sony_ptpip_response& out_resp
) noexcept {
    out_resp = {};
    if (!payload || len < 6u || len > 26u || ((len - 6u) % 4u) != 0) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    out_resp.response_code = readU16LE(payload);
    out_resp.reserved0 = 0;
    out_resp.transaction_id = readU32LE(payload + 2);
    out_resp.param_count = static_cast<uint32_t>((len - 6u) / 4u);
    for (uint32_t i = 0; i < out_resp.param_count; ++i) {
        out_resp.params[i] = readU32LE(payload + 6u + static_cast<size_t>(i) * 4u);
    }
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status parseEvent(
    const uint8_t* payload,
    size_t len,
    sony2fuji_sony_ptpip_event& out_evt
) noexcept {
    out_evt = {};
    if (!payload || len < 6u || len > 18u || ((len - 6u) % 4u) != 0) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    out_evt.event_code = readU16LE(payload);
    out_evt.reserved0 = 0;
    out_evt.transaction_id = readU32LE(payload + 2);
    out_evt.param_count = static_cast<uint32_t>((len - 6u) / 4u);
    for (uint32_t i = 0; i < out_evt.param_count; ++i) {
        out_evt.params[i] = readU32LE(payload + 6u + static_cast<size_t>(i) * 4u);
    }
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status parseWifiCredential(
    const uint8_t* data,
    size_t len,
    bool is_password,
    std::string& out_value
) {
    out_value.clear();
    if (!data || len < 4u || static_cast<size_t>(data[0]) != len - 1u) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    size_t start = 3u;
    size_t end = len;
    while (end > start && data[end - 1u] == 0) {
        --end;
    }
    const size_t value_len = end - start;
    const size_t min_len = is_password ? 8u : 1u;
    const size_t max_len = is_password ? 63u : 32u;
    if (value_len < min_len || value_len > max_len) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    for (size_t i = start; i < end; ++i) {
        if (data[i] < 32u || data[i] > 126u) {
            return SONY2FUJI_STATUS_INVALID_ARGUMENT;
        }
    }
    out_value.assign(reinterpret_cast<const char*>(data + start), value_len);
    return SONY2FUJI_STATUS_OK;
}

bool isValidPhotoFilename(std::string_view name) noexcept {
    if (name.empty() || name == "." || name == "..") {
        return false;
    }
    for (char ch : name) {
        if (ch == '/' || ch == '\\' || ch == '\0') {
            return false;
        }
    }
    return true;
}

bool isPhotoFilename(std::string_view name) noexcept {
    return asciiEndsWithInsensitive(name, ".arw") ||
           asciiEndsWithInsensitive(name, ".jpg") ||
           asciiEndsWithInsensitive(name, ".jpeg");
}

bool validatePhotoHeader(std::string_view name, const uint8_t* prefix, size_t prefix_len) noexcept {
    if (!prefix) {
        return false;
    }
    const bool tiff = prefix_len >= 4u &&
                      ((prefix[0] == 0x49u && prefix[1] == 0x49u && prefix[2] == 0x2au && prefix[3] == 0x00u) ||
                       (prefix[0] == 0x4du && prefix[1] == 0x4du && prefix[2] == 0x00u && prefix[3] == 0x2au));
    const bool jpeg = prefix_len >= 3u &&
                      prefix[0] == 0xffu && prefix[1] == 0xd8u && prefix[2] == 0xffu;
    if (asciiEndsWithInsensitive(name, ".arw")) {
        return tiff;
    }
    return isPhotoFilename(name) && jpeg;
}

sony2fuji_status parseDeviceInfo(const uint8_t* data, size_t len, DeviceInfo& out_info) {
    out_info = {};
    if (!data && len > 0) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    Reader reader(data, len);
    uint16_t std_ver = 0;
    uint32_t vendor_id = 0;
    uint16_t vendor_ver = 0;
    std::string vendor_desc;
    uint16_t func_mode = 0;
    if (!reader.u16(std_ver) || !reader.u32(vendor_id) || !reader.u16(vendor_ver) ||
        !reader.ptpString(true, vendor_desc) || !reader.u16(func_mode)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    if (!reader.u16Array(out_info.operations)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    std::vector<uint16_t> scratch;
    for (int i = 0; i < 4; ++i) {
        if (!reader.u16Array(scratch)) {
            return SONY2FUJI_STATUS_INVALID_ARGUMENT;
        }
    }
    if (!reader.ptpString(true, out_info.manufacturer) ||
        !reader.ptpString(true, out_info.model) ||
        !reader.ptpString(true, out_info.firmware) ||
        !reader.ptpString(true, out_info.serial)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    if (vendor_id != 17u ||
        !asciiContainsInsensitive(out_info.manufacturer, "sony") ||
        out_info.model.empty() ||
        out_info.firmware.empty()) {
        return SONY2FUJI_STATUS_UNSUPPORTED;
    }
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status parseRemoteDescriptor(const uint8_t* data, size_t len, RemoteDescriptor& out_desc) {
    out_desc = {};
    if (!data && len > 0) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    Reader reader(data, len);
    if (!reader.u16(out_desc.version) ||
        !reader.u16Array(out_desc.properties) ||
        !reader.u16Array(out_desc.controls)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    const bool supported = (out_desc.version == 0xc8u && reader.remaining() == 0) ||
                           out_desc.version >= 0x12cu;
    if (!supported) {
        return SONY2FUJI_STATUS_UNSUPPORTED;
    }
    out_desc.enum_tables = (out_desc.version >= 0x12cu) ? 2 : 1;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status parseProperties(const uint8_t* data, size_t len, int32_t enum_tables, PropertyTable& out_table) {
    out_table.entries.clear();
    if ((enum_tables != 1 && enum_tables != 2) || (!data && len > 0)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    Reader reader(data, len);
    uint64_t count = 0;
    if (!reader.u64(count) || count > 4096u) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    out_table.entries.reserve(static_cast<size_t>(count));
    size_t enum_count = 0;
    std::vector<uint8_t> seen_codes(65536u / 8u, 0);
    for (uint64_t i = 0; i < count; ++i) {
        uint16_t code = 0;
        uint16_t type = 0;
        uint8_t writable = 0;
        uint8_t enabled = 0;
        if (!reader.u16(code) || !reader.u16(type) || !reader.u8(writable) || !reader.u8(enabled)) {
            return SONY2FUJI_STATUS_INVALID_ARGUMENT;
        }
        PropVal def_val;
        PropVal cur_val;
        if (!readPropertyValue(reader, type, def_val) || !readPropertyValue(reader, type, cur_val)) {
            return SONY2FUJI_STATUS_INVALID_ARGUMENT;
        }
        uint8_t form = 0;
        if (!reader.u8(form)) {
            return SONY2FUJI_STATUS_INVALID_ARGUMENT;
        }

        PropertyEntry entry{};
        entry.info.code = code;
        entry.info.type = type;
        entry.info.writable = (writable == 1u) ? 1 : 0;
        entry.info.enabled = enabled;
        entry.info.form = form;
        entry.info.reserved0 = 0;
        entry.info.value_kind = cur_val.kind;
        entry.info.number_value = (cur_val.kind == SONY2FUJI_SONY_PROP_NUMBER) ? cur_val.number : 0;
        if (cur_val.kind == SONY2FUJI_SONY_PROP_TEXT) {
            entry.text_value = std::move(cur_val.text);
        }

        if (form == 1u) {
            PropVal low, high, step;
            if (!readPropertyValue(reader, type, low) ||
                !readPropertyValue(reader, type, high) ||
                !readPropertyValue(reader, type, step)) {
                return SONY2FUJI_STATUS_INVALID_ARGUMENT;
            }
            if (low.kind == SONY2FUJI_SONY_PROP_NUMBER &&
                high.kind == SONY2FUJI_SONY_PROP_NUMBER &&
                step.kind == SONY2FUJI_SONY_PROP_NUMBER) {
                entry.info.has_range = 1;
                entry.info.minimum = low.number;
                entry.info.maximum = high.number;
                entry.info.step = step.number;
            }
        } else if (form == 2u) {
            for (int32_t table = 0; table < enum_tables; ++table) {
                uint16_t table_size = 0;
                if (!reader.u16(table_size)) {
                    return SONY2FUJI_STATUS_INVALID_ARGUMENT;
                }
                if (table_size > 4096u || enum_count + table_size > 65536u) {
                    return SONY2FUJI_STATUS_INVALID_ARGUMENT;
                }
                enum_count += table_size;
                for (uint16_t j = 0; j < table_size; ++j) {
                    PropVal choice;
                    if (!readPropertyValue(reader, type, choice)) {
                        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
                    }
                    if (table == 0 && choice.kind == SONY2FUJI_SONY_PROP_NUMBER) {
                        entry.choices.push_back(choice.number);
                    }
                }
            }
            entry.info.choice_count = static_cast<uint32_t>(entry.choices.size());
        } else if (form != 0u) {
            return SONY2FUJI_STATUS_INVALID_ARGUMENT;
        }

        const size_t byte_idx = code >> 3u;
        const uint8_t bit_mask = static_cast<uint8_t>(1u << (code & 7u));
        if ((seen_codes[byte_idx] & bit_mask) != 0) {
            return SONY2FUJI_STATUS_INVALID_ARGUMENT;
        }
        seen_codes[byte_idx] |= bit_mask;
        out_table.entries.push_back(std::move(entry));
    }
    if (reader.remaining() != 0) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    return SONY2FUJI_STATUS_OK;
}

bool propertyAccepts(
    const sony2fuji_sony_property_info& info,
    const int64_t* choices,
    uint32_t choice_count,
    int64_t value
) noexcept {
    if (info.writable != 1 || info.enabled != 1u) {
        return false;
    }
    switch (info.type) {
        case 3:
            if (value < -32768 || value > 32767) return false;
            break;
        case 4:
            if (value < 0 || value > 65535) return false;
            break;
        case 6:
            if (value < 0 || value > 0xFFFFFFFFLL) return false;
            break;
        default:
            return false;
    }
    if (info.form == 2u) {
        if (choice_count > 0 && !choices) return false;
        for (uint32_t i = 0; i < choice_count; ++i) {
            if (choices[i] == value) return true;
        }
        return false;
    }
    if (info.form == 1u) {
        if (info.has_range != 1 || info.step <= 0 || value < info.minimum || value > info.maximum) {
            return false;
        }
        const uint64_t delta = static_cast<uint64_t>(value) - static_cast<uint64_t>(info.minimum);
        return (delta % static_cast<uint64_t>(info.step)) == 0;
    }
    return false;
}

sony2fuji_status propertyOptions(
    const sony2fuji_sony_property_info& info,
    const int64_t* choices,
    uint32_t choice_count,
    bool only_settable,
    bool sort_unique,
    uint32_t max_range_count,
    std::vector<int64_t>& out_values
) {
    out_values.clear();
    if (choice_count > 0 && !choices) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    if (info.form == 2u) {
        out_values.assign(choices, choices + choice_count);
        if (sort_unique) {
            std::sort(out_values.begin(), out_values.end());
            out_values.erase(std::unique(out_values.begin(), out_values.end()), out_values.end());
        }
        if (only_settable) {
            out_values.erase(
                std::remove_if(out_values.begin(), out_values.end(), [&](int64_t v) {
                    return !propertyAccepts(info, choices, choice_count, v);
                }),
                out_values.end()
            );
        }
        return SONY2FUJI_STATUS_OK;
    }
    if (info.form != 1u || info.has_range != 1 || info.step <= 0 ||
        info.maximum < info.minimum || max_range_count == 0u) {
        return SONY2FUJI_STATUS_OK;
    }
    if (only_settable) {
        if (info.writable != 1 || info.enabled != 1u ||
            (info.type != 3u && info.type != 4u && info.type != 6u) ||
            info.minimum < -32768 || info.maximum > 0xFFFFFFFFLL || info.step > 0xFFFFFFFFLL) {
            return SONY2FUJI_STATUS_OK;
        }
    }
    if (info.minimum < 0 && info.maximum > std::numeric_limits<int64_t>::max() + info.minimum) {
        return SONY2FUJI_STATUS_OK;
    }
    const uint64_t distance = static_cast<uint64_t>(info.maximum) - static_cast<uint64_t>(info.minimum);
    const uint64_t step_u = static_cast<uint64_t>(info.step);
    const uint64_t steps = distance / step_u;
    if (steps >= static_cast<uint64_t>(max_range_count)) {
        return SONY2FUJI_STATUS_OK;
    }
    out_values.reserve(static_cast<size_t>(steps + 1u));
    for (uint64_t i = 0; i <= steps; ++i) {
        const uint64_t raw = static_cast<uint64_t>(info.minimum) + i * step_u;
        int64_t val = 0;
        std::memcpy(&val, &raw, sizeof(val));
        if (!only_settable || propertyAccepts(info, choices, choice_count, val)) {
            out_values.push_back(val);
        }
    }
    return SONY2FUJI_STATUS_OK;
}

void focusIndication(const PropertyTable* table, int32_t& out_locked, int32_t& out_failed) noexcept {
    out_locked = 0;
    out_failed = 0;
    if (!table) return;
    const PropertyEntry* prop = table->find(0xd213u);
    if (!prop || prop->info.value_kind != SONY2FUJI_SONY_PROP_NUMBER) return;
    const int64_t v = prop->info.number_value;
    out_locked = (v == 2 || v == 6) ? 1 : 0;
    out_failed = (v == 3 || v == 7) ? 1 : 0;
}

bool canCancelTouchFocus(
    const PropertyTable* table,
    const uint16_t* controls,
    uint32_t control_count,
    const uint16_t* operations,
    uint32_t operation_count,
    bool remote_ready
) noexcept {
    if (!table || !remote_ready ||
        !containsU16(operations, operation_count, 0x9207u) ||
        !containsU16(controls, control_count, 0xd2e5u)) {
        return false;
    }
    const PropertyEntry* prop = table->find(0xd285u);
    return prop != nullptr &&
           prop->info.enabled == 1u &&
           prop->info.value_kind == SONY2FUJI_SONY_PROP_NUMBER &&
           prop->info.number_value == 1;
}

sony2fuji_status resolveFocusTarget(
    const PropertyTable* table,
    const uint16_t* controls,
    uint32_t control_count,
    const uint16_t* operations,
    uint32_t operation_count,
    bool remote_ready,
    sony2fuji_sony_focus_target& out_target,
    sony2fuji_sony_focus_unavailable_reason& out_reason
) noexcept {
    out_target = SONY2FUJI_SONY_FOCUS_TARGET_NONE;
    out_reason = SONY2FUJI_SONY_FOCUS_UNAVAILABLE_UNSUPPORTED;
    if ((control_count > 0 && !controls) || (operation_count > 0 && !operations)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    if (!table || !remote_ready || !containsU16(operations, operation_count, 0x9207u)) {
        return SONY2FUJI_STATUS_OK;
    }
    if (containsU16(controls, control_count, 0xd2e4u)) {
        const PropertyEntry* touch = table->find(0xd284u);
        if (touch != nullptr &&
            touch->info.enabled == 1u &&
            touch->info.value_kind == SONY2FUJI_SONY_PROP_NUMBER &&
            touch->info.number_value == 1) {
            out_target = SONY2FUJI_SONY_FOCUS_TARGET_REMOTE_TOUCH;
            out_reason = SONY2FUJI_SONY_FOCUS_AVAILABLE;
            return SONY2FUJI_STATUS_OK;
        }
    }
    const PropertyEntry* focus_mode = table->find(0x500au);
    if (focus_mode != nullptr &&
        focus_mode->info.value_kind == SONY2FUJI_SONY_PROP_NUMBER &&
        focus_mode->info.number_value == 1) {
        out_target = SONY2FUJI_SONY_FOCUS_TARGET_NONE;
        out_reason = SONY2FUJI_SONY_FOCUS_UNAVAILABLE_MANUAL_FOCUS;
        return SONY2FUJI_STATUS_OK;
    }
    const PropertyEntry* focus_area = table->find(0xd22cu);
    const bool area_fixed = focus_area != nullptr &&
                            focus_area->info.value_kind == SONY2FUJI_SONY_PROP_NUMBER &&
                            isFixedFocusArea(focus_area->info.number_value);
    if (containsU16(controls, control_count, 0xd2dcu)) {
        if (area_fixed) {
            out_target = SONY2FUJI_SONY_FOCUS_TARGET_NONE;
            out_reason = SONY2FUJI_SONY_FOCUS_UNAVAILABLE_AREA_FIXED;
        } else {
            out_target = SONY2FUJI_SONY_FOCUS_TARGET_AF_AREA_POSITION;
            out_reason = SONY2FUJI_SONY_FOCUS_AVAILABLE;
        }
        return SONY2FUJI_STATUS_OK;
    }
    if (containsU16(controls, control_count, 0xd2e4u) && area_fixed) {
        out_target = SONY2FUJI_SONY_FOCUS_TARGET_NONE;
        out_reason = SONY2FUJI_SONY_FOCUS_UNAVAILABLE_AREA_FIXED;
        return SONY2FUJI_STATUS_OK;
    }
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status parseSlotPhotoCount(const uint8_t* data, size_t len, uint32_t& out_count) noexcept {
    out_count = 0;
    if (len > kSlotDatesLimit || (len > 0 && !data)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    if (len < 4u) {
        out_count = 0;
        return SONY2FUJI_STATUS_OK;
    }
    out_count = readU32LE(data);
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status parseMobilePage(const uint8_t* data, size_t len, MobilePage& out_page) {
    out_page = {};
    if (!data && len > 0) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    Reader reader(data, len);
    if (!reader.skip(144u)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    uint32_t count = 0;
    if (!reader.u32(count) || count > 100u) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    out_page.entry_count = count;
    for (uint32_t i = 0; i < count; ++i) {
        uint32_t ignored_u32 = 0;
        uint32_t content = 0;
        uint64_t created = 0;
        uint32_t marks = 0;
        uint32_t files = 0;
        if (!reader.u32(ignored_u32) || !reader.u32(content) || !reader.skip(20u) ||
            !reader.u64(created) || !reader.skip(36u) ||
            !reader.u32(marks) || marks > (1u << 20) || !reader.skip(marks) ||
            !reader.u32(files) || files > 32u) {
            return SONY2FUJI_STATUS_INVALID_ARGUMENT;
        }
        out_page.cursor = created;
        for (uint32_t f = 0; f < files; ++f) {
            uint32_t file = 0;
            uint32_t path_len = 0;
            if (!reader.u32(file) || !reader.u32(path_len) ||
                file > 65535u || path_len < 1u || path_len > 4096u) {
                return SONY2FUJI_STATUS_INVALID_ARGUMENT;
            }
            const uint8_t* path_bytes = nullptr;
            if (!reader.take(path_len, path_bytes) || path_bytes[path_len - 1u] != 0) {
                return SONY2FUJI_STATUS_INVALID_ARGUMENT;
            }
            const size_t str_len = path_len - 1u;
            if (!isValidUtf8NoNul(path_bytes, str_len)) {
                return SONY2FUJI_STATUS_INVALID_ARGUMENT;
            }
            std::string_view full(reinterpret_cast<const char*>(path_bytes), str_len);
            const size_t slash = full.rfind('/');
            std::string_view name = (slash == std::string_view::npos) ? full : full.substr(slash + 1u);
            if (!isValidPhotoFilename(name)) {
                return SONY2FUJI_STATUS_INVALID_ARGUMENT;
            }
            uint64_t size = 0;
            uint32_t extra = 0;
            uint32_t video = 0;
            uint32_t audio = 0;
            if (!reader.u32(ignored_u32) || !reader.u64(size) || !reader.skip(32u) ||
                !reader.u32(extra)) {
                return SONY2FUJI_STATUS_INVALID_ARGUMENT;
            }
            if (extra != 0u && !reader.skip(8u)) {
                return SONY2FUJI_STATUS_INVALID_ARGUMENT;
            }
            if (!reader.u32(video)) {
                return SONY2FUJI_STATUS_INVALID_ARGUMENT;
            }
            if (video != 0u && !reader.skip(76u)) {
                return SONY2FUJI_STATUS_INVALID_ARGUMENT;
            }
            if (!reader.u32(audio)) {
                return SONY2FUJI_STATUS_INVALID_ARGUMENT;
            }
            if (audio != 0u && !reader.skip(16u)) {
                return SONY2FUJI_STATUS_INVALID_ARGUMENT;
            }
            if (video == 0u && audio == 0u && size > 0u && isPhotoFilename(name)) {
                MobileAsset asset{};
                asset.info.content = content;
                asset.info.file = file;
                asset.info.size = size;
                asset.info.created = created;
                asset.name.assign(name.data(), name.size());
                out_page.assets.push_back(std::move(asset));
            }
        }
    }
    if (reader.remaining() != 0) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status parseLegacyObject(const uint8_t* data, size_t len, LegacyObject& out_obj) {
    out_obj = {};
    if (!data && len > 0) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    Reader reader(data, len);
    uint16_t ignored_u16 = 0;
    uint32_t size32 = 0;
    std::string keywords;
    if (!reader.u32(out_obj.info.storage) ||
        !reader.u16(out_obj.info.format) ||
        !reader.u16(ignored_u16) ||
        !reader.u32(size32) ||
        !reader.skip(40u) ||
        !reader.ptpString(true, out_obj.name) ||
        !reader.ptpString(true, out_obj.created) ||
        !reader.ptpString(true, out_obj.modified) ||
        !reader.ptpString(true, keywords) ||
        reader.remaining() != 0 ||
        !isValidPhotoFilename(out_obj.name)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    out_obj.info.reserved0 = 0;
    out_obj.info.size = static_cast<uint64_t>(size32);
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status parseLiveFrameBounds(
    const uint32_t fields4[4],
    uint64_t max_total_bytes,
    sony2fuji_sony_live_frame_bounds& out_bounds
) noexcept {
    out_bounds = {};
    if (!fields4 || max_total_bytes < 16u) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    const uint64_t image = fields4[0];
    const uint64_t length = fields4[1];
    const uint64_t metadata = fields4[2];
    const uint64_t metadata_length = fields4[3];
    const uint64_t image_end = image + length;
    const uint64_t metadata_end = metadata + metadata_length;
    const uint64_t total = std::max(image_end, metadata_length == 0u ? uint64_t(16u) : metadata_end);
    if (image < 16u || length < 4u || total > max_total_bytes ||
        (metadata_length != 0u && (metadata < 16u || (image < metadata_end && metadata < image_end)))) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    out_bounds.body_size = static_cast<uint32_t>(total - 16u);
    out_bounds.image_offset = static_cast<uint32_t>(image - 16u);
    out_bounds.image_length = static_cast<uint32_t>(length);
    if (metadata_length > 0u) {
        out_bounds.metadata_offset = static_cast<uint32_t>(metadata - 16u);
        out_bounds.metadata_length = static_cast<uint32_t>(metadata_length);
        out_bounds.has_metadata = 1;
    }
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status parseLiveViewFrames(
    const uint8_t* metadata,
    size_t len,
    std::vector<sony2fuji_sony_live_view_frame>& out_frames
) {
    out_frames.clear();
    if (len > 0 && !metadata) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    if (len < 0x28u) {
        return SONY2FUJI_STATUS_OK;
    }
    const uint16_t version = readU16LE(metadata);
    if (version <= 0x27u) {
        return SONY2FUJI_STATUS_OK;
    }
    size_t offset = 0x28u;
    auto readBlock = [&](bool emit, sony2fuji_sony_live_view_frame_kind kind) -> bool {
        if (offset + 16u > len) return false;
        const uint32_t x_max = readU32LE(metadata + offset);
        const uint32_t y_max = readU32LE(metadata + offset + 4u);
        const uint16_t count = readU16LE(metadata + offset + 8u);
        offset += 16u;
        if (count > 128u || static_cast<size_t>(count) * 24u > len - offset) {
            return false;
        }
        for (uint16_t i = 0; i < count; ++i) {
            const uint16_t type = readU16LE(metadata + offset);
            const uint16_t state = readU16LE(metadata + offset + 2u);
            const uint32_t cx = readU32LE(metadata + offset + 8u);
            const uint32_t cy = readU32LE(metadata + offset + 12u);
            const uint32_t h = readU32LE(metadata + offset + 16u);
            const uint32_t w = readU32LE(metadata + offset + 20u);
            offset += 24u;
            if (emit && x_max > 0u && y_max > 0u && w > 0u && h > 0u &&
                w <= x_max && h <= y_max && cx <= x_max && cy <= y_max) {
                sony2fuji_sony_live_view_frame frame{};
                frame.kind = kind;
                if (kind == SONY2FUJI_SONY_LIVE_FRAME_FACE) {
                    frame.focused = (type == 2u) ? 1 : 0;
                } else {
                    frame.focused = (state == 2u) ? 1 : 0;
                }
                frame.cx = static_cast<double>(cx) / static_cast<double>(x_max);
                frame.cy = static_cast<double>(cy) / static_cast<double>(y_max);
                frame.width = static_cast<double>(w) / static_cast<double>(x_max);
                frame.height = static_cast<double>(h) / static_cast<double>(y_max);
                out_frames.push_back(frame);
            }
        }
        return true;
    };

    if (!readBlock(false, SONY2FUJI_SONY_LIVE_FRAME_FOCUS) ||
        !readBlock(true, SONY2FUJI_SONY_LIVE_FRAME_FOCUS)) {
        out_frames.clear();
        return SONY2FUJI_STATUS_OK;
    }
    if (version > 0x64u) {
        if (!readBlock(true, SONY2FUJI_SONY_LIVE_FRAME_FACE) ||
            !readBlock(true, SONY2FUJI_SONY_LIVE_FRAME_TRACKING)) {
            out_frames.clear();
            return SONY2FUJI_STATUS_OK;
        }
    }
    return SONY2FUJI_STATUS_OK;
}

bool focusPointFromTap(
    double tap_x,
    double tap_y,
    double container_width,
    double container_height,
    double image_width,
    double image_height,
    sony2fuji_sony_focus_tap_point& out_tap
) noexcept {
    out_tap = {};
    if (!std::isfinite(tap_x) || !std::isfinite(tap_y) ||
        !std::isfinite(container_width) || !std::isfinite(container_height) ||
        !std::isfinite(image_width) || !std::isfinite(image_height) ||
        container_width <= 0.0 || container_height <= 0.0 ||
        image_width <= 0.0 || image_height <= 0.0) {
        return false;
    }
    const double scale = std::min(container_width / image_width, container_height / image_height);
    const double fitted_w = image_width * scale;
    const double fitted_h = image_height * scale;
    const double left = (container_width - fitted_w) / 2.0;
    const double top = (container_height - fitted_h) / 2.0;
    if (tap_x < left || tap_x > left + fitted_w || tap_y < top || tap_y > top + fitted_h) {
        return false;
    }
    const double u = std::clamp((tap_x - left) / fitted_w, 0.0, 1.0);
    const double v = std::clamp((tap_y - top) / fitted_h, 0.0, 1.0);
    const int32_t x = std::clamp(static_cast<int32_t>(std::llround(u * 640.0)), int32_t(0), int32_t(639));
    const int32_t y = std::clamp(static_cast<int32_t>(std::llround(v * 480.0)), int32_t(0), int32_t(479));
    out_tap.u = u;
    out_tap.v = v;
    out_tap.x = x;
    out_tap.y = y;
    out_tap.packed = (static_cast<uint32_t>(x) << 16u) | static_cast<uint32_t>(y);
    out_tap.reserved0 = 0;
    return true;
}

sony2fuji_status focusOverlayBox(
    const sony2fuji_sony_live_view_frame& frame,
    double left,
    double top,
    double fitted_width,
    double fitted_height,
    sony2fuji_sony_focus_overlay_box& out_box
) noexcept {
    out_box = {};
    if (!std::isfinite(left) || !std::isfinite(top) ||
        !std::isfinite(fitted_width) || !std::isfinite(fitted_height) ||
        !std::isfinite(frame.cx) || !std::isfinite(frame.cy) ||
        !std::isfinite(frame.width) || !std::isfinite(frame.height) ||
        fitted_width < 0.0 || fitted_height < 0.0) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    const double raw_w = frame.width * fitted_width;
    const double raw_h = frame.height * fitted_height;
    const double cx = left + frame.cx * fitted_width;
    const double cy = top + frame.cy * fitted_height;
    out_box.focused = frame.focused != 0 ? 1 : 0;
    if (frame.kind != SONY2FUJI_SONY_LIVE_FRAME_FACE && raw_w > 0.0 && raw_h > 0.0) {
        const double aspect = std::max(raw_w, raw_h) / std::min(raw_w, raw_h);
        if (aspect <= 1.35) {
            const double side = (raw_w + raw_h) / 2.0;
            out_box.x = cx - side / 2.0;
            out_box.y = cy - side / 2.0;
            out_box.width = side;
            out_box.height = side;
            out_box.is_normalized_square = 1;
            return SONY2FUJI_STATUS_OK;
        }
    }
    out_box.x = cx - raw_w / 2.0;
    out_box.y = cy - raw_h / 2.0;
    out_box.width = raw_w;
    out_box.height = raw_h;
    out_box.is_normalized_square = 0;
    return SONY2FUJI_STATUS_OK;
}

bool normalizedFocusSquareRatio(
    const sony2fuji_sony_live_view_frame& frame,
    double image_width,
    double image_height,
    double& out_ratio
) noexcept {
    out_ratio = 0.0;
    if (frame.kind == SONY2FUJI_SONY_LIVE_FRAME_FACE ||
        !std::isfinite(image_width) || !std::isfinite(image_height) ||
        !std::isfinite(frame.width) || !std::isfinite(frame.height) ||
        image_width <= 0.0 || image_height <= 0.0) {
        return false;
    }
    const double short_edge = std::min(image_width, image_height);
    const double w = frame.width * (image_width / short_edge);
    const double h = frame.height * (image_height / short_edge);
    if (w <= 0.0 || h <= 0.0 || (std::max(w, h) / std::min(w, h)) > 1.35) {
        return false;
    }
    out_ratio = (w + h) / 2.0;
    return true;
}

sony2fuji_status tapFocusSide(
    double fitted_width,
    double fitted_height,
    double min_default_px,
    double max_default_px,
    double min_learned_px,
    bool has_last_ratio,
    double last_ratio,
    double& out_side
) noexcept {
    out_side = 0.0;
    if (!std::isfinite(min_default_px) || !std::isfinite(max_default_px) || !std::isfinite(min_learned_px)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    const double short_edge = std::min(fitted_width, fitted_height);
    if (!std::isfinite(fitted_width) || !std::isfinite(fitted_height) ||
        !std::isfinite(short_edge) || short_edge <= 0.0) {
        out_side = min_default_px;
        return SONY2FUJI_STATUS_OK;
    }
    if (has_last_ratio && std::isfinite(last_ratio) && last_ratio > 0.0) {
        out_side = std::min(std::max(min_learned_px, short_edge * last_ratio),
                            std::max(min_learned_px, short_edge * 0.5));
        return SONY2FUJI_STATUS_OK;
    }
    out_side = std::min(std::max(min_default_px, max_default_px),
                        std::max(min_default_px, short_edge * 0.138));
    return SONY2FUJI_STATUS_OK;
}

bool isValidFocusState(const sony2fuji_sony_focus_state* state) noexcept {
    return state != nullptr &&
           state->version == SONY2FUJI_SONY_FOCUS_STATE_VERSION &&
           state->struct_size == sizeof(sony2fuji_sony_focus_state);
}

sony2fuji_status focusStateInit(sony2fuji_sony_focus_state& state) noexcept {
    state = {};
    state.version = SONY2FUJI_SONY_FOCUS_STATE_VERSION;
    state.struct_size = sizeof(sony2fuji_sony_focus_state);
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status focusStateReset(sony2fuji_sony_focus_state& state, bool preserve_last_ratio) noexcept {
    if (!isValidFocusState(&state)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    const uint64_t next_gen = state.tap_generation + 1u;
    const int32_t keep_has_ratio = preserve_last_ratio ? state.has_last_square_ratio : 0;
    const double keep_ratio = preserve_last_ratio ? state.last_square_ratio : 0.0;
    state = {};
    state.version = SONY2FUJI_SONY_FOCUS_STATE_VERSION;
    state.struct_size = sizeof(sony2fuji_sony_focus_state);
    state.tap_generation = next_gen;
    state.has_last_square_ratio = keep_has_ratio;
    state.last_square_ratio = keep_ratio;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status focusStateOnTap(
    sony2fuji_sony_focus_state& state,
    double u,
    double v,
    int32_t x,
    int32_t y,
    uint64_t /*now_ms*/
) noexcept {
    if (!isValidFocusState(&state) ||
        !std::isfinite(u) || !std::isfinite(v) ||
        u < 0.0 || u > 1.0 || v < 0.0 || v > 1.0 ||
        x < 0 || x > 639 || y < 0 || y > 479) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    state.focus_busy = 1;
    state.tap_active = 1;
    state.tap_generation += 1u;
    state.tap_u = u;
    state.tap_v = v;
    state.tap_x = x;
    state.tap_y = y;
    state.tap_deadline_ms = 0;
    state.has_pending_deadline = 0;
    state.tap_focus_locked = 0;
    state.has_live_frames = 0;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status focusStateOnCancelStart(sony2fuji_sony_focus_state& state) noexcept {
    if (!isValidFocusState(&state)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    state.focus_busy = 1;
    state.tap_active = 0;
    state.tap_generation += 1u;
    state.tap_deadline_ms = 0;
    state.has_pending_deadline = 0;
    state.tap_focus_locked = 0;
    state.has_live_frames = 0;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status focusStateOnFocusFinished(
    sony2fuji_sony_focus_state& state,
    bool succeeded,
    bool focus_locked,
    uint64_t now_ms
) noexcept {
    if (!isValidFocusState(&state)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    state.focus_busy = 0;
    if (succeeded) {
        state.tap_focus_locked = focus_locked ? 1 : 0;
        if (state.tap_active != 0 && state.has_live_frames == 0) {
            state.has_pending_deadline = 1;
            state.tap_deadline_ms = (now_ms > std::numeric_limits<uint64_t>::max() - kTapFocusTimeoutMs)
                                        ? std::numeric_limits<uint64_t>::max()
                                        : (now_ms + kTapFocusTimeoutMs);
        } else {
            state.has_pending_deadline = 0;
            state.tap_deadline_ms = 0;
        }
    } else {
        state.tap_focus_locked = 0;
        state.tap_active = 0;
        state.has_pending_deadline = 0;
        state.tap_deadline_ms = 0;
    }
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status focusStateOnLiveFrame(
    sony2fuji_sony_focus_state& state,
    const sony2fuji_sony_live_view_frame* frames,
    uint32_t frame_count,
    double image_width,
    double image_height
) noexcept {
    if (!isValidFocusState(&state) || (frame_count > 0u && !frames)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    if (state.focus_busy != 0) {
        state.has_live_frames = 0;
        return SONY2FUJI_STATUS_OK;
    }
    state.has_live_frames = (frame_count > 0u) ? 1 : 0;
    if (frame_count > 0u) {
        state.tap_active = 0;
        state.has_pending_deadline = 0;
        state.tap_deadline_ms = 0;

        uint32_t non_face_count = 0;
        const sony2fuji_sony_live_view_frame* single_non_face = nullptr;
        for (uint32_t i = 0; i < frame_count; ++i) {
            if (frames[i].kind != SONY2FUJI_SONY_LIVE_FRAME_FACE) {
                ++non_face_count;
                single_non_face = &frames[i];
            }
        }
        double ratio = 0.0;
        if (non_face_count == 1u &&
            normalizedFocusSquareRatio(*single_non_face, image_width, image_height, ratio)) {
            state.has_last_square_ratio = 1;
            state.last_square_ratio = ratio;
        }
    }
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status focusStateOnProperties(
    sony2fuji_sony_focus_state& state,
    bool can_cancel_touch_focus,
    bool props_focus_locked,
    bool props_focus_failed
) noexcept {
    if (!isValidFocusState(&state)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    const int32_t had_cancel = state.can_cancel_touch_focus;
    state.can_cancel_touch_focus = can_cancel_touch_focus ? 1 : 0;
    state.props_focus_locked = props_focus_locked ? 1 : 0;
    if (props_focus_failed || (had_cancel != 0 && state.can_cancel_touch_focus == 0)) {
        state.tap_focus_locked = 0;
    }
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status focusStateOnCaptureOrParamStart(sony2fuji_sony_focus_state& state) noexcept {
    if (!isValidFocusState(&state)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    state.tap_focus_locked = 0;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status focusStateOnLiveChanged(sony2fuji_sony_focus_state& state, bool live_active) noexcept {
    if (!isValidFocusState(&state)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    if (!live_active) {
        state.tap_active = 0;
        state.has_pending_deadline = 0;
        state.tap_deadline_ms = 0;
        state.has_live_frames = 0;
    }
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status focusStateOnTick(sony2fuji_sony_focus_state& state, uint64_t now_ms) noexcept {
    if (!isValidFocusState(&state)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    if (state.focus_busy == 0 &&
        state.tap_active != 0 &&
        state.has_pending_deadline != 0 &&
        now_ms >= state.tap_deadline_ms) {
        state.tap_active = 0;
        state.has_pending_deadline = 0;
        state.tap_deadline_ms = 0;
    }
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status focusStateOnTimeout(
    sony2fuji_sony_focus_state& state,
    uint64_t generation,
    uint64_t now_ms
) noexcept {
    if (!isValidFocusState(&state)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    if (generation == state.tap_generation) {
        return focusStateOnTick(state, now_ms);
    }
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status focusStateResolveRender(
    const sony2fuji_sony_focus_state& state,
    double left,
    double top,
    double fitted_width,
    double fitted_height,
    double min_default_px,
    double max_default_px,
    double min_learned_px,
    sony2fuji_sony_focus_render_decision& out_decision
) noexcept {
    out_decision = {};
    if (!isValidFocusState(&state) ||
        !std::isfinite(left) || !std::isfinite(top) ||
        !std::isfinite(fitted_width) || !std::isfinite(fitted_height) ||
        fitted_width < 0.0 || fitted_height < 0.0) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    const int32_t effective_locked =
        (state.focus_busy == 0 && (state.tap_focus_locked != 0 || state.props_focus_locked != 0)) ? 1 : 0;
    out_decision.effective_focus_locked = effective_locked;

    if (state.focus_busy == 0 && state.has_live_frames != 0) {
        out_decision.mode = SONY2FUJI_SONY_FOCUS_RENDER_LIVE_FRAMES;
        return SONY2FUJI_STATUS_OK;
    }
    if (state.tap_active != 0) {
        double side = 0.0;
        const sony2fuji_status st = tapFocusSide(
            fitted_width,
            fitted_height,
            min_default_px,
            max_default_px,
            min_learned_px,
            state.has_last_square_ratio != 0,
            state.last_square_ratio,
            side
        );
        if (st != SONY2FUJI_STATUS_OK) {
            return st;
        }
        const double cx = left + state.tap_u * fitted_width;
        const double cy = top + state.tap_v * fitted_height;
        out_decision.mode = SONY2FUJI_SONY_FOCUS_RENDER_TAP_RETICLE;
        out_decision.tap_box.x = cx - side / 2.0;
        out_decision.tap_box.y = cy - side / 2.0;
        out_decision.tap_box.width = side;
        out_decision.tap_box.height = side;
        out_decision.tap_box.is_normalized_square = 1;
        out_decision.tap_box.focused = effective_locked;
        return SONY2FUJI_STATUS_OK;
    }
    out_decision.mode = SONY2FUJI_SONY_FOCUS_RENDER_NONE;
    return SONY2FUJI_STATUS_OK;
}

} // namespace sony2fuji::sony
