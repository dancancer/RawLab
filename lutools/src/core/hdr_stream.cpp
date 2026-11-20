#include "core/hdr_stream.h"
#include "core/hdr_resample.h"
#include "core/hdr_storage.h"
#include "core/hdr_jpeg.h"
#include "core/processing_cancellation.h"
#include "platform/hdr_image.h"
#include <algorithm>
#include <cmath>
#include <limits>
#include <optional>
#include <unordered_map>

namespace sony2fuji::hdr {
namespace {
namespace fs = std::filesystem;
constexpr uint32_t decodeRows = 256, tileEdge = 128;
constexpr size_t cachedTiles = 32;

using storage::Directory;
using storage::File;
using storage::Mapping;

class TileReader {
    struct Tile { std::vector<RGB> pixels; uint64_t use; };
    File file_;
    uint32_t width_, height_;
    uint64_t clock_ = 0;
    uint32_t lastLeft_ = std::numeric_limits<uint32_t>::max();
    uint32_t lastTop_ = std::numeric_limits<uint32_t>::max();
    Tile* lastTile_ = nullptr;
    std::unordered_map<uint64_t, Tile> tiles_;
public:
    TileReader(const fs::path& path, uint32_t width, uint32_t height) : file_(path), width_(width), height_(height) {}
    RGB read(int x, int y) {
        const uint32_t left = uint32_t(x) / tileEdge * tileEdge, top = uint32_t(y) / tileEdge * tileEdge;
        Tile* tile = lastTile_;
        if (!tile || left != lastLeft_ || top != lastTop_) {
            const uint64_t key = uint64_t(top) * width_ + left;
            auto found = tiles_.find(key);
            if (found == tiles_.end()) {
                checkProcessingCancellation();
                if (tiles_.size() == cachedTiles) {
                    const auto oldest = std::min_element(tiles_.begin(), tiles_.end(),
                        [](const auto& a, const auto& b) { return a.second.use < b.second.use; });
                    if (&oldest->second == lastTile_) {
                        lastTile_ = nullptr;
                        lastLeft_ = std::numeric_limits<uint32_t>::max();
                        lastTop_ = std::numeric_limits<uint32_t>::max();
                    }
                    tiles_.erase(oldest);
                }
                Tile fresh{std::vector<RGB>(tileEdge * tileEdge), 0};
                const size_t rowBytes = size_t(std::min(tileEdge, width_ - left)) * sizeof(RGB);
                for (uint32_t row = 0; row < std::min(tileEdge, height_ - top); ++row)
                    file_.read((uint64_t(top + row) * width_ + left) * sizeof(RGB), fresh.pixels.data() + row * tileEdge, rowBytes);
                found = tiles_.emplace(key, std::move(fresh)).first;
            }
            lastLeft_ = left;
            lastTop_ = top;
            lastTile_ = tile = &found->second;
        }
        tile->use = ++clock_;
        return tile->pixels[(uint32_t(y) - top) * tileEdge + uint32_t(x) - left];
    }
};

class RenderedRows {
    TileReader source_;
    bool hasGeometry_ = false;
    bool integerGeometry_ = false;
    int srcWidth_ = 0, srcHeight_ = 0, rotatedWidth_ = 0, rotatedHeight_ = 0, cropLeft_ = 0, cropTop_ = 0;
    GeometryOptions geometryOptions_;
    GeometryPixelSampler geometry_;
    GeometryPixelReader read_;
    std::pair<int, int> nativeSize_;
    uint32_t width_, height_, first_ = std::numeric_limits<uint32_t>::max();
    std::vector<RGB> rows_;
    float* headroom_;
    std::optional<PhotoEffectSampler> effects_;
    std::optional<HDRDetailPlan> detail_;
    double peak_ = 0;

    RGB readIntegerGeometry(int x, int y) {
        int px = cropLeft_ + x;
        int py = cropTop_ + y;
        if (geometryOptions_.flip_horizontal) px = rotatedWidth_ - 1 - px;
        if (geometryOptions_.flip_vertical) py = rotatedHeight_ - 1 - py;
        switch (geometryOptions_.quarter_turns) {
            case 1: return source_.read(py, srcHeight_ - 1 - px);
            case 2: return source_.read(srcWidth_ - 1 - px, srcHeight_ - 1 - py);
            case 3: return source_.read(srcWidth_ - 1 - py, px);
            default: return source_.read(px, py);
        }
    }

    template<class Reader, class Write>
    void sampleBandWithReader(uint32_t first, uint32_t end, const Reader& reader, const Write& write) {
        // 输出按小块访问，90° 旋转时不让每行反复淘汰整列源块。
        for (uint32_t left = 0; left < width_; left += tileEdge) for (uint32_t row = first; row < end; ++row) {
            checkProcessingCancellation();
            for (uint32_t x = left; x < std::min(left + tileEdge, width_); ++x)
                write(x, row, sampleResample(x, row, nativeSize_.first, nativeSize_.second, width_, height_, reader));
        }
    }

    template<class Write> void sampleBand(uint32_t first, uint32_t end, const Write& write) {
        if (!hasGeometry_) {
            sampleBandWithReader(first, end, [this](int sx, int sy) { return source_.read(sx, sy); }, write);
        } else if (integerGeometry_) {
            sampleBandWithReader(first, end, [this](int sx, int sy) { return readIntegerGeometry(sx, sy); }, write);
        } else {
            sampleBandWithReader(first, end, [this](int sx, int sy) { return geometry_(sx, sy, read_); }, write);
        }
    }

    RGB finishPixel(RGB p, int x, int y) {
        if (effects_) p = effects_->applyExtendedLinear(p, x, y, peak_);
        const float luminance = .2126f * p.r + .7152f * p.g + .0722f * p.b;
        if (!std::isfinite(p.r) || !std::isfinite(p.g) || !std::isfinite(p.b) || !std::isfinite(luminance))
            throw std::overflow_error("HDR streamed canvas exceeded finite float range");
        if (headroom_) *headroom_ = std::max(*headroom_, luminance);
        return p;
    }
public:
    RenderedRows(const fs::path& path, const HDRRowSource& source, const HDRRenderOptions& options,
        uint32_t width, uint32_t height, float* headroom) : source_(path, source.width, source.height),
        hasGeometry_(options.geometry.active()),
        integerGeometry_(hasGeometry_ && options.geometry.straighten_degrees == 0 &&
            options.geometry.perspective_horizontal == 0 && options.geometry.perspective_vertical == 0),
        srcWidth_(int(source.width)), srcHeight_(int(source.height)),
        rotatedWidth_(options.geometry.quarter_turns % 2 ? srcHeight_ : srcWidth_),
        rotatedHeight_(options.geometry.quarter_turns % 2 ? srcWidth_ : srcHeight_),
        cropLeft_(integerGeometry_ ? static_cast<int>(std::floor(double(options.geometry.crop_x) * rotatedWidth_)) : 0),
        cropTop_(integerGeometry_ ? static_cast<int>(std::floor(double(options.geometry.crop_y) * rotatedHeight_)) : 0),
        geometryOptions_(options.geometry),
        geometry_(hasGeometry_ && !integerGeometry_ ? makeGeometrySampler(source.width, source.height, options.geometry) : GeometryPixelSampler{}),
        read_(hasGeometry_ && !integerGeometry_ ? GeometryPixelReader([this](int x, int y) { return source_.read(x, y); }) : GeometryPixelReader{}),
        nativeSize_(geometryOutputSize(source.width, source.height, options.geometry)),
        width_(width), height_(height), rows_(size_t(width) * std::min(tileEdge, height)), headroom_(headroom) {
        if (headroom_ && options.rendition.peakLimitEV > 0) peak_ = std::exp2(double(options.rendition.peakLimitEV));
        if (options.hasPhotoEffects()) effects_.emplace(options.effects, width, height);
        if (options.hasDetail()) {
            if (!hasGeometry_) {
                detail_ = planHDRDetail(width, height, options.detail, peak_, [&](int x, int y) {
                    return sampleResample(x, y, nativeSize_.first, nativeSize_.second, width_, height_,
                        [this](int sx, int sy) { return source_.read(sx, sy); });
                });
            } else if (integerGeometry_) {
                detail_ = planHDRDetail(width, height, options.detail, peak_, [&](int x, int y) {
                    return sampleResample(x, y, nativeSize_.first, nativeSize_.second, width_, height_,
                        [this](int sx, int sy) { return readIntegerGeometry(sx, sy); });
                });
            } else {
                detail_ = planHDRDetail(width, height, options.detail, peak_, [&](int x, int y) {
                    return sampleResample(x, y, nativeSize_.first, nativeSize_.second, width_, height_,
                        [this](int sx, int sy) { return geometry_(sx, sy, read_); });
                });
            }
        }
    }

    const RGB* row(uint32_t y) {
        const uint32_t first = y / tileEdge * tileEdge;
        if (first != first_) {
            const uint32_t end = std::min(first + tileEdge, height_);
            if (detail_) {
                const uint32_t halo = detail_->halo;
                const uint32_t top = first > halo ? first - halo : 0;
                const uint32_t bottom = std::min(height_, end + halo);
                std::vector<RGB> input(size_t(width_) * (bottom - top));
                sampleBand(top, bottom, [&](uint32_t x, uint32_t y, RGB p) { input[size_t(y - top) * width_ + x] = p; });
                renderHDRDetailBand(*detail_, input.data(), top, bottom - top, rows_.data(), first, end - first);
                for (uint32_t row = first; row < end; ++row) {
                    checkProcessingCancellation();
                    for (uint32_t x = 0; x < width_; ++x) {
                        auto& p = rows_[size_t(row - first) * width_ + x];
                        p = finishPixel(p, x, row);
                    }
                }
            } else {
                sampleBand(first, end, [&](uint32_t x, uint32_t y, RGB p) {
                    rows_[size_t(y - first) * width_ + x] = finishPixel(p, x, y);
                });
            }
            first_ = first;
        }
        return rows_.data() + size_t(y - first_) * width_;
    }
};

HDRStreamResult streamShape(const HDRRowSource& source, const HDRRenderOptions& options) {
    validateHDRRenderOptions(options);
    if (!source.width || !source.height || source.width > 65535 || source.height > 65535 ||
        uint64_t(source.width) * source.height > 128000000 || !source.read || !source.finish ||
        options.intent != HDRQuality::Final)
        throw std::invalid_argument("Invalid complete HDR stream source or output settings");
    checkProcessingCancellation();
    HDRStreamResult result;
    const auto native = geometryOutputSize(source.width, source.height, options.geometry);
    const auto size = hdrResizeSize(native.first, native.second, options.longEdge);
    result.width = size.first; result.height = size.second;
    result.outputNativeWidth = native.first; result.outputNativeHeight = native.second;
    return result;
}

void stageSource(const HDRRowSource& source, const HDRRenderOptions& options,
    HDRStreamResult& result, const Directory& scratch) {
    admitMemory(uint64_t(source.width) * std::min(decodeRows, source.height) * sizeof(RGB) + (32ull << 20));
    for (bool hdr : {true, false}) {
        File file(scratch.path / (hdr ? "hdr.rgb32f" : "sdr.rgb32f"), true);
        for (uint32_t row = 0; row < source.height; row += decodeRows) {
            checkProcessingCancellation();
            ImageData strip(source.width, std::min(decodeRows, source.height - row));
            const float missing = std::numeric_limits<float>::quiet_NaN();
            std::fill(strip.pixels.begin(), strip.pixels.end(), RGB(missing, missing, missing));
            source.read(hdr, row, strip.height, strip.pixels.data());
            checkProcessingCancellation();
            if (hdr) for (const auto& p : strip.pixels) {
                const float y = .2126f * p.r + .7152f * p.g + .0722f * p.b;
                if (!std::isfinite(y)) throw std::invalid_argument("Nonfinite HDR source headroom");
                result.sourceHeadroom = std::max(result.sourceHeadroom, y);
            }
            editHDRPixels(strip, options, hdr);
            file.append(strip.pixels.data(), strip.pixels.size() * sizeof(RGB));
        }
    }
    source.finish(); checkProcessingCancellation();
    uint64_t extra = 0;
    if (options.hasDetail()) {
        const uint32_t halo = options.detail.halo(result.width, result.height);
        extra = uint64_t(result.width) * std::min(result.height, tileEdge + 2 * halo) * (sizeof(RGB) + sizeof(float));
    }
    admitMemory(uint64_t(result.width) * tileEdge * 20 + (32ull << 20) + extra);
}
}

HDRStreamFiles renderStreamFiles(const HDRRowSource& source, const HDRRenderOptions& options,
    bool includeHDR, const fs::path& temporaryRoot) {
    HDRStreamFiles output;
    output.result = streamShape(source, options);
    const uint64_t outputPixels = uint64_t(output.result.width) * output.result.height;
    // 完整源双平面、输出浮点文件与成片空间一并准入，避免中途才发现磁盘不足。
    const uint64_t requiredBytes = uint64_t(source.width) * source.height * 24 +
        outputPixels * (includeHDR ? 40 : 24) + (64ull << 20);
    auto scratch = std::make_shared<Directory>(temporaryRoot, requiredBytes);
    stageSource(source, options, output.result, *scratch);
    output.sdr = scratch->path / "rendered-sdr.rgb32f";
    if (includeHDR) output.hdr = scratch->path / "rendered-hdr.rgb32f";
    output.result.editedHeadroom = includeHDR ? 1 : 0;
    for (bool hdr : {true, false}) {
        if (hdr && !includeHDR) continue;
        File file(hdr ? output.hdr : output.sdr, true);
        RenderedRows rows(scratch->path / (hdr ? "hdr.rgb32f" : "sdr.rgb32f"), source, options,
            output.result.width, output.result.height, hdr ? &output.result.editedHeadroom : nullptr);
        for (uint32_t row = 0; row < output.result.height; ++row) {
            checkProcessingCancellation();
            const auto* pixels = rows.row(row);
            if (hdr) for (uint32_t x = 0; x < output.result.width; ++x)
                output.rgbHeadroom = std::max({output.rgbHeadroom, pixels[x].r, pixels[x].g, pixels[x].b});
            file.append(pixels, size_t(output.result.width) * sizeof(RGB));
        }
    }
    output.directory = std::move(scratch);
    return output;
}

uint64_t streamScratchBytes(uint32_t width, uint32_t height, const HDRRenderOptions& options, bool hdr) {
    validateHDRRenderOptions(options);
    if (!width || !height || width > 65535 || height > 65535 || uint64_t(width) * height > 128000000)
        throw std::invalid_argument("Invalid complete HDR stream dimensions");
    const auto native = geometryOutputSize(width, height, options.geometry);
    const auto output = hdrResizeSize(native.first, native.second, options.longEdge);
    if (output.first > 65500 || output.second > 65500) throw std::invalid_argument("Stream output exceeds JPEG limits");
    return uint64_t(width) * height * 24 + uint64_t(output.first) * output.second * (hdr ? 20 : 4) + (64ull << 20);
}

HDRStreamResult encodeStream(const HDRRowSource& source, const HDRRenderOptions& options,
    bool highDynamicRange, uint32_t quality, uint32_t baseColor, const fs::path& temporaryRoot) {
    if (quality < 1 || quality > 100 ||
        (baseColor != kHdrColorSrgb && baseColor != kHdrColorDisplayP3))
        throw std::invalid_argument("Invalid complete HDR stream source or output settings");
    HDRStreamResult result = streamShape(source, options);
    if (result.width > 65500 || result.height > 65500) throw std::invalid_argument("Stream output exceeds JPEG limits");
    const uint64_t outputPixels = uint64_t(result.width) * result.height;
    // 两份浮点源、紧凑编码输入及压缩产物；不依赖稀疏文件虚报可用空间。
    const uint64_t requiredBytes = streamScratchBytes(source.width, source.height, options, highDynamicRange);
    auto scratch = std::make_shared<Directory>(temporaryRoot, requiredBytes);
    stageSource(source, options, result, *scratch);
    const auto high = scratch->path / "hdr.rgb32f", low = scratch->path / "sdr.rgb32f";
    if (!highDynamicRange) {
        RenderedRows rows(low, source, options, result.width, result.height, nullptr);
        result.jpeg = encodeSDRJPEGRows(result.width, result.height, quality, [&](uint32_t y) { return rows.row(y); });
        return result;
    }
    const auto packedHigh = scratch->path / "hdr.rgba16f", packedLow = scratch->path / "sdr.rgba8";
    float capacity = 1;
    result.editedHeadroom = 1;
    for (bool hdr : {true, false}) {
        File file(hdr ? packedHigh : packedLow, true);
        RenderedRows rows(hdr ? high : low, source, options, result.width, result.height, hdr ? &result.editedHeadroom : nullptr);
        std::vector<uint16_t> packed(size_t(result.width) * (hdr ? 4 : 2));
        for (uint32_t row = 0; row < result.height; ++row) {
            checkProcessingCancellation();
            capacity = std::max(capacity, packJPEGInput(rows.row(row), result.width, hdr, baseColor, packed.data()));
            file.append(packed.data(), size_t(result.width) * (hdr ? 8 : 4));
        }
    }
    // libultrahdr 2.0.2 主要同时存活缓冲为 33 B/pixel；保留 42 B/pixel 覆盖
    // 对齐、压缩与 allocator 滞留，再留 128 MiB 固定余量。系统余量由准入函数另留。
    admitStreamingMemory(outputPixels * 42 + (128ull << 20));
    result.jpeg = encodeJPEGInputs(result.width, result.height, quality, baseColor, capacity,
        [&](bool hdr, const std::function<void(const void*)>& consume) {
            Mapping input(hdr ? packedHigh : packedLow, size_t(outputPixels) * (hdr ? 8 : 4));
            consume(input.data());
        });
    return result;
}
}
