// Tone interpolation follows the Adobe DNG SDK reference spline algorithm.
// Copyright 2006-2019 Adobe Systems Incorporated. All Rights Reserved.
// See third_party/Adobe-DNG-SDK-LICENSE.txt for the retained license.
#include "sony2fuji/dcp_compiler.h"

#include "nlohmann/json.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <map>
#include <stdexcept>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace sony2fuji {
namespace {

using Json = nlohmann::json;
using Matrix = std::array<double, 9>;
using Vector = std::array<double, 3>;

constexpr std::size_t maxSourceBytes = 128u * 1024u * 1024u;
constexpr uint64_t maxCells = 4'000'000;
constexpr std::size_t toneCount = 4097;
constexpr std::size_t maxMetadataBytes = 65536;
constexpr double floatMagnitude = static_cast<double>(std::numeric_limits<float>::max());

struct CompileFailure : std::exception {
    explicit CompileFailure(DcpCompilerError value) : reason(value) {}
    DcpCompilerError reason;
};

[[noreturn]] void fail(DcpCompilerError reason) { throw CompileFailure(reason); }

struct Tag {
    uint16_t kind = 0;
    uint32_t count = 0;
    std::size_t offset = 0;
};

struct Table {
    uint32_t hues = 0;
    uint32_t saturations = 0;
    uint32_t valuesCount = 0;
    uint32_t encoding = 0;
    std::vector<float> values;

    uint64_t cells() const {
        return uint64_t(hues) * saturations * valuesCount;
    }
};

struct Reader {
    const uint8_t* bytes = nullptr;
    std::size_t size = 0;
    bool bigEndian = false;
    std::map<uint16_t, Tag> tags;

    Reader(const void* source, std::size_t sourceSize) :
        bytes(static_cast<const uint8_t*>(source)), size(sourceSize) {
        if (size > maxSourceBytes) fail(DcpCompilerError::TooLarge);
        if (!bytes || size < 8) fail(DcpCompilerError::Malformed);
        if ((bytes[0] != 'I' && bytes[0] != 'M') || bytes[0] != bytes[1]) fail(DcpCompilerError::Malformed);
        bigEndian = bytes[0] == 'M';
        const uint16_t magic = static_cast<uint16_t>(integer(2, 2));
        const uint64_t startValue = integer(4, 4);
        if (magic != 42 && magic != 0x4352) fail(DcpCompilerError::Malformed);
        if (startValue < 8 || startValue > size - 2) fail(DcpCompilerError::Malformed);
        const std::size_t start = static_cast<std::size_t>(startValue);
        const uint64_t count = integer(start, 2);
        if (count > 4096) fail(DcpCompilerError::Malformed);
        const uint64_t endValue = uint64_t(start) + 2 + count * 12;
        if (endValue > size - 4) fail(DcpCompilerError::Malformed);
        const std::size_t end = static_cast<std::size_t>(endValue);
        if (integer(end, 4) != 0) fail(DcpCompilerError::Malformed);

        static constexpr std::array<std::size_t, 13> elementSizes = {
            0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8};
        std::size_t rationalCount = 0;
        for (uint64_t index = 0; index < count; ++index) {
            const std::size_t base = start + 2 + static_cast<std::size_t>(index) * 12;
            const auto key = static_cast<uint16_t>(integer(base, 2));
            const auto kind = static_cast<uint16_t>(integer(base + 2, 2));
            const uint64_t length = integer(base + 4, 4);
            if (tags.find(key) != tags.end() || kind == 0 || kind > 12) fail(DcpCompilerError::Malformed);
            const std::size_t width = elementSizes[kind];
            if (length > std::numeric_limits<std::size_t>::max() / width) fail(DcpCompilerError::Malformed);
            const std::size_t payloadSize = static_cast<std::size_t>(length) * width;
            std::size_t offset = base + 8;
            if (payloadSize > 4) {
                const uint64_t location = integer(base + 8, 4);
                if (location > size) fail(DcpCompilerError::Malformed);
                offset = static_cast<std::size_t>(location);
            }
            if (offset > size || payloadSize > size - offset) fail(DcpCompilerError::Malformed);
            if ((kind == 5 || kind == 10)) {
                if (length > size / 8 - rationalCount) fail(DcpCompilerError::TooLarge);
                rationalCount += static_cast<std::size_t>(length);
                for (uint64_t point = 0; point < length; ++point) {
                    if (integer(offset + static_cast<std::size_t>(point) * 8 + 4, 4) == 0)
                        fail(DcpCompilerError::Malformed);
                }
            }
            tags.emplace(key, Tag{kind, static_cast<uint32_t>(length), offset});
        }
    }

    uint64_t integer(std::size_t offset, std::size_t width) const {
        uint64_t result = 0;
        for (std::size_t index = 0; index < width; ++index) {
            const std::size_t shift = (bigEndian ? width - 1 - index : index) * 8;
            result |= uint64_t(bytes[offset + index]) << shift;
        }
        return result;
    }

    std::vector<double> numbers(const Tag& tag) const {
        std::size_t width = 0;
        switch (tag.kind) {
            case 3: width = 2; break;
            case 4: width = 4; break;
            case 10: width = 8; break;
            case 11: width = 4; break;
            default: fail(DcpCompilerError::Malformed);
        }
        std::vector<double> result;
        result.reserve(tag.count);
        for (uint32_t index = 0; index < tag.count; ++index) {
            const std::size_t offset = tag.offset + static_cast<std::size_t>(index) * width;
            if (tag.kind == 3 || tag.kind == 4) {
                result.push_back(static_cast<double>(integer(offset, width)));
            } else if (tag.kind == 10) {
                const int32_t numerator = static_cast<int32_t>(integer(offset, 4));
                const int32_t denominator = static_cast<int32_t>(integer(offset + 4, 4));
                result.push_back(static_cast<double>(numerator) / static_cast<double>(denominator));
            } else {
                const uint32_t bits = static_cast<uint32_t>(integer(offset, 4));
                float value = 0;
                std::memcpy(&value, &bits, sizeof(value));
                result.push_back(static_cast<double>(value));
            }
        }
        return result;
    }

    double scalar(uint16_t key, uint16_t kind, double fallback) const {
        const auto iterator = tags.find(key);
        if (iterator == tags.end()) return fallback;
        if (iterator->second.kind != kind || iterator->second.count != 1) fail(DcpCompilerError::Malformed);
        return numbers(iterator->second)[0];
    }

    std::string text(uint16_t key) const {
        const auto iterator = tags.find(key);
        if (iterator == tags.end()) return {};
        const Tag& tag = iterator->second;
        if (tag.kind != 1 && tag.kind != 2) fail(DcpCompilerError::Malformed);
        std::vector<uint8_t> value(bytes + tag.offset, bytes + tag.offset + tag.count);
        while (!value.empty() && value.back() == 0) value.pop_back();
        // Match String(decoding:as:) by replacing malformed UTF-8 sequences.
        std::string result;
        result.reserve(value.size());
        for (std::size_t index = 0; index < value.size();) {
            const uint8_t first = value[index];
            std::size_t length = 0;
            if (first < 0x80) length = 1;
            else if (first >= 0xC2 && first <= 0xDF) length = 2;
            else if (first >= 0xE0 && first <= 0xEF) length = 3;
            else if (first >= 0xF0 && first <= 0xF4) length = 4;
            bool valid = length != 0 && index + length <= value.size();
            if (valid) {
                for (std::size_t continuation = 1; continuation < length; ++continuation)
                    valid = valid && (value[index + continuation] & 0xC0) == 0x80;
                if (length == 3 && valid) {
                    valid = !(first == 0xE0 && value[index + 1] < 0xA0) &&
                            !(first == 0xED && value[index + 1] >= 0xA0);
                } else if (length == 4 && valid) {
                    valid = !(first == 0xF0 && value[index + 1] < 0x90) &&
                            !(first == 0xF4 && value[index + 1] >= 0x90);
                }
            }
            if (!valid) {
                result.append("\xEF\xBF\xBD");
                ++index;
            } else {
                result.append(reinterpret_cast<const char*>(value.data() + index), length);
                index += length;
            }
        }
        return result;
    }

    Matrix calibration(uint16_t key) const {
        const auto iterator = tags.find(key);
        if (iterator == tags.end() || iterator->second.kind != 10 || iterator->second.count != 9)
            fail(DcpCompilerError::InvalidCalibration);
        const auto values = numbers(iterator->second);
        Matrix result{};
        for (std::size_t index = 0; index < result.size(); ++index) {
            if (!std::isfinite(values[index])) fail(DcpCompilerError::InvalidCalibration);
            result[index] = values[index];
        }
        return result;
    }

    Table table(uint16_t dimensionsKey, uint16_t dataKey, uint16_t encodingKey) const {
        const auto dimensionsIterator = tags.find(dimensionsKey);
        const auto dataIterator = tags.find(dataKey);
        if (dimensionsIterator == tags.end() || dimensionsIterator->second.kind != 4 ||
            (dimensionsIterator->second.count != 2 && dimensionsIterator->second.count != 3) ||
            dataIterator == tags.end() || dataIterator->second.kind != 11) {
            fail(DcpCompilerError::InvalidTable);
        }
        const auto dimensions = numbers(dimensionsIterator->second);
        const uint32_t hues = static_cast<uint32_t>(dimensions[0]);
        const uint32_t saturations = static_cast<uint32_t>(dimensions[1]);
        const uint32_t values = dimensions.size() == 3 ? static_cast<uint32_t>(dimensions[2]) : 1;
        if (hues < 1 || saturations < 2 || values < 1 ||
            hues > maxCells / saturations || uint64_t(hues) * saturations > maxCells / values)
            fail(DcpCompilerError::InvalidTable);
        const uint64_t cells = uint64_t(hues) * saturations * values;
        const double code = scalar(encodingKey, 4, 0);
        if (code != 0 && code != 1) fail(DcpCompilerError::InvalidTable);
        if (values == 1 && code == 1) fail(DcpCompilerError::InvalidTable);
        const uint64_t omittedCount = uint64_t(hues) * (saturations - 1) * values * 3;
        const uint64_t fullCount = cells * 3;
        const bool omitted = dataIterator->second.count == omittedCount;
        if (dataIterator->second.count != fullCount && !omitted) fail(DcpCompilerError::InvalidTable);
        const auto source = numbers(dataIterator->second);
        for (std::size_t index = 0; index < source.size(); ++index) {
            if (!std::isfinite(source[index]) || (index % 3 != 0 && source[index] < 0))
                fail(DcpCompilerError::InvalidTable);
        }
        Table result;
        result.hues = hues;
        result.saturations = saturations;
        result.valuesCount = values;
        result.encoding = static_cast<uint32_t>(code);
        result.values.resize(static_cast<std::size_t>(cells) * 3);
        for (uint32_t value = 0; value < values; ++value) {
            for (uint32_t hue = 0; hue < hues; ++hue) {
                for (uint32_t saturation = 0; saturation < saturations; ++saturation) {
                    const std::size_t target = (static_cast<std::size_t>(value) * hues + hue) * saturations * 3 +
                                               static_cast<std::size_t>(saturation) * 3;
                    const uint32_t sourceSaturation = omitted ? (saturation > 0 ? saturation - 1 : 0) : saturation;
                    const uint32_t sourceSaturations = omitted ? saturations - 1 : saturations;
                    const std::size_t origin = (static_cast<std::size_t>(value) * hues + hue) * sourceSaturations * 3 +
                                               static_cast<std::size_t>(sourceSaturation) * 3;
                    for (int channel = 0; channel < 3; ++channel)
                        result.values[target + channel] = channel == 2 && saturation == 0
                            ? 1.0f : static_cast<float>(source[origin + channel]);
                }
            }
        }
        return result;
    }
};

Vector multiply(const Matrix& matrix, const Vector& vector) {
    return {
        matrix[0] * vector[0] + matrix[1] * vector[1] + matrix[2] * vector[2],
        matrix[3] * vector[0] + matrix[4] * vector[1] + matrix[5] * vector[2],
        matrix[6] * vector[0] + matrix[7] * vector[1] + matrix[8] * vector[2]};
}

Matrix multiply(const Matrix& left, const Matrix& right) {
    Matrix result{};
    for (int row = 0; row < 3; ++row) {
        for (int column = 0; column < 3; ++column) {
            result[row * 3 + column] = left[row * 3] * right[column] +
                                        left[row * 3 + 1] * right[3 + column] +
                                        left[row * 3 + 2] * right[6 + column];
        }
    }
    return result;
}

Matrix diagonal(const Vector& vector) {
    return {vector[0], 0, 0, 0, vector[1], 0, 0, 0, vector[2]};
}

bool inverse(const Matrix& matrix, Matrix& result) {
    const double a = matrix[0], b = matrix[1], c = matrix[2];
    const double d = matrix[3], e = matrix[4], f = matrix[5];
    const double g = matrix[6], h = matrix[7], i = matrix[8];
    const double determinant = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
    if (!std::isfinite(determinant) || determinant == 0) return false;
    result = {(e * i - f * h) / determinant, (c * h - b * i) / determinant,
              (b * f - c * e) / determinant, (f * g - d * i) / determinant,
              (a * i - c * g) / determinant, (c * d - a * f) / determinant,
              (d * h - e * g) / determinant, (b * g - a * h) / determinant,
              (a * e - b * d) / determinant};
    return true;
}

bool finiteMatrix(const Matrix& matrix) {
    return std::all_of(matrix.begin(), matrix.end(), [](double value) {
        return std::isfinite(value) && std::abs(value) <= floatMagnitude;
    });
}

bool fullRank(const Matrix& matrix) {
    // One-sided Jacobi SVD keeps the conditioning of A itself. Diagonalizing
    // A^T*A would square the condition number and hide near-singular matrices.
    double values[3][3]{};
    for (int row = 0; row < 3; ++row)
        for (int column = 0; column < 3; ++column) values[row][column] = matrix[row * 3 + column];
    for (int iteration = 0; iteration < 32; ++iteration) {
        bool rotated = false;
        for (int p = 0; p < 2; ++p) {
            for (int q = p + 1; q < 3; ++q) {
                double alpha = 0, beta = 0, gamma = 0;
                for (int row = 0; row < 3; ++row) {
                    alpha += values[row][p] * values[row][p];
                    beta += values[row][q] * values[row][q];
                    gamma += values[row][p] * values[row][q];
                }
                if (!std::isfinite(alpha) || !std::isfinite(beta) || !std::isfinite(gamma)) return false;
                if (gamma == 0 || std::abs(gamma) <= std::numeric_limits<double>::epsilon() * std::sqrt(alpha * beta))
                    continue;
                const double tau = (beta - alpha) / (2 * gamma);
                const double tangent = std::copysign(1.0, tau) / (std::abs(tau) + std::hypot(1.0, tau));
                const double cosine = 1 / std::sqrt(1 + tangent * tangent), sine = tangent * cosine;
                for (int row = 0; row < 3; ++row) {
                    const double left = values[row][p], right = values[row][q];
                    values[row][p] = cosine * left - sine * right;
                    values[row][q] = sine * left + cosine * right;
                }
                rotated = true;
            }
        }
        if (!rotated) break;
    }
    std::array<double, 3> singular{};
    for (int column = 0; column < 3; ++column) {
        double norm = 0;
        for (int row = 0; row < 3; ++row) norm += values[row][column] * values[row][column];
        if (!std::isfinite(norm)) return false;
        singular[column] = std::sqrt(std::max(0.0, norm));
    }
    std::sort(singular.begin(), singular.end(), std::greater<double>());
    if (!(singular[0] > 0) || !std::isfinite(singular[0])) return false;
    const double threshold = singular[0] * 3 * std::numeric_limits<double>::epsilon();
    return std::isfinite(singular[2]) && singular[2] > threshold;
}

std::vector<double> toneSamples(const std::vector<double>& points) {
    const std::size_t count = points.size() / 2;
    std::vector<double> x(count), y(count);
    for (std::size_t index = 0; index < count; ++index) {
        x[index] = points[index * 2];
        y[index] = points[index * 2 + 1];
        if (!std::isfinite(x[index]) || !std::isfinite(y[index]) || x[index] < 0 || x[index] > 1 ||
            y[index] < 0 || y[index] > 1 || (index > 0 && x[index] <= x[index - 1]))
            fail(DcpCompilerError::InvalidToneCurve);
    }
    std::vector<double> h(count - 1), second(count, 0);
    for (std::size_t index = 0; index + 1 < count; ++index) h[index] = x[index + 1] - x[index];
    if (count > 2) {
        std::vector<double> diagonalValues(count - 2), right(count - 2);
        for (std::size_t index = 0; index + 2 < count; ++index) {
            diagonalValues[index] = 2 * (h[index] + h[index + 1]);
            right[index] = 6 * ((y[index + 2] - y[index + 1]) / h[index + 1] -
                                (y[index + 1] - y[index]) / h[index]);
        }
        for (std::size_t index = 1; index < diagonalValues.size(); ++index) {
            const double ratio = h[index] / diagonalValues[index - 1];
            diagonalValues[index] -= ratio * h[index];
            right[index] -= ratio * right[index - 1];
        }
        for (std::size_t index = diagonalValues.size(); index-- > 0;)
            second[index + 1] = (right[index] - h[index + 1] * second[index + 2]) / diagonalValues[index];
    }
    std::vector<double> result;
    result.reserve(toneCount);
    std::size_t interval = 0;
    for (std::size_t step = 0; step <= 4096; ++step) {
        const double position = static_cast<double>(step) / 4096;
        if (position <= x.front()) result.push_back(y.front());
        else if (position >= x.back()) result.push_back(y.back());
        else {
            while (interval < count - 2 && position > x[interval + 1]) ++interval;
            const double width = h[interval];
            const double a = (x[interval + 1] - position) / width;
            const double b = (position - x[interval]) / width;
            const double value = a * y[interval] + b * y[interval + 1] + width * width / 6 *
                ((a * a * a - a) * second[interval] + (b * b * b - b) * second[interval + 1]);
            if (!std::isfinite(value) || std::abs(value) > floatMagnitude) fail(DcpCompilerError::InvalidToneCurve);
            result.push_back(value);
        }
    }
    return result;
}

void appendU32(std::vector<uint8_t>& output, uint32_t value) {
    output.push_back(static_cast<uint8_t>(value));
    output.push_back(static_cast<uint8_t>(value >> 8));
    output.push_back(static_cast<uint8_t>(value >> 16));
    output.push_back(static_cast<uint8_t>(value >> 24));
}

void appendU64(std::vector<uint8_t>& output, uint64_t value) {
    for (int index = 0; index < 8; ++index) output.push_back(static_cast<uint8_t>(value >> (index * 8)));
}

void appendDouble(std::vector<uint8_t>& output, double value) {
    uint64_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    appendU64(output, bits);
}

void appendFloat(std::vector<uint8_t>& output, float value) {
    uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    appendU32(output, bits);
}

Json dimensions(const Table* table) {
    if (!table) return nullptr;
    return Json::array({table->hues, table->saturations, table->valuesCount});
}

std::vector<uint8_t> compileImpl(const void* data, std::size_t size, const std::string& sourceName) {
    Reader reader(data, size);
    for (uint16_t key : {uint16_t(52525), uint16_t(52539), uint16_t(52543), uint16_t(52544), uint16_t(52551)})
        if (reader.tags.find(key) != reader.tags.end()) fail(DcpCompilerError::UnsupportedStages);

    constexpr std::array<std::array<uint16_t, 3>, 3> pairs = {{
        {{50778, 50721, 50964}}, {{50779, 50722, 50965}}, {{52529, 52531, 52532}}}};
    std::vector<std::array<uint16_t, 3>> matches;
    for (const auto& pair : pairs)
        if (reader.scalar(pair[0], 3, 0) == 21) matches.push_back(pair);
    if (matches.size() != 1) fail(DcpCompilerError::InvalidCalibration);
    const auto pair = matches.front();
    const Matrix color = reader.calibration(pair[1]);
    Matrix forward = reader.calibration(pair[2]);
    if (!fullRank(color)) fail(DcpCompilerError::InvalidCalibration);
    const Vector d65{0.95047, 1, 1.08883};
    const Vector white = multiply(color, d65);
    const Vector forwardWhite = multiply(forward, Vector{1, 1, 1});
    if (!std::all_of(white.begin(), white.end(), [](double value) { return std::isfinite(value) && value > 0; }) ||
        !std::all_of(forwardWhite.begin(), forwardWhite.end(), [](double value) { return std::isfinite(value) && value > 0; }))
        fail(DcpCompilerError::InvalidCalibration);

    const Matrix prophoto = {0.7976749, 0.1351917, 0.0313534,
                             0.2880402, 0.7118741, 0.0000857,
                             0, 0, 0.8252100};
    const Matrix srgb = {0.4124564, 0.3575761, 0.1804375,
                         0.2126729, 0.7151522, 0.0721750,
                         0.0193339, 0.1191920, 0.9503041};
    const Matrix bradford = {0.8951, 0.2664, -0.1614,
                             -0.7502, 1.7135, 0.0367,
                             0.0389, -0.0685, 1.0296};
    Matrix prophotoInverse, bradfordInverse;
    if (!inverse(prophoto, prophotoInverse) || !inverse(bradford, bradfordInverse))
        fail(DcpCompilerError::InvalidCalibration);
    const Vector d50{0.96422, 1, 0.82521};
    const Vector bradfordD65 = multiply(bradford, d65), bradfordD50 = multiply(bradford, d50);
    Vector adaptationScale{};
    for (int index = 0; index < 3; ++index) adaptationScale[index] = bradfordD50[index] / bradfordD65[index];
    const Matrix d65ToD50 = multiply(multiply(bradfordInverse, diagonal(adaptationScale)), bradford);
    const Matrix srgbToProphoto = multiply(multiply(prophotoInverse, d65ToD50), srgb);
    Matrix output;
    if (!inverse(srgbToProphoto, output)) fail(DcpCompilerError::InvalidCalibration);
    const Vector prophotoWhite = multiply(prophoto, Vector{1, 1, 1});
    Vector forwardScale{};
    for (int index = 0; index < 3; ++index) forwardScale[index] = prophotoWhite[index] / forwardWhite[index];
    forward = multiply(diagonal(forwardScale), forward);
    const Matrix input = multiply(multiply(multiply(multiply(prophotoInverse, forward), diagonal({
        1 / white[0], 1 / white[1], 1 / white[2]})), color), srgb);
    if (!finiteMatrix(input) || !finiteMatrix(output)) fail(DcpCompilerError::InvalidCalibration);

    Table calibration;
    bool hasCalibration = false;
    uint16_t selectedHsm = 0;
    const bool hasHsmTag = reader.tags.find(50937) != reader.tags.end() || reader.tags.find(50938) != reader.tags.end() ||
                           reader.tags.find(50939) != reader.tags.end() || reader.tags.find(51107) != reader.tags.end() ||
                           reader.tags.find(52537) != reader.tags.end();
    if (hasHsmTag) {
        if (reader.tags.find(52529) != reader.tags.end() || reader.tags.find(52537) != reader.tags.end())
            fail(DcpCompilerError::TripleIlluminant);
        if (reader.tags.find(50937) == reader.tags.end() || reader.tags.find(50938) == reader.tags.end())
            fail(DcpCompilerError::InvalidTable);
        selectedHsm = reader.tags.find(50939) != reader.tags.end() && pair[0] == 50779 ? 50939 : 50938;
        for (uint16_t key : {uint16_t(50938), uint16_t(50939)}) {
            if (reader.tags.find(key) == reader.tags.end()) continue;
            Table table = reader.table(50937, key, 51107);
            if (key == selectedHsm) {
                calibration = std::move(table);
                hasCalibration = true;
            }
        }
    }
    Table look;
    bool hasLook = false;
    const bool hasLookTag = reader.tags.find(50981) != reader.tags.end() || reader.tags.find(50982) != reader.tags.end() ||
                            reader.tags.find(51108) != reader.tags.end();
    if (hasLookTag) {
        look = reader.table(50981, 50982, 51108);
        hasLook = true;
    }
    const uint64_t cells = (hasCalibration ? calibration.cells() : 0) + (hasLook ? look.cells() : 0);
    if (cells > maxCells) fail(DcpCompilerError::TooLarge);

    const auto toneIterator = reader.tags.find(50940);
    if (toneIterator == reader.tags.end()) fail(DcpCompilerError::MissingToneCurve);
    if (toneIterator->second.kind != 11 || toneIterator->second.count < 4 || toneIterator->second.count > 16384 ||
        toneIterator->second.count % 2 != 0)
        fail(DcpCompilerError::InvalidToneCurve);
    const auto points = reader.numbers(toneIterator->second);
    const auto tone = toneSamples(points);
    if (reader.scalar(51110, 4, 0) != 1) fail(DcpCompilerError::AutomaticBlack);
    const double exposure = reader.scalar(51109, 10, 0);
    if (!std::isfinite(exposure) || std::abs(exposure) > 16) fail(DcpCompilerError::InvalidExposure);
    const double exposureMultiplier = std::pow(2.0, exposure);
    if (!std::isfinite(exposureMultiplier) || exposureMultiplier < 1.0 / 65536 || exposureMultiplier > 65536)
        fail(DcpCompilerError::InvalidExposure);

    const uint32_t version = hasCalibration || !hasLook ? 2 : 1;
    std::set<uint16_t> consumed = {50940, 50981, 50982, 51108, 51109, 51110,
                                   pair[0], pair[1], pair[2]};
    if (selectedHsm) consumed.insert(50937), consumed.insert(selectedHsm), consumed.insert(51107);
    const std::set<uint16_t> metadataTags = {50708, 50932, 50936, 50941, 50942};
    Json excluded = Json::array();
    for (const auto& [key, unused] : reader.tags)
        if (consumed.find(key) == consumed.end() && metadataTags.find(key) == metadataTags.end()) excluded.push_back(key);
    Json dcp = {
        {"canonical", false}, {"excluded_tags", excluded}, {"format", "dcp"},
        {"hue_sat_map_data_tag", selectedHsm ? Json(selectedHsm) : Json(nullptr)},
        {"hue_sat_map_dimensions", hasCalibration ? dimensions(&calibration) : Json(nullptr)},
        {"hue_sat_map_encoding", hasCalibration ? calibration.encoding : 0},
        {"input_adapter", "d65-white-relative-virtual-camera"},
        {"input_calibration_tags", Json::array({pair[0], pair[1], pair[2]})},
        {"look_dimensions", hasLook ? dimensions(&look) : Json(nullptr)},
        {"look_encoding", hasLook ? look.encoding : 0}, {"name", reader.text(50936)},
        {"profile_exposure_ev", exposure}, {"scope", "D65-adapted profile appearance; target RAW calibration/WB unchanged; no Adobe rendering parity"},
        {"source_model", reader.text(50708)}, {"tone_points", points.size() / 2},
        {"tone_source", "profile"}, {"black_render_policy", "none-profile"},
        {"apply_profile_exposure", true}, {"exposure_method", "linear EV before look; not Adobe exposure-tone emulation"}
    };
    Json metadata = {
        {"dcp", dcp}, {"evaluation", "CPU double reference; optional GPU float32"},
        {"format_version", version}, {"input", "scene-linear-srgb-d65"},
        {"mode", "native-dcp"}, {"output", "display-srgb"}, {"rgb_cube_baked", false},
        {"source", sourceName}, {"version", "mac-native-1"}
    };
    const std::string metadataText = metadata.dump();
    if (metadataText.size() > maxMetadataBytes) fail(DcpCompilerError::TooLarge);

    std::vector<uint8_t> result;
    const uint64_t tableBytes = cells * 3 * sizeof(float);
    const uint64_t expected = (version == 2 ? 56 : 40) + 19 * sizeof(double) + tableBytes + toneCount * sizeof(double) + metadataText.size();
    if (expected > 64u * 1024u * 1024u) fail(DcpCompilerError::TooLarge);
    result.reserve(static_cast<std::size_t>(expected));
    result.insert(result.end(), {'R', 'L', 'O', 'O', 'K', 'D', 'C', 'P'});
    appendU32(result, version);
    appendU32(result, 0);
    appendU32(result, hasLook ? look.encoding : 0);
    appendU32(result, hasLook ? look.hues : 0);
    appendU32(result, hasLook ? look.saturations : 0);
    appendU32(result, hasLook ? look.valuesCount : 0);
    appendU32(result, static_cast<uint32_t>(toneCount));
    appendU32(result, static_cast<uint32_t>(metadataText.size()));
    if (version == 2) {
        appendU32(result, hasCalibration ? calibration.encoding : 0);
        appendU32(result, hasCalibration ? calibration.hues : 0);
        appendU32(result, hasCalibration ? calibration.saturations : 0);
        appendU32(result, hasCalibration ? calibration.valuesCount : 0);
    }
    for (double value : input) appendDouble(result, value);
    for (double value : output) appendDouble(result, value);
    appendDouble(result, exposureMultiplier);
    auto appendTable = [&](const Table* table) {
        if (!table) return;
        for (float value : table->values) appendFloat(result, value);
    };
    appendTable(hasCalibration ? &calibration : nullptr);
    appendTable(hasLook ? &look : nullptr);
    for (double value : tone) appendDouble(result, value);
    result.insert(result.end(), metadataText.begin(), metadataText.end());
    if (result.size() != expected || result.size() > 64u * 1024u * 1024u) fail(DcpCompilerError::TooLarge);
    return result;
}

} // namespace

std::vector<uint8_t> compileDcp(const void* data, std::size_t size, const std::string& sourceName,
                                DcpCompilerError& error) {
    error = DcpCompilerError::None;
    try {
        return compileImpl(data, size, sourceName);
    } catch (const CompileFailure& failure) {
        error = failure.reason;
        return {};
    } catch (const std::bad_alloc&) {
        throw;
    } catch (const std::exception&) {
        error = DcpCompilerError::Malformed;
        return {};
    }
}

} // namespace sony2fuji
