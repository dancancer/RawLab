# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Stack

Shared C++17/LibRaw processing core with native SwiftUI/AppKit macOS, SwiftUI iOS, Kotlin/Compose Android and C#/WPF Windows clients.

## Users

Photography enthusiasts editing their own camera RAW files and supported photos
on macOS, Windows, iPhone/iPad and Android. Their main job is to develop a photo,
choose or refine a film look, reuse adjustments across photos, and export finished
images while preserving the originals.

Developers and automation users also use the shared core and desktop Agent tools
to reproduce edits and verify processing behavior. Technical LUT inspection is a
supporting workflow, not the product's primary audience or purpose.

## Product Purpose

RawLab is a local RAW and photo editor with four native clients. It brings
cross-camera film looks, reusable adjustments and consistent export semantics
into the same editing workflow.

Success means the user can reach an intended result, compare it with the
unadjusted rendering, resume saved work, reuse selected adjustments and export
the confirmed result. The original photo remains unchanged, and failed or
unsupported operations are reported accurately.

## Positioning

Film looks are a starting point for editing photos from different camera brands.
Built-in looks, master recipes, imported looks and user adjustment presets serve
different purposes and retain distinct identities.

Native interfaces adapt to each operating system while sharing processing and
parameter contracts. The GUI, desktop Agent tools and batch exports reuse that
core; cross-platform consistency concerns parameter meaning and rendering, not
identical screen layouts or an assumption that every device supports every mode.

## Operating Context

1. Open local photos through the platform's file or photo-library workflow. New
   photos begin with neutral adjustments; reopening a photo restores saved edits.
2. Inspect the photo, choose a look if desired, adjust tone, color, detail and
   geometry, and compare the result at a useful viewing scale.
3. Reuse selected adjustments through copy/paste, named presets or photo
   collections, then fine-tune individual photos. Keep per-photo edit memory
   distinct from reusable presets and imported look files.
4. Export one photo or a batch. Batch tasks freeze the chosen settings, support
   recovery and report per-item failures; later editing must not change an
   already-started task.

Photo browsing and collections support this editing workflow. RawLab's scope is
local editing and adjustment reuse, not a general photo catalog or cloud library.

## Capabilities and Constraints

- Shared RAW development and supported SDR photo editing include tone and color
  controls, curves, HSL, color grading, detail/effects, geometry, looks and recipes.
  Input formats, export formats and available controls remain platform- and
  mode-specific; use the [rendering contract](lutools/docs/color-contract.md) and
  platform guides linked from [the documentation index](docs/README.md).
- Supported gain-map HDR photos have a separate editing path on supported Apple
  platforms, with a narrower tool set. HDR is not implied by RAW support, output
  bit depth or the shared core. Its boundaries are recorded in the
  [HDR design](docs/design/hdr-photos/technical-design.md).
- Source photos remain read-only. Persisted edits, presets and batch settings
  preserve their versioned meaning; migrations or rendering changes must be
  explicit rather than silently reinterpreting saved work. Compatibility details
  belong in the contracts and release notes.
- Preview and export follow the same processing semantics. A reduced preview is
  not evidence of full-resolution quality, and numerical correctness is distinct
  from a subjective preference for a look.
- Ordinary GPU Auto processing retains CPU fallback; Force requires actual GPU
  execution. Desktop AI denoising instead requires a supported hardware GPU
  backend (Mac Core ML or Windows DirectML), reports unavailability and does not
  fall back to CPU neural inference. Device support must be verified separately.
- LUT compatibility settings describe declared color assumptions, not measured
  camera calibration or a certified match to the author's intended appearance.
  Preserve the [LUT color contract](docs/reference/formats/lut-color-contract-v1.md).
- Local photo processing and edit storage are distinct from user-controllable
  usage statistics. The [statistics and privacy contract](docs/reference/rum-analytics.md)
  excludes photo content, previews, file names/paths and EXIF from collection.
- Roadmap entries and prototypes record intent, not implementation or device
  acceptance. Refer to version-specific release and verification evidence before
  describing a capability as available on a particular platform.

## Brand Commitments

The product name is **RawLab**. It is an independent project, not an official
Fujifilm product. Film looks do not promise equality with Fujifilm in-camera JPEGs
or unmeasured cross-camera matching. Bundled looks, artwork, models and third-party
components retain the attribution and usage limits recorded in
[licensing and attribution](docs/reference/licensing.md).

## Evidence on Hand

- [Product overview](README.md), [release records](docs/releases/) and the
  [documentation index](docs/README.md) describe capabilities and their evidence.
- The repository includes a [DJI DNG](lutools/examples/DJI_20250602164503_0444_D.DNG)
  and [synthetic regression fixtures](lutools/tests/fixtures/), including JPEG XL
  DNG inputs. Other camera RAWs are external test inputs; these fixtures do not
  establish camera-wide calibration or image-quality claims.
- [Bundled looks](Shared/BundledLooks/), [master recipes](Shared/master-recipes.json)
  and the [LUT source audit](docs/luts/README.md) provide real product assets and
  provenance. [Design assets](docs/design/README.md) document existing interfaces
  and proposed flows; their approval and implementation states remain separate.

## Product Principles

- Keep the photo and the editing task central; controls support inspecting and
  changing the image.
- Share processing and parameter meaning while respecting native interaction.
- Preserve originals and make saved, pending, failed and unsupported states clear.
- Make adjustments reproducible across saved edits, reuse and export, with
  explicit compatibility boundaries.
- Separate numerical correctness, device verification and subjective style
  preference; support each claim with the appropriate evidence.

## Accessibility & Inclusion

The [editor requirements](docs/design/editor-workspace/requirements.md) require
usable large-text and adaptive layouts, accessible control names and values,
non-color indicators for selection and changes, native numeric entry and respect
for reduced motion. Desktop interactions include keyboard operation; mobile
interactions must work with touch and platform accessibility services.

Product terminology and translations use the
[shared localization sources](Shared/strings/README.md), with platform-specific
wording where the native workflow differs. These are ongoing requirements, not
a claim that every screen or device has passed accessibility acceptance.
