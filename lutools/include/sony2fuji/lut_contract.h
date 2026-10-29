#pragma once
#include <string>

namespace sony2fuji {
enum class LUTColorSpace { SRGB, Rec709Gamma24, LinearSRGB, VLogVGamut, SLog3SGamut3, SLog3SGamut3Cine };
enum class LUTReference { Scene, Display };
enum class LUTRange { Full, Legal10 };
enum class LUTInterpolation { Linear, Tetrahedral };
enum class LUTBaseRendering { None, RawLabNeutral, SourceDisplay };
// Declared 表示有明确契约和出处，不代表已经与作者参考图验证一致。
enum class LUTContractState { MissingColor = 0, MissingReference, Unsupported, Invalid, Declared, Legacy,
    Compatibility = 7, ApproximateBase = 8 };
struct LUTSignal {
    LUTColorSpace space = LUTColorSpace::SRGB;
    LUTReference reference = LUTReference::Display;
    LUTRange range = LUTRange::Full;
};
struct LUTColorContract {
    LUTSignal input, output;
    LUTInterpolation interpolation = LUTInterpolation::Linear;
    LUTBaseRendering base = LUTBaseRendering::None;
    std::string evidenceSource, evidenceConditions;
};
}
