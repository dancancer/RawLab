# Continuous Verification

The [workflow](../../.github/workflows/ci.yml) verifies pull requests targeting
`development`, `release/**` or `main`, and pushes to `development` or `main`.
Release branches are verified through PRs rather than duplicate push runs. It does not
run on tags, publish packages, create releases, deploy, notarize or use signing
credentials. A workflow run is not release authorization.

## Required Checks

| Check | Runner | Coverage |
| --- | --- | --- |
| Contracts and CI policy | Ubuntu 24.04 | Workflow boundary guards, single-preview source contracts, whitespace |
| macOS build and parity (arm64 / x86_64) | Dedicated Apple Silicon Mac and hosted macOS 26 Intel; deployment target 14.0 | Default app/bundle and full-feature native build for each architecture; CPU-safe CTest; real RAW/raster GUI-Agent-batch parity; edit model, photo-copy/localization and SDK-free analytics lifecycle |
| Windows build and parity | Dedicated Windows 11 x64 KVM / VS 2022 | Default native and self-contained .NET 8 package; selected CPU-safe CTest/schema; managed editing/localization/denoise/profile; RAW/raster Agent and default-comparison integration |
| Android build and JVM tests | Dedicated Ubuntu 24.04 KVM / JDK 17 | JVM tests, lint, debug app and instrumentation test APK compilation, arm64-v8a/x86_64 native libraries and 16 KB alignment |
| iOS framework and unsigned app | Apple Silicon runner pool / Xcode | Existing full-feature device arm64 and simulator arm64/x86_64 framework; resource/license/runtime-dependency verification; unsigned simulator app and UI-test compilation |

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
  from the CI CTest invocation. Other tests may exercise an available GPU
  opportunistically; this is not a guaranteed physical GPU gate.
- Windows does not invoke `build.ps1 -Test`: that entry point's default suite
  requires physical D3D11 and an external RAW path. The hosted suite uses the
  already-public tracked DJI DNG and explicitly selected CPU-safe cases.
- The iOS job compiles UI tests with `build-for-testing`; it does **not** execute
  XCTest, import Photos fixtures, sign a device app or validate installation.
- Android compiles instrumentation tests but does **not** run connected-device
  tests. GLES, SAF, OEM locale and physical interaction evidence stays separate.
- Building both architectures with a 14.0 minimum on a newer macOS does not establish
  runtime support on macOS 14; native acceptance on the minimum OS is separate.
  [Runner labels](https://github.com/actions/runner-images/blob/main/README.md)
  and toolchains can change; logs identify the actual environment.
- Mac dependencies include source-built dynamic GLib/Lensfun rather than a
  higher-minimum Homebrew bottle. App/bundled-dylib architecture and minimum OS
  are checked by the existing bundle gate. The 14.0-target picker model/native
  bridge regressions run on both architectures, not on an OS 14 host.

## Safety and Results

Actions are pinned to full commit SHAs. Workflow permission is `contents: read`,
checkout credentials are not persisted, and no `pull_request_target` is used.
The workflow has bounded jobs and cancels obsolete runs for the same PR/ref.

## Local Android Runner

GitHub Actions still owns triggers, check results, logs and dependency caches.
The Android job selects `[self-hosted, linux, x64, rawlab-android]`. This label
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

This is a persistent, trusted-contributor runner: SDKs, download caches and the
runner installation survive jobs. Checkout cleanup is not a security boundary
against malicious workflow code. Review external contributions before allowing
them onto this runner; do not treat it as an untrusted-code sandbox.

Only one job runs in this runner workspace at a time. Checkout retains its
default clean behavior, so product output and previous test results cannot
make another job pass. Native dependencies still use the exact-key restore/save
policy below; a persistent VM is not permission to bypass a cold push build.
The Android job caps Gradle workers at eight. Native tools can use their own
limits: AGP invokes Ninja directly, while Lensfun's builder retains four jobs;
the guest's CPU and memory allocation is the overall resource boundary.
This does not change parallelism or coverage on another platform.

The runner must be online for required Android checks to finish. GitHub does
not automatically fall back to hosted execution when a self-hosted runner is
offline. To roll back, restore the Android `ubuntu-24.04` runner and its previous
parallelism, and update the matching workflow-policy test. Do not skip the check
or weaken branch protection. Keep device/GLES acceptance separate from this
build-only runner.

## Local Windows Runner

Windows selects `[self-hosted, windows, x64, rawlab-windows]` in a dedicated
Windows 11 KVM guest with 32 vCPUs, 32 GiB memory, VS 2022 C++ Build Tools and
the Windows SDK. This
changes the verification host from hosted Windows Server 2022 to Windows 11;
it does not establish physical GPU or interactive-desktop acceptance.

Use a separate 120 GiB NTFS data volume for `E:\RawLabCI`: runner installation, `_work`,
toolcache, SDK downloads, NuGet/Python caches, temporary files and build output
belong there, not on the existing system drive or developer build workspace.
`provision-windows-runner.ps1` rejects system-drive and relative roots. Supply
the pinned PowerShell 7.6.7, runner 2.338.0 and actions/python-versions 3.12.10
ZIPs from their official GitHub releases plus the source-archive bundle and `lens-dependencies.json`; the
script verifies all SHA-256 values before use. Run
`test_windows_runner_provisioning.ps1` as an administrator in the guest to
exercise the no-install safety guards; add `-VerifyToolchain` after provisioning
to verify the completed Python cache. The administrator seeds the official
Python tool cache once because setup-python invokes Windows PowerShell without
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

Keep the complete CPU-safe suite, tracked DNG fixture, artifact allowlist and
exact dependency-cache policy. Do not replace it with `build.ps1 -Test`, which
requires physical GPU/external-RAW evidence. Service-session results do not
cover real Explorer/UIA interaction. To roll back, restore `windows-2022`, its
previous parallelism and matching policy/actionlint declarations rather than
skipping required checks.

## Local Apple Runners

macOS arm64 and iOS both select `[self-hosted, macOS, ARM64, rawlab-apple]`.
Each Mac runs one runner, so the two Apple jobs can execute concurrently without
sharing memory or build directories. When the developer laptop is offline, the
always-on Mac can execute both jobs sequentially instead of waiting indefinitely
for a role-specific runner. Either host must have both complete toolchains.
Their initial build parallelism is six. The Intel matrix
entry remains on `macos-26-intel` with two workers; neither cross-compilation
nor Rosetta substitutes for its native x86_64 runtime checks.

These two runners run directly on user-approved physical Macs, unlike the
Android/Windows KVM guests. Use the dedicated non-administrator `rawlab-ci`
account, not a personal administrator account. Prepare full Xcode and Homebrew
`cmake`, `pkgconf`, `autoconf`, `automake`, `libtool` and `python@3.12` as an
administrator. Keep Xcode on a local disk with sufficient capacity and use
`DEVELOPER_DIR` rather than changing another user's selected developer tools.
After installing or updating Xcode, an administrator must accept that version's
license and run its first-launch initialization with the same `DEVELOPER_DIR`.
The CI account must pass `xcodebuild -checkFirstLaunchStatus` and SDK discovery
without sudo before runner registration; an older Xcode license is not sufficient.
`provision-macos-runner.sh <ci-root> <Xcode.app> <runner-archive>` checks the
account and SDKs, verifies the pinned official arm64 runner archive, and creates
an isolated Python 3.12 venv and dedicated build/cache/temp directories. Do not
copy private SSH keys, personal Keychains or signing credentials into this account.

Local Apple jobs use that prepared Python instead of setup-python's macOS
installer, whose fixed framework installation requires elevated privileges.
CI installs its pinned requirements only in the venv. Keep the complete PATH in
the runner's `.path` and literal SDK/cache variables in `.env`. PATH is also
stored in `.env` because `config.sh` rewrites `.path` during registration.
Configure each runner separately with its shared pool label and own workspace, then install its
official user LaunchAgent while `rawlab-ci` is logged in. A user LaunchAgent
depends on that login session: fast user switching is fine, logout or machine
sleep makes the runner unavailable. Do not grant the CI account sudo or change
sleep/security settings silently on a developer's laptop.

This remains trusted-code execution, not a security sandbox. Use separate
workspaces per machine and keep persistent source/download caches separate from
the exact dependency-output cache. Logs record the actual macOS/Xcode versions;
moving hosts is not evidence for minimum-OS, physical GPU or device acceptance.
To roll back, restore hosted `macos-26` for the relevant job and its Python setup
step, parallelism, policy tests and actionlint declarations. Keep all six checks.

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
changing the cold-push policy.

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
does not demonstrate a speedup. Hosted jobs retain their existing parallelism.
Local Android and Windows jobs use the bounded settings documented above;
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
