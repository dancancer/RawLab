#include "preview_exposure.h"
#include "file_path.h"
#include <libraw/libraw.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <csetjmp>
#include <cstdio>
#include <filesystem>
#include <limits>
#include <memory>
#include <mutex>
#include <jpeglib.h>
#include <jerror.h>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <sys/stat.h>
#endif

namespace sony2fuji {

namespace {

std::mutex& diagnosticsMutex() {
    static std::mutex mutex;
    return mutex;
}

PreviewExposureDiagnostics& globalDiagnosticsState() {
    static PreviewExposureDiagnostics state;
    return state;
}

thread_local PreviewExposureCache* activePreviewExposureCache = nullptr;

struct PreviewJpegError {
    jpeg_error_mgr manager{};
    std::jmp_buf jump;
};

struct ScaledJpegState {
    jpeg_decompress_struct codec{};
    PreviewJpegError error;
    std::vector<unsigned char> rowBuffer;
    ~ScaledJpegState() { jpeg_destroy_decompress(&codec); }
};

bool sampleScaledJpegLuminance(
    const unsigned char* bytes, size_t size, const float linear[256],
    PreviewExposureDiagnostics& delta, std::vector<float>& outLuminance
) {
    outLuminance.clear();
    outLuminance.reserve(128 * 128);
    auto state = std::make_unique<ScaledJpegState>();
    auto& c = state->codec;
    c.err = jpeg_std_error(&state->error.manager);
    state->error.manager.error_exit = [](j_common_ptr p) {
        std::longjmp(reinterpret_cast<PreviewJpegError*>(p->err)->jump, 1);
    };
    state->error.manager.emit_message = [](j_common_ptr p, int msgLevel) {
        if (msgLevel < 0) {
            const int code = p->err->msg_code;
            if (code == JWRN_JPEG_EOF || code == JWRN_HIT_MARKER ||
                code == JWRN_HUFF_BAD_CODE || code == JWRN_MUST_RESYNC) {
                std::longjmp(reinterpret_cast<PreviewJpegError*>(p->err)->jump, 1);
            }
        }
    };
    if (setjmp(state->error.jump)) {
        outLuminance.clear();
        return false;
    }

    jpeg_create_decompress(&c);
    jpeg_mem_src(&c, bytes, static_cast<unsigned long>(size));
    if (jpeg_read_header(&c, TRUE) != JPEG_HEADER_OK) return false;
    if (c.image_width == 0 || c.image_height == 0 ||
        uint64_t(c.image_width) * c.image_height > 64000000) return false;

    // Only 128x128 luminance samples are needed; cap DCT scaling at 1/2 so
    // coarse block averaging does not shift median preview EV while still saving 75% decoded pixels (50% row memory).
    const uint32_t minDim = std::min(c.image_width, c.image_height);
    c.scale_num = 1;
    c.scale_denom = minDim >= 256 ? 2 : 1;

    if (c.num_components == 1 || c.jpeg_color_space == JCS_GRAYSCALE) {
        c.out_color_space = JCS_GRAYSCALE;
    } else if (c.jpeg_color_space == JCS_CMYK || c.jpeg_color_space == JCS_YCCK) {
        c.out_color_space = JCS_CMYK;
    } else {
        c.out_color_space = JCS_RGB;
    }
    c.dct_method = JDCT_ISLOW;
    jpeg_calc_output_dimensions(&c);
    if (c.output_width == 0 || c.output_height == 0 ||
        uint64_t(c.output_width) * c.output_height > 64000000) return false;
    if (c.output_components != 1 && c.output_components != 3 && c.output_components != 4) return false;

    ++delta.jpegDecodes;
    delta.lastJpegSourcePixels = static_cast<uint64_t>(c.image_width) * c.image_height;
    delta.lastJpegDecodedPixels = static_cast<uint64_t>(c.output_width) * c.output_height;

    jpeg_start_decompress(&c);
    const size_t width = c.output_width;
    const size_t height = c.output_height;
    const int components = c.output_components;
    state->rowBuffer.resize(width * static_cast<size_t>(components));

    std::array<size_t, 128> targetRows{};
    std::array<size_t, 128> targetCols{};
    for (int i = 0; i < 128; ++i) {
        targetRows[i] = static_cast<size_t>(2 * i + 1) * height / 256;
        targetCols[i] = static_cast<size_t>(2 * i + 1) * width / 256;
    }

    size_t nextY = 0;
    unsigned char* rowPtr = state->rowBuffer.data();
    while (c.output_scanline < c.output_height) {
        const size_t currentRow = c.output_scanline;
        if (jpeg_read_scanlines(&c, &rowPtr, 1) != 1) {
            outLuminance.clear();
            return false;
        }
        while (nextY < 128 && targetRows[nextY] == currentRow) {
            for (int x = 0; x < 128; ++x) {
                const auto* p = rowPtr + targetCols[x] * static_cast<size_t>(components);
                if (components == 1) {
                    outLuminance.push_back(linear[p[0]]);
                } else if (components == 3) {
                    outLuminance.push_back(
                        .2126f * linear[p[0]] + .7152f * linear[p[1]] + .0722f * linear[p[2]]);
                } else {
                    const uint8_t r = static_cast<uint8_t>((static_cast<unsigned>(p[0]) * p[3] + 127u) / 255u);
                    const uint8_t g = static_cast<uint8_t>((static_cast<unsigned>(p[1]) * p[3] + 127u) / 255u);
                    const uint8_t b = static_cast<uint8_t>((static_cast<unsigned>(p[2]) * p[3] + 127u) / 255u);
                    outLuminance.push_back(
                        .2126f * linear[r] + .7152f * linear[g] + .0722f * linear[b]);
                }
            }
            ++nextY;
        }
    }
    jpeg_finish_decompress(&c);
    return outLuminance.size() == 128u * 128u;
}

std::vector<float> loadPreviewLuminanceWithStats(
    const std::string& path, PreviewExposureDiagnostics* outDelta, bool* outOpened
) {
    if (outOpened) *outOpened = false;
    PreviewExposureDiagnostics delta;
    auto publish = [&] {
        std::lock_guard<std::mutex> lock(diagnosticsMutex());
        auto& global = globalDiagnosticsState();
        global.thumbnailOpens += delta.thumbnailOpens;
        global.jpegDecodes += delta.jpegDecodes;
        if (delta.jpegDecodes > 0) {
            global.lastJpegSourcePixels = delta.lastJpegSourcePixels;
            global.lastJpegDecodedPixels = delta.lastJpegDecodedPixels;
        }
        if (outDelta) *outDelta = delta;
    };
    struct PublishGuard {
        decltype(publish)& fn;
        ~PublishGuard() { fn(); }
    } publishGuard{publish};

    // Keep thumbnail failures/recycle separate from the active RAW decoder.
    // LibRaw is larger than a macOS dispatch worker's default stack.
    auto raw=std::make_unique<LibRaw>();
    ++delta.thumbnailOpens;
    if (openRawFile(*raw,path)!=LIBRAW_SUCCESS) return {};
    if (outOpened) *outOpened = true;
    int thumbnail=-1;
    const auto& defaultThumb=raw->imgdata.thumbnail;
    if (static_cast<size_t>(defaultThumb.twidth)*defaultThumb.theight>64000000) {
        // High-resolution cameras may select a full-size JPEG as the default preview.
        size_t largest=0;
        const auto& list=raw->imgdata.thumbs_list;
        for (int i=0;i<list.thumbcount;++i) {
            const auto& candidate=list.thumblist[i];
            const size_t pixels=static_cast<size_t>(candidate.twidth)*candidate.theight;
            if (pixels>largest && pixels<=64000000) {
                thumbnail=i;
                largest=pixels;
            }
        }
    }
    if ((thumbnail<0 ? raw->unpack_thumb() : raw->unpack_thumb_ex(thumbnail))!=LIBRAW_SUCCESS) return {};
    // DNG: 0 unspecified, 1 gray gamma 2.2, 2 sRGB. Do not reinterpret a
    // declared Adobe RGB/ProPhoto preview as sRGB for exposure metering.
    const unsigned previewSpace=raw->imgdata.color.dng_levels.preview_colorspace;
    if (previewSpace>2) return {};
    std::unique_ptr<libraw_processed_image_t,decltype(&LibRaw::dcraw_clear_mem)>
        thumb(raw->dcraw_make_mem_thumb(),LibRaw::dcraw_clear_mem);
    if (!thumb) return {};
    float linear[256];
    for (int i=0;i<256;++i) {
        const float v=i/255.0f;
        linear[i]=previewSpace==1 ? std::pow(v,2.2f) :
            (v<=.04045f ? v/12.92f : std::pow((v+.055f)/1.055f,2.4f));
    }
    if (thumb->type==LIBRAW_IMAGE_JPEG) {
        if (thumb->data_size==0 || thumb->data_size>static_cast<unsigned>(std::numeric_limits<int>::max()))
            return {};
        std::vector<float> luminance;
        if (!sampleScaledJpegLuminance(thumb->data, thumb->data_size, linear, delta, luminance)) return {};
        return luminance;
    }
    const int width=thumb->width,height=thumb->height,channels=thumb->colors;
    const unsigned char* pixels=thumb->data;
    if (thumb->type!=LIBRAW_IMAGE_BITMAP || thumb->bits!=8 || !pixels ||
        width<=0 || height<=0 || (channels!=1 && channels!=3) ||
        static_cast<size_t>(width)*height*channels!=thumb->data_size) return {};
    std::vector<float> luminance;
    luminance.reserve(128*128);
    for (int y=0;y<128;++y) for (int x=0;x<128;++x) {
        const size_t row=static_cast<size_t>(2*y+1)*height/256;
        const size_t col=static_cast<size_t>(2*x+1)*width/256;
        const auto* p=pixels+(row*width+col)*channels;
        luminance.push_back(channels==1 ? linear[p[0]] :
            .2126f*linear[p[0]]+.7152f*linear[p[1]]+.0722f*linear[p[2]]);
    }
    return luminance;
}

} // namespace

struct PreviewExposureCache::Impl {
    static constexpr size_t kMaxEntries = 8;
    struct Entry {
        std::string fingerprint;
        std::vector<float> luminance;
    };
    std::vector<Entry> entries;
    PreviewExposureDiagnostics diagnostics;
};

PreviewExposureCache::PreviewExposureCache() : impl_(std::make_unique<Impl>()) {}
PreviewExposureCache::~PreviewExposureCache() = default;
PreviewExposureCache::PreviewExposureCache(PreviewExposureCache&&) noexcept = default;
PreviewExposureCache& PreviewExposureCache::operator=(PreviewExposureCache&&) noexcept = default;

std::vector<float> PreviewExposureCache::getOrLoad(const std::string& path) {
    std::string fingerprint;
    const bool hasFingerprint = buildFileIdentityKey(path.c_str(), fingerprint);
    if (hasFingerprint) {
        for (size_t i = impl_->entries.size(); i-- > 0;) {
            if (impl_->entries[i].fingerprint == fingerprint) {
                if (i + 1 != impl_->entries.size()) {
                    auto hit = std::move(impl_->entries[i]);
                    impl_->entries.erase(impl_->entries.begin() + static_cast<std::ptrdiff_t>(i));
                    impl_->entries.push_back(std::move(hit));
                }
                ++impl_->diagnostics.cacheHits;
                {
                    std::lock_guard<std::mutex> lock(diagnosticsMutex());
                    ++globalDiagnosticsState().cacheHits;
                }
                return impl_->entries.back().luminance;
            }
        }
    }

    PreviewExposureDiagnostics delta;
    bool opened = false;
    auto luminance = loadPreviewLuminanceWithStats(path, &delta, &opened);
    ++impl_->diagnostics.cacheMisses;
    impl_->diagnostics.thumbnailOpens += delta.thumbnailOpens;
    impl_->diagnostics.jpegDecodes += delta.jpegDecodes;
    if (delta.jpegDecodes > 0) {
        impl_->diagnostics.lastJpegSourcePixels = delta.lastJpegSourcePixels;
        impl_->diagnostics.lastJpegDecodedPixels = delta.lastJpegDecodedPixels;
    }
    {
        std::lock_guard<std::mutex> lock(diagnosticsMutex());
        ++globalDiagnosticsState().cacheMisses;
    }
    if (hasFingerprint && opened) {
        if (impl_->entries.size() >= Impl::kMaxEntries) {
            impl_->entries.erase(impl_->entries.begin());
        }
        impl_->entries.push_back(Impl::Entry{std::move(fingerprint), luminance});
    }
    return luminance;
}

PreviewExposureDiagnostics PreviewExposureCache::diagnostics() const {
    return impl_->diagnostics;
}

PreviewExposureCacheScope::PreviewExposureCacheScope(PreviewExposureCache* cache)
    : previous_(activePreviewExposureCache) {
    activePreviewExposureCache = cache;
}

PreviewExposureCacheScope::~PreviewExposureCacheScope() {
    activePreviewExposureCache = previous_;
}

PreviewExposureCache* currentPreviewExposureCache() {
    return activePreviewExposureCache;
}

bool buildFileIdentityKey(const char* inputPathStr, std::string& outKey) {
    if (!inputPathStr || inputPathStr[0] == '\0') return false;
    std::error_code fileError;
    const auto inputPath = std::filesystem::u8path(inputPathStr);
    const auto modified = std::filesystem::last_write_time(inputPath, fileError);
    if (fileError) return false;
    const auto fileSize = std::filesystem::file_size(inputPath, fileError);
    if (fileError) return false;
    const auto modifiedNanoseconds = std::chrono::duration_cast<std::chrono::nanoseconds>(
        modified.time_since_epoch()).count();
    outKey = std::string(inputPathStr) + ":" +
        std::to_string(modifiedNanoseconds) + ":" + std::to_string(fileSize);
#ifdef _WIN32
    const HANDLE identityHandle = CreateFileW(inputPath.c_str(), FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (identityHandle == INVALID_HANDLE_VALUE) return false;
    BY_HANDLE_FILE_INFORMATION identity{};
    const bool hasIdentity = GetFileInformationByHandle(identityHandle, &identity) != 0;
    CloseHandle(identityHandle);
    if (!hasIdentity) return false;
    outKey += ":file:" + std::to_string(identity.dwVolumeSerialNumber) + ":" +
        std::to_string(identity.nFileIndexHigh) + ":" + std::to_string(identity.nFileIndexLow);
#else
    struct stat identity{};
    if (::stat(inputPath.c_str(), &identity) != 0) return false;
    outKey += ":file:" + std::to_string(identity.st_dev) + ":" + std::to_string(identity.st_ino);
#endif
    return true;
}

float estimatePreviewExposureEV(std::vector<float> raw, std::vector<float> preview, bool* matched) {
    if (matched) *matched=false;
    auto prepare=[](std::vector<float>& values) {
        values.erase(std::remove_if(values.begin(),values.end(),[](float v) {
            return !std::isfinite(v) || v<0;
        }),values.end());
        std::sort(values.begin(),values.end());
    };
    prepare(raw);
    prepare(preview);
    if (raw.size()<64 || preview.size()<64) return 0;
    // Match middle tones, not the white point or the camera's contrast curve.
    // The median does not require matching orientation/resolution or let a few
    // specular highlights dominate. Black/clipped references cannot set EV.
    const float source=raw[raw.size()/2], reference=preview[preview.size()/2];
    if (source<=1e-7f || reference<=.0003f || reference>=.95f) return 0;
    if (matched) *matched=true;
    return std::clamp(std::log2(reference/source),-8.0f,8.0f);
}

std::vector<float> loadPreviewLuminance(const std::string& path) {
    return loadPreviewLuminanceWithStats(path, nullptr, nullptr);
}

PreviewExposureDiagnostics previewExposureDiagnostics() {
    std::lock_guard<std::mutex> lock(diagnosticsMutex());
    return globalDiagnosticsState();
}

} // namespace sony2fuji
