#include "bsh_cli_report.h"

#include "nlohmann/json.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <iomanip>
#include <sstream>

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

std::string toLowerAscii(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return s;
}

std::string formatCompactPyFloat(double v) {
    std::ostringstream oss;
    oss << std::setprecision(15) << v;
    std::string str = oss.str();
    if (str.find('.') == std::string::npos && str.find('e') == std::string::npos &&
        str.find('E') == std::string::npos) {
        str += ".0";
    }
    return str;
}

std::string formatFixed3(double v) {
    std::ostringstream oss;
    oss << std::fixed << std::setprecision(3) << v;
    return oss.str();
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
        const std::string lowLbl = toLowerAscii(s.label);
        const bool isSkin =
            lowLbl.find("skin") != std::string::npos ||
            lowLbl.find("face") != std::string::npos ||
            lowLbl.find("cheek") != std::string::npos ||
            lowLbl.find("portrait") != std::string::npos ||
            s.label.find("\xe8\x82\xa4") != std::string::npos ||
            s.label.find("\xe8\x84\xb8") != std::string::npos;
        if (isSkin) {
            Json hints = Json::array();
            if (bPct < 70.0) {
                hints.push_back("B=" + formatCompactPyFloat(bPct) + "% < 70%: consider lifting exposure or hsl.orange.l/red.l");
            } else if (bPct > 85.0) {
                hints.push_back("B=" + formatCompactPyFloat(bPct) + "% > 85%: consider recovering highlights or pulling orange.l slightly down");
            }
            if (sPct > 35.0) {
                hints.push_back("S=" + formatCompactPyFloat(sPct) + "% > 35%: skin over-saturated/muddy; pull hsl.orange.s/red.s negative");
            } else if (sPct < 15.0) {
                hints.push_back("S=" + formatCompactPyFloat(sPct) + "% < 15%: skin pale; check vibrance or warm skin slightly");
            }
            if (hDeg < 15.0) {
                hints.push_back("H=" + formatCompactPyFloat(hDeg) + "deg < 15deg: skin too red/magenta; shift hsl.red.h positive or warm tint toward yellow");
            } else if (hDeg > 26.0) {
                hints.push_back("H=" + formatCompactPyFloat(hDeg) + "deg > 26deg: skin too yellow/greenish; shift hsl.orange.h negative toward peach");
            }
            item["portrait_skin_check"] = {
                {"target_east_asian_hsb", {{"h_deg", "15..26"}, {"s_pct", "15..35"}, {"b_pct", "70..85"}}},
                {"in_window", hints.empty()},
                {"hints", std::move(hints)},
            };
        }
        samplesArr.push_back(std::move(item));
    }

    Json alerts = Json::array();
    if (wbPct > 1.5 || clipAnyPct > 3.0) {
        alerts.push_back("Highlight clipping (" + formatCompactPyFloat(wbPct) + "% white blowout, " +
                         formatCompactPyFloat(clipAnyPct) +
                         "% single-channel clip): reduce UI highlights (negative) or exposure_ev.");
    }
    if (scPct > 3.0) {
        alerts.push_back("Shadow crush (" + formatCompactPyFloat(scPct) +
                         "% pure black): lift shadows (+), black_point (+), or soften blacks toe.");
    } else if (p05 > 0.14 && blacksPct < 1.0) {
        alerts.push_back("Weak dark anchor (p05=" + formatFixed3(p05) + ", blacks=" +
                         formatCompactPyFloat(blacksPct) +
                         "%): image may look hazy/unanchored; lower black_point or anchor dark toe unless flat look is intended.");
    }
    if (meltPct > 2.0) {
        alerts.push_back("Melting saturation risk (" + formatCompactPyFloat(meltPct) +
                         "% pixels S>85% & V>35%): reduce global saturation/look strength or pull offending HSL channel saturation.");
    }
    if (diag.cast_hint == SONY2FUJI_BSH_CAST_GREEN || diag.cast_hint == SONY2FUJI_BSH_CAST_MAGENTA) {
        alerts.push_back(std::string("Midtone neutral cast detected (") + castHintStr +
                         ": R/G=" + formatCompactPyFloat(rOverG) +
                         ", B/G=" + formatCompactPyFloat(bOverG) +
                         "): check white_balance tint or color grading.");
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
        {"auto_diagnostics", std::move(alerts)},
    };
    return doc.dump(-1, ' ', false, Json::error_handler_t::replace);
}

} // namespace sony2fuji
