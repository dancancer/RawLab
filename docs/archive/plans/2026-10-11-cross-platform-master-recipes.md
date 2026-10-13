# Cross-Platform Master Recipes Implementation Plan

**Goal:** Match the current macOS adjustment surface and master-recipe behavior on iOS, Android and Windows, then test and rebuild each client.

**Architecture:** One shared JSON catalog contains the calibrated fourteen recipes. Existing client settings remain the visible/editable state; applying a recipe overwrites six controls and HSL. Rendering scales a copy of those current values. The shared C ABI and native algorithms stay unchanged.

**Constraints:** Preserve existing uncommitted work, original RAWs, old ordinary edits and frozen tasks. Recipe tint is relative to each target RAW's actual camera WB. Do not commit, push, change release versions or redistribute reference photos/models.

- [x] Add a failing catalog-parity regression, export the verified Mac definitions into `Shared/master-recipes.json`, and make Mac consume this catalog.
- [x] Windows: add catalog/asset packaging, visible recipe selection, state/snapshot support, scaled request/HSL, target-WB initialization and film mutual exclusion. Extend portable and native rendering checks, then build on the existing Windows host.
- [x] Android: add catalog/asset packaging, selection UI, edit/journal codecs, frozen LUT handling, native target-WB initialization and effective parameters. Align numeric steps and HSL reset. Run Gradle unit/lint/build and connected tests.
- [x] iOS: preserve native/normalized storage while correcting UI ranges/signs/steps; add catalog/resources, recipe UI, edit/batch state and effective rendering with target-WB initialization. Run model/processor tests and simulator/device builds.
- [x] Check all bundled catalogs/assets against the same source; inspect the native picker surfaces, run the relevant RAW CPU/GPU/export checks and write the final verification report.

Regression contract: all fourteen presets overwrite six controls and all 24 HSL values; current manual edits survive persistence and frozen batch replay; strength 0/0.5/1/2 scales only the six controls, HSL and LUT; HSL preserves fractions and clamps to [-100,100]. Recipe removal preserves visible values, converting the WB tint offset to an absolute independent setting. Ordinary LUT strength leaves independent controls unchanged. iOS old records retain their old rendered values.

Picker contract: iOS and Android use direct horizontal dragging, with no left/right buttons. macOS and Windows show left/right buttons only when film or master-recipe items exceed the complete available width; endpoint buttons are disabled and controls disappear when all items fit.
