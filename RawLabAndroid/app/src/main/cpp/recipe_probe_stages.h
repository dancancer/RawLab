#pragma once
#include "sony2fuji/ffi/sony2fuji_c.h"
#include <stdexcept>
#include <initializer_list>

namespace rawlab {
struct RecipeProbeStages {
    sony2fuji_tone_controls_config tone{SONY2FUJI_TONE_CONTROLS_CONFIG_VERSION, sizeof(tone)};
    sony2fuji_atmosphere_config atmosphere{SONY2FUJI_ATMOSPHERE_CONFIG_VERSION, sizeof(atmosphere)};
    sony2fuji_color_grading_config grading{SONY2FUJI_COLOR_GRADING_CONFIG_VERSION, sizeof(grading)};
    sony2fuji_tone_curve_config curve{SONY2FUJI_TONE_CURVE_CONFIG_VERSION, sizeof(curve)};

    sony2fuji_status apply(sony2fuji_session* session) const {
        for (auto status : {sony2fuji_session_set_tone_controls(session, &tone),
                            sony2fuji_session_set_atmosphere(session, &atmosphere),
                            sony2fuji_session_set_color_grading(session, &grading),
                            sony2fuji_session_set_tone_curve(session, &curve)}) {
            if (status != SONY2FUJI_STATUS_OK) return status;
        }
        return SONY2FUJI_STATUS_OK;
    }
};

// 探测仅使用恒等阶段；无论成功或抛错，都恢复正式请求的已校验配置。
class RecipeProbeStageScope {
public:
    RecipeProbeStageScope(sony2fuji_session* session, const RecipeProbeStages& saved) : session_(session), saved_(saved) {
        if (RecipeProbeStages{}.apply(session_) != SONY2FUJI_STATUS_OK)
            throw std::runtime_error("Cannot configure neutral recipe white balance probe");
    }
    ~RecipeProbeStageScope() { saved_.apply(session_); }
private:
    sony2fuji_session* session_;
    RecipeProbeStages saved_;
};
}
