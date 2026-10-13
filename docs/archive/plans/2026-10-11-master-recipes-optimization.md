# Master Recipes Optimization Implementation Plan

> **For agentic workers:** Optimization is complete. A subsequent user request authorizes commit, push, a PR to `development`, and merge after verification. Keep private run data out of the delivery.

**Goal:** Optimize the 14 existing display-sRGB master looks using the user-provided reference collections and the existing model runtime, without changing preset application or strength semantics.

**Architecture:** CanonCGT canonicalizes each approved reference independently. These are model-generated pseudo inputs, not real before/after pairs. Fit a small, smooth correction to each existing LUT, with a bounded prior and separate validation images. Export one fixed 65-grid LUT per style; no per-source prediction or spatial effects.

**Tech Stack:** Existing Python/PyTorch/Pillow/CanonCGT runtime; existing CUBE mathematical helpers; RawLab native CPU/Metal and Swift regression tests.

**Spec:** The user's optimization request, existing `MasterRecipe.swift` catalog, and `lutools/docs/color-contract.md`. Implementation must match the already-supported display-sRGB look path rather than the older F-Log2 preparation path.

## Global Constraints

- Work only in the existing isolated b175b283 worktree. Preserve all earlier UI and behavior fixes.
- Do not modify NAS originals, existing remote scripts/checkpoints, system packages, GPU services, or original RAWs.
- Use one currently idle GPU, fixed by UUID. Keep private reference paths, EXIF, previews, weights, and checkpoints out of Git and public CUBE headers.
- Convert embedded ICC profiles to sRGB before analysis; record untagged sRGB assumptions. Exclude monochrome, undecodable and duplicate references. Group by supplied series or capture day where available; without these, proxy dedup does not prove scene independence.
- Existing SetLUT training covers synthetic functions only; do not call it a trained photographer model. Load CanonCGT checkpoint strictly and label pseudo supervision explicitly.
- Keep names, IDs, 65-grid, sRGB/BT.709 metadata, six UI settings, persistence, and strength behavior compatible. Do not bake those six UI controls into the LUT again.
- Preserve authored color directions with a small correction budget. Repair only gray-axis tone monotonicity and compress gamut, rather than enforcing single-channel luma monotonicity across hue changes or clipping channels.
- Validation error against pseudo targets is only an internal diagnostic, not photographer-style accuracy. Ordinary LUTs cannot reproduce light placement, grain, halation or semantic masks.

## Tasks

1. [x] Add failing tests for the finite/range/gray-tone constraints, bounded correction, axis order, ICC conversion, duplicate split and rejected export. Run them in the existing model runtime.
2. [x] Implement `experiments/master-recipes-v2/optimize.py` and focused tests. Reuse `hamada_neural.cube` rather than add a second interpolation/export implementation. Keep all fit artifacts under a new private run.
3. [x] Analyze all reference groups, use approved Hamada daylight entries separately, and run CanonCGT strictly. Fit on train only, choose a bounded correction on validation, and retain test images for diagnostic replay.
4. [x] Export candidates, check all 14 with `generate-lut/scripts/validate_lut.py`, and compare clipping, adjacent luminance, neutral/skin probes and old-look preservation. Inspect old/new native RAW previews and reference pseudo-input scenes; dedicated night RAW remains unverified.
5. [x] Replace only accepted CUBE assets, run catalog/model and native RAW CPU/Metal/full-recipe export regressions, then build/package macOS and record provenance, measured results and limitations in `docs/verification/`.

Run unit tests with `PYTHONPATH=<existing-hamada-code> python -m unittest discover -s experiments/master-recipes-v2 -p 'test_*.py'`. Run production checks with `bash RawLabMac/tests/master-recipe.sh`, `bash RawLabMac/tests/edit-model.sh`, `bash RawLabMac/tests/master-recipe-render.sh <DNG> <Sony ARW>`, and `bash RawLabMac/build.sh`.
