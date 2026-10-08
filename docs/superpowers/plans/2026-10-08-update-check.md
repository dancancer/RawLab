# Update Detection and About

Approved scope: Mac, Windows and Android detect public stable GitHub releases;
the user opens the release page to download. No installer, telemetry, credentials,
photo uploads, iOS changes or release publishing. Author links are the repository
and the user-provided Xiaohongshu profile only.

## Implementation

- [x] Add platform-local release parsing and numeric version comparison tests.
  Accept historical two-part tags, reject prerelease/malformed tags, never downgrade,
  require a matching platform asset, and test the 24-hour automatic-check policy.
- [x] Add native HTTP clients with timeouts, persistent opt-out and last-attempt
  timestamps. Manual checks bypass the interval; concurrent checks coalesce.
  Cache successful metadata so a restart inside the interval retains update news.
- [x] Add native About surfaces and manual checks. Startup checks are nonblocking;
  failures stay in About and new versions use a nonmodal entry point.
- [x] Correct Windows product version to the current 0.4.0 baseline, without
  changing historical release records or publishing new packages.
- [x] Run focused tests, build Mac/Android and check Windows compilation when a
  suitable SDK is available. Inspect native UI and report platform-specific gaps.

## Files and Contracts

Mac: `Sources/UpdateRelease.swift` owns parsing/policy; `UpdateChecker.swift`
owns URLSession/UserDefaults state; `AboutView.swift` owns native presentation;
`RawLabMacApp.swift` wires startup, menu and update notice.

Windows: `UpdateRelease.cs`, `UpdateChecker.cs`, `AboutWindow.xaml(.cs)` mirror
those responsibilities using HttpClient and a local JSON preference file.
MainWindow owns only the entry point and startup trigger.

Android: `UpdateRelease.kt`, `UpdateViewModel.kt`, `AboutDialog.kt` mirror those
responsibilities using HttpURLConnection, SharedPreferences and Compose.
MainActivity/EditorScreen expose the existing More-menu entry point.

Endpoint: `https://api.github.com/repos/dancancer/RawLab/releases/latest`.
Only numeric stable tags `vMAJOR.MINOR[.PATCH]` are eligible. Construct release
URLs from that validated tag, never navigate to arbitrary API-supplied links.
Current versions come from application package metadata. Tests use synthetic
responses, not live GitHub state. API reference:
https://docs.github.com/en/rest/releases/releases#get-the-latest-release

Repository: https://github.com/dancancer/RawLab

Author: https://www.xiaohongshu.com/user/profile/6474b1560000000010037c8e

## Verification

- Mac: `bash RawLabMac/tests/update-check.sh` passes release/policy and async state
  suites; isolated local app build and bundle checks pass. All Mac sources also
  type-check with the macOS 15 deployment target. Native About links, manual
  online check and layout inspected; no newer release is reported at 0.4.0.
- Android: `:app:testDebugUnitTest` (36 tests), `:app:lintDebug`,
  `:app:assembleDebug` and `:app:assembleDebugAndroidTest` pass. Explicit
  emulator-only instrumentation runs `UpdateViewModelInstrumentedTest` and
  `AboutScreenTest`: 3 tests pass. Phone/light and tablet/dark with 1.3 font scale
  screenshots inspected. No physical-device app was replaced.
- Windows: portable `tests/updates/UpdateChecks.csproj` passes parsing, policy,
  preferences, cache, HTTP failure, coalescing and persistence-failure checks.
  Main WPF app and existing WPF test project cross-compile with .NET 8 and
  `EnableWindowsTargeting=true`, zero warnings/errors. `build.ps1 -Test` now
  includes the portable checks. Native Windows UI/runtime execution remains
  unverified in this task.
- `git diff --check` passes. No commit, push or new release was performed.
