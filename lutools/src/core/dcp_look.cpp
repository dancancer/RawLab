// HSV/tone evaluation follows the Adobe DNG SDK reference algorithms.
// Copyright 2006-2023 Adobe Systems Incorporated. All Rights Reserved.
// See third_party/Adobe-DNG-SDK-LICENSE.txt for the retained Adobe license.
#include "sony2fuji/dcp_look.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <mutex>
#include <type_traits>

namespace sony2fuji {
namespace {

constexpr uintmax_t maxBytes = 64 * 1024 * 1024;
constexpr uint64_t maxCells = 4000000;
constexpr double magnitudeLimit = std::numeric_limits<float>::max();
static_assert(sizeof(float) == 4 && sizeof(double) == 8, "Native DCP requires float32/float64");

uint64_t integer(const unsigned char*& cursor, size_t bytes) {
    uint64_t value = 0;
    for (size_t i = 0; i < bytes; ++i) value |= uint64_t(*cursor++) << (i * 8);
    return value;
}

template<class T> T floating(const unsigned char*& cursor) {
    static_assert(std::numeric_limits<T>::is_iec559, "Native DCP requires IEEE floating point");
    using Bits = typename std::conditional<sizeof(T) == 4, uint32_t, uint64_t>::type;
    Bits bits = static_cast<Bits>(integer(cursor, sizeof(T)));
    T value;
    std::memcpy(&value, &bits, sizeof(T));
    return value;
}

bool bounded(double value) { return std::isfinite(value) && std::abs(value) <= magnitudeLimit; }
double clip(double value) { return std::clamp(value, 0.0, 1.0); }
double encode(double value) { return value <= .0031308 ? 12.92 * value : 1.055 * std::pow(value, 1 / 2.4) - .055; }
double decode(double value) { return value <= .04045 ? value / 12.92 : std::pow((value + .055) / 1.055, 2.4); }
double wrapHue(double value) {
    value = std::fmod(value, 6.0);
    if (value < 0) value += 6.0;
    return value >= 6.0 ? 0.0 : value;
}

std::array<double, 3> multiply(const std::array<double, 9>& matrix, const std::array<double, 3>& rgb) {
    return {matrix[0] * rgb[0] + matrix[1] * rgb[1] + matrix[2] * rgb[2],
            matrix[3] * rgb[0] + matrix[4] * rgb[1] + matrix[5] * rgb[2],
            matrix[6] * rgb[0] + matrix[7] * rgb[1] + matrix[8] * rgb[2]};
}

bool tableCells(const DcpTable& table, bool optional, uint64_t& count) {
    count = 0;
    if (optional && !table.hues && !table.saturations && !table.values && !table.encoding) return true;
    const uint64_t plane = uint64_t(table.hues) * table.saturations;
    if (table.hues < 1 || table.saturations < 2 || table.values < 1 || plane > maxCells ||
        plane * table.values > maxCells || table.encoding > 1 || (table.encoding == 1 && table.values == 1)) return false;
    count = plane * table.values;
    return true;
}

} // namespace

std::shared_ptr<const DcpLook> DcpLook::loadCached(const std::string& path) {
    std::error_code error;
    const auto file = std::filesystem::u8path(path);
    const auto stamp = std::filesystem::last_write_time(file, error);
    if (error) return nullptr;
    const auto bytes = std::filesystem::file_size(file, error);
    if (error || bytes < 40 || bytes > maxBytes) return nullptr;
    static std::mutex mutex;
    static std::string previous;
    static std::filesystem::file_time_type modified;
    static uintmax_t size = 0;
    static std::shared_ptr<const DcpLook> cached;
    std::lock_guard<std::mutex> lock(mutex);
    if (previous == path && modified == stamp && size == bytes && cached) return cached;
    auto result = std::shared_ptr<DcpLook>(new DcpLook);
    if (!result->load(path, bytes)) return nullptr;
    cached = result;
    previous = path; modified = stamp; size = bytes;
    return cached;
}

bool DcpLook::load(const std::string& path, uintmax_t size) {
    std::ifstream stream(std::filesystem::u8path(path), std::ios::binary);
    if (!stream) return false;
    std::vector<unsigned char> bytes(static_cast<size_t>(size));
    stream.read(reinterpret_cast<char*>(bytes.data()), static_cast<std::streamsize>(size));
    if (stream.gcount() != static_cast<std::streamsize>(size) || stream.peek() != std::char_traits<char>::eof()) return false;
    if (std::memcmp(bytes.data(), "RLOOKDCP", 8) != 0) return false;
    const unsigned char* cursor = bytes.data() + 8;
    const auto version = integer(cursor, 4), flags = integer(cursor, 4);
    auto dimensions = [&](DcpTable& table) {
        table.encoding = static_cast<uint32_t>(integer(cursor, 4));
        table.hues = static_cast<uint32_t>(integer(cursor, 4));
        table.saturations = static_cast<uint32_t>(integer(cursor, 4));
        table.values = static_cast<uint32_t>(integer(cursor, 4));
    };
    dimensions(stages_.look);
    const auto toneCount = integer(cursor, 4), metadataSize = integer(cursor, 4);
    if ((version != 1 && version != 2) || flags != 0 || toneCount != stages_.tone.size() || metadataSize > 65536) return false;
    if (version == 2) {
        if (size < 56) return false;
        dimensions(stages_.calibration);
    }
    uint64_t lookCells, calibrationCells;
    if (!tableCells(stages_.look, version == 2, lookCells) || !tableCells(stages_.calibration, true, calibrationCells) ||
        lookCells + calibrationCells > maxCells) return false;
    const uint64_t headerSize = version == 2 ? 56 : 40;
    if (size != headerSize + 19 * 8 + (lookCells + calibrationCells) * 12 + toneCount * 8 + metadataSize) return false;
    for (auto& value : stages_.input) { value = floating<double>(cursor); if (!bounded(value)) return false; }
    for (auto& value : stages_.output) { value = floating<double>(cursor); if (!bounded(value)) return false; }
    stages_.exposure = floating<double>(cursor);
    if (!std::isfinite(stages_.exposure) || stages_.exposure < 1.0 / 65536 || stages_.exposure > 65536) return false;
    auto readTable = [&](DcpTable& table, uint64_t cells) {
        table.entries.resize(static_cast<size_t>(cells));
        for (size_t i = 0; i < table.entries.size(); ++i) {
            auto& value = table.entries[i];
            value.r = floating<float>(cursor); value.g = floating<float>(cursor); value.b = floating<float>(cursor);
            if (!bounded(value.r) || !bounded(value.g) || !bounded(value.b) || value.g < 0 || value.b < 0 ||
                (i % table.saturations == 0 && value.b != 1)) return false;
        }
        return true;
    };
    if (!readTable(stages_.calibration, calibrationCells) || !readTable(stages_.look, lookCells)) return false;
    for (auto& value : stages_.tone) { value = floating<double>(cursor); if (!bounded(value)) return false; }
    return true;
}

double DcpLook::tone(double value) const {
    const double position = clip(value) * 4096;
    const auto index = std::min(static_cast<size_t>(position), size_t(4095));
    const double fraction = position - index;
    return stages_.tone[index] + (stages_.tone[index + 1] - stages_.tone[index]) * fraction;
}

static std::array<double, 3> applyTable(std::array<double, 3> rgb, const DcpTable& table) {
    for (auto& value : rgb) value = clip(value);
    const double high = std::max({rgb[0], rgb[1], rgb[2]});
    const double low = std::min({rgb[0], rgb[1], rgb[2]});
    const double delta = high - low, divisor = delta > 0 ? delta : 1;
    double hue = high == rgb[0] ? (rgb[1] - rgb[2]) / divisor :
                 high == rgb[1] ? 2 + (rgb[2] - rgb[0]) / divisor : 4 + (rgb[0] - rgb[1]) / divisor;
    hue = wrapHue(hue);
    double saturation = high > 0 ? delta / high : 0;
    const double encodedValue = table.encoding == 1 ? encode(high) : high;
    const double hp = hue * table.hues / 6, sp = saturation * (table.saturations - 1), vp = encodedValue * (table.values - 1);
    const auto h0 = std::min(static_cast<uint32_t>(hp), table.hues - 1);
    const auto s0 = std::min(static_cast<uint32_t>(sp), table.saturations - 2);
    const auto v0 = table.values > 1 ? std::min(static_cast<uint32_t>(vp), table.values - 2) : 0;
    const double hf = hp - h0, sf = sp - s0, vf = vp - v0;
    std::array<double, 3> adjustment{};
    for (uint32_t dh = 0; dh < 2; ++dh) for (uint32_t ds = 0; ds < 2; ++ds) for (uint32_t dv = 0; dv < 2; ++dv) {
        const double weight = (dh ? hf : 1 - hf) * (ds ? sf : 1 - sf) * (dv ? vf : 1 - vf);
        const size_t index = (size_t(std::min(v0 + dv, table.values - 1)) * table.hues + (h0 + dh) % table.hues) * table.saturations + s0 + ds;
        const auto& value = table.entries[index];
        adjustment[0] += weight * value.r; adjustment[1] += weight * value.g; adjustment[2] += weight * value.b;
    }
    hue = wrapHue(hue + adjustment[0] / 60);
    saturation = clip(saturation * adjustment[1]);
    double value = clip(encodedValue * adjustment[2]);
    if (table.encoding == 1) value = decode(value);
    const double chroma = value * saturation, x = chroma * (1 - std::abs(std::fmod(hue, 2) - 1));
    switch (static_cast<int>(hue)) {
        case 0: rgb = {chroma, x, 0}; break;
        case 1: rgb = {x, chroma, 0}; break;
        case 2: rgb = {0, chroma, x}; break;
        case 3: rgb = {0, x, chroma}; break;
        case 4: rgb = {x, 0, chroma}; break;
        default: rgb = {chroma, 0, x}; break;
    }
    for (auto& channel : rgb) channel = clip(channel + value - chroma);
    return rgb;
}

RGB DcpLook::apply(const RGB& linearSrgb) const {
    auto rgb = multiply(stages_.input, {linearSrgb.r, linearSrgb.g, linearSrgb.b});
    if (!stages_.calibration.entries.empty()) rgb = applyTable(rgb, stages_.calibration);
    for (auto& value : rgb) value *= stages_.exposure;
    if (!stages_.look.entries.empty()) rgb = applyTable(rgb, stages_.look);
    for (auto& value : rgb) value = clip(value);
    const double minimum = std::min({rgb[0], rgb[1], rgb[2]}), maximum = std::max({rgb[0], rgb[1], rgb[2]});
    const double lower = tone(minimum), upper = tone(maximum);
    for (auto& channel : rgb)
        channel = lower + (upper - lower) * (maximum != minimum ? (channel - minimum) / (maximum - minimum) : 0);
    rgb = multiply(stages_.output, rgb);
    return RGB(static_cast<float>(clip(encode(rgb[0]))), static_cast<float>(clip(encode(rgb[1]))),
               static_cast<float>(clip(encode(rgb[2]))));
}

} // namespace sony2fuji
