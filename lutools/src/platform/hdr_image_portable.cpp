#include "platform/hdr_image.h"
#include "platform/hdr_heif.h"
#include "platform/hdr_metadata.h"
#include "core/hdr_jpeg.h"
#include "core/sha256.h"
#include "sony2fuji/raw_processor.h"
#include <lcms2.h>
#include <zlib.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
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
File readFile(const char* name) {
    const auto path=std::filesystem::u8path(name);
    std::error_code error;
    if (!std::filesystem::is_regular_file(path,error))
        fail(SONY2FUJI_STATUS_IO_ERROR,SONY2FUJI_HDR_REASON_INPUT_IO,"HDR input is not a readable regular file");
    const uint64_t size=std::filesystem::file_size(path,error);
    if (error || !size || size>512ull*1024*1024)
        fail(SONY2FUJI_STATUS_IO_ERROR,SONY2FUJI_HDR_REASON_INPUT_IO,"HDR compressed input exceeds the file budget");
    admitMemory(size*3);
    File file; file.bytes.resize(size_t(size));
    std::ifstream input(path,std::ios::binary);
    if (!input.read(reinterpret_cast<char*>(file.bytes.data()),std::streamsize(size)))
        fail(SONY2FUJI_STATUS_IO_ERROR,SONY2FUJI_HDR_REASON_INPUT_IO,"Cannot read HDR source");
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
    const auto sha=hash::sha256Bytes(file.bytes.data(),file.bytes.size());
    auto hex=[](char c) { return c<='9' ? c-'0' : c-'a'+10; };
    for (size_t i=0;i<32;++i) file.info.source_sha256[i]=uint8_t(hex(sha[2*i])*16+hex(sha[2*i+1]));
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
std::vector<uint8_t> captureMetadata(const char* source,const uint8_t sha[32],uint32_t width,uint32_t height) {
    std::vector<uint8_t> exif;
    if (source) {
        auto file=readFile(source);
        if (std::memcmp(file.info.source_sha256,sha,32))
            fail(SONY2FUJI_STATUS_INVALID_ARGUMENT,SONY2FUJI_HDR_REASON_SOURCE_CHANGED,"HDR metadata source changed");
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
        wchar_t path[MAX_PATH]{};
        if (!GetTempFileNameW(parent.c_str(),L"rlh",0,path))
            fail(SONY2FUJI_STATUS_OUTPUT_IO_ERROR,SONY2FUJI_HDR_REASON_OUTPUT_IO,"Cannot create HDR output transaction");
        path_=path;
#else
        auto pattern=(parent/".rawlab-hdr-XXXXXX").u8string(); std::vector<char> name(pattern.begin(),pattern.end()); name.push_back(0);
        const int fd=mkstemp(name.data());
        if (fd<0) fail(SONY2FUJI_STATUS_OUTPUT_IO_ERROR,SONY2FUJI_HDR_REASON_OUTPUT_IO,"Cannot create HDR output transaction");
        close(fd); path_=name.data();
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
void pngExif(const std::filesystem::path& path,const std::vector<uint8_t>& exif) {
    std::ifstream input(path,std::ios::binary); std::vector<uint8_t> bytes{std::istreambuf_iterator<char>(input),{}}; input.close();
    if (bytes.size()<33) throw std::runtime_error("Cannot read SDR PNG output");
    std::vector<uint8_t> chunk;
    auto integer=[&](uint32_t v) { for (int i=3;i>=0;--i) chunk.push_back(uint8_t(v>>(8*i))); };
    integer(uint32_t(exif.size())); chunk.insert(chunk.end(),{'e','X','I','f'}); chunk.insert(chunk.end(),exif.begin(),exif.end());
    integer(uint32_t(crc32(0,chunk.data()+4,uInt(chunk.size()-4))));
    bytes.insert(bytes.begin()+33,chunk.begin(),chunk.end()); write(path,bytes);
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
        if (ImageEncoder::savePNG(display,output.path().u8string())!=ErrorCode::Success)
            fail(SONY2FUJI_STATUS_OUTPUT_IO_ERROR,SONY2FUJI_HDR_REASON_OUTPUT_IO,"Cannot encode SDR PNG");
        pngExif(output.path(),exif);
    } else fail(SONY2FUJI_STATUS_UNSUPPORTED,SONY2FUJI_HDR_REASON_UNSUPPORTED_PROTOCOL,"Unsupported SDR export format");
    output.publish(path);
}
} // namespace sony2fuji::hdr
