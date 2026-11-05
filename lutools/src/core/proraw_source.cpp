#include "core/proraw_source.h"
#include "core/hdr_storage.h"
#include "core/processing_cancellation.h"
#include "core/sha256.h"
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
    throw Error(SONY2FUJI_STATUS_UNSUPPORTED, SONY2FUJI_HDR_REASON_UNSUPPORTED_RAW,
        SONY2FUJI_HDR_FIELD_SOURCE, "Unsupported ProRAW source or decoder configuration");
}
[[noreturn]] void changed() {
    throw Error(SONY2FUJI_STATUS_INVALID_ARGUMENT, SONY2FUJI_HDR_REASON_SOURCE_CHANGED,
        SONY2FUJI_HDR_FIELD_SOURCE, "ProRAW source changed during development");
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
    std::shared_ptr<Storage> storage_;
    fs::path path_;
    mutable storage::File file_;
    uint32 physicalWidth_, pixelBytes_;
    int64_t origin_ = 0, rowStep_, colStep_;
    struct Tile { std::vector<uint8_t> pixels; };
    int64_t address(int32 y, int32 x) const {
        return origin_ + int64_t(y - fBounds.t) * rowStep_ + int64_t(x - fBounds.l) * colStep_;
    }
    void transfer(const dng_rect& area, uint8_t* pixels, bool write) const {
        // 旋转后的块仍映射到一个原始矩形；逐行读取该矩形，避免逐像素磁盘访问。
        const int64_t addresses[] = {address(area.t, area.l), address(area.t, area.r - 1),
            address(area.b - 1, area.l), address(area.b - 1, area.r - 1)};
        const auto low = *std::min_element(std::begin(addresses), std::end(addresses));
        const auto high = *std::max_element(std::begin(addresses), std::end(addresses));
        const int64_t rowBytes = int64_t(physicalWidth_) * pixelBytes_;
        const uint32 left = uint32((low % rowBytes) / pixelBytes_);
        const uint32 top = uint32(low / rowBytes), bottom = uint32(high / rowBytes);
        const uint32 width = uint32((high % rowBytes) / pixelBytes_) - left + 1;
        std::vector<uint8_t> physical(size_t(width) * (bottom - top + 1) * pixelBytes_);
        if (!write) for (uint32 y = top; y <= bottom; ++y)
            file_.read(uint64_t(y) * rowBytes + uint64_t(left) * pixelBytes_,
                physical.data() + size_t(y - top) * width * pixelBytes_, size_t(width) * pixelBytes_);
        for (int32 y = area.t; y < area.b; ++y) for (int32 x = area.l; x < area.r; ++x) {
            const auto offset = address(y, x);
            const size_t index = (size_t(offset / rowBytes - top) * width + size_t(offset % rowBytes / pixelBytes_ - left)) * pixelBytes_;
            auto* logical = pixels + (size_t(y - area.t) * area.W() + x - area.l) * pixelBytes_;
            if (write) std::memcpy(physical.data() + index, logical, pixelBytes_);
            else std::memcpy(logical, physical.data() + index, pixelBytes_);
        }
        if (write) for (uint32 y = top; y <= bottom; ++y)
            file_.write(uint64_t(y) * rowBytes + uint64_t(left) * pixelBytes_,
                physical.data() + size_t(y - top) * width * pixelBytes_, size_t(width) * pixelBytes_);
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
          physicalWidth_(bounds.W()), pixelBytes_(planes * TagTypeSize(type)),
          rowStep_(int64_t(bounds.W()) * pixelBytes_), colStep_(pixelBytes_) {
        if (!planes || planes > 4 || !pixelBytes_ || uint64_t(bounds.W()) * bounds.H() > 128000000)
            unsupported();
        file_.resize(uint64_t(bounds.W()) * bounds.H() * pixelBytes_);
    }
    ~DiskImage() override { std::error_code error; fs::remove(path_, error); }
    dng_rect RepeatingTile() const override { return dng_rect(128, 128); }
    dng_image* Clone() const override {
        auto copy = std::make_unique<DiskImage>(storage_, fBounds, fPlanes, fPixelType);
        copy->CopyArea(*this, fBounds, 0, fPlanes); storage_->check(); return copy.release();
    }
    void Trim(const dng_rect& area) override {
        if (!fBounds.Contains(area) || area.IsEmpty()) throw std::invalid_argument("Invalid ProRAW trim");
        origin_ = address(area.t, area.l); fBounds = dng_rect(area.H(), area.W());
    }
    void Offset(const dng_point& offset) override { fBounds = fBounds + offset; }
    void Rotate(const dng_orientation& orientation) override {
        auto width = fBounds.W(), height = fBounds.H();
        if (orientation.FlipH()) { origin_ += int64_t(width - 1) * colStep_; colStep_ = -colStep_; }
        if (orientation.FlipV()) { origin_ += int64_t(height - 1) * rowStep_; rowStep_ = -rowStep_; }
        if (orientation.FlipD()) { std::swap(rowStep_, colStep_); std::swap(width, height); }
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
    fs::file_time_type modified;
    Sniffer sniffer;
    Memory memory;
    Host host{&memory, &sniffer};
    std::unique_ptr<dng_file_stream> stream;
    dng_info info;
    AutoPtr<dng_negative> negative;
    AutoPtr<dng_image> rendered;
    uint32_t width = 0, height = 0;
    std::string digest;
    int renderedKind = -1;
    explicit Source(const char* file) : path(fs::u8path(file)) {
        std::error_code error;
        size = fs::file_size(path, error); if (error || size < 8 || size > (512ull << 20)) unsupported();
        modified = fs::last_write_time(path);
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
    sony2fuji_hdr_source_info_v1 description() const {
        sony2fuji_hdr_source_info_v1 result{}; result.version = 1; result.struct_size = sizeof(result);
        result.width = width; result.height = height; result.orientation = 1;
        result.container = SONY2FUJI_HDR_CONTAINER_PRORAW; result.color_description = SONY2FUJI_HDR_COLOR_SRGB;
        return result;
    }
    void develop(const fs::path& root) {
        const auto& raw = *info.fIFD[info.fMainIndex];
        const uint64_t tileWidth = raw.fTileWidth ? raw.fTileWidth : raw.fImageWidth;
        const uint64_t tileHeight = raw.fTileLength ? raw.fTileLength : raw.fImageLength;
        if (tileWidth > 65535 || tileHeight > 65535) unsupported();
        // 压缩输入、predictor 额外行和浮点展开；JXL 的其它分配由 Memory 逐次核验。
        admitMemory((96ull << 20) + size + tileWidth * (tileHeight + 1) * raw.fSamplesPerPixel * 8);
        host.storage = std::make_shared<Storage>(root, uint64_t(width) * height);
        digest = hash::sha256File(path.u8string());
        verify();
        try { negative->ReadStage1Image(host, *stream, info); }
        catch (...) { memory.check(); throw; }
        memory.check(); host.storage->check();
        negative->SynchronizeMetadata();
        negative->BuildStage2Image(host); host.storage->check();
        negative->BuildStage3Image(host); host.storage->check();
        stream.reset();
        dng_camera_profile profile;
        if (!negative->GetProfileByID(dng_camera_profile_id("Apple Embedded Color Profile"), profile)) unsupported();
        profile.SetName("RawLab ProRAW HDR v2");
        dng_camera_profile_dynamic_range range; range.fDynamicRange = 1; range.fHintMaxOutputValue = 4.0f;
        profile.SetDynamicRangeInfo(range);
        AutoPtr<dng_camera_profile> copy(new dng_camera_profile()); *copy.Get() = profile;
        negative->AddProfile(copy);
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
        if (size != fs::file_size(path) || modified != fs::last_write_time(path)) changed();
    }
    void finish() {
        rendered.Reset(); negative.Reset(); host.storage->check(); host.storage.reset();
        verify();
        if (hash::sha256File(path.u8string()) != digest) changed();
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
sony2fuji_hdr_source_info_v1 probeProRAW(const char* path) {
#ifdef SONY2FUJI_ENABLE_DNGSDK
    return sdkBoundary([&] { Source source(path); return source.description(); });
#else
    (void)path; unsupported();
#endif
}
DecodedImage decodeProRAW(const char* path, const sony2fuji_hdr_decode_options_v1& options, const fs::path& root) {
#ifdef SONY2FUJI_ENABLE_DNGSDK
    return sdkBoundary([&] {
        Source source(path);
        const bool preview = options.intent == SONY2FUJI_INTENT_PREVIEW;
        if (options.intent > 1 || (preview ? !options.long_edge || options.long_edge > 2048 : options.long_edge != 0))
            throw std::invalid_argument("Invalid ProRAW decode size");
        DecodedImage result; result.info = source.description();
        auto& pair = result.pixels;
        pair.nativeWidth = source.width; pair.nativeHeight = source.height;
        pair.sourceQuality = pair.renderQuality = static_cast<HDRQuality>(options.intent);
        pair.isProxy = preview; pair.decodeRevision = portableProRAWRevision;
        const auto edge = preview ? options.long_edge : std::max(source.width, source.height);
        const double scale = std::min(1.0, double(edge) / std::max(source.width, source.height));
        admitMemory(uint64_t(std::ceil(source.width * scale)) * uint64_t(std::ceil(source.height * scale)) * 24 + (128ull << 20));
        source.develop(root);
        for (bool hdr : {true, false}) {
            source.render(hdr, preview ? options.long_edge : 0);
            auto& image = hdr ? pair.hdr : pair.sdr;
            image = ImageData(source.rendered->Width(), source.rendered->Height());
            for (uint32_t row = 0; row < uint32_t(image.height); row += 128)
                source.readRows(row, std::min(128u, uint32_t(image.height) - row), image.pixels.data() + size_t(row) * image.width);
        }
        source.finish();
        if (!preview) {
            pair.sourceHeadroom = 1;
            for (const auto& p : pair.hdr.pixels) pair.sourceHeadroom = std::max(pair.sourceHeadroom, .2126f*p.r + .7152f*p.g + .0722f*p.b);
            result.info.headroom_kind = SONY2FUJI_HDR_HEADROOM_MEASURED; result.info.content_headroom = pair.sourceHeadroom;
        }
        for (size_t i = 0; i < 32; ++i) result.info.source_sha256[i] = uint8_t(std::stoul(source.digest.substr(2*i, 2), nullptr, 16));
        return result;
    });
#else
    (void)path; (void)options; (void)root; unsupported();
#endif
}
HDRRowSource openProRAW(const char* path, const fs::path& root) {
#ifdef SONY2FUJI_ENABLE_DNGSDK
    return sdkBoundary([&] {
        auto source = std::make_shared<Source>(path); source->develop(root);
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
    (void)path; (void)root; unsupported();
#endif
}
}
