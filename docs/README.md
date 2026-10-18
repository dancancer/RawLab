# Documentation

The current source targets [v0.8.1, build 13](releases/v0.8.1.md). Use the
[GitHub release record](https://github.com/dancancer/RawLab/releases) for actual
published packages and checksums. v0.8.1 is a follow-up release; candidate
gates for the 0.8 line are tracked in [v0.8.0 preparation](releases/v0.8.0-preparation.md); the older v0.7 records below
retain their original candidate scope.

## Using RawLab

- [Installation and published packages](installation.md)
- [iPhone installation](ios-installation.md) and [Simplified Chinese guide](ios-installation.zh-CN.md)
- [macOS](../RawLabMac/README.md), [Windows](../RawLabWindows/README.md), and [Android](../RawLabAndroid/README.md)
- [Core and CLI](../lutools/README.md) and [usage guide](../lutools/docs/usage-guide.md)
- [Look reference](../lutools/docs/look-reference.md) and [LUT preparation](../lutools/docs/lut-preparation.md)

## Rendering and Interfaces

- [Color and rendering contract](../lutools/docs/color-contract.md)
- [Platform integration](../lutools/docs/platform-integration.md) and [iOS API](../lutools/docs/ios-api.md)
- [Native DCP look format](superpowers/specs/2026-10-03-native-dcp-look-design.md)
- [DCP HueSatMap and Metal contract](superpowers/specs/2026-10-03-dcp-hsm-metal-design.md)
- [Fujifilm LUT compatibility](superpowers/specs/2026-10-07-fuji-lut-compatibility.md)

## Development and Design

- [Gitflow, integration and release procedure](../agent.md) and [repository instructions](../AGENTS.md)
- [Desktop design](../DESIGN.md) and [product scope](../PRODUCT.md)
- [Product roadmap (Chinese)](roadmap.md), with dated planning status and links to current delivery records
- [Edit memory and batch export design](design/2026-10-09-edit-memory-batch-export/README.md)
- [Cross-camera preset roadmap](superpowers/specs/2026-10-07-cross-camera-presets-roadmap.md), including its outstanding quality gates
- [Licensing and attribution](licensing.md)
- [Hosted verification and its coverage boundaries](ci.md)
- [Architecture review, Android reproduction and performance record (2026-10-18, Chinese; baseline e493bb2)](architecture-and-performance-review-2026-10-18.md)

## v0.8.0 Preparation

- [Release notes](releases/v0.8.0.md) and [corresponding-source instructions](releases/v0.8.0-source.md)
- [Release blockers, scope decisions and remaining acceptance](releases/v0.8.0-preparation.md)
- [macOS Agent and ordinary-image verification](verification-agent-v08.md)
- [Windows Agent and integrated-source verification](../RawLabWindows/VERIFICATION-agent-v08.md)
- [All-platform ordinary-image input and current acceptance](verification-raster-input-all-platforms-2026-10-16.md)
- [Android integrated geometry/native/device verification](../RawLabAndroid/docs/geometry-v08-integration-verification-2026-10-16.md)
- [iOS integrated-source verification](ios-v08-development-integration-2026-10-16.md)
- [RUM local SDK verification (2026-10-16, before release builds carried the SDK)](verification-rum-analytics-2026-10-16.md)

## v0.7.0 Release Records

- [Candidate notes](releases/v0.7.0.md) and [corresponding-source instructions](releases/v0.7.0-source.md)
- [Feature deliveries and final verification](verification-v0.7.0.md)
- [Final five-feature composition report](verification-final-composition-2026-10-13.md)
- [Versioned local candidate package verification](verification-v0.7.0-candidate.md)
- [Version and release preparation checklist](releases/v0.7.0-preparation.md)
- [JPEG XL DNG verification](verification-dng-jpeg-xl-2026-10-12.md)

The five v0.7 features were integrated before that release. Its final composition
report distinguishes new execution from evidence reused through identical source.
These candidate records retain their original local scope; the versioned
[v0.7.0 Release](https://github.com/dancancer/RawLab/releases/tag/v0.7.0)
records that publication, not the current v0.8 candidate state.

## Published Releases and History

- [Changelog](../CHANGELOG.md)
- [v0.8.1 notes](releases/v0.8.1.md) and [corresponding source](releases/v0.8.1-source.md)
- [v0.8.0 notes](releases/v0.8.0.md) and [corresponding source](releases/v0.8.0-source.md)
- [v0.7.0 release](releases/v0.7.0.md) and [corresponding source](releases/v0.7.0-source.md)
- [v0.6.0 release](releases/v0.6.0.md), [corresponding source](releases/v0.6.0-source.md), and [release verification](verification-v0.6.0.md)
- [v0.5.1 release](releases/v0.5.1.md) and [v0.5.0 release](releases/v0.5.0.md)
- [Historical plans, feature checks, reviews and experiment references](archive/README.md)

Archived records preserve their dates, branch context, results and limitations.
Use the current integration tracker when assessing the next release.
