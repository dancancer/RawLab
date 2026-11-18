## Summary

- What changed and why:
- Related GitHub Issue(s): `Closes #...` / `Refs #...`

## Source SHA & Target Base

- **Source head SHA**: `<git rev-parse HEAD>`
- **Target base branch**: `development` (or `main` / `release/*` per Gitflow)

## Verification Anchor

> Every fix or behavior change must anchor an observable test that passes with the change and fails when the fix is reverted (not private-member literal assertions or silent skips).

- **Test command(s)**:
  ```sh
  # e.g. ctest --test-dir lutools/build-macos --output-on-failure
  ```
- **Expected / observed assertion**:
  - ...
- **Revert-to-red evidence** (how reverting the fix makes the test fail):
  - ...

## Platform Coverage

> Strictly separate locally executed checks, Hosted CI checks, static checks, and unverified physical hardware/device gates.

- **Local executed & passed**:
  - [ ] Core (`ctest`) / Scripts (`python3 -m unittest`) / Apple / Android / Windows
- **Hosted CI (`ci.yml`)**:
  - [ ] `contracts`
  - [ ] Affected platform checks (`models` / `build` / `native` / `full`)
- **Pending physical hardware / device verification** (if any):
  - [ ] None / List specific device, OS, or hardware GPU gates still pending

## Risk & Scope Checklist

- [ ] Minimal sufficient change; unrelated refactoring avoided, raw photos/credentials/build artifacts excluded.
- [ ] **CODEOWNERS high-risk paths check**: Does this PR touch `/lutools/include/`, `/Shared/specs/`, `/Shared/fixtures/`, or `/lutools/src/gpu/*shader*`?
  - [ ] No — standard self-verification + Hosted CI gate applies.
  - [ ] Yes — **mandatory carbon / independent review** completed and bound to the current head/base SHAs.
- [ ] No tracked in-repo task ledger / kanban / changelog files added (execution status belongs in GitHub Issues/Projects).
