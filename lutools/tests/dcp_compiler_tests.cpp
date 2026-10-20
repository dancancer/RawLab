#include "sony2fuji/ffi/sony2fuji_c.h"

#include <algorithm>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <limits>
#include <string>
#include <utility>
#include <vector>

namespace {

using Bytes = std::vector<uint8_t>;

void appendInteger(Bytes& bytes, uint64_t value, size_t width, bool bigEndian = false) {
    for (size_t i = 0; i < width; ++i) {
        const size_t shift = (bigEndian ? width - 1 - i : i) * 8;
        bytes.push_back(static_cast<uint8_t>(value >> shift));
    }
}

void appendFloat(Bytes& bytes, float value, bool bigEndian = false) {
    uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    appendInteger(bytes, bits, 4, bigEndian);
}

void appendRational(Bytes& bytes, int32_t numerator, int32_t denominator, bool bigEndian = false) {
    appendInteger(bytes, static_cast<uint32_t>(numerator), 4, bigEndian);
    appendInteger(bytes, static_cast<uint32_t>(denominator), 4, bigEndian);
}

struct Tag {
    uint16_t kind;
    Bytes data;
};

Bytes makeDcp(const std::vector<std::pair<uint16_t, Tag>>& supplied, bool bigEndian = false) {
    std::vector<std::pair<uint16_t, Tag>> tags = supplied;
    std::sort(tags.begin(), tags.end(), [](const auto& left, const auto& right) { return left.first < right.first; });
    const uint32_t payloadStart = 8 + 2 + static_cast<uint32_t>(tags.size()) * 12 + 4;
    Bytes entries, payload;
    for (const auto& [key, tag] : tags) {
        appendInteger(entries, key, 2, bigEndian);
        appendInteger(entries, tag.kind, 2, bigEndian);
        appendInteger(entries, tag.data.size() / (tag.kind == 10 ? 8 : tag.kind == 11 ? 4 : tag.kind == 4 ? 4 : tag.kind == 3 ? 2 : 1), 4, bigEndian);
        if (tag.data.size() <= 4) {
            entries.insert(entries.end(), tag.data.begin(), tag.data.end());
            entries.insert(entries.end(), 4 - tag.data.size(), 0);
        } else {
            appendInteger(entries, payloadStart + payload.size(), 4, bigEndian);
            payload.insert(payload.end(), tag.data.begin(), tag.data.end());
        }
    }
    Bytes result;
    result.push_back(bigEndian ? 'M' : 'I');
    result.push_back(bigEndian ? 'M' : 'I');
    appendInteger(result, 0x4352, 2, bigEndian);
    appendInteger(result, 8, 4, bigEndian);
    appendInteger(result, tags.size(), 2, bigEndian);
    result.insert(result.end(), entries.begin(), entries.end());
    appendInteger(result, 0, 4, bigEndian);
    result.insert(result.end(), payload.begin(), payload.end());
    return result;
}

Tag type3(std::initializer_list<uint16_t> values, bool bigEndian = false) {
    Tag tag{3, {}};
    for (uint16_t value : values) appendInteger(tag.data, value, 2, bigEndian);
    return tag;
}

Tag type4(std::initializer_list<uint32_t> values, bool bigEndian = false) {
    Tag tag{4, {}};
    for (uint32_t value : values) appendInteger(tag.data, value, 4, bigEndian);
    return tag;
}

Tag type10(std::initializer_list<std::pair<int32_t, int32_t>> values, bool bigEndian = false) {
    Tag tag{10, {}};
    for (const auto& [numerator, denominator] : values) appendRational(tag.data, numerator, denominator, bigEndian);
    return tag;
}

Tag type11(std::initializer_list<float> values, bool bigEndian = false) {
    Tag tag{11, {}};
    for (float value : values) appendFloat(tag.data, value, bigEndian);
    return tag;
}

std::vector<std::pair<uint16_t, Tag>> validTags(bool bigEndian = false) {
    std::vector<std::pair<uint16_t, Tag>> tags = {
        {50708, {2, Bytes{'S', 'y', 'n', 't', 'h', 'e', 't', 'i', 'c', ' ', 'C', 'a', 'm', 'e', 'r', 'a', 0}}},
        {50779, type3({21}, bigEndian)},
        {50936, {2, Bytes{'S', 'y', 'n', 't', 'h', 'e', 't', 'i', 'c', ' ', 'L', 'o', 'o', 'k', 0}}},
        {50940, type11({0, 0, 1, 1}, bigEndian)},
        {50965, type10({{7976749, 10000000}, {1351917, 10000000}, {313534, 10000000},
                        {2880402, 10000000}, {7118741, 10000000}, {857, 10000000},
                        {0, 1}, {0, 1}, {8252100, 10000000}}, bigEndian)},
        {50981, type4({2, 2, 2}, bigEndian)},
        {50982, type11({0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1, 1,
                        0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 1, 1}, bigEndian)},
        {51110, type4({1}, bigEndian)},
    };
    // The synthetic profile uses an identity ColorMatrix and a ProPhoto
    // ForwardMatrix, both represented as DCP signed rationals.
    tags.push_back({50722, type10({{1, 1}, {0, 1}, {0, 1}, {0, 1}, {1, 1}, {0, 1},
                                     {0, 1}, {0, 1}, {1, 1}}, bigEndian)});
    return tags;
}

Bytes validDcp(bool bigEndian = false) { return makeDcp(validTags(bigEndian), bigEndian); }

Bytes overlappingRationals() {
    auto tags = validTags();
    Tag payload{10, {}};
    for (int index = 0; index < 1000; ++index) appendRational(payload.data, 1, 1);
    tags.push_back({60000, payload});
    tags.push_back({60001, payload});
    auto result = makeDcp(tags);
    auto read32 = [&](size_t offset) {
        return uint32_t(result[offset]) | (uint32_t(result[offset + 1]) << 8) |
               (uint32_t(result[offset + 2]) << 16) | (uint32_t(result[offset + 3]) << 24);
    };
    uint32_t firstOffset = 0, secondOffset = 0;
    const uint16_t count = uint16_t(result[8]) | (uint16_t(result[9]) << 8);
    for (uint16_t index = 0; index < count; ++index) {
        const size_t base = 10 + static_cast<size_t>(index) * 12;
        const uint16_t key = uint16_t(result[base]) | (uint16_t(result[base + 1]) << 8);
        if (key == 60000) firstOffset = read32(base + 8);
        if (key == 60001) {
            secondOffset = read32(base + 8);
            for (int byte = 0; byte < 4; ++byte) result[base + 8 + byte] = uint8_t(firstOffset >> (byte * 8));
        }
    }
    result.erase(result.begin() + secondOffset, result.end());
    return result;
}

bool compile(const Bytes& bytes, const char* name, sony2fuji_blob& blob, sony2fuji_dcp_error& reason) {
    return sony2fuji_compile_dcp(bytes.data(), bytes.size(), name, &blob, &reason) == SONY2FUJI_STATUS_OK;
}

void expect(bool condition, const char* message) {
    if (!condition) {
        std::cerr << "FAIL " << message << '\n';
        std::exit(1);
    }
}

void unitTests() {
    for (bool bigEndian : {false, true}) {
        sony2fuji_blob blob{};
        sony2fuji_dcp_error reason = SONY2FUJI_DCP_ERROR_MALFORMED;
        const auto bytes = validDcp(bigEndian);
        expect(compile(bytes, "synthetic.dcp", blob, reason), "valid DCP compiles");
        expect(reason == SONY2FUJI_DCP_ERROR_NONE && blob.data && blob.size_bytes > 40, "valid result owns a blob");
        expect(std::memcmp(blob.data, "RLOOKDCP", 8) == 0, "RLOOK magic is serialized");
        sony2fuji_release_blob(&blob);
        expect(blob.data == nullptr && blob.size_bytes == 0, "release clears blob ownership");
    }

    sony2fuji_blob blob{};
    sony2fuji_dcp_error reason = SONY2FUJI_DCP_ERROR_NONE;
    const auto valid = validDcp();
    expect(compile(valid, "kept.dcp", blob, reason), "seed previous blob");
    expect(sony2fuji_compile_dcp(nullptr, 0, "kept.dcp", &blob, &reason) == SONY2FUJI_STATUS_UNSUPPORTED &&
               reason == SONY2FUJI_DCP_ERROR_MALFORMED && blob.data == nullptr && blob.size_bytes == 0,
           "malformed input clears previous blob");

    expect(sony2fuji_compile_dcp(valid.data(), valid.size(), "dir/name.dcp", &blob, &reason) ==
               SONY2FUJI_STATUS_INVALID_ARGUMENT,
           "path-like source names are invalid arguments");
    const std::string portableName = "look:day\\\xF0\x9F\x94\xA5.dcp";
    expect(compile(valid, portableName.c_str(), blob, reason),
           "UTF-8 filenames retain legal colon and backslash characters");
    sony2fuji_release_blob(&blob);
    const std::string invalidUtf8("bad\xFF.dcp", 8);
    expect(sony2fuji_compile_dcp(valid.data(), valid.size(), invalidUtf8.c_str(), &blob, &reason) ==
               SONY2FUJI_STATUS_INVALID_ARGUMENT,
           "invalid UTF-8 source names are invalid arguments");
    expect(sony2fuji_compile_dcp(valid.data(), valid.size(), nullptr, &blob, &reason) ==
               SONY2FUJI_STATUS_INVALID_ARGUMENT,
           "missing source name is invalid arguments");
    expect(sony2fuji_compile_dcp(valid.data(), 128u * 1024u * 1024u + 1, "large.dcp", &blob, &reason) ==
               SONY2FUJI_STATUS_UNSUPPORTED && reason == SONY2FUJI_DCP_ERROR_TOO_LARGE,
           "source size bound is enforced before parsing");

    const auto overlapping = overlappingRationals();
    expect(sony2fuji_compile_dcp(overlapping.data(), overlapping.size(), "overlap.dcp", &blob, &reason) ==
               SONY2FUJI_STATUS_UNSUPPORTED && reason == SONY2FUJI_DCP_ERROR_TOO_LARGE,
           "overlapping rational payloads consume one bounded parser budget");

    auto omittedTags = validTags();
    for (auto& [key, tag] : omittedTags) {
        if (key == 50981) tag = type4({2, 3, 2});
    }
    const auto omittedBytes = makeDcp(omittedTags);
    expect(compile(omittedBytes, "omitted.dcp", blob, reason),
           "omitted zero-saturation table entries are normalized safely");
    sony2fuji_release_blob(&blob);

    auto singular = validTags();
    for (auto& [key, tag] : singular) {
        if (key == 50722) {
            tag = type10({{1, 1}, {1, 1}, {0, 1}, {50000001, 50000000}, {50000002, 50000001},
                           {0, 1}, {0, 1}, {0, 1}, {1, 1}});
        }
    }
    const auto singularBytes = makeDcp(singular);
    const auto singularStatus = sony2fuji_compile_dcp(singularBytes.data(), singularBytes.size(), "singular.dcp", &blob, &reason);
    expect(singularStatus == SONY2FUJI_STATUS_UNSUPPORTED && reason == SONY2FUJI_DCP_ERROR_INVALID_CALIBRATION,
           "near singular calibration is rejected");
    sony2fuji_release_blob(&blob);
}

int commandLine(const std::string& sourcePath, const std::string& outputPath) {
    const auto source = std::filesystem::u8path(sourcePath);
    const auto destination = std::filesystem::u8path(outputPath);
    std::ifstream input(source, std::ios::binary);
    if (!input) return 2;
    Bytes bytes((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
    sony2fuji_blob blob{};
    sony2fuji_dcp_error reason = SONY2FUJI_DCP_ERROR_NONE;
    const std::string sourceName = source.filename().u8string();
    const auto status = sony2fuji_compile_dcp(bytes.data(), bytes.size(), sourceName.c_str(), &blob, &reason);
    if (status != SONY2FUJI_STATUS_OK) {
        std::cerr << "DCP compile failed status=" << static_cast<int>(status) << " reason=" << static_cast<int>(reason) << '\n';
        return 2;
    }
    std::ofstream output(destination, std::ios::binary);
    if (!output) {
        sony2fuji_release_blob(&blob);
        return 2;
    }
    output.write(static_cast<const char*>(blob.data), static_cast<std::streamsize>(blob.size_bytes));
    sony2fuji_release_blob(&blob);
    return output ? 0 : 2;
}

} // namespace

int runMain(int argc, const std::vector<std::string>& arguments) {
    if (argc == 3) return commandLine(arguments[1], arguments[2]);
    if (argc != 1) return 2;
    unitTests();
    std::cout << "PASS dcp_compiler" << std::endl;
    return 0;
}

#ifdef _WIN32
#include <windows.h>
std::string utf8(const wchar_t* value) {
    const int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1, nullptr, 0, nullptr, nullptr);
    if (length <= 0) return {};
    std::string result(static_cast<size_t>(length), '\0');
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1, result.data(), length, nullptr, nullptr) <= 0)
        return {};
    result.resize(static_cast<size_t>(length - 1));
    return result;
}

int wmain(int argc, wchar_t** argv) {
    std::vector<std::string> arguments;
    arguments.reserve(argc);
    for (int index = 0; index < argc; ++index) {
        arguments.push_back(utf8(argv[index]));
        if (arguments.back().empty() && argv[index][0] != L'\0') return 2;
    }
    return runMain(argc, arguments);
}
#else
int main(int argc, char** argv) {
    std::vector<std::string> arguments;
    arguments.reserve(argc);
    for (int index = 0; index < argc; ++index) arguments.emplace_back(argv[index]);
    return runMain(argc, arguments);
}
#endif
