#include "sony2fuji/lut_parser.h"
#include <algorithm>
#include <cctype>
#include <cmath>
#include <fstream>
#include <filesystem>
#include <mutex>
#include <sstream>
#include <sys/stat.h>

namespace sony2fuji {
namespace {
std::string compact(std::string text) {
    std::string result;
    for (unsigned char c : text) if (std::isalnum(c)) result += std::tolower(c);
    return result;
}
bool readRGB(std::istringstream& line, RGB& p) {
    return static_cast<bool>(line >> p.r >> p.g >> p.b) &&
        std::isfinite(p.r) && std::isfinite(p.g) && std::isfinite(p.b);
}
}

ErrorCode LUT3D::loadFromFile(const std::string& path) { return parseCubeFile(path); }

RGB LUT3D::getValue(int r, int g, int b) const {
    if (r < 0 || g < 0 || b < 0 || r >= size_ || g >= size_ || b >= size_) return RGB();
    return data_[static_cast<size_t>((b * size_ + g) * size_ + r)];
}

ErrorCode LUT3D::parseCubeFile(const std::string& path) {
    *this = LUT3D();
    std::ifstream file(std::filesystem::u8path(path));
    if (!file) return ErrorCode::FileNotFound;
    std::string line, gamma, gamut;
    std::vector<RGB> values;
    bool minSeen = false, maxSeen = false;
    while (std::getline(file, line)) {
        auto first = line.find_first_not_of(" \t\r");
        if (first == std::string::npos) continue;
        line.erase(0, first);
        if (line.front() == '#') {
            const auto colon = line.find(':');
            if (colon == std::string::npos) continue;
            auto key = compact(line.substr(1, colon-1));
            auto value = line.substr(colon+1);
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
            values.reserve(static_cast<size_t>(size_) * size_ * size_);
        } else if (key == "DOMAIN_MIN") {
            if (minSeen || !readRGB(input, domainMin_)) return ErrorCode::ParseError;
            minSeen = true;
        } else if (key == "DOMAIN_MAX") {
            if (maxSeen || !readRGB(input, domainMax_)) return ErrorCode::ParseError;
            maxSeen = true;
        } else {
            RGB value;
            std::istringstream numbers(line);
            if (!size_ || !readRGB(numbers, value)) return ErrorCode::ParseError;
            if (values.size() >= static_cast<size_t>(size_)*size_*size_) return ErrorCode::ParseError;
            values.push_back(value);
        }
    }
    if (!size_ || values.size() != static_cast<size_t>(size_)*size_*size_ ||
        domainMin_.r >= domainMax_.r || domainMin_.g >= domainMax_.g || domainMin_.b >= domainMax_.b)
        return ErrorCode::ParseError;
    // CUBE specifies R-fast order, independent of the output color variation.
    data_ = std::move(values);
    const std::string prefix = "flog2to";
    const std::string output = gamma.compare(0, prefix.size(), prefix) == 0 ? gamma.substr(prefix.size()) : "";
    // The gamut-only F-Log2 conversion is not a display look.
    photoLUT_ = gamut == "fgamuttoiturbt709" &&
        !output.empty() && output != "flog2";
    return ErrorCode::Success;
}

std::unique_ptr<LUT3D> LUTParser::loadLUT(const std::string& path) {
    if (detectFormat(path) != "cube") return nullptr;
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
