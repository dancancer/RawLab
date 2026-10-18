# Hosted CI Speedup Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Reduce PR latency without removing platforms, product features or tests.

**Architecture:** Reuse only third-party installation/build outputs with exact,
toolchain-specific keys. PRs restore caches; successful push builds on `main`
and `development` build from source and seed caches visible to later PRs.
Keep the existing generators and product build/test commands.

**Tech Stack:** GitHub Actions, Python unittest, Bash, CMake/Xcode/MSBuild/Ninja.

**Spec:** User request of 2026-10-18 and [CI verification boundaries](../../ci.md).
Implementation, pushing `feature/ci-speedup` and opening a PR to `development`
are authorized. Merging and publishing are not authorized.

## Global Constraints

- Base: `origin/development` at `515bbf7a69fe43446a3a9503e63d7fb50629448c`.
- Keep all six required checks and their existing regression suites.
- Keep `contents: read`, SHA-pinned actions, credential-free checkouts and the
  existing log/JSON/XML artifact allowlist.
- Remove only `release/**` push triggers; keep PRs targeting all three branch
  classes and push checks on `development` and `main`.
- No fallback/prefix restore keys for compiled dependencies.
- Cache identity includes dependency inputs, build scripts, compiler/SDK,
  runner image, architecture, deployment configuration and absolute workspace.
- No product libraries, executables, app bundles, test results or final mobile
  frameworks in the native cache. Shared build metadata is not a product output.
- Keep build parallelism unchanged until hosted evidence justifies changing it.

## Review Focus

- Cache visibility: a PR-only cache cannot seed unrelated PRs; cold base-branch
  push jobs must save the same exact key without restoring it.
- ABI/toolchain drift and absolute paths must invalidate restored outputs.
- CMake/Xcode/Ninja metadata may cause dependency rebuilds even after restore;
  measure a second hosted run rather than treating a cache hit as a speedup.
- Changed RawLab sources must compile even if dependency keys stay unchanged.
- Missing cached headers/libraries must fail or rebuild, never skip checks.

## Task 1: Exact Cache Identity and Policy

**Files:** `scripts/ci/native_cache.py`, `scripts/ci/test_native_cache.py`,
`scripts/ci/test_workflow.py`, `.github/workflows/ci.yml`.

**Interfaces:** A Python CLI emits `key` and multiline `paths` step outputs;
the workflow uses those outputs for pinned `actions/cache/restore` and `save`.

- [x] Write failing tests for input invalidation, product-output exclusion,
  release trigger deduplication and PR-only restores.
- [x] Implement platform-specific input/path allowlists and toolchain identity.
- [x] Wire exact restore/save steps without skipping product builds or tests.
- [x] Run all CI policy/cache tests and actionlint; expect success.

## Task 2: Reuse Installed Dependencies

**Files:** `RawLabMac/build.sh`, `lutools/cmake/lens-dependencies.cmake`,
cache regression tests and a small real Xcode cache-boundary fixture.

**Interfaces:** `RAWLAB_CI_CACHE_HIT=true` is supplied only by the exact restore
step. Local and cold builds retain their existing behavior.

- [x] Write failing tests for exact-hit reuse and missing dependency failure.
- [x] Skip redundant Mac dependency builds and Lensfun configure/build only
  after exact hits; preserve package/architecture/runtime checks.
- [x] Prove with a real Xcode build that selected dependency outputs can be
  reused while product objects are absent and changed product sources rebuild.
- [x] Run existing Mac build-environment and Lensfun contract tests.

## Task 3: Hosted Measurement and Documentation

**Files:** `docs/ci.md`, this plan's checklist and a scoped verification report.

**Interfaces:** Record the source SHA, event, cache hits, job execution time and
queue time separately. Cold and warm runs must refer to the same source.

- [x] Request independent review, resolve actionable findings and run local gates.
- [x] Commit owned files, push the feature branch and create one PR to development.
- [ ] Run cold and warm hosted CI; investigate failures or ineffective caches.
- [ ] Record observed improvements, remaining limits and untested scenarios.
- [ ] Remove task-owned temporary files; retain the worktree and PR for review.
