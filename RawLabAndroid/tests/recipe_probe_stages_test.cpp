#include "../app/src/main/cpp/recipe_probe_stages.h"
#include "../app/src/main/cpp/recipe_white_balance_cache.h"
#include <cassert>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <random>
struct sony2fuji_session { rawlab::RecipeProbeStages active; };
extern "C" sony2fuji_status sony2fuji_session_set_tone_controls(sony2fuji_session* s,const sony2fuji_tone_controls_config* c) { s->active.tone=*c;return SONY2FUJI_STATUS_OK; }
extern "C" sony2fuji_status sony2fuji_session_set_atmosphere(sony2fuji_session* s,const sony2fuji_atmosphere_config* c) { s->active.atmosphere=*c;return SONY2FUJI_STATUS_OK; }
extern "C" sony2fuji_status sony2fuji_session_set_color_grading(sony2fuji_session* s,const sony2fuji_color_grading_config* c) { s->active.grading=*c;return SONY2FUJI_STATUS_OK; }
extern "C" sony2fuji_status sony2fuji_session_set_tone_curve(sony2fuji_session* s,const sony2fuji_tone_curve_config* c) { s->active.curve=*c;return SONY2FUJI_STATUS_OK; }

static void testWhiteBalanceCache() {
    namespace fs = std::filesystem;
    const auto directory = fs::temp_directory_path() / ("rawlab-wb-probe-" + std::to_string(std::random_device{}()));
    if (!fs::create_directory(directory)) throw std::runtime_error("Cannot create a fresh probe fixture directory");
    const auto source = directory / "source.dng";
    const auto replacement = directory / "replacement.dng";
    std::ofstream(source).put('a');

    rawlab::RecipeWhiteBalanceCache cache;
    int probes = 0;
    auto read = [&]() -> std::optional<rawlab::RecipeWhiteBalance> {
        ++probes;
        return rawlab::RecipeWhiteBalance{5000, static_cast<float>(probes)};
    };
    assert(cache.resolve(source.c_str(), 2, 0, 0, read)->tint == 1);
    assert(cache.resolve(source.c_str(), 2, 0, 0, read)->tint == 1 && probes == 1);
    assert(cache.resolve(source.c_str(), 1, 0, 0, read)->tint == 2);
    assert(cache.resolve(source.c_str(), 1, 1, 0, read)->tint == 3);
    assert(cache.resolve(source.c_str(), 1, 1, 1, read)->tint == 4);

    const auto modified = fs::last_write_time(source);
    std::ofstream(replacement).put('b');
    fs::last_write_time(replacement, modified);
    fs::rename(replacement, source);
    assert(fs::last_write_time(source) == modified && fs::file_size(source) == 1);
    try {
        cache.resolve(source.c_str(), 1, 1, 1, []() -> std::optional<rawlab::RecipeWhiteBalance> {
            throw std::runtime_error("cancelled probe");
        });
        assert(false);
    } catch (const std::runtime_error&) {}
    assert(cache.resolve(source.c_str(), 1, 1, 1, read)->tint == 5);

    assert(!cache.resolve(source.c_str(), 1, 1, 0, [&]() -> std::optional<rawlab::RecipeWhiteBalance> {
        ++probes;
        return std::nullopt;
    }));
    assert(!cache.resolve(source.c_str(), 1, 1, 0, read) && probes == 6);
    fs::remove_all(directory);
    std::cout << "PASS: camera white balance probes are reused and invalidated by RAW identity or decode settings\n";
}

int main() {
    sony2fuji_session session;
    auto& active=session.active;
    active.tone.black_point=.2f;active.tone.white_point=-.3f;active.tone.vibrance=.4f;
    active.atmosphere.clarity=.6f;active.atmosphere.dehaze=.8f;
    active.grading.shadows_hue=120;active.grading.shadows_saturation=30;
    active.curve.mode=SONY2FUJI_CURVE_CUSTOM;active.curve.count=3;
    active.curve.points[0]={0,0};active.curve.points[1]={.5,.7};active.curve.points[2]={1,1};
    const auto saved=active;
    for(bool fail : {false,true}) {
        try {
            rawlab::RecipeProbeStageScope scope(&session,saved);
            assert(active.tone.black_point==0 && active.tone.white_point==0 && active.tone.vibrance==0);
            assert(active.atmosphere.clarity==0 && active.atmosphere.dehaze==0);
            assert(active.grading.shadows_saturation==0 && active.curve.mode==0 && active.curve.count==0);
            if(fail)throw std::runtime_error("injected probe failure");
        } catch(const std::runtime_error&) {}
        assert(std::memcmp(&active,&saved,sizeof(saved))==0);
    }
    std::cout<<"PASS: recipe probe uses identity stages and restores them after success or failure\n";
    testWhiteBalanceCache();
}
