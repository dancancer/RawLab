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
[desktop release packaging](desktop-release.md). No signing keys are used in CI.
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
| Ordinary PR / `development` push | Static contracts plus fast models for affected platforms; no product/native dependency build |
| Draft PR | Contracts only; platform checks and aggregate result stay skipped |
| External fork PR | Contracts plus hosted Android and Windows checks when selected; the self-hosted macOS and iOS jobs stay skipped (see [External fork pull requests](#external-fork-pull-requests)) |
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
   For an external fork PR, the skipped platforms and the build/native coverage
   that fork runs never trigger also require the maintainer verification in
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
| macOS | Dedicated arm64 Mac; hosted Intel for heavier groups | Models run once on arm64. `build` runs once per architecture. `native/full` use arm64 all plus Intel core/agent/render shards |
| Windows | Hosted Server 2022 for models; dedicated Windows 11 for explicit builds and cold gates | Seven managed model projects and runner checks / self-contained package, CTest, DCP and RAW/raster CLI parity |
| Android | Hosted Ubuntu 24.04 / JDK 17 (dedicated guest paused) | JVM unit tests / lint, app and instrumentation APK builds, both native ABIs and alignment/cache checks |
| iOS | Apple Silicon / Xcode | Standalone settings/viewing/persistence models / all framework slices, unsigned simulator app and UI-test compilation, simulator look-import integration |
| CI result | Ubuntu 24.04 | Automatic gate: every selected job succeeds and every unselected job is skipped |
| Manual verification (platform, group) | Ubuntu 24.04 | Checks the requested scope without presenting it as the automatic PR gate |

Desktop updater model checks include persisted failure/installation state, admission,
data backup/recovery and crash interruption. Windows also exercises the pinned SDK's
signed source and rejects untrusted packages without installing them. The vpk offline
package fixture and native update UI remain local checks; they do not replace signed
seed-to-release installation and recovery acceptance.

**CI result** must succeed on the current PR head/test merge for its automatic
scope. An ordinary model-only result is not evidence of a product build or native
regression run. Release/hotfix acceptance requires the full result. A missing,
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
  by every client; `RawLabMac/tests/DCPTestFixtures.swift` also selects iOS.
- `docs/` except packaged licensing, `reviews/`, `.impeccable/`, AGENTS/CLAUDE files
  and root README/CHANGELOG/DESIGN/PRODUCT/.gitignore select no platform.
- Shared core/resources, CI/tooling, licensing and unknown paths select all platforms.

PRs compare the test merge against its base. Pushes compare with the last
successful `development` push run, so a cancelled run cannot conceal unverified
changes. Missing history selects all platforms at the event's level: ordinary
changes still run models; release/hotfix PRs run everything cold. Manual selection
is explicit and does not infer its scope from the branch diff. An external fork PR
additionally removes the self-hosted-only platforms from the selected set; see
[External fork pull requests](#external-fork-pull-requests).

## External Fork Pull Requests

External fork pull requests are accepted, and their normal automatic run
schedules only GitHub-hosted checks. GitHub runs the workflow in the base
repository but takes the workflow file from the pull request's merge commit; the
`macos` and `ios` jobs in that file each require
`github.event.pull_request.head.repo.full_name == github.repository`
([workflow](../../.github/workflows/ci.yml)), so a fork PR that leaves the
workflow unchanged skips both. The `windows` job carries the same
head-repository clause with one escape: it also runs when the selected route is
`windows-2022`, so a fork diff's model checks run on the hosted runner
while the trusted machines stay reserved for same-repository code. The gate
keeps normal fork changes off the trusted machines that persist SDKs, caches
and runner installations. The selector
also removes the platforms that exist only as self-hosted runners before the
result gate sees the run: `SELF_HOSTED_ONLY = {"macos", "ios"}` in
[`affected_platforms.py`](../../scripts/ci/affected_platforms.py). An external
branch is never treated as a release/hotfix cold build, so its check group stays
`models` even when it targets `main` or `release/**`. The automatic coverage of a
ready-for-review fork PR is therefore:

- **Contracts and CI policy** always run on `ubuntu-24.04`.
- **Android** runs on hosted `ubuntu-24.04` when the diff selects it.
- **macOS and iOS** are not selected, and their jobs are skipped by the source
  gate. `verify` requires a selected platform to succeed and an unselected one to
  be `skipped`, so these two skips are accepted; the selection reason records
  them (for example, `fork pull request: ios, macos stay off self-hosted
  runners`).
- **Windows** stays selected because its ordinary route is hosted:
  `windows_runner` returns `windows-2022`, and the job's source gate admits that
  route, so the fork diff compiles and runs its model checks on `windows-2022`
  exactly like an internal PR. Self-hosted Windows routing (cold builds and
  manual `build`/`native`/`full`) stays same-repository only, so fork code never
  executes on the dedicated KVM guest.

A fork PR whose diff selects only the removed macOS/iOS platforms leaves no
platform selected: contracts run, every platform job is skipped, and the green
result means those platforms were not tested. A draft fork PR keeps the normal
draft behavior: platform checks wait for **Ready for review**, and the coverage
above applies to the ready-for-review run.

Because the workflow file comes from the merge commit, a fork PR that edits
`.github/workflows/` can run its edited version. GitHub's fork approval policy,
read-only token and withheld secrets reduce that risk; they do not make a
self-hosted runner safe. Review workflow edits in a fork PR as security-sensitive,
and never approve or merge one that removes or weakens a `head.repo.full_name`
condition or routes fork code to a self-hosted runner. Contributors must not try
to bypass the gate by editing the workflow on their fork either; the supported
path is review followed by the trusted-ref verification below.

### Verifying a Fork Pull Request Before Merge

The automatic run leaves two kinds of gaps: fork PRs never select the
self-hosted-only platforms (`macos`, `ios`), and they always lock `checks` to
`models`, so build and native regressions stay unrun wherever the diff touches
platform or native code — including `android`, whose hosted `models` run did
pass. After reviewing the change, a maintainer with write access fills the gaps
relevant to the diff on a trusted ref. Bring the
reviewed head into a branch in this repository (a fork branch cannot be selected
by **Run workflow**) or check it out locally and use the
[local entry points](#local-and-targeted-entry-points) for the platform-specific
scripts. For a **Run workflow** dispatch, open **Actions → Hosted CI → Run
workflow** on that branch:

- Set `platform` to `macos`, `windows`, `android` or `ios`; use `all` when the
  whole matrix is needed. `contracts` ignores this selector.
- Set `checks` to `models` at minimum for the platforms the fork selection
  skipped (`macos`, `ios`), and to `build`, `native` or `full` on every platform
  whose build or native code the diff touches, per the
  [Verification Levels](#verification-levels) groups.
  `native` omits the independent model suites, so use `full` when both are
  required.
- Confirm the logged checkout SHA is the reviewed source you intend to verify,
  record the manual result and any local UI/device evidence in the PR, and treat
  a missing, cancelled or stale-head run as unverified. The manual run's
  aggregate check is named `Manual verification (<platform>, <checks>)` and does
  not replace `CI result`.

For a shared-core change, at minimum run `models` for each skipped platform and
add `build`, `native` or `full` only for the coverage the change requires.

`workflow_dispatch` runs the workflow file from the selected branch and is not
subject to the pull-request source gate. Before dispatching, confirm the branch's
workflow files contain only the changes you reviewed and do not weaken the gate;
otherwise the dispatch would execute unreviewed workflow code on self-hosted
machines. Do not bypass the gate for a fork: do not remove a
`head.repo.full_name` condition or copy unreviewed fork code into a
same-repository branch to obtain a privileged run; `pull_request_target` remains
forbidden ([Safety and Results](#safety-and-results)).

### JIT Dispatcher for Self-Hosted Jobs (Opt-In, Not Enabled)

[`scripts/ci/jit_dispatch.py`](../../scripts/ci/jit_dispatch.py) is the opt-in WP-01
replacement for the resident `Runner.Listener` on the Apple pool Macs. While it stays
disabled — the current state — the resident listener serves every run exactly as before;
enabling it is a host-side change, not a workflow change, and no CI file loads it.

The dispatcher polls `GET /repos/<repo>/actions/runs` for `queued` and `in_progress`
runs and judges each run only by GitHub's server-side fields, which fork workflow YAML
cannot forge: the run `event`, `head_repository.full_name`, and the queued jobs'
`labels` (a job is only claimable when its label set is one this machine actually
registers). A run may reach the physical machine only when it is a `push` on this
repository or an operator admitted it through the `RAWLAB_JIT_ALLOWLIST` environment
variable (comma-separated run ids, head repositories, or `head-repo:branch`). Claimed
runs get a `POST .../runners/generate-jitconfig` registration (`name` +
`runner_group_id` + `labels`; a 2026-11-14 live probe against API version 2022-11-28
pinned the contract: omitting the group answers 422, the response field is
`encoded_jit_config`, and JIT runners are single-use by design — one job, then
deregister). The POST creates the runner registration immediately, so a launch that
never starts leaves an offline runner behind to delete under Settings → runners. Fork
and non-conforming runs are never claimed: they wait in the queue and expire. One
caveat is stated, not hidden — the JIT service hands a started runner the oldest
queued job carrying the label (FIFO), so an *already approved* fork job can still be
picked up by a runner dispatched for a trusted run; the review gate stays the fork
approval policy above, while the dispatcher removes the standing listener that would
execute unreviewed queue contents unconditionally.

- **Enable (host-side, one Mac at a time)**: unpack the pinned `actions/runner`
  archive into a **pristine** directory (`mkdir -p ~/jit-runner && tar -xzf
  <runner-archive> -C ~/jit-runner`; never reuse the resident runner directory, whose
  `.runner`/`.credentials` a JIT run would overwrite and deregister) and symlink its
  `_work` to the pool volume; stop the resident runner's user agent (`./svc.sh stop`
  in the runner directory, or its `launchctl bootout gui/$(id -u)/<runner-agent>`);
  preview one queue pass with `RAWLAB_JIT_TOKEN=<PAT> python3
  scripts/ci/jit_dispatch.py --once --dry-run` (plain `--once` decides *and dispatches
  one job*); then copy
  [`scripts/ci/launchd/com.rawlab.jit-dispatcher.plist`](../../scripts/ci/launchd/com.rawlab.jit-dispatcher.plist)
  to `~/Library/LaunchAgents/`, adjust the paths and the token placeholder (keep the
  file `0600`), and load it with `launchctl bootstrap gui/$(id -u)
  ~/Library/LaunchAgents/com.rawlab.jit-dispatcher.plist`. The token needs repository
  `Administration` (write) for `generate-jitconfig` plus `Actions` (read) for the
  queue poll on fine-grained PATs — `Actions: write` alone answers 403 on the dispatch
  POST — or the classic `repo` scope. Same-repository `pull_request` and
  `workflow_dispatch` (manual *Run workflow*) jobs are not push events, so add the run
  id — or the repository name for a transitional window — to `RAWLAB_JIT_ALLOWLIST` if
  this machine must keep serving them.
- **Disable**: `launchctl bootout gui/$(id -u)/com.rawlab.jit-dispatcher`, remove the
  copied plist, and restart the resident `Runner.Listener` agent; the pristine
  `~/jit-runner` directory can stay for the next activation. Queued jobs resume being
  served unchanged because no workflow file changed while the dispatcher was on.
- **Attack-verification PR (one-time, after enabling)**: open a pull request from a
  throwaway fork whose diff edits `.github/workflows/ci.yml` to drop one self-hosted
  job's `head.repo.full_name` clause (or route it to `[self-hosted, macOS, ARM64,
  rawlab-apple]`), and confirm all four observations: the dispatcher logs the run as
  `skip (untrusted …)`; no JIT token is generated for it while the allowlist stays
  empty, so with the resident listener stopped the job only queues; after allowlisting
  the run id and re-running `--once`, one ephemeral runner claims it and deregisters;
  without the allowlist entry the job expires in the queue instead of executing on the
  machine.
- **Retirement for hosted runners (deprecation path)**: the dispatcher keeps no state
  outside this repository — decisions are in memory and the queue is GitHub's. When the
  self-hosted jobs move to hosted runners, bootout the LaunchAgent, drop the host-side
  leftovers (the copied plist and the pristine `~/jit-runner` directory), and delete
  `scripts/ci/jit_dispatch.py`, `scripts/ci/test_jit_dispatch.py`,
  `scripts/ci/launchd/com.rawlab.jit-dispatcher.plist` and this subsection; nothing
  else references them, so the repository is back at zero.

## Local and Targeted Entry Points

Run affected UI tests locally before committing UI changes. Record source version,
commands, results and limits in the PR; keep logs/screenshots outside tracked source.
CI never repeats runtime UI checks. UI-test target compilation is not a UI-test pass.

- Apple fast models: `bash scripts/ci/apple-models.sh macos` or `ios`; no prebuilt
  C++ core or simulator is required.
  Multi-file Swift model runners use whole-module compilation to avoid repeated
  per-file work, retaining their existing optimization levels and assertions.
  Each invocation shares one temporary compiler-module cache between the adjustment
  transfer suites, then removes it on success or failure. Test executables and
  results are always rebuilt; no compiled product or test result is reused.
  The standalone `RawLabMac/tests/chroma-settings.sh` and `wavelet-settings.sh`
  likewise need only the Swift models and C ABI declarations, not native libraries.
- iOS Files/LUT UI: `IOS_SIMULATOR_UDID=<dedicated-device> bash RawLab/tests/document-import-ui.sh <build-for-testing-products> <new-output-directory>`.
  The runner stages generated PNG/CUBE fixtures in a test app copy and executes
  picker opening, selection, cancellation and reopening. Run on each required
  iPadOS runtime; `RAWLAB_DOCUMENT_IMPORT_TEST` selects a narrower XCTest case.
- iOS Recently Opened UI: `IOS_SIMULATOR_UDID=<dedicated-device> bash RawLab/tests/recent-photo-ui.sh <build-for-testing-products> <new-output-directory>`. Seed one photo with `simctl addmedia` first. The runner grants Photos access only on that simulator and verifies edit filters, reopening across process restart, reset and removal. It rejects skipped tests.
- Edited-preview cache and iOS recent-source retention checks run in the fast Apple model groups. Mac rendered-preview and resource-watcher checks use `bash RawLabMac/tests/edited-photo-previews.sh` after building the native core; `edited-photo-ui.sh <output-directory>` builds an isolated native editor harness for marker, selection and reset inspection.
- Windows fast models: `./scripts/ci/windows-models.ps1`; no WPF window, native
  rendering DLL, RAW fixture or self-contained app build is required.
- Android models: `./gradlew :app:testDebugUnitTest`; the task graph excludes native
  compilation and APK assembly. Instrumentation remains a separate local entry.
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
- Release-style builds (macOS `build.sh`, Windows `build.ps1`) download the
  pinned vendor RUM SDK from its versioned public URL and fail on a SHA-256
  mismatch; the Android and iOS jobs build Debug, which carries no SDK. No job
  launches a packaged app, uses secrets or sends RUM traffic.
- macOS explicitly excludes `native_dcp_metal`, `gpu_photo` and `metal_denoise`
  from the CI CTest invocation. Other tests may exercise an available GPU
  opportunistically; this is not a guaranteed physical GPU gate.
- Windows does not invoke `build.ps1 -Test`: that entry point's default suite
  requires physical D3D11 and an external RAW path. The hosted suite uses the
  already-public tracked DJI DNG and explicitly selected CPU-safe cases.
  Windows `native/full` includes `raw_active_area_metadata` in that selection.
  It also selects `raw_active_area_sony` when an existing external photo is
  configured through `SONY2FUJI_TEST_SONY_ASPECT_RAW`; the private Sony fixture
  is not provided by CI by default.
- The iOS job compiles UI tests with `build-for-testing`; it does **not** execute
  XCTest, import Photos fixtures, sign a device app or validate installation.
- UI tests are not a CI gate. The self-hosted macOS runner has no accessibility
  grant, so `hdr-rendition-ui.sh` (`AXUIElement`) runs locally and pre-release
  instead of in the model suites; `RAWLAB_REQUIRE_AX=1` turns its skip into a
  failure. The same contract stays gated by the AX-free presentation-layer suite
  `hdr-rendition-reset.sh`. Host-executed suites with "UI" in the name, such as
  `ios-reset-entry-ui.sh`, are presentation-layer model assertions, not XCUITest.
  A `SKIP` reason in a CI suite log counts as a failed gate, never as a pass;
  the gate matches a line-leading `SKIP` marker, so paths, identifiers and
  `PASS:` wording that merely contain "SKIP" stay green. This is distinct from
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
credentials are not persisted, and no `pull_request_target` is used. The
`macos` and `ios` jobs also require the pull request head to come from
this repository, so a normal fork PR skips both; the `windows` job carries the
same clause but admits the hosted `windows-2022` route, so only that route can
execute fork code. Workflow edits in a fork PR
require security review ([External fork pull requests](#external-fork-pull-requests)).
The workflow has bounded jobs and cancels obsolete runs for the same PR/ref;
manual runs use their own concurrency groups so a push neither cancels nor is
cancelled by a manual verification.

The separate [PR cache cleanup](../../.github/workflows/pr-cache-cleanup.yml)
workflow runs when a same-repository PR closes. With `actions: write` and no
checkout, it deletes only the caches stored under that PR's merge ref, which no
other PR or branch can use.

## Local Android Runner

The Android job currently runs on GitHub's hosted `ubuntu-24.04` runner with two
Gradle workers, and the dedicated guest below is paused. From that guest, the
Android SDK's CMake 3.22 download client fails the TLS handshake to github.com,
libraw.org and other upstream hosts, while the system `curl` succeeds.
Prefetching LibRaw alone was not enough, because the native build fetches more
archives from GitHub. Return the job to the guest only after its CMake client can
download them: restore the runner label, the environment and eight-worker limit
described below, and the LibRaw prefetch step, then update the workflow-policy test.

GitHub Actions still owns triggers, check results, logs and dependency caches.
When enabled, the Android job selects `[self-hosted, linux, x64, rawlab-android]`. This label
belongs only to a dedicated Ubuntu
24.04 KVM guest with 32 vCPUs, 32 GiB memory and a 160 GiB disk. The physical
Proxmox host must not carry a runner, JDK or Android toolchain.

Run `sudo bash scripts/ci/provision-android-runner.sh` inside the new guest to
install the Android toolchain. The script rejects a non-KVM/non-Ubuntu guest,
verifies the pinned command-line tools archive, and installs the SDK under
`/opt/android-sdk`. Register the official GitHub runner separately as the
unprivileged `runner` account with the `rawlab-android` label. Do not copy an
administrator's SSH keys or long-lived GitHub token into that account. The job
sets `ANDROID_HOME=/opt/android-sdk`; keep SDK and Gradle
download caches outside its checkout. No Docker socket, host filesystem mount,
GPU passthrough or nested virtualization is needed for the current suite.

`RAWLAB_LENS_SOURCE_CACHE=/var/cache/rawlab-ci/lens-sources` holds source archives
from `lutools/cmake/lens-dependencies.json`, not compiled libraries. Pre-seed
checksum-matching archives there when an upstream endpoint is unavailable;
the existing builder verifies every archive again before use. Missing archives
still download from their pinned upstream URL and failures remain fatal.
`RAWLAB_ANDROID_SOURCE_CACHE=/var/cache/rawlab-ci/android-sources` holds the
LibRaw source archive. On this guest the job prefetched the archive with the
system `curl` and checked its SHA-256. The Android build uses a local copy there
first when the variable is set; `URL_HASH` verifies it again.

This is a persistent, trusted-contributor runner: SDKs, download caches and the
runner installation survive jobs. Checkout cleanup is not a security boundary
against malicious workflow code. Review external contributions before allowing
them onto this runner; do not treat it as an untrusted-code sandbox. The Android
job has no head-repository source gate because it currently runs on hosted
Ubuntu; returning it to this guest without one would execute fork PR code here
([External fork pull requests](#external-fork-pull-requests)).

Only one job runs in this runner workspace at a time. Checkout retains its
default clean behavior, so product output and previous test results cannot
make another job pass. Native dependencies still use the exact-key restore/save
policy below; a persistent VM is not permission to bypass an explicitly selected cold build.
On this guest, the Android job caps Gradle workers at eight. Native tools can use their own
limits: AGP invokes Ninja directly, while Lensfun's builder retains four jobs;
the guest's CPU and memory allocation is the overall resource boundary.
This does not change parallelism or coverage on another platform.

While the job uses the guest, the runner must be online for required Android
checks to finish. GitHub does not automatically fall back to hosted execution
when a self-hosted runner is offline. The hosted route above, with two Gradle
workers, is the rollback. Do not skip the check or weaken branch protection. Keep device/GLES acceptance separate from this
build-only runner.

## Windows Runner Scheduling

Model checks, including ordinary non-draft PRs targeting `development`, use the
standard hosted `windows-2022` runner. They can run concurrently without occupying the dedicated
integration runner. Release/hotfix PRs and manual build/native/full runs select `[self-hosted, windows, x64, rawlab-windows]` in the dedicated
Windows 11 KVM guest with 32 vCPUs, 32 GiB memory, VS 2022 C++ Build Tools and the
Windows SDK. Drafts still skip all platform jobs. A fork PR runs the Windows job
only on the hosted `windows-2022` route; the self-hosted selection keeps the
head-repository source gate, so fork code never queues on the dedicated guest
([External fork pull requests](#external-fork-pull-requests)).
This is event-based routing,
not a busy-runner probe or an automatic fallback when the dedicated runner is
offline. Hosted jobs remain subject to GitHub's account concurrency limits.

The selected group determines coverage on either runner. Model runs do not build
the app or native core; build/native/full groups retain the complete product build
and their requested non-UI suites. Manual runs have a separate result name. A PR's
Windows Server model result does not replace a requested Windows 11 build/native
run or the automatic check on the resulting `development` push SHA.
Neither route establishes physical GPU or interactive-desktop acceptance.

The first Windows setup step uses `runner.environment` to select paths and limits.
Hosted jobs keep .NET and lens source downloads under `RUNNER_TEMP\rawlab-ci`,
with four CMake workers and a four-process cross-project MSVC cap for the standard
four-core, 16 GiB runner. Dedicated jobs keep `E:\RawLabCI` and the existing
16-worker/24-process limits. The native dependency key includes workspace, host,
image and compiler identities, so these hosts cannot restore each other's build
trees. Product outputs and test results are always rebuilt.

### Dedicated Windows Runner

Use a separate 120 GiB NTFS data volume for `E:\RawLabCI`: runner installation, `_work`,
toolcache, SDK downloads, NuGet/Python caches, temporary files and build output
belong there, not on the existing system drive or developer build workspace.
`provision-windows-runner.ps1` rejects system-drive and relative roots. Supply
the pinned PowerShell 7.6.7, runner 2.338.0 and actions/python-versions 3.12.10
ZIPs from their official GitHub releases plus the source-archive bundle and `lens-dependencies.json`; the
script verifies all SHA-256 values before use. Run
`test_windows_runner_provisioning.ps1` as an administrator in the guest to
exercise the no-install safety guards; add `-VerifyToolchain` after provisioning
to verify the completed Python cache and a GNU tar/gzip cache round-trip. The
administrator seeds the official Python tool cache once because setup-python invokes Windows PowerShell without
an execution-policy override and the installer needs administrator privileges.
The bootstrap overrides policy only in that installer process, not on the
machine or service account. It refuses to replace an existing Python 3.12
installation outside this cache. Keep the runner service unprivileged.

Register the runner separately with the `rawlab-windows` label, `_work` on the
data volume, and `NT AUTHORITY\NETWORK SERVICE`, not LocalSystem or the
developer's interactive account. The provisioning script restricts its root
ACL to that service account, SYSTEM and administrators, and prepares its
environment/tool paths. Keep `cmake` and `ctest` discoverable on the runner
PATH before cache identification. `setup-python` and `setup-dotnet` still
select the workflow's Python 3.12 and .NET 8 SDK; their caches/install directory
are on the data volume. No registration token or service credentials belong
in source control or uploaded logs.

Include Git for Windows' `usr\bin` in the runner-only PATH, not just its `cmd`
directory. The cache action selects Git's GNU tar, which must also find `gzip`;
a missing compressor can leave the job green while silently losing its cache.

The dedicated Windows job builds 16 projects at once and enables MSBuild's multi-tool task,
which otherwise leaves each project's sources compiling one at a time. A single
cross-project cap of 24 `cl.exe` processes (`CL_MPCount` with
`EnforceProcessCountAcrossBuilds`) keeps memory within the guest's 32 GiB. These
are CI environment settings; `build.ps1` and local builds are unchanged.

Keep the complete CPU-safe suite, tracked DNG fixture, artifact allowlist and
exact dependency-cache policy. Do not replace it with `build.ps1 -Test`, which
requires physical GPU/external-RAW evidence. Service-session results do not
cover real Explorer/UIA interaction. To route every event back to the dedicated
runner, change `windows_runner` in `affected_platforms.py` and its scheduling
regressions, and keep the job gate coherent: either add `windows` to
`SELF_HOSTED_ONLY` or adjust the hosted-route escape, otherwise fork PRs that
select Windows would skip the job again and the aggregate turns red; do not skip
required checks or remove the runner environment setup.

## Local Apple Runners

The macOS, iOS and Android build jobs use `scripts/ci/prepare-rust.sh` to select
Rust 1.99.1, its standard-library notices and the required target slices. If
`rustup` is absent from the job PATH, the helper verifies the official installer
checksum and installs it under `RUNNER_TEMP/rawlab-x3f-tools`, exporting the job's
Cargo/Rustup paths. It does not require an administrator or change the runner's
login profile. Windows prepares the same pinned toolchain in its own job directory.

macOS arm64 and iOS both select `[self-hosted, macOS, ARM64, rawlab-apple]`.
Each Mac runs one runner, so Apple jobs can execute concurrently without
sharing memory or build directories. When the developer laptop is offline, the
always-on Mac can execute both jobs sequentially instead of waiting indefinitely
for a role-specific runner. Either host must have both complete toolchains.
Their initial build parallelism is six. Heavier Intel matrix
entries remain on `macos-26-intel` with four workers each; neither cross-compilation
nor Rosetta substitutes for its native x86_64 runtime checks.

The Intel `agent` shard isolates Agent recipe rendering from the remaining
`render` checks. Every Intel shard still builds the complete app and executes
its assigned suites; arm64 `all` executes every group once. Only Intel `core`
saves their shared dependency key, while the arm64 job saves its own key. The build-only Intel row also saves its key.
An additional shard uses another hosted macOS execution slot, so concurrent
PRs may still queue at the account's macOS concurrency limit.

Both Mac architectures (the Intel `core` shard) run the existing CPU-safe CTest selection with at most
two test processes. This limit is separate from build parallelism because RAW
rendering tests may also use internal worker threads. Each architecture's `core`/`all`
native group also runs HDR display packing and native bridge regressions, including
Intel's portable FP16 conversion. The default Swift app uses whole-module optimization with compiler threads bounded by `JOBS`; it retains
`-O` and all sources. The full-source straighten UI harness runs locally. No app or test executable is cached. Each Mac regression
stage records elapsed seconds and its exit code in `build/ci/macos-timings.log`; command failures
still fail the job rather than being hidden by the timing wrapper.

These two runners run directly on user-approved physical Macs, unlike the
Android/Windows KVM guests. Prefer the dedicated non-administrator `rawlab-ci`
account. An owner-approved personal account may opt in by appending
`--allow-current-user` to the provisioning command; this is not isolation and
CI inherits that user's access to personal files and credentials. Root is
always refused, and CI jobs must not use sudo. Prepare full Xcode and Homebrew
`pkgconf`, `autoconf`, `automake`, `libtool` and `python@3.12` as an
administrator. Use `DEVELOPER_DIR` rather than changing another user's selected
developer tools.

For iOS builds, both pool Macs need Xcode 27.1+ with device and simulator SDKs
at least 27.1. This enables iPhone Duo's full display without raising RawLab's
iOS 18.0 deployment target. `bash scripts/ci/check-ios-sdk.sh` checks the selected
toolchain during runner provisioning and before the iOS build job prepares Rust
or native caches. The app target checks its actual SDK for local and release
builds too. Model-only jobs retain their standalone macOS-SDK route. Upgrade
the prepared Xcode copy on each pool host before running iOS build/native/full
checks; CI does not install Xcode or change global toolchain selection.

Native dependency outputs embed the workspace, Xcode SDK and Python paths, so the
cache key includes them. Both pool Macs therefore use one identical layout on a
case-sensitive APFS volume named `RawLabCI`, mounted at `/Volumes/RawLabCI`
(an administrator adds it with `diskutil apfs addVolume <container> APFSX RawLabCI`;
it shares the container's free space): the runner workspace `_work`, a CI-only
Xcode copy at `tools/Xcode.app` and the Python venv `venv`, which pins CMake via
[`requirements-apple-runner.txt`](../../scripts/ci/requirements-apple-runner.txt).
A key computed on one Mac then matches the other, and either Mac reuses the
other's dependencies. The pool Macs must also keep the same macOS build, Xcode
build, Homebrew `pkgconf`/autotools and Python 3.12 patch release. A mismatch does
not break builds; it only gives each Mac separate cache keys again. Compare
`build/ci/native-cache.json` from each Mac's artifacts to find the differing field.

Keep the CI root with runner startup files and credentials inside the CI user's
home on the internal disk. A LaunchAgent can be denied access to an external
volume even when SSH under the same user works; allow only the necessary
external-storage access when macOS prompts in the CI desktop session. Do not
grant system-wide shells Full Disk Access to work around this restriction.
After installing or updating Xcode, an administrator must accept that version's
license and run its first-launch initialization with the same `DEVELOPER_DIR`.
The CI account must pass `xcodebuild -checkFirstLaunchStatus` and SDK discovery
without sudo before runner registration; an older Xcode license is not sufficient.
The iOS simulator SDK alone is not enough: both pool hosts need an available iOS
simulator runtime for the look-import regression. Prepare one with the selected
Xcode's `xcodebuild -downloadPlatform iOS -architectureVariant arm64`, or export
and import an official runtime using `-exportPath` and `-importPlatform`.
Provisioning checks `xcrun simctl list runtimes available -j` as the runner user
before creating runner files; it never installs system components from a CI job.
`provision-macos-runner.sh <ci-root> /Volumes/RawLabCI/tools/Xcode.app <runner-archive>`
checks the account, pool volume and SDKs, verifies the pinned official arm64
runner archive, creates the shared-path Python 3.12 venv with pinned CMake and
dedicated cache/temp directories, and names the `--work` directory to register. Do not
copy private SSH keys, personal Keychains or signing credentials into this account.

Local Apple jobs use that prepared Python instead of setup-python's macOS
installer, whose fixed framework installation requires elevated privileges.
CI installs its pinned requirements only in the venv. Keep the complete PATH in
the runner's `.path` and literal SDK/cache variables in `.env`. PATH is also
stored in `.env` because `config.sh` rewrites `.path` during registration.
Configure each runner separately with its shared pool label and own workspace, then install its
official user LaunchAgent while the selected runner user is logged in. A user LaunchAgent
depends on that login session: fast user switching is fine, logout or machine
sleep makes the runner unavailable. Do not grant the CI account sudo or change
sleep/security settings silently on a developer's laptop.

This remains trusted-code execution, not a security sandbox. Use separate
workspaces per machine and keep persistent source/download caches separate from
the exact dependency-output cache. Logs record the actual macOS/Xcode versions;
moving hosts is not evidence for minimum-OS, physical GPU or device acceptance.
To roll back, restore hosted `macos-26` for the relevant job and its Python setup
step, parallelism, policy tests and actionlint declarations. Keep every platform check.

## Native Dependency Caches

Model-only checks do not configure or restore native caches. Explicit warm build
and native groups use an exact dependency key. **Cold builds never restore native
caches**: manual full runs and release/hotfix PRs build dependencies from source. They
look up the exact key without downloading its contents and skip saving when that
accessible cache already exists. Any miss builds from source and saves only after
the full job succeeds; of the three Intel shards, only `core` saves their shared key.
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
does not demonstrate a speedup. Hosted Intel uses four build workers and two
CTest processes; local Android and Windows jobs use the bounded settings
documented above;
measure changes on their own guests rather than extrapolating from hosted timings.

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

The [archived 0.8 preparation ledger](../archive/releases/v0.8/preparation.md)
retains its original candidate scope. Use [release notes](../releases/v0.8/v0.8.1.md)
and package provenance for delivered artifacts; historical local/device reports
retain their original source and device scope.
