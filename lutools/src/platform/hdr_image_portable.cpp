#include "platform/hdr_image.h"
#include "platform/hdr_heif.h"
#include "platform/hdr_metadata.h"
#include "core/hdr_jpeg.h"
#include "core/output_file_mode.h"
#include "core/proraw_source.h"
#include "core/processing_cancellation.h"
#include "core/sha256.h"
#include "core/resource_file_stamp.h"
#include "sony2fuji/raw_processor.h"
#include <lcms2.h>
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#ifndef _WIN32
#include <fcntl.h>
#include <sys/stat.h>
#endif
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
std::atomic<uint64_t> sourceHashPasses{0};
bool hasDigest(const uint8_t sha[32]) {
    return std::any_of(sha, sha + 32, [](uint8_t value) { return value != 0; });
}
[[noreturn]] void fail(sony2fuji_status status,uint32_t reason,const char* message) {
    throw Error(status,reason,SONY2FUJI_HDR_FIELD_PATH,message);
}
bool has(const std::vector<uint8_t>& bytes,const char* text) {
    return std::search(bytes.begin(),bytes.end(),text,text+std::strlen(text))!=bytes.end();
}
struct File {
    std::vector<uint8_t> bytes;
    sony2fuji_hdr_source_info_v1 info{};
    bool jpeg=false;
    AppleGainMapMetadata apple;
};
File readFile(const char* name, const uint8_t* expectedSHA256 = nullptr) {
    const auto path=std::filesystem::u8path(name);
    std::error_code error;
    if (!std::filesystem::is_regular_file(path,error))
        fail(SONY2FUJI_STATUS_IO_ERROR,SONY2FUJI_HDR_REASON_INPUT_IO,"HDR input is not a readable regular file");
    const uint64_t size=std::filesystem::file_size(path,error);
    if (error || (!size && !expectedSHA256) || size>512ull*1024*1024)
        fail(SONY2FUJI_STATUS_IO_ERROR,SONY2FUJI_HDR_REASON_INPUT_IO,"HDR compressed input exceeds the file budget");
    admitMemory(size*3);
    File file; file.bytes.resize(size_t(size));
    std::ifstream input(path,std::ios::binary);
    if (!input.read(reinterpret_cast<char*>(file.bytes.data()),std::streamsize(size)))
        fail(SONY2FUJI_STATUS_IO_ERROR,SONY2FUJI_HDR_REASON_INPUT_IO,"Cannot read HDR source");
    sourceHashPasses.fetch_add(1, std::memory_order_relaxed);
    const auto sha=hash::sha256Bytes(file.bytes.data(),file.bytes.size());
    auto hex=[](char c) { return c<='9' ? c-'0' : c-'a'+10; };
    std::array<uint8_t, 32> digest{};
    for (size_t i=0;i<digest.size();++i) digest[i]=uint8_t(hex(sha[2*i])*16+hex(sha[2*i+1]));
    if (expectedSHA256 && std::memcmp(digest.data(),expectedSHA256,digest.size()))
        fail(SONY2FUJI_STATUS_INVALID_ARGUMENT,SONY2FUJI_HDR_REASON_SOURCE_CHANGED,"HDR metadata source changed");
    if (!size) fail(SONY2FUJI_STATUS_IO_ERROR,SONY2FUJI_HDR_REASON_INPUT_IO,"HDR compressed input exceeds the file budget");
    file.jpeg=size>=2 && file.bytes[0]==255 && file.bytes[1]==0xd8;
    const bool heif=size>=12 && std::memcmp(file.bytes.data()+4,"ftyp",4)==0;
    const bool xmp=has(file.bytes,"http://ns.adobe.com/hdr-gain-map/1.0/");
    const bool iso=has(file.bytes,"urn:iso:std:iso:ts:21496:-1");
    const bool apple=has(file.bytes,"urn:com:apple:photo:2020:aux:hdrgainmap") ||
        has(file.bytes,"http://ns.apple.com/HDRGainMap/1.0/");
    if (file.jpeg) {
        if (!xmp && !iso && !apple) {
            fail(SONY2FUJI_STATUS_UNSUPPORTED,SONY2FUJI_HDR_REASON_NOT_HDR,"No HDR gain map");
        }
        const auto jpeg=apple && !iso ? probeAppleJPEG(file.bytes.data(),file.bytes.size()) : probeJPEG(file.bytes.data(),file.bytes.size());
        const auto exif=jpegExif(file.bytes.data(),file.bytes.size());
        file.info.width=jpeg.width; file.info.height=jpeg.height;
        file.info.orientation=exifOrientation(exif.data(),exif.size());
        file.info.container=SONY2FUJI_HDR_CONTAINER_JPEG;
        file.info.protocol=iso ? (xmp ? SONY2FUJI_HDR_PROTOCOL_ISO_XMP : SONY2FUJI_HDR_PROTOCOL_ISO) : SONY2FUJI_HDR_PROTOCOL_XMP;
        file.info.color_description=jpegColorDescription(file.bytes.data(),file.bytes.size(),apple && !iso);
        if (!file.info.color_description)
            fail(SONY2FUJI_STATUS_UNSUPPORTED,SONY2FUJI_HDR_REASON_UNSUPPORTED_COLOR,"HDR JPEG has no supported RGB profile");
        file.info.content_headroom=jpeg.headroom;
        if(apple && !iso) {
            const auto metadata=jpegGainMapXMP(file.bytes.data(),file.bytes.size());
            file.apple=appleGainMapMetadata(metadata.data(),metadata.size());
            const float headroom=file.apple.headroom;
            file.info.protocol=SONY2FUJI_HDR_PROTOCOL_APPLE;
            file.info.content_headroom=headroom ? headroom : appleHeadroom(exif.data(),exif.size());
        }
        file.info.headroom_kind=SONY2FUJI_HDR_HEADROOM_DECLARED;
    } else if (heif) file.info=probeHEIF(file.bytes.data(),file.bytes.size());
    else {
        if (xmp || iso || apple) fail(SONY2FUJI_STATUS_UNSUPPORTED,SONY2FUJI_HDR_REASON_UNSUPPORTED_PROTOCOL,"Unsupported declared HDR container");
        fail(SONY2FUJI_STATUS_UNSUPPORTED,SONY2FUJI_HDR_REASON_NOT_HDR,"No HDR gain map");
    }
    file.info.version=1; file.info.struct_size=sizeof(file.info);
    std::copy(digest.begin(),digest.end(),file.info.source_sha256);
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
        fail(SONY2FUJI_STATUS_PROCESSING_ERROR,SONY2FUJI_HDR_REASON_INVALID_BUFFER,"HDR orientation failed");
}
bool isTIFF(const char* source) {
    std::ifstream input(std::filesystem::u8path(source), std::ios::binary);
    char magic[4]{}; input.read(magic, sizeof(magic));
    return input.gcount() == 4 && (!std::memcmp(magic,"II*\0",4) || !std::memcmp(magic,"MM\0*",4));
}
std::string fileDigest(const char* source) {
    checkProcessingCancellation();
    sourceHashPasses.fetch_add(1, std::memory_order_relaxed);
    try { return hash::sha256File(source); }
    catch (const std::runtime_error&) {
        fail(SONY2FUJI_STATUS_IO_ERROR,SONY2FUJI_HDR_REASON_INPUT_IO,"Cannot verify HDR metadata source");
    }
}
void verifyDigest(const char* source, const uint8_t sha[32]) {
    const std::string digest = fileDigest(source);
    const auto hex = [](char c) { return c <= '9' ? c - '0' : c - 'a' + 10; };
    for (size_t i = 0; i < 32; ++i) if (uint8_t(hex(digest[2*i])*16 + hex(digest[2*i+1])) != sha[i])
        fail(SONY2FUJI_STATUS_INVALID_ARGUMENT,SONY2FUJI_HDR_REASON_SOURCE_CHANGED,"HDR metadata source changed");
    checkProcessingCancellation();
}
void differentFile(const char* source, const char* output) {
    const auto inputPath = std::filesystem::u8path(source), outputPath = std::filesystem::u8path(output);
    std::error_code error;
    if (std::filesystem::equivalent(inputPath,outputPath,error) ||
        std::filesystem::weakly_canonical(inputPath) == std::filesystem::weakly_canonical(outputPath))
        fail(SONY2FUJI_STATUS_INVALID_ARGUMENT,SONY2FUJI_HDR_REASON_SAME_FILE,"HDR output must not replace the source");
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
class Temporary {
    std::filesystem::path path_;
public:
    explicit Temporary(const char* target) {
        const auto destination=std::filesystem::u8path(target);
        auto parent=destination.parent_path(); if (parent.empty()) parent=".";
#ifdef _WIN32
        // Mirror of the POSIX branch below: CREATE_NEW with a bounded retry and the
        // shared `.rawlab-hdr-*` staging name. GetTempFileNameW could return an
        // already-existing name and write()'s trunc open would rewrite a foreign
        // file; a name we did not create is never deleted here. NTFS permissions
        // follow the target directory's ACL inheritance (no destination-mode copy).
        std::wstring candidate;
        HANDLE created = INVALID_HANDLE_VALUE;
        for (int attempt=0;attempt<64 && created==INVALID_HANDLE_VALUE;++attempt) {
            const std::string suffix=stagingSuffix();
            candidate=(parent/(L".rawlab-hdr-"+std::wstring(suffix.begin(),suffix.end())+L".tmp")).wstring();
            created=CreateFileW(candidate.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
            if (created==INVALID_HANDLE_VALUE) {
                if (GetLastError()!=ERROR_FILE_EXISTS) break;
                candidate.clear(); // the name belongs to someone else; never delete it
            }
        }
        if (created==INVALID_HANDLE_VALUE)
            fail(SONY2FUJI_STATUS_OUTPUT_IO_ERROR,SONY2FUJI_HDR_REASON_OUTPUT_IO,"Cannot create HDR output transaction");
        CloseHandle(created); // write() reopens the reserved name.
        path_=candidate;
#else
        int fd=-1;
        std::filesystem::path candidate;
        for (int attempt=0;attempt<64 && fd<0;++attempt) {
            candidate=parent/(".rawlab-hdr-"+stagingSuffix()+".tmp");
            fd=::open(candidate.c_str(),O_CREAT|O_EXCL|O_WRONLY|O_CLOEXEC,0666);
            if (fd<0 && errno!=EEXIST) break;
        }
        if (fd<0) fail(SONY2FUJI_STATUS_OUTPUT_IO_ERROR,SONY2FUJI_HDR_REASON_OUTPUT_IO,"Cannot create HDR output transaction");
        preserveDestinationMode(fd,destination);
        close(fd); path_=std::move(candidate);
#endif
    }
    ~Temporary() { std::error_code error; std::filesystem::remove(path_,error); }
    const std::filesystem::path& path() const { return path_; }
    void publish(const char* target) {
#ifdef _WIN32
        const bool okay=MoveFileExW(path_.c_str(),std::filesystem::u8path(target).c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)!=0;
#else
        const bool okay=std::rename(path_.c_str(),std::filesystem::u8path(target).c_str())==0;
#endif
        if (!okay) fail(SONY2FUJI_STATUS_OUTPUT_IO_ERROR,SONY2FUJI_HDR_REASON_OUTPUT_IO,"Cannot publish HDR output");
    }
};
void write(const std::filesystem::path& path,const std::vector<uint8_t>& bytes) {
    std::ofstream output(path,std::ios::binary|std::ios::trunc);
    output.write(reinterpret_cast<const char*>(bytes.data()),std::streamsize(bytes.size())); output.flush();
    if (!output.good()) fail(SONY2FUJI_STATUS_OUTPUT_IO_ERROR,SONY2FUJI_HDR_REASON_OUTPUT_IO,"Cannot write HDR output");
}
void syncOutput(const std::filesystem::path& path) {
#ifdef _WIN32
    const auto handle = CreateFileW(path.c_str(),GENERIC_WRITE,0,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);
    const bool okay = handle != INVALID_HANDLE_VALUE && FlushFileBuffers(handle);
    if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle);
#else
    const int handle = ::open(path.c_str(),O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    const bool okay = handle >= 0 && fsync(handle) == 0;
    if (handle >= 0) close(handle);
#endif
    if (!okay) fail(SONY2FUJI_STATUS_OUTPUT_IO_ERROR,SONY2FUJI_HDR_REASON_OUTPUT_IO,"Cannot flush HDR output transaction");
}
std::vector<uint8_t> srgbICC(const std::vector<uint8_t>& jpeg) {
    auto profile=cmsCreate_sRGBProfile(); if (!profile) throw std::bad_alloc();
    cmsUInt32Number size=0; bool okay=cmsSaveProfileToMem(profile,nullptr,&size)!=0;
    std::vector<uint8_t> icc(size);
    okay=okay && cmsSaveProfileToMem(profile,icc.data(),&size)!=0; cmsCloseProfile(profile);
    if (!okay || size>65519) throw std::runtime_error("Cannot encode SDR RGB profile");
    const uint32_t length=size+16;
    std::vector<uint8_t> output{255,0xd8,255,0xe2,uint8_t(length>>8),uint8_t(length),'I','C','C','_','P','R','O','F','I','L','E',0,1,1};
    output.insert(output.end(),icc.begin(),icc.end()); output.insert(output.end(),jpeg.begin()+2,jpeg.end()); return output;
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
        fail(SONY2FUJI_STATUS_OUT_OF_MEMORY,SONY2FUJI_HDR_REASON_OUT_OF_MEMORY,"HDR task exceeds current memory budget");
}
// Mac 上的可移植适配器测试也必须完全覆盖平台符号，不能链接回 Apple 对象。
void admitStreamingMemory(uint64_t additionalBytes) { admitMemory(additionalBytes); }
void validateStreamSource(const sony2fuji_hdr_export_config_v1& config, uint32_t width, uint32_t height,
    const char* path, StreamSourcePin& pin) {
    differentFile(config.metadata_source_path,path);
    sony2fuji_hdr_source_info_v1 info;
    if (isTIFF(config.metadata_source_path)) {
        const auto file = std::filesystem::u8path(config.metadata_source_path);
        const auto before = resourceFileStamp(file);
        if (hasDigest(config.source_sha256)) verifyDigest(config.metadata_source_path,config.source_sha256);
        else {
            // 全零 config.source_sha256：调用方未预冻结，内部自采一次并贯穿发布阶段。
            const auto digest = fileDigest(config.metadata_source_path);
            const auto hex = [](char c) { return c <= '9' ? c - '0' : c - 'a' + 10; };
            for (size_t i = 0; i < 32; ++i) pin.digest[i] = uint8_t(hex(digest[2*i])*16 + hex(digest[2*i+1]));
        }
        info = probeProRAW(config.metadata_source_path);
        if (!before || !(resourceFileStamp(file) == before))
            fail(SONY2FUJI_STATUS_INVALID_ARGUMENT,SONY2FUJI_HDR_REASON_SOURCE_CHANGED,"HDR metadata source changed");
    } else {
        const auto source = readFile(config.metadata_source_path,config.source_sha256); info = source.info;
        if (info.orientation >= 5 && info.orientation <= 8) std::swap(info.width,info.height);
    }
    if (info.width != width || info.height != height)
        fail(SONY2FUJI_STATUS_INVALID_ARGUMENT,SONY2FUJI_HDR_REASON_PREVIEW_SOURCE,"Stream must read the complete source canvas");
}
void publishStreamJPEG(std::vector<uint8_t> data, uint32_t width, uint32_t height,
    const sony2fuji_hdr_export_config_v1& config, bool hdr, const char* path, const StreamSourcePin& pin) {
    checkProcessingCancellation();
    differentFile(config.metadata_source_path,path);
    admitStreamingMemory(uint64_t(data.size()) * 8 + (64ull << 20));
    const uint8_t* expected = !hasDigest(config.source_sha256) && hasDigest(pin.digest) ? pin.digest : config.source_sha256;
    const auto exif = captureMetadata(config.metadata_source_path,expected,width,height);
    if (hdr) {
        const auto base = jpegBase(data.data(),data.size());
        const auto tagged = withJPEGExif(base.data(),base.size(),exif.data(),exif.size());
        data = replaceJPEGBase(data.data(),data.size(),tagged.data(),tagged.size());
        (void)probeJPEG(data.data(),data.size());
    } else {
        data = srgbICC(data);
        data = withJPEGExif(data.data(),data.size(),exif.data(),exif.size());
    }
    Temporary output(path);
    write(output.path(),data); syncOutput(output.path());
    verifyDigest(config.metadata_source_path,expected);
    differentFile(config.metadata_source_path,path);
    checkProcessingCancellation();
    output.publish(path);
}
sony2fuji_hdr_source_info_v1 probeFile(const char* path) { return readFile(path).info; }
DecodedImage decodeFile(const char* path,const sony2fuji_hdr_decode_options_v1& options) {
    auto file=readFile(path); const uint32_t edge=options.intent==SONY2FUJI_INTENT_PREVIEW ? options.long_edge : 0;
    const uint32_t nativeWidth=file.info.orientation>=5 ? file.info.height : file.info.width;
    const uint32_t nativeHeight=file.info.orientation>=5 ? file.info.width : file.info.height;
    const double scale=edge && std::max(nativeWidth,nativeHeight)>edge ? double(edge)/std::max(nativeWidth,nativeHeight) : 1;
    const uint32_t width=std::max(1u,uint32_t(std::lround(nativeWidth*scale))),height=std::max(1u,uint32_t(std::lround(nativeHeight*scale)));
    admitMemory(uint64_t(width)*height*48);
    DecodedImage result;
    if (file.jpeg) {
        result.pixels.hdr=file.info.protocol==SONY2FUJI_HDR_PROTOCOL_APPLE ?
            decodeAppleJPEG(file.bytes.data(),file.bytes.size(),file.info.content_headroom,edge,file.apple,file.info.color_description) :
            edge ? decodeJPEGPreview(file.bytes.data(),file.bytes.size(),edge) : decodeJPEG(file.bytes.data(),file.bytes.size());
        result.pixels.sdr=decodeSDRJPEG(file.bytes.data(),file.bytes.size(),edge,file.info.color_description);
        orient(result.pixels.hdr,file.info.orientation); orient(result.pixels.sdr,file.info.orientation);
    } else result=decodeHEIF(file.bytes.data(),file.bytes.size(),edge);
    result.info=file.info;
    if (result.pixels.hdr.width!=int(width) || result.pixels.hdr.height!=int(height) ||
        result.pixels.sdr.width!=int(width) || result.pixels.sdr.height!=int(height))
        fail(SONY2FUJI_STATUS_PROCESSING_ERROR,SONY2FUJI_HDR_REASON_INVALID_BUFFER,"HDR/SDR decoded canvases disagree");
    result.pixels.nativeWidth=nativeWidth; result.pixels.nativeHeight=nativeHeight;
    result.pixels.sourceHeadroom=file.info.content_headroom;
    result.pixels.sourceQuality=result.pixels.renderQuality=static_cast<HDRQuality>(options.intent);
    result.pixels.isProxy=options.intent==SONY2FUJI_INTENT_PREVIEW;
    result.pixels.decodeRevision=nextRevision.fetch_add(1);
    return result;
}
#if defined(__APPLE__)
// Keep the portable adapter's symbol closure complete when the Apple-compiled
// C ABI object also references tiled export. Never pull the Apple adapter back in.
HDRRowSource openRasterRows(const char*, const uint8_t[32], StreamSourcePin&, uint64_t&) {
    fail(SONY2FUJI_STATUS_UNSUPPORTED, SONY2FUJI_HDR_REASON_UNSUPPORTED_SYSTEM,
        "Tiled HDR raster decoding is unavailable on this platform");
}
void freezeStreamSourceFile(const char*, StreamSourcePin&) {
    fail(SONY2FUJI_STATUS_UNSUPPORTED, SONY2FUJI_HDR_REASON_UNSUPPORTED_SYSTEM,
        "Tiled HDR source snapshots are unavailable on this platform");
}
void verifyStreamSource(const StreamSourcePin&) {
    fail(SONY2FUJI_STATUS_UNSUPPORTED, SONY2FUJI_HDR_REASON_UNSUPPORTED_SYSTEM,
        "Tiled HDR source snapshots are unavailable on this platform");
}
void publishTiledHEIF(const HDRStreamFiles&, const sony2fuji_hdr_export_config_v1&, const char*, const StreamSourcePin&) {
    throw Error(SONY2FUJI_STATUS_UNSUPPORTED, SONY2FUJI_HDR_REASON_UNSUPPORTED_SYSTEM,
        SONY2FUJI_HDR_FIELD_EXPORT, "Tiled HDR HEIF encoding is unavailable on this platform");
}
#endif

bool heifExportAvailable() { return false; }
void exportHEIF(const HDRImagePair&,const sony2fuji_hdr_export_config_v1&,const char*) {
    throw Error(SONY2FUJI_STATUS_UNSUPPORTED,SONY2FUJI_HDR_REASON_UNSUPPORTED_SYSTEM,
        SONY2FUJI_HDR_FIELD_EXPORT,"HDR HEIF encoding is unavailable on this platform");
}

void exportJPEG(const HDRImagePair& image,const sony2fuji_hdr_export_config_v1& config,const char* path) {
    if (config.metadata_policy!=SONY2FUJI_HDR_METADATA_ISO_XMP) throw std::invalid_argument("HDR JPEG requires ISO and XMP metadata");
    const auto exif=captureMetadata(config.metadata_source_path,config.source_sha256,image.hdr.width,image.hdr.height);
    auto bytes=encodeJPEG(image,config.jpeg_quality ? config.jpeg_quality : 95,config.base_color);
    const auto base=jpegBase(bytes.data(),bytes.size());
    const auto tagged=withJPEGExif(base.data(),base.size(),exif.data(),exif.size());
    bytes=replaceJPEGBase(bytes.data(),bytes.size(),tagged.data(),tagged.size());
    Temporary output(path); write(output.path(),bytes); output.publish(path);
}
void exportSDR(const HDRImagePair& image,const sony2fuji_hdr_sdr_export_config_v1& config,const char* path) {
    if (config.quality>100) throw std::invalid_argument("Invalid SDR quality");
    const auto exif=captureMetadata(config.metadata_source_path,config.source_sha256,image.sdr.width,image.sdr.height);
    Temporary output(path);
    if (config.output_format==SONY2FUJI_OUTPUT_JPEG) {
        auto bytes=srgbICC(encodeSDRJPEG(image.sdr,config.quality ? config.quality : 95));
        bytes=withJPEGExif(bytes.data(),bytes.size(),exif.data(),exif.size()); write(output.path(),bytes);
    } else if (config.output_format==SONY2FUJI_OUTPUT_PNG) {
        admitMemory(uint64_t(image.sdr.width)*image.sdr.height*16);
        ImageData display=image.sdr;
        for (auto& pixel:display.pixels) for (float* p:{&pixel.r,&pixel.g,&pixel.b}) {
            const float value=std::clamp(*p,0.0f,1.0f); *p=value<=.0031308f ? 12.92f*value : 1.055f*std::pow(value,1/2.4f)-.055f;
        }
        ImageEncoder::PngMetadata metadata;
        metadata.exif=exif;
        if (ImageEncoder::savePNG(display,output.path().u8string(),&metadata)!=ErrorCode::Success)
            fail(SONY2FUJI_STATUS_OUTPUT_IO_ERROR,SONY2FUJI_HDR_REASON_OUTPUT_IO,"Cannot encode SDR PNG");
    } else fail(SONY2FUJI_STATUS_UNSUPPORTED,SONY2FUJI_HDR_REASON_UNSUPPORTED_PROTOCOL,"Unsupported SDR export format");
    output.publish(path);
}

// 可移植路径按既有 verifyDigest 流程核对来源；快照冻结由摘要重算代替，impl 保持为空。
StreamSourcePin::~StreamSourcePin() {}
uint64_t sourceHashPassCount() { return sourceHashPasses.load(std::memory_order_relaxed); }
void resetSourceHashPassCount() { sourceHashPasses.store(0, std::memory_order_relaxed); }
void (*sourceReadTestHook)() = nullptr;
} // namespace sony2fuji::hdr
