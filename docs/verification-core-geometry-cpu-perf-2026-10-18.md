# CPU Geometry Verification (2026-10-18)

Baseline: `a883b91`; optimization measurements: `75aee3e`, before the nesting-only follow-up. No threading change is part of this work.
Integer mappings use exact strides and 32x32 transpose tiles; `copyRectangle` separates tile traversal from row copies, with nesting at most three levels.
Interpolation batches 256 independent double coordinates (4 KiB), preserving arithmetic/division order; nonnegative clamped-coordinate truncation equals floor. Canvas, API, resize and pixel contracts are unchanged.

## Exactness
The test-only oracle preserves the baseline helper and `applyGeometry` bodies verbatim; only unchanged `valid()/active()` guards are shared.
Each run checks status, dimensions, pixel count and `memcmp` for 9,024 deterministic cases (seed `0x67a91e35`): all turns/flips, edge/subnormal crops, straighten/perspective combinations, odd/tiny/1xN/Nx1 images, tile/batch boundaries, signed zero, subnormals, Inf and NaN payloads.
Baseline versus itself necessarily passes. A one-ULP mutation failed; an intermediate zero-perspective specialization failed under `-ffp-contract=fast` and was removed.
After rectangle extraction: Mac default/off/fast and NDK default each PASS 9,024 comparisons; geometry/perspective CTest 10/10 (22.99 s). Equality is against each compiler/mode's oracle, not between FP modes.

## Reproduce
Run from the repository root in bash; standalone tests/benchmarks need no core dependencies. The benchmark is opt-in, not part of CTest.
```bash
set -e
T="$(mktemp -d)"
FLAGS=(-std=c++17 -O3 -DNDEBUG -I lutools/include -I lutools/src)
SOURCES=(lutools/tests/photo_geometry_exactness_tests.cpp lutools/tests/photo_geometry_oracle.cpp lutools/src/core/photo_geometry.cpp)
for mode in default off fast; do
    FP=(); if [ "$mode" != default ]; then FP=(-ffp-contract="$mode"); fi
    clang++ "${FLAGS[@]}" "${FP[@]}" "${SOURCES[@]}" -o "$T/mac-$mode"
    "$T/mac-$mode"
done
git show a883b91:lutools/src/core/photo_geometry.cpp > "$T/before.cpp"
for source in "$T/before.cpp" lutools/src/core/photo_geometry.cpp; do
    clang++ "${FLAGS[@]}" lutools/tests/geometry_benchmark.cpp "$source" -o "$T/bench"
    "$T/bench"
done
NDK="$HOME/Library/Android/sdk/ndk/27.2.12479018"
"$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android26-clang++" "${FLAGS[@]}" -static-libstdc++ "${SOURCES[@]}" -o "$T/android"
LOCK=/Users/xupeng/mycode/rawtools/.cache/tmp/locks/device-HA1ZKK0Q
until mkdir "$LOCK" 2>/dev/null; do sleep 30; done
trap 'adb -s HA1ZKK0Q shell rm -f /data/local/tmp/rawlab-geometry-review-exact || true; rmdir "$LOCK"' EXIT
adb -s HA1ZKK0Q push "$T/android" /data/local/tmp/rawlab-geometry-review-exact
adb -s HA1ZKK0Q shell chmod 755 /data/local/tmp/rawlab-geometry-review-exact
adb -s HA1ZKK0Q shell /data/local/tmp/rawlab-geometry-review-exact
adb -s HA1ZKK0Q shell rm -f /data/local/tmp/rawlab-geometry-review-exact
rmdir "$LOCK"; trap - EXIT
rm -r "$T"
```
NDK benchmark: use the same compiler/flags as NDK exactness with `geometry_benchmark.cpp` and the chosen geometry source, then run under the same lock/cleanup protocol.
Mac core subset uses the existing read-only dependency prefix, GPU/DNG/denoise ON and Lensfun OFF:
```bash
P=/Users/xupeng/mycode/rawtools/build/macos15-deps/arm64/install
RAW=/Users/xupeng/mycode/rawtools/.cache/shared/raw/73c79fd9fbd73dff89548b611aaedc3c5a7e3412ec190c23881ea8434ff2214c.arw
PKG_CONFIG_PATH="$P/lib/pkgconfig:/opt/homebrew/Library/Homebrew/os/mac/pkgconfig/26:/opt/homebrew/opt/libtiff/lib/pkgconfig" cmake -S lutools -B lutools/build-macos -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DBUILD_SHARED_LIB=OFF -DBUILD_TESTING=ON -DSONY2FUJI_ENABLE_OPENMP=OFF -DSONY2FUJI_ENABLE_LENSFUN=OFF -DSONY2FUJI_ENABLE_GPU=ON -DSONY2FUJI_ENABLE_DNGSDK=ON -DSONY2FUJI_ENABLE_CHROMA_DENOISE=ON -DSONY2FUJI_ENABLE_WAVELET_DENOISE=ON -DSONY2FUJI_TEST_RAW="$RAW"
cmake --build lutools/build-macos --target photo_geometry_tests photo_geometry_exactness_tests perspective_tests perspective_api_tests geometry_api_tests edit_recipe_geometry_tests edit_recipe_perspective_tests sony2fuji_cli -j 6
ctest --test-dir lutools/build-macos --output-on-failure -R 'geometry|perspective'
```

## 7008x4672 Measurements
Synthetic float RGB gradient; copy outside timer; one warm-up + five timed runs; median [min, max] ms, including allocation/replacement. Crop=(.1,.1,.8,.8), flip=horizontal. No clock pinning or thermal control; not full frame times.
Apple M3 Max, Apple clang 21.0.0, `-std=c++17 -O3 -DNDEBUG`, default FP contraction:

| Case | Before | After | Speedup |
| --- | ---: | ---: | ---: |
| Crop | 36.294 [36.041, 37.818] | 6.954 [6.760, 7.374] | 5.22x |
| Turn 90 | 89.057 [88.332, 91.869] | 42.308 [40.591, 49.839] | 2.10x |
| Flip | 58.469 [57.091, 58.975] | 19.689 [19.209, 21.027] | 2.97x |
| Crop + turn 90 | 56.108 [55.015, 61.038] | 26.117 [25.377, 27.525] | 2.15x |
| Straighten 3 | 195.530 [193.600, 195.839] | 138.398 [133.632, 142.306] | 1.41x |
| Perspective h0.2 + straighten 3 | 174.857 [172.076, 185.335] | 127.005 [124.511, 130.662] | 1.38x |

Lenovo TB320FC / HA1ZKK0Q, Android 15, NDK 27.2.12479018 clang 18.0.3, arm64 API 26; same flags plus `-static-libstdc++`:

| Case | Before | After | Speedup |
| --- | ---: | ---: | ---: |
| Crop | 108.435 [108.417, 109.905] | 91.618 [90.175, 92.304] | 1.18x |
| Turn 90 | 275.023 [273.586, 277.191] | 148.655 [147.391, 152.024] | 1.85x |
| Flip | 158.035 [157.541, 158.523] | 131.499 [131.330, 131.964] | 1.20x |
| Crop + turn 90 | 170.353 [169.310, 171.224] | 117.911 [117.394, 119.085] | 1.44x |
| Straighten 3 | 500.330 [499.669, 506.641] | 356.963 [355.954, 357.417] | 1.40x |
| Perspective h0.2 + straighten 3 | 475.739 [474.402, 476.253] | 347.817 [347.578, 348.062] | 1.37x |

## Full Process and Limits
Existing Sony A7 IV RAW (`RAW` above), Mac warmed sessions, GPU OFF, camera WB, no LUT/adjustments, FINAL native RGB8, no resize, one warm-up + five process calls: none 1162.484 [1151.298,1181.696] ms (7008x4672); crop 1157.587 [1151.314,1159.746] ms (5608x3738). Ranges overlap; crop also reduces output work, so the difference is not isolated geometry cost or a cold RAW import.
Earlier full CTest was 43/44: existing `dng_jxl` SDK OOM check failed identically with original geometry. This follow-up reruns only the requested subset. No Windows/iOS runtime, full client application, Lensfun-enabled or shipping macOS 14 build verification; host TIFF links with a newer deployment-target warning. No CI claim.
