#pragma once
#include <lcms2.h>
#include <algorithm>
#include <cctype>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <memory>
#include <new>
#include <stdexcept>
#include <string>

namespace rawlab {
namespace detail {
struct CmsProfileDeleter {
    void operator()(cmsHPROFILE profile) const noexcept {
        if (profile) cmsCloseProfile(profile);
    }
};
struct CmsTransformDeleter {
    void operator()(cmsHTRANSFORM transform) const noexcept {
        if (transform) cmsDeleteTransform(transform);
    }
};
using ScopedCmsProfile = std::unique_ptr<std::remove_pointer_t<cmsHPROFILE>, CmsProfileDeleter>;
using ScopedCmsTransform = std::unique_ptr<std::remove_pointer_t<cmsHTRANSFORM>, CmsTransformDeleter>;

inline bool hasHdrDescription(cmsHPROFILE profile) {
    const cmsUInt32Number length = cmsGetProfileInfoASCII(
        profile, cmsInfoDescription, cmsNoLanguage, cmsNoCountry, nullptr, 0);
    if (length == 0 || length > 4096) return false;
    std::string text(length, '\0');
    cmsGetProfileInfoASCII(profile, cmsInfoDescription, cmsNoLanguage, cmsNoCountry, text.data(), length);
    for (char& ch : text) ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    for (const char* marker : {"pq", "hlg", "hdr", "gainmap", "extended", "bt.2020", "rec.2020", "bt2020"}) {
        if (text.find(marker) != std::string::npos) return true;
    }
    return false;
}
} // namespace detail

inline void convertPng16ToSrgb(uint16_t* pixels, size_t count, const void* iccData, size_t iccSize,
    int channels = 4) {
    constexpr size_t kMaxIccProfileBytes = 16u * 1024u * 1024u;
    if ((!pixels && count > 0) || !iccData || iccSize < 128 || iccSize > kMaxIccProfileBytes ||
        (channels != 3 && channels != 4))
        throw std::invalid_argument("Invalid PNG ICC profile");
    detail::ScopedCmsProfile source(cmsOpenProfileFromMem(iccData, static_cast<cmsUInt32Number>(iccSize)));
    if (!source) throw std::runtime_error("Invalid PNG ICC profile");
    const auto deviceClass = cmsGetDeviceClass(source.get());
    if (cmsGetColorSpace(source.get()) != cmsSigRgbData ||
        (deviceClass != cmsSigDisplayClass && deviceClass != cmsSigInputClass &&
            deviceClass != cmsSigOutputClass && deviceClass != cmsSigColorSpaceClass))
        throw std::runtime_error("Image color space is not supported");
    constexpr auto kCicpTag = static_cast<cmsTagSignature>(0x63696370u);
    if (cmsIsTag(source.get(), kCicpTag)) {
        uint8_t cicp[12]{};
        if (cmsReadRawTag(source.get(), kCicpTag, nullptr, 0) < 12 ||
            cmsReadRawTag(source.get(), kCicpTag, cicp, sizeof(cicp)) < 12)
            throw std::runtime_error("Invalid PNG ICC profile");
        if (cicp[8] == 9 || cicp[9] == 8 || cicp[9] == 16 || cicp[9] == 18 || cicp[10] != 0 || cicp[11] != 1)
            throw std::runtime_error("Image color space is not supported");
    }
    if (detail::hasHdrDescription(source.get()))
        throw std::runtime_error("Image color space is not supported");
    detail::ScopedCmsProfile destination(cmsCreate_sRGBProfile());
    if (!destination) throw std::bad_alloc();
    const cmsUInt32Number format = channels == 4 ? TYPE_RGBA_16 : TYPE_RGB_16;
    const cmsUInt32Number flags = cmsFLAGS_NOOPTIMIZE | (channels == 4 ? cmsFLAGS_COPY_ALPHA : 0);
    detail::ScopedCmsTransform transform(cmsCreateTransform(
        source.get(), format, destination.get(), format, INTENT_RELATIVE_COLORIMETRIC, flags));
    if (!transform) throw std::runtime_error("Image color space is not supported");
    while (count > 0) {
        const auto batch = static_cast<cmsUInt32Number>(
            std::min<size_t>(count, std::numeric_limits<cmsUInt32Number>::max()));
        cmsDoTransform(transform.get(), pixels, pixels, batch);
        pixels += static_cast<size_t>(batch) * static_cast<size_t>(channels);
        count -= batch;
    }
}
}
