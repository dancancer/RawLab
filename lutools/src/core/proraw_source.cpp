#include "core/proraw_source.h"
#include "core/hdr_progress.h"
#include "core/hdr_storage.h"
#include "core/processing_cancellation.h"
#include "core/sha256.h"
#include "core/resource_file_stamp.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <exception>
#include <fstream>
#include <limits>
#include <mutex>
#include <cstdlib>
#include <cstddef>
#ifdef SONY2FUJI_ENABLE_DNGSDK
#include "dng_abort_sniffer.h"
#include "dng_color_space.h"
#include "dng_exceptions.h"
#include "dng_exif.h"
#include "dng_file_stream.h"
#include "dng_host.h"
#include "dng_ifd.h"
#include "dng_image.h"
#include "dng_info.h"
#include "dng_negative.h"
#include "dng_memory.h"
#include "dng_render.h"
#include "dng_shared.h"
#include "dng_tag_types.h"
#endif

namespace sony2fuji::hdr {
namespace fs = std::filesystem;
namespace {
[[noreturn]] void unsupported() {
    throw Error(RenderStatus::Unsupported, kHdrReasonUnsupportedRaw,
        kHdrFieldSource, "Unsupported ProRAW source or decoder configuration");
}
[[noreturn]] void changed() {
    throw Error(RenderStatus::InvalidArgument, kHdrReasonSourceChanged,
        kHdrFieldSource, "ProRAW source changed during development");
}
#ifdef SONY2FUJI_ENABLE_DNGSDK
struct Storage {
    storage::Directory directory;
    unsigned serial = 0;
    std::exception_ptr error;
    Storage(const fs::path& root, uint64_t pixels) : directory(root, proRAWStageBytes(pixels)) {}
    void check() const { if (error) std::rethrow_exception(error); checkProcessingCancellation(); }
};

class DiskImage final : public dng_image {
    static constexpr uint32_t kTileEdge = 128;
    std::shared_ptr<Storage> storage_;
    fs::path path_;
    mutable storage::File file_;
    uint32 physicalWidth_, physicalHeight_, pixelBytes_, tilesX_, tilesY_;
    int32_t physOriginX_ = 0, physOriginY_ = 0;
    int32_t stepX_Col_ = 1, stepY_Col_ = 0, stepX_Row_ = 0, stepY_Row_ = 1;
    mutable std::mutex mutex_;
    mutable std::vector<uint8_t> tileWritten_;
    struct Tile { std::vector<uint8_t> pixels; };

    uint64_t physicalTileOffset(uint32_t left, uint32_t top, uint32_t tileHeight) const {
        return (uint64_t(top) * physicalWidth_ + uint64_t(left) * tileHeight) * pixelBytes_;
    }

    void physicalCoord(int32 y, int32 x, int32_t& px, int32_t& py) const {
        const int32_t lx = x - fBounds.l;
        const int32_t ly = y - fBounds.t;
        px = physOriginX_ + lx * stepX_Col_ + ly * stepX_Row_;
        py = physOriginY_ + lx * stepY_Col_ + ly * stepY_Row_;
    }

    void transfer(const dng_rect& area, uint8_t* pixels, bool write) const {
        int32_t c0x = 0, c0y = 0, c1x = 0, c1y = 0, c2x = 0, c2y = 0, c3x = 0, c3y = 0;
        physicalCoord(area.t, area.l, c0x, c0y);
        physicalCoord(area.t, area.r - 1, c1x, c1y);
        physicalCoord(area.b - 1, area.l, c2x, c2y);
        physicalCoord(area.b - 1, area.r - 1, c3x, c3y);
        const uint32_t pxMin = uint32_t(std::min({c0x, c1x, c2x, c3x}));
        const uint32_t pxMax = uint32_t(std::max({c0x, c1x, c2x, c3x}));
        const uint32_t pyMin = uint32_t(std::min({c0y, c1y, c2y, c3y}));
        const uint32_t pyMax = uint32_t(std::max({c0y, c1y, c2y, c3y}));
        const uint32_t txMin = pxMin / kTileEdge, txMax = pxMax / kTileEdge;
        const uint32_t tyMin = pyMin / kTileEdge, tyMax = pyMax / kTileEdge;
        const uint32_t areaW = uint32_t(area.W()), areaH = uint32_t(area.H());
        const bool axisIdentity = (stepX_Col_ == 1 && stepY_Col_ == 0 && stepX_Row_ == 0 && stepY_Row_ == 1);

        std::lock_guard<std::mutex> lock(mutex_);
        if (!write) {
            bool anyWritten = false;
            for (uint32_t ty = tyMin; ty <= tyMax && !anyWritten; ++ty) {
                for (uint32_t tx = txMin; tx <= txMax; ++tx) {
                    if (tileWritten_[size_t(ty) * tilesX_ + tx]) {
                        anyWritten = true;
                        break;
                    }
                }
            }
            if (!anyWritten) {
                std::memset(pixels, 0, size_t(areaW) * areaH * pixelBytes_);
                return;
            }
        }

        std::vector<uint8_t> tileBuf;
        for (uint32_t ty = tyMin; ty <= tyMax; ++ty) {
            const uint32_t top = ty * kTileEdge;
            const uint32_t th = std::min(kTileEdge, physicalHeight_ - top);
            const uint32_t iy0 = std::max(top, pyMin), iy1 = std::min(top + th - 1, pyMax) + 1;
            for (uint32_t tx = txMin; tx <= txMax; ++tx) {
                const uint32_t left = tx * kTileEdge;
                const uint32_t tw = std::min(kTileEdge, physicalWidth_ - left);
                const uint32_t ix0 = std::max(left, pxMin), ix1 = std::min(left + tw - 1, pxMax) + 1;
                const size_t tileIdx = size_t(ty) * tilesX_ + tx;
                const size_t tileBytes = size_t(tw) * th * pixelBytes_;
                const uint64_t diskOffset = physicalTileOffset(left, top, th);
                tileBuf.resize(tileBytes);

                if (!write) {
                    if (!tileWritten_[tileIdx]) {
                        std::memset(tileBuf.data(), 0, tileBytes);
                    } else {
                        file_.read(diskOffset, tileBuf.data(), tileBytes);
                    }
                } else {
                    const bool fullOverwrite = (ix1 - ix0 == tw) && (iy1 - iy0 == th);
                    if (!fullOverwrite) {
                        if (!tileWritten_[tileIdx]) std::memset(tileBuf.data(), 0, tileBytes);
                        else file_.read(diskOffset, tileBuf.data(), tileBytes);
                    }
                }

                if (axisIdentity) {
                    const size_t copyBytes = size_t(ix1 - ix0) * pixelBytes_;
                    for (uint32_t py = iy0; py < iy1; ++py) {
                        uint8_t* tileRow = tileBuf.data() + (size_t(py - top) * tw + (ix0 - left)) * pixelBytes_;
                        uint8_t* logRow = pixels + (size_t(py - pyMin) * areaW + (ix0 - pxMin)) * pixelBytes_;
                        if (write) std::memcpy(tileRow, logRow, copyBytes);
                        else std::memcpy(logRow, tileRow, copyBytes);
                    }
                } else {
                    // 仅对逻辑区域中落入当前物理 tile 的坐标交集逐点搬移，步进更新免除乘法/除法。
                    for (int32 y = area.t; y < area.b; ++y) {
                        int32_t px = 0, py = 0;
                        physicalCoord(y, area.l, px, py);
                        uint8_t* logPtr = pixels + size_t(y - area.t) * areaW * pixelBytes_;
                        for (int32 x = area.l; x < area.r; ++x, px += stepX_Col_, py += stepY_Col_, logPtr += pixelBytes_) {
                            if (uint32_t(px) >= ix0 && uint32_t(px) < ix1 &&
                                uint32_t(py) >= iy0 && uint32_t(py) < iy1) {
                                uint8_t* tilePtr = tileBuf.data() + (size_t(uint32_t(py) - top) * tw + (uint32_t(px) - left)) * pixelBytes_;
                                if (write) std::memcpy(tilePtr, logPtr, pixelBytes_);
                                else std::memcpy(logPtr, tilePtr, pixelBytes_);
                            }
                        }
                    }
                }

                if (write) {
                    file_.write(diskOffset, tileBuf.data(), tileBytes);
                    tileWritten_[tileIdx] = 1;
                }
            }
        }
    }
protected:
    void AcquireTileBuffer(dng_tile_buffer& buffer, const dng_rect& area, bool dirty) const override {
        storage_->check();
        if (area.IsEmpty() || !fBounds.Contains(area)) throw std::invalid_argument("Invalid ProRAW tile bounds");
        const auto bytes = uint64_t(area.W()) * area.H() * pixelBytes_;
        admitMemory(bytes * 2);
        auto tile = std::make_unique<Tile>(); tile->pixels.resize(size_t(bytes));
        transfer(area, tile->pixels.data(), false);
        buffer.fArea = area; buffer.fPlane = 0; buffer.fPlanes = fPlanes;
        buffer.fRowStep = area.W() * fPlanes; buffer.fColStep = fPlanes; buffer.fPlaneStep = 1;
        buffer.fPixelType = fPixelType; buffer.fPixelSize = TagTypeSize(fPixelType);
        buffer.fData = tile->pixels.data(); buffer.fDirty = dirty;
        buffer.SetRefData(tile.release());
    }
    void ReleaseTileBuffer(dng_tile_buffer& buffer) const override {
        std::unique_ptr<Tile> tile(static_cast<Tile*>(buffer.GetRefData()));
        // SDK 在析构函数内释放块；延迟报告写入失败，禁止析构抛异常导致进程终止。
        try { if (tile && buffer.fDirty) transfer(buffer.fArea, tile->pixels.data(), true); }
        catch (...) { if (!storage_->error) storage_->error = std::current_exception(); }
        buffer.SetRefData(nullptr);
    }
public:
    DiskImage(std::shared_ptr<Storage> storage, const dng_rect& bounds, uint32 planes, uint32 type)
        : dng_image(bounds, planes, type), storage_(std::move(storage)),
          path_(storage_->directory.path / ("sdk-" + std::to_string(++storage_->serial))), file_(path_, true),
          physicalWidth_(uint32_t(bounds.W())), physicalHeight_(uint32_t(bounds.H())),
          pixelBytes_(planes * TagTypeSize(type)),
          tilesX_((physicalWidth_ + kTileEdge - 1) / kTileEdge),
          tilesY_((physicalHeight_ + kTileEdge - 1) / kTileEdge),
          tileWritten_(size_t(tilesX_) * tilesY_, 0) {
        if (!planes || planes > 4 || !pixelBytes_ || uint64_t(bounds.W()) * bounds.H() > 128000000)
            unsupported();
        file_.resize(uint64_t(bounds.W()) * bounds.H() * pixelBytes_);
    }
    ~DiskImage() override { std::error_code error; fs::remove(path_, error); }
    dng_rect RepeatingTile() const override { return dng_rect(kTileEdge, kTileEdge); }
    dng_image* Clone() const override {
        auto copy = std::make_unique<DiskImage>(storage_, fBounds, fPlanes, fPixelType);
        copy->CopyArea(*this, fBounds, 0, fPlanes); storage_->check(); return copy.release();
    }
    void Trim(const dng_rect& area) override {
        if (!fBounds.Contains(area) || area.IsEmpty()) throw std::invalid_argument("Invalid ProRAW trim");
        const int32_t dx = area.l - fBounds.l, dy = area.t - fBounds.t;
        physOriginX_ += dx * stepX_Col_ + dy * stepX_Row_;
        physOriginY_ += dx * stepY_Col_ + dy * stepY_Row_;
        fBounds = dng_rect(area.H(), area.W());
    }
    void Offset(const dng_point& offset) override { fBounds = fBounds + offset; }
    void Rotate(const dng_orientation& orientation) override {
        auto width = fBounds.W(), height = fBounds.H();
        if (orientation.FlipH()) {
            physOriginX_ += (width - 1) * stepX_Col_;
            physOriginY_ += (width - 1) * stepY_Col_;
            stepX_Col_ = -stepX_Col_;
            stepY_Col_ = -stepY_Col_;
        }
        if (orientation.FlipV()) {
            physOriginX_ += (height - 1) * stepX_Row_;
            physOriginY_ += (height - 1) * stepY_Row_;
            stepX_Row_ = -stepX_Row_;
            stepY_Row_ = -stepY_Row_;
        }
        if (orientation.FlipD()) {
            std::swap(stepX_Row_, stepX_Col_);
            std::swap(stepY_Row_, stepY_Col_);
            std::swap(width, height);
        }
        fBounds.r = fBounds.l + width; fBounds.b = fBounds.t + height;
    }
};
class Sniffer final : public dng_abort_sniffer {
    void Sniff() override { checkProcessingCancellation(); }
};
class Memory final : public dng_memory_allocator {
    struct alignas(std::max_align_t) Header { size_t bytes; };
    std::mutex mutex_;
    uint64_t live_ = 0;
    std::exception_ptr failure_;
    class Block final : public dng_memory_block {
        Memory& owner_;
        void* data_;
    public:
        Block(uint32 size, Memory& owner) : dng_memory_block(size), owner_(owner), data_(owner.Malloc(PhysicalSize())) {
            SetBuffer(data_);
        }
        ~Block() override { owner_.Free(data_); }
    };
public:
    dng_memory_block* Allocate(uint32 size) override { return new Block(size, *this); }
    void* Malloc(size_t size) override {
        std::lock_guard<std::mutex> lock(mutex_);
        try {
            if (size > std::numeric_limits<size_t>::max() - sizeof(Header) ||
                size > UINT64_MAX - live_ - (64ull << 20)) throw std::bad_alloc();
            // libjxl 的全图输出和内部工作集也走此 allocator；已申请但尚未触页的内存不能漏计。
            admitMemory(live_ + size + (64ull << 20));
            auto* allocation = static_cast<Header*>(std::malloc(sizeof(Header) + size));
            if (!allocation) throw std::bad_alloc();
            allocation->bytes = size; live_ += size;
            return allocation + 1;
        } catch (...) {
            if (!failure_) failure_ = std::current_exception();
            throw;
        }
    }
    void Free(void* data) override {
        if (!data) return;
        auto* allocation = static_cast<Header*>(data) - 1;
        { std::lock_guard<std::mutex> lock(mutex_); live_ -= allocation->bytes; }
        std::free(allocation);
    }
    void check() {
        std::exception_ptr failure;
        { std::lock_guard<std::mutex> lock(mutex_); failure = failure_; }
        if (failure) std::rethrow_exception(failure);
    }
};
class Host final : public dng_host {
public:
    std::shared_ptr<Storage> storage;
    Host(dng_memory_allocator* memory, dng_abort_sniffer* sniffer) : dng_host(memory, sniffer) {}
    dng_image* Make_dng_image(const dng_rect& bounds, uint32 planes, uint32 type) override {
        if (!storage) throw std::logic_error("Missing ProRAW scratch storage");
        storage->check(); return new DiskImage(storage, bounds, planes, type);
    }
};
struct Source {
    fs::path path;
    uintmax_t size;
    ResourceFileStamp stamp{};
    Sniffer sniffer;
    Memory memory;
    Host host{&memory, &sniffer};
    std::unique_ptr<dng_file_stream> stream;
    dng_info info;
    AutoPtr<dng_negative> negative;
    AutoPtr<dng_image> rendered;
    uint32_t width = 0, height = 0;
    std::array<uint8_t, 32> digest{};
    int renderedKind = -1;
    explicit Source(const char* file) : path(fs::u8path(file)) {
        const auto before = resourceFileStamp(path);
        if (!before || before->size < 8 || before->size > (512ull << 20)) unsupported();
        stamp = *before; size = stamp.size;
#ifdef _WIN32
        stream = std::make_unique<dng_file_stream>(path.c_str());
#else
        stream = std::make_unique<dng_file_stream>(path.c_str());
#endif
        info.Parse(host, *stream); info.PostParse(host);
        if (!info.IsValidDNG() || info.fMainIndex < 0 || !info.fExif.Get()) unsupported();
        const auto& raw = *info.fIFD[info.fMainIndex];
        const auto* exif = info.fExif.Get();
        if (std::string(exif->fMake.Get()) != "Apple" || std::string(exif->fModel.Get()).rfind("iPhone ", 0) != 0 ||
            raw.fPhotometricInterpretation != 34892 || raw.fSamplesPerPixel != 3 || !raw.fLinearizationTableCount)
            unsupported();
        negative.Reset(host.Make_dng_negative());
        negative->Parse(host, *stream, info); negative->PostParse(host, *stream, info);
        if (!negative->HasProfileGainTableMap()) unsupported();
        dng_camera_profile embedded;
        if (!negative->GetProfileByID(dng_camera_profile_id("Apple Embedded Color Profile"), embedded)) unsupported();
        width = negative->DefaultFinalWidth(); height = negative->DefaultFinalHeight();
        if (negative->BaseOrientation().FlipD()) std::swap(width, height);
        if (width < 2 || height < 2 || width > 65535 || height > 65535 || uint64_t(width) * height > 128000000) unsupported();
    }
    HDRSourceInfo description() const {
        HDRSourceInfo result{};
        result.width = width; result.height = height; result.orientation = 1;
        result.container = kHdrContainerProRaw; result.colorDescription = kHdrColorSrgb;
        return result;
    }
    void develop(const fs::path& root, const uint8_t* expectedSHA256 = nullptr) {
        const auto& raw = *info.fIFD[info.fMainIndex];
        const uint64_t tileWidth = raw.fTileWidth ? raw.fTileWidth : raw.fImageWidth;
        const uint64_t tileHeight = raw.fTileLength ? raw.fTileLength : raw.fImageLength;
        if (tileWidth > 65535 || tileHeight > 65535) unsupported();
        // 压缩输入、predictor 额外行和浮点展开；JXL 的其它分配由 Memory 逐次核验。
        admitMemory((96ull << 20) + size + tileWidth * (tileHeight + 1) * raw.fSamplesPerPixel * 8);
        host.storage = std::make_shared<Storage>(root, uint64_t(width) * height);
        if (expectedSHA256) {
            std::copy_n(expectedSHA256, digest.size(), digest.begin());
        } else {
            const auto hex = hash::sha256File(path.u8string(), checkProcessingCancellation);
            for (size_t i = 0; i < digest.size(); ++i)
                digest[i] = uint8_t(std::stoul(hex.substr(2 * i, 2), nullptr, 16));
        }
        verify();
        reportHdrProgress(50, 1000);
        try { negative->ReadStage1Image(host, *stream, info); }
        catch (...) { memory.check(); throw; }
        memory.check(); host.storage->check();
        reportHdrProgress(350, 1000);
        negative->SynchronizeMetadata();
        negative->BuildStage2Image(host); host.storage->check();
        reportHdrProgress(650, 1000);
        negative->BuildStage3Image(host); host.storage->check();
        reportHdrProgress(950, 1000);
        stream.reset();
        dng_camera_profile profile;
        if (!negative->GetProfileByID(dng_camera_profile_id("Apple Embedded Color Profile"), profile)) unsupported();
        profile.SetName("RawLab ProRAW HDR v2");
        dng_camera_profile_dynamic_range range; range.fDynamicRange = 1; range.fHintMaxOutputValue = 4.0f;
        profile.SetDynamicRangeInfo(range);
        AutoPtr<dng_camera_profile> copy(new dng_camera_profile()); *copy.Get() = profile;
        negative->AddProfile(copy);
        reportHdrProgress(1000, 1000);
    }
    void render(bool hdr, uint32_t edge) {
        rendered.Reset();
        dng_render render(host, *negative);
        render.SetFinalSpace(dng_space_sRGB_Linear::Get()); render.SetFinalPixelType(ttFloat); render.SetExposure(0);
        render.SetCameraProfileID(dng_camera_profile_id(hdr ? "RawLab ProRAW HDR v2" : "Apple Embedded Color Profile"));
        if (edge) render.SetMaximumSize(edge);
        rendered.Reset(render.Render()); host.storage->check();
        rendered->Rotate(negative->BaseOrientation());
        renderedKind = hdr ? 1 : 0;
    }
    void readRows(uint32_t row, uint32_t count, RGB* output) const {
        const auto bounds = rendered->Bounds();
        if (row + uint64_t(count) > bounds.H()) throw std::invalid_argument("Invalid ProRAW row request");
        dng_pixel_buffer buffer;
        buffer.fArea = dng_rect(bounds.t + row, bounds.l, bounds.t + row + count, bounds.r);
        buffer.fPlane = 0; buffer.fPlanes = 3; buffer.fRowStep = bounds.W() * 3;
        buffer.fColStep = 3; buffer.fPlaneStep = 1; buffer.fPixelType = ttFloat; buffer.fPixelSize = 4;
        buffer.fData = output; buffer.fDirty = true;
        rendered->Get(buffer); host.storage->check();
    }
    void verify() const {
        checkProcessingCancellation();
        const auto current = resourceFileStamp(path);
        if (!current || !(*current == stamp)) changed();
    }
    void finish() {
        rendered.Reset(); negative.Reset(); host.storage->check(); host.storage.reset();
        verify();
        checkProcessingCancellation();
    }
};

template<class F> auto sdkBoundary(F body) -> decltype(body()) {
    try { return body(); }
    catch (const dng_exception& error) {
        if (error.ErrorCode() == dng_error_memory) throw std::bad_alloc();
        if (error.ErrorCode() == dng_error_user_canceled) throw ProcessingCancelled();
        unsupported();
    }
}
#endif
}
HDRSourceInfo probeProRAW(const char* path) {
#ifdef SONY2FUJI_ENABLE_DNGSDK
    return sdkBoundary([&] { Source source(path); return source.description(); });
#else
    (void)path; unsupported();
#endif
}
DecodedImage decodeProRAW(const char* path, const HDRDecodeOptions& options, const fs::path& root) {
#ifdef SONY2FUJI_ENABLE_DNGSDK
    return sdkBoundary([&] {
        Source source(path);
        const bool preview = options.intent == kHdrIntentPreview;
        if (options.intent > 1 || (preview ? !options.longEdge || options.longEdge > 2048 : options.longEdge != 0))
            throw std::invalid_argument("Invalid ProRAW decode size");
        DecodedImage result; result.info = source.description();
        auto& pair = result.pixels;
        pair.nativeWidth = source.width; pair.nativeHeight = source.height;
        pair.sourceQuality = pair.renderQuality = static_cast<HDRQuality>(options.intent);
        pair.isProxy = preview; pair.decodeRevision = portableProRAWRevision;
        const auto edge = preview ? options.longEdge : std::max(source.width, source.height);
        const double scale = std::min(1.0, double(edge) / std::max(source.width, source.height));
        admitMemory(uint64_t(std::ceil(source.width * scale)) * uint64_t(std::ceil(source.height * scale)) * 24 + (128ull << 20));
        {
            HdrProgressSubrangeScope sub(0, 500);
            source.develop(root);
        }
        for (bool hdr : {true, false}) {
            HdrProgressSubrangeScope sub(hdr ? 500u : 750u, hdr ? 750u : 1000u);
            source.render(hdr, preview ? options.longEdge : 0);
            auto& image = hdr ? pair.hdr : pair.sdr;
            image = ImageData(source.rendered->Width(), source.rendered->Height());
            for (uint32_t row = 0; row < uint32_t(image.height); row += 128) {
                const uint32_t chunk = std::min(128u, uint32_t(image.height) - row);
                source.readRows(row, chunk, image.pixels.data() + size_t(row) * image.width);
                reportHdrProgress(row + chunk, uint32_t(image.height));
            }
        }
        source.finish();
        if (!preview) {
            pair.sourceHeadroom = 1;
            for (const auto& p : pair.hdr.pixels) pair.sourceHeadroom = std::max(pair.sourceHeadroom, .2126f*p.r + .7152f*p.g + .0722f*p.b);
            result.info.headroomKind = kHdrHeadroomMeasured; result.info.contentHeadroom = pair.sourceHeadroom;
        }
        std::copy(source.digest.begin(), source.digest.end(), result.info.sourceSha256);
        return result;
    });
#else
    (void)path; (void)options; (void)root; unsupported();
#endif
}
HDRRowSource openProRAW(const char* path, const fs::path& root, const uint8_t expectedSHA256[32]) {
#ifdef SONY2FUJI_ENABLE_DNGSDK
    return sdkBoundary([&] {
        auto source = std::make_shared<Source>(path); source->develop(root, expectedSHA256);
        HDRRowSource result; result.width = source->width; result.height = source->height;
        result.read = [source](bool hdr, uint32_t row, uint32_t count, RGB* output) {
            sdkBoundary([&] {
                if (source->renderedKind != int(hdr)) {
                    if (row) throw std::invalid_argument("ProRAW rendition must start at row zero");
                    source->render(hdr, 0);
                    if (source->rendered->Width() != source->width || source->rendered->Height() != source->height) unsupported();
                }
                source->readRows(row, count, output);
            });
        };
        result.finish = [source] { source->finish(); };
        return result;
    });
#else
    (void)path; (void)root; (void)expectedSHA256; unsupported();
#endif
}
}
