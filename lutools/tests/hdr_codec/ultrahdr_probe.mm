#import <Foundation/Foundation.h>

#include <ultrahdr_api.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void checkStatus(uhdr_error_info_t status) {
    if (status.error_code != UHDR_CODEC_OK)
        throw std::runtime_error(status.has_detail ? status.detail : "Ultra HDR codec failed");
}

float srgb(float value) {
    return value <= 0.0031308f ? 12.92f * value : 1.055f * std::pow(value, 1 / 2.4f) - 0.055f;
}

bool contains(NSData* data, const char* marker) {
    const auto* begin = static_cast<const char*>(data.bytes);
    return std::search(begin, begin + data.length, marker, marker + std::strlen(marker)) != begin + data.length;
}

} // namespace

NSData* makeUltraHDRJPEG(bool rgb) {
    constexpr unsigned int width = 96, height = 64;
    std::vector<_Float16> hdr(width * height * 4);
    std::vector<uint8_t> sdr(width * height * 4);
    for (unsigned int y = 0; y < height; ++y) {
        for (unsigned int x = 0; x < width; ++x) {
            const float base[] = {0.18f, 0.5f, 0.8f};
            const float boost = 1.0f + x / 24;
            for (size_t c = 0; c < 3; ++c) {
                const size_t index = (y * width + x) * 4 + c;
                hdr[index] = static_cast<_Float16>(base[c] * (rgb ? std::min(4.0f, boost + c * 0.25f) : boost));
                sdr[index] = static_cast<uint8_t>(std::round(srgb(base[c]) * 255));
            }
            hdr[(y * width + x) * 4 + 3] = 1;
            sdr[(y * width + x) * 4 + 3] = 255;
        }
    }
    uhdr_raw_image_t h{}, s{};
    h.fmt = UHDR_IMG_FMT_64bppRGBAHalfFloat;
    h.cg = s.cg = UHDR_CG_BT_709;
    h.ct = UHDR_CT_LINEAR;
    s.ct = UHDR_CT_SRGB;
    h.range = s.range = UHDR_CR_FULL_RANGE;
    h.w = s.w = width;
    h.h = s.h = height;
    h.planes[0] = hdr.data();
    s.planes[0] = sdr.data();
    h.stride[0] = s.stride[0] = width;
    s.fmt = UHDR_IMG_FMT_32bppRGBA8888;
    std::unique_ptr<uhdr_codec_private_t, decltype(&uhdr_release_encoder)> encoder(uhdr_create_encoder(), uhdr_release_encoder);
    if (!encoder) throw std::bad_alloc();
    checkStatus(uhdr_enc_set_raw_image(encoder.get(), &h, UHDR_HDR_IMG));
    checkStatus(uhdr_enc_set_raw_image(encoder.get(), &s, UHDR_SDR_IMG));
    checkStatus(uhdr_enc_set_quality(encoder.get(), 95, UHDR_BASE_IMG));
    checkStatus(uhdr_enc_set_quality(encoder.get(), 95, UHDR_GAIN_MAP_IMG));
    checkStatus(uhdr_enc_set_using_multi_channel_gainmap(encoder.get(), rgb ? 1 : 0));
    checkStatus(uhdr_enc_set_gainmap_scale_factor(encoder.get(), 1));
    // libultrahdr 使用 203 nits 作为相对参考白；不能继承默认的 10000 nits 目标容量。
    checkStatus(uhdr_enc_set_target_display_peak_brightness(encoder.get(), 4.0f * 203.0f));
    checkStatus(uhdr_enc_set_preset(encoder.get(), UHDR_USAGE_BEST_QUALITY));
    checkStatus(uhdr_encode(encoder.get()));
    const auto* compressed = uhdr_get_encoded_stream(encoder.get());
    if (!compressed || !compressed->data || compressed->data_sz == 0)
        throw std::runtime_error("Ultra HDR encoder returned no bytes");
    return [NSData dataWithBytes:compressed->data length:compressed->data_sz];
}

static std::vector<float> decodeWithUltraHDR(NSData* data) {
    std::unique_ptr<uhdr_codec_private_t, decltype(&uhdr_release_decoder)> decoder(uhdr_create_decoder(), uhdr_release_decoder);
    if (!decoder) throw std::bad_alloc();
    uhdr_compressed_image_t compressed{};
    compressed.data = const_cast<void*>(data.bytes);
    compressed.data_sz = compressed.capacity = data.length;
    compressed.cg = UHDR_CG_UNSPECIFIED;
    compressed.ct = UHDR_CT_UNSPECIFIED;
    compressed.range = UHDR_CR_UNSPECIFIED;
    checkStatus(uhdr_dec_set_image(decoder.get(), &compressed));
    checkStatus(uhdr_dec_set_out_color_transfer(decoder.get(), UHDR_CT_LINEAR));
    checkStatus(uhdr_dec_set_out_img_format(decoder.get(), UHDR_IMG_FMT_64bppRGBAHalfFloat));
    checkStatus(uhdr_dec_probe(decoder.get()));
    checkStatus(uhdr_decode(decoder.get()));
    const auto* image = uhdr_get_decoded_image(decoder.get());
    if (!image || image->w != 96 || image->h != 64) throw std::runtime_error("Ultra HDR canvas mismatch");
    float peak = 0;
    std::vector<float> result;
    result.reserve(image->w * image->h * 3);
    const auto* values = static_cast<const _Float16*>(image->planes[0]);
    for (unsigned int y = 0; y < image->h; ++y) {
        for (unsigned int x = 0; x < image->w; ++x) {
            for (size_t c = 0; c < 3; ++c) {
                const float value = values[(y * image->stride[0] + x) * 4 + c];
                if (!std::isfinite(value)) throw std::runtime_error("Ultra HDR returned nonfinite values");
                peak = std::max(peak, value);
                result.push_back(value);
            }
        }
    }
    const auto* metadata = uhdr_dec_get_gainmap_metadata(decoder.get());
    if (peak <= 1.5f || !metadata) throw std::runtime_error("Ultra HDR decode lost HDR range");
    if (metadata->hdr_capacity_max > 4.01f)
        throw std::runtime_error("codec default capacity does not match the fixture's authored headroom");
    std::cout << "ultrahdr_peak=" << peak << " capacity=" << metadata->hdr_capacity_max << '\n';
    return result;
}

void checkUltraHDRJPEG(NSData* data, bool rgb) {
    const char* markers[] = {"urn:iso:std:iso:ts:21496:-1", "http://ns.adobe.com/hdr-gain-map/1.0/"};
    if (!contains(data, markers[0]) || !contains(data, markers[1]))
        throw std::runtime_error("Ultra HDR output must contain ISO and XMP metadata");
    const auto original = decodeWithUltraHDR(data);
    for (const auto* marker : markers) {
        NSMutableData* masked = [data mutableCopy];
        auto* begin = static_cast<char*>(masked.mutableBytes);
        auto* end = begin + masked.length;
        auto* position = begin;
        size_t count = 0;
        while ((position = std::search(position, end, marker, marker + std::strlen(marker))) != end) {
            // 仅改命名空间一个字节，保持 JPEG/MPF 所有偏移，用于强制另一种协议的解码路径。
            position[0] = 'x';
            position += std::strlen(marker);
            ++count;
        }
        if (!count) throw std::runtime_error("metadata masking did not select a protocol");
        const auto alternate = decodeWithUltraHDR(masked);
        if (alternate.size() != original.size()) throw std::runtime_error("protocol paths produced different canvases");
        for (size_t i = 0; i < original.size(); ++i)
            if (std::abs(original[i] - alternate[i]) > 0.02f)
                throw std::runtime_error("ISO and XMP reconstruct different HDR pixels");
    }
    std::vector<float> errors;
    for (unsigned int y = 2; y < 62; ++y) {
        for (unsigned int x = 2; x < 94; ++x) {
            if (x % 24 < 2 || x % 24 > 21) continue;
            const float base[] = {0.18f, 0.5f, 0.8f}, weights[] = {0.2126f, 0.7152f, 0.0722f};
            float reference = 0, decoded = 0;
            for (size_t c = 0; c < 3; ++c) {
                const float boost = 1.0f + x / 24;
                reference += base[c] * (rgb ? std::min(4.0f, boost + c * 0.25f) : boost) * weights[c];
                decoded += original[(y * 96 + x) * 3 + c] * weights[c];
            }
            if (decoded <= 0) throw std::runtime_error("decoded luminance is not positive");
            errors.push_back(std::abs(std::log2(decoded / reference)));
        }
    }
    std::sort(errors.begin(), errors.end());
    const float p95 = errors[static_cast<size_t>(std::ceil(errors.size() * 0.95)) - 1];
    std::cout << "hdr_luminance_p95_ev=" << p95 << '\n';
    if (p95 > 0.10f) throw std::runtime_error("codec round-trip exceeds the authored luminance tolerance");
}
