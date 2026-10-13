#include "rendered_dng.h"

#include <tiffio.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <iterator>
#include <limits>
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
constexpr uint32_t kRowsPerStrip = 64;
constexpr uint64_t kMaxClassicTiffBytes = (uint64_t{1} << 32) - 1;

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

} // namespace

ErrorCode saveRenderedDNG(const ImageData& image, const std::string& filepath) {
    if (filepath.empty() || !validImage(image)) return ErrorCode::ProcessingError;

    const uint32_t width = static_cast<uint32_t>(image.width);
    const uint32_t height = static_cast<uint32_t>(image.height);
    const uint64_t rowSampleCount = static_cast<uint64_t>(image.width) * 3;
    const uint64_t rowBytes = rowSampleCount * sizeof(float);
    if (rowSampleCount > std::numeric_limits<size_t>::max() ||
        rowSampleCount > std::vector<float>().max_size() ||
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

    bool ok = registerCustomFields(tif);
    const uint16_t bitsPerSample = 32;
    const uint16_t samplesPerPixel = 3;
    const uint16_t compression = COMPRESSION_NONE;
    const uint16_t photometric = kLinearRaw;
    const uint16_t planar = PLANARCONFIG_CONTIG;
    const uint16_t sampleFormat = SAMPLEFORMAT_IEEEFP;
    const uint32_t rowsPerStrip = kRowsPerStrip;
    const uint16_t orientation = ORIENTATION_TOPLEFT;
    const uint16_t resolutionUnit = RESUNIT_NONE;
    const uint32_t subfileType = 0;

    ok = ok && TIFFSetField(tif, TIFFTAG_SUBFILETYPE, subfileType);
    ok = ok && TIFFSetField(tif, TIFFTAG_IMAGEWIDTH, width);
    ok = ok && TIFFSetField(tif, TIFFTAG_IMAGELENGTH, height);
    ok = ok && TIFFSetField(tif, TIFFTAG_BITSPERSAMPLE, bitsPerSample);
    ok = ok && TIFFSetField(tif, TIFFTAG_COMPRESSION, compression);
    ok = ok && TIFFSetField(tif, TIFFTAG_PHOTOMETRIC, photometric);
    ok = ok && TIFFSetField(tif, TIFFTAG_ORIENTATION, orientation);
    ok = ok && TIFFSetField(tif, TIFFTAG_SAMPLESPERPIXEL, samplesPerPixel);
    ok = ok && TIFFSetField(tif, TIFFTAG_ROWSPERSTRIP, rowsPerStrip);
    ok = ok && TIFFSetField(tif, TIFFTAG_PLANARCONFIG, planar);
    ok = ok && TIFFSetField(tif, TIFFTAG_SAMPLEFORMAT, sampleFormat);
    ok = ok && TIFFSetField(tif, TIFFTAG_XRESOLUTION, 1.0f);
    ok = ok && TIFFSetField(tif, TIFFTAG_YRESOLUTION, 1.0f);
    ok = ok && TIFFSetField(tif, TIFFTAG_RESOLUTIONUNIT, resolutionUnit);
    ok = ok && TIFFSetField(tif, TIFFTAG_IMAGEDESCRIPTION,
                            "Baked display-sRGB render; not sensor RAW.");
    ok = ok && TIFFSetField(tif, TIFFTAG_MAKE, "RawLab");
    ok = ok && TIFFSetField(tif, TIFFTAG_MODEL, "Rendered sRGB");
    ok = ok && TIFFSetField(tif, TIFFTAG_SOFTWARE, "RawLab rendered DNG");

    uint8_t dngVersion[4] = {1, 4, 0, 0};
    uint16_t blackLevelRepeatDim[2] = {1, 1};
    float blackLevel[3] = {0, 0, 0};
    uint32_t whiteLevel[3] = {1, 1, 1};
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
    ok = ok && TIFFSetField(tif, TIFFTAG_BLACKLEVELREPEATDIM, blackLevelRepeatDim);
    ok = ok && TIFFSetField(tif, TIFFTAG_BLACKLEVEL, count3, blackLevel);
    ok = ok && TIFFSetField(tif, TIFFTAG_WHITELEVEL, count3, whiteLevel);
    ok = ok && TIFFSetField(tif, TIFFTAG_DEFAULTSCALE, defaultScale);
    ok = ok && TIFFSetField(tif, TIFFTAG_DEFAULTCROPORIGIN, defaultCropOrigin);
    ok = ok && TIFFSetField(tif, TIFFTAG_DEFAULTCROPSIZE, defaultCropSize);
    ok = ok && TIFFSetField(tif, TIFFTAG_COLORMATRIX1, count9, kColorMatrix);
    ok = ok && TIFFSetField(tif, TIFFTAG_ANALOGBALANCE, count3, analogBalance);
    ok = ok && TIFFSetField(tif, TIFFTAG_ASSHOTWHITEXY, asShotWhiteXY);
    ok = ok && TIFFSetField(tif, TIFFTAG_BASELINEEXPOSURE, baselineExposure);
    ok = ok && TIFFSetField(tif, TIFFTAG_BASELINENOISE, baselineNoise);
    ok = ok && TIFFSetField(tif, TIFFTAG_BASELINESHARPNESS, baselineSharpness);
    ok = ok && TIFFSetField(tif, TIFFTAG_CALIBRATIONILLUMINANT1, calibrationIlluminant);
    ok = ok && TIFFSetField(tif, TIFFTAG_ACTIVEAREA, activeArea);
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

    std::vector<float> row;
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
                row[offset] = inverseSrgb(pixel.r);
                row[offset + 1] = inverseSrgb(pixel.g);
                row[offset + 2] = inverseSrgb(pixel.b);
            }
            ok = TIFFWriteScanline(tif, row.data(), y, 0) >= 0;
        }
    }

    if (ok) ok = TIFFFlushData(tif) == 1;
    if (ok) ok = TIFFWriteDirectory(tif) == 1;
    if (ok) ok = TIFFFlush(tif) == 1;
    if (!ok) return ErrorCode::IOError;
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
