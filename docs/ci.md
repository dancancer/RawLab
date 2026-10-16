# Hosted Verification

The [workflow](../.github/workflows/ci.yml) verifies pull requests targeting
`development`, `release/**` or `main`, and pushes to those branches. It does not
run on tags, publish packages, create releases, deploy, notarize or use signing
credentials. A workflow run is not release authorization.

## Required Checks

| Check | Hosted runner | Coverage |
| --- | --- | --- |
| Contracts and CI policy | Ubuntu 24.04 | Workflow boundary guards, photo-copy and single-preview source contracts, whitespace |
| macOS build and parity | macOS 26 arm64 | Default app/bundle and full-feature native build; CPU-safe CTest; real RAW/raster GUI-Agent-batch parity; edit model, localization and SDK-free analytics lifecycle |
| Windows build and parity | Windows Server 2022 x64 / VS 2022 | Default native and self-contained .NET 8 package; selected CPU-safe CTest/schema; managed editing/localization/denoise/profile; RAW/raster Agent and default-comparison integration |
| Android build and JVM tests | Ubuntu 24.04 / JDK 17 | JVM tests, lint, debug app and instrumentation test APK compilation, arm64-v8a/x86_64 native libraries and 16 KB alignment |
| iOS framework and unsigned app | macOS 26 arm64 / Xcode | Existing full-feature device arm64 and simulator arm64/x86_64 framework; resource/license/runtime-dependency verification; unsigned simulator app and UI-test compilation |

All five checks must **succeed on the current PR head/test merge**. A missing,
skipped, cancelled or stale-head run is not a pass. After merge, also inspect the
push run for the exact `development` merge SHA. Logs print the checked-out SHA;
PR checks may test GitHub's synthetic merge commit rather than the source head.
Use the run's event, source head, checkout SHA and base together when recording
evidence. A later source/base change invalidates the earlier integration result.

## Boundaries

- Default builds retain Adobe DNG SDK, Lensfun, chroma and wavelet denoise. No
  optional product feature is disabled to obtain a green check.
- RUM vendor SDKs remain opt-in private-local dependencies. These jobs use the
  default SDK-free path, no secrets and no real RUM traffic.
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
- macOS 26 arm64 success does not establish the advertised macOS 15/Intel support.
  [Runner labels](https://github.com/actions/runner-images/blob/main/README.md)
  and toolchains can change; logs identify the actual environment.

## Safety and Results

Actions are pinned to full commit SHAs. Workflow permission is `contents: read`,
checkout credentials are not persisted, and no `pull_request_target` is used.
The workflow has bounded jobs and cancels obsolete runs for the same PR/ref.
It currently performs cold native builds, with no shared compiled-output cache.

Only `build/ci/*.log`, `*.json` and `*.xml` are uploaded, retained for seven days.
Do not widen this allowlist to photos, RAW inputs, screenshots, user profiles,
app bundles, native binaries, APKs or entire build directories. Build packages
are ephemeral verification outputs, not versioned release candidates.

Local workflow-policy regression tests:

```sh
python3 -m venv /tmp/rawlab-ci-venv
/tmp/rawlab-ci-venv/bin/pip install -r scripts/ci/requirements.txt
/tmp/rawlab-ci-venv/bin/python scripts/ci/test_workflow.py
```

These guards supplement, not replace, workflow syntax linting and actual hosted
execution. Platform jobs stop on command/test failures; they are not allowed to
silently skip a required suite or mark a failing native process successful.

The [0.8 release checklist](releases/v0.8.0-preparation.md) owns release blockers;
historical local/device reports retain their original source and device scope.
