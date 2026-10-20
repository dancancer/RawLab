#include "sony2fuji/ffi/sony2fuji_c.h"
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef NOGDI
#define NOGDI
#endif
#include <windows.h>
#include <wincodec.h>
#include <wrl/client.h>
#include <zlib.h>
#include <tiffio.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <system_error>
#include <utility>
#include <vector>

using Microsoft::WRL::ComPtr;
namespace fs = std::filesystem;

extern "C" sony2fuji_status rawlab_display_preview(
    const char* path, uint32_t edge, sony2fuji_buffer* out_buffer,
    uint32_t* oriented_source_width, uint32_t* oriented_source_height);

namespace {
int checks = 0;
void check(bool success, const char* message) {
    if (!success) throw std::runtime_error(message);
    ++checks; std::cout << "PASS " << message << '\n';
}
void ok(HRESULT result) {
    if (FAILED(result)) throw std::runtime_error("WIC fixture HRESULT " + std::to_string(result));
}
std::vector<uint8_t> read(const fs::path& path) {
    std::ifstream file(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
}
void write(const fs::path& path, const std::vector<uint8_t>& bytes) {
    std::ofstream file(path, std::ios::binary);
    file.write(reinterpret_cast<const char*>(bytes.data()), bytes.size());
    if (!file) throw std::runtime_error("Cannot write private fixture");
}
void addExifColorSpace(const fs::path& source, const fs::path& target,
                       unsigned colorSpace, unsigned orientation = 1) {
    // 独立构造 EXIF，保留原 JPEG 压缩像素和 ICC；与相机/编辑器的双重色彩标记一致。
    std::vector<uint8_t> exif = {
        'E','x','i','f',0,0,'I','I',42,0,8,0,0,0,
        2,0, 0x12,0x01,3,0,1,0,0,0,static_cast<uint8_t>(orientation),0,0,0,
        0x69,0x87,4,0,1,0,0,0,38,0,0,0, 0,0,0,0,
        1,0, 1,0xa0,3,0,1,0,0,0,static_cast<uint8_t>(colorSpace),
        static_cast<uint8_t>(colorSpace >> 8),0,0, 0,0,0,0
    };
    auto bytes = read(source);
    const auto length = exif.size() + 2;
    exif.insert(exif.begin(), {255,225,static_cast<uint8_t>(length >> 8),
        static_cast<uint8_t>(length)});
    bytes.insert(bytes.begin() + 2, exif.begin(), exif.end());
    write(target, bytes);
}

void addMpfThumbnail(const fs::path& source, const fs::path& target,
                     uint32_t thumbnailType = 0x010002, bool littleEndian = true,
                     const fs::path& thumbnailSource = {}, uint32_t secondThumbnailType = 0) {
    auto primary = read(source);
    const auto thumbnail = thumbnailSource.empty() ? primary : read(thumbnailSource);
    std::vector<uint8_t> payload(secondThumbnailType == 0 ? 86 : 102);
    std::copy_n("MPF", 3, payload.begin());
    payload[4] = payload[5] = littleEndian ? 'I' : 'M';
    const auto word = [&](size_t offset, uint16_t value) {
        payload[offset] = static_cast<uint8_t>(value >> (littleEndian ? 0 : 8));
        payload[offset + 1] = static_cast<uint8_t>(value >> (littleEndian ? 8 : 0));
    };
    const auto number = [&](size_t offset, uint32_t value) {
        for (unsigned index = 0; index < 4; ++index)
            payload[offset + index] = static_cast<uint8_t>(value >> (littleEndian ? index * 8 : (3 - index) * 8));
    };
    word(6, 42); number(8, 8); word(12, 3);
    word(14, 0xb000); word(16, 7); number(18, 4);
    std::copy_n("0100", 4, payload.begin() + 22);
    word(26, 0xb001); word(28, 4); number(30, 1); number(34, secondThumbnailType == 0 ? 2 : 3);
    word(38, 0xb002); word(40, 7); number(42, secondThumbnailType == 0 ? 32 : 48); number(46, 50);
    const auto primarySize = static_cast<uint32_t>(primary.size() + payload.size() + 4);
    number(54, 0xa0030000); number(58, primarySize); word(66, 2);
    number(70, 0x40000000 | thumbnailType); number(74, static_cast<uint32_t>(thumbnail.size()));
    number(78, primarySize + 16 - 10);
    if (secondThumbnailType != 0) {
        word(68, 3);
        number(86, 0x40000000 | secondThumbnailType); number(90, static_cast<uint32_t>(thumbnail.size()));
        number(94, primarySize + 32 + static_cast<uint32_t>(thumbnail.size()) - 10);
    }
    const auto length = static_cast<uint16_t>(payload.size() + 2);
    payload.insert(payload.begin(), {255, 226, static_cast<uint8_t>(length >> 8), static_cast<uint8_t>(length)});
    primary.insert(primary.begin() + 2, payload.begin(), payload.end());
    primary.insert(primary.end(), 16, 0);
    primary.insert(primary.end(), thumbnail.begin(), thumbnail.end());
    if (secondThumbnailType != 0) {
        primary.insert(primary.end(), 16, 0);
        primary.insert(primary.end(), thumbnail.begin(), thumbnail.end());
    }
    write(target, primary);
}
void encodeFloatTiff(const fs::path& path) {
    // A separate encoder supplies real IEEE-float data, not a silently
    // converted WIC fixture or an optional test skip.
    std::unique_ptr<TIFF, decltype(&TIFFClose)> file(TIFFOpenW(path.c_str(), "w"), TIFFClose);
    if (!file) throw std::runtime_error("Cannot create float TIFF fixture");
    const uint16_t alpha = EXTRASAMPLE_UNASSALPHA;
    const bool configured = TIFFSetField(file.get(), TIFFTAG_IMAGEWIDTH, 12) &&
        TIFFSetField(file.get(), TIFFTAG_IMAGELENGTH, 8) &&
        TIFFSetField(file.get(), TIFFTAG_SAMPLESPERPIXEL, 4) &&
        TIFFSetField(file.get(), TIFFTAG_BITSPERSAMPLE, 32) &&
        TIFFSetField(file.get(), TIFFTAG_SAMPLEFORMAT, SAMPLEFORMAT_IEEEFP) &&
        TIFFSetField(file.get(), TIFFTAG_PHOTOMETRIC, PHOTOMETRIC_RGB) &&
        TIFFSetField(file.get(), TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG) &&
        TIFFSetField(file.get(), TIFFTAG_COMPRESSION, COMPRESSION_NONE) &&
        TIFFSetField(file.get(), TIFFTAG_ROWSPERSTRIP, 8) &&
        TIFFSetField(file.get(), TIFFTAG_EXTRASAMPLES, 1, &alpha);
    if (!configured) throw std::runtime_error("Cannot configure float TIFF fixture");
    std::array<float,12*4> row{};
    for (size_t x=0;x<12;++x) { row[x*4]=.25f;row[x*4+1]=.5f;row[x*4+2]=.75f;row[x*4+3]=1; }
    for (uint32_t y=0;y<8;++y)
        if (TIFFWriteScanline(file.get(),row.data(),y,0)<0) throw std::runtime_error("Cannot write float TIFF fixture");
    if (!TIFFWriteDirectory(file.get())) throw std::runtime_error("Cannot finish float TIFF fixture");
}
void encode(IWICImagingFactory* factory, const fs::path& path, REFGUID container,
            WICPixelFormatGUID format, unsigned bits, bool transparent = false,
            unsigned frames = 1, unsigned orientation = 1, unsigned transparentAlpha = 0,
            const fs::path* profile = nullptr, unsigned pixelOffset = 0) {
    ComPtr<IWICStream> stream; ok(factory->CreateStream(&stream));
    ok(stream->InitializeFromFilename(path.c_str(), GENERIC_WRITE));
    ComPtr<IWICBitmapEncoder> encoder; ok(factory->CreateEncoder(container, nullptr, &encoder));
    ok(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache));
    for (unsigned frameIndex = 0; frameIndex < frames; ++frameIndex) {
        ComPtr<IWICBitmapFrameEncode> frame; ComPtr<IPropertyBag2> options;
        ok(encoder->CreateNewFrame(&frame, &options)); ok(frame->Initialize(options.Get()));
        ok(frame->SetSize(12, 8)); auto actual = format; ok(frame->SetPixelFormat(&actual));
        if (!IsEqualGUID(actual, format)) throw std::runtime_error("Fixture silently converted pixel format");
        if (orientation != 1) {
            ComPtr<IWICMetadataQueryWriter> metadata; ok(frame->GetMetadataQueryWriter(&metadata));
            PROPVARIANT value{}; value.vt = VT_UI2; value.uiVal = static_cast<USHORT>(orientation);
            const auto query = IsEqualGUID(container, GUID_ContainerFormatTiff)
                ? L"/ifd/{ushort=274}" : L"/app1/ifd/{ushort=274}";
            ok(metadata->SetMetadataByName(query, &value));
        }
        if (profile) {
            ComPtr<IWICColorContext> context; ok(factory->CreateColorContext(&context));
            ok(context->InitializeFromFilename(profile->c_str()));
            IWICColorContext* contexts[] = {context.Get()};
            ok(frame->SetColorContexts(1, contexts));
        }
        const auto stride = (12 * bits + 7) / 8;
        std::vector<uint8_t> pixels(stride * 8, 0);
        for (unsigned y = 0; y < 8; ++y) for (unsigned x = 0; x < 12; ++x) {
            const auto offset = y * stride + x * bits / 8;
            pixels[offset] = static_cast<uint8_t>(31 + x * 11 + pixelOffset);
            if (bits >= 24) {
                pixels[offset + 1] = static_cast<uint8_t>(29 + y * 17);
                pixels[offset + 2] = static_cast<uint8_t>(33 + x * 7 + y * 3);
            }
            if (bits == 32) pixels[offset + 3] = transparent && x == 3 && y == 5 ?
                static_cast<uint8_t>(transparentAlpha) : 255;
        }
        ok(frame->WritePixels(8, stride, static_cast<UINT>(pixels.size()), pixels.data()));
        ok(frame->Commit());
    }
    ok(encoder->Commit());
}
std::vector<uint8_t> decode(const fs::path& path, unsigned width, unsigned height) {
    sony2fuji_buffer buffer{};
    const auto status = sony2fuji_load_display_image(path.u8string().c_str(), &buffer);
    if (status != SONY2FUJI_STATUS_OK) throw std::runtime_error("Display decode status " + std::to_string(status)+" for "+path.u8string());
    check(buffer.width == width && buffer.height == height && buffer.pixel_format == SONY2FUJI_PIXEL_RGBA8 &&
        buffer.stride_bytes == width * 4 && buffer.size_bytes == width * height * 4, "Decoder returns oriented tightly packed RGBA8");
    const auto* data = static_cast<const uint8_t*>(buffer.data);
    std::vector<uint8_t> result(data, data + buffer.size_bytes);
    for (size_t index = 3; index < result.size(); index += 4)
        if (result[index] != 255) throw std::runtime_error("Decoder published nonopaque input");
    sony2fuji_release_buffer(&buffer);
    check(buffer.data == nullptr && buffer.size_bytes == 0, "Display buffer uses the existing release lifecycle");
    return result;
}
void reject(const fs::path& path, sony2fuji_status expected,
            const char* message = "Unsupported/damaged input clears a stale output buffer") {
    sony2fuji_buffer buffer{
        std::malloc(4), 4, 99, 98, 4, SONY2FUJI_PIXEL_RGBA8
    };
    if (!buffer.data) throw std::runtime_error("Cannot allocate stale display buffer fixture");
    const auto status = sony2fuji_load_display_image(path.u8string().c_str(), &buffer);
    const bool clean = status == expected && buffer.data == nullptr && buffer.width == 0 &&
        buffer.height == 0 && buffer.stride_bytes == 0 && buffer.size_bytes == 0 &&
        buffer.pixel_format == SONY2FUJI_PIXEL_RGB8;
    sony2fuji_release_buffer(&buffer);
    check(clean, message);
}
void rejectEither(const fs::path& path, sony2fuji_status first, sony2fuji_status second,
                  const char* message) {
    sony2fuji_buffer buffer{
        std::malloc(4), 4, 99, 98, 4, SONY2FUJI_PIXEL_RGBA8
    };
    if (!buffer.data) throw std::runtime_error("Cannot allocate malformed fixture buffer");
    const auto status = sony2fuji_load_display_image(path.u8string().c_str(), &buffer);
    const bool clean = (status == first || status == second) && buffer.data == nullptr &&
        buffer.size_bytes == 0 && buffer.width == 0 && buffer.height == 0 &&
        buffer.stride_bytes == 0 && buffer.pixel_format == SONY2FUJI_PIXEL_RGB8;
    sony2fuji_release_buffer(&buffer);
    check(clean, message);
}
void rejectEmptyAndNullPaths() {
    sony2fuji_buffer empty{
        std::malloc(4), 4, 99, 98, 4, SONY2FUJI_PIXEL_RGBA8
    };
    if (!empty.data) throw std::runtime_error("Cannot allocate empty-path fixture");
    const auto emptyStatus = sony2fuji_load_display_image("", &empty);
    const bool emptyClean = emptyStatus == SONY2FUJI_STATUS_INVALID_ARGUMENT &&
        empty.data == nullptr && empty.size_bytes == 0 && empty.width == 0 && empty.height == 0 &&
        empty.stride_bytes == 0 && empty.pixel_format == SONY2FUJI_PIXEL_RGB8;
    sony2fuji_release_buffer(&empty);
    check(emptyClean, "Empty display-image path is invalid and clears stale output");

    sony2fuji_buffer nullPath{
        std::malloc(4), 4, 99, 98, 4, SONY2FUJI_PIXEL_RGBA8
    };
    if (!nullPath.data) throw std::runtime_error("Cannot allocate null-path fixture");
    const auto nullPathStatus = sony2fuji_load_display_image(nullptr, &nullPath);
    const bool nullPathClean = nullPathStatus == SONY2FUJI_STATUS_INVALID_ARGUMENT &&
        nullPath.data == nullptr && nullPath.size_bytes == 0 && nullPath.width == 0 &&
        nullPath.height == 0 && nullPath.stride_bytes == 0 &&
        nullPath.pixel_format == SONY2FUJI_PIXEL_RGB8;
    sony2fuji_release_buffer(&nullPath);
    check(nullPathClean, "Null display-image path is invalid and clears stale output");
    check(sony2fuji_load_display_image(nullptr, nullptr) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "Null display-image output is an invalid argument");
}

void checkPreview(const fs::path& path, uint32_t edge, unsigned sourceWidth, unsigned sourceHeight,
                  unsigned width, unsigned height) {
    sony2fuji_buffer buffer{};
    uint32_t actualSourceWidth = 0, actualSourceHeight = 0;
    const auto status = rawlab_display_preview(path.u8string().c_str(), edge, &buffer,
        &actualSourceWidth, &actualSourceHeight);
    const bool valid = status == SONY2FUJI_STATUS_OK && actualSourceWidth == sourceWidth &&
        actualSourceHeight == sourceHeight && buffer.width == width && buffer.height == height &&
        buffer.stride_bytes == width * 4 && buffer.size_bytes == static_cast<size_t>(width) * height * 4 &&
        buffer.pixel_format == SONY2FUJI_PIXEL_RGBA8;
    if (valid) {
        const auto full = decode(path, sourceWidth, sourceHeight);
        const auto* preview = static_cast<const uint8_t*>(buffer.data);
        std::array<uint64_t, 3> fullSum{}, previewSum{};
        for (size_t pixel = 0; pixel < full.size(); pixel += 4)
            for (size_t channel = 0; channel < 3; ++channel) fullSum[channel] += full[pixel + channel];
        for (size_t pixel = 0; pixel < buffer.size_bytes; pixel += 4)
            for (size_t channel = 0; channel < 3; ++channel) previewSum[channel] += preview[pixel + channel];
        // 面积缩放应保持每个颜色通道的均值；独立于插值实现，允许量化误差。
        bool colorsMatch = true;
        for (size_t channel = 0; channel < 3; ++channel)
            colorsMatch &= std::abs(double(fullSum[channel]) / (sourceWidth * sourceHeight) -
                double(previewSum[channel]) / (width * height)) <= 1.5;
        if (!colorsMatch) {
            sony2fuji_release_buffer(&buffer);
            check(false, "Scaled preview preserves RGB channel colors from the full decode");
        }
    }
    sony2fuji_release_buffer(&buffer);
    check(valid, "Display preview scales after orientation and reports source dimensions");
    check(valid, "Scaled preview preserves RGB channel colors from the full decode");
}

void rejectPreview(const fs::path& path) {
    sony2fuji_buffer buffer{
        std::malloc(4), 4, 99, 98, 4, SONY2FUJI_PIXEL_RGBA8
    };
    if (!buffer.data) throw std::runtime_error("Cannot allocate stale preview fixture");
    uint32_t sourceWidth = 99, sourceHeight = 98;
    const auto status = rawlab_display_preview(path.u8string().c_str(), 1, &buffer,
        &sourceWidth, &sourceHeight);
    const bool clean = status == SONY2FUJI_STATUS_UNSUPPORTED && sourceWidth == 0 &&
        sourceHeight == 0 && buffer.data == nullptr && buffer.size_bytes == 0 &&
        buffer.width == 0 && buffer.height == 0 && buffer.stride_bytes == 0 &&
        buffer.pixel_format == SONY2FUJI_PIXEL_RGB8;
    sony2fuji_release_buffer(&buffer);
    check(clean, "Display preview rejects source alpha before thumbnail scaling");
}

void rejectPreviewZeroEdge(const fs::path& path) {
    sony2fuji_buffer buffer{
        std::malloc(4), 4, 99, 98, 4, SONY2FUJI_PIXEL_RGBA8
    };
    if (!buffer.data) throw std::runtime_error("Cannot allocate zero-edge preview fixture");
    uint32_t sourceWidth = 99, sourceHeight = 98;
    const auto status = rawlab_display_preview(path.u8string().c_str(), 0, &buffer,
        &sourceWidth, &sourceHeight);
    const bool clean = status == SONY2FUJI_STATUS_INVALID_ARGUMENT && sourceWidth == 0 &&
        sourceHeight == 0 && buffer.data == nullptr && buffer.size_bytes == 0 &&
        buffer.width == 0 && buffer.height == 0 && buffer.stride_bytes == 0 &&
        buffer.pixel_format == SONY2FUJI_PIXEL_RGB8;
    sony2fuji_release_buffer(&buffer);
    check(clean, "Display preview rejects a zero edge before decoding");
}

unsigned orientedWidth(unsigned orientation) {
    return orientation >= 5 ? 8 : 12;
}

unsigned orientedHeight(unsigned orientation) {
    return orientation >= 5 ? 12 : 8;
}

std::pair<unsigned, unsigned> orientedCoordinate(unsigned orientation, unsigned x, unsigned y) {
    switch (orientation) {
        case 1: return {x, y};
        case 2: return {11 - x, y};
        case 3: return {11 - x, 7 - y};
        case 4: return {x, 7 - y};
        case 5: return {y, x};
        case 6: return {7 - y, x};
        case 7: return {7 - y, 11 - x};
        case 8: return {y, 11 - x};
        default: throw std::runtime_error("Invalid orientation fixture");
    }
}

void compareOriented(const std::vector<uint8_t>& upright, const std::vector<uint8_t>& actual,
                     unsigned orientation, unsigned tolerance) {
    const auto width = orientedWidth(orientation);
    const auto height = orientedHeight(orientation);
    if (actual.size() != static_cast<size_t>(width) * height * 4)
        throw std::runtime_error("Oriented fixture has an unexpected output size");
    for (unsigned y = 0; y < 8; ++y) for (unsigned x = 0; x < 12; ++x) {
        const auto [outputX, outputY] = orientedCoordinate(orientation, x, y);
        const auto sourcePixel = (y * 12 + x) * 4;
        const auto outputPixel = (outputY * width + outputX) * 4;
        for (unsigned channel = 0; channel < 3; ++channel) {
            const auto difference = std::abs(static_cast<int>(upright[sourcePixel + channel]) -
                static_cast<int>(actual[outputPixel + channel]));
            if (difference > static_cast<int>(tolerance))
                throw std::runtime_error("EXIF orientation changed source pixels");
        }
        if (actual[outputPixel + 3] != 255)
            throw std::runtime_error("EXIF orientation output is not opaque");
    }
}
void append32(std::vector<uint8_t>& bytes, uint32_t value) {
    for (int shift : {24, 16, 8, 0}) bytes.push_back(static_cast<uint8_t>(value >> shift));
}
void writeReferenceProfile(const fs::path& path) {
    // Self-owned ICC v2 matrix/shaper data makes the default CTest ICC gate
    // independent of optional system profiles or downloaded binary fixtures.
    using Bytes=std::vector<uint8_t>;
    auto signature=[](Bytes& value,size_t offset,const char* text) {
        std::copy_n(text,4,value.begin()+offset);
    };
    auto fixed=[](double value){return static_cast<uint32_t>(static_cast<int32_t>(std::llround(value*65536)));};
    auto xyz=[&](double x,double y,double z) {
        Bytes value(8,0);signature(value,0,"XYZ ");
        for(auto component : {x,y,z})append32(value,fixed(component));return value;
    };
    Bytes description(8,0);signature(description,0,"desc");
    const std::string name="RawLab P3 primaries gamma 2.2 test";
    append32(description,static_cast<uint32_t>(name.size()+1));
    description.insert(description.end(),name.begin(),name.end());description.push_back(0);
    append32(description,0);append32(description,0);description.insert(description.end(),70,0);
    Bytes copyright(8,0);signature(copyright,0,"text");
    const std::string notice="Public domain RawLab test colorimetry";
    copyright.insert(copyright.end(),notice.begin(),notice.end());copyright.push_back(0);
    Bytes curve(8,0);signature(curve,0,"curv");append32(curve,1);
    curve.insert(curve.end(),{2,51});
    const std::array<std::pair<const char*,Bytes>,9> tags{{
        {"desc",description},{"cprt",copyright},{"wtpt",xyz(.9642,1,.8249)},
        {"rXYZ",xyz(.515102,.241182,-.001049)},
        {"gXYZ",xyz(.291965,.692236,.041882)},
        {"bXYZ",xyz(.157153,.066582,.784378)},
        {"rTRC",curve},{"gTRC",curve},{"bTRC",curve}}};
    Bytes profile(132+tags.size()*12,0);
    auto put=[&](size_t offset,uint32_t value) {
        for(int byte=0;byte<4;++byte)profile[offset+byte]=static_cast<uint8_t>(value>>(24-byte*8));
    };
    put(8,0x02100000);signature(profile,12,"mntr");signature(profile,16,"RGB ");
    signature(profile,20,"XYZ ");profile[24]=7;profile[25]=0xea;profile[27]=profile[29]=1;
    signature(profile,36,"acsp");signature(profile,40,"MSFT");signature(profile,80,"RLAB");
    put(68,fixed(.9642));put(72,fixed(1));put(76,fixed(.8249));put(128,static_cast<uint32_t>(tags.size()));
    for(size_t index=0;index<tags.size();++index) {
        while(profile.size()%4)profile.push_back(0);
        const auto entry=132+index*12;signature(profile,entry,tags[index].first);
        put(entry+4,static_cast<uint32_t>(profile.size()));put(entry+8,static_cast<uint32_t>(tags[index].second.size()));
        profile.insert(profile.end(),tags[index].second.begin(),tags[index].second.end());
    }
    while(profile.size()%4)profile.push_back(0);
    put(0,static_cast<uint32_t>(profile.size()));write(path,profile);
}
void appendChunk(std::vector<uint8_t>& bytes, const std::array<char, 4>& type,
                 const std::vector<uint8_t>& payload) {
    append32(bytes, static_cast<uint32_t>(payload.size()));
    const auto start = bytes.size();
    bytes.insert(bytes.end(), type.begin(), type.end());
    bytes.insert(bytes.end(), payload.begin(), payload.end());
    append32(bytes, static_cast<uint32_t>(crc32(0, bytes.data() + start,
        static_cast<uInt>(4 + payload.size()))));
}
void chunk(const fs::path& source, const fs::path& target, const std::array<char, 4>& type,
           const std::vector<uint8_t>& payload) {
    const auto bytes = read(source);
    if (bytes.size() < 33) throw std::runtime_error("PNG fixture has no IHDR");
    std::vector<uint8_t> result(bytes.begin(), bytes.begin() + 33);
    appendChunk(result, type, payload);
    result.insert(result.end(), bytes.begin() + 33, bytes.end()); write(target, result);
}
void writePngHeader(const fs::path& path, uint32_t width, uint32_t height) {
    std::vector<uint8_t> bytes = {137, 80, 78, 71, 13, 10, 26, 10};
    std::vector<uint8_t> header;
    append32(header, width); append32(header, height);
    header.insert(header.end(), {8, 2, 0, 0, 0});
    appendChunk(bytes, {'I','H','D','R'}, header);
    appendChunk(bytes, {'I','E','N','D'}, {});
    write(path, bytes);
}

std::vector<uint8_t> wicSrgbReference(IWICImagingFactory* factory, const fs::path& path,
                                      const fs::path& profile, unsigned expectedWidth,
                                      unsigned expectedHeight) {
    ComPtr<IWICBitmapDecoder> decoder;
    ok(factory->CreateDecoderFromFilename(path.c_str(), nullptr, GENERIC_READ,
        WICDecodeMetadataCacheOnLoad, &decoder));
    UINT frameCount = 0; ok(decoder->GetFrameCount(&frameCount));
    if (frameCount != 1) throw std::runtime_error("WIC ICC reference is not single-frame");
    ComPtr<IWICBitmapFrameDecode> frame; ok(decoder->GetFrame(0, &frame));
    ComPtr<IWICColorContext> sourceContext; ok(factory->CreateColorContext(&sourceContext));
    ok(sourceContext->InitializeFromFilename(profile.c_str()));
    ComPtr<IWICColorContext> destinationContext; ok(factory->CreateColorContext(&destinationContext));
    ok(destinationContext->InitializeFromExifColorSpace(1));
    ComPtr<IWICColorTransform> transform; ok(factory->CreateColorTransformer(&transform));
    ok(transform->Initialize(frame.Get(), sourceContext.Get(), destinationContext.Get(),
        GUID_WICPixelFormat32bppRGBA));
    UINT width = 0, height = 0; ok(transform->GetSize(&width, &height));
    if (width != expectedWidth || height != expectedHeight)
        throw std::runtime_error("WIC ICC reference has an unexpected size");
    const auto stride = static_cast<size_t>(width) * 4;
    std::vector<uint8_t> result(stride * height);
    ok(transform->CopyPixels(nullptr, static_cast<UINT>(stride),
        static_cast<UINT>(result.size()), result.data()));
    return result;
}

struct ComApartment {
    bool initialized = false;
    ComApartment() {
        ok(CoInitializeEx(nullptr, COINIT_MULTITHREADED));
        initialized = true;
    }
    ~ComApartment() {
        if (initialized) CoUninitialize();
    }
};
}

int main(int argc, char** argv) {
    try {
        ComApartment apartment;
        ComPtr<IWICImagingFactory> factory;
        ok(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)));
        const auto root = argc > 1 ? fs::u8path(argv[1]) : fs::temp_directory_path() / ("rawlab-wic-" + std::to_string(GetCurrentProcessId()));
        fs::create_directories(root);
        const auto png = root / "opaque.png", jpeg = root / "ordinary.jpg";
        encode(factory.Get(), png, GUID_ContainerFormatPng, GUID_WICPixelFormat24bppBGR, 24);
        const auto expected = decode(png, 12, 8);
        for (unsigned y = 0; y < 8; ++y) for (unsigned x = 0; x < 12; ++x) {
            const auto pixel = (y * 12 + x) * 4;
            if (expected[pixel] != 33 + x * 7 + y * 3 || expected[pixel + 1] != 29 + y * 17 || expected[pixel + 2] != 31 + x * 11)
                throw std::runtime_error("Untagged RGB was not preserved as display-sRGB exactly");
        }
        check(true, "Untagged RGB values assume sRGB without an extra transfer function");
        checkPreview(png, 6, 12, 8, 6, 4);
        chunk(png, root / "orientation-6.png", {'e','X','I','f'}, {
            'I','I',42,0,8,0,0,0,1,0,
            0x12,0x01,3,0,1,0,0,0,6,0,0,0,
            0,0,0,0
        });
        compareOriented(expected, decode(root / "orientation-6.png", 8, 12), 6, 0);
        check(true, "PNG eXIf orientation 6 is applied exactly once");
        encode(factory.Get(), jpeg, GUID_ContainerFormatJpeg, GUID_WICPixelFormat24bppBGR, 24);
        const auto upright = decode(jpeg, 12, 8);
        checkPreview(jpeg, 6, 12, 8, 6, 4);
        const auto thumbnail = root / "different-thumbnail.jpg";
        encode(factory.Get(), thumbnail, GUID_ContainerFormatJpeg, GUID_WICPixelFormat24bppBGR,
            24, false, 1, 1, 0, nullptr, 30);
        for (const auto littleEndian : {true, false}) {
            const auto mpf = root / (littleEndian ? "camera-mpf.jpg" : "camera-mpf-big-endian.jpg");
            addMpfThumbnail(jpeg, mpf, 0x010002, littleEndian, thumbnail);
            check(decode(mpf, 12, 8) == upright,
                "A JPEG primary image with an MPF large thumbnail decodes without applying the thumbnail");
            checkPreview(mpf, 6, 12, 8, 6, 4);
        }
        addMpfThumbnail(jpeg, root / "camera-mpf-vga.jpg", 0x010001);
        check(decode(root / "camera-mpf-vga.jpg", 12, 8) == upright,
            "An MPF VGA thumbnail also leaves the primary JPEG unchanged");
        for (const auto& trailing : {std::vector<uint8_t>{0}, read(jpeg)}) {
            auto unindexed = read(root / "camera-mpf.jpg");
            unindexed.insert(unindexed.end(), trailing.begin(), trailing.end());
            write(root / "mpf-unindexed-trailer.jpg", unindexed);
            reject(root / "mpf-unindexed-trailer.jpg", SONY2FUJI_STATUS_UNSUPPORTED,
                "MPF rejects bytes and JPEG images beyond its indexed ranges");
        }
        addMpfThumbnail(jpeg, root / "camera-mpf-two-thumbnails.jpg", 0x010002, true, thumbnail, 0x010001);
        check(decode(root / "camera-mpf-two-thumbnails.jpg", 12, 8) == upright,
            "An MPF primary can have one thumbnail of each supported class");
        addMpfThumbnail(jpeg, root / "mpf-duplicate-class.jpg", 0x010002, true, thumbnail, 0x010002);
        reject(root / "mpf-duplicate-class.jpg", SONY2FUJI_STATUS_UNSUPPORTED,
            "Duplicate MPF thumbnail classes remain unsupported");
        addMpfThumbnail(jpeg, root / "mpf-unknown-image.jpg", 0);
        reject(root / "mpf-unknown-image.jpg", SONY2FUJI_STATUS_UNSUPPORTED,
            "Unknown MPF auxiliary images are not silently treated as SDR thumbnails");
        addMpfThumbnail(jpeg, root / "mpf-stereo.jpg", 0x020002);
        reject(root / "mpf-stereo.jpg", SONY2FUJI_STATUS_UNSUPPORTED,
            "MPF stereo images remain unsupported");
        addMpfThumbnail(jpeg, root / "mpf-gain-map.jpg", 0x050000);
        reject(root / "mpf-gain-map.jpg", SONY2FUJI_STATUS_UNSUPPORTED,
            "MPF gain maps remain unsupported instead of losing HDR interpretation");
        auto invalidMpf = read(root / "camera-mpf.jpg");
        std::fill(invalidMpf.begin() + 84, invalidMpf.begin() + 88, 0xff);
        write(root / "mpf-out-of-bounds.jpg", invalidMpf);
        reject(root / "mpf-out-of-bounds.jpg", SONY2FUJI_STATUS_UNSUPPORTED,
            "An MPF thumbnail outside the source file is rejected");
        for (const auto& field : {std::pair<size_t, uint32_t>{56, 50}, {60, 0x20030000}, {76, 0x00010002}, {72, 1}}) {
            auto invalid = read(root / "camera-mpf.jpg");
            for (unsigned byte = 0; byte < 4; ++byte) invalid[field.first + byte] = static_cast<uint8_t>(field.second >> (byte * 8));
            write(root / "invalid-mpf-index.jpg", invalid);
            reject(root / "invalid-mpf-index.jpg", SONY2FUJI_STATUS_UNSUPPORTED,
                "MPF extra attribute IFDs or invalid dependency flags are rejected");
        }
        auto oversizedThumbnail = read(root / "camera-mpf.jpg");
        const auto thumbnailStart = read(jpeg).size() + 90 + 16;
        bool enlarged = false;
        for (size_t index = thumbnailStart; index + 8 < oversizedThumbnail.size(); ++index) {
            if (oversizedThumbnail[index] == 0xff && (oversizedThumbnail[index + 1] == 0xc0 || oversizedThumbnail[index + 1] == 0xc2)) {
                oversizedThumbnail[index + 7] = 8; oversizedThumbnail[index + 8] = 0;
                enlarged = true; break;
            }
        }
        check(enlarged, "Oversized thumbnail fixture has a real JPEG frame header");
        write(root / "mpf-oversized-thumbnail.jpg", oversizedThumbnail);
        reject(root / "mpf-oversized-thumbnail.jpg", SONY2FUJI_STATUS_UNSUPPORTED,
            "MPF thumbnail dimensions must fit their declared class");
        write(root / "cmyk-header.jpg", {255,216,255,192,0,20,8,0,8,0,12,4,
            1,17,0,2,17,0,3,17,0,4,17,0,255,217});
        reject(root / "cmyk-header.jpg",SONY2FUJI_STATUS_UNSUPPORTED,"JPEG CMYK/YCCK components are refused before codec conversion");
        for (unsigned orientation = 1; orientation <= 8; ++orientation) {
            const auto oriented = orientation == 1 ? jpeg :
                root / ("orientation-" + std::to_string(orientation) + ".jpg");
            if (orientation != 1)
                encode(factory.Get(), oriented, GUID_ContainerFormatJpeg, GUID_WICPixelFormat24bppBGR,
                    24, false, 1, orientation);
            compareOriented(upright, decode(oriented, orientedWidth(orientation), orientedHeight(orientation)),
                orientation, 0);
        }
        check(true, "JPEG EXIF orientations 1 through 8 are applied exactly once");
        checkPreview(root / "orientation-6.jpg", 4, 8, 12, 3, 4);
        checkPreview(root / "orientation-6.jpg", 100, 8, 12, 8, 12);
        rejectPreviewZeroEdge(png);

        const auto tiff = root / "ordinary.tiff";
        encode(factory.Get(), tiff, GUID_ContainerFormatTiff, GUID_WICPixelFormat24bppBGR, 24);
        check(decode(tiff, 12, 8) == expected, "Single-page TIFF preserves RGB8");
        checkPreview(tiff, 6, 12, 8, 6, 4);
        for (const auto& source : {png, jpeg, tiff}) {
            const auto original = decode(source, 12, 8);
            for (const auto* extension : {".JPG", ".png", ".tiff"}) {
                const auto renamed = root / (source.filename().string() + extension);
                fs::copy_file(source, renamed, fs::copy_options::overwrite_existing);
                check(decode(renamed, 12, 8) == original,
                    "Image content determines the decoder when a supported suffix is misleading");
                checkPreview(renamed, 6, 12, 8, 6, 4);
            }
        }
        for (unsigned orientation = 1; orientation <= 8; ++orientation) {
            const auto orientedTiff = orientation == 1 ? tiff :
                root / ("orientation-" + std::to_string(orientation) + ".tiff");
            if (orientation != 1)
                encode(factory.Get(), orientedTiff, GUID_ContainerFormatTiff,
                    GUID_WICPixelFormat24bppBGR, 24, false, 1, orientation);
            compareOriented(expected,
                decode(orientedTiff, orientedWidth(orientation), orientedHeight(orientation)),
                orientation, 0);
        }
        check(true, "TIFF orientations 1 through 8 are applied exactly once");

        for (const auto alpha : {0u, 1u, 254u, 255u}) {
            const auto alphaPath = root / ("alpha-" + std::to_string(alpha) + ".png");
            encode(factory.Get(), alphaPath, GUID_ContainerFormatPng, GUID_WICPixelFormat32bppBGRA,
                32, true, 1, 1, alpha);
            if (alpha == 255) {
                check(decode(alphaPath, 12, 8) == expected,
                    "RGBA alpha 255 is accepted as opaque");
            } else {
                reject(alphaPath, SONY2FUJI_STATUS_UNSUPPORTED);
            }
        }
        rejectPreview(root / "alpha-254.png");
        fs::copy_file(root / "alpha-254.png", root / "alpha-254.jpg", fs::copy_options::overwrite_existing);
        reject(root / "alpha-254.jpg", SONY2FUJI_STATUS_UNSUPPORTED,
            "Misleading suffixes do not bypass the actual container's transparency checks");
        encode(factory.Get(), root / "opaque-rgba.png", GUID_ContainerFormatPng, GUID_WICPixelFormat32bppBGRA, 32);
        check(decode(root / "opaque-rgba.png", 12, 8) == expected, "RGBA is accepted only when every source alpha is opaque");
        checkPreview(root / "opaque-rgba.png", 4, 12, 8, 4, 3);
        encode(factory.Get(), root / "high-bit.png", GUID_ContainerFormatPng, GUID_WICPixelFormat48bppRGB, 48);
        reject(root / "high-bit.png", SONY2FUJI_STATUS_UNSUPPORTED);
        encode(factory.Get(), root / "gray.png", GUID_ContainerFormatPng, GUID_WICPixelFormat8bppGray, 8);
        reject(root / "gray.png", SONY2FUJI_STATUS_UNSUPPORTED);
        encode(factory.Get(), root / "multi.tiff", GUID_ContainerFormatTiff, GUID_WICPixelFormat24bppBGR, 24, false, 2);
        reject(root / "multi.tiff", SONY2FUJI_STATUS_UNSUPPORTED);
        encode(factory.Get(), root / "cmyk.tiff", GUID_ContainerFormatTiff,
            GUID_WICPixelFormat32bppCMYK, 32);
        reject(root / "cmyk.tiff", SONY2FUJI_STATUS_UNSUPPORTED);
        encodeFloatTiff(root / "float.tiff");
        reject(root / "float.tiff", SONY2FUJI_STATUS_UNSUPPORTED);
        encode(factory.Get(), root / "bitmap.bmp", GUID_ContainerFormatBmp,
            GUID_WICPixelFormat24bppBGR, 24);
        reject(root / "bitmap.bmp", SONY2FUJI_STATUS_UNSUPPORTED);

        const auto unicode = root / fs::u8path("\xE4\xB8\xAD\xE6\x96\x87.png");
        encode(factory.Get(), unicode, GUID_ContainerFormatPng, GUID_WICPixelFormat24bppBGR, 24);
        check(decode(unicode, 12, 8) == expected, "UTF-8 Unicode image paths round-trip through WIC");

        // acTL is a refusal marker, not a complete APNG decode fixture.
        chunk(png, root / "animated.png", {'a','c','T','L'}, {0,0,0,2,0,0,0,0});
        reject(root / "animated.png", SONY2FUJI_STATUS_UNSUPPORTED);
        // cICP {9,16,0,1} is a valid BT.2020/PQ/full-range marker. This is a
        // conservative HDR refusal marker, not a complete HDR decode fixture.
        chunk(png, root / "sdr-cicp.png", {'c','I','C','P'}, {1,13,0,1});
        check(decode(root / "sdr-cicp.png",12,8)==expected,"Valid SDR cICP uses the RGB identity matrix");
        chunk(png, root / "hdr.png", {'c','I','C','P'}, {9,16,0,1});
        reject(root / "hdr.png", SONY2FUJI_STATUS_UNSUPPORTED);
        chunk(png, root / "malformed-cicp.png", {'c','I','C','P'}, {1,13,1});
        reject(root / "malformed-cicp.png", SONY2FUJI_STATUS_UNSUPPORTED);
        chunk(png, root / "malformed-icc.png", {'i','C','C','P'}, {'b','a','d',0,0});
        rejectEither(root / "malformed-icc.png", SONY2FUJI_STATUS_UNSUPPORTED,
            SONY2FUJI_STATUS_PROCESSING_ERROR, "Malformed ICC metadata is never accepted");
        // A bare MPF marker without its required index remains invalid.
        auto gain = read(jpeg); gain.insert(gain.begin() + 2, {255,226,0,6,'M','P','F',0});
        write(root / "gain-map.jpg", gain); reject(root / "gain-map.jpg", SONY2FUJI_STATUS_UNSUPPORTED);

        const auto oversized = root / "over-64m.png";
        writePngHeader(oversized, 8001, 8000);
        reject(oversized, SONY2FUJI_STATUS_UNSUPPORTED);

        write(root / "corrupt.png", {137,80,78,71}); reject(root / "corrupt.png", SONY2FUJI_STATUS_PROCESSING_ERROR);
        reject(root / "missing.jpg", SONY2FUJI_STATUS_IO_ERROR);
        fs::copy_file(png, root / "not-raw.dng", fs::copy_options::overwrite_existing);
        reject(root / "not-raw.dng", SONY2FUJI_STATUS_UNSUPPORTED);
        rejectEmptyAndNullPaths();

        {
            const auto generatedProfile=root/"reference-p3.icc";
            writeReferenceProfile(generatedProfile);
            const auto profile = argc > 2 ? fs::u8path(argv[2]) : generatedProfile;
            std::error_code profileError;
            if (!fs::is_regular_file(profile, profileError) || profileError)
                throw std::runtime_error("Supplied Display P3 fixture is not a regular file");
            for (const auto& fixture : std::array<std::pair<const char*, const GUID*>,3>{{
                {"display-p3.png",&GUID_ContainerFormatPng},
                {"display-p3.jpg",&GUID_ContainerFormatJpeg},
                {"display-p3.tiff",&GUID_ContainerFormatTiff}}}) {
            const auto displayP3 = root / fixture.first;
            encode(factory.Get(), displayP3, *fixture.second,
                GUID_WICPixelFormat24bppBGR, 24, false, 1, 1, 0, &profile);
            const auto reference = wicSrgbReference(factory.Get(), displayP3, profile, 12, 8);
            check(reference != (IsEqualGUID(*fixture.second,GUID_ContainerFormatJpeg) ? upright : expected),
                "Non-sRGB ICC fixture requires an observable color conversion");
            const auto actual = decode(displayP3, 12, 8);
            if (actual.size() != reference.size())
                throw std::runtime_error("Display P3 output has an unexpected size");
            for (size_t index = 0; index < actual.size(); ++index) {
                if (index % 4 == 3) {
                    if (actual[index] != 255)
                        throw std::runtime_error("Display P3 output is not opaque");
                } else if (std::abs(static_cast<int>(actual[index]) -
                        static_cast<int>(reference[index])) > 2) {
                    throw std::runtime_error("Display P3 output differs from WIC sRGB reference");
                }
            }
            check(true, "Display P3 ICC conversion matches an independent WIC sRGB reference");
            if (IsEqualGUID(*fixture.second, GUID_ContainerFormatJpeg)) {
                for (unsigned exifSpace : {1u, 65535u}) {
                    const auto tagged = root / ("icc-exif-" + std::to_string(exifSpace) + ".jpg");
                    addExifColorSpace(displayP3, tagged, exifSpace);
                    check(decode(tagged, 12, 8) == actual,
                        "JPEG embedded ICC takes precedence over coexisting EXIF color space");
                    checkPreview(tagged, 4, 12, 8, 4, 3);
                }
                const auto rotated = root / "icc-exif-oriented.jpg";
                addExifColorSpace(displayP3, rotated, 1, 6);
                compareOriented(reference, decode(rotated, 8, 12), 6, 2);
                check(true, "JPEG ICC and EXIF coexist without double color conversion or rotation");
                checkPreview(rotated, 4, 8, 12, 3, 4);
                auto invalid = read(root / "icc-exif-1.jpg");
                const std::string marker("ICC_PROFILE\0", 12);
                const auto start = std::search(invalid.begin(), invalid.end(), marker.begin(), marker.end());
                if (start == invalid.end()) throw std::runtime_error("ICC fixture has no profile marker");
                const auto header = static_cast<size_t>(start - invalid.begin()) + 14;
                invalid.at(header + 16) = 'C';
                write(root / "invalid-icc-with-srgb-exif.jpg", invalid);
                rejectEither(root / "invalid-icc-with-srgb-exif.jpg", SONY2FUJI_STATUS_UNSUPPORTED,
                    SONY2FUJI_STATUS_PROCESSING_ERROR, "EXIF sRGB cannot hide an invalid embedded ICC");
            }
            }
            addExifColorSpace(jpeg, root / "uncalibrated-no-icc.jpg", 65535);
            reject(root / "uncalibrated-no-icc.jpg", SONY2FUJI_STATUS_UNSUPPORTED);
        }

        std::cout << "PASS " << checks << " Windows display decoder checks; fixtures=" << root.u8string() << '\n';
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n'; return 1;
    }
}
