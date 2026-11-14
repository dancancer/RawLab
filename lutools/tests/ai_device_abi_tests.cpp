#include "sony2fuji/ffi/sony2fuji_c.h"
#include <nlohmann/json.hpp>
#include <cstddef>
#include <iostream>
#include <stdexcept>

static_assert(offsetof(sony2fuji_ai_denoise_config,model_directory) == 16, "AI config v1 ABI changed");
static_assert(sizeof(sony2fuji_ai_denoise_config) == 16 + 2 * sizeof(void*), "AI config v1 ABI changed");
int main() {
    sony2fuji_session* session = nullptr;
    try {
        auto require = [](bool value, const char* reason) { if (!value) throw std::runtime_error(reason); };
        const auto devices = nlohmann::json::parse(sony2fuji_ai_get_devices());
        require(devices.at("version") == 1 && devices.at("devices").is_array(), "Device inventory is not valid JSON");
        require(nlohmann::json::parse(sony2fuji_session_get_ai_diagnostics(nullptr)).is_object(), "Null diagnostics is invalid");
        require(sony2fuji_session_set_ai_device(nullptr,"") == SONY2FUJI_STATUS_INVALID_ARGUMENT, "Null session accepted");
        require(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK, "Session creation failed");
        require(sony2fuji_session_set_ai_device(session,"") == SONY2FUJI_STATUS_OK, "Auto selection broke old clients");
        require(sony2fuji_session_set_ai_device(session,std::string(257,'a').c_str()) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
                "Unbounded device ID accepted");
        sony2fuji_ai_denoise_config old{};
        old.version = 1; old.struct_size = sizeof(old); old.backend = SONY2FUJI_AI_AUTO;
        require(sony2fuji_session_set_ai_denoise(session,&old) == SONY2FUJI_STATUS_OK, "Existing v1 client rejected");
        require(nlohmann::json::parse(sony2fuji_session_get_ai_diagnostics(session)).is_object(), "Session diagnostic JSON invalid");
        if (sony2fuji_ai_available()) {
            sony2fuji_ai_denoise_config enabled = old;
            enabled.enabled = 1;
            enabled.model_directory = "nonexistent-model";
            enabled.cache_directory = "nonexistent-cache";
            require(sony2fuji_session_set_ai_denoise(session,&enabled) == SONY2FUJI_STATUS_OK, "Enabled AI config rejected");
            sony2fuji_request req{};
            req.version = SONY2FUJI_REQUEST_VERSION; req.struct_size = sizeof(req);
            req.input_type = SONY2FUJI_INPUT_RAW; req.input_path = "dummy.dng";
            req.wb_mode = SONY2FUJI_WB_CAMERA; req.temperature = 6500;
            req.brightness = req.contrast = req.saturation = 1.0f;
            struct ForeignProgressException {};
            const auto prepareStatus = sony2fuji_session_prepare_ai(session, &req,
                [](void*, int32_t, uint64_t, uint64_t) -> int32_t { throw ForeignProgressException{}; }, nullptr);
            const auto diag = nlohmann::json::parse(sony2fuji_session_get_ai_diagnostics(session));
            require(prepareStatus == SONY2FUJI_STATUS_PROCESSING_ERROR &&
                    sony2fuji_session_get_ai_error(session)[0] != '\0' &&
                    diag.at("native_status") == SONY2FUJI_STATUS_PROCESSING_ERROR,
                    "Foreign exception in sony2fuji_session_prepare_ai progress callback escaped or lost diagnostics");

            // P2-15/C10：progress==nullptr 时，仅会话取消回调也必须能进入 AI prepare 的
            // 公共取消链（Loading notify 的桥接是第一道 tile 前检查点）。
            sony2fuji_session_set_cancellation_callback(session,
                [](void*) -> int32_t { return 1; }, nullptr);
            const auto cancelledStatus = sony2fuji_session_prepare_ai(session, &req, nullptr, nullptr);
            require(cancelledStatus == SONY2FUJI_STATUS_CANCELLED,
                    "Session cancellation callback did not cancel sony2fuji_session_prepare_ai");
            // 反向契约：空闲回调不得把 AI prepare 误报成取消（与未接线时的基线行为一致）。
            sony2fuji_session_set_cancellation_callback(session,
                [](void*) -> int32_t { return 0; }, nullptr);
            const auto idleStatus = sony2fuji_session_prepare_ai(session, &req, nullptr, nullptr);
            require(idleStatus != SONY2FUJI_STATUS_CANCELLED,
                    "Null-progress prepare falsely reported cancellation with an idle cancellation callback");
            sony2fuji_session_set_cancellation_callback(session, nullptr, nullptr);
        }
        sony2fuji_session_destroy(session);
        std::cout << "PASS additive AI device/diagnostic APIs preserve config v1\n";
        return 0;
    } catch (const std::exception& error) {
        if (session) sony2fuji_session_destroy(session);
        std::cerr << error.what() << '\n'; return 1;
    }
}
