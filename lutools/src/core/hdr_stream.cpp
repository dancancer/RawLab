#include "core/hdr_stream.h"
#include "core/hdr_detail.h"
#include "core/hdr_progress.h"
#include "core/hdr_resample.h"
#include "core/hdr_storage.h"
#include "core/hdr_jpeg.h"
#include "core/parallel_pixels.h"
#include "core/processing_cancellation.h"
#include "platform/hdr_image.h"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <limits>
#include <mutex>
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

bool isDirectStripEligible(const HDRRowSource& source, const HDRRenderOptions& options, const HDRStreamResult& result) {
    return !options.geometry.active() &&
        result.width == source.width &&
        result.height == source.height &&
        !options.hasDetail() &&
        options.outputSharpening == OutputSharpening::Off;
}

// 128x128 物理分块平面：总字节严格等于 width*height*sizeof(RGB)（无尾部浪费），
// 且每个 128x128（或边缘 tw x th）块在磁盘上完全连续，将 TileReader 缺失读降为单次 pread。
uint64_t tilePlaneOffset(uint32_t width, uint32_t left, uint32_t top, uint32_t tileHeight) {
    return (uint64_t(top) * width + uint64_t(left) * tileHeight) * sizeof(RGB);
}

class TileReader {
    struct Tile { std::vector<RGB> pixels; uint64_t use; uint32_t stride; };
    const File& file_;
    uint32_t width_, height_;
    uint64_t clock_ = 0;
    uint32_t lastLeft_ = std::numeric_limits<uint32_t>::max();
    uint32_t lastTop_ = std::numeric_limits<uint32_t>::max();
    Tile* lastTile_ = nullptr;
    std::unordered_map<uint64_t, Tile> tiles_;
public:
    TileReader(const File& file, uint32_t width, uint32_t height)
        : file_(file), width_(width), height_(height) {}
    RGB read(int x, int y) {
        const uint32_t left = uint32_t(x) / tileEdge * tileEdge;
        const uint32_t top = uint32_t(y) / tileEdge * tileEdge;
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
                const uint32_t tileWidth = std::min(tileEdge, width_ - left);
                const uint32_t tileHeight = std::min(tileEdge, height_ - top);
                Tile fresh{std::vector<RGB>(size_t(tileWidth) * tileHeight), 0, tileWidth};
                file_.read(tilePlaneOffset(width_, left, top, tileHeight),
                           fresh.pixels.data(),
                           fresh.pixels.size() * sizeof(RGB));
                found = tiles_.emplace(key, std::move(fresh)).first;
            }
            lastLeft_ = left;
            lastTop_ = top;
            lastTile_ = tile = &found->second;
        }
        tile->use = ++clock_;
        return tile->pixels[size_t(uint32_t(y) - top) * tile->stride + (uint32_t(x) - left)];
    }
};

void writeTiledBand(File& file, uint32_t width, uint32_t bandHeight, const RGB* rows,
                    std::vector<RGB>& packed) {
    if (!bandHeight) return;
    const uint32_t tilesX = (width + tileEdge - 1) / tileEdge;
    packed.resize(size_t(width) * bandHeight);
    RGB* cursor = packed.data();
    for (uint32_t tx = 0; tx < tilesX; ++tx) {
        const uint32_t left = tx * tileEdge;
        const uint32_t tw = std::min(tileEdge, width - left);
        for (uint32_t r = 0; r < bandHeight; ++r) {
            std::memcpy(cursor, rows + size_t(r) * width + left, size_t(tw) * sizeof(RGB));
            cursor += tw;
        }
    }
    file.append(packed.data(), size_t(width) * bandHeight * sizeof(RGB));
}

void validateAndUpdateSourceHeadroom(const ImageData& strip, float& sourceHeadroom) {
    std::atomic<bool> nonfinite{false};
    float bandPeak = sourceHeadroom;
    std::mutex peakMutex;
    parallelPixelRanges(strip.pixels.size(), [&](size_t first, size_t last) {
        float localPeak = sourceHeadroom;
        for (size_t i = first; i < last; ++i) {
            const auto& p = strip.pixels[i];
            const float y = .2126f * p.r + .7152f * p.g + .0722f * p.b;
            if (!std::isfinite(p.r) || !std::isfinite(p.g) || !std::isfinite(p.b) || !std::isfinite(y)) {
                nonfinite.store(true, std::memory_order_relaxed);
                return;
            }
            localPeak = std::max(localPeak, y);
        }
        std::lock_guard<std::mutex> lock(peakMutex);
        bandPeak = std::max(bandPeak, localPeak);
    });
    if (nonfinite.load(std::memory_order_relaxed)) {
        throw std::invalid_argument("Nonfinite HDR source headroom");
    }
    sourceHeadroom = bandPeak;
}

void applyStripEffects(ImageData& strip, uint32_t yOffset, const std::optional<PhotoEffectSampler>& effects,
                       double peak) {
    if (!effects) return;
    std::atomic<bool> overflow{false};
    parallelRowRanges(strip.height, strip.width, [&](int firstRow, int lastRow) {
        for (int localY = firstRow; localY < lastRow; ++localY) {
            RGB* row = strip.pixels.data() + size_t(localY) * strip.width;
            const int globalY = int(yOffset) + localY;
            for (int x = 0; x < strip.width; ++x) {
                RGB p = effects->applyExtendedLinear(row[x], x, globalY, peak);
                if (!std::isfinite(p.r) || !std::isfinite(p.g) || !std::isfinite(p.b)) {
                    overflow.store(true, std::memory_order_relaxed);
                    return;
                }
                row[x] = p;
            }
        }
    });
    if (overflow.load(std::memory_order_relaxed)) {
        throw std::overflow_error("HDR streamed canvas exceeded finite float range");
    }
}

void accumulateHDRHeadroomAndFinite(const ImageData& strip, float& editedHeadroom) {
    std::atomic<bool> overflow{false};
    float bandMax = editedHeadroom;
    std::mutex maxMutex;
    parallelPixelRanges(strip.pixels.size(), [&](size_t first, size_t last) {
        float localMax = bandMax;
        for (size_t i = first; i < last; ++i) {
            const auto& p = strip.pixels[i];
            const float y = .2126f * p.r + .7152f * p.g + .0722f * p.b;
            if (!std::isfinite(p.r) || !std::isfinite(p.g) || !std::isfinite(p.b) || !std::isfinite(y)) {
                overflow.store(true, std::memory_order_relaxed);
                return;
            }
            localMax = std::max(localMax, y);
        }
        std::lock_guard<std::mutex> lock(maxMutex);
        bandMax = std::max(bandMax, localMax);
    });
    if (overflow.load(std::memory_order_relaxed)) {
        throw std::overflow_error("HDR streamed canvas exceeded finite float range");
    }
    editedHeadroom = bandMax;
}

class RenderedRows {
    File file_;
    uint32_t srcW_ = 0, srcH_ = 0;
    bool hasGeometry_ = false;
    bool integerGeometry_ = false;
    int srcWidth_ = 0, srcHeight_ = 0, rotatedWidth_ = 0, rotatedHeight_ = 0, cropLeft_ = 0, cropTop_ = 0;
    GeometryOptions geometryOptions_;
    GeometryPixelSampler geometry_;
    std::optional<HDRDetailPlan> detail_;
    OutputSharpening outputSharpening_ = OutputSharpening::Off;
    std::pair<int, int> nativeSize_;
    uint32_t width_, height_, first_ = std::numeric_limits<uint32_t>::max(), currentEnd_ = 0;
    std::vector<RGB> rows_;
    float* headroom_;
    std::optional<PhotoEffectSampler> effects_;
    double peak_ = 0;
    std::mutex readerPoolMutex_;
    std::vector<std::unique_ptr<TileReader>> readerPool_;

    struct LeasedReader {
        RenderedRows& owner;
        std::unique_ptr<TileReader> reader;
        LeasedReader(RenderedRows& o) : owner(o) {
            std::lock_guard<std::mutex> lock(owner.readerPoolMutex_);
            if (!owner.readerPool_.empty()) {
                reader = std::move(owner.readerPool_.back());
                owner.readerPool_.pop_back();
            } else {
                reader = std::make_unique<TileReader>(owner.file_, owner.srcW_, owner.srcH_);
            }
        }
        ~LeasedReader() {
            std::lock_guard<std::mutex> lock(owner.readerPoolMutex_);
            owner.readerPool_.push_back(std::move(reader));
        }
    };

    RGB readIntegerGeometryWith(TileReader& src, int x, int y) const {
        int px = cropLeft_ + x;
        int py = cropTop_ + y;
        if (geometryOptions_.flip_horizontal) px = rotatedWidth_ - 1 - px;
        if (geometryOptions_.flip_vertical) py = rotatedHeight_ - 1 - py;
        switch (geometryOptions_.quarter_turns) {
            case 1: return src.read(py, srcHeight_ - 1 - px);
            case 2: return src.read(srcWidth_ - 1 - px, srcHeight_ - 1 - py);
            case 3: return src.read(srcWidth_ - 1 - py, px);
            default: return src.read(px, py);
        }
    }

    template<class Reader>
    void sampleBandGeneric(uint32_t first, uint32_t end, const Reader& makeReader,
                           const std::function<void(uint32_t, uint32_t, RGB)>& write) {
        const uint32_t totalRows = end - first;
        if (!totalRows) return;
        // 按行范围并行切分（parallelRowRanges），每线程借用一个 TileReader，并在行块内按 128 列切分保持旋转局部性。
        parallelRowRanges(int(totalRows), int(width_), [&](int r0, int r1) {
            LeasedReader lease(*this);
            TileReader& src = *lease.reader;
            auto reader = makeReader(src);
            for (uint32_t left = 0; left < width_; left += tileEdge) {
                const uint32_t right = std::min(left + tileEdge, width_);
                for (int r = r0; r < r1; ++r) {
                    const uint32_t row = first + uint32_t(r);
                    for (uint32_t x = left; x < right; ++x) {
                        write(x, row, sampleResample(int(x), int(row), nativeSize_.first, nativeSize_.second,
                                                     int(width_), int(height_), reader));
                    }
                }
            }
        });
    }

    template<class Write>
    void sampleBand(uint32_t first, uint32_t end, const Write& write) {
        if (!hasGeometry_) {
            sampleBandGeneric(first, end, [](TileReader& src) {
                return [&src](int sx, int sy) { return src.read(sx, sy); };
            }, write);
        } else if (integerGeometry_) {
            sampleBandGeneric(first, end, [this](TileReader& src) {
                return [this, &src](int sx, int sy) { return readIntegerGeometryWith(src, sx, sy); };
            }, write);
        } else {
            sampleBandGeneric(first, end, [this](TileReader& src) {
                return [this, &src](int sx, int sy) {
                    GeometryPixelReader pixelReader([&src](int gx, int gy) { return src.read(gx, gy); });
                    return geometry_(sx, sy, pixelReader);
                };
            }, write);
        }
    }

    RGB finishPixel(RGB p, int x, int y, float& localHeadroom, bool& overflow) const {
        if (effects_) p = effects_->applyExtendedLinear(p, x, y, peak_);
        const float luminance = .2126f * p.r + .7152f * p.g + .0722f * p.b;
        if (!std::isfinite(p.r) || !std::isfinite(p.g) || !std::isfinite(p.b) || !std::isfinite(luminance)) {
            overflow = true;
            return p;
        }
        localHeadroom = std::max(localHeadroom, luminance);
        return p;
    }

    void prepareBand(uint32_t first) {
        const uint32_t end = std::min(first + tileEdge, height_);
        const uint32_t bandRows = end - first;
        if (detail_ || outputSharpening_ != OutputSharpening::Off) {
            const uint32_t sharpHalo = outputSharpening_ != OutputSharpening::Off ? 1u : 0u;
            const uint32_t midTop = first > sharpHalo ? first - sharpHalo : 0;
            const uint32_t midBottom = std::min(height_, end + sharpHalo);
            const uint32_t midRows = midBottom - midTop;
            std::vector<RGB> sharpenedInput;
            RGB* midDst = rows_.data();
            if (sharpHalo > 0) {
                sharpenedInput.resize(size_t(width_) * midRows);
                midDst = sharpenedInput.data();
            }
            if (detail_) {
                const uint32_t halo = detail_->halo;
                const uint32_t top = midTop > halo ? midTop - halo : 0;
                const uint32_t bottom = std::min(height_, midBottom + halo);
                std::vector<RGB> input(size_t(width_) * (bottom - top));
                sampleBand(top, bottom, [&](uint32_t x, uint32_t y, RGB p) {
                    input[size_t(y - top) * width_ + x] = p;
                });
                renderHDRDetailBand(*detail_, input.data(), int(top), int(bottom - top), midDst, int(midTop), int(midRows));
            } else {
                sampleBand(midTop, midBottom, [&](uint32_t x, uint32_t y, RGB p) {
                    midDst[size_t(y - midTop) * width_ + x] = p;
                });
            }
            if (sharpHalo > 0) {
                if (effects_) {
                    std::atomic<bool> overflow{false};
                    parallelRowRanges(int(midRows), int(width_), [&](int r0, int r1) {
                        bool localOverflow = false;
                        for (int r = r0; r < r1; ++r) {
                            const uint32_t row = midTop + uint32_t(r);
                            RGB* dst = midDst + size_t(r) * width_;
                            for (uint32_t x = 0; x < width_; ++x) {
                                RGB p = effects_->applyExtendedLinear(dst[x], int(x), int(row), peak_);
                                if (!std::isfinite(p.r) || !std::isfinite(p.g) || !std::isfinite(p.b)) {
                                    localOverflow = true;
                                    break;
                                }
                                dst[x] = p;
                            }
                            if (localOverflow) break;
                        }
                        if (localOverflow) overflow.store(true, std::memory_order_relaxed);
                    });
                    if (overflow.load(std::memory_order_relaxed))
                        throw std::overflow_error("HDR streamed canvas exceeded finite float range");
                }
                renderHDROutputSharpeningBand(outputSharpening_, int(width_), int(height_),
                    headroom_ ? peak_ : 0.0, midDst, int(midTop), int(midRows),
                    rows_.data(), int(first), int(bandRows));
                std::vector<float> rowMax(bandRows, 0.0f);
                std::atomic<bool> overflow{false};
                parallelRowRanges(int(bandRows), int(width_), [&](int r0, int r1) {
                    bool localOverflow = false;
                    for (int r = r0; r < r1; ++r) {
                        float maxLum = 0.0f;
                        const RGB* dst = rows_.data() + size_t(r) * width_;
                        for (uint32_t x = 0; x < width_; ++x) {
                            const float luminance = .2126f * dst[x].r + .7152f * dst[x].g + .0722f * dst[x].b;
                            if (!std::isfinite(dst[x].r) || !std::isfinite(dst[x].g) || !std::isfinite(dst[x].b) || !std::isfinite(luminance)) {
                                localOverflow = true;
                                break;
                            }
                            maxLum = std::max(maxLum, luminance);
                        }
                        if (localOverflow) break;
                        rowMax[size_t(r)] = maxLum;
                    }
                    if (localOverflow) overflow.store(true, std::memory_order_relaxed);
                });
                if (overflow.load(std::memory_order_relaxed))
                    throw std::overflow_error("HDR streamed canvas exceeded finite float range");
                if (headroom_) {
                    for (float v : rowMax) *headroom_ = std::max(*headroom_, v);
                }
            } else {
                std::vector<float> rowMax(bandRows, 0.0f);
                std::atomic<bool> overflow{false};
                parallelRowRanges(int(bandRows), int(width_), [&](int r0, int r1) {
                    bool localOverflow = false;
                    for (int r = r0; r < r1; ++r) {
                        const uint32_t row = first + uint32_t(r);
                        float maxLum = 0.0f;
                        RGB* dst = rows_.data() + size_t(r) * width_;
                        for (uint32_t x = 0; x < width_; ++x) {
                            dst[x] = finishPixel(dst[x], int(x), int(row), maxLum, localOverflow);
                        }
                        rowMax[size_t(r)] = maxLum;
                    }
                    if (localOverflow) overflow.store(true, std::memory_order_relaxed);
                });
                if (overflow.load(std::memory_order_relaxed))
                    throw std::overflow_error("HDR streamed canvas exceeded finite float range");
                if (headroom_) {
                    for (float v : rowMax) *headroom_ = std::max(*headroom_, v);
                }
            }
        } else {
            std::vector<float> rowMax(bandRows, 0.0f);
            std::atomic<bool> overflow{false};
            const uint32_t totalRows = end - first;
            parallelRowRanges(int(totalRows), int(width_), [&](int r0, int r1) {
                LeasedReader lease(*this);
                TileReader& src = *lease.reader;
                bool localOverflow = false;
                auto eval = [&](auto& sampler) {
                    for (uint32_t left = 0; left < width_; left += tileEdge) {
                        const uint32_t right = std::min(left + tileEdge, width_);
                        for (int r = r0; r < r1; ++r) {
                            const uint32_t row = first + uint32_t(r);
                            RGB* dst = rows_.data() + size_t(r) * width_;
                            for (uint32_t x = left; x < right; ++x) {
                                RGB p = sampleResample(int(x), int(row), nativeSize_.first, nativeSize_.second,
                                                       int(width_), int(height_), sampler);
                                dst[x] = finishPixel(p, int(x), int(row), rowMax[size_t(r)], localOverflow);
                            }
                        }
                    }
                };
                if (!hasGeometry_) {
                    auto reader = [&src](int sx, int sy) { return src.read(sx, sy); };
                    eval(reader);
                } else if (integerGeometry_) {
                    auto reader = [this, &src](int sx, int sy) { return readIntegerGeometryWith(src, sx, sy); };
                    eval(reader);
                } else {
                    GeometryPixelReader pixelReader([&src](int gx, int gy) { return src.read(gx, gy); });
                    auto reader = [this, &pixelReader](int sx, int sy) { return geometry_(sx, sy, pixelReader); };
                    eval(reader);
                }
                if (localOverflow) overflow.store(true, std::memory_order_relaxed);
            });
            if (overflow.load(std::memory_order_relaxed))
                throw std::overflow_error("HDR streamed canvas exceeded finite float range");
            if (headroom_) {
                for (float v : rowMax) *headroom_ = std::max(*headroom_, v);
            }
        }
        first_ = first;
        currentEnd_ = end;
    }

public:
    RenderedRows(const fs::path& path, const HDRRowSource& source, const HDRRenderOptions& options,
        uint32_t width, uint32_t height, float* headroom)
        : file_(path), srcW_(source.width), srcH_(source.height),
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
        outputSharpening_(options.outputSharpening),
        nativeSize_(geometryOutputSize(source.width, source.height, options.geometry)),
        width_(width), height_(height), rows_(size_t(width) * std::min(tileEdge, height)), headroom_(headroom) {
        if (headroom_ && options.rendition.peakLimitEV > 0) peak_ = std::exp2(double(options.rendition.peakLimitEV));
        if (options.hasPhotoEffects()) effects_.emplace(options.effects, width, height);
        if (options.hasDetail()) {
            // planHDRDetail 仅在单线程构造期读中心周边若干像素或估算全局直方图，复用 LeasedReader。
            LeasedReader lease(*this);
            TileReader& src = *lease.reader;
            if (!hasGeometry_) {
                detail_ = planHDRDetail(width, height, options.detail, peak_, [&](int x, int y) {
                    return sampleResample(x, y, nativeSize_.first, nativeSize_.second, width_, height_,
                        [&src](int sx, int sy) { return src.read(sx, sy); });
                });
            } else if (integerGeometry_) {
                detail_ = planHDRDetail(width, height, options.detail, peak_, [&](int x, int y) {
                    return sampleResample(x, y, nativeSize_.first, nativeSize_.second, width_, height_,
                        [this, &src](int sx, int sy) { return readIntegerGeometryWith(src, sx, sy); });
                });
            } else {
                GeometryPixelReader pixelReader([&src](int gx, int gy) { return src.read(gx, gy); });
                detail_ = planHDRDetail(width, height, options.detail, peak_, [&](int x, int y) {
                    return sampleResample(x, y, nativeSize_.first, nativeSize_.second, width_, height_,
                        [this, &pixelReader](int sx, int sy) { return geometry_(sx, sy, pixelReader); });
                });
            }
        }
    }

    const RGB* row(uint32_t y) {
        const uint32_t first = y / tileEdge * tileEdge;
        if (first != first_) {
            prepareBand(first);
        }
        return rows_.data() + size_t(y - first_) * width_;
    }

    const RGB* band(uint32_t bandFirst, uint32_t& outBandRows) {
        prepareBand(bandFirst);
        outBandRows = currentEnd_ - first_;
        return rows_.data();
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
    HDRStreamResult& result, const Directory& scratch, bool includeHDR) {
    admitMemory(uint64_t(source.width) * std::min(decodeRows, source.height) * sizeof(RGB) + (32ull << 20));
    std::vector<RGB> tileScratch;
    const uint32_t totalWork = (includeHDR ? source.height : 0) + source.height;
    uint32_t completedWork = 0;
    for (bool hdr : {true, false}) {
        std::optional<File> file;
        if (!hdr || includeHDR) {
            file.emplace(scratch.path / (hdr ? "hdr.rgb32f" : "sdr.rgb32f"), true);
        }
        for (uint32_t row = 0; row < source.height; row += decodeRows) {
            checkProcessingCancellation();
            ImageData strip(source.width, std::min(decodeRows, source.height - row));
            const float missing = std::numeric_limits<float>::quiet_NaN();
            std::fill(strip.pixels.begin(), strip.pixels.end(), RGB(missing, missing, missing));
            source.read(hdr, row, strip.height, strip.pixels.data());
            checkProcessingCancellation();
            if (hdr) {
                validateAndUpdateSourceHeadroom(strip, result.sourceHeadroom);
                if (!includeHDR) continue;
            }
            editHDRPixels(strip, options, hdr);
            // 按 128 行一个 tile 带写入物理分块布局，免去 TileReader 每块 128 次 pread 系统调用。
            const uint32_t firstBandRows = std::min(tileEdge, uint32_t(strip.height));
            writeTiledBand(*file, source.width, firstBandRows, strip.pixels.data(), tileScratch);
            if (uint32_t(strip.height) > firstBandRows) {
                writeTiledBand(*file, source.width, uint32_t(strip.height) - firstBandRows,
                               strip.pixels.data() + size_t(firstBandRows) * source.width, tileScratch);
            }
            completedWork += uint32_t(strip.height);
            reportHdrProgress(completedWork, totalWork);
        }
    }
    source.finish(); checkProcessingCancellation();
    uint64_t extra = 0;
    if (options.hasDetail() || options.outputSharpening != OutputSharpening::Off) {
        const uint32_t sharpHalo = options.outputSharpening != OutputSharpening::Off ? 1u : 0u;
        const uint32_t halo = (options.hasDetail() ? options.detail.halo(result.width, result.height) : 0u) + sharpHalo;
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

    if (isDirectStripEligible(source, options, output.result)) {
        admitMemory(uint64_t(source.width) * std::min(decodeRows, source.height) * sizeof(RGB) + (32ull << 20));
        output.sdr = scratch->path / "rendered-sdr.rgb32f";
        if (includeHDR) output.hdr = scratch->path / "rendered-hdr.rgb32f";
        output.result.editedHeadroom = includeHDR ? 1 : 0;
        std::optional<PhotoEffectSampler> effects;
        if (options.hasPhotoEffects()) effects.emplace(options.effects, output.result.width, output.result.height);
        const double peak = options.rendition.peakLimitEV > 0 ? std::exp2(double(options.rendition.peakLimitEV)) : 0;
        for (bool hdr : {true, false}) {
            std::optional<File> file;
            if (!hdr || includeHDR) file.emplace(hdr ? output.hdr : output.sdr, true);
            for (uint32_t row = 0; row < source.height; row += decodeRows) {
                checkProcessingCancellation();
                ImageData strip(source.width, std::min(decodeRows, source.height - row));
                const float missing = std::numeric_limits<float>::quiet_NaN();
                std::fill(strip.pixels.begin(), strip.pixels.end(), RGB(missing, missing, missing));
                source.read(hdr, row, strip.height, strip.pixels.data());
                checkProcessingCancellation();
                if (hdr) {
                    validateAndUpdateSourceHeadroom(strip, output.result.sourceHeadroom);
                    if (!includeHDR) continue;
                }
                editHDRPixels(strip, options, hdr);
                applyStripEffects(strip, row, effects, hdr ? peak : 0);
                if (hdr) {
                    accumulateHDRHeadroomAndFinite(strip, output.result.editedHeadroom);
                    float stripRgbMax = output.rgbHeadroom;
                    std::mutex rgbMutex;
                    parallelPixelRanges(strip.pixels.size(), [&](size_t first, size_t last) {
                        float localMax = stripRgbMax;
                        for (size_t i = first; i < last; ++i) {
                            const auto& p = strip.pixels[i];
                            localMax = std::max({localMax, p.r, p.g, p.b});
                        }
                        std::lock_guard<std::mutex> lock(rgbMutex);
                        stripRgbMax = std::max(stripRgbMax, localMax);
                    });
                    output.rgbHeadroom = stripRgbMax;
                }
                file->append(strip.pixels.data(), strip.pixels.size() * sizeof(RGB));
                const uint32_t base = hdr ? 0u : (includeHDR ? 500u : 250u);
                const uint32_t span = includeHDR ? 500u : 750u;
                reportHdrProgress(base + uint32_t((uint64_t(row + strip.height) * span) / source.height), 1000);
            }
        }
        source.finish(); checkProcessingCancellation();
        output.directory = std::move(scratch);
        reportHdrProgress(1000, 1000);
        return output;
    }

    {
        HdrProgressSubrangeScope sub(0, 450);
        stageSource(source, options, output.result, *scratch, includeHDR);
    }
    output.sdr = scratch->path / "rendered-sdr.rgb32f";
    if (includeHDR) output.hdr = scratch->path / "rendered-hdr.rgb32f";
    output.result.editedHeadroom = includeHDR ? 1 : 0;
    for (bool hdr : {true, false}) {
        if (hdr && !includeHDR) continue;
        File file(hdr ? output.hdr : output.sdr, true);
        RenderedRows rows(scratch->path / (hdr ? "hdr.rgb32f" : "sdr.rgb32f"), source, options,
            output.result.width, output.result.height, hdr ? &output.result.editedHeadroom : nullptr);
        for (uint32_t bandFirst = 0; bandFirst < output.result.height; bandFirst += tileEdge) {
            checkProcessingCancellation();
            uint32_t bandRows = 0;
            const RGB* pixels = rows.band(bandFirst, bandRows);
            if (hdr) {
                const size_t count = size_t(bandRows) * output.result.width;
                float bandRgbMax = output.rgbHeadroom;
                std::mutex rgbMutex;
                parallelPixelRanges(count, [&](size_t first, size_t last) {
                    float localMax = bandRgbMax;
                    for (size_t i = first; i < last; ++i) {
                        localMax = std::max({localMax, pixels[i].r, pixels[i].g, pixels[i].b});
                    }
                    std::lock_guard<std::mutex> lock(rgbMutex);
                    bandRgbMax = std::max(bandRgbMax, localMax);
                });
                output.rgbHeadroom = bandRgbMax;
            }
            file.append(pixels, size_t(bandRows) * output.result.width * sizeof(RGB));
            const uint32_t base = hdr ? 450u : (includeHDR ? 725u : 450u);
            const uint32_t span = includeHDR ? 275u : 550u;
            reportHdrProgress(base + uint32_t((uint64_t(bandFirst + bandRows) * span) / output.result.height), 1000);
        }
    }
    output.directory = std::move(scratch);
    reportHdrProgress(1000, 1000);
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
    bool highDynamicRange, uint32_t quality, uint32_t baseColor, const fs::path& temporaryRoot,
    const std::function<JPEGTransformBase(uint32_t, uint32_t)>& makeTransformBase) {
    if (quality < 1 || quality > 100 ||
        (baseColor != kHdrColorSrgb && baseColor != kHdrColorDisplayP3))
        throw std::invalid_argument("Invalid complete HDR stream source or output settings");
    HDRStreamResult result = streamShape(source, options);
    if (result.width > 65500 || result.height > 65500) throw std::invalid_argument("Stream output exceeds JPEG limits");
    const uint64_t outputPixels = uint64_t(result.width) * result.height;
    const JPEGTransformBase transformBase = (highDynamicRange && makeTransformBase)
        ? makeTransformBase(result.width, result.height)
        : JPEGTransformBase{};
    // 两份浮点源、紧凑编码输入及压缩产物；不依赖稀疏文件虚报可用空间。
    const uint64_t requiredBytes = streamScratchBytes(source.width, source.height, options, highDynamicRange);
    auto scratch = std::make_shared<Directory>(temporaryRoot, requiredBytes);

    if (isDirectStripEligible(source, options, result)) {
        admitMemory(uint64_t(source.width) * std::min(decodeRows, source.height) * sizeof(RGB) + (32ull << 20));
        std::optional<PhotoEffectSampler> effects;
        if (options.hasPhotoEffects()) effects.emplace(options.effects, result.width, result.height);
        const double peak = options.rendition.peakLimitEV > 0 ? std::exp2(double(options.rendition.peakLimitEV)) : 0;

        if (!highDynamicRange) {
            const auto stagedLow = scratch->path / "sdr.rgb32f";
            {
                File lowFile(stagedLow, true);
                for (bool hdr : {true, false}) {
                    for (uint32_t row = 0; row < source.height; row += decodeRows) {
                        checkProcessingCancellation();
                        ImageData strip(source.width, std::min(decodeRows, source.height - row));
                        const float missing = std::numeric_limits<float>::quiet_NaN();
                        std::fill(strip.pixels.begin(), strip.pixels.end(), RGB(missing, missing, missing));
                        source.read(hdr, row, strip.height, strip.pixels.data());
                        checkProcessingCancellation();
                        if (hdr) {
                            validateAndUpdateSourceHeadroom(strip, result.sourceHeadroom);
                            continue;
                        }
                        editHDRPixels(strip, options, false);
                        applyStripEffects(strip, row, effects, 0);
                        lowFile.append(strip.pixels.data(), strip.pixels.size() * sizeof(RGB));
                        reportHdrProgress(150 + uint32_t((uint64_t(row + strip.height) * 300) / source.height), 1000);
                    }
                }
            }
            source.finish(); checkProcessingCancellation();
            File readLow(stagedLow);
            std::vector<RGB> readChunk(size_t(result.width) * std::min(decodeRows, result.height));
            uint32_t chunkFirst = std::numeric_limits<uint32_t>::max();
            HdrProgressSubrangeScope sub(450, 1000);
            result.jpeg = encodeSDRJPEGRows(result.width, result.height, quality, [&](uint32_t y) {
                const uint32_t first = y / decodeRows * decodeRows;
                if (first != chunkFirst) {
                    const uint32_t count = std::min(decodeRows, result.height - first);
                    readLow.read(uint64_t(first) * result.width * sizeof(RGB),
                                 readChunk.data(), size_t(count) * result.width * sizeof(RGB));
                    chunkFirst = first;
                }
                return readChunk.data() + size_t(y - chunkFirst) * result.width;
            });
            return result;
        }

        const auto packedHigh = scratch->path / "hdr.rgba16f", packedLow = scratch->path / "sdr.rgba8";
        float capacity = 1.0f;
        result.editedHeadroom = 1.0f;
        for (bool hdr : {true, false}) {
            File packedFile(hdr ? packedHigh : packedLow, true);
            for (uint32_t row = 0; row < source.height; row += decodeRows) {
                checkProcessingCancellation();
                ImageData strip(source.width, std::min(decodeRows, source.height - row));
                const float missing = std::numeric_limits<float>::quiet_NaN();
                std::fill(strip.pixels.begin(), strip.pixels.end(), RGB(missing, missing, missing));
                source.read(hdr, row, strip.height, strip.pixels.data());
                checkProcessingCancellation();
                if (hdr) validateAndUpdateSourceHeadroom(strip, result.sourceHeadroom);
                editHDRPixels(strip, options, hdr);
                applyStripEffects(strip, row, effects, hdr ? peak : 0);
                if (hdr) accumulateHDRHeadroomAndFinite(strip, result.editedHeadroom);

                std::vector<uint16_t> packed(strip.pixels.size() * (hdr ? 4 : 2));
                std::vector<float> rowCap(strip.height, 1.0f);
                std::atomic<bool> overflow{false};
                parallelRowRanges(strip.height, strip.width, [&](int firstRow, int lastRow) {
                    for (int y = firstRow; y < lastRow; ++y) {
                        try {
                            void* dst = hdr
                                ? static_cast<void*>(packed.data() + size_t(y) * strip.width * 4)
                                : static_cast<void*>(reinterpret_cast<uint8_t*>(packed.data()) + size_t(y) * strip.width * 4);
                            rowCap[size_t(y)] = packJPEGInput(strip.pixels.data() + size_t(y) * strip.width,
                                                              strip.width, hdr, baseColor, dst);
                        } catch (const std::overflow_error&) {
                            overflow.store(true, std::memory_order_relaxed);
                            return;
                        }
                    }
                });
                if (overflow.load(std::memory_order_relaxed))
                    throw std::overflow_error("HDR JPEG exceeds finite half-float codec range");
                for (float cap : rowCap) capacity = std::max(capacity, cap);
                packedFile.append(packed.data(), packed.size() * sizeof(uint16_t));
                const uint32_t base = hdr ? 0u : 250u;
                reportHdrProgress(base + uint32_t((uint64_t(row + strip.height) * 250) / source.height), 1000);
            }
        }
        source.finish(); checkProcessingCancellation();
        admitStreamingMemory(outputPixels * 42 + (128ull << 20));
        HdrProgressSubrangeScope sub(500, 1000);
        result.jpeg = encodeJPEGInputs(result.width, result.height, quality, baseColor, capacity,
            [&](bool hdr, const std::function<void(const void*)>& consume) {
                Mapping input(hdr ? packedHigh : packedLow, size_t(outputPixels) * (hdr ? 8 : 4));
                consume(input.data());
            }, transformBase);
        return result;
    }

    {
        HdrProgressSubrangeScope sub(0, 350);
        stageSource(source, options, result, *scratch, highDynamicRange);
    }
    const auto high = scratch->path / "hdr.rgb32f", low = scratch->path / "sdr.rgb32f";
    if (!highDynamicRange) {
        RenderedRows rows(low, source, options, result.width, result.height, nullptr);
        HdrProgressSubrangeScope sub(350, 1000);
        result.jpeg = encodeSDRJPEGRows(result.width, result.height, quality, [&](uint32_t y) { return rows.row(y); });
        return result;
    }
    const auto packedHigh = scratch->path / "hdr.rgba16f", packedLow = scratch->path / "sdr.rgba8";
    float capacity = 1;
    result.editedHeadroom = 1;
    for (bool hdr : {true, false}) {
        File file(hdr ? packedHigh : packedLow, true);
        RenderedRows rows(hdr ? high : low, source, options, result.width, result.height, hdr ? &result.editedHeadroom : nullptr);
        for (uint32_t bandFirst = 0; bandFirst < result.height; bandFirst += tileEdge) {
            checkProcessingCancellation();
            uint32_t bandRows = 0;
            const RGB* bandPixels = rows.band(bandFirst, bandRows);
            std::vector<uint16_t> packed(size_t(result.width) * bandRows * (hdr ? 4 : 2));
            std::vector<float> rowCap(bandRows, 1.0f);
            std::atomic<bool> overflow{false};
            parallelRowRanges(int(bandRows), int(result.width), [&](int firstRow, int lastRow) {
                for (int y = firstRow; y < lastRow; ++y) {
                    try {
                        void* dst = hdr
                            ? static_cast<void*>(packed.data() + size_t(y) * result.width * 4)
                            : static_cast<void*>(reinterpret_cast<uint8_t*>(packed.data()) + size_t(y) * result.width * 4);
                        rowCap[size_t(y)] = packJPEGInput(bandPixels + size_t(y) * result.width,
                                                          result.width, hdr, baseColor, dst);
                    } catch (const std::overflow_error&) {
                        overflow.store(true, std::memory_order_relaxed);
                        return;
                    }
                }
            });
            if (overflow.load(std::memory_order_relaxed))
                throw std::overflow_error("HDR JPEG exceeds finite half-float codec range");
            for (float cap : rowCap) capacity = std::max(capacity, cap);
            file.append(packed.data(), packed.size() * sizeof(uint16_t));
            const uint32_t base = hdr ? 350u : 525u;
            reportHdrProgress(base + uint32_t((uint64_t(bandFirst + bandRows) * 175) / result.height), 1000);
        }
    }
    // libultrahdr 2.0.2 主要同时存活缓冲为 33 B/pixel；保留 42 B/pixel 覆盖
    // 对齐、压缩与 allocator 滞留，再留 128 MiB 固定余量。系统余量由准入函数另留。
    admitStreamingMemory(outputPixels * 42 + (128ull << 20));
    HdrProgressSubrangeScope sub(700, 1000);
    result.jpeg = encodeJPEGInputs(result.width, result.height, quality, baseColor, capacity,
        [&](bool hdr, const std::function<void(const void*)>& consume) {
            Mapping input(hdr ? packedHigh : packedLow, size_t(outputPixels) * (hdr ? 8 : 4));
            consume(input.data());
        }, transformBase);
    return result;
}
}
