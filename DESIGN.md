---
name: "RawLab iOS / iPadOS design extension"
description: "Native editor tokens; the macOS body is preserved."
rounded:
  ios-film-artwork: "4pt"
  ios-film-selection: "6pt"
  ios-overlay: "8pt"
spacing:
  ios-gap-compact: "4pt"
  ios-gap-standard: "8pt"
  ios-gap-controls: "12pt"
  ios-inset-controls: "16pt"
components:
  ios-adjustment-circle-base:
    size: "48pt"
  ios-hsl-swatch:
    size: "22pt"
  ios-histogram-header:
    height: "44pt"
  ios-film-artwork:
    rounded: "{rounded.ios-film-artwork}"
  ios-film-selection:
    rounded: "{rounded.ios-film-selection}"
  ios-status-container:
    rounded: "{rounded.ios-overlay}"
---

# RawLab Desktop Design

## Overview

Native macOS RAW and raster photo verification and editing, with a Photos-inspired bottom adjustment dock. The actual photo leads; this is not a marketing page or a catalog database. Preserve source photos and the shared rendering contract. Controls support Simplified Chinese, English, German, French, Japanese and Spanish; film simulation names retain their proper names.

Editable proposals are maintained in the [design asset registry](docs/design/README.md). Check each asset's metadata before reusing it: a review prototype does not replace the confirmed native rules in this document or establish implementation evidence.

<!-- BEGIN RAWLAB IOS IPADOS OVERVIEW -->
### iOS / iPadOS

**Creative North Star: "RawLab photo-first editor"**

The native iOS and iPadOS editor uses the same restrained gray-and-yellow identity for an Operate surface: import a photo, inspect a real preview, adjust it and export. The photograph leads; system navigation, sheets, menus, SF Symbols and semantic text styles carry the interface.

This extension is scoped to `RawLab/RawLab/UI/Editor/ContentView.swift`, its Adjustments, EditorState and Panels, and `RawLab/RawLab/UI/Controls/EditorComponents.swift`. The desktop prose above and in every section below remains the macOS authority. All frontmatter tokens have an `ios-` prefix and describe native points at their base size. Semantic UIKit colors and Dynamic Type styles are recorded as native source identities in the prose and sidecar; they are not converted into fixed hex values, CSS font families or invented tonal ramps. The sidecar records native components without presenting HTML/CSS approximations as SwiftUI or UIKit controls.

**Key Characteristics:**
- A dark photo workspace with yellow functional selection.
- Continuous control surfaces, a scrollable tool strip and complete numeric readouts.
- Window-dependent iPhone/iPad composition and a stacked accessibility layout.
- A moving horizontal ruler, a single-column system value wheel and explicit local drafts.

This document records implemented design and source behavior. Simulator evidence and its limits belong in `.impeccable/review/ios-editor-v4/README.md`; these rules do not establish physical haptic feel, performance improvement or RAW export correctness.
<!-- END RAWLAB IOS IPADOS OVERVIEW -->

## Colors

- Dark neutral-gray canvas (`NSColor(white: 0.12, alpha: 1)`) and native window-background surfaces reduce glare.
- Yellow identifies selected tools, changed values, default-value markers and adjustment progress. It is functional, not decorative.
- Film icons are square, flat front-label artwork inspired by documented Fujifilm packaging. Preserve each reference's colors and typography; no perspective boxes, sides or generic all-green styling. Simulations without physical products use explicitly marked concept labels.
- Histogram RGB channels and clipping colors retain their output-diagnostic meanings, not sensor-measurement claims.

<!-- BEGIN RAWLAB IOS IPADOS COLORS -->
### iOS / iPadOS

The photo canvas uses `Color(white: 0.12)`; the workspace and adjustment surface use `Color(.systemBackground)` and `Color(.secondarySystemBackground)`. The editor deliberately requests dark appearance even when the system appearance is light. Text uses `Color.primary` / `Color.secondary` and UIKit `label` / `secondaryLabel`; the ruler uses `UIColor.systemYellow` for its fixed indicator.

Yellow remains functional: selected tools, signed scalar values, progress arcs, film outlines and primary actions. Positive, negative and zero selected scalar badges keep the same yellow. The ruler's separate default dot uses `UIColor.secondaryLabel`; it moves with the tape and is not the yellow current indicator. HSL swatches preserve their eight named channel colors and selected outline.

**The iOS State Color Rule.** Preserve semantic text colors and express selection with a visible shape or label as well as tint.
<!-- END RAWLAB IOS IPADOS COLORS -->

## Typography

Use macOS system typography, compact 11-point tool labels and native control sizes. Numeric values use monospaced digits. Built-in film names must remain readable; wrap long names inside stable two-line slots. Do not add a display font or scale text with window width.

<!-- BEGIN RAWLAB IOS IPADOS TYPOGRAPHY -->
### iOS / iPadOS

Use SwiftUI system text styles and `UIFont.preferredFont(forTextStyle:)`. Parameter names use `.subheadline`; complete tappable values use semibold `.body` with monospaced digits. Reference text uses `.caption`; ruler labels use `.caption2`. The wheel title uses `.headline`, the complete temporary value and native picker rows use `.body`, and its range/default explanation uses `.caption`. SF Symbols follow the surrounding native styles.

Ordinary tool captions use two centered lines of `.caption`. At accessibility sizes, each tool changes to a horizontal row with a 44-point glyph circle and its complete `.body` title; only the glyph's Dynamic Type growth is capped. The caption-sized scalar badge is supplementary: measure it with the native preferred caption font, show it only when it fits the scaled circle, and use the glyph at accessibility sizes. The main parameter header retains the complete value and unit.

Film names retain stable two-line slots. Do not shrink text to make a circle, window or translated title fit.
<!-- END RAWLAB IOS IPADOS TYPOGRAPHY -->

## Layout

- Minimum content size is 950x620 points; the photo workspace expands with the window.
- A collapsible 200-300 point file tree spans the full content height on the left. Folder rows expand into subfolders and two-column supported-photo thumbnail grids.
- The photo area contains neutral/result comparison panes sharing zoom and pan. Fit mode uses bounded previews; actual-pixel viewing requests native resolution and accounts for display scale.
- A collapsible histogram floats at the photo area's upper-right. Optional photo information at the upper-left cycles between file details and capture settings, with a hidden state. Keep its width clear of the histogram and its text non-interactive so zoom and pan remain usable. There is no fixed right-side adjustment inspector.
- Every edit control is in the bottom of the right-hand workspace, never beneath the file tree. Its header holds the active film name, exposure baseline and reset menu. Drag its upper edge to resize; collapse completely and restore using the toolbar adjustment icon without losing values or the previous height.
- A single circular tool row contains film, strength and tonal/color/detail/effects adjustments. Film is a peer tool, never a separate mode tab.
- Selecting film replaces the value editor below the tool row with a horizontal square-label chooser. Center the list when it fits and scroll when it overflows. Selecting a numeric tool restores its input, slider, ticks and reset button without changing other values.
- Vignette and grain each occupy one tool in that row. Their parameter groups use compact native sliders and numeric inputs below it, with parameter and group reset actions. Vignette highlights are disabled for nonnegative amounts; auxiliary controls retain their values while amount is zero. All settings fit the minimum desktop window without adding a sidebar.
- The photo canvas has no title strip. Comparison identifiers are small bottom-left overlays only in comparison mode.

<!-- BEGIN RAWLAB IOS IPADOS LAYOUT -->
### iOS / iPadOS

A `NavigationStack` contains the photo workspace and the same adjustment surface across iPhone and iPad. Before import, the photo area shows the import action and the adjustment surface is absent. After import, the tool strip remains attached to the photo column and the parameter area scrolls independently.

The current layout policy uses side-by-side composition when the available width is at least 600 points, width exceeds height and Dynamic Type is below accessibility sizes. The side panel is `min(320, width × 0.48)` points wide; portrait, narrow windows and accessibility sizes use the stacked composition. These are window conditions, not device-model or orientation locks. Keep the tool strip horizontally scrollable and center the selected tool after its available width changes.

The stacked parameter region starts from a body-scaled 256-point budget, with extra room for geometry, lens and HSL. Accessibility layout also budgets the tool row and separators, then leaves up to 96 points for the photo whenever that space is available. A 96-point reservation is a layout budget, not a guaranteed photo height in an arbitrarily small window.

The value wheel explicitly uses a sheet on iPhone, including a landscape window with regular horizontal size class. iPad uses an anchored popover with system adaptation to a large sheet in compact presentation. Regular popovers prefer 440 points of height, or 600 at accessibility sizes, clamped to the presenting window height minus its safe-area insets and 40 points. Popover width is 280–480 points, with a 360-point ideal; sheets use their available width. The Cancel/Apply row remains outside the value content. Below it, use a single stacked column normally; when a sheet's content area is wider than 480 points and shorter than 400, put the scrollable title/value/range context beside the wheel and default action, giving the context 44% of the width. Do not auto-scroll the context away on presentation. The picker is bounded to 200–220 points normally and 100–264 at accessibility sizes; native row height is at least 44 points and grows with the preferred body font.

**The iOS Photo Budget Rule.** Reflow and scroll controls as the window and reading size change; keep the photograph available for evaluating the adjustment.
<!-- END RAWLAB IOS IPADOS LAYOUT -->

## Elevation & Depth

Use continuous surfaces and separators, not floating section cards. The histogram has an 8-point radius, a translucent black surface and a quiet border. Its header uses icons only, with accessible names and tooltips. Film and file selections use restrained yellow outlines.

<!-- BEGIN RAWLAB IOS IPADOS ELEVATION -->
### iOS / iPadOS

Continuous semantic backgrounds and dividers separate the photo, tool strip and parameter surface. System sheets and popovers supply task presentation; progress feedback uses system `.regularMaterial` near the photo edge. Do not obscure the imported photograph's center with a processing overlay.

The floating luminance histogram uses a translucent black surface (opacity 0.65), a quiet white border (opacity 0.12) and rounded corners. Film selection uses a restrained yellow fill (opacity 0.08) and outline. Tool circles use a subtle selected yellow fill (opacity 0.12) and border (opacity 0.5), with low-opacity white fill/border for unselected tools. These overlays do not establish a decorative shadow vocabulary.
<!-- END RAWLAB IOS IPADOS ELEVATION -->

## Shapes

- Circular tool icons have a stable 40-point diameter inside 72x70-point button layouts, leaving room for localized captions.
- Progress starts at the top: positive changes run clockwise, negative changes counterclockwise. Normalize each side against its own distance from the default. Keep the ring visible on the selected tool.
- Thumbnail corners are 4 points; film selection outlines are 6 points. Do not introduce decorative blobs or nested cards.

<!-- BEGIN RAWLAB IOS IPADOS SHAPES -->
### iOS / iPadOS

Ordinary adjustment tool circles start at 48 points and scale relative to the title3 text style. Accessibility tool rows use a 44-point glyph circle. Tappable controls and crop drag handles target at least 44×44 points; visible glyphs, the 22-point HSL swatches and the 12-point crop corner marks can be smaller within that target.

Progress arcs start at 12 o'clock, travel clockwise for positive change and counterclockwise for negative change, and cover at most 270 degrees. Normalize each direction against its own distance from the parameter default; do not turn every default into zero. A default has no progress arc.

Film artwork and film selection outlines use the namespaced rounded tokens. Histogram and material status containers use the overlay radius. Preserve these native shapes without adding decorative card stacks.
<!-- END RAWLAB IOS IPADOS SHAPES -->

## Components

- The macOS app icon is an abstract flat mark: two offset yellow/cyan photographic frames on a charcoal rounded-square tile. No aperture blades, film perforations, text, metallic bevels or 3D camera illustration. The color overlap represents the source-to-render transformation.

- Use SF Symbols, native sliders, numeric fields, pickers, menus and file dialogs. Film label bitmaps are bundled local resources with generation provenance.
- The toolbar contains file-tree visibility, open, a comparison toggle, photo information, one zoom menu, adjustment visibility and export. The information action cycles hidden/file/capture; desktop `I` is inactive while entering text. Fit, actual pixels, zoom in and zoom out live inside the zoom menu. Editing sliders do not belong in the toolbar.
- Directory contents load on demand. Thumbnail decoding uses embedded previews with orientation; no full RAW decode is triggered merely to populate the file tree.
- Histogram collapse state survives photo changes. Bottom tool selection survives film/numeric editor changes. Changed values retain their signed ring and marker.
- No-photo, loading, disabled, error/retry and export-complete states are explicit. Export must not overwrite the source file.
- Photo adjustments and look identities persist locally per original photo; unseen photos start with defaults. Save failures remain visible and retryable. No sidecars or cloud catalog are created.
- Batch export uses a frozen source adjustment snapshot, including denoise settings, in a separate desktop window or mobile task page. It never changes target photos' saved edits. The confirmed flow is documented in [the batch export design](docs/design/2026-10-09-edit-memory-batch-export/README.md).
- Single and batch export size controls default to native resolution, with a long-edge pixel ceiling, presets and custom entry. Keep this setting separate from preview quality. Desktop file-tree context actions can explicitly copy current settings to confirmed targets' local edit records, without opening targets first or changing source photos; folder scope is direct supported RAW/raster children only.

<!-- BEGIN RAWLAB IOS IPADOS COMPONENTS -->
### iOS / iPadOS

#### Adjustment ruler and scalar tool

Keep the yellow indicator fixed at the ruler center while the tape, labels and gray default dot move. Show the complete parameter name, legal value, unit, default and range; show a boundary label at either endpoint. Horizontal intent must be confirmed before adjustment, so vertical movement can scroll the parameter surface. The Fine action changes drag sensitivity to one quarter; it does not change the legal grid, range or committed value. Exposure uses −4…+4 EV in 0.05 EV steps; HSL axes use −100…+100 integers. Temperature keeps reciprocal tape mapping with numeric Kelvin values and a per-photo camera baseline.

The ruler keeps a fixed bottom edge. Minor strokes are 13 points, major strokes 22, and only nearby strokes grow toward 28. Actual horizontal tape movement excites each stroke within 24 points using `max(0, 1 − (distance / 24)²)`; retain the larger of its decayed residual and new weight. After the last nearby movement, each residual decays over 180 ms with `(1 − progress)²`. A pause relaxes the height while the finger can remain down. The marker, default dot, labels and container do not grow with the strokes. A stationary touch, native wheel, keyboard step or release does not inject another height pulse.

Release may settle the tape to the already committed legal value over 120 ms with an ease-out quadratic curve. It adds no inertia, parameter value or haptic event. Starting another adjustment interrupts the old finish. Cancel, loss of the ruler's window/focus, hiding and app inactivity clear residuals and settlement. Reduce Motion keeps the static 13/22-point strokes, current readout, default marker and arc, removes settlement, and restores surrounding controls immediately on release.

During adjustment, the current tool, main readout and ruler remain visible. Enter focus with a 100 ms ease-out fade; surrounding navigation, overlays and other tools retain their positions and names at opacity 0.08 on iPhone or 0.42 on iPad. After release, hold for 160 ms and return over 180 ms. A new drag cancels the pending return. Tool changes, source changes, scene inactivity and disappearance clear the focus task. Reduce Motion removes the hold and return animation. These are authored RawLab constants, not measurements of Apple's Photos app.

Only selected scalar tools show a circle value when it fits; multi-parameter tools retain their SF Symbol. The selected value persists after surroundings return. The `square.stack.3d.up` family identifies the master-recipe tool and choices.

#### Single-column native value wheel

The numeric entry uses one `UIPickerView` column, with each row a complete legal value. Keep sign, integer and decimal together. The title, complete temporary value, unit and range remain in the value context; VoiceOver names the temporary selection. The value list is sorted and deduplicated, includes legal endpoints, and retains a valid current value and default even if they are off the normal grid.

Wheel selection changes only its local draft. Cancel leaves the entering value intact; Apply commits the selected legal value and returns accessibility focus to the originating numeric button. A changed draft disables interactive dismissal; an unchanged draft can close. Default changes the same draft. Preserve the native picker's motion and system feedback instead of applying the custom ruler's physics or additional haptics to it.

#### Geometry, lens, looks and effects

Geometry and lens establish local drafts and render their temporary settings into the photo preview. Keep the Cancel/Apply row fixed outside the scrolling parameters. Apply is unavailable while the draft is unchanged, a ruler is adjusting, or `previewRendering` / `previewResizePending` indicates an incomplete preview. Apply commits, Cancel discards, and either action returns to Exposure. Switching tools with changes presents Apply, Discard or Continue Editing. Single-photo import is guarded by changed drafts; all export entry points remain disabled while either geometry or lens draft is active, including an unchanged draft. Lens editing is RAW-only and disabled for raster sources; its draft export guard is recorded from source, without claiming raster UI tests cover a RAW lens draft.

Film and master recipes are peer tools. Preserve real names and available bundled artwork; selecting no recipe clears the recipe/look choice without promising a global reset. Global reset explicitly returns all adjustments to neutral. HSL keeps eight named swatches, three independent axes, reset-current-color and reset-all actions. Denoise uses a native toggle and preset menu with expandable existing parameters. Vignette and grain preserve auxiliary settings at zero amount; vignette highlight protection is disabled for nonnegative amount with an explanation.

#### Preview, import and export

Single import uses the system photo picker or file picker and accepts supported RAW and raster images. Raster input follows the shared opaque RGB8 SDR contract, with orientation applied once and no additional RAW scene curve. Camera-only white balance, exposure baseline and lens controls are unavailable for raster input. Preserve the previous visible image during preview work and show edge feedback from the actual `previewRendering` or `previewResizePending` flags. Export actions also wait for those flags, a usable look and an idle editor; do not present an old preview as current merely because a generic busy flag is false.

Single-photo JPEG and rendered DNG export are available for both supported RAW and raster sources. JPEG saves to Photos; rendered DNG uses the system file destination flow. A rendered DNG is an output appearance, not the original RAW or preserved adjustment history. Batch export accepts supported RAW and raster targets and uses a frozen source adjustment snapshot, the existing output formats, explicit targets and per-item results. Resolve camera-only settings for each target independently without altering the saved snapshot or leaking RAW session state into raster targets. Keep native-resolution/long-edge export sizing separate from preview sizing, and report completion only from the actual output result.
<!-- END RAWLAB IOS IPADOS COMPONENTS -->

## Do's and Don'ts

- Keep all adjustments at the bottom and preserve the shared color-processing semantics.
- Keep both the file tree and floating histogram collapsible so the photo can occupy the workspace.
- Do not restore a right adjustment sidebar or a separate film-mode switch.
- RAW white balance starts at the per-photo as-shot calibration estimate. Kelvin increases toward warm; positive tint adds magenta. Use the camera baseline for reset and the signed ring. The slider uses reciprocal Kelvin; numeric input remains Kelvin. Do not claim Lightroom profile parity or that the estimate is a literal EXIF Kelvin tag.
- Histograms use shared linear pixel-count scaling with RGB/CMY/neutral-gray filled overlaps. The horizontal axis is the current sRGB output, not RAW sensor saturation or Adobe's internal working space.

<!-- BEGIN RAWLAB IOS IPADOS DOS -->
### iOS / iPadOS

- **Do** preserve the shared processing contract, semantic system colors, system text styles and native navigation/task presentations.
- **Do** keep complete values and units visible, provide 44-point action targets and retain named defaults, ranges and explicit draft actions.
- **Do** preserve the fixed indicator, moving tape, local residual decay and static Reduce Motion state.
- **Do** reflow by the available window and Dynamic Type; keep the selected tool and wheel draft stable across layout changes.
- **Don't** invent aggregate values for multi-parameter tools, shrink text into a badge, split numeric signs/decimals into separate wheels or introduce a custom numeric keyboard.
- **Don't** export an active geometry/lens draft or label an unfinished preview as current.
- **Don't** turn the custom ruler's lack of inertia into a change to the native picker's system behavior.
- **Don't** describe authored timing as an Apple measurement, or claim Simulator images prove physical haptics, performance improvement or RAW output correctness.
<!-- END RAWLAB IOS IPADOS DOS -->
