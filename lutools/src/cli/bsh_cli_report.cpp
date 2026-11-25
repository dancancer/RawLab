#include "bsh_cli_report.h"

#include "nlohmann/json.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>

namespace sony2fuji {
namespace {

using Json = nlohmann::json;

constexpr std::array<const char*, SONY2FUJI_HSL_CHANNELS> kHslChannelNames = {{
    "red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"
}};

inline double roundHalfEven(double value) noexcept {
    return std::nearbyint(value);
}

inline double roundN(double value, int decimals) noexcept {
    double scale = 1.0;
    for (int i = 0; i < decimals; ++i) {
        scale *= 10.0;
    }
    const double rounded = roundHalfEven(value * scale) / scale;
    return rounded == 0.0 ? 0.0 : rounded;
}

std::string trimAsciiWhitespace(const std::string& s) {
    size_t start = 0;
    while (start < s.size() && std::isspace(static_cast<unsigned char>(s[start]))) {
        ++start;
    }
    size_t end = s.size();
    while (end > start && std::isspace(static_cast<unsigned char>(s[end - 1]))) {
        --end;
    }
    return s.substr(start, end - start);
}

} // namespace

bool parseBshSampleArg(
    const std::string& rawArg,
    BshSampleQueryItem& out,
    std::string& error
) {
    std::vector<std::string> parts;
    size_t start = 0;
    while (true) {
        const size_t pos = rawArg.find(',', start);
        if (pos == std::string::npos) {
            parts.push_back(trimAsciiWhitespace(rawArg.substr(start)));
            break;
        }
        parts.push_back(trimAsciiWhitespace(rawArg.substr(start, pos - start)));
        start = pos + 1;
    }
    if (parts.size() != 2 && parts.size() != 3) {
        error = "Invalid --sample '" + rawArg + "'. Expected 'x,y' or 'x,y,label' in [0,1].";
        return false;
    }
    auto parseDouble = [](const std::string& s, double& val) -> bool {
        if (s.empty()) return false;
        char* endPtr = nullptr;
        val = std::strtod(s.c_str(), &endPtr);
        return endPtr == s.c_str() + s.size() && std::isfinite(val);
    };
    double x = 0.0, y = 0.0;
    if (!parseDouble(parts[0], x) || !parseDouble(parts[1], y)) {
        error = "Invalid coordinates in --sample '" + rawArg + "'.";
        return false;
    }
    if (x < 0.0 || x > 1.0 || y < 0.0 || y > 1.0) {
        error = "Sample coordinates out of [0,1] in '" + rawArg + "'.";
        return false;
    }
    out.normX = static_cast<float>(x);
    out.normY = static_cast<float>(y);
    if (parts.size() == 3 && !parts[2].empty()) {
        out.label = parts[2];
    } else {
        char buf[64];
        std::snprintf(buf, sizeof(buf), "point_%.2f_%.2f", x, y);
        out.label = buf;
    }
    error.clear();
    return true;
}

const char* bshCastHintName(sony2fuji_bsh_cast_hint hint) noexcept {
    switch (hint) {
        case SONY2FUJI_BSH_CAST_INSUFFICIENT_NEUTRALS: return "insufficient_neutrals";
        case SONY2FUJI_BSH_CAST_BALANCED: return "balanced";
        case SONY2FUJI_BSH_CAST_WARM_YELLOW_AMBER: return "warm_yellow_amber";
        case SONY2FUJI_BSH_CAST_COOL_BLUE: return "cool_blue";
        case SONY2FUJI_BSH_CAST_GREEN: return "green_cast";
        case SONY2FUJI_BSH_CAST_MAGENTA: return "magenta_cast";
        default: return "insufficient_neutrals";
    }
}

const char* hslChannelName(sony2fuji_hsl_channel channel) noexcept {
    const auto idx = static_cast<size_t>(channel);
    if (idx < kHslChannelNames.size()) {
        return kHslChannelNames[idx];
    }
    return "red";
}

std::string bshDiagnosisToJsonString(
    const sony2fuji_bsh_diagnosis& diag,
    const std::vector<BshSampleEntry>& samples
) {
    const double blacksPct = roundN(diag.blacks_0_10_pct, 2);
    const double shadowsPct = roundN(diag.shadows_10_35_pct, 2);
    const double midtonesPct = roundN(diag.midtones_35_65_pct, 2);
    const double lightsPct = roundN(diag.lights_65_90_pct, 2);
    const double highlightsPct = roundN(diag.highlights_90_100_pct, 2);
    const double meanLuma = roundN(diag.mean_luma_0_1, 4);

    const double p01 = roundN(diag.luma_p01, 4);
    const double p05 = roundN(diag.luma_p05, 4);
    const double p25 = roundN(diag.luma_p25, 4);
    const double p50 = roundN(diag.luma_p50, 4);
    const double p75 = roundN(diag.luma_p75, 4);
    const double p95 = roundN(diag.luma_p95, 4);
    const double p99 = roundN(diag.luma_p99, 4);
    const double spread = roundN(diag.dynamic_spread_p95_minus_p05, 4);

    const double scPct = roundN(diag.shadow_crush_pct, 2);
    const double wbPct = roundN(diag.white_blowout_pct, 2);
    const double clipAnyPct = roundN(diag.channel_clip_high_any_pct, 2);
    const double clipRPct = roundN(diag.channel_clip_high_r_pct, 2);
    const double clipGPct = roundN(diag.channel_clip_high_g_pct, 2);
    const double clipBPct = roundN(diag.channel_clip_high_b_pct, 2);

    const double neutralCovPct = roundN(diag.neutral_midtone_coverage_pct, 2);
    const double rOverG = roundN(diag.r_over_g, 4);
    const double bOverG = roundN(diag.b_over_g, 4);
    const char* castHintStr = bshCastHintName(diag.cast_hint);

    const double meanSPct = roundN(diag.mean_s_pct, 2);
    const double p95SPct = roundN(diag.p95_s_pct, 2);
    const double lowSatPct = roundN(diag.low_sat_pct, 2);
    const double meltPct = roundN(diag.melting_saturation_pct, 2);
    const bool meltWarn = diag.melting_warning != 0;

    Json hslObj = Json::object();
    for (size_t i = 0; i < SONY2FUJI_HSL_CHANNELS; ++i) {
        const auto& ch = diag.hsl_channels[i];
        if (ch.active != 0) {
            hslObj[kHslChannelNames[i]] = {
                {"coverage_pct", roundN(ch.coverage_pct, 2)},
                {"mean_hue_deg", roundN(ch.mean_hue_deg, 1)},
                {"mean_sat_pct", roundN(ch.mean_sat_pct, 1)},
                {"mean_brightness_pct", roundN(ch.mean_brightness_pct, 1)},
            };
        }
    }

    Json samplesArr = Json::array();
    for (const auto& s : samples) {
        const double hDeg = roundN(s.result.hsb[0], 1);
        const double sPct = roundN(s.result.hsb[1], 1);
        const double bPct = roundN(s.result.hsb[2], 1);
        Json item = {
            {"label", s.label},
            {"norm_coord", {roundN(s.normX, 4), roundN(s.normY, 4)}},
            {"pixel_coord", {s.result.pixel_x, s.result.pixel_y}},
            {"rgb_8bit", {s.result.rgb_8bit[0], s.result.rgb_8bit[1], s.result.rgb_8bit[2]}},
            {"hsb", {{"h_deg", hDeg}, {"s_pct", sPct}, {"b_pct", bPct}}},
            {"hsl_channel", hslChannelName(s.result.nearest_hsl_channel)},
        };
        samplesArr.push_back(std::move(item));
    }

    auto to255 = [](double p) -> int {
        return static_cast<int>(roundHalfEven(p * 255.0));
    };

    Json doc = {
        {"dimensions", {
            {"width", diag.width},
            {"height", diag.height},
            {"bit_depth", diag.bit_depth},
            {"channels", diag.channels},
            {"sampled_pixels", diag.sampled_pixels},
        }},
        {"luma_zones", {
            {"blacks_0_10_pct", blacksPct},
            {"shadows_10_35_pct", shadowsPct},
            {"midtones_35_65_pct", midtonesPct},
            {"lights_65_90_pct", lightsPct},
            {"highlights_90_100_pct", highlightsPct},
            {"mean_luma_0_1", meanLuma},
            {"percentiles_0_1", {
                {"p01", p01}, {"p05", p05}, {"p25", p25}, {"p50", p50},
                {"p75", p75}, {"p95", p95}, {"p99", p99},
            }},
            {"percentiles_0_255", {
                {"p01", to255(p01)}, {"p05", to255(p05)}, {"p50", to255(p50)},
                {"p95", to255(p95)}, {"p99", to255(p99)},
            }},
            {"dynamic_spread_p95_minus_p05", spread},
        }},
        {"clipping", {
            {"shadow_crush_pct", scPct},
            {"white_blowout_pct", wbPct},
            {"channel_clip_high_pct", {
                {"any", clipAnyPct}, {"r", clipRPct}, {"g", clipGPct}, {"b", clipBPct},
            }},
        }},
        {"color_balance", {
            {"neutral_midtone_coverage_pct", neutralCovPct},
            {"r_over_g", rOverG},
            {"b_over_g", bOverG},
            {"cast_hint", castHintStr},
        }},
        {"saturation", {
            {"mean_s_pct", meanSPct},
            {"p95_s_pct", p95SPct},
            {"low_sat_pct", lowSatPct},
            {"melting_saturation_pct", meltPct},
            {"melting_warning", meltWarn},
        }},
        {"hsl_channels", std::move(hslObj)},
        {"samples", std::move(samplesArr)},
    };
    return doc.dump(-1, ' ', false, Json::error_handler_t::replace);
}

} // namespace sony2fuji
