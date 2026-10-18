# CPU geometry benchmark (2026-10-18)

## Scope and claim check

Baseline: `a883b91c547e9cc6d5f463d9ece25720dc33e8cd` on
`feature/core-geometry-cpu-perf`. The geometry source, header and color contract
are unchanged from the architecture review's `e493bb2`. The literal claim that
the entire `lutools/` subtree is unchanged is not true: unrelated Lensfun cache
handling and DNG test diagnostics changed in the meantime.

The performance lead is confirmed in the baseline `src/core/photo_geometry.cpp`:
lines 80-88 evaluate double coordinates per pixel, and lines 124-131 read source
columns for a quarter turn. Production OpenMP settings are OFF in
`RawLabMac/build.sh:48`, `RawLabWindows/native/CMakeLists.txt:46`,
`lutools/platform/ios/build-framework.sh:58`, and
`RawLabAndroid/app/src/main/cpp/CMakeLists.txt:39`. The generic Android default
is also OFF (`lutools/CMakeLists.txt:40-44`). No OpenMP change is part of this work.

## Exactness and design

- Canvas construction, validation, identity bypass and allocation/error behavior
  remain unchanged. No API, C ABI, geometry ordering or resize policy changes.
- Integer mappings are signed permutations of integer coordinates. Derive the
  origin and strides once, copy forward-contiguous rows with `std::copy_n`, and
  visit quarter-turn transposes in 32x32 tiles. No pixel arithmetic is performed.
- Interpolating mappings keep the original double expressions and division
  order. Only the row-invariant `dy` moves outside the inner loop. Compute 256
  independent coordinates before sampling them, using a 4096-byte stack buffer.
  This lets the compiler schedule independent arithmetic without manual SIMD,
  threads, reciprocal substitutions, incremental coordinates or downscaling.
- Clamped sample coordinates are finite and nonnegative, so integer truncation
  is exactly equivalent to `floor`. Bilinear float expressions are unchanged.

`tests/photo_geometry_oracle.cpp` preserves the baseline helper and
`applyGeometry` bodies verbatim in a test-only namespace. It shares only the
unchanged `GeometryOptions::valid()/active()` guards with production code.
It is never linked into the shipping core or benchmark.

The deterministic xorshift matrix (seed `0x67a91e35`) compares status, dimensions,
pixel count and `memcmp`: all 16 turn/flip combinations, six crop regions,
edge tolerance/subnormal crops, extreme and random straighten/perspective
combinations, odd/tiny/single-row/single-column images, exact tile/batch multiples,
large batch tails, negative/super-white values, signed zero, subnormals, infinities
and NaN payloads. There are 9,024 comparisons per run.

The unchanged implementation necessarily passes its own oracle, so a behavioral
RED on baseline is impossible. A one-ULP mutation of the first actual pixel was
detected at comparison 1 and removed. More importantly, an intermediate attempt
to skip zero perspective terms failed at comparison 4803 under Mac
`-ffp-contract=fast` (32x33, -45 degrees). That specialization was removed;
the original denominator expression is retained. Final default/off/fast
contraction runs pass independently against the oracle on both compilers.
This does not assert identical output *between* different compiler/FP modes.

## Reproduction

Run from the repository root. The benchmark is `EXCLUDE_FROM_ALL`, not a CTest;
neither building the default targets nor running CTest executes it.

```sh
cmake --build lutools/build-macos --target geometry_benchmark -j 6
lutools/build-macos/geometry_benchmark
```

For standalone measurements without core dependencies:

```sh
TMP="$(mktemp -d)"
git show a883b91:lutools/src/core/photo_geometry.cpp > "$TMP/before.cpp"
FLAGS=(-std=c++17 -O3 -DNDEBUG -I lutools/include -I lutools/src)
clang++ "${FLAGS[@]}" lutools/tests/geometry_benchmark.cpp "$TMP/before.cpp" -o "$TMP/before"
clang++ "${FLAGS[@]}" lutools/tests/geometry_benchmark.cpp lutools/src/core/photo_geometry.cpp -o "$TMP/after"
"$TMP/before"
"$TMP/after"
for mode in default off fast; do
    FP=()
    if [ "$mode" != default ]; then FP=(-ffp-contract="$mode"); fi
    clang++ "${FLAGS[@]}" "${FP[@]}" lutools/tests/photo_geometry_exactness_tests.cpp \
        lutools/tests/photo_geometry_oracle.cpp lutools/src/core/photo_geometry.cpp -o "$TMP/exact-$mode"
    "$TMP/exact-$mode"
done
rm -rf "$TMP"
```

Android uses NDK `27.2.12479018`, the version pinned by the app:

```sh
NDK="$HOME/Library/Android/sdk/ndk/27.2.12479018"
CXX="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android26-clang++"
TMP="$(mktemp -d)"
git show a883b91:lutools/src/core/photo_geometry.cpp > "$TMP/before.cpp"
FLAGS=(-std=c++17 -O3 -DNDEBUG -static-libstdc++ -I lutools/include -I lutools/src)
"$CXX" "${FLAGS[@]}" lutools/tests/geometry_benchmark.cpp "$TMP/before.cpp" -o "$TMP/before"
"$CXX" "${FLAGS[@]}" lutools/tests/geometry_benchmark.cpp lutools/src/core/photo_geometry.cpp -o "$TMP/after"
# Compile exactness with the same command as Mac, replacing clang++ with "$CXX".
```

All device commands, including cleanup, must run while holding the shared lock.
Use the existing adb server and never access other devices or installed apps:

```sh
set -e
LOCK=/Users/xupeng/mycode/rawtools/.cache/tmp/locks/device-HA1ZKK0Q
until mkdir "$LOCK" 2>/dev/null; do sleep 30; done
cleanup() {
    adb -s HA1ZKK0Q shell rm -f /data/local/tmp/rawlab-geometry-before /data/local/tmp/rawlab-geometry-after || true
    rmdir "$LOCK"
}
trap cleanup EXIT
for mode in before after; do
    adb -s HA1ZKK0Q push "$TMP/$mode" "/data/local/tmp/rawlab-geometry-$mode"
    adb -s HA1ZKK0Q shell chmod 755 "/data/local/tmp/rawlab-geometry-$mode"
    adb -s HA1ZKK0Q shell "/data/local/tmp/rawlab-geometry-$mode"
done
# Also remove any separately pushed exactness executables before releasing the lock.
```

Remove the host `$TMP` after the device session. Each case creates a synthetic
float RGB gradient `(x/width, y/height, (x+y)/(width+height))`. Crop is
`(.1, .1, .8, .8)`; flip is horizontal; turn is clockwise. There is one warm-up
and five timed runs per case. Input copy is outside the timed region;
allocation, mapping, sampling and input replacement inside `applyGeometry` are
included. Checksums are consumed outside the timer. All implementations are
single-threaded; there is no CPU affinity, clock pinning or thermal control.
These are isolated stage measurements, not full render times or frame rates.

## Measurements

Each value is median [minimum, maximum], in milliseconds. Before and after use
the same compiler/flags, fixtures and timing procedure, not the old review's
numbers. The baseline is measured before modifying production geometry.

### Apple M3 Max

Apple clang 21.0.0 (`clang-2100.3.34.2`), arm64, `-std=c++17 -O3 -DNDEBUG`,
default FP contraction, no OpenMP.

| Input | Case | Before | After | Speedup |
| --- | --- | ---: | ---: | ---: |
| 1600x1067 | Crop | 1.929 [1.859, 2.059] | 0.530 [0.516, 0.721] | 3.64x |
| 1600x1067 | Turn 90 | 3.220 [3.147, 3.592] | 2.558 [2.421, 3.702] | 1.26x |
| 1600x1067 | Flip | 3.140 [3.063, 3.352] | 1.530 [1.423, 1.651] | 2.05x |
| 1600x1067 | Crop + turn 90 | 1.951 [1.934, 1.983] | 1.343 [1.262, 1.602] | 1.45x |
| 1600x1067 | Straighten 3 | 10.603 [10.396, 10.792] | 7.810 [7.730, 8.189] | 1.36x |
| 1600x1067 | Perspective h0.2 + straighten 3 | 9.216 [9.153, 9.457] | 7.118 [6.998, 7.670] | 1.29x |
| 7008x4672 | Crop | 36.294 [36.041, 37.818] | 6.954 [6.760, 7.374] | 5.22x |
| 7008x4672 | Turn 90 | 89.057 [88.332, 91.869] | 42.308 [40.591, 49.839] | 2.10x |
| 7008x4672 | Flip | 58.469 [57.091, 58.975] | 19.689 [19.209, 21.027] | 2.97x |
| 7008x4672 | Crop + turn 90 | 56.108 [55.015, 61.038] | 26.117 [25.377, 27.525] | 2.15x |
| 7008x4672 | Straighten 3 | 195.530 [193.600, 195.839] | 138.398 [133.632, 142.306] | 1.41x |
| 7008x4672 | Perspective h0.2 + straighten 3 | 174.857 [172.076, 185.335] | 127.005 [124.511, 130.662] | 1.38x |

### Lenovo TB320FC

Physical device `HA1ZKK0Q`, Android 15, arm64, NDK clang 18.0.3 (r522817c),
Android API 26 target, `-std=c++17 -O3 -DNDEBUG -static-libstdc++`, default FP
contraction, no OpenMP. Each session held and released the shared device lock.

| Input | Case | Before | After | Speedup |
| --- | --- | ---: | ---: | ---: |
| 1600x1067 | Crop | 4.868 [4.689, 4.968] | 3.670 [3.523, 3.717] | 1.33x |
| 1600x1067 | Turn 90 | 11.244 [10.770, 11.663] | 6.738 [6.618, 6.760] | 1.67x |
| 1600x1067 | Flip | 7.220 [7.125, 7.266] | 6.247 [6.185, 6.297] | 1.16x |
| 1600x1067 | Crop + turn 90 | 6.861 [6.726, 7.040] | 4.634 [4.569, 4.657] | 1.48x |
| 1600x1067 | Straighten 3 | 25.283 [24.792, 25.382] | 18.513 [18.301, 18.589] | 1.37x |
| 1600x1067 | Perspective h0.2 + straighten 3 | 24.022 [23.921, 24.243] | 18.434 [18.241, 18.468] | 1.30x |
| 7008x4672 | Crop | 108.435 [108.417, 109.905] | 91.618 [90.175, 92.304] | 1.18x |
| 7008x4672 | Turn 90 | 275.023 [273.586, 277.191] | 148.655 [147.391, 152.024] | 1.85x |
| 7008x4672 | Flip | 158.035 [157.541, 158.523] | 131.499 [131.330, 131.964] | 1.20x |
| 7008x4672 | Crop + turn 90 | 170.353 [169.310, 171.224] | 117.911 [117.394, 119.085] | 1.44x |
| 7008x4672 | Straighten 3 | 500.330 [499.669, 506.641] | 356.963 [355.954, 357.417] | 1.40x |
| 7008x4672 | Perspective h0.2 + straighten 3 | 475.739 [474.402, 476.253] | 347.817 [347.578, 348.062] | 1.37x |

## Core verification environment

Mac validation configured a build inside this worktree at `lutools/build-macos`
(removed after verification). It reused the existing, read-only macOS 15 arm64 dependency prefix rather than
copying or rebuilding dependencies in another worktree:

```sh
export PKG_CONFIG_PATH=/Users/xupeng/mycode/rawtools/build/macos15-deps/arm64/install/lib/pkgconfig:/opt/homebrew/Library/Homebrew/os/mac/pkgconfig/26:/opt/homebrew/opt/libtiff/lib/pkgconfig
cmake -S lutools -B lutools/build-macos -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DBUILD_SHARED_LIB=OFF -DBUILD_TESTING=ON -DSONY2FUJI_ENABLE_OPENMP=OFF \
    -DSONY2FUJI_ENABLE_LENSFUN=OFF -DSONY2FUJI_ENABLE_GPU=ON \
    -DSONY2FUJI_ENABLE_DNGSDK=ON -DSONY2FUJI_ENABLE_CHROMA_DENOISE=ON \
    -DSONY2FUJI_ENABLE_WAVELET_DENOISE=ON \
    -DSONY2FUJI_TEST_RAW=/Users/xupeng/mycode/rawtools/.cache/shared/raw/73c79fd9fbd73dff89548b611aaedc3c5a7e3412ec190c23881ea8434ff2214c.arw
cmake --build lutools/build-macos -j 6
ctest --test-dir lutools/build-macos --output-on-failure
```

This configures/builds the Mac core and CLI, not a full application. The available
prefix supplies LibRaw 0.22.2, DNG SDK 1.7.1, OpenCV 4.12.0 and wavelib 1.0.0.
Lensfun is unavailable and disabled. Homebrew TIFF 4.7.1 links successfully on
this host but warns that its deployment target is 26.0, newer than this test
configuration's 15.0. This is not verification of the shipping macOS 14 build.

The existing `dng_jxl` SDK OOM test fails before geometry with
`FAIL SDK OOM survives load, WB reload and C ABI` and
`Corrupted data or unexpected EOF`. Replacing only the geometry object in the
same core archive with the original `a883b91` object and relinking the same DNG
test reproduces the identical failure (exit 1). No DNG files were changed to
hide it.

Final production-code CTest: **43/44 passed**, 234.02 seconds; only `dng_jxl`
failed. Geometry/perspective unit, API, CLI, recipe and real-RAW tests passed.
The final enlarged exactness matrix was subsequently rebuilt and rerun with
`ctest --test-dir lutools/build-macos --output-on-failure -R 'geometry|perspective'`:
**10/10 passed**, 23.50 seconds. `ctest -N -R benchmark` lists zero tests, and the
explicit `geometry_benchmark` target builds successfully. Mac standalone default/off/fast and
ASan+UBSan each report `PASS 9024 bit-exact geometry comparisons` (exit 0).
NDK standalone default/off/fast each report the same result on the physical
device. No full platform applications, Windows/iOS runtime, shipping macOS 14
dependencies, Lensfun-enabled build or CI run was performed.

## Optional full-render comparison

Used the existing shared Sony A7 IV RAW sample, SHA-256
`73c79fd9fbd73dff89548b611aaedc3c5a7e3412ec190c23881ea8434ff2214c`;
no downloads or RAW copies. On Mac, a temporary C ABI harness used one session
per case, GPU OFF, camera WB, no LUT or adjustments, FINAL intent, native RGB8
buffer output, no early/final resizing, one warm-up and five timed process calls.
The timed calls reuse the warmed session/decoder; they are not cold RAW imports.
Buffer release was outside the timer; all process statuses were OK.

| Geometry | Output | Median [min, max] ms |
| --- | --- | ---: |
| None | 7008x4672 | 1162.484 [1151.298, 1181.696] |
| Crop (.1, .1, .8, .8) | 5608x3738 | 1157.587 [1151.314, 1159.746] |

The ranges overlap. Crop reduces output-buffer work while adding geometry, so
the -4.897 ms difference is **not** an isolated geometry measurement. For scale,
the independent synthetic crop stage takes 6.954 ms, around 0.6% of this warmed
full process time; that ratio is not instrumentation of geometry inside the RAW
render. The temporary harness and build/device artifacts were removed afterward.
