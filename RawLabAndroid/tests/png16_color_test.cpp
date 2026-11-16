#include "png16_decoder.h"
#include "png16_color.h"
#include <zlib.h>
#include <algorithm>
#include <array>
#include <cassert>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <vector>

using Bytes = std::vector<uint8_t>;

static float srgbEncode(float value) {
    return static_cast<float>(value <= 0.0031308f ? value * 12.92 :
        1.055 * std::pow(static_cast<double>(value), 1.0 / 2.4) - 0.055);
}

static void putBe16(Bytes& bytes, uint16_t value) {
    bytes.push_back(static_cast<uint8_t>(value >> 8));
    bytes.push_back(static_cast<uint8_t>(value & 0xff));
}

static void putBe32(Bytes& bytes, uint32_t value) {
    for (int shift : {24, 16, 8, 0}) bytes.push_back(static_cast<uint8_t>((value >> shift) & 0xff));
}

static void putS15Fixed16(Bytes& bytes, double value) {
    putBe32(bytes, static_cast<uint32_t>(static_cast<int32_t>(std::lround(value * 65536.0))));
}

static void appendChunk(Bytes& png, const char* type, const Bytes& data) {
    putBe32(png, static_cast<uint32_t>(data.size()));
    const size_t start = png.size();
    png.insert(png.end(), type, type + 4);
    png.insert(png.end(), data.begin(), data.end());
    putBe32(png, static_cast<uint32_t>(crc32(0, png.data() + start, static_cast<uInt>(png.size() - start))));
}

static Bytes saveProfile(cmsHPROFILE profile) {
    cmsUInt32Number size = 0;
    assert(cmsSaveProfileToMem(profile, nullptr, &size) != 0 && size > 0);
    Bytes bytes(size);
    assert(cmsSaveProfileToMem(profile, bytes.data(), &size) != 0);
    bytes.resize(size);
    return bytes;
}

static Bytes makeDisplayP3MatrixProfile(double gamma) {
    const cmsCIExyY d65{0.3127, 0.3290, 1.0};
    const cmsCIExyYTRIPLE p3Primaries{{0.680, 0.320, 1.0}, {0.265, 0.690, 1.0}, {0.150, 0.060, 1.0}};
    cmsToneCurve* curve = cmsBuildGamma(nullptr, gamma);
    assert(curve != nullptr);
    cmsToneCurve* curves[3] = {curve, curve, curve};
    rawlab::detail::ScopedCmsProfile profile(cmsCreateRGBProfile(&d65, &p3Primaries, curves));
    cmsFreeToneCurve(curve);
    assert(profile != nullptr);
    return saveProfile(profile.get());
}

static Bytes makeMft2LutTag(bool forward) {
    constexpr int grid = 9, entries = 256;
    Bytes tag{'m', 'f', 't', '2', 0, 0, 0, 0, 3, 3, static_cast<uint8_t>(grid), 0};
    for (int r = 0; r < 3; ++r)
        for (int c = 0; c < 3; ++c)
            putS15Fixed16(tag, r == c ? 1.0 : 0.0);
    putBe16(tag, entries);
    putBe16(tag, entries);
    for (int ch = 0; ch < 3; ++ch)
        for (int i = 0; i < entries; ++i) {
            const double x = i / 255.0;
            const auto y = forward ? static_cast<uint16_t>(std::lround(std::pow(x, 2.2) * 65535.0))
                                   : static_cast<uint16_t>(i * 257);
            putBe16(tag, y);
        }
    for (int ri = 0; ri < grid; ++ri)
        for (int gi = 0; gi < grid; ++gi)
            for (int bi = 0; bi < grid; ++bi) {
                const double rf = ri / double(grid - 1);
                const double gf = gi / double(grid - 1);
                const double bf = bi / double(grid - 1);
                if (forward) {
                    const double X = 0.515102 * rf + 0.291965 * gf + 0.157153 * bf;
                    const double Y = 0.241182 * rf + 0.692237 * gf + 0.066582 * bf;
                    const double Z = std::max(0.0, -0.001049 * rf + 0.041882 * gf + 0.784378 * bf);
                    putBe16(tag, static_cast<uint16_t>(std::clamp(std::lround(X * 32768.0), 0L, 65535L)));
                    putBe16(tag, static_cast<uint16_t>(std::clamp(std::lround(Y * 32768.0), 0L, 65535L)));
                    putBe16(tag, static_cast<uint16_t>(std::clamp(std::lround(Z * 32768.0), 0L, 65535L)));
                } else {
                    putBe16(tag, static_cast<uint16_t>(std::lround(rf * 65535.0)));
                    putBe16(tag, static_cast<uint16_t>(std::lround(gf * 65535.0)));
                    putBe16(tag, static_cast<uint16_t>(std::lround(bf * 65535.0)));
                }
            }
    for (int ch = 0; ch < 3; ++ch)
        for (int i = 0; i < entries; ++i)
            putBe16(tag, static_cast<uint16_t>(i * 257));
    return tag;
}

// Pure A2B0+B2A0 LUT-based RGB ICC profile (no rXYZ/gXYZ/bXYZ/rTRC/gTRC/bTRC fallback tags).
static Bytes makePureA2B0LutProfile() {
    Bytes desc{'d', 'e', 's', 'c', 0, 0, 0, 0};
    const char name[] = "RawLab A2B0 P3";
    putBe32(desc, static_cast<uint32_t>(sizeof(name)));
    desc.insert(desc.end(), name, name + sizeof(name));
    desc.resize(desc.size() + 79, 0);

    Bytes cprt{'t', 'e', 'x', 't', 0, 0, 0, 0, 'R', 'a', 'w', 'L', 'a', 'b', 0};
    Bytes wtpt{'X', 'Y', 'Z', ' ', 0, 0, 0, 0};
    putS15Fixed16(wtpt, 0.9642029);
    putS15Fixed16(wtpt, 1.0);
    putS15Fixed16(wtpt, 0.8249054);

    struct TagEntry { const char* sig; Bytes data; };
    const std::vector<TagEntry> tags = {
        {"desc", desc}, {"cprt", cprt}, {"wtpt", wtpt},
        {"A2B0", makeMft2LutTag(true)}, {"B2A0", makeMft2LutTag(false)},
    };

    Bytes profile(128, 0);
    profile[8] = 2;
    profile[9] = 0x40;
    std::memcpy(profile.data() + 12, "mntr", 4);
    std::memcpy(profile.data() + 16, "RGB ", 4);
    std::memcpy(profile.data() + 20, "XYZ ", 4);
    std::memcpy(profile.data() + 36, "acsp", 4);
    std::memcpy(profile.data() + 68, wtpt.data() + 8, 12);

    putBe32(profile, static_cast<uint32_t>(tags.size()));
    const size_t tableOffset = profile.size();
    profile.resize(tableOffset + tags.size() * 12, 0);
    for (size_t i = 0; i < tags.size(); ++i) {
        while (profile.size() % 4 != 0) profile.push_back(0);
        const auto offset = static_cast<uint32_t>(profile.size());
        const auto size = static_cast<uint32_t>(tags[i].data.size());
        std::memcpy(profile.data() + tableOffset + i * 12, tags[i].sig, 4);
        for (int s = 0; s < 4; ++s) {
            profile[tableOffset + i * 12 + 4 + s] = static_cast<uint8_t>((offset >> ((3 - s) * 8)) & 0xff);
            profile[tableOffset + i * 12 + 8 + s] = static_cast<uint8_t>((size >> ((3 - s) * 8)) & 0xff);
        }
        profile.insert(profile.end(), tags[i].data.begin(), tags[i].data.end());
    }
    const auto total = static_cast<uint32_t>(profile.size());
    for (int s = 0; s < 4; ++s) profile[s] = static_cast<uint8_t>((total >> ((3 - s) * 8)) & 0xff);
    return profile;
}

template <class F>
static void expectsFailure(F operation) {
    bool rejected = false;
    try { operation(); } catch (const std::exception&) { rejected = true; }
    assert(rejected);
}

int main() {
    // 1. Exhaustive 65536-sample precision check on parametric Display P3 -> sRGB (RGBA16 & RGB16, <= 1 LSB).
    std::vector<uint16_t> pixels(65536 * 4);
    const std::array<float, 9> p3ToSrgb{1.2249401f, -0.0420569f, -0.0196376f,
        -0.2249402f, 1.0420571f, -0.0786361f, 0.0f, 0.0f, 1.0982735f};
    for (double gamma : {1.8, 2.2, 2.6}) {
        const Bytes p3Icc = makeDisplayP3MatrixProfile(gamma);
        rawlab::detail::ScopedCmsProfile refSrc(cmsOpenProfileFromMem(p3Icc.data(), static_cast<cmsUInt32Number>(p3Icc.size())));
        rawlab::detail::ScopedCmsProfile refDst(cmsCreate_sRGBProfile());
        rawlab::detail::ScopedCmsTransform refDbl(cmsCreateTransform(
            refSrc.get(), TYPE_RGB_DBL, refDst.get(), TYPE_RGB_DBL, INTENT_RELATIVE_COLORIMETRIC, cmsFLAGS_NOOPTIMIZE));
        assert(refDbl != nullptr);
        for (int sweep = 0; sweep < 4; ++sweep) {
            for (int i = 0; i < 65536; ++i) {
                pixels[i * 4] = static_cast<uint16_t>(i);
                pixels[i * 4 + 1] = static_cast<uint16_t>(sweep == 0 ? i : (i * 251 + sweep * 17) & 65535);
                pixels[i * 4 + 2] = static_cast<uint16_t>(sweep == 0 ? i : (i * 97 + sweep * 127) & 65535);
                pixels[i * 4 + 3] = 65535;
            }
            const auto original = pixels;
            rawlab::convertPng16ToSrgb(pixels.data(), 65536, p3Icc.data(), p3Icc.size());
            for (int i = 0; i < 65536; ++i) {
                const double inRgb[3] = {original[i * 4] / 65535.0, original[i * 4 + 1] / 65535.0, original[i * 4 + 2] / 65535.0};
                double outRgb[3]{};
                cmsDoTransform(refDbl.get(), inRgb, outRgb, 1);
                const double r = std::pow(inRgb[0], gamma), g = std::pow(inRgb[1], gamma), b = std::pow(inRgb[2], gamma);
                for (int c = 0; c < 3; ++c) {
                    const int expectedIcc = std::lround(std::clamp(outRgb[c], 0.0, 1.0) * 65535.0);
                    assert(std::abs(int(pixels[i * 4 + c]) - expectedIcc) <= 1);
                    const float linear = static_cast<float>(p3ToSrgb[c] * r + p3ToSrgb[c + 3] * g + p3ToSrgb[c + 6] * b);
                    const int expectedIdeal = std::lround(std::clamp(srgbEncode(linear), 0.0f, 1.0f) * 65535);
                    assert(std::abs(int(pixels[i * 4 + c]) - expectedIdeal) <= 20);
                }
                assert(pixels[i * 4 + 3] == 65535);
            }
        }
        std::vector<uint16_t> rgb16 = {16384, 32768, 49152, 49152, 24576, 12288};
        std::vector<uint16_t> rgba16 = {16384, 32768, 49152, 65535, 49152, 24576, 12288, 65535};
        rawlab::convertPng16ToSrgb(rgb16.data(), 2, p3Icc.data(), p3Icc.size(), 3);
        rawlab::convertPng16ToSrgb(rgba16.data(), 2, p3Icc.data(), p3Icc.size(), 4);
        for (int p = 0; p < 2; ++p)
            for (int c = 0; c < 3; ++c)
                assert(rgb16[p * 3 + c] == rgba16[p * 4 + c]);
    }

    // 2. End-to-end 16-bit PNG with pure A2B0 LUT ICC profile (no matrix/TRC fallback) vs desktop display_image.
    const Bytes a2b0Icc = makePureA2B0LutProfile();
    {
        rawlab::detail::ScopedCmsProfile check(cmsOpenProfileFromMem(a2b0Icc.data(), static_cast<cmsUInt32Number>(a2b0Icc.size())));
        assert(check != nullptr);
        assert(cmsIsTag(check.get(), cmsSigAToB0Tag));
        assert(!cmsIsTag(check.get(), cmsSigRedColorantTag));
        assert(!cmsIsTag(check.get(), cmsSigRedTRCTag));
    }
    const std::array<uint16_t, 18> srcRgb = {
        32768, 49152, 24576,
        49152, 32768, 24576,
        24576, 32768, 49152,
        32768, 32768, 32768,
        0,     0,     0,
        65535, 65535, 65535,
    };
    // Verified reference values from macOS sony2fuji_load_display_image (ColorSync kCGColorSpaceSRGB)
    // and exact analytical ICC v4 sRGB reference (<= 1 LSB vs analytical sRGB; <= 6 LSB vs ColorSync 1024-curv sRGB).
    const std::array<uint16_t, 24> expectedLcms = {
        27504, 50054, 20652, 65535,
        52339, 32080, 22822, 65535,
        22051, 33320, 50861, 65535,
        33015, 33023, 33027, 65535,
        0,     0,     0,     65535,
        65533, 65534, 65535, 65535,
    };
    const std::array<uint16_t, 24> expectedDesktopDisplayImage = {
        27507, 50054, 20652, 65535,
        52340, 32079, 22824, 65535,
        22045, 33322, 50861, 65535,
        33020, 33021, 33028, 65535,
        0,     0,     0,     65535,
        65533, 65534, 65535, 65535,
    };

    Bytes png{137, 80, 78, 71, 13, 10, 26, 10};
    Bytes ihdr;
    putBe32(ihdr, 2);
    putBe32(ihdr, 3);
    ihdr.insert(ihdr.end(), {16, 2, 0, 0, 0});
    appendChunk(png, "IHDR", ihdr);
    Bytes iccp{'R', 'a', 'w', 'L', 'a', 'b', ' ', 'A', '2', 'B', '0', 0, 0};
    Bytes zicc(compressBound(a2b0Icc.size()));
    uLongf ziccLen = zicc.size();
    assert(compress2(zicc.data(), &ziccLen, a2b0Icc.data(), static_cast<uLong>(a2b0Icc.size()), 9) == Z_OK);
    iccp.insert(iccp.end(), zicc.begin(), zicc.begin() + ziccLen);
    appendChunk(png, "iCCP", iccp);
    Bytes rawScanlines;
    for (int y = 0; y < 3; ++y) {
        rawScanlines.push_back(0);
        for (int x = 0; x < 2; ++x)
            for (int c = 0; c < 3; ++c)
                putBe16(rawScanlines, srcRgb[(y * 2 + x) * 3 + c]);
    }
    Bytes zdat(compressBound(rawScanlines.size()));
    uLongf zdatLen = zdat.size();
    assert(compress2(zdat.data(), &zdatLen, rawScanlines.data(), static_cast<uLong>(rawScanlines.size()), 9) == Z_OK);
    zdat.resize(zdatLen);
    appendChunk(png, "IDAT", zdat);
    appendChunk(png, "IEND", {});

    const auto pngPath = std::filesystem::temp_directory_path() / "rawlab-a2b0-lut-png16-test.png";
    {
        std::ofstream out(pngPath, std::ios::binary);
        out.write(reinterpret_cast<const char*>(png.data()), static_cast<std::streamsize>(png.size()));
    }
    auto decoded = rawlab::decodePng16(pngPath.string().c_str(), 2, 3, 1);
    std::filesystem::remove(pngPath);
    rawlab::convertPng16ToSrgb(decoded.get(), 6, a2b0Icc.data(), a2b0Icc.size());
    for (size_t i = 0; i < expectedLcms.size(); ++i) {
        assert(std::abs(int(decoded.get()[i]) - int(expectedLcms[i])) <= 1);
        assert(std::abs(int(decoded.get()[i]) - int(expectedDesktopDisplayImage[i])) <= 6);
    }

    // 3. Reject malformed, non-RGB, DeviceLink, and HDR ICC profiles.
    uint16_t dummy[4] = {1000, 2000, 3000, 65535};
    expectsFailure([&] { rawlab::convertPng16ToSrgb(dummy, 1, nullptr, 0); });
    expectsFailure([&] { rawlab::convertPng16ToSrgb(dummy, 1, a2b0Icc.data(), 64); });
    Bytes corrupted = a2b0Icc;
    corrupted[36] = 'x';
    expectsFailure([&] { rawlab::convertPng16ToSrgb(dummy, 1, corrupted.data(), corrupted.size()); });

    cmsToneCurve* grayGamma = cmsBuildGamma(nullptr, 2.2);
    rawlab::detail::ScopedCmsProfile grayProfile(cmsCreateGrayProfile(cmsD50_xyY(), grayGamma));
    cmsFreeToneCurve(grayGamma);
    const Bytes grayIcc = saveProfile(grayProfile.get());
    expectsFailure([&] { rawlab::convertPng16ToSrgb(dummy, 1, grayIcc.data(), grayIcc.size()); });

    rawlab::detail::ScopedCmsProfile hdrProfile(cmsCreate_sRGBProfile());
    const uint8_t pqCicp[12] = {'c', 'i', 'c', 'p', 0, 0, 0, 0, 9, 16, 0, 1};
    assert(cmsWriteRawTag(hdrProfile.get(), static_cast<cmsTagSignature>(0x63696370u), pqCicp, sizeof(pqCicp)) != 0);
    const Bytes hdrIcc = saveProfile(hdrProfile.get());
    expectsFailure([&] { rawlab::convertPng16ToSrgb(dummy, 1, hdrIcc.data(), hdrIcc.size()); });
}
