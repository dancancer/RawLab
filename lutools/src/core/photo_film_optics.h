#pragma once

#include "sony2fuji/common.h"

namespace sony2fuji {

struct FilmOpticsOptions {
    float halationAmount = 0.0f;     // [0, 100]
    float halationThreshold = 75.0f; // [0, 100]
    float halationRadius = 35.0f;    // [0, 100]
    float halationHue = 0.0f;        // [-100, 100]
    float bloomAmount = 0.0f;        // [0, 100]
    float bloomThreshold = 70.0f;    // [0, 100]
    float bloomRadius = 40.0f;       // [0, 100]

    bool valid() const;
    bool active() const { return halationAmount > 0.0f || bloomAmount > 0.0f; }
    bool halationIsDefault() const {
        return halationAmount == 0.0f && halationThreshold == 75.0f &&
               halationRadius == 35.0f && halationHue == 0.0f;
    }
    bool bloomIsDefault() const {
        return bloomAmount == 0.0f && bloomThreshold == 70.0f && bloomRadius == 40.0f;
    }
    bool isDefault() const { return halationIsDefault() && bloomIsDefault(); }

    bool operator==(const FilmOpticsOptions& other) const {
        return halationAmount == other.halationAmount && halationThreshold == other.halationThreshold &&
               halationRadius == other.halationRadius && halationHue == other.halationHue &&
               bloomAmount == other.bloomAmount && bloomThreshold == other.bloomThreshold &&
               bloomRadius == other.bloomRadius;
    }
};

void applyFilmOptics(ImageData& image, const FilmOpticsOptions& options);

} // namespace sony2fuji
