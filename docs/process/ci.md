# Verification SOP

This is the project procedure for local checks, automatic CI and requested
verification. [Development rules](../../AGENTS.md) and
[integration rules](integration-workflow.md) use this procedure; workflow changes
must update it together with the executable policy tests.

The [workflow](../../.github/workflows/ci.yml) verifies PRs targeting `development`,
`release/**` or `main`, pushes to `development`, and explicitly requested manual
runs. There is no scheduled full cold build. It does not run on tags, publish,
deploy, sign, notarize or create releases. Verification is not release authorization.

Full macOS and Windows checks compile with the pinned GPU AI models and inference
runtimes. Model provisioning and shared-cache paths are specified in
[desktop release packaging](desktop-release.md). When the default shared-cache
directory (`$RAWLAB_AI_SHARED_CACHE/ai-models/<manifest-sha256>/complete`) is
already present, `ai-inputs.py` validates it offline without downloading; an
explicit `RAWLAB_DUALDN_MODEL_DIR` is likewise validated in place without
downloading. When that default directory is absent (such as on a fresh hosted
VM), `ai-inputs.py` fetches the pinned `macos-arm64` model archive from
`Shared/ai-models/catalog.json` and the CI replay-tensor archive from
`scripts/ci/ai-replay-tensors.json` (both published on `assets-v1`), checks each
archive's size and SHA-256 before decompressing, extracts into a private staging
directory, verifies the unpacked tree against both descriptions, and renames it
atomically to `complete`. A download or verification failure, or an existing
invalid directory, remains a hard failure for macOS arm64 `native` and desktop
`full`. Do not drop those steps, upload private models, add secrets, or call a
model-free `build` run a full pass. Windows `build/native`, macOS `build`, and iOS/Android groups do not
require that model package. No signing keys are used in CI.
Native checks include direct HLSL compilation without a hardware adapter and
GLES source validation with glslang. CPU neural-inference validation is excluded;
ordinary CPU photo processing and deterministic ISP tests remain applicable.
Hardware-unavailable skips do not satisfy the separate release GPU acceptance gate.

Product builds enable the pinned X3F renderer on every platform. Build jobs prepare
Rust 1.99.1, the platform targets and `rust-docs`; Android/Windows also prepare host
libclang. Apple uses Xcode's libclang. Python 3.11+ collects dependency and runtime
notices into each package. Model-only jobs do not build Rust or native dependencies.
The supported camera/settings boundary remains the [X3F contract](../../lutools/docs/x3f-rendering.md).

## Verification Levels

| Event or request | Automatic coverage |
| --- | --- |
| Ordinary PR / `development` push | Static contracts plus fast models for affected platforms; affected Windows also runs the isolated `batch-selection` WPF suite with its native prerequisites; core changes add the macOS core CTest row, and changes to the standalone D3D11 test project's inputs add its Windows configure/build (see [Core CTest on ordinary runs](#core-ctest-on-ordinary-runs) and [Automatic D3D11 build](#automatic-d3d11-build)) |
| Draft PR | Contracts only; platform checks and aggregate result stay skipped |
| PR title/body edit | No checks; **CI result** restates the head's latest automatic result (see [Safety and Results](#safety-and-results)) |
| External fork PR | Contracts and affected-platform models on GitHub-hosted runners, including macOS/iOS; external branch names never request a full cold gate (see [External fork pull requests](#external-fork-pull-requests)) |
| Release or hotfix PR | Every platform, complete non-UI coverage and cold native dependencies |
| Manual run | Exactly the requested platform and check group; a separately named result |

A release/hotfix PR means base `main` or `release/**`, or source `release/*` or
`hotfix/*`. Full verification is reserved for these important gates or an explicit
manual `full` request. UI changes must pass affected local UI checks before commit;
release acceptance also requires the applicable local UI/device matrix.

Apple model runs include shared HDR adjustment-transfer regressions. The iOS model
route also runs the camera protocol, durable original-store and scoped editor-draft
suites; these use local responders and temporary files, without Bluetooth/Wi-Fi
hardware or an iOS signing identity. They do not replace device acceptance.

The manual **Run workflow** form has two selectors:

- `platform`: `all`, `macos`, `windows`, `android`, `ios`.
- `checks`: `contracts`, `models` (default), `build`, `native`, `full`.

| Group | What runs |
| --- | --- |
| `contracts` | Shared static, localization, LUT, protocol and CI-policy checks; platform selector is ignored |
| `models` | Standalone platform model tests without building the product/native dependencies |
| `build` | Complete product/framework/package build and package checks; UI test targets compile but do not run |
| `native` | Required product build plus native/render/CLI/cache integration suites; independent models are omitted |
| `full` | Models + build + native, with cold native dependencies; `platform=all` also runs contracts |

For example, choose `windows` + `models` for an edit-state regression, `macos` +
`native` for native render/CLI parity, or `all` + `full` for a pre-release run.
A build prerequisite is retained when a selected test needs its native artifacts;
this is not reuse of an unverified product binary.

An explicitly requested `platform=windows`, `checks=models` run also builds and
runs the isolated WARP regressions under `RawLabWindows/tests/native/d3d11` on
hosted Windows. This narrow native exception exercises production renderer/filter
sources with a compile-time test device factory and software adapter. Ordinary PR
model checks do not run the WARP tests or mutation checks. WARP does not establish
hardware GPU behavior; production builds continue to reject software adapters.
The same run uses `RawLabWindows/tests/native/d3d11/check-mutations.ps1`
(tracked in the manual WARP script inventory) to check test sensitivity by removing
buffer reuse and idle trimming
in generated test-only source copies. Each mutation must fail at its corresponding
resource assertion; compile errors or unrelated test failures are rejected. The
normal backend is restored and the reuse test must pass again before the step ends.

### Automatic D3D11 build

An ordinary PR or `development` push that selects Windows also configures and builds
the standalone D3D11 test project, inside the existing Windows job, when changed files
can affect it: the project's own directory, the `lutools/src/core/`, `lutools/src/gpu/`,
`lutools/include/` and `lutools/third_party/nlohmann/` trees its CMake source list and
includes draw from, and `lutools/tests/d3d11_shader_tests.cpp`. This is a build gate
only, so that a compile or link break in the project is caught when it is introduced;
the WARP regressions and mutation checks still run only on the explicit `windows` +
`models` request above. If the changed-file diff is unavailable the build is included.
Directory guidance files, drafts, release/hotfix full gates and manual runs do not add it.

## Execution Procedure

1. Before commit, identify the affected behavior and run its local regressions.
   UI changes require the affected local UI tests to pass. Record source version,
   commands, results and unverified platforms in the PR; retain logs and screenshots
   in the task evidence directory outside tracked source.
2. For an ordinary PR or `development` push, let the automatic contracts and
   affected-platform models run. Do not add a full build, native suite or scheduled
   full run merely because a commit was pushed.
3. When a product build or specialized regression is needed, open **Actions →
   Hosted CI → Run workflow**, select the intended branch, then choose `platform`
   and `checks` from the tables above. Verify the resulting selection summary and
   checkout SHA before treating the run as evidence. `contracts` is shared and
   ignores the platform selector; use `all` + `full` for complete non-UI coverage.
4. Before release or hotfix acceptance, require the automatic full gate for the
   release/hotfix PR, plus the applicable local UI/device matrix. A requested
   `all` + `full` run may provide earlier validation, but does not replace required
   PR checks or grant release authorization.
5. Before merge, check the current source/base, required automatic result and any
   requested specialized results. A failed, cancelled or unfinished check is not a
   pass. A manual partial result does not satisfy the automatic aggregate gate.
   Fork model results also do not establish build/native coverage; see
   [External fork pull requests](#external-fork-pull-requests).
6. After a change, rerun only checks whose source, configuration or integration
   assumptions changed. Documentation-only updates require content, link and diff
   checks; preserve earlier native/UI evidence with its actual tested SHA and
   explain why it still applies, without labeling it as CI on the new head.

## Checks and Evidence

### Choosing and Maintaining Tests

A test earns its maintenance and execution cost by detecting a plausible regression
with a meaningful effect on users or delivery. Keep an independent expected result:
pixels or numerical tolerances, persisted data, observable state transitions, public
protocols, resource validity, and build/test failure propagation.

- Prefer the smallest test that exercises the real behavior. Keep native/UI coverage
  when the regression depends on rendering, framework behavior or user interaction.
- Remove exact duplicates and superseded migration checklists. A test for an old PR's
  list of renamed strings is not an enduring localization contract; generation,
  missing-key, placeholder and language-switching checks are.
- Do not freeze private function names, source snippets, call counts or control layout
  in text searches. Those assertions cannot establish that the behavior works and
  make harmless refactoring fail. Review wording and visual layout in their context.
- Static checks remain useful for declarative contracts such as workflow permissions,
  package metadata, asset hashes, schemas and resource completeness. Preserve those
  boundaries rather than reproducing every configuration value in a second file.
- Screenshot generators and benchmarks can support manual inspection and measurement.
  Without an asserted result or threshold, their successful execution is not a
  regression-test pass.
- Before removing a test, identify its failure mode and any retained coverage. A
  failing test, slow test or short test is not by itself a deletion candidate. Record
  pre-existing failures and unavailable native/device coverage separately.

### Execution Evidence

| Check | Runner | Model route / heavier route |
| --- | --- | --- |
| Select affected platforms | Ubuntu 24.04 | Selects platforms, groups, matrix and cold/warm mode |
| Contracts and CI policy | Ubuntu 24.04 | Static source/contracts, localization, LUT and MCP protocol checks |
| macOS | GitHub-hosted `macos-26` arm64 and `macos-26-intel` x86_64 | Models run once on arm64; a core change in an automatic models run adds the arm64 `ctest` row. `build` runs once per architecture. `native` uses arm64 all plus Intel core/agent/render shards; the cold `full` gate uses arm64 all plus one Intel job that builds once and runs core, agent and render |
| Windows | GitHub-hosted `windows-2022` for every group | Managed model projects and runner checks; separate automatic WPF batch-selection job / self-contained package, CTest, DCP and RAW/raster CLI parity |
| Android | GitHub-hosted `ubuntu-24.04` / JDK 17 | JVM unit tests / lint, debug/instrumentation + unsigned minified release APK builds, both native ABIs, DEX JNI class verification and alignment/cache checks |
| iOS | GitHub-hosted arm64 `xcode-27`, selected Xcode 27.1 | Standalone settings/viewing/persistence models / all framework slices, unsigned simulator app and UI-test compilation, simulator look-import integration |
| CI result | Ubuntu 24.04 | Automatic gate: every selected job succeeds and every unselected job is skipped; after a core change the macOS job must include the core CTest row and succeed |
| Manual verification (platform, group) | Ubuntu 24.04 | Checks the requested scope without presenting it as the automatic PR gate |

Desktop updater model checks include persisted failure/installation state, admission,
data backup/recovery and crash interruption. Windows also exercises the pinned SDK's
signed source and rejects untrusted packages without installing them. The vpk offline
package fixture and native update UI remain local checks; they do not replace signed
seed-to-release installation and recovery acceptance.

**CI result** must succeed on the current PR head/test merge for its automatic
scope, including the isolated Windows WPF subset when selected. An ordinary result
does not establish a complete product package build or the full native regression
run. Release/hotfix acceptance requires the full result. A missing,
cancelled or stale-head run is not a pass. After merge, inspect the exact
`development` push SHA. Record event, source head, checked-out SHA and base; a PR
can test GitHub's synthetic merge. A later source/base change invalidates the
previous integration result. This policy does not alter branch protection or
grant permission to bypass it.

When the user explicitly requests only a scoped follow-up after a push, `[skip ci]`
avoids the automatic PR run. Dispatch the chosen platform/group on that new head
and verify its logged checkout SHA. The automatic required check remains pending;
do not combine older platform successes into a new-head result or rename the
manual result to satisfy it.

## Platform Selection

[`affected_platforms.py`](../../scripts/ci/affected_platforms.py) owns selection.
Preview paths with `git diff --name-only origin/development... | python3 scripts/ci/affected_platforms.py classify`.

- Client directories select their own platform. `RawLabMac/Resources/` is packaged
  by every client; `RawLabMac/tests/DCPTestFixtures.swift` and the shared AX gate
  `RawLabMac/tests/ax-gate.sh` (sourced by the mixed iOS model suite) also select iOS.
- `docs/` except packaged licensing, `.impeccable/`, AGENTS/CLAUDE files
  and root README/CHANGELOG/DESIGN/PRODUCT/.gitignore select no platform.
- Shared core/resources, CI/tooling, licensing and unknown paths select all platforms.
- Core inputs additionally request the macOS core CTest row; see
  [Core CTest on ordinary runs](#core-ctest-on-ordinary-runs).

PRs compare the test merge against its base. Pushes compare with the last
successful `development` push run, so a cancelled run cannot conceal unverified
changes. Missing history selects all platforms at the event's level: ordinary
changes still run models; release/hotfix PRs run everything cold. Manual selection
is explicit and does not infer its scope from the branch diff. External forks use
the same affected selection on ephemeral hosted runners; they retain the ordinary
`models` group even when an external branch is named `release/*` or `hotfix/*`.

## External Fork Pull Requests

Ready-for-review fork PRs run contracts and all affected platform models on
GitHub-hosted runners, including macOS/iOS. Drafts retain the normal deferral.
External fork PRs restore base-branch caches read-only and never execute
`actions/cache/save` steps, so unprivileged PR runs do not occupy or evict the
repository's cache quota.
There are no self-hosted routes in this workflow. The selector and aggregate
still require every selected job to succeed; an Apple job skipped merely because
it came from a fork no longer satisfies the gate.

The workflow uses `pull_request`, not `pull_request_target`, read-only token
permissions, no secrets, and checkout with `persist-credentials: false`.
GitHub's fork approval policy remains applicable. Review workflow edits as
security-sensitive; do not route untrusted code to a persistent machine or add
signing/publication credentials to verification jobs.

### Verifying a Fork Pull Request Before Merge

Fork PRs, like ordinary internal PRs, do not automatically build products or run
the complete native gate. A maintainer should verify relevant build/native
changes on a reviewed same-repository ref using the explicit platform/group
selectors. `native` omits independent models; choose `full` when both are needed.
Confirm the logged checkout SHA and keep the manual result separate from
`CI result`. No dispatch, local build or green model result authorizes signing,
release publication or deployment.

## Local and Targeted Entry Points

Run affected UI tests locally before committing UI changes. Record source version,
commands, results and limits in the PR; keep logs/screenshots outside tracked source.
CI never repeats runtime UI checks. UI-test target compilation is not a UI-test pass.
When running the UI suites pre-release, carry `RAWLAB_REQUIRE_AX=1` so the accessibility-gated
scripts (`hdr-rendition-ui.sh`, `color-grading-input-ui.sh`, `system-menu-language.sh`) fail
with an explicit reason instead of returning 0 with a `SKIP` for checks that did not run. The
mixed suite `ios-reset-entry-ui.sh` is different: its 30 AX-free presentation/model assertions
always run (in CI and locally), and after they finish the suite's trailing gate check fails the
run (FAIL, no skip) when accessibility is missing with `RAWLAB_REQUIRE_AX=1`, or logs the
gate's honest skip pair otherwise.

- Apple fast models: `bash scripts/ci/apple-models.sh macos` or `ios`; no prebuilt
  C++ core or simulator is required.
  Multi-file Swift model runners use whole-module compilation to avoid repeated
  per-file work, retaining their existing optimization levels and assertions.
  Each invocation shares one temporary compiler-module cache between the adjustment
  transfer suites, then removes it on success or failure. Test executables and
  results are always rebuilt; no compiled product or test result is reused.
  The Mac and iOS zero-dependency model checks (chroma, wavelet, geometry, localization, lens
  localization, RUM configuration, error diagnostics, recent photos, adjustment persistence, HDR
  model, control groups, master recipe, and adjustment transfer/session/preset suites) run inside
  `RawLabKitTests` via `swift test`, needing only the Swift models/native bridge types and no native
  libraries.
  The `macos` models route runs `RawLabKitTests` in both Debug and Release
  (`swift test -c release -Xswiftc -enable-testing`) using separate scratch
  directories so release-configuration coverage is preserved without affecting
  the non-testable release prewarm linked by the remaining shell suites; it also
  runs `RawLabMac/tests/usage-termination.sh` and `RawLabMac/tests/text-fit.sh`.
- iOS Files/LUT UI: `IOS_SIMULATOR_UDID=<dedicated-device> bash RawLab/tests/document-import-ui.sh <build-for-testing-products> <new-output-directory>`.
  The runner stages generated PNG/CUBE fixtures in a test app copy and executes
  picker opening, selection, cancellation and reopening. Run on each required
  iPadOS runtime; `RAWLAB_DOCUMENT_IMPORT_TEST` selects a narrower XCTest case.
- iOS Recently Opened UI: `IOS_SIMULATOR_UDID=<dedicated-device> bash RawLab/tests/recent-photo-ui.sh <build-for-testing-products> <new-output-directory>`. Seed one photo with `simctl addmedia` first. The runner grants Photos access only on that simulator and verifies edit filters, reopening across process restart, reset and removal. It rejects skipped tests.
- Edited-preview cache and iOS recent-source retention checks run in the fast Apple model groups; `RawLabMac/tests/thumbnail-cache.sh` likewise runs in the standalone macOS model route. After building the native core, Mac rendered-preview/resource-watcher checks (`bash RawLabMac/tests/edited-photo-previews.sh`) and no-argument AI denoise model/recovery checks (`bash RawLabMac/tests/ai-denoise.sh`) run in the macOS `native`/`full` workflow (`in_suite model`); the argument form `bash RawLabMac/tests/ai-denoise.sh <MODEL_DIR> <RAW> <CACHE_DIR>` requires a real model package and RAW fixture and stays a local check, while `edited-photo-ui.sh <output-directory>` builds an isolated local native editor harness for marker, selection and reset inspection. `RawLabMac/tests/batch-cancellation.sh` delegates to `batch-render.sh` (requiring the prebuilt C++ core and native dependencies), `RawLab/tests/ios-photo-previews.sh` requires a booted iOS Simulator, and `RawLab/tests/raw-unpack-export.sh` and `RawLab/tests/subtool-menu-draft.sh` require both a built simulator `RawLab.app` and a booted iOS Simulator, so these four remain local/native-gate suites rather than `apple-models.sh` entries. Within that gate the iOS items split by drive mode: `ios-photo-previews.sh` (built-in harness app, headless `simctl spawn`, needs only a booted Simulator beyond the Xcode toolchain) and `raw-unpack-export.sh` (reuses the `RawLab.app` framework, headless `simctl spawn` with interpose counters, third argument is an absolute-path real RAW fixture) are latent-runnable without a GUI session or permission grant; `subtool-menu-draft.sh` launches the full `UIWindowScene` app through `simctl launch --console-pty`, so it stays a manual local UI gate: `bash RawLab/tests/subtool-menu-draft.sh <simulator RawLab.app> <booted simulator UDID>` and expect `VERIFIED: <N> checks passed` with exit 0.
- iOS `RawLab/tests/hdr-batch.sh` is not simulator-applicable (real device plus an HDR-capable
  environment required): the mixed HDR-JPEG collection assertions fail on the simulator even on a
  pristine `development` base with the same framework and harness, so a simulator failure is not
  a product delta and the suite stays a real-device HDR gate.
- Windows fast models: `./scripts/ci/windows-models.ps1` runs
  `dotnet test RawLabWindows/tests/RawLabWindows.Tests.csproj -c Release --list-tests`
  and `--filter Category=Model`; no WPF window, native rendering DLL, RAW fixture
  or self-contained app build is required.
- Android models: `./gradlew :app:testDebugUnitTest` plus
  `RawLabAndroid/tests/jni-session-lock.sh` and
  `ndk-compile.sh` (arm64 NDK CMake compile check for GLES/test targets without
  building full native dependencies or running on device); the task graph
  excludes full native compilation and APK assembly. Instrumentation remains a
  separate local entry.
- Mac UI checks remain independent scripts: `horizontal-picker-native.sh`,
  `parameter-value.sh`, `mac-straighten-preview.sh`, `mac-canvas-input.sh`.
  `presentation.sh --models-only` skips canvas UI but still needs the native core,
  so it belongs to the heavier group, not the standalone model route.
- Windows `RawLabWindows/tests/run-v08.ps1 -Only ...` selects individual local UI
  or native suites. Examples include `ui-details`, `transform-ui`, `editor-shell`,
  `editor-review`, `tool-groups`, `localization-ui`, `profile-isolation` and
  `comparison-default`. Its required test-host builds remain explicit.
- Windows `native` and `full` include the `rendered_dng` and
  `processing_migration_api` CTest results. For release acceptance, run the
  client DNG suite on Windows with the package built from the same source.

  ```powershell
  ./RawLabWindows/tests/run-v08.ps1 -Only rendered-dng -RawPath ./lutools/examples/DJI_20250602164503_0444_D.DNG -NativeArtifacts ./build/RawLab-Windows
  ```

  Record the `rendered-dng` entry in `build/windows-v08-results/summary.json`
  and the corresponding `rendered-dng.log` for the actual WPF batch export.
- iOS UI and Android connected-device tests run locally for affected work; the
  full applicable UI/device matrix belongs to release acceptance.

## Boundaries

- Default builds retain Adobe DNG SDK, Lensfun, chroma and wavelet denoise. No
  optional product feature is disabled to obtain a green check.
- Release-style builds (macOS `build.sh`, Windows `build.ps1`, Android
  `:app:assembleRelease`) download the pinned vendor RUM SDK from its versioned
  public URL and fail on a SHA-256 mismatch; the iOS job and Android Debug
  APK carry no SDK. Android `build`/`native`/`full` builds the unsigned
  R8-minified release APK alongside Debug/instrumentation APKs and checks
  Release DEX JNI classes (`RawLabAndroid/tests/check-rum-jni-classes.py`) and
  16 KB alignment (`zipalign` + `check-native.sh`). No job signs packages,
  launches a packaged app, executes emulator/device smoke, uses secrets or sends
  RUM traffic; running `RawLabAndroid/scripts/smoke-release-apk.sh` on the
  actual signed release APK remains a mandatory pre-publish gate.
- macOS explicitly excludes `native_dcp_metal`, `gpu_photo` and `metal_denoise`
  from the CI CTest invocation. Other tests may exercise an available GPU
  opportunistically; this is not a guaranteed physical GPU gate.
- The fast macOS CTest selects `dualdn_api` only in its no-package
  `dualdn_api_disabled` form, because `RAWLAB_DUALDN_TEST_PACKAGE` is unset
  there and the `RAWLAB_TEST_AI` Core ML assertions are compiled out. The
  arm64 `native` gate retains that check through
  `RawLabMac/tests/dualdn-api-package.sh`, which configures a dedicated
  AI-enabled build against the pinned ONNX Runtime and the validated DualDn
  package and runs the real `dualdn_api` test. In `full`, `ai-inputs.py` injects
  the package into `build.sh`, so its `build-macos` CTest runs the real-package
  tests. A missing model or runtime is a hard failure, not a skip; hosted routing
  does not provide a license or silently manufacture a model package.
- Windows does not invoke `build.ps1 -Test`: that entry point's default suite
  requires physical D3D11 and an external RAW path. The hosted suite uses the
  already-public tracked DJI DNG and explicitly selected CPU-safe cases.
  Windows `native/full` includes `raw_active_area_metadata` in that selection.
  It also selects `raw_active_area_sony` when an existing external photo is
  configured through `SONY2FUJI_TEST_SONY_ASPECT_RAW`; the private Sony fixture
  is not provided by CI by default.
- The iOS job compiles UI tests with `build-for-testing`; it does **not** execute
  XCTest, import Photos fixtures, sign a device app or validate installation.
- UI tests are not a CI gate. Hosted macOS has no project accessibility
  grant, so `hdr-rendition-ui.sh` (`AXUIElement`) runs locally and pre-release
  instead of in the model suites; `RAWLAB_REQUIRE_AX=1` turns its skip into a
  failure. The same contract stays gated by the AX-free presentation-layer suite
  `hdr-rendition-reset.sh`. Host-executed suites with "UI" in the name, such as
  `ios-reset-entry-ui.sh`, are presentation-layer model assertions, not XCUITest.
  A `SKIP` reason in a CI suite log counts as a failed gate, never as a pass;
  the gate matches a line-leading `SKIP` marker, so paths, identifiers and
  `PASS:` wording that merely contain "SKIP" stay green. The one exception: in a
  mixed AX model suite registered in `scripts/ci/apple-models.sh` (currently
  `ios-reset-entry-ui.sh`) the model checks run unconditionally and the suite's
  second-layer AX guard may pass through the gate's fixed `SKIP: accessibility ...`
  line only when its `::warning::` annotation is logged alongside it; every other
  `SKIP` stays red, and `RAWLAB_REQUIRE_AX=1` keeps the guard on its FAIL exit with
  no skip at all. This is distinct from
  CTest `SKIP_RETURN_CODE 77`, which registers an explicit visible skip for
  optional external models or private samples (such as `dualdn_skip` and
  `dualdn_onnx_skip`); the `full` gate still hard-fails a missing AI model
  earlier through `scripts/ci/ai-inputs.py`.
- Android compiles instrumentation tests but does **not** run connected-device
  tests. GLES, SAF, OEM locale and physical interaction evidence stays separate.
- Building both architectures with a 14.0 minimum on a newer macOS does not establish
  runtime support on macOS 14; native acceptance on the minimum OS is separate.
  [Runner labels](https://github.com/actions/runner-images/blob/main/README.md)
  and toolchains can change; logs identify the actual environment.
- Mac dependencies include source-built dynamic GLib/Lensfun rather than a
  higher-minimum Homebrew bottle. App/bundled-dylib architecture and minimum OS
  are checked by the existing bundle gate. The 14.0-target picker model checks
  run in the arm64 model route; native picker UI checks run locally.

## Safety and Results

Actions are pinned to full commit SHAs. Workflow permission is `contents: read`;
only the selection job adds `actions: read` to look up earlier runs. Checkout
credentials are not persisted, and no `pull_request_target` is used. Workflow
edits in a fork PR require security review
([External fork pull requests](#external-fork-pull-requests)).
The workflow has bounded jobs and cancels obsolete runs for the same PR/ref;
manual runs include `inputs.platform` and `inputs.checks` in their concurrency
group so concurrent manual runs for different targets/suites on the same branch
do not cancel one another or automatic PR/push checks. Pull request `edited`
events re-evaluate checks only when `base` changes; title/body edits use an
isolated `-noop` concurrency group and do not cancel active checks.

A title/body edit still creates a `pull_request` run on the same head. GitHub was
observed (#691, #698) to read the required **CI result** from the newest such run,
so an edit run without that check blocks a PR whose head already passed. An edit
run therefore selects no checks. Its selection job (named *Reuse the CI result of
this head*) finds the newest earlier automatic run for this PR and head, polling
once a minute for up to 170 minutes, and the edit run's **CI result** passes only
if that run's result passed. Earlier edit runs are passed over, and so is a run
cancelled before it started a job (normally an edit run superseded by the next
edit). Every other outcome fails closed instead of falling back to an older run:
a failed, cancelled, missing, unfinished or timed-out result, and a run that never
started for another reason, such as one awaiting fork approval (`action_required`)
or a `startup_failure`. So an edit cannot turn an unverified head green, including
one whose base changed. Edits on drafts stay skipped. A newer push or base change
supersedes the edit run.

Because the newest run decides, re-running the automatic run does not clear a
failed edit run's **CI result**: once the automatic result has passed, edit the
title or body again (the new edit run reuses it) or push a new commit.

The separate [PR cache cleanup](../../.github/workflows/pr-cache-cleanup.yml)
workflow runs when a same-repository PR closes (external fork PRs never save
caches, so no `pull_request_target` cleanup is needed). With `actions: write` and no
checkout, it deletes only the caches stored under that PR's merge ref, which no
other PR or branch can use.

## Hosted Android Runner

All Android groups run on GitHub-hosted `ubuntu-24.04` with Temurin JDK 17,
Python 3.12, and Gradle capped at `--max-workers=2`. Build jobs install the
pinned Android SDK/NDK/CMake components (`platforms;android-35`,
`build-tools;35.0.0`, `ndk;27.2.12479018`, `cmake;3.22.1`) via `sdkmanager`,
build both arm64 and x86_64 ABIs, fetch the SHA-256-pinned public RUM AAR,
run `lintDebug`, compile the Debug, instrumentation, and unsigned R8-minified
Release APKs, and verify Release DEX JNI class preservation
(`check-rum-jni-classes.py`) plus 16 KB alignment without signing or running
connected-device, emulator cold-start smoke, or GLES tests. Pre-release acceptance
still requires running `RawLabAndroid/scripts/smoke-release-apk.sh` against the
actual signed release APK.

## Windows Runner Scheduling

All Windows groups, including release/hotfix cold builds and manual
`build/native/full`, select GitHub-hosted `windows-2022`. Forks use
the same affected model route with read-only permissions. Drafts still defer
platform jobs; hosted concurrency limits still apply.

The selected group, not the host, determines coverage. Model runs do not build
the app or native core; build/native/full retain the complete self-contained
product build and their requested non-UI suites. Manual results stay separate
from `CI result`; Windows Server execution does not establish physical GPU or
interactive Windows 11 desktop acceptance.

For ordinary automatic PR/push events selecting Windows, **Windows batch-selection**
runs independently on `windows-2022`, alongside the unchanged models job. It builds
the current checkout's `sony2fuji` target and its `raw.dll` dependency, retaining the
production rendering features while omitting native test executables and CLI builds.
`run-v08.ps1 -Only 'batch-selection'` compiles the unified xUnit test project
`RawLabWindows.Tests.csproj` (referencing `RawLab.Windows.Core` and the WPF app),
resolves its real `TargetDir`, and copies the native DLLs, MSVC CRT/OpenMP and
complete pinned ExifTool 13.59 distribution there. The suite uses the tracked DJI
DNG, CPU editing and ordinary Auto export with CPU fallback; it does not require
AI models or a physical GPU. Only the `Suite=batch-selection` xUnit test executes:
the default/legacy suite and all other UI subsets stay outside this automatic job. Native products are rebuilt
from source on every run; only checksum-verified source archives are shared by cache.
The aggregate result requires this job to succeed when selected, so a skipped,
failed or cancelled suite cannot produce a green automatic gate. Its v08 logs and
summary are retained in `windows-batch-selection-results` for seven days. Manual
groups and release/hotfix full gates retain their existing scope. This narrow WPF
exception does not replace local UI, physical DPI, Narrator, Snap or hardware checks.

The Windows setup step configures download and tool caches under
`RUNNER_TEMP\rawlab-ci`, with four CMake workers and a four-process
cross-project MSVC cap (`CL_MPCount`) for the standard four-core, 16 GiB
hosted runner. The native dependency key includes workspace, host, image
and compiler identities, and product outputs and test results are always
rebuilt.

### Core CTest on ordinary runs

The `models` group never builds the core, so an automatic models run (PR or `development`
push) whose changes touch core inputs adds one `macOS models (arm64, ctest)` row to the macOS
job. Core inputs are every `lutools/` path except documentation and the iOS framework glue
under `lutools/platform/ios/`, plus what the core tests read or run outside `lutools/`
(`Shared/BundledLooks/`, `Shared/assets-manifest.json`, `scripts/assets/prepare.py`, the
CTest drivers and requirements under `scripts/ci/`), the row's Rust and dependency-cache
helpers, and the scripts `RawLabMac/build.sh` runs up to the core build.
`affected_platforms.py` owns the list. An unavailable diff runs the row. Drafts,
release/hotfix `full` gates (which already run native CTest on both architectures) and manual
groups never add it.

The row reuses the macOS job: it restores the arm64 dependency cache, builds the core and its
tests with `RAWLAB_CORE_ONLY=1 RawLabMac/build.sh` (no app, Sparkle or usage SDK; refused
together with `RAWLAB_RELEASE=1`), checks the CTest inventory and runs the complete
`ci_macos_arm64` label set with the same command as the native `core` group; no test is
filtered. **CI result** fails when core inputs changed and the row is missing,
failed, cancelled or skipped. Intel CTest stays in the native and full gates.

A successful row saves the shared arm64 dependency key, so a core change pushed to
`development` warms it for later PRs. The row occupies one hosted macOS runner for roughly
half as long as a native macOS job, plus any queueing for a macOS slot.

## GitHub-Hosted Apple Runners

The active macOS matrix uses `macos-26` arm64 (two build workers) and the existing
`macos-26-intel` x86_64 shards (four). iOS uses the official `xcode-27` arm64
preview image, explicitly selecting `/Applications/Xcode_27.1.app/Contents/Developer`.
The stable `macos-26` image carries Xcode 26, which cannot satisfy the retained
iOS SDK 27.1+ guard. Both Apple jobs select Python 3.12 through `setup-python` and
prepare Homebrew build tools instead of assuming a provisioned local venv.
The iOS SDK guard still runs before Rust/native work, all framework slices are
built, and simulator app/test compilation remains unsigned.

Official [labels](https://github.com/actions/runner-images/blob/main/README.md),
[runner resources](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
and [Xcode 27 image](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)
currently document three-core/7 GB arm64 VMs, four-core/14 GB Intel VMs and Xcode
27.1 default plus 27.2 installed on `xcode-27`. The preview label is deliberate,
not a claim of GA availability. Logs and the SDK guard determine the actual
image/toolchain. No larger paid runner, signing identity or persistent Mac is
required by this route. Hosted VMs do not establish physical Metal/Core ML or
iPhone acceptance; retained hardware-dependent tests may fail without a device,
and that is not permission to skip them or claim a hardware pass.

The arm64 `all` coverage, Intel suite coverage, cache cold/warm rules and bounded
CTest parallelism stay unchanged. Moving hosts does not authorize model uploads;
see the model prerequisites above.

The macOS, iOS and Android build jobs use `scripts/ci/prepare-rust.sh` to select
Rust 1.99.1, its standard-library notices and the required target slices. If
`rustup` is absent from the job PATH, the helper verifies the official installer
checksum and installs it under `RUNNER_TEMP/rawlab-x3f-tools`, exporting the job's
Cargo/Rustup paths. It does not require an administrator or change the runner's
login profile. Windows prepares the same pinned toolchain in its own job directory.

For `native`, the Intel `agent` shard isolates Agent recipe rendering from the remaining
`render` checks; each shard restores the warm dependency cache, builds the app and
executes its assigned suites. The cold `full` gate cannot restore that cache, so separate
shards would each rebuild every dependency, lutools and the app (33–44 minutes apiece);
instead its single Intel `intel` job builds once and runs `core`, `agent` and `render` in
turn, reusing one SwiftPM scratch directory. arm64 `all` executes every group once. Only
Intel `core` (native) or `intel` (full) saves the shared dependency key, while the arm64
job saves its own key. The build-only Intel row also saves its key. Each additional shard
uses another hosted macOS execution slot, so concurrent PRs may still queue at the
account's macOS concurrency limit.

Both Mac architectures (the Intel `core` shard) run the existing CPU-safe CTest selection with at most
two test processes. This limit is separate from build parallelism because RAW
rendering tests may also use internal worker threads. Each architecture's `core`/`all`
native group also runs HDR display packing and native bridge regressions, including
Intel's portable FP16 conversion. The default Swift app uses whole-module optimization with compiler threads bounded by `JOBS`; it retains
`-O` and all sources. The full-source straighten UI harness runs locally. No app or test executable is cached. Each Mac regression
stage records elapsed seconds and its exit code in `build/ci/macos-timings.log`; command failures
still fail the job rather than being hidden by the timing wrapper.

## Native Dependency Caches

Model-only checks do not configure or restore native caches; the macOS core CTest row and the
Windows D3D11 test project build (which needs no dependency cache) are the only native steps of a
models run. Explicit warm build
and native groups use an exact dependency key. **Cold builds never restore native
caches**: manual full runs and release/hotfix PRs build dependencies from source. They
look up the exact key without downloading its contents and skip saving when that
accessible cache already exists. Any miss builds from source and saves only after
the full job succeeds; on Intel only the `core` shard (native) or the single `intel` job (full) saves the shared key.
Cache lookup/restore failures leave builds enabled and suppress the cache save.
A cache miss or cache-service outage is not permission to skip a build. Keys hash
every dependency input and toolchain. Cold release/hotfix and explicit full runs
prove the selected source builds without restored native outputs.

This deliberately uses separate restore/save actions. GitHub makes base/default
branch caches available to PRs, while a cache created under a PR merge ref cannot
seed unrelated PRs. See the [GitHub cache scope reference](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching#restrictions-for-accessing-a-cache).

[`native_cache.py`](../../scripts/ci/native_cache.py) owns the input/path allowlists.
Keys include pinned dependency versions/checksums, patches and build scripts,
the complete consuming workflow job and shared defaults, compiler and SDK
identity, runner image, target
architectures/minimum OS, and the absolute workspace/toolchain paths. This last
constraint matters for pkg-config prefixes, Lensfun's `libraries.json` and
CMake/Xcode/MSBuild state. There are no prefix/fallback restore keys.
Changing an unrelated platform's job no longer invalidates every native cache.
Mac matrix identity includes only the selected architecture row. Shared job
steps, build environment/defaults and cache-helper changes still invalidate their
consumers. Mac tool identity includes the relevant Homebrew build tools and m4,
not unrelated installed applications; CMake, Python, Xcode and SDK identities
remain explicit. This reduces false misses without caching product outputs or
weakening the cold release/full gate.

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
does not demonstrate a speedup. Hosted Intel uses four build workers and two CTest processes; hosted Android
and Windows jobs use the bounded worker settings documented above.

### Download Caches and iOS Slices

Separately from the exact native caches, every native build job keeps two download-only
caches: the Cargo registry/git database for the pinned X3F crates (keyed by job and
`lutools/x3f-bridge/Cargo.lock`, in the `CARGO_HOME` that `prepare-rust.sh` or the Windows
Rust step exports, since each job fetches only its own targets' crates), and the dependency
source archives (`RAWLAB_SOURCE_ARCHIVE_CACHE`, the Mac `.cache/shared/macos-sources`, which
also holds the Mac Lensfun/GLib downloads, and the iOS `build-ios-libraw/*/sources/*.tar.gz`),
keyed by the files that pin them. `rawlab_download_archive` locks each archive, so parallel
configures sharing the directory wait for one verified download instead of truncating each
other's partial file. Windows keeps its
existing `native_cache.py archives` key. These caches hold only downloads that are still
checked against their pinned SHA-256 (or `Cargo.lock`) before use, so unlike native caches
they do use prefix restore keys, and cold gates restore them: a cold build still compiles
every dependency from source, it just does not depend on crates.io, GitHub or Adobe being
reachable. They are saved under the same fork-PR rule as every other cache.

The iOS job builds the three framework slices concurrently
(`RAWLAB_IOS_PARALLEL_SLICES=1` in `lutools/platform/ios/build-framework.sh`); each slice
keeps its own build tree, Cargo target directory and `-j "$JOBS"`, the logs are replayed per
slice after all finish, and any failed slice fails the step by name. CMake's Xcode configure
is dominated by serial `try_compile` latency (about eight minutes per slice in the
2026-11-25 cold run), which the slices now overlap. Local scripts keep the serial default.

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

Verification logs and metadata under `build/ci/` are retained for seven days.
The allowlist includes top-level `*.log`, `*.json` and `*.xml`, plus the explicit
Windows model/process/runner subdirectories and runner `*.jsonl` call traces.
Mac artifacts are named `macos-<arch>-<suite>-results`.
Do not widen this allowlist to photos, RAW inputs, screenshots, user profiles,
app bundles, native binaries, APKs or entire build directories. Build packages
are ephemeral verification outputs, not versioned release candidates.

Local workflow-policy regression tests (PowerShell, when available, also executes
both Windows environment branches without installing tools or writing to `E:`):

```sh
python3 -m venv /tmp/rawlab-ci-venv
/tmp/rawlab-ci-venv/bin/pip install -r scripts/ci/requirements.txt
/tmp/rawlab-ci-venv/bin/python -m unittest discover -s scripts/ci -p 'test_*.py' -v
```

These guards supplement, not replace, workflow syntax linting and actual hosted
execution. Platform jobs stop on command/test failures; they are not allowed to
silently skip a required suite or mark a failing native process successful.

### Apple Shell Harness Ownership

Pure-Swift shared model tests reside in `tests/RawLabKitTests/` (`Package.swift`)
and run automatically via `swift test` (invoked by `scripts/ci/apple-models.sh`
and `.github/workflows/ci.yml`). Remaining `.sh` scripts under `Shared/tests/`,
`RawLab/tests/`, and `RawLabMac/tests/` that are not already invoked by
`apple-models.sh`, `ci.yml`, or `RawLabMac/build.sh` are explicitly owned as
local/pre-release integration harnesses:

- **Shared SwiftPM & source-list helpers** (sourced by Apple test harnesses; guarded by `scripts/ci/test_mac_native_sources.py` and `scripts/ci/test_apple_shell_ownership.py`):
  `Shared/tests/hdr-native-sources.sh`, `Shared/tests/mac-native-sources.sh`,
  `RawLabMac/tests/native-env.sh`, `RawLabMac/tests/core-link.sh`,
  `RawLabMac/tests/sparkle-bundle.sh`.
- **iOS core/native/simulator/UI harnesses** (owned by iOS build/simulator gates in `RawLab/AGENTS.md` and release acceptance):
  `RawLab/tests/adjustment-history-model.sh`, `RawLab/tests/adjustment-ruler-enabled.sh`,
  `RawLab/tests/batch-publication.sh`,
  `RawLab/tests/bundled-look-artwork.sh`, `RawLab/tests/bundled-luts.sh`,
  `RawLab/tests/camera-import-fault-tolerance.sh`,
  `RawLab/tests/camera-skip-and-limit.sh`,
  `RawLab/tests/geometry-processing.sh`,
  `RawLab/tests/hdr-history.sh`, `RawLab/tests/hdr-missing-resources.sh`,
  `RawLab/tests/hdr-processing.sh`,
  `RawLab/tests/hdr-sdr-preview.sh`,
  `RawLab/tests/import-state.sh`, `RawLab/tests/lens-dng-export.sh`,
  `RawLab/tests/native-value-wheel-layout.sh`,
  `RawLab/tests/photo-entry.sh`,
  `RawLab/tests/preview-performance.sh`, `RawLab/tests/processor-export.sh`,
  `RawLab/tests/raster-export.sh`, `RawLab/tests/raw-import-history.sh`,
  `RawLab/tests/seed-sim-ui-fixtures.sh`, `RawLab/tests/viewing-canvas.sh`,
  `RawLab/tests/viewing-render.sh`, `RawLab/tests/viewport-state.sh`.
- **Mac native/AppKit/UI/Sparkle harnesses** (owned by Mac local native/UI/release acceptance in `RawLabMac/README.md` and `docs/process/desktop-release.md`):
  `RawLabMac/tests/agent-sdr-fallback.sh`, `RawLabMac/tests/atmosphere-render.sh`,
  `RawLabMac/tests/batch-import-presentation.sh`,
  `RawLabMac/tests/batch-render.sh`, `RawLabMac/tests/chroma-render.sh`,
  `RawLabMac/tests/compact-controls-presentation.sh`, `RawLabMac/tests/denoise-model.sh`,
  `RawLabMac/tests/edit-memory.sh`,
  `RawLabMac/tests/file-browser.sh`, `RawLabMac/tests/folder-drop.sh`,
  `RawLabMac/tests/fuji-compatibility.sh`, `RawLabMac/tests/geometry-render.sh`,
  `RawLabMac/tests/geometry-viewport.sh`, `RawLabMac/tests/hdr-agent.sh`,
  `RawLabMac/tests/hdr-batch.sh`, `RawLabMac/tests/hdr-history.sh`,
  `RawLabMac/tests/hdr-sdr-preview.sh`, `RawLabMac/tests/horizontal-picker-native.sh`,
  `RawLabMac/tests/hsl-target-render.sh`, `RawLabMac/tests/lens-render.sh`,
  `RawLabMac/tests/lens-settings.sh`, `RawLabMac/tests/lut-preview.sh`,
  `RawLabMac/tests/mac-canvas-input.sh`, `RawLabMac/tests/mac-crop-presentation.sh`,
  `RawLabMac/tests/mac-lens-draft-controls.sh`, `RawLabMac/tests/mac-lens-draft-presentation.sh`,
  `RawLabMac/tests/mac-menu-commands.sh`, `RawLabMac/tests/mac-perspective-integration.sh`,
  `RawLabMac/tests/mac-straighten-preview.sh`, `RawLabMac/tests/mac-ui-smoke.sh`,
  `RawLabMac/tests/mac-viewing-model.sh`,
  `RawLabMac/tests/master-recipe-render.sh`, `RawLabMac/tests/parameter-value.sh`,
  `RawLabMac/tests/processing-migration-input.sh`, `RawLabMac/tests/proraw-stream.sh`,
  `RawLabMac/tests/rendered-dng.sh`,
  `RawLabMac/tests/sparkle-signature.sh`,
  `RawLabMac/tests/tone-curve-input.sh`,
  `RawLabMac/tests/tone-curve-render.sh`, `RawLabMac/tests/update-ui.sh`,
  `RawLabMac/tests/wavelet-render.sh`, `RawLabMac/tests/x3f-workflow.sh`.

The [archived 0.8 preparation ledger](../archive/releases/v0.8/preparation.md)
retains its original candidate scope. Use [release notes](../releases/v0.8/v0.8.1.md)
and package provenance for delivered artifacts; historical local/device reports
retain their original source and device scope.
