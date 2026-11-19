#include "../app/src/main/cpp/recipe_probe_stages.h"
#include <cassert>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

#define REQUIRE(cond)                                                                               \
    do {                                                                                            \
        if (!(cond)) {                                                                              \
            std::cerr << "REQUIRE failed at " << __FILE__ << ":" << __LINE__ << ": " #cond "\n"; \
            std::abort();                                                                           \
        }                                                                                           \
    } while (false)

struct sony2fuji_session {
    std::string activeJson;
    std::vector<std::string> history;
    int failOnCall = -1;
    int callCount = 0;
};

extern "C" sony2fuji_status sony2fuji_apply_params(sony2fuji_session* s, const char* recipe_json) {
    if (!s || !recipe_json) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    const int idx = s->callCount++;
    if (s->failOnCall == idx) return SONY2FUJI_STATUS_PROCESSING_ERROR;
    s->activeJson = recipe_json;
    s->history.emplace_back(recipe_json);
    return SONY2FUJI_STATUS_OK;
}

int main() {
    {
        sony2fuji_session session;
        const std::string saved = R"({"schema_version":7,"custom":"user-edits"})";
        session.activeJson = saved;
        {
            rawlab::RecipeProbeStageScope scope(&session, saved);
            REQUIRE(session.activeJson == rawlab::kNeutralRecipeProbeParamsJson);
            REQUIRE(session.history.size() == 1);
        }
        REQUIRE(session.activeJson == saved);
        REQUIRE(session.history.size() == 2);
    }
    {
        // Empty saved params means no prior apply_params; destructor skips restore cleanly.
        sony2fuji_session session;
        {
            rawlab::RecipeProbeStageScope scope(&session, "");
            REQUIRE(session.activeJson == rawlab::kNeutralRecipeProbeParamsJson);
        }
        REQUIRE(session.history.size() == 1);
    }
    {
        // Failure entering scope throws and does not attempt restore.
        sony2fuji_session session;
        session.failOnCall = 0;
        const std::string saved = R"({"schema_version":7,"custom":"user-edits"})";
        session.activeJson = saved;
        bool threw = false;
        try {
            rawlab::RecipeProbeStageScope scope(&session, saved);
        } catch (const std::runtime_error&) {
            threw = true;
        }
        REQUIRE(threw);
        REQUIRE(session.activeJson == saved);
        REQUIRE(session.history.empty());
    }
    {
        // Failure during destructor restore is swallowed (noexcept).
        sony2fuji_session session;
        session.failOnCall = 1;
        {
            rawlab::RecipeProbeStageScope scope(&session, R"({"schema_version":7})");
            REQUIRE(session.activeJson == rawlab::kNeutralRecipeProbeParamsJson);
        }
        REQUIRE(session.history.size() == 1);
    }
    std::cout << "recipe_probe_stages_test passed\n";
    return 0;
}
