# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Stack

Shared C++17/LibRaw processing core with native SwiftUI/AppKit macOS, SwiftUI iOS, Kotlin/Compose Android and C#/WPF Windows clients.

## Users

Sighted photography enthusiasts editing their own camera RAW files and supported
photos on macOS, Windows, iPhone/iPad and Android. Their main job is to develop
a photo, choose or refine a film look, reuse adjustments across photos, and export
finished images while preserving the originals.

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

1. Open local photos through the platform's file or photo-library workflow, system
   Open With / Share / drag-and-drop, or (on iOS and Android) wireless Sony camera
   import and tethered shooting. New photos begin with neutral adjustments; reopening
   a photo restores saved edits.
2. Inspect the photo at a useful viewing scale (including desktop Fit / 1:1 actual
   pixels and mobile 1:1 viewport ROI tiling), choose a look or recipe if desired,
   adjust tone, color, detail, effects, geometry and lens controls, and compare
   before/after rendering.
3. Reuse selected adjustments through copy/paste, Quick/My Presets, or batch
   collections and synchronization, then fine-tune individual photos. Keep per-photo
   edit memory distinct from reusable presets and imported look files.
4. Export one photo or a batch. Batch tasks (including uniform frozen tasks and
   per-target frozen collection exports) preserve chosen settings, support recovery
   and report per-item failures; later editing must not change an already-started
   task. Mobile HDR exports support cancellable progress.

Desktop clients organize browsing, selection and editing into Edit, Select and
Preview workspaces, while mobile clients use dedicated per-tool workspaces with
local drafts. Photo browsing and collections support this editing workflow; RawLab's
scope is local editing and adjustment reuse, not a general photo catalog or cloud
library.

## Capabilities and Constraints

- Shared RAW development and supported SDR photo editing (processing version 3 by
  default) include tone and color controls (SDR exposure ±5 EV across all four
  clients; HDR ±4 EV), S-curve and multi-point luminance curves plus per-channel RGB
  curves (editable on iOS and Android; preserved, transferred and rendered on macOS
  and Windows, where SDR channel curves execute on CPU and report unsupported under
  GPU Force), 8-range HSL with photo target sampling, 3-zone color grading, detail
  and effects, geometry, lens correction (available for both RAW and JPEG/raster
  sources with a vignetting switch on iOS and Android; SDR lens editing remains
  RAW-only without a vignetting switch on macOS and Windows, while Bayer HDR RAW
  camera development exposes vignetting on desktop), looks, master recipes and user
  presets. Input formats, export formats and available controls remain platform-
  and mode-specific; use the [rendering contract](lutools/docs/color-contract.md)
  and platform guides linked from [the documentation index](docs/README.md).
- HDR editing is available across all four clients (macOS 15+, iOS, Android API 34+
  display with SDR fallback, and Windows FP16 scRGB with SDR fallback), supporting
  phone gain-map HDR JPEG/HEIF, linear Bayer/X-Trans Camera RAW HDR, and Apple
  ProRAW (Core Image on Apple; Adobe DNG SDK on Android/Windows). The HDR toolset
  includes auto exposure, exposure (±4 EV), contrast, highlights/shadows, black/white
  points, luminance and RGB curves (−8…+8 EV), relative white balance, vibrance,
  saturation, 8-range HSL with photo sampling, 3-zone color grading, clarity, dehaze,
  vignette, grain, sharpening, image-level HDR denoise, geometry, HDR peak limit
  (0…6 EV), separate SDR-base exposure/contrast/saturation controls, HDR CUBE LUTs /
  HDR Silver / HDR Silver Master, and Camera RAW HDR development (camera WB, exposure
  reference, FBDD, lens correction, fixed-D65 camera profiles, plus GPU AI denoising
  for compatible Bayer RAW HDR on Apple Silicon macOS and Windows). Exports include
  gain-map HDR JPEG on all four clients, HDR HEIF on supported macOS/iOS runtimes,
  and SDR JPEG / 16-bit PNG / 16-bit linear rendered DNG. Boundaries are recorded in
  the [HDR design](docs/design/hdr-photos/technical-design.md),
  [Android/Windows HDR scope](docs/design/hdr-photos/android-windows.md),
  [camera RAW HDR scope](docs/design/hdr-photos/camera-raw.md) and
  [ProRAW scope](docs/design/hdr-photos/proraw.md).
- Supported raster and RAW boundaries include opaque 16-bit integer RGB PNG on all
  four clients, 16-bit RGB TIFF on macOS/iOS/Windows, SDR HEIF on Windows and Android
  9+, Normal vs. Legacy X3F rendering ([X3F scope](lutools/docs/x3f-rendering.md)),
  full-sensor development for Sony cropped-aspect RAWs, 16-bit linear rendered DNG
  with embedded sRGB thumbnail/preview, and overflow-checked native-size processing
  up to ~2.1 gigapixels (subject to available device memory).
- Wireless Sony camera import and tethered shooting are available on Android
  (verified with Sony α7C II firmware 2.00 and an initial ZV-E10 profile, using
  model-agnostic capability probing without whitelist gating) and on iOS as a preview
  (untested on camera hardware); macOS and Windows do not ship camera import or
  tethering. Camera access is read-only and includes manual selection, one-tap
  resumable/deduplicated incremental import (RAW, JPEG, RAW+JPEG, with optional local
  JPEG resize/recompress) and foreground still-photo tethered shooting (live view,
  shutter, parameter read/write, tap-to-focus, live focus frames with lock
  confirmation, and focus area controls). See
  [mobile camera workspaces](docs/design/camera-transfer/android-camera-ui.md).
- Source photos remain read-only. Persisted edits, presets and batch settings
  preserve their versioned meaning. Opening a pre-v3 SDR non-recipe edit can start
  an automatic appearance-preserving migration: fit the new parameters, validate the
  full-source render, and atomically retain the original settings before adoption.
  Excessive error keeps the old version; a persistent rollback restores the entire
  original edit and stops automatic retries for that photo. See the
  [migration contract](lutools/docs/processing-migration.md). Corrupt edit records,
  presets, looks or batch journals are quarantined individually so the rest of the
  library remains usable; batch records retain up to 30 days / 100 jobs and tether
  records 90 days, while camera originals and Android system-opened private copies
  use explicit manual cleanup in Settings.
- Photo browsers expose saved non-default edits with a pencil marker and rendered
  thumbnails; iOS and Android add All/Edited/Unedited filters, and iOS Recently
  Opened retains up to 100 photos (~2 GiB of bounded local copies; removing a recent
  record preserves the original photo and saved adjustments). See the
  [edited-photo preview contract](docs/design/editor-workspace/edited-photo-previews.md).
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
  acceptance. Refer to release records such as the
  [0.11.0 release notes](docs/releases/v0.11/v0.11.0.md) and version-specific
  verification evidence before describing a capability as available on a particular
  platform or hardware device.

## Brand Commitments

The product name is **RawLab**. It is an independent project, not an official
Fujifilm product. Film looks do not promise equality with Fujifilm in-camera JPEGs
or unmeasured cross-camera matching. Bundled looks, artwork, models and third-party
components retain the attribution and usage limits recorded in
[licensing and attribution](docs/reference/licensing.md).

## Evidence on Hand

- [Product overview](README.md), [release records](docs/releases/) and the
  [documentation index](docs/README.md) describe capabilities and their evidence.
- Externalized asset packs ([`Shared/assets-manifest.json`](Shared/assets-manifest.json), materialized into the shared `.cache/shared/assets/` cache via `python3 scripts/assets/prepare.py --group all`) provide the externalized `lutools/examples/DJI_20250602164503_0444_D.DNG` fixture (in `assets-v1`) and bundled `.cube` LUTs alongside [synthetic regression fixtures](lutools/tests/fixtures/), including JPEG XL
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

RawLab targets **sighted photographers** working at standard OS text sizes.
Low-vision and screen-reader adaptations — including extreme large-text /
Accessibility Dynamic Type reflow, VoiceOver / TalkBack / screen-reader-first
interaction flows, and low-vision high-contrast-first layout compromises — are
outside active design and review scope. Legacy accessibility hooks and scaling
branches may remain in existing source code, but they are not active design
targets or UI review blockers.

Within this sighted-user scope, interfaces maintain legible standard-size
typography with monospaced or tabular numerals, non-color indicators alongside
tint for selection and modified states, comfortable touch and pointer targets,
direct numeric entry, desktop keyboard shortcuts, and optional reduced-motion
restraint where practical. Product terminology and translations use the
[shared localization sources](Shared/strings/README.md) across six languages
(`zh-Hans`, `en`, `de`, `fr`, `ja`, `es`), with platform-specific wording where
the native workflow differs.
