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
        sony2fuji_session_destroy(session);
        std::cout << "PASS additive AI device/diagnostic APIs preserve config v1\n";
        return 0;
    } catch (const std::exception& error) {
        if (session) sony2fuji_session_destroy(session);
        std::cerr << error.what() << '\n'; return 1;
    }
}
