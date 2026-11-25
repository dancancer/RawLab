#include "platform/hdr_image.h"
#include "platform/hdr_heif.h"
#include "platform/hdr_metadata.h"
#include "core/atomic_output_transaction.h"
#include "core/hdr_jpeg.h"
#include "core/hdr_progress.h"
#include "core/hdr_srgb_lut.h"
#include "core/parallel_pixels.h"
#include "core/pinned_source_file.h"
#include "core/proraw_source.h"
#include "core/processing_cancellation.h"
#include "core/sha256.h"
#include "sony2fuji/raw_processor.h"
#include <lcms2.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <memory>
#include <string>
#ifdef _WIN32
#include <windows.h>
#include <psapi.h>
#elif defined(__APPLE__)
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <unistd.h>
#else
#include <sys/sysinfo.h>
#include <unistd.h>
#endif

namespace sony2fuji::hdr {
namespace {
std::atomic<uint64_t> nextRevision{1};
bool hasDigest(const uint8_t sha[32]) {
    return std::any_of(sha, sha + 32, [](uint8_t value) { return value != 0; });
}
[[noreturn]] void fail(RenderStatus status, uint32_t reason, const char* message) {
    throw Error(status, reason, kHdrFieldPath, message);
}
bool has(const std::vector<uint8_t>& bytes,const char* text) {
    return std::search(bytes.begin(),bytes.end(),text,text+std::strlen(text))!=bytes.end();
}
struct StreamSourcePinImpl {
    PinnedSourceFile pinned;
    bool isTiff = false;
    std::vector<uint8_t> rawExif;
    uint8_t digest[32]{};
};
struct File {
    std::vector<uint8_t> bytes;
    HDRSourceInfo info{};
    bool jpeg=false;
    AppleGainMapMetadata apple;
    PinnedSourceFile pinned;
};
File readFile(const char* name, const uint8_t* expectedSHA256 = nullptr) {
    if (!name) fail(RenderStatus::InvalidArgument, kHdrReasonInvalidArgument, "Invalid HDR source path");
    const auto path=std::filesystem::u8path(name);
    File file;
    PinnedSourceOptions options;
    options.maxBytes = 512ull * 1024 * 1024;
    options.allowEmpty = (expectedSHA256 != nullptr);
    options.checkCancellation = true;
    options.computeSha256 = true;
    options.rejectSymlink = false;
    options.expectedSha256 = expectedSHA256;
    options.beforeAlloc = [](uint64_t size) { admitMemory(size * 3); };
    const auto status = PinnedSourceFile::pinAndRead(path, options, file.pinned, file.bytes);
    switch (status) {
        case SourcePinStatus::Ok:
            break;
        case SourcePinStatus::SourceChanged:
            fail(RenderStatus::InvalidArgument, kHdrReasonSourceChanged, "HDR metadata source changed");
        case SourcePinStatus::TooLarge:
            fail(RenderStatus::IoError, kHdrReasonInputIo, "HDR compressed input exceeds the file budget");
        case SourcePinStatus::Cancelled:
            throw ProcessingCancelled();
        case SourcePinStatus::InvalidPath:
        case SourcePinStatus::IoError:
            fail(RenderStatus::IoError, kHdrReasonInputIo, "HDR input is not a readable regular file");
    }
    const uint64_t size = file.bytes.size();
    if (!size) fail(RenderStatus::IoError, kHdrReasonInputIo, "HDR compressed input exceeds the file budget");
    file.jpeg=size>=2 && file.bytes[0]==255 && file.bytes[1]==0xd8;
    const bool heif=size>=12 && std::memcmp(file.bytes.data()+4,"ftyp",4)==0;
    const bool xmp=has(file.bytes,"http://ns.adobe.com/hdr-gain-map/1.0/");
    const bool iso=has(file.bytes,"urn:iso:std:iso:ts:21496:-1");
    const bool apple=has(file.bytes,"urn:com:apple:photo:2020:aux:hdrgainmap") ||
        has(file.bytes,"http://ns.apple.com/HDRGainMap/1.0/");
    if (file.jpeg) {
        if (!xmp && !iso && !apple) {
            fail(RenderStatus::Unsupported, kHdrReasonNotHdr, "No HDR gain map");
        }
        const auto jpeg=apple && !iso ? probeAppleJPEG(file.bytes.data(),file.bytes.size()) : probeJPEG(file.bytes.data(),file.bytes.size());
        const auto exif=jpegExif(file.bytes.data(),file.bytes.size());
        file.info.width=jpeg.width; file.info.height=jpeg.height;
        file.info.orientation=exifOrientation(exif.data(),exif.size());
        file.info.container=kHdrContainerJpeg;
        file.info.protocol=iso ? (xmp ? kHdrProtocolIsoXmp : kHdrProtocolIso) : kHdrProtocolXmp;
        file.info.colorDescription=jpegColorDescription(file.bytes.data(),file.bytes.size(),apple && !iso);
        if (!file.info.colorDescription)
            fail(RenderStatus::Unsupported, kHdrReasonUnsupportedColor, "HDR JPEG has no supported RGB profile");
        file.info.contentHeadroom=jpeg.headroom;
        if(apple && !iso) {
            const auto metadata=jpegGainMapXMP(file.bytes.data(),file.bytes.size());
            file.apple=appleGainMapMetadata(metadata.data(),metadata.size());
            const float headroom=file.apple.headroom;
            file.info.protocol=kHdrProtocolApple;
            file.info.contentHeadroom=headroom ? headroom : appleHeadroom(exif.data(),exif.size());
        }
        file.info.headroomKind=kHdrHeadroomDeclared;
    } else if (heif) file.info=probeHEIF(file.bytes.data(),file.bytes.size());
    else {
        if (xmp || iso || apple) fail(RenderStatus::Unsupported, kHdrReasonUnsupportedProtocol, "Unsupported declared HDR container");
        fail(RenderStatus::Unsupported, kHdrReasonNotHdr, "No HDR gain map");
    }
    std::copy(file.pinned.sha256().begin(), file.pinned.sha256().end(), file.info.sourceSha256);
    return file;
}
void orient(ImageData& image,uint32_t orientation) {
    GeometryOptions options;
    switch (orientation) {
        case 2: options.flip_horizontal=true; break;
        case 3: options.quarter_turns=2; break;
        case 4: options.flip_vertical=true; break;
        case 5: options.quarter_turns=1; options.flip_horizontal=true; break;
        case 6: options.quarter_turns=1; break;
        case 7: options.quarter_turns=1; options.flip_vertical=true; break;
        case 8: options.quarter_turns=3; break;
    }
    if (applyGeometry(image,options)!=ErrorCode::Success)
        fail(RenderStatus::ProcessingError, kHdrReasonInvalidBuffer, "HDR orientation failed");
}
bool isTIFF(const char* source) {
    std::ifstream input(std::filesystem::u8path(source), std::ios::binary);
    char magic[4]{}; input.read(magic, sizeof(magic));
    return input.gcount() == 4 && (!std::memcmp(magic,"II*\0",4) || !std::memcmp(magic,"MM\0*",4));
}
std::string fileDigest(const char* source) {
    checkProcessingCancellation();
    recordSourceHashPass();
    try { return hash::sha256File(source, checkProcessingCancellation); }
    catch (const ProcessingCancelled&) { throw; }
    catch (const std::runtime_error&) {
        fail(RenderStatus::IoError, kHdrReasonInputIo, "Cannot verify HDR metadata source");
    }
}
void verifyDigest(const char* source, const uint8_t sha[32]) {
    const std::string digest = fileDigest(source);
    const auto hex = [](char c) { return c <= '9' ? c - '0' : c - 'a' + 10; };
    for (size_t i = 0; i < 32; ++i) if (uint8_t(hex(digest[2*i])*16 + hex(digest[2*i+1])) != sha[i])
        fail(RenderStatus::InvalidArgument, kHdrReasonSourceChanged, "HDR metadata source changed");
    checkProcessingCancellation();
}
void differentFile(const char* source, const char* output) {
    if (!source || !output) return;
    if (PinnedSourceFile::isSameFile(std::filesystem::u8path(source), std::filesystem::u8path(output)))
        fail(RenderStatus::InvalidArgument, kHdrReasonSameFile, "HDR output must not replace the source");
}
std::vector<uint8_t> captureMetadata(const char* source,const uint8_t sha[32],uint32_t width,uint32_t height) {
    std::vector<uint8_t> exif;
    if (source) {
        if (isTIFF(source)) {
            verifyDigest(source,sha);
            (void)probeProRAW(source);
            const auto path = std::filesystem::u8path(source);
            return sanitizedDNGExif(path,width,height);
        }
        auto file=readFile(source,sha);
        exif=file.jpeg ? jpegExif(file.bytes.data(),file.bytes.size()) : heifExif(file.bytes.data(),file.bytes.size());
    }
    return sanitizedExif(exif.data(),exif.size(),width,height);
}
void publishAtomicBytes(const char* target, const std::vector<uint8_t>& bytes,
    const std::function<bool()>& preCommitCheck = {}) {
    if (!target) fail(RenderStatus::OutputIoError, kHdrReasonOutputIo, "Cannot create HDR output transaction");
    AtomicOutputOptions options;
    options.stagingPrefix = ".rawlab-hdr";
    options.modePolicy = OutputModePolicy::PreserveDestinationOrUmask;
    options.rejectSymlinkTarget = false;
    options.syncFile = true;
    AtomicOutputTransaction tx(std::filesystem::u8path(target), options);
    if (tx.begin() != AtomicOutputStatus::Ok)
        fail(RenderStatus::OutputIoError, kHdrReasonOutputIo, "Cannot create HDR output transaction");
    if (tx.writeAll(bytes.data(), bytes.size(), false) != AtomicOutputStatus::Ok)
        fail(RenderStatus::OutputIoError, kHdrReasonOutputIo, "Cannot write HDR output");
    if (tx.commit(preCommitCheck) != AtomicOutputStatus::Ok)
        fail(RenderStatus::OutputIoError, kHdrReasonOutputIo, "Cannot publish HDR output");
}
std::vector<uint8_t> srgbICC(const std::vector<uint8_t>& jpeg) {
    static const std::vector<uint8_t> icc = []() -> std::vector<uint8_t> {
        auto profile = cmsCreate_sRGBProfile();
        if (!profile) throw std::bad_alloc();
        cmsUInt32Number size = 0;
        bool okay = cmsSaveProfileToMem(profile, nullptr, &size) != 0;
        std::vector<uint8_t> bytes(size);
        okay = okay && cmsSaveProfileToMem(profile, bytes.data(), &size) != 0;
        cmsCloseProfile(profile);
        if (!okay || size > 65519) throw std::runtime_error("Cannot encode SDR RGB profile");
        if (bytes.size() >= 128 && std::memcmp(bytes.data() + 36, "acsp", 4) == 0) {
            static constexpr uint8_t kFixedUtcDate[12] = {
                0x07, 0xEA, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
            };
            std::memcpy(bytes.data() + 24, kFixedUtcDate, sizeof(kFixedUtcDate));
        }
        return bytes;
    }();
    const uint32_t length = uint32_t(icc.size()) + 16;
    std::vector<uint8_t> output{255,0xd8,255,0xe2,uint8_t(length>>8),uint8_t(length),'I','C','C','_','P','R','O','F','I','L','E',0,1,1};
    output.insert(output.end(), icc.begin(), icc.end());
    output.insert(output.end(), jpeg.begin() + 2, jpeg.end());
    return output;
}
}

void admitMemory(uint64_t additionalBytes) {
    uint64_t total=0,available=0,resident=0;
#ifdef _WIN32
    MEMORYSTATUSEX memory{}; memory.dwLength=sizeof(memory);
    PROCESS_MEMORY_COUNTERS_EX process{}; process.cb=sizeof(process);
    if (GlobalMemoryStatusEx(&memory) && GetProcessMemoryInfo(GetCurrentProcess(),reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&process),sizeof(process))) {
        total=memory.ullTotalPhys; available=memory.ullAvailPhys; resident=process.PrivateUsage;
    }
#elif defined(__APPLE__)
    size_t size=sizeof(total); sysctlbyname("hw.memsize",&total,&size,nullptr,0);
    task_vm_info_data_t task{}; mach_msg_type_number_t count=TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(),TASK_VM_INFO,reinterpret_cast<task_info_t>(&task),&count)==KERN_SUCCESS) resident=task.phys_footprint;
    available=total;
#else
    struct sysinfo memory{};
    if (!sysinfo(&memory)) {
        total=uint64_t(memory.totalram)*memory.mem_unit;
        available=uint64_t(memory.freeram+memory.bufferram)*memory.mem_unit;
    }
    std::ifstream status("/proc/meminfo"); std::string key,unit; uint64_t value;
    while (status>>key>>value>>unit) if (key=="MemAvailable:") { available=value*1024; break; }
    std::ifstream process("/proc/self/statm"); uint64_t pages=0,used=0;
    if (process>>pages>>used) resident=used*uint64_t(sysconf(_SC_PAGESIZE));
#endif
    const uint64_t limit=total/2;
    available=std::min(available,resident<limit ? limit-resident : 0);
    if (!total || !available || additionalBytes>available*.65)
        fail(RenderStatus::OutOfMemory, kHdrReasonOutOfMemory, "HDR task exceeds current memory budget");
}
// Mac 上的可移植适配器测试也必须完全覆盖平台符号，不能链接回 Apple 对象。
void admitStreamingMemory(uint64_t additionalBytes) { admitMemory(additionalBytes); }
void validateStreamSource(const HDRExportConfig& config, uint32_t width, uint32_t height,
    const char* path, StreamSourcePin& pin) {
    differentFile(config.metadataSourcePath, path);
    HDRSourceInfo info;
    auto impl = std::make_unique<StreamSourcePinImpl>();
    const auto sourcePath = std::filesystem::u8path(config.metadataSourcePath);
    if (isTIFF(config.metadataSourcePath)) {
        impl->isTiff = true;
        PinnedSourceOptions pinOpts;
        pinOpts.maxBytes = 512ull * 1024 * 1024;
        pinOpts.allowEmpty = false;
        pinOpts.checkCancellation = true;
        pinOpts.computeSha256 = true;
        pinOpts.rejectSymlink = false;
        pinOpts.expectedSha256 = hasDigest(config.sourceSha256) ? config.sourceSha256 : nullptr;
        const auto pinSt = PinnedSourceFile::pinAndHash(sourcePath, pinOpts, impl->pinned);
        switch (pinSt) {
            case SourcePinStatus::Ok:
                break;
            case SourcePinStatus::SourceChanged:
                fail(RenderStatus::InvalidArgument, kHdrReasonSourceChanged, "HDR metadata source changed");
            case SourcePinStatus::Cancelled:
                throw ProcessingCancelled();
            case SourcePinStatus::InvalidPath:
            case SourcePinStatus::IoError:
            case SourcePinStatus::TooLarge:
                fail(RenderStatus::IoError, kHdrReasonInputIo, "Cannot inspect HDR metadata source");
        }
        std::copy(impl->pinned.sha256().begin(), impl->pinned.sha256().end(), impl->digest);
        std::copy(impl->pinned.sha256().begin(), impl->pinned.sha256().end(), pin.digest);
        info = probeProRAW(config.metadataSourcePath);
        if (!impl->pinned.verifyUnchanged())
            fail(RenderStatus::InvalidArgument, kHdrReasonSourceChanged, "HDR metadata source changed");
    } else {
        const auto source = readFile(config.metadataSourcePath, config.sourceSha256);
        info = source.info;
        if (info.orientation >= 5 && info.orientation <= 8) std::swap(info.width, info.height);
        impl->pinned = source.pinned;
        impl->rawExif = source.jpeg ? jpegExif(source.bytes.data(), source.bytes.size())
                                    : heifExif(source.bytes.data(), source.bytes.size());
        std::copy_n(source.info.sourceSha256, 32, impl->digest);
        std::copy_n(source.info.sourceSha256, 32, pin.digest);
    }
    if (info.width != width || info.height != height)
        fail(RenderStatus::InvalidArgument, kHdrReasonPreviewSource, "Stream must read the complete source canvas");
    pin.impl = impl.release();
}
namespace {
std::vector<uint8_t> buildStreamExif(const char* metadataSourcePath, uint32_t width, uint32_t height,
    const StreamSourcePinImpl* impl, const uint8_t* expected) {
    if (impl) {
        if (!impl->pinned.verifyUnchanged())
            fail(RenderStatus::InvalidArgument, kHdrReasonSourceChanged, "HDR metadata source changed");
        if (impl->isTiff) {
            (void)probeProRAW(metadataSourcePath);
            return sanitizedDNGExif(impl->pinned.path(), width, height);
        }
        return sanitizedExif(impl->rawExif.data(), impl->rawExif.size(), width, height);
    }
    return captureMetadata(metadataSourcePath, expected, width, height);
}
} // namespace

JPEGTransformBase makeStreamBaseTransform(const HDRExportConfig& config, uint32_t width, uint32_t height,
    const char*, const StreamSourcePin& pin) {
    if (!config.metadataSourcePath) return {};
    std::string metadataPath(config.metadataSourcePath);
    const uint8_t* sourceSha = !hasDigest(config.sourceSha256) && hasDigest(pin.digest) ? pin.digest : config.sourceSha256;
    std::array<uint8_t, 32> expected{};
    std::copy_n(sourceSha, 32, expected.begin());
    const auto* impl = static_cast<const StreamSourcePinImpl*>(pin.impl);
    std::shared_ptr<const StreamSourcePinImpl> pinned;
    if (impl) {
        pinned = std::make_shared<StreamSourcePinImpl>(*impl);
    }
    return [metadataPath = std::move(metadataPath), width, height, pinned = std::move(pinned),
            expected](const std::vector<uint8_t>& base) {
        checkProcessingCancellation();
        const auto exif = buildStreamExif(metadataPath.c_str(), width, height, pinned.get(), expected.data());
        return withJPEGExif(base.data(), base.size(), exif.data(), exif.size());
    };
}

void publishStreamJPEG(std::vector<uint8_t> data, uint32_t width, uint32_t height,
    const HDRExportConfig& config, bool hdr, const char* path, const StreamSourcePin& pin, bool baseMetadataApplied) {
    checkProcessingCancellation();
    if (config.metadataSourcePath && *config.metadataSourcePath) {
        differentFile(config.metadataSourcePath, path);
    }
    const auto* impl = static_cast<const StreamSourcePinImpl*>(pin.impl);
    const uint8_t* expected = !hasDigest(config.sourceSha256) && hasDigest(pin.digest) ? pin.digest : config.sourceSha256;
    if (!(hdr && baseMetadataApplied)) {
        admitStreamingMemory(uint64_t(data.size()) * 8 + (64ull << 20));
        const auto exif = buildStreamExif(config.metadataSourcePath, width, height, impl, expected);
        if (hdr) {
            const auto base = jpegBase(data.data(),data.size());
            const auto tagged = withJPEGExif(base.data(),base.size(),exif.data(),exif.size());
            data = replaceJPEGBase(data.data(),data.size(),tagged.data(),tagged.size());
        } else {
            data = srgbICC(data);
            data = withJPEGExif(data.data(),data.size(),exif.data(),exif.size());
        }
    }
    if (hdr) (void)probeJPEG(data.data(),data.size());
    publishAtomicBytes(path, data, [&]() {
        if (impl) {
            if (!impl->pinned.verifyUnchanged())
                fail(RenderStatus::InvalidArgument, kHdrReasonSourceChanged, "HDR metadata source changed");
        } else if (config.metadataSourcePath && *config.metadataSourcePath) {
            verifyDigest(config.metadataSourcePath, expected);
        }
        if (config.metadataSourcePath && *config.metadataSourcePath) {
            differentFile(config.metadataSourcePath, path);
        }
        checkProcessingCancellation();
        return true;
    });
}
HDRSourceInfo probeFile(const char* path) { return readFile(path).info; }
DecodedImage decodeFile(const char* path, const HDRDecodeOptions& options) {
    auto file=readFile(path); const uint32_t edge=options.intent==kHdrIntentPreview ? options.longEdge : 0;
    const uint32_t nativeWidth=file.info.orientation>=5 ? file.info.height : file.info.width;
    const uint32_t nativeHeight=file.info.orientation>=5 ? file.info.width : file.info.height;
    const double scale=edge && std::max(nativeWidth,nativeHeight)>edge ? double(edge)/std::max(nativeWidth,nativeHeight) : 1;
    const uint32_t width=std::max(1u,uint32_t(std::lround(nativeWidth*scale))),height=std::max(1u,uint32_t(std::lround(nativeHeight*scale)));
    admitMemory(uint64_t(width)*height*48);
    DecodedImage result;
    if (file.jpeg) {
        result.pixels.hdr=file.info.protocol==kHdrProtocolApple ?
            decodeAppleJPEG(file.bytes.data(),file.bytes.size(),file.info.contentHeadroom,edge,file.apple,file.info.colorDescription) :
            edge ? decodeJPEGPreview(file.bytes.data(),file.bytes.size(),edge) : decodeJPEG(file.bytes.data(),file.bytes.size());
        result.pixels.sdr=decodeSDRJPEG(file.bytes.data(),file.bytes.size(),edge,file.info.colorDescription);
        orient(result.pixels.hdr,file.info.orientation); orient(result.pixels.sdr,file.info.orientation);
    } else result=decodeHEIF(file.bytes.data(),file.bytes.size(),edge);
    result.info=file.info;
    if (result.pixels.hdr.width!=int(width) || result.pixels.hdr.height!=int(height) ||
        result.pixels.sdr.width!=int(width) || result.pixels.sdr.height!=int(height))
        fail(RenderStatus::ProcessingError, kHdrReasonInvalidBuffer, "HDR/SDR decoded canvases disagree");
    result.pixels.nativeWidth=nativeWidth; result.pixels.nativeHeight=nativeHeight;
    result.pixels.sourceHeadroom=file.info.contentHeadroom;
    result.pixels.sourceQuality=result.pixels.renderQuality=static_cast<HDRQuality>(options.intent);
    result.pixels.isProxy=options.intent==kHdrIntentPreview;
    result.pixels.decodeRevision=nextRevision.fetch_add(1);
    return result;
}
DecodedImage decodeFileROI(const char* path, const RoiSubRect& rect) {
    if (rect.empty() || rect.x0 < 0 || rect.y0 < 0) {
        fail(RenderStatus::InvalidArgument, kHdrFieldRequest, "Invalid HDR file ROI rect");
    }
    auto full = decodeFile(path, HDRDecodeOptions{kHdrIntentFinal, 0});
    if (rect.x1 > full.pixels.hdr.width || rect.y1 > full.pixels.hdr.height) {
        fail(RenderStatus::InvalidArgument, kHdrFieldRequest, "HDR file ROI exceeds image bounds");
    }
    const int rw = rect.width();
    const int rh = rect.height();
    ImageData subHdr(rw, rh);
    ImageData subSdr(rw, rh);
    for (int y = 0; y < rh; ++y) {
        std::copy_n(full.pixels.hdr.pixels.data() + size_t(rect.y0 + y) * full.pixels.hdr.width + rect.x0,
            rw, subHdr.pixels.data() + size_t(y) * rw);
        std::copy_n(full.pixels.sdr.pixels.data() + size_t(rect.y0 + y) * full.pixels.sdr.width + rect.x0,
            rw, subSdr.pixels.data() + size_t(y) * rw);
    }
    full.pixels.hdr = std::move(subHdr);
    full.pixels.sdr = std::move(subSdr);
    return full;
}
#if defined(__APPLE__)
// Keep the portable adapter's symbol closure complete when the Apple-compiled
// C ABI object also references tiled/Apple-ProRAW export. Never pull the Apple adapter back in.
HDRSourceInfo probeAppleProRAW(const char*) {
    fail(RenderStatus::Unsupported, kHdrReasonUnsupportedSystem,
        "Apple ProRAW probing is unavailable in the portable adapter");
}
HDRSourceInfo probeFileOrAppleProRAW(const char* path) {
    return probeFile(path);
}
HDRRowSource openAppleProRAWRows(const char*, const uint8_t[32], StreamSourcePin&, uint64_t&) {
    fail(RenderStatus::Unsupported, kHdrReasonUnsupportedSystem,
        "Apple ProRAW streaming is unavailable in the portable adapter");
}
HDRRowSource openRasterRows(const char*, const uint8_t[32], StreamSourcePin&, uint64_t&) {
    fail(RenderStatus::Unsupported, kHdrReasonUnsupportedSystem,
        "Tiled HDR raster decoding is unavailable on this platform");
}
void freezeStreamSourceFile(const char*, StreamSourcePin&) {
    fail(RenderStatus::Unsupported, kHdrReasonUnsupportedSystem,
        "Tiled HDR source snapshots are unavailable on this platform");
}
void verifyStreamSource(const StreamSourcePin&) {
    fail(RenderStatus::Unsupported, kHdrReasonUnsupportedSystem,
        "Tiled HDR source snapshots are unavailable on this platform");
}
void publishTiledHEIF(const HDRStreamFiles&, const HDRExportConfig&, const char*, const StreamSourcePin&) {
    throw Error(RenderStatus::Unsupported, kHdrReasonUnsupportedSystem,
        kHdrFieldExport, "Tiled HDR HEIF encoding is unavailable on this platform");
}
#endif

bool heifExportAvailable() { return false; }
void exportHEIF(const HDRImagePair&, const HDRExportConfig&, const char*) {
    throw Error(RenderStatus::Unsupported, kHdrReasonUnsupportedSystem,
        kHdrFieldExport, "HDR HEIF encoding is unavailable on this platform");
}

void exportJPEG(const HDRImagePair& image, const HDRExportConfig& config, const char* path) {
    if (config.metadataPolicy!=kHdrMetadataIsoXmp) throw std::invalid_argument("HDR JPEG requires ISO and XMP metadata");
    const auto exif=captureMetadata(config.metadataSourcePath, config.sourceSha256, image.hdr.width, image.hdr.height);
    reportHdrProgress(100, 1000);
    std::vector<uint8_t> bytes;
    {
        HdrProgressSubrangeScope sub(100, 950);
        bytes = encodeJPEG(image, config.jpegQuality ? config.jpegQuality : 95, config.baseColor,
            [&](const std::vector<uint8_t>& base) {
                return withJPEGExif(base.data(), base.size(), exif.data(), exif.size());
            });
    }
    publishAtomicBytes(path, bytes, []() {
        checkProcessingCancellation();
        return true;
    });
    reportHdrProgress(1000, 1000);
}
void exportSDR(const HDRImagePair& image, const HDRSdrExportConfig& config, const char* path) {
    if (config.quality>100) throw std::invalid_argument("Invalid SDR quality");
    const auto exif=captureMetadata(config.metadataSourcePath, config.sourceSha256, image.sdr.width, image.sdr.height);
    reportHdrProgress(100, 1000);
    if (config.outputFormat==kHdrSdrOutputJpeg) {
        std::vector<uint8_t> bytes;
        {
            HdrProgressSubrangeScope sub(100, 900);
            bytes = srgbICC(encodeSDRJPEG(image.sdr,config.quality ? config.quality : 95));
        }
        bytes=withJPEGExif(bytes.data(),bytes.size(),exif.data(),exif.size());
        reportHdrProgress(950, 1000);
        publishAtomicBytes(path, bytes, []() {
            checkProcessingCancellation();
            return true;
        });
    } else if (config.outputFormat==kHdrSdrOutputPng) {
        admitMemory(uint64_t(image.sdr.width)*image.sdr.height*16);
        ImageData display=image.sdr;
        parallelPixelRanges(display.pixels.size(), [&](size_t first, size_t last) {
            for (size_t i = first; i < last; ++i) {
                auto& pixel = display.pixels[i];
                pixel.r = linearToSrgbUnit(pixel.r);
                pixel.g = linearToSrgbUnit(pixel.g);
                pixel.b = linearToSrgbUnit(pixel.b);
            }
        });
        reportHdrProgress(400, 1000);
        ImageEncoder::PngMetadata metadata;
        metadata.exif=exif;
        if (!path || ImageEncoder::savePNG(display, path, &metadata) != ErrorCode::Success)
            fail(RenderStatus::OutputIoError, kHdrReasonOutputIo, "Cannot encode SDR PNG");
        reportHdrProgress(950, 1000);
        checkProcessingCancellation();
    } else fail(RenderStatus::Unsupported, kHdrReasonUnsupportedProtocol, "Unsupported SDR export format");
    reportHdrProgress(1000, 1000);
}

StreamSourcePin::~StreamSourcePin() {
    delete static_cast<StreamSourcePinImpl*>(impl);
}
} // namespace sony2fuji::hdr
