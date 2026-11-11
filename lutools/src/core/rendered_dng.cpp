#include "rendered_dng.h"

#include <cstddef>
#include <cstdio>
#include <jpeglib.h>
#include <jerror.h>
#include <tiffio.h>

#include <algorithm>
#include <array>
#include <csetjmp>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <iterator>
#include <limits>
#include <memory>
#include <new>
#include <string_view>
#include <system_error>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#else
#include <fcntl.h>
#include <unistd.h>
#endif

namespace sony2fuji {
namespace {

constexpr uint16_t kLinearRaw = 34892;
constexpr uint32_t kWhiteLevel = std::numeric_limits<uint16_t>::max();
constexpr uint32_t kRowsPerStrip = 64;
constexpr uint64_t kMaxClassicTiffBytes = (uint64_t{1} << 32) - 1;
constexpr uint32_t kThumbnailLongEdge = 160;
constexpr int kPreviewJpegQuality = 95;

// The reservation covers the classic TIFF header/IFD, DNG value arrays, and
// the neutral XMP packet. It is deliberately conservative so libtiff never
// has to fall back to a BigTIFF layout after this preflight.
constexpr uint64_t kMetadataReservation = 64 * 1024;

// These are the D65 sRGB primaries adapted to the D50 PCS with Bradford, as
// defined by the rendered-DNG experiment. DNG stores the inverse in
// ColorMatrix1 and the forward matrix in ForwardMatrix1.
constexpr float kColorMatrix[9] = {
    3.1341358529001178f, -1.6173859980180429f, -0.49066221791109732f,
    -0.97879547655577737f, 1.9162543773959879f, 0.033442873390366848f,
    0.071955392557947362f, -0.22897675981518195f, 1.4053860351131175f,
};
constexpr float kForwardMatrix[9] = {
    0.43606574687426941f, 0.38515150959015992f, 0.1430784199651387f,
    0.22249317711056515f, 0.71688701309448266f, 0.060619809794952378f,
    0.013923921463169377f, 0.097081324231410165f, 0.71409935681588099f,
};

// Keep the neutral Adobe Camera Raw settings identical to the verified
// experiment. This prevents a second tone, sharpening, noise, or effects pass.
constexpr char kNeutralXmp[] =
    "<x:xmpmeta xmlns:crs=\"http://ns.adobe.com/camera-raw-settings/1.0/\" "
    "xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\" "
    "xmlns:x=\"adobe:ns:meta/\"><rdf:RDF><rdf:Description rdf:about=\"\" "
    "crs:Version=\"16.0\" crs:ProcessVersion=\"11.0\" crs:HasSettings=\"True\" "
    "crs:AlreadyApplied=\"False\" crs:WhiteBalance=\"As Shot\" crs:AutoTone=\"False\" "
    "crs:Exposure2012=\"0.00\" crs:Contrast2012=\"0\" crs:Highlights2012=\"0\" "
    "crs:Shadows2012=\"0\" crs:Whites2012=\"0\" crs:Blacks2012=\"0\" "
    "crs:Clarity2012=\"0\" crs:Texture=\"0\" crs:Dehaze=\"0\" crs:Vibrance=\"0\" "
    "crs:Saturation=\"0\" crs:Sharpness=\"0\" crs:LuminanceSmoothing=\"0\" "
    "crs:ColorNoiseReduction=\"0\" crs:VignetteAmount=\"0\" "
    "crs:PostCropVignetteAmount=\"0\" crs:GrainAmount=\"0\" "
    "crs:LensProfileEnable=\"0\" crs:AutoLateralCA=\"0\" "
    "crs:ToneCurveName2012=\"Linear\"><crs:ToneCurvePV2012><rdf:Seq>"
    "<rdf:li>0, 0</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq>"
    "</crs:ToneCurvePV2012><crs:ToneCurvePV2012Red><rdf:Seq>"
    "<rdf:li>0, 0</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq>"
    "</crs:ToneCurvePV2012Red><crs:ToneCurvePV2012Green><rdf:Seq>"
    "<rdf:li>0, 0</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq>"
    "</crs:ToneCurvePV2012Green><crs:ToneCurvePV2012Blue><rdf:Seq>"
    "<rdf:li>0, 0</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq>"
    "</crs:ToneCurvePV2012Blue></rdf:Description></rdf:RDF></x:xmpmeta>";

constexpr TIFFFieldInfo kCustomFields[] = {
    {TIFFTAG_COLORIMETRICREFERENCE, 1, 1, TIFF_SHORT, FIELD_CUSTOM, 1, 0,
     const_cast<char*>("ColorimetricReference")},
    {TIFFTAG_PROFILENAME, TIFF_VARIABLE, TIFF_VARIABLE, TIFF_ASCII, FIELD_CUSTOM, 1, 0,
     const_cast<char*>("ProfileName")},
    {TIFFTAG_PROFILETONECURVE, TIFF_VARIABLE, TIFF_VARIABLE, TIFF_FLOAT, FIELD_CUSTOM, 1, 1,
     const_cast<char*>("ProfileToneCurve")},
    {TIFFTAG_FORWARDMATRIX1, TIFF_VARIABLE, TIFF_VARIABLE, TIFF_SRATIONAL, FIELD_CUSTOM, 1, 1,
     const_cast<char*>("ForwardMatrix1")},
    {TIFFTAG_BASELINEEXPOSUREOFFSET, 1, 1, TIFF_SRATIONAL, FIELD_CUSTOM, 1, 0,
     const_cast<char*>("BaselineExposureOffset")},
    {TIFFTAG_DEFAULTBLACKRENDER, 1, 1, TIFF_LONG, FIELD_CUSTOM, 1, 0,
     const_cast<char*>("DefaultBlackRender")},
    {TIFFTAG_PREVIEWAPPLICATIONNAME, TIFF_VARIABLE, TIFF_VARIABLE, TIFF_ASCII, FIELD_CUSTOM, 1, 0,
     const_cast<char*>("PreviewApplicationName")},
    {TIFFTAG_PREVIEWCOLORSPACE, 1, 1, TIFF_LONG, FIELD_CUSTOM, 1, 0,
     const_cast<char*>("PreviewColorSpace")},
};

bool registerCustomFields(TIFF* tif) {
    return TIFFMergeFieldInfo(tif, kCustomFields,
                              static_cast<uint32_t>(std::size(kCustomFields))) == 0;
}

#ifndef _WIN32
void closeFileDescriptor(int fd) noexcept {
    if (fd >= 0) ::close(fd);
}
#endif

void removeFileNoThrow(const std::filesystem::path& path) noexcept {
    if (path.empty()) return;
    try {
        std::error_code error;
        std::filesystem::remove(path, error);
    } catch (...) {
        // Cleanup is best effort after an earlier failure. The staging file is
        // never published unless the rename below succeeds.
    }
}

class StagingFile final {
public:
    StagingFile() = default;
    StagingFile(const StagingFile&) = delete;
    StagingFile& operator=(const StagingFile&) = delete;

    ~StagingFile() { cleanup(); }

    bool create(const std::filesystem::path& destination) {
#ifdef _WIN32
        wchar_t temporaryName[MAX_PATH] = {};
        try {
            std::filesystem::path parent = destination.parent_path();
            if (parent.empty()) parent = L".";
            const std::wstring parentString = parent.wstring();
            if (GetTempFileNameW(parentString.c_str(), L"rld", 0, temporaryName) == 0)
                return false;

            path_ = std::filesystem::path(temporaryName);
            handle_ = CreateFileW(
                path_.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
                FILE_ATTRIBUTE_TEMPORARY, nullptr);
            if (handle_ == INVALID_HANDLE_VALUE) {
                DeleteFileW(temporaryName);
                return false;
            }

            // Win32 libtiff expects the native HANDLE's significant 32 bits,
            // not a CRT descriptor produced by _open_osfhandle.
            tif_ = TIFFFdOpen(static_cast<int>(reinterpret_cast<intptr_t>(handle_)),
                             "rawlab-rendered-dng-staging", "w");
            if (!tif_) return false;
            handle_ = INVALID_HANDLE_VALUE; // libtiff owns the HANDLE on success.
            return true;
        } catch (...) {
            cleanup();
            if (temporaryName[0] != L'\0') DeleteFileW(temporaryName);
            throw;
        }
#else
        std::vector<char> temporaryName;
        int createdFd = -1;
        try {
            std::filesystem::path parent = destination.parent_path();
            if (parent.empty()) parent = ".";
            std::string basename = destination.filename().string();
            if (basename.empty()) basename = "rendered";
            const std::string pattern =
                (parent / (basename + ".rawlab-rendered-dng-XXXXXX")).string();
            temporaryName.assign(pattern.begin(), pattern.end());
            temporaryName.push_back('\0');
            createdFd = ::mkstemp(temporaryName.data());
            if (createdFd < 0) return false;

            path_ = std::filesystem::path(temporaryName.data());
            fd_ = createdFd;
            createdFd = -1;
            tif_ = TIFFFdOpen(fd_, path_.c_str(), "w");
            if (!tif_) return false;
            fd_ = -1; // libtiff owns the descriptor after TIFFFdOpen succeeds.
            return true;
        } catch (...) {
            closeFileDescriptor(createdFd);
            cleanup();
            if (!temporaryName.empty()) ::unlink(temporaryName.data());
            throw;
        }
#endif
    }

    TIFF* tif() const noexcept { return tif_; }

    bool publish(const std::filesystem::path& destination) {
        closeTiff();
#ifdef _WIN32
        const std::wstring source = path_.wstring();
        const std::wstring target = destination.wstring();
        const bool published = MoveFileExW(
            source.c_str(), target.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
#else
        const bool published = ::rename(path_.c_str(), destination.c_str()) == 0;
#endif
        if (!published) return false;
        published_ = true;
        path_.clear();
        return true;
    }

private:
    void closeTiff() noexcept {
        if (tif_) {
            TIFFClose(tif_);
            tif_ = nullptr;
        }
#ifdef _WIN32
        if (handle_ != INVALID_HANDLE_VALUE) {
            CloseHandle(handle_);
            handle_ = INVALID_HANDLE_VALUE;
        }
#else
        if (fd_ >= 0) {
            closeFileDescriptor(fd_);
            fd_ = -1;
        }
#endif
    }

    void cleanup() noexcept {
        closeTiff();
        if (!published_) removeFileNoThrow(path_);
        path_.clear();
    }

    std::filesystem::path path_;
    TIFF* tif_ = nullptr;
#ifdef _WIN32
    HANDLE handle_ = INVALID_HANDLE_VALUE;
#else
    int fd_ = -1;
#endif
    bool published_ = false;
};

float inverseSrgb(float encoded) {
    const double value = std::clamp(static_cast<double>(encoded), 0.0, 1.0);
    const double linear = value <= 0.04045
        ? value / 12.92
        : std::pow((value + 0.055) / 1.055, 2.4);
    return static_cast<float>(linear);
}

uint16_t linear16(float encoded) {
    return static_cast<uint16_t>(std::lround(static_cast<double>(inverseSrgb(encoded)) * kWhiteLevel));
}

bool validImage(const ImageData& image) {
    if (image.width <= 0 || image.height <= 0) return false;
    const uint64_t pixelCount = static_cast<uint64_t>(image.width) *
        static_cast<uint64_t>(image.height);
    if (pixelCount != image.pixels.size()) return false;
    for (const RGB& pixel : image.pixels) {
        if (!std::isfinite(pixel.r) || !std::isfinite(pixel.g) ||
            !std::isfinite(pixel.b)) return false;
    }
    return true;
}

struct PreviewSize {
    uint32_t width;
    uint32_t height;
};

PreviewSize previewSize(uint32_t width, uint32_t height, uint32_t maxLongEdge) {
    const uint32_t longEdge = std::max(width, height);
    if (longEdge <= maxLongEdge) return {width, height};
    return {
        std::max(1u, static_cast<uint32_t>(static_cast<uint64_t>(width) * maxLongEdge / longEdge)),
        std::max(1u, static_cast<uint32_t>(static_cast<uint64_t>(height) * maxLongEdge / longEdge)),
    };
}

bool setPreviewFields(TIFF* tif, PreviewSize size, bool orientation) {
    bool ok = registerCustomFields(tif);
    ok = ok && TIFFSetField(tif, TIFFTAG_SUBFILETYPE, uint32_t{1});
    ok = ok && TIFFSetField(tif, TIFFTAG_IMAGEWIDTH, size.width);
    ok = ok && TIFFSetField(tif, TIFFTAG_IMAGELENGTH, size.height);
    ok = ok && TIFFSetField(tif, TIFFTAG_BITSPERSAMPLE, uint16_t{8});
    ok = ok && TIFFSetField(tif, TIFFTAG_SAMPLESPERPIXEL, uint16_t{3});
    ok = ok && TIFFSetField(tif, TIFFTAG_COMPRESSION, uint16_t{COMPRESSION_JPEG});
    ok = ok && TIFFSetField(tif, TIFFTAG_PHOTOMETRIC, uint16_t{PHOTOMETRIC_YCBCR});
    ok = ok && TIFFSetField(tif, TIFFTAG_PLANARCONFIG, uint16_t{PLANARCONFIG_CONTIG});
    ok = ok && TIFFSetField(tif, TIFFTAG_ROWSPERSTRIP, size.height);
    ok = ok && TIFFSetField(tif, TIFFTAG_YCBCRSUBSAMPLING, uint16_t{2}, uint16_t{2});
    ok = ok && TIFFSetField(tif, TIFFTAG_YCBCRPOSITIONING, uint16_t{YCBCRPOSITION_CENTERED});
    if (orientation) ok = ok && TIFFSetField(tif, TIFFTAG_ORIENTATION, uint16_t{ORIENTATION_TOPLEFT});
    ok = ok && TIFFSetField(tif, TIFFTAG_XRESOLUTION, 1.0f);
    ok = ok && TIFFSetField(tif, TIFFTAG_YRESOLUTION, 1.0f);
    ok = ok && TIFFSetField(tif, TIFFTAG_RESOLUTIONUNIT, uint16_t{RESUNIT_NONE});
    ok = ok && TIFFSetField(tif, TIFFTAG_IMAGEDESCRIPTION, "Baked display-sRGB render; not sensor RAW.");
    ok = ok && TIFFSetField(tif, TIFFTAG_MAKE, "RawLab");
    ok = ok && TIFFSetField(tif, TIFFTAG_MODEL, "Rendered sRGB");
    ok = ok && TIFFSetField(tif, TIFFTAG_SOFTWARE, "RawLab rendered DNG");
    ok = ok && TIFFSetField(tif, TIFFTAG_PREVIEWAPPLICATIONNAME, "RawLab");
    ok = ok && TIFFSetField(tif, TIFFTAG_PREVIEWCOLORSPACE, uint32_t{2});
    return ok;
}

struct JpegError {
    jpeg_error_mgr manager{};
    std::jmp_buf jump;
};

struct JpegDestination {
    jpeg_destination_mgr manager{};
    TIFF* tif = nullptr;
    uint64_t* remaining = nullptr;
    bool tooLarge = false;
    bool ioError = false;
    std::array<JOCTET, 65536> buffer{};

    bool write(size_t count) {
        if (count > *remaining) {
            tooLarge = true;
            return false;
        }
        if (count && TIFFWriteRawStrip(tif, 0, buffer.data(), static_cast<tmsize_t>(count)) !=
                         static_cast<tmsize_t>(count)) {
            ioError = true;
            return false;
        }
        *remaining -= count;
        return true;
    }

    static void init(j_compress_ptr codec) {
        auto& dest = *reinterpret_cast<JpegDestination*>(codec->dest);
        dest.manager.next_output_byte = dest.buffer.data();
        dest.manager.free_in_buffer = dest.buffer.size();
    }

    static boolean flush(j_compress_ptr codec) {
        auto& dest = *reinterpret_cast<JpegDestination*>(codec->dest);
        if (!dest.write(dest.buffer.size())) ERREXIT(codec, JERR_FILE_WRITE);
        dest.manager.next_output_byte = dest.buffer.data();
        dest.manager.free_in_buffer = dest.buffer.size();
        return TRUE;
    }

    static void finish(j_compress_ptr codec) {
        auto& dest = *reinterpret_cast<JpegDestination*>(codec->dest);
        if (!dest.write(dest.buffer.size() - dest.manager.free_in_buffer))
            ERREXIT(codec, JERR_FILE_WRITE);
    }
};

void makePreviewRow(const ImageData& image, PreviewSize size, uint32_t y, std::vector<uint8_t>& row) {
    const uint64_t sourceWidth = static_cast<uint64_t>(image.width);
    const uint64_t sourceHeight = static_cast<uint64_t>(image.height);
    if (sourceWidth == size.width && sourceHeight == size.height) {
        for (uint32_t x = 0; x < size.width; ++x) {
            const RGB& pixel = image.at(static_cast<int>(x), static_cast<int>(y));
            const size_t offset = static_cast<size_t>(x) * 3;
            row[offset] = static_cast<uint8_t>(std::lround(std::clamp(pixel.r, 0.0f, 1.0f) * 255));
            row[offset + 1] = static_cast<uint8_t>(std::lround(std::clamp(pixel.g, 0.0f, 1.0f) * 255));
            row[offset + 2] = static_cast<uint8_t>(std::lround(std::clamp(pixel.b, 0.0f, 1.0f) * 255));
        }
        return;
    }

    // Integrate each output pixel's source area to avoid aliasing fine detail.
    // Coordinates use integer units of the destination dimensions, so partial
    // edge pixels receive their exact proportional weight.
    const uint64_t top = static_cast<uint64_t>(y) * sourceHeight;
    const uint64_t bottom = static_cast<uint64_t>(y + 1) * sourceHeight;
    const uint64_t firstY = top / size.height;
    const uint64_t endY = (bottom - 1) / size.height + 1;
    const double scale = 255.0 / static_cast<double>(sourceWidth * sourceHeight);
    for (uint32_t x = 0; x < size.width; ++x) {
        const uint64_t left = static_cast<uint64_t>(x) * sourceWidth;
        const uint64_t right = static_cast<uint64_t>(x + 1) * sourceWidth;
        const uint64_t firstX = left / size.width;
        const uint64_t endX = (right - 1) / size.width + 1;
        double r = 0, g = 0, b = 0;
        for (uint64_t sourceY = firstY; sourceY < endY; ++sourceY) {
            const uint64_t weightY = std::min(bottom, (sourceY + 1) * size.height) -
                std::max(top, sourceY * size.height);
            for (uint64_t sourceX = firstX; sourceX < endX; ++sourceX) {
                const uint64_t weightX = std::min(right, (sourceX + 1) * size.width) -
                    std::max(left, sourceX * size.width);
                const double weight = static_cast<double>(weightX * weightY);
                const RGB& pixel = image.at(static_cast<int>(sourceX), static_cast<int>(sourceY));
                r += std::clamp(pixel.r, 0.0f, 1.0f) * weight;
                g += std::clamp(pixel.g, 0.0f, 1.0f) * weight;
                b += std::clamp(pixel.b, 0.0f, 1.0f) * weight;
            }
        }
        const size_t offset = static_cast<size_t>(x) * 3;
        row[offset] = static_cast<uint8_t>(std::lround(std::clamp(r * scale, 0.0, 255.0)));
        row[offset + 1] = static_cast<uint8_t>(std::lround(std::clamp(g * scale, 0.0, 255.0)));
        row[offset + 2] = static_cast<uint8_t>(std::lround(std::clamp(b * scale, 0.0, 255.0)));
    }
}

ErrorCode writeJpegPreview(TIFF* tif, const ImageData& image, PreviewSize size, uint64_t& remaining) {
    struct State {
        jpeg_compress_struct codec{};
        JpegError error{};
        JpegDestination destination{};
        std::vector<uint8_t> row;
        ~State() { jpeg_destroy_compress(&codec); }
    };
    auto state = std::make_unique<State>();
    state->row.resize(static_cast<size_t>(size.width) * 3);
    state->codec.err = jpeg_std_error(&state->error.manager);
    state->error.manager.error_exit = [](j_common_ptr codec) {
        std::longjmp(reinterpret_cast<JpegError*>(codec->err)->jump, 1);
    };
    if (setjmp(state->error.jump)) {
        if (state->destination.tooLarge) return ErrorCode::ProcessingError;
        if (state->destination.ioError) return ErrorCode::IOError;
        return state->error.manager.msg_code == JERR_OUT_OF_MEMORY ? ErrorCode::OutOfMemory : ErrorCode::ProcessingError;
    }
    jpeg_create_compress(&state->codec);
    auto& dest = state->destination;
    dest.tif = tif;
    dest.remaining = &remaining;
    dest.manager.init_destination = JpegDestination::init;
    dest.manager.empty_output_buffer = JpegDestination::flush;
    dest.manager.term_destination = JpegDestination::finish;
    state->codec.dest = &dest.manager;
    state->codec.image_width = size.width;
    state->codec.image_height = size.height;
    state->codec.input_components = 3;
    state->codec.in_color_space = JCS_RGB;
    jpeg_set_defaults(&state->codec);
    jpeg_set_quality(&state->codec, kPreviewJpegQuality, TRUE);
    jpeg_start_compress(&state->codec, TRUE);
    while (state->codec.next_scanline < size.height) {
        makePreviewRow(image, size, state->codec.next_scanline, state->row);
        JSAMPROW row = state->row.data();
        jpeg_write_scanlines(&state->codec, &row, 1);
    }
    jpeg_finish_compress(&state->codec);
    return ErrorCode::Success;
}

} // namespace

ErrorCode saveRenderedDNG(const ImageData& image, const std::string& filepath) {
    if (filepath.empty() || !validImage(image)) return ErrorCode::ProcessingError;

    const uint32_t width = static_cast<uint32_t>(image.width);
    const uint32_t height = static_cast<uint32_t>(image.height);
    const uint64_t rowSampleCount = static_cast<uint64_t>(image.width) * 3;
    const uint64_t rowBytes = rowSampleCount * sizeof(uint16_t);
    if (rowSampleCount > std::numeric_limits<size_t>::max() ||
        rowSampleCount > std::vector<uint16_t>().max_size() ||
        rowBytes > static_cast<uint64_t>(std::numeric_limits<size_t>::max()) ||
        rowBytes > static_cast<uint64_t>(std::numeric_limits<tmsize_t>::max()))
        return ErrorCode::ProcessingError;

    if (rowBytes != 0 && static_cast<uint64_t>(height) >
            std::numeric_limits<uint64_t>::max() / rowBytes)
        return ErrorCode::ProcessingError;
    const uint64_t pixelBytes = rowBytes * height;
    const uint64_t stripCount =
        (static_cast<uint64_t>(height) + kRowsPerStrip - 1) / kRowsPerStrip;
    const uint64_t stripTableBytes = stripCount * sizeof(uint32_t) * 2;
    const uint64_t metadataBytes = kMetadataReservation + (sizeof(kNeutralXmp) - 1);
    if (pixelBytes > kMaxClassicTiffBytes ||
        stripTableBytes > kMaxClassicTiffBytes - pixelBytes ||
        metadataBytes > kMaxClassicTiffBytes - pixelBytes - stripTableBytes)
        return ErrorCode::ProcessingError;
    uint64_t previewBytesRemaining = kMaxClassicTiffBytes - pixelBytes - stripTableBytes - metadataBytes;

    const size_t rowSamples = static_cast<size_t>(rowSampleCount);

    std::filesystem::path outputPath;
    try {
#ifdef _WIN32
        outputPath = std::filesystem::u8path(filepath);
#else
        outputPath = std::filesystem::path(filepath);
#endif
    } catch (...) {
        return ErrorCode::IOError;
    }

    StagingFile staging;
    try {
        if (!staging.create(outputPath)) return ErrorCode::IOError;
    } catch (const std::bad_alloc&) {
        return ErrorCode::OutOfMemory;
    } catch (...) {
        return ErrorCode::IOError;
    }
    TIFF* tif = staging.tif();

    const PreviewSize thumbnail = previewSize(width, height, kThumbnailLongEdge);
    const PreviewSize fullPreview = previewSize(width, height, static_cast<uint32_t>(JPEG_MAX_DIMENSION));
    uint64_t subIfdOffsets[2] = {0, 0};
    bool ok = setPreviewFields(tif, thumbnail, true);
    ok = ok && TIFFSetField(tif, TIFFTAG_SUBIFD, uint16_t{2}, subIfdOffsets);

    uint8_t dngVersion[4] = {1, 4, 0, 0};
    uint16_t blackLevelRepeatDim[2] = {1, 1};
    float blackLevel[3] = {0, 0, 0};
    uint32_t whiteLevel[3] = {kWhiteLevel, kWhiteLevel, kWhiteLevel};
    float defaultScale[2] = {1, 1};
    float defaultCropOrigin[2] = {0, 0};
    float defaultCropSize[2] = {static_cast<float>(width), static_cast<float>(height)};
    float analogBalance[3] = {1, 1, 1};
    float asShotWhiteXY[2] = {0.3457f, 0.3585f};
    uint32_t activeArea[4] = {0, 0, height, width};
    float profileToneCurve[4] = {0, 0, 1, 1};
    const uint16_t colorimetricReference = 1;
    const float baselineExposure = 0;
    const float baselineNoise = 1;
    const float baselineSharpness = 1;
    const uint16_t calibrationIlluminant = 23;
    const double baselineExposureOffset = 0.0;
    const uint32_t defaultBlackRender = 1;

    const uint16_t count3 = 3;
    const uint16_t count9 = 9;
    ok = ok && TIFFSetField(tif, TIFFTAG_DNGVERSION, dngVersion);
    ok = ok && TIFFSetField(tif, TIFFTAG_DNGBACKWARDVERSION, dngVersion);
    ok = ok && TIFFSetField(tif, TIFFTAG_UNIQUECAMERAMODEL, "RawLab Rendered sRGB");
    ok = ok && TIFFSetField(tif, TIFFTAG_COLORMATRIX1, count9, kColorMatrix);
    ok = ok && TIFFSetField(tif, TIFFTAG_ANALOGBALANCE, count3, analogBalance);
    ok = ok && TIFFSetField(tif, TIFFTAG_ASSHOTWHITEXY, asShotWhiteXY);
    ok = ok && TIFFSetField(tif, TIFFTAG_BASELINEEXPOSURE, baselineExposure);
    ok = ok && TIFFSetField(tif, TIFFTAG_BASELINENOISE, baselineNoise);
    ok = ok && TIFFSetField(tif, TIFFTAG_BASELINESHARPNESS, baselineSharpness);
    ok = ok && TIFFSetField(tif, TIFFTAG_CALIBRATIONILLUMINANT1, calibrationIlluminant);
    ok = ok && TIFFSetField(tif, TIFFTAG_COLORIMETRICREFERENCE, colorimetricReference);
    ok = ok && TIFFSetField(tif, TIFFTAG_PROFILENAME, "RawLab Baked sRGB");
    ok = ok && TIFFSetField(tif, TIFFTAG_PROFILETONECURVE, count3 + 1, profileToneCurve);
    ok = ok && TIFFSetField(tif, TIFFTAG_FORWARDMATRIX1, count9, kForwardMatrix);
    ok = ok && TIFFSetField(tif, TIFFTAG_BASELINEEXPOSUREOFFSET, baselineExposureOffset);
    ok = ok && TIFFSetField(tif, TIFFTAG_DEFAULTBLACKRENDER, defaultBlackRender);

    const std::string_view xmp(kNeutralXmp, sizeof(kNeutralXmp) - 1);
    ok = ok && TIFFSetField(tif, TIFFTAG_XMLPACKET,
                            static_cast<uint32_t>(xmp.size()),
                            const_cast<char*>(xmp.data()));
    if (!ok) return ErrorCode::IOError;

    try {
        const ErrorCode result = writeJpegPreview(tif, image, thumbnail, previewBytesRemaining);
        if (result != ErrorCode::Success) return result;
    } catch (const std::bad_alloc&) {
        return ErrorCode::OutOfMemory;
    } catch (...) {
        return ErrorCode::ProcessingError;
    }
    if (!TIFFWriteDirectory(tif)) return ErrorCode::IOError;

    ok = TIFFSetField(tif, TIFFTAG_SUBFILETYPE, uint32_t{0});
    ok = ok && TIFFSetField(tif, TIFFTAG_IMAGEWIDTH, width);
    ok = ok && TIFFSetField(tif, TIFFTAG_IMAGELENGTH, height);
    ok = ok && TIFFSetField(tif, TIFFTAG_BITSPERSAMPLE, uint16_t{16});
    ok = ok && TIFFSetField(tif, TIFFTAG_SAMPLESPERPIXEL, uint16_t{3});
    ok = ok && TIFFSetField(tif, TIFFTAG_COMPRESSION, uint16_t{COMPRESSION_NONE});
    ok = ok && TIFFSetField(tif, TIFFTAG_PHOTOMETRIC, uint16_t{kLinearRaw});
    ok = ok && TIFFSetField(tif, TIFFTAG_PLANARCONFIG, uint16_t{PLANARCONFIG_CONTIG});
    ok = ok && TIFFSetField(tif, TIFFTAG_SAMPLEFORMAT, uint16_t{SAMPLEFORMAT_UINT});
    ok = ok && TIFFSetField(tif, TIFFTAG_ROWSPERSTRIP, kRowsPerStrip);
    ok = ok && TIFFSetField(tif, TIFFTAG_BLACKLEVELREPEATDIM, blackLevelRepeatDim);
    ok = ok && TIFFSetField(tif, TIFFTAG_BLACKLEVEL, count3, blackLevel);
    ok = ok && TIFFSetField(tif, TIFFTAG_WHITELEVEL, count3, whiteLevel);
    ok = ok && TIFFSetField(tif, TIFFTAG_DEFAULTSCALE, defaultScale);
    ok = ok && TIFFSetField(tif, TIFFTAG_DEFAULTCROPORIGIN, defaultCropOrigin);
    ok = ok && TIFFSetField(tif, TIFFTAG_DEFAULTCROPSIZE, defaultCropSize);
    ok = ok && TIFFSetField(tif, TIFFTAG_ACTIVEAREA, activeArea);

    std::vector<uint16_t> row;
    try {
        row.resize(rowSamples);
    } catch (const std::bad_alloc&) {
        return ErrorCode::OutOfMemory;
    }
    if (ok) {
        for (uint32_t y = 0; y < height && ok; ++y) {
            for (uint32_t x = 0; x < width; ++x) {
                const RGB& pixel = image.at(static_cast<int>(x), static_cast<int>(y));
                const size_t offset = static_cast<size_t>(x) * 3;
                row[offset] = linear16(pixel.r);
                row[offset + 1] = linear16(pixel.g);
                row[offset + 2] = linear16(pixel.b);
            }
            ok = TIFFWriteScanline(tif, row.data(), y, 0) >= 0;
        }
    }

    if (ok) ok = TIFFFlushData(tif) == 1;
    if (ok) ok = TIFFWriteDirectory(tif) == 1;
    if (!ok) return ErrorCode::IOError;

    if (!setPreviewFields(tif, fullPreview, false)) return ErrorCode::IOError;
    try {
        const ErrorCode result = writeJpegPreview(tif, image, fullPreview, previewBytesRemaining);
        if (result != ErrorCode::Success) return result;
    } catch (const std::bad_alloc&) {
        return ErrorCode::OutOfMemory;
    } catch (...) {
        return ErrorCode::ProcessingError;
    }
    if (!TIFFWriteDirectory(tif) || !TIFFFlush(tif)) return ErrorCode::IOError;
    try {
        if (!staging.publish(outputPath)) return ErrorCode::IOError;
    } catch (const std::bad_alloc&) {
        return ErrorCode::OutOfMemory;
    } catch (...) {
        return ErrorCode::IOError;
    }
    return ErrorCode::Success;
}

} // namespace sony2fuji
