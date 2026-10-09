#pragma once
#include "sony2fuji/common.h"

namespace sony2fuji {

struct WaveletDenoiseOptions {
    bool enabled = false;
    float luma = 40, chroma = 46, coarse = 50;
    bool active() const { return enabled && (luma > 0 || chroma > 0); }
    bool operator==(const WaveletDenoiseOptions& other) const {
        return enabled == other.enabled && luma == other.luma && chroma == other.chroma && coarse == other.coarse;
    }
};

struct WaveletDenoiseDiagnostics {
    int flatTiles = 0;
    bool applied = false;
    float a[3] = {}, b[3] = {};
};

bool waveletDenoiseAvailable();
bool validWaveletDenoiseOptions(const WaveletDenoiseOptions& options);
ErrorCode applyWaveletDenoise(ImageData& image, const WaveletDenoiseOptions& options,
                            WaveletDenoiseDiagnostics* diagnostics = nullptr);

} // namespace sony2fuji
