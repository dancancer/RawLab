# Hosted Verification

The [workflow](../../.github/workflows/ci.yml) verifies pull requests targeting
`development`, `release/**` or `main`, and pushes to `development` or `main`.
Release branches are verified through PRs rather than duplicate push runs. It does not
run on tags, publish packages, create releases, deploy, notarize or use signing
credentials. A workflow run is not release authorization.

## Required Checks

| Check | Hosted runner | Coverage |
| --- | --- | --- |
| Contracts and CI policy | Ubuntu 24.04 | Workflow boundary guards, single-preview source contracts, whitespace |
| macOS build and parity (arm64 / x86_64) | macOS 26 arm64 and Intel; deployment target 14.0 | Default app/bundle and full-feature native build for each architecture; CPU-safe CTest; real RAW/raster GUI-Agent-batch parity; edit model, photo-copy/localization and SDK-free analytics lifecycle |
| Windows build and parity | Windows Server 2022 x64 / VS 2022 | Default native and self-contained .NET 8 package; selected CPU-safe CTest/schema; managed editing/localization/denoise/profile; RAW/raster Agent and default-comparison integration |
| Android build and JVM tests | Ubuntu 24.04 / JDK 17 | JVM tests, lint, debug app and instrumentation test APK compilation, arm64-v8a/x86_64 native libraries and 16 KB alignment |
| iOS framework and unsigned app | macOS 26 arm64 / Xcode | Existing full-feature device arm64 and simulator arm64/x86_64 framework; resource/license/runtime-dependency verification; unsigned simulator app and UI-test compilation |

All six checks (five job groups, including both Mac architectures) must
**succeed on the current PR head/test merge**. A missing,
skipped, cancelled or stale-head run is not a pass. After merge, also inspect the
push run for the exact `development` merge SHA. Logs print the checked-out SHA;
PR checks may test GitHub's synthetic merge commit rather than the source head.
Use the run's event, source head, checkout SHA and base together when recording
evidence. A later source/base change invalidates the earlier integration result.
This is the merge acceptance policy; this task does not change repository branch
protection settings or grant permission to bypass them.

## Boundaries

- Default builds retain Adobe DNG SDK, Lensfun, chroma and wavelet denoise. No
  optional product feature is disabled to obtain a green check.
- Release-style builds (macOS `build.sh`, Windows `build.ps1`) download the
  pinned vendor RUM SDK from its versioned public URL and fail on a SHA-256
  mismatch; the Android and iOS jobs build Debug, which carries no SDK. No job
  launches a packaged app, uses secrets or sends RUM traffic.
- macOS explicitly excludes `native_dcp_metal`, `gpu_photo` and `metal_denoise`
  from the hosted CTest invocation. Other tests may exercise an available GPU
  opportunistically; this is not a guaranteed physical GPU gate.
- Windows does not invoke `build.ps1 -Test`: that entry point's default suite
  requires physical D3D11 and an external RAW path. The hosted suite uses the
  already-public tracked DJI DNG and explicitly selected CPU-safe cases.
- The iOS job compiles UI tests with `build-for-testing`; it does **not** execute
  XCTest, import Photos fixtures, sign a device app or validate installation.
- Android compiles instrumentation tests but does **not** run connected-device
  tests. GLES, SAF, OEM locale and physical interaction evidence stays separate.
- Building both architectures with a 14.0 minimum on macOS 26 does not establish
  runtime support on macOS 14; native acceptance on the minimum OS is separate.
  [Runner labels](https://github.com/actions/runner-images/blob/main/README.md)
  and toolchains can change; logs identify the actual environment.
- Mac dependencies include source-built dynamic GLib/Lensfun rather than a
  higher-minimum Homebrew bottle. App/bundled-dylib architecture and minimum OS
  are checked by the existing bundle gate. The 14.0-target picker model/native
  bridge regressions run on both hosted architectures, not on an OS 14 host.

## Safety and Results

Actions are pinned to full commit SHAs. Workflow permission is `contents: read`,
checkout credentials are not persisted, and no `pull_request_target` is used.
The workflow has bounded jobs and cancels obsolete runs for the same PR/ref.

## Native Dependency Caches

PR checks restore third-party native dependencies using an exact cache key.
Push checks on **both `development` and `main` never restore native caches**:
they still build all dependencies from source, then save successful results for
later PRs. PR misses also build from source and save only after the full job
succeeds. A cache miss or cache-service outage is not permission to skip a build.

This deliberately uses separate restore/save actions. GitHub makes base/default
branch caches available to PRs, while a cache created under a PR merge ref cannot
seed unrelated PRs. See the [GitHub cache scope reference](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching#restrictions-for-accessing-a-cache).

[`native_cache.py`](../../scripts/ci/native_cache.py) owns the input/path allowlists.
Keys include pinned dependency versions/checksums, patches and build scripts,
workflow configuration, compiler and SDK identity, runner image, target
architectures/minimum OS, and the absolute workspace/toolchain paths. This last
constraint matters for pkg-config prefixes, Lensfun's `libraries.json` and
CMake/Xcode/MSBuild state. There are no prefix/fallback restore keys.

| Platform | Cached | Always rebuilt |
| --- | --- | --- |
| macOS | Architecture-specific dependency and Lensfun install prefixes | C++ core, CLI/tests, Swift app, resources and bundle validation |
| Windows | FetchContent dependencies, DNG SDK, wavelib, OpenCV libraries and Lensfun install | LibRaw wrapper, RawLab native libraries/CLI/tests and self-contained app |
| Android | Per-ABI third-party subtrees and Ninja dependency metadata | LibRaw wrapper, core/JNI, JVM tests, lint, app and test APK |
| iOS | Per-slice third-party subtrees, dependency-only Xcode objects/build metadata and pinned sources | RawLab core objects, framework linking/packaging, framework verification and unsigned app/test compilation |

No final product binary, test result or entire application build tree is cached.
Exact hits bypass redundant Mac dependency builders and Lensfun configuration,
but retain dependency checks and all existing build/test commands. Missing
cached Lensfun libraries fail configuration rather than silently dropping it.
The Mac jobs also exercise a small real Xcode cold/restore build: an unchanged
dependency object must retain its timestamp while changed product code is rebuilt.
Android retains AGP's configure fingerprint and command metadata so a fresh job
does not delete restored dependency directories before CMake runs. Its real AGP
cold/restore regression also verifies that changed JNI code is rebuilt.

`build/ci/native-cache.json` records the key and its inputs; `native-cache-size.json`
records the selected file count and bytes. Compare cold and warm hosted runs on
the same source, separating queue time from job time. A successful restore alone
does not demonstrate a speedup. Parallelism remains at the existing settings;
increasing it requires separate hosted timing and memory evidence.

### Hosted Measurement: 2026-10-18

The [cold run](https://github.com/dancancer/RawLab/actions/runs/39114495492/attempts/1)
and [warm rerun](https://github.com/dancancer/RawLab/actions/runs/39114495492/attempts/2)
used source `7bf19e6d665ea952e40af5495db7e47876f893e8` and test merge
`18ca28d242885fb2a32c3d17323b7f78a1f576b1`. All six checks passed in both
attempts; all five native jobs restored exact keys in the warm attempt.

| Platform | Cold job | Warm job | Reduction |
| --- | ---: | ---: | ---: |
| macOS Intel | 37m22s | 21m13s | 43% |
| macOS Apple silicon | 16m30s | 11m15s | 32% |
| Windows | 15m59s | 9m26s | 41% |
| Android | 21m02s | 20m26s | 3% |
| iOS | 45m37s | 15m14s | 67% |

These are single-run job durations including setup, restore and tests, not a
stable performance guarantee. The longest job fell from 45m37s to 21m13s.
Android's improvement was not material in this sample. Build parallelism stayed
unchanged. iOS C/C++ compile entries fell from 2,188 to 229, while all 72 entries
under `lutools/src/` remained in both attempts.

Queueing is separate: the longest queue was 65m51s cold and 22m22s warm. Full
workflow wall time was 1h45m44s and 43m36s respectively; that difference must not
be attributed solely to caching. The five compressed dependency caches totaled
2.61 GiB. Subsequent integration checks against newer `development` commits are
reported in the PR, not mixed into this same-source comparison.

## Results

Only `build/ci/*.log`, `*.json` and `*.xml` are uploaded, retained for seven days.
Do not widen this allowlist to photos, RAW inputs, screenshots, user profiles,
app bundles, native binaries, APKs or entire build directories. Build packages
are ephemeral verification outputs, not versioned release candidates.

Local workflow-policy regression tests:

```sh
python3 -m venv /tmp/rawlab-ci-venv
/tmp/rawlab-ci-venv/bin/pip install -r scripts/ci/requirements.txt
/tmp/rawlab-ci-venv/bin/python -m unittest discover -s scripts/ci -p 'test_*.py' -v
```

These guards supplement, not replace, workflow syntax linting and actual hosted
execution. Platform jobs stop on command/test failures; they are not allowed to
silently skip a required suite or mark a failing native process successful.

The [archived 0.8 preparation ledger](../archive/releases/v0.8/preparation.md)
retains its original candidate scope. Use [release notes](../releases/v0.8/v0.8.1.md)
and package provenance for delivered artifacts; historical local/device reports
retain their original source and device scope.
