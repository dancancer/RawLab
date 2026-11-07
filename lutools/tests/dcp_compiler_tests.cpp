#include "sony2fuji/ffi/sony2fuji_c.h"
#include "sony2fuji/ffi/sony2fuji_hdr.h"
#include "sony2fuji/dcp_compiler.h"

#include <algorithm>
#include <chrono>
#include <cmath>
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

void hdrCameraCalibrationTests(const char* source, const char* cameraModel, bool syntheticFixture) {
    auto makeProfile = [&](bool shifted, const std::string& model, bool bigEndian = false, bool shiftedWhite = false) {
        auto tags = validTags(bigEndian);
        for (auto& [key, tag] : tags) {
            if (key == 50708) {
                tag = {2, Bytes(model.begin(), model.end())};
                tag.data.push_back(0);
            }
            if (key == 50965) {
                // sRGB-to-XYZ(D50), alone or after R' = 4R - 3G.
                tag = shifted
                    ? type10({{17442988,10000000}, {-9231592,10000000}, {1430804,10000000},
                              {8900180,10000000}, {493651,10000000}, {606169,10000000},
                              {557288,10000000}, {553079,10000000}, {7141733,10000000}}, bigEndian)
                    : type10({{4360747,10000000}, {3850649,10000000}, {1430804,10000000},
                              {2225045,10000000}, {7168786,10000000}, {606169,10000000},
                              {139322,10000000}, {971045,10000000}, {7141733,10000000}}, bigEndian);
            }
            if (shifted && key == 50940) tag = type11({0, 0, .5f, .2f, 1, 1}, bigEndian);
            if (shiftedWhite && key == 50722)
                tag = type10({{1,1}, {1,1}, {0,1}, {0,1}, {1,1}, {0,1}, {0,1}, {0,1}, {1,1}}, bigEndian);
        }
        return makeDcp(tags, bigEndian);
    };
    const auto directory = std::filesystem::temp_directory_path() / ("rawlab-hdr-dcp-" +
        std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    expect(std::filesystem::create_directory(directory), "create HDR profile test directory");
    struct Cleanup {
        std::filesystem::path path;
        ~Cleanup() { std::error_code error; std::filesystem::remove_all(path, error); }
    } cleanup{directory};
    auto write = [&](const char* name, const void* data, size_t size) {
        const auto file = directory / name;
        std::ofstream out(file, std::ios::binary);
        expect(bool(out.write(static_cast<const char*>(data), static_cast<std::streamsize>(size))),
               "write HDR profile fixture");
        return file.u8string();
    };
    const auto unshifted = makeProfile(false, cameraModel);
    const auto shifted = makeProfile(true, cameraModel, true);
    const auto wrong = makeProfile(true, "Different camera");
    auto tiff = unshifted;
    tiff[2] = 42;
    tiff[3] = 0;
    expect(!sony2fuji::readHDRCameraProfile(tiff.data(), tiff.size()), "a TIFF header was treated as a standalone DCP");
    const auto plainFile = write("linear.dcp", unshifted.data(), unshifted.size());
    const auto shiftedFile = write("shifted.dcp", shifted.data(), shifted.size());
    const auto wrongFile = write("mismatched.dcp", wrong.data(), wrong.size());

    auto linear = sony2fuji::readHDRCameraProfile(shifted.data(), shifted.size());
    expect(linear.has_value(), "read fixed D65 ForwardMatrix");
    const auto& matrix = linear->balancedToSrgb;
    for (const float grey : {-.125f, .1845f, .9999f, 1.0f, 1.0001f, 4.0f, 8.0f}) {
        for (const auto& row : matrix)
            expect(std::abs((row[0] + row[1] + row[2]) * grey - grey) < 2e-5f,
                   "DCP linear matrix moved the neutral axis");
    }
    expect(std::abs(matrix[0][0] - 4) < 2e-5f && std::abs(matrix[0][1] + 3) < 2e-5f &&
           std::abs(matrix[1][1] - 1) < 2e-5f, "D50 ForwardMatrix was not converted to D65 linear sRGB");

    sony2fuji_blob blob{};
    sony2fuji_dcp_error reason{};
    expect(sony2fuji_compile_hdr_camera_dcp(shifted.data(), shifted.size(), &blob, &reason) == SONY2FUJI_STATUS_OK &&
           blob.size_bytes > 8 && std::memcmp(blob.data, "RLOOKHDR", 8) == 0, "compile matrix-only HDR resource");
    const auto compiledFile = write("shifted.rlook", blob.data, blob.size_bytes);
    const auto truncatedFile = write("truncated.rlook", blob.data, blob.size_bytes - 1);
    auto* bytes = static_cast<uint8_t*>(blob.data);
    bytes[8] = 2;
    const auto futureFile = write("future.rlook", blob.data, blob.size_bytes);
    sony2fuji_release_blob(&blob);
    expect(sony2fuji_compile_dcp(shifted.data(), shifted.size(), "shifted.dcp", &blob, &reason) == SONY2FUJI_STATUS_OK,
           "the same source can still compile its independent SDR stages");
    const auto legacyFile = write("legacy.rlook", blob.data, blob.size_bytes);
    sony2fuji_release_blob(&blob);

    auto tags = validTags();
    for (auto& [key, tag] : tags) {
        if (key == 50965)
            tag = type10({{1,1}, {0,1}, {0,1}, {1,1}, {0,1}, {0,1}, {1,1}, {0,1}, {0,1}});
    }
    const auto singular = makeDcp(tags);
    expect(sony2fuji_compile_hdr_camera_dcp(singular.data(), singular.size(), &blob, &reason) ==
           SONY2FUJI_STATUS_UNSUPPORTED && reason == SONY2FUJI_DCP_ERROR_INVALID_CALIBRATION && !blob.data,
           "a singular ForwardMatrix was accepted");

    auto info = sony2fuji_hdr_camera_profile_info_v1{1, sizeof(sony2fuji_hdr_camera_profile_info_v1)};
    auto diagnostic = sony2fuji_hdr_diagnostic_v1{1, sizeof(sony2fuji_hdr_diagnostic_v1)};
    auto options = sony2fuji_hdr_decode_options_v1{1, sizeof(sony2fuji_hdr_decode_options_v1),
        SONY2FUJI_INTENT_FINAL, 0};
    sony2fuji_hdr_camera_development_v2 development{};
    development.base.version = 2;
    development.base.struct_size = sizeof(development);
    auto configure = [&](const std::string& file) {
        expect(sony2fuji_hdr_probe_camera_profile(file.c_str(), &info, &diagnostic) == SONY2FUJI_STATUS_OK,
               "probe supported HDR camera profile");
        development.profile_path = file.c_str();
        std::copy_n(info.sha256, 65, development.profile_sha256);
    };
    struct Pair {
        sony2fuji_hdr_image_pair_v1 value{1, sizeof(sony2fuji_hdr_image_pair_v1)};
        ~Pair() { sony2fuji_hdr_release_pair(&value); }
    };
    auto decodeFile = [&](const char* file, Pair& pair) {
        return sony2fuji_hdr_decode_camera_raw_with_development(nullptr, file, &options,
            &development.base, &pair.value, &diagnostic);
    };
    auto decode = [&](Pair& pair) { return decodeFile(source, pair); };
    for (const auto& invalid : {truncatedFile, futureFile, legacyFile})
        expect(sony2fuji_hdr_probe_camera_profile(invalid.c_str(), &info, &diagnostic) == SONY2FUJI_STATUS_UNSUPPORTED,
               "an incompatible RLOOK was accepted");
    Pair bad;
    configure(wrongFile);
    expect(decode(bad) == SONY2FUJI_STATUS_UNSUPPORTED && !bad.value.owner_token,
           "different camera model was accepted");
    configure(plainFile);
    const auto fingerprint = std::string(development.profile_sha256);
    expect(std::string(info.camera_model) == cameraModel && fingerprint.size() == 64,
           "profile probe did not publish identity");
    development.profile_sha256[0] = fingerprint[0] == '0' ? '1' : '0';
    expect(decode(bad) == SONY2FUJI_STATUS_INVALID_ARGUMENT && !bad.value.owner_token,
           "incorrect profile hash was accepted");
    development.profile_sha256[0] = fingerprint[0];
    development.base.struct_size = sizeof(development.base);
    expect(decode(bad) == SONY2FUJI_STATUS_INVALID_ARGUMENT && !bad.value.owner_token,
           "truncated HDR development v2 was accepted");
    development.base.struct_size = sizeof(development);

    Pair plain, calibrated, compiled;
    expect(decode(plain) == SONY2FUJI_STATUS_OK, "decode Bayer RAW with linear DCP");
    configure(shiftedFile);
    expect(decode(calibrated) == SONY2FUJI_STATUS_OK, "decode Bayer RAW with shifted DCP");
    configure(compiledFile);
    expect(decode(compiled) == SONY2FUJI_STATUS_OK, "decode Bayer RAW with compiled HDR RLOOK");
    const auto& a = plain.value.hdr;
    const auto& b = calibrated.value.hdr;
    expect(a.size_bytes == b.size_bytes && b.size_bytes == compiled.value.hdr.size_bytes &&
           std::memcmp(b.data, compiled.value.hdr.data, b.size_bytes) == 0 &&
           std::memcmp(calibrated.value.sdr.data, compiled.value.sdr.data, compiled.value.sdr.size_bytes) == 0,
           "DCP and HDR RLOOK differ across renditions");
    expect(std::memcmp(plain.value.sdr.data, calibrated.value.sdr.data, plain.value.sdr.size_bytes) != 0,
           "camera profile did not affect SDR base development");
    expect(std::memcmp(plain.value.source_sha256, calibrated.value.source_sha256, 32) == 0,
           "profile must not replace the source photo identity");
    bool negative = false, aboveWhite = false;
    for (uint32_t y = 0; y < a.height; ++y) {
        const auto* original = reinterpret_cast<const float*>(static_cast<const uint8_t*>(a.data) + y * a.stride_bytes);
        const auto* adjusted = reinterpret_cast<const float*>(static_cast<const uint8_t*>(b.data) + y * b.stride_bytes);
        for (uint32_t x = 0; x < a.width; ++x, original += 3, adjusted += 3) {
            expect(std::abs(adjusted[0] - (4 * original[0] - 3 * original[1])) < 2e-5f &&
                   std::abs(adjusted[1] - original[1]) < 2e-5f && std::abs(adjusted[2] - original[2]) < 2e-5f,
                   "camera profile stopped being a linear transform");
            negative |= adjusted[0] < -.01f;
            aboveWhite |= adjusted[0] > 1.01f;
        }
    }
    expect(negative && aboveWhite, "DCP path clipped signed or super-white values");
    if (syntheticFixture) {
        std::ifstream fixture(source, std::ios::binary);
        const Bytes original((std::istreambuf_iterator<char>(fixture)), std::istreambuf_iterator<char>());
        expect(original.size() > 8 && original[0] == 'I' && original[1] == 'I', "read Bayer DNG test fixture");
        auto littleEndian = [&](size_t offset, size_t count) {
            uint32_t value = 0;
            for (size_t i = 0; i < count; ++i) value |= uint32_t(original.at(offset + i)) << (8 * i);
            return value;
        };
        const size_t ifd = littleEndian(4, 4);
        const size_t count = littleEndian(ifd, 2);
        const size_t begin = ifd + 2, end = begin + count * 12;
        expect(end + 4 <= original.size() && littleEndian(end, 4) == 0, "Bayer DNG must have a single IFD");
        size_t insertion = begin;
        while (insertion < end && littleEndian(insertion, 2) < 50727) insertion += 12;
        expect(insertion == end || littleEndian(insertion, 2) > 50727, "fixture already contains AnalogBalance");
        auto altered = original;
        const size_t analogBalance = altered.size();
        for (int value : {2, 1, 1}) appendRational(altered, value, 1);
        const size_t replacementIfd = altered.size();
        appendInteger(altered, count + 1, 2);
        altered.insert(altered.end(), original.begin() + begin, original.begin() + insertion);
        appendInteger(altered, 50727, 2);
        appendInteger(altered, 5, 2);
        appendInteger(altered, 3, 4);
        appendInteger(altered, analogBalance, 4);
        altered.insert(altered.end(), original.begin() + insertion, original.begin() + end + 4);
        for (size_t i = 0; i < 4; ++i) altered[4 + i] = static_cast<uint8_t>(replacementIfd >> (8 * i));
        const auto alteredFile = write("analog-balance.dng", altered.data(), altered.size());
        sony2fuji_hdr_source_info_v1 sourceInfo{1, sizeof(sony2fuji_hdr_source_info_v1)};
        expect(sony2fuji_hdr_probe_camera_raw(alteredFile.c_str(), &sourceInfo, &diagnostic) == SONY2FUJI_STATUS_OK,
               "fixture with DNG AnalogBalance is an ordinary HDR RAW");
        expect(decodeFile(alteredFile.c_str(), bad) == SONY2FUJI_STATUS_UNSUPPORTED &&
               diagnostic.reason == SONY2FUJI_HDR_REASON_CAMERA_PROFILE && !bad.value.owner_token,
               "nonidentity DNG AnalogBalance silently used the reference camera matrix");

        const auto changedWhite = makeProfile(false, cameraModel, false, true);
        const auto changedWhiteFile = write("changed-white.dcp", changedWhite.data(), changedWhite.size());
        configure(changedWhiteFile);
        Pair asShot;
        expect(decode(asShot) == SONY2FUJI_STATUS_OK && std::memcmp(a.data, asShot.value.hdr.data, a.size_bytes) == 0,
               "DCP ColorMatrix changed the source as-shot white balance");
        development.base.white_balance = SONY2FUJI_HDR_CAMERA_WB_TEMPERATURE;
        development.base.temperature = 6500;
        options.intent = SONY2FUJI_INTENT_PREVIEW;
        options.long_edge = 64;
        Pair custom, changedCustom;
        expect(decode(changedCustom) == SONY2FUJI_STATUS_OK, "decode custom WB using DCP ColorMatrix");
        configure(plainFile);
        expect(decode(custom) == SONY2FUJI_STATUS_OK &&
               custom.value.hdr.size_bytes == changedCustom.value.hdr.size_bytes,
               "decode custom WB using the control profile");
        const auto* control = static_cast<const float*>(custom.value.hdr.data);
        const auto* mapped = static_cast<const float*>(changedCustom.value.hdr.data);
        // The non-diagonal ColorMatrix changes only the red response of the
        // neutral from X to X+Y. At 6500 K, X/(X+Y) is approximately 0.49.
        for (size_t i = 0; i < custom.value.hdr.size_bytes / sizeof(float); i += 3) {
            expect(control[i] > 0 && std::abs(mapped[i] / control[i] - .49f) < .012f &&
                   std::abs(mapped[i + 1] - control[i + 1]) < 4e-4f &&
                   std::abs(mapped[i + 2] - control[i + 2]) < 4e-4f,
                   "custom WB used the wrong XYZ-to-camera matrix direction");
        }
        options.intent = SONY2FUJI_INTENT_FINAL;
        options.long_edge = 0;

        sony2fuji_hdr_request_v1 request{1, sizeof(sony2fuji_hdr_request_v1)};
        request.hdr_processing_version = 1;
        request.intent = SONY2FUJI_INTENT_FINAL;
        request.temperature = 6500;
        request.crop_width = request.crop_height = 1;
        struct Session {
            sony2fuji_session* value = nullptr;
            ~Session() { sony2fuji_session_destroy(value); }
        } session;
        expect(sony2fuji_session_create(&session.value) == SONY2FUJI_STATUS_OK, "create HDR render session");
        Pair rendered;
        expect(sony2fuji_hdr_render(session.value, &compiled.value, &request, &rendered.value, &diagnostic) == SONY2FUJI_STATUS_OK,
               "render the full-resolution calibrated pair");
        sony2fuji_hdr_export_config_v1 config{1, sizeof(sony2fuji_hdr_export_config_v1)};
        config.jpeg_quality = 95;
        config.base_color = SONY2FUJI_HDR_COLOR_SRGB;
        config.metadata_policy = SONY2FUJI_HDR_METADATA_ISO_XMP;
        expect(sony2fuji_hdr_export_jpeg(&rendered.value, &config, compiledFile.c_str(), &diagnostic) ==
               SONY2FUJI_STATUS_INVALID_ARGUMENT && diagnostic.reason == SONY2FUJI_HDR_REASON_SAME_FILE,
               "HDR export replaced its calibration resource");
        const auto output = (directory / "calibrated.jpg").u8string();
        expect(sony2fuji_hdr_export_jpeg(&rendered.value, &config, output.c_str(), &diagnostic) == SONY2FUJI_STATUS_OK,
               "export HDR JPEG with the selected profile");
        Pair reimported;
        expect(sony2fuji_hdr_decode(output.c_str(), &options, &reimported.value, &diagnostic) == SONY2FUJI_STATUS_OK &&
               reimported.value.hdr.width == a.width && reimported.value.hdr.height == a.height,
               "reimport calibrated HDR JPEG");
    }
    std::cout << "PASS HDR matrix DCP and RLOOK parity, grey axis, signed channels and super-white\n";
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
    if (argc == 4 && arguments[1] == "--hdr-camera") {
        hdrCameraCalibrationTests(arguments[2].c_str(), arguments[3].c_str(), false);
        return 0;
    }
    if (argc == 3) return commandLine(arguments[1], arguments[2]);
    if (argc != 1) return 2;
    unitTests();
    hdrCameraCalibrationTests(TEST_FIXTURE_DIR "/bayer-demosaic.dng", "RawLab synthetic Bayer", true);
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
