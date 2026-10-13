# Multilingual Support Implementation Plan

**Goal:** Localize the four native clients in Simplified Chinese, English,
German, French, Japanese and Spanish.

**Approved behavior:** Follow system language by default, persist a manual
language choice, and fall back to English for unsupported languages. Translate
application UI, accessibility text, dialogs and application-controlled errors.
Keep film names, file names, processing parameters and persisted identifiers
unchanged. CLI, logs and documentation are outside the translation scope.

**Architecture:** Apple clients share a Foundation-only language resolver and
bundle lookup, with separate native string resources. Android uses qualified
string resources. Windows uses a client-local resource catalog. No changes to
the C ABI or rendering pipeline are required.

## Tasks

- [x] Apple foundation: add `Shared/Localization.swift` and focused resolver,
  fallback, interpolation and preference tests in
  `RawLabMac/tests/LocalizationTests.swift` and `localization.sh`.
- [x] macOS: extract UI and model text into six `Localizable.strings` catalogs,
  add the persistent native language picker, package localized bundles, and
  link the shared helper into relevant shell-driven tests.
- [x] iOS: localize views/models/permissions, add the persistent native picker,
  and add shared source and localization resources to the Xcode target.
- [x] Android: complete native resources, localize remaining hardcoded UI text,
  add persistent language choice, and run available Gradle checks.
- [x] Windows: localize XAML/model text, add persistent language choice, and
  run portable catalog tests and available WPF checks.
- [x] Integration: verify six-language key/placeholder parity, inspect source
  coverage and persisted identifiers, build native clients where tooling is
  available, and report unavailable platform checks explicitly.
- [x] Approved migration: move only localization-owned changes onto current
  `development`; adapt master recipes, HSL, photo effects and exposure controls
  added on that branch. Exclude the unrelated AI/JPEG XL and viewport changes.
- [x] Obtain two independent reviews, fix confirmed findings, and recheck them.

## Workspace Constraints

The initial work used `feat/multilingual-support` in the original checkout. The
user subsequently approved migration into an independent worktree and delivery
via commit, push and a PR to `development`. Delivery now uses
`feature/multilingual-support`, based on development commit
`12d6cc17b2b92233657d3eb548ee146dbdcb8530`.

Preserve the original checkout and its viewport-preview/denoise changes and
untracked files. Do not merge, release, deploy, modify original RAWs or include
build artifacts. Use explicit single-device Android commands and the isolated
Windows verification directory; do not change other tasks' devices or machine
security settings.
