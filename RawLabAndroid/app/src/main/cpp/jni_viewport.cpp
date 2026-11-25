#include "jni_internal.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <vector>

namespace {

using namespace rawlab::jni;

jdoubleArray packTilesToDoubleArray(JNIEnv* env, const std::vector<sony2fuji_pyramid_tile_v1>& tiles) {
    if (tiles.empty()) {
        return env->NewDoubleArray(0);
    }
    if (tiles.size() > static_cast<size_t>(std::numeric_limits<jsize>::max() / 8)) {
        return nullptr;
    }
    std::vector<jdouble> packed;
    packed.reserve(tiles.size() * 8u);
    for (const auto& tile : tiles) {
        packed.push_back(static_cast<jdouble>(tile.level));
        packed.push_back(static_cast<jdouble>(tile.col));
        packed.push_back(static_cast<jdouble>(tile.row));
        packed.push_back(static_cast<jdouble>(tile.max_output_long_edge));
        packed.push_back(static_cast<jdouble>(tile.norm_x0));
        packed.push_back(static_cast<jdouble>(tile.norm_y0));
        packed.push_back(static_cast<jdouble>(tile.norm_x1));
        packed.push_back(static_cast<jdouble>(tile.norm_y1));
    }
    jdoubleArray out = env->NewDoubleArray(static_cast<jsize>(packed.size()));
    if (!out) return nullptr;
    env->SetDoubleArrayRegion(out, 0, static_cast<jsize>(packed.size()), packed.data());
    return env->ExceptionCheck() ? nullptr : out;
}

} // namespace

extern "C" JNIEXPORT jboolean JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeSupportsFastFullResGpu(
    JNIEnv* env, jobject, jlong id, jint inputType, jint inputWidth, jint inputHeight,
    jint maxPixels, jstring inputPath, jstring editStateJson) {
    try {
        if (inputWidth < 0 || inputHeight < 0 || maxPixels < 0) {
            throw std::invalid_argument("Invalid fast GPU query dimensions");
        }
        UtfChars in(env, inputPath);
        UtfChars json(env, editStateJson);
        SessionGuard guard(id);
        const sony2fuji_fast_gpu_query_v1 query{
            SONY2FUJI_FAST_GPU_QUERY_V1_VERSION,
            sizeof(sony2fuji_fast_gpu_query_v1),
            static_cast<sony2fuji_input_type>(inputType),
            static_cast<uint32_t>(inputWidth),
            static_cast<uint32_t>(inputHeight),
            static_cast<uint32_t>(maxPixels),
            in.chars,
        };
        int32_t supported = 0;
        check(sony2fuji_session_supports_fast_full_res_gpu(guard.get(), &query, json.chars, &supported), guard.get());
        return supported != 0 ? JNI_TRUE : JNI_FALSE;
    } catch (...) {
        handleSdrException(env, "Not enough memory to query fast GPU support");
        return JNI_FALSE;
    }
}

extern "C" JNIEXPORT jint JNICALL
Java_com_rawlab_android_editor_canvas_ViewportNative_nativePyramidLevel(
    JNIEnv*, jclass, jdouble zoomScale, jdouble baseScale) {
    int32_t level = -1;
    if (sony2fuji_pyramid_level(zoomScale, baseScale, &level) != SONY2FUJI_STATUS_OK) {
        return -1;
    }
    return static_cast<jint>(level);
}

extern "C" JNIEXPORT jdoubleArray JNICALL
Java_com_rawlab_android_editor_canvas_ViewportNative_nativePyramidTiles(
    JNIEnv* env, jclass, jint fullWidth, jint fullHeight, jint tileSize, jint overscanRing,
    jdouble zoomScale, jdouble baseScale,
    jdouble visibleX0, jdouble visibleY0, jdouble visibleX1, jdouble visibleY1) {
    if (fullWidth <= 0 || fullHeight <= 0 || tileSize <= 0 || overscanRing < 0) {
        return nullptr;
    }
    try {
        const sony2fuji_pyramid_config_v1 config{
            SONY2FUJI_PYRAMID_CONFIG_V1_VERSION,
            sizeof(sony2fuji_pyramid_config_v1),
            static_cast<uint32_t>(fullWidth),
            static_cast<uint32_t>(fullHeight),
            static_cast<uint32_t>(tileSize),
            static_cast<uint32_t>(overscanRing),
            zoomScale,
            baseScale,
            visibleX0,
            visibleY0,
            visibleX1,
            visibleY1,
        };
        uint32_t count = 0;
        if (sony2fuji_pyramid_tiles(&config, nullptr, 0, &count) != SONY2FUJI_STATUS_OK) {
            return nullptr;
        }
        if (count == 0) {
            return env->NewDoubleArray(0);
        }
        std::vector<sony2fuji_pyramid_tile_v1> tiles(count);
        if (sony2fuji_pyramid_tiles(&config, tiles.data(), count, &count) != SONY2FUJI_STATUS_OK) {
            return nullptr;
        }
        tiles.resize(count);
        return packTilesToDoubleArray(env, tiles);
    } catch (...) {
        return nullptr;
    }
}

extern "C" JNIEXPORT jdoubleArray JNICALL
Java_com_rawlab_android_editor_canvas_ViewportNative_nativePyramidLevel0Grid(
    JNIEnv* env, jclass, jint fullWidth, jint fullHeight, jint tileSize) {
    if (fullWidth <= 0 || fullHeight <= 0 || tileSize <= 0) {
        return nullptr;
    }
    try {
        uint32_t count = 0;
        if (sony2fuji_pyramid_level0_grid(
                static_cast<uint32_t>(fullWidth),
                static_cast<uint32_t>(fullHeight),
                static_cast<uint32_t>(tileSize),
                nullptr, 0, &count) != SONY2FUJI_STATUS_OK) {
            return nullptr;
        }
        if (count == 0) {
            return env->NewDoubleArray(0);
        }
        std::vector<sony2fuji_pyramid_tile_v1> tiles(count);
        if (sony2fuji_pyramid_level0_grid(
                static_cast<uint32_t>(fullWidth),
                static_cast<uint32_t>(fullHeight),
                static_cast<uint32_t>(tileSize),
                tiles.data(), count, &count) != SONY2FUJI_STATUS_OK) {
            return nullptr;
        }
        tiles.resize(count);
        return packTilesToDoubleArray(env, tiles);
    } catch (...) {
        return nullptr;
    }
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_rawlab_android_editor_canvas_ViewportNative_nativeDetailOverlayCovers(
    JNIEnv*, jclass,
    jint tilePixelWidth, jint tilePixelHeight,
    jint fullWidth, jint fullHeight,
    jint maxOutputLongEdge,
    jdouble tileNormX0, jdouble tileNormY0, jdouble tileNormX1, jdouble tileNormY1,
    jdouble visibleNormX0, jdouble visibleNormY0, jdouble visibleNormX1, jdouble visibleNormY1,
    jdouble requiredZoomScale) {
    if (tilePixelWidth <= 0 || tilePixelHeight <= 0 ||
        fullWidth <= 0 || fullHeight <= 0 || maxOutputLongEdge < 0) {
        return JNI_FALSE;
    }
    const sony2fuji_detail_coverage_query_v1 query{
        SONY2FUJI_DETAIL_COVERAGE_QUERY_V1_VERSION,
        sizeof(sony2fuji_detail_coverage_query_v1),
        static_cast<uint32_t>(tilePixelWidth),
        static_cast<uint32_t>(tilePixelHeight),
        static_cast<uint32_t>(fullWidth),
        static_cast<uint32_t>(fullHeight),
        static_cast<uint32_t>(maxOutputLongEdge),
        0u,
        tileNormX0,
        tileNormY0,
        tileNormX1,
        tileNormY1,
        visibleNormX0,
        visibleNormY0,
        visibleNormX1,
        visibleNormY1,
        requiredZoomScale,
    };
    int32_t covers = 0;
    return sony2fuji_detail_overlay_covers(&query, &covers) == SONY2FUJI_STATUS_OK && covers != 0
        ? JNI_TRUE
        : JNI_FALSE;
}
