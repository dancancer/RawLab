# Documentation

[English](README.md) | [简体中文](README.zh-CN.md)

The current release is [v0.8.2, build 14](releases/v0.8/v0.8.2.md).
The [GitHub release record](https://github.com/dancancer/RawLab/releases) owns
published packages, checksums and package provenance.

## Guides

- [Installation and published packages](guides/installation.md)
- [iPhone installation](guides/ios-installation.md) and [Simplified Chinese guide](guides/ios-installation.zh-CN.md)
- [macOS](../RawLabMac/README.md), [Windows](../RawLabWindows/README.md), [Android](../RawLabAndroid/README.md) and [iOS builds](../lutools/platform/ios/README.md)
- [Core and CLI](../lutools/README.md), [usage](../lutools/docs/usage-guide.md) and [look reference](../lutools/docs/look-reference.md)

## Process

- [Repository instructions: Gitflow, release authority and documentation policy](../AGENTS.md)
- [Multi-PR integration workflow](process/integration-workflow.md)
- [Hosted CI policy and coverage boundaries](process/ci.md)
- [Localization](process/localization.md)

## Reference

- [Color and rendering contract](../lutools/docs/color-contract.md), [platform integration](../lutools/docs/platform-integration.md) and [iOS API](../lutools/docs/ios-api.md)
- [Edit JSON and Agent interface](../lutools/docs/edit-json.md)
- [Native DCP look](reference/formats/native-dcp-look.md) and [DCP HueSatMap/Metal](reference/formats/dcp-hsm-metal.md)
- [Universal LUT contract](reference/formats/universal-lut.md), [LUT preparation](../lutools/docs/lut-preparation.md) and [Fujifilm LUT compatibility](reference/formats/fuji-lut-compatibility.md)
- [Native-client lens correction](reference/platforms/lens-correction.md)
- [RUM privacy, events and packaging contract](reference/rum-analytics.md)
- [Bundled looks and source audit](luts/README.md), [licensing and attribution](reference/licensing.md)

## Architecture And Design

- [Product scope](../PRODUCT.md), [desktop design](../DESIGN.md) and [product roadmap](architecture/roadmap.md)
- [Maintained design assets](design/README.md), including the [four-platform app prototype and coverage](design/editor-workspace/README.md)
- [Iteration requirements](design/editing-iteration/requirements.md) and [technical design](design/editing-iteration/technical-design.md): phase-one remaining work, all of phase two and desktop updates
- [Workspace sub-requirements](design/editor-workspace/requirements.md) and [native sub-design](design/editor-workspace/technical-design.md), ITER-02 based on the r4 four-platform prototype
- [Active architecture and performance review, 2026-10-18](architecture/architecture-and-performance-review-2026-10-18.md), with separate historical measurements and current-code static recheck
- [Active cross-camera preset roadmap](architecture/cross-camera-presets-roadmap.md), including outstanding quality gates
- [Edit memory and batch export design](design/2026-10-09-edit-memory-batch-export/README.md)

## Releases

User-facing notes and corresponding-source instructions are grouped by release
line. Historical acceptance and integration records are separate from these
deliverables.

| Release line | Notes and source instructions |
| --- | --- |
| 0.8 | [0.8.2](releases/v0.8/v0.8.2.md), [source](releases/v0.8/v0.8.2-source.md), [Chinese announcement](releases/v0.8/v0.8.2-xiaohongshu.md); [0.8.1](releases/v0.8/v0.8.1.md), [source](releases/v0.8/v0.8.1-source.md); [0.8.0](releases/v0.8/v0.8.0.md), [source](releases/v0.8/v0.8.0-source.md) |
| 0.7 | [0.7.0](releases/v0.7/v0.7.0.md), [source](releases/v0.7/v0.7.0-source.md) |
| 0.6 | [0.6.0](releases/v0.6/v0.6.0.md), [source](releases/v0.6/v0.6.0-source.md), [Chinese update notes](releases/v0.6/master-recipes-update.md) |
| 0.5 | [0.5.1](releases/v0.5/v0.5.1.md), [source](releases/v0.5/v0.5.1-source.md); [0.5.0](releases/v0.5/v0.5.0.md), [source](releases/v0.5/v0.5.0-source.md) |
| 0.4 | [0.4.1](releases/v0.4/v0.4.1.md), [LibRaw source build](releases/v0.4/libraw-0.22.2-build.md), [0.4.0](releases/v0.4/v0.4.0.md) |
| 0.3 | [0.3.0](releases/v0.3/v0.3.0.md) |
| 0.2 | [0.2.1](releases/v0.2/v0.2.1.md), [0.2](releases/v0.2/v0.2.md) |
| 0.1 | [Mac 0.1](releases/v0.1/v0.1.md), [Android 0.1.0](releases/v0.1/android-v0.1.0.md) |

## History

- [Changelog](../CHANGELOG.md)
- [Cross-PR release acceptance, integration and review archive](archive/README.md)

Single-PR verification, measurements, reproduction notes and readiness lists
belong in PR descriptions, not new repository documents. Removed historical
records remain available through immutable Git links where existing references
still need their original evidence.
